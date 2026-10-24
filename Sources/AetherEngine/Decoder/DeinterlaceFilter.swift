import CoreVideo
import Foundation
import AetherLibavfilter
import AetherLibavutil

/// Deinterlacer cadence for the software-decode path, resolved from `LoadOptions` at load time and
/// handed to `SoftwareVideoDecoder` before `open`.
struct DeinterlaceConfig: Sendable, Equatable {
    var fieldRate: DeinterlaceFieldRate = .field
}

/// Persistent deinterlacing graph for the software-decode path (MPEG-2/VC-1/MPEG-4 and, per the
/// #107 routing rule, interlaced H.264, tvOS AVPlayer does not deinterlace, so 1080i/576i
/// broadcast routes here; see VideoRoutingPolicy).
///
/// It runs on the display buffers `PlanarFrameFinisher` writes: `yadif_videotoolbox`
/// (`bwdif_videotoolbox` when the linked build has it, see `hardwareFilterName`), the kernel as a
/// Metal compute shader over the buffers' planes. Every format the finisher writes (NV12, P010,
/// NV16, P210, P216, NV24, P410, P416) is one the kernel textures. The input frames context carries
/// the display pool's attributes (`SoftwareVideoDecoder.displayBufferAttributes`) and the filter
/// makes its output buffers with them (FFmpegBuild's `pixel_buffer_attributes` patch), so the sink's
/// buffers are displayed as they come, carrying the input's attachments (colour, pixel aspect).
/// Runs at field rate by default (`config.fieldRate`). A graph that cannot be built is logged and
/// the pictures go out as decoded.
///
/// MUST be persistent: yadif/bwdif are temporal filters that need a continuous frame stream.
/// `deint=interlaced` passes progressive frames through untouched (the input buffer itself).
/// Torn down on seek so stale temporal references never cross a discontinuity; lazily rebuilt on
/// the next interlaced frame. Not thread-safe; the owning decoder serializes access with its lock.
///
/// PTS contract: output frames carry PTS on `outputTimeBase` (the buffersink's time_base), NOT the
/// input stream time_base. yadif/bwdif halve their output link time_base and scale PTS by 2, and
/// with `mode=send_field` the two fields of a frame land on ODD/EVEN ticks of that halved base,
/// rescaling back to the stream base would collapse each pair onto one integer PTS (duplicate
/// timestamps, every other field dropped). Callers must timestamp with `outputTimeBase`.
final class DeinterlaceFilter {

    /// Set by the owning decoder (under its lock) before the first `ensureGraph`.
    var config = DeinterlaceConfig()

    /// Time base of the filter output. Valid while `isActive`; see the PTS contract above.
    private(set) var outputTimeBase = AVRational(num: 0, den: 1)

    /// What the graph was built for: a buffer of another size or format needs a new one.
    private struct Geometry: Equatable {
        var width: Int
        var height: Int
        var pixelFormatType: OSType
    }

    private var graph: UnsafeMutablePointer<AVFilterGraph>?
    private var srcCtx: UnsafeMutablePointer<AVFilterContext>?
    private var sinkCtx: UnsafeMutablePointer<AVFilterContext>?
    /// The frames context the pushed buffers are described by; the filter's output context copies
    /// its attributes and range.
    private var framesRef: UnsafeMutablePointer<AVBufferRef>?
    private var geometry: Geometry?
    private var loggedUnavailable = false

    /// VideoToolbox hw device, created lazily for the graph and kept across seek teardowns (device
    /// creation is not per-stream state).
    private var hwDeviceRef: UnsafeMutablePointer<AVBufferRef>?

    var isActive: Bool { graph != nil }

    /// The Metal deinterlacer to use: `bwdif_videotoolbox` when the linked FFmpeg has it (better
    /// edge reconstruction), else `yadif_videotoolbox`. FFmpeg 8.1 ships only the yadif one; the
    /// preference costs nothing until a build adds bwdif. Both take the same `mode` / `parity` /
    /// `deint` options. nil when neither is linked.
    static func hardwareFilterName(available: (String) -> Bool = { avfilter_get_by_name($0) != nil }) -> String? {
        ["bwdif_videotoolbox", "yadif_videotoolbox"].first(where: available)
    }

    /// Builds and drops one graph over a small NV12 buffer, so the Metal pipeline and the device
    /// exist before the first interlaced picture needs them. False when no graph can be built.
    static func prewarmHardwarePipeline() -> Bool {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  SoftwareVideoDecoder.displayBufferAttributes, &buffer) == kCVReturnSuccess,
              let buffer, let frame = av_frame_alloc() else { return false }
        var ownedFrame: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&ownedFrame) }
        frame.pointee.pts = 0
        frame.pointee.flags |= AV_FRAME_FLAG_INTERLACED
        frame.pointee.sample_aspect_ratio = AVRational(num: 1, den: 1)

        let filter = DeinterlaceFilter()
        defer { filter.teardown() }
        return filter.ensureGraph(buffer: buffer, properties: frame, timeBase: AVRational(num: 1, den: 30))
    }

    /// Build (or rebuild after a size or format change) the graph for `buffer`, a display buffer
    /// the finisher wrote; `properties` is its decoded frame (aspect, colour). Returns false when
    /// no deinterlacer is in the linked FFmpeg build or the graph cannot be built; the caller then
    /// shows the picture as decoded.
    func ensureGraph(buffer: CVPixelBuffer, properties frame: UnsafePointer<AVFrame>, timeBase: AVRational) -> Bool {
        let wanted = Geometry(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                              pixelFormatType: CVPixelBufferGetPixelFormatType(buffer))
        if graph != nil, geometry == wanted { return true }
        teardown()
        return buildGraph(wanted, properties: frame, timeBase: timeBase)
    }

    private func buildGraph(_ wanted: Geometry, properties frame: UnsafePointer<AVFrame>, timeBase: AVRational) -> Bool {
        // AE#492: the build cost belongs on the line that reports the build. A seek tears the graph
        // down, so this is paid per seek on interlaced sources and never on progressive ones, and
        // without the number the two are not comparable.
        let buildStart = DispatchTime.now()
        guard let deintName = Self.hardwareFilterName() else {
            if !loggedUnavailable {
                loggedUnavailable = true
                EngineLog.emit("[Deinterlace] no bwdif_videotoolbox / yadif_videotoolbox in the linked FFmpeg build; "
                               + "interlaced pictures go out as decoded", category: .swPlayback)
            }
            return false
        }
        guard ensureHWDevice(), let dev = hwDeviceRef else { return false }
        guard let frames = Self.framesContext(device: dev, geometry: wanted) else {
            EngineLog.emit("[Deinterlace] frames context for \(wanted) failed", category: .swPlayback)
            return false
        }
        var framesOpt: UnsafeMutablePointer<AVBufferRef>? = frames
        var built = false
        defer { if !built { av_buffer_unref(&framesOpt) } }

        guard let g = avfilter_graph_alloc(),
              let bufferFilter = avfilter_get_by_name("buffer"),
              let sinkFilter = avfilter_get_by_name("buffersink"),
              let deintFilter = avfilter_get_by_name(deintName) else {
            return false
        }
        var gOpt: UnsafeMutablePointer<AVFilterGraph>? = g
        defer { if !built { avfilter_graph_free(&gOpt) } }

        // Allocated, described and only then initialised: a hardware format needs its frames context
        // before the buffer source initialises.
        guard let srcC = avfilter_graph_alloc_filter(g, bufferFilter, "in"),
              let parameters = av_buffersrc_parameters_alloc() else { return false }
        let sar = frame.pointee.sample_aspect_ratio
        parameters.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        parameters.pointee.width = Int32(wanted.width)
        parameters.pointee.height = Int32(wanted.height)
        parameters.pointee.time_base = timeBase
        parameters.pointee.sample_aspect_ratio = sar.num > 0 && sar.den > 0 ? sar : AVRational(num: 1, den: 1)
        // The first frame's colour description, so the link matches the incoming frames ("Changing
        // video frame properties on the fly" warning otherwise).
        parameters.pointee.color_space = frame.pointee.colorspace
        parameters.pointee.color_range = frame.pointee.color_range
        parameters.pointee.hw_frames_ctx = frames
        let paramRet = av_buffersrc_parameters_set(srcC, parameters)
        av_free(parameters)
        let srcInit = paramRet >= 0 ? avfilter_init_str(srcC, nil) : paramRet
        var sink: UnsafeMutablePointer<AVFilterContext>?
        let sinkRet = avfilter_graph_create_filter(&sink, sinkFilter, "out", nil, nil, g)
        guard srcInit >= 0, sinkRet >= 0, let sinkC = sink else {
            EngineLog.emit("[Deinterlace] buffer source / sink failed src=\(srcInit) sink=\(sinkRet)",
                           category: .swPlayback)
            return false
        }

        // Built filter by filter: the deinterlacer validates its device at init, which
        // avfilter_graph_parse_ptr would run before a device could be attached.
        // deint=interlaced: progressive frames pass through untouched.
        let mode = config.fieldRate == .field ? "send_field" : "send_frame"
        let deintOpts = "mode=\(mode):parity=auto:deint=interlaced"
        guard let deintC = avfilter_graph_alloc_filter(g, deintFilter, "deint") else { return false }
        deintC.pointee.hw_device_ctx = av_buffer_ref(dev)
        let deintInit = avfilter_init_str(deintC, deintOpts)
        guard deintInit >= 0 else {
            EngineLog.emit("[Deinterlace] \(deintName) init failed ret=\(deintInit)", category: .swPlayback)
            return false
        }
        guard avfilter_link(srcC, 0, deintC, 0) >= 0, avfilter_link(deintC, 0, sinkC, 0) >= 0 else {
            EngineLog.emit("[Deinterlace] graph link failed", category: .swPlayback)
            return false
        }
        let configRet = avfilter_graph_config(g, nil)
        guard configRet >= 0 else {
            EngineLog.emit("[Deinterlace] graph_config failed ret=\(configRet) \(deintName)=\(deintOpts)",
                           category: .swPlayback)
            return false
        }

        built = true
        graph = g
        srcCtx = srcC
        sinkCtx = sinkC
        framesRef = frames
        geometry = wanted
        outputTimeBase = av_buffersink_get_time_base(sinkC)
        let buildMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart.uptimeNanoseconds) / 1e6
        EngineLog.emit(
            "[Deinterlace] engaged: \(wanted.width)x\(wanted.height) \(Self.fourCC(wanted.pixelFormatType)) "
            + "(\(deintName)=\(deintOpts)) outTB=\(outputTimeBase.num)/\(outputTimeBase.den) "
            + "built in \(String(format: "%.1f", buildMs))ms",
            category: .swPlayback
        )
        return true
    }

    /// A VideoToolbox frames context describing the display buffers of `geometry`: their format and
    /// range, and the display pool's attributes for the buffers the filter makes.
    private static func framesContext(device: UnsafeMutablePointer<AVBufferRef>,
                                      geometry: Geometry) -> UnsafeMutablePointer<AVBufferRef>? {
        let swFormat = av_map_videotoolbox_format_to_pixfmt(geometry.pixelFormatType)
        guard swFormat != AV_PIX_FMT_NONE, let ref = av_hwframe_ctx_alloc(device) else { return nil }
        var owned: UnsafeMutablePointer<AVBufferRef>? = ref
        let frames = ref.pointee.data.withMemoryRebound(to: AVHWFramesContext.self, capacity: 1) { $0 }
        frames.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX
        frames.pointee.sw_format = swFormat
        frames.pointee.width = Int32(geometry.width)
        frames.pointee.height = Int32(geometry.height)
        let vt = frames.pointee.hwctx.assumingMemoryBound(to: AVVTFramesContext.self)
        let fullRange = SoftwareVideoDecoder.OutputFormat(pixelFormatType: geometry.pixelFormatType)?.fullRange ?? false
        vt.pointee.color_range = fullRange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
        vt.pointee.pixel_buffer_attributes = Unmanaged.passRetained(SoftwareVideoDecoder.displayBufferAttributes)
        guard av_hwframe_ctx_init(ref) >= 0 else {
            av_buffer_unref(&owned)
            return nil
        }
        return ref
    }

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
    }

    /// Create (once) the VideoToolbox hw device the graph runs on.
    private func ensureHWDevice() -> Bool {
        if hwDeviceRef != nil { return true }
        let ret = av_hwdevice_ctx_create(&hwDeviceRef, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0)
        guard ret >= 0, hwDeviceRef != nil else {
            EngineLog.emit("[Deinterlace] videotoolbox hwdevice create failed ret=\(ret)", category: .swPlayback)
            return false
        }
        return true
    }

    /// Feed one display buffer, timed and described by `properties` (its decoded frame: pts, field
    /// flags, aspect, colour, side data). The filter holds its own reference to `buffer`.
    func push(_ buffer: CVPixelBuffer, properties: UnsafePointer<AVFrame>) -> Int32 {
        guard let src = srcCtx, let framesRef, let frame = av_frame_alloc() else { return -1 }
        var owned: UnsafeMutablePointer<AVFrame>? = frame
        defer { av_frame_free(&owned) }
        let copied = av_frame_copy_props(frame, properties)
        guard copied >= 0 else { return copied }
        frame.pointee.format = AV_PIX_FMT_VIDEOTOOLBOX.rawValue
        frame.pointee.width = Int32(CVPixelBufferGetWidth(buffer))
        frame.pointee.height = Int32(CVPixelBufferGetHeight(buffer))
        let retained = Unmanaged.passRetained(buffer).toOpaque()
        guard let ref = av_buffer_create(retained.assumingMemoryBound(to: UInt8.self), MemoryLayout<UnsafeRawPointer>.size, { _, data in
            if let data { Unmanaged<CVPixelBuffer>.fromOpaque(data).release() }
        }, nil, 0) else {
            Unmanaged<CVPixelBuffer>.fromOpaque(retained).release()
            return -12
        }
        frame.pointee.buf.0 = ref
        frame.pointee.data.3 = retained.assumingMemoryBound(to: UInt8.self)
        guard let hw = av_buffer_ref(framesRef) else { return -12 }
        frame.pointee.hw_frames_ctx = hw
        return av_buffersrc_add_frame_flags(src, frame, 0)
    }

    /// Signal end of stream: yadif/bwdif then filter the frame they held as look-ahead, and `pull`
    /// returns AVERROR_EOF once it is out. The buffersrc refuses frames from here on; `teardown`.
    func pushEndOfStream() -> Int32 {
        guard let src = srcCtx else { return -1 }
        return av_buffersrc_add_frame_flags(src, nil, 0)
    }

    /// Pull the next filtered frame into `out`. Returns >= 0 on success, AVERROR(EAGAIN) when the
    /// filter needs more input. Output PTS is on `outputTimeBase` (see class doc); the frame is
    /// `AV_PIX_FMT_VIDEOTOOLBOX`, its display buffer in `data[3]`.
    func pull(into out: UnsafeMutablePointer<AVFrame>) -> Int32 {
        guard let sink = sinkCtx else { return -1 }
        return av_buffersink_get_frame(sink, out)
    }

    /// Free the graph. Called on seek (stale temporal references) and close; `ensureGraph` lazily
    /// rebuilds. The hw device ref survives teardown (not per-stream state); freed in deinit.
    func teardown() {
        if graph != nil {
            avfilter_graph_free(&graph)
        }
        graph = nil
        srcCtx = nil
        sinkCtx = nil
        if framesRef != nil { av_buffer_unref(&framesRef) }
        geometry = nil
        outputTimeBase = AVRational(num: 0, den: 1)
    }

    deinit {
        teardown()
        if hwDeviceRef != nil {
            av_buffer_unref(&hwDeviceRef)
        }
    }
}
