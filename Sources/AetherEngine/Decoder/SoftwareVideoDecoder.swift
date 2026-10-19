import Foundation
import os
import CoreMedia
import CoreVideo
import VideoToolbox
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import AetherLibswscale

/// libavcodec software video decoder for codecs without VideoToolbox support (e.g. AV1/dav1d on Apple TV).
/// Uses sws_scale (SIMD/NEON-optimized) for YUV→NV12/P010 conversion; required to hit 24fps at 1080p for AV1.
final class SoftwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    // FFmpeg 8.x exposes SwsContext as a real struct (7.x was OpaquePointer); pointer type must match or call sites miscompile.
    private var swsContext: UnsafeMutablePointer<SwsContext>?
    /// What `swsContext` was built for; a different key rebuilds it. Guarded by `lock`, like the context.
    private var swsKey: SwscaleSetup?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    var onFrame: DecodedFrameHandler?

    /// Fires once (demux thread) on first HDR10+ side data; engine flips videoFormat to .hdr10Plus.
    private var seenHDR10Plus = false
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    /// AE#658: fires (decode thread) on the first displayed frame and whenever the decoded format or the
    /// display buffer's format changes. Guarded by `lock`, like everything `emit` reads.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var decodedFormatKey: DecodedFormatKey?
    private var reportedFormatKey: DecodedFormatKey?

    /// The decoder's own output, taken before a deinterlace graph can rewrite the frame (the hardware
    /// graph hands `emit` a VideoToolbox surface whose pixel format says nothing about the decode).
    struct DecodedFormatKey: Equatable {
        var pixelFormat: Int32
        var color: ColorDescription
        var pixelBufferType: OSType = 0
    }

    /// True when the source is >8-bit (HDR10, AV1 HDR).
    private var use10Bit = false

    /// Container-declared SAR fallback for anamorphic DVD/SD content (NTSC 720x480, PAL 720x576, widescreen DVDs).
    /// Native VideoToolbox gets this from the container automatically; the software path must attach it explicitly.
    private var streamSAR = AVRational(num: 1, den: 1)

    /// #177: first sane non-square SAR of the stream. Once latched, every frame attaches this value;
    /// interlaced sources can oscillate SAR per-field and a garbage AVCodecContext value (1088:1 seen
    /// in the field) must never flicker the display geometry. Guarded by `lock` (set inside emit).
    private var latchedSAR: AVRational?
    private var loggedSARLatch = false
    /// #290: one line per stream when a declared SAR is dropped for the aspect it produces, so a
    /// smeared picture names its own cause instead of looking like a renderer bug.
    private var loggedSARReject = false

    private var pixelBufferPool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat = OutputFormat(tenBit: false, fullRange: false)
    /// The format the last converted frame asked for, so a change is logged once (release-visible) rather
    /// than per frame. Guarded by `lock`, like the pool.
    private var loggedOutputFormat: OutputFormat?

    /// Skip pre-seek frames; decoded for reference but not converted.
    /// Guarded by `skipLock` not `lock`: emit() runs with `lock` held, so a same-lock accessor would deadlock.
    /// CMTime is multi-word: old unsynchronized access was a torn-read candidate.
    var skipUntilPTS: CMTime? {
        get { skipLock.lock(); defer { skipLock.unlock() }; return _skipUntilPTS }
        set { skipLock.lock(); _skipUntilPTS = newValue; skipLock.unlock() }
    }
    private var _skipUntilPTS: CMTime?

    /// AE#492: guarded by `lock`, the same one `flush()` and `decode(packet:epoch:)` take.
    private var _feedEpoch: UInt64 = 0
    var feedEpoch: UInt64 {
        lock.lock(); defer { lock.unlock() }; return _feedEpoch
    }
    private let skipLock = NSLock()

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipLock.lock()
        if let current = _skipUntilPTS, CMTimeCompare(current, threshold) == 0 {
            _skipUntilPTS = nil
        }
        skipLock.unlock()
    }

    /// Protects codecContext across the demux thread (decode) and main thread (close/flush).
    private let lock = NSLock()

    /// Deinterlacer for interlaced MPEG-2/VC-1/MPEG-4 (DVD rips, SD broadcast); see DeinterlaceFilter class doc.
    /// Engaged lazily on first interlaced frame; every subsequent frame routes through it. Guarded by `lock`.
    private let deinterlacer = DeinterlaceFilter()

    /// Deinterlacer selection + cadence from LoadOptions. Set by the host BEFORE `open`;
    /// applied to the filter there (mutating it mid-stream would need a graph rebuild).
    var deinterlaceConfig = DeinterlaceConfig()

    /// #544: decode on the calling thread with no frame-level threading. Set before `open`; the
    /// still extractor is the only caller, everything on a playback path wants the parallel default.
    var decodesSingleThreaded = false

    /// The pixel buffer format this decoder hands the display layer, read off the decoded frame (audit
    /// DEC-107). The container's declaration alone missed two cases: `color_range` was never read, so a
    /// full-range AV1 / VP9 / HEVC picture was labelled video range and shown crushed, and
    /// `bits_per_raw_sample` is 0 for libdav1d and the AV1 / VP9 parsers, so a 10-bit SDR stream was
    /// dithered down to 8 bit.
    ///
    /// #8: the frame's chroma subsampling and depth are kept wherever CoreVideo has a bi-planar format
    /// for them. Everything used to go out as 4:2:0 NV12 / P010, so a 4:2:2 or 4:4:4 source (ProRes,
    /// XDCAM / broadcast 4:2:2, HEVC and H.264 4:2:2 / 4:4:4 that VideoToolbox will not decode) had its
    /// chroma halved by swscale only for the display layer to upsample it again, and a 12-bit picture
    /// was cut to 10 bits with no dither. The 16-bit formats (`sv22` / `sv44`) are video range only:
    /// their range is the 10-bit range shifted left six, so a full-range 12-bit picture goes to the
    /// 10-bit full-range format, dithered.
    struct OutputFormat: Equatable {
        enum Chroma: Equatable { case yuv420, yuv422, yuv444 }
        enum Depth: Equatable { case eight, ten, sixteen }

        var chroma: Chroma
        var depth: Depth
        var fullRange: Bool
        /// The frame has more bits than `depth` keeps. swscale's P010 / P210 / P410 writers round with
        /// no dither (and its unscaled 4:2:0 path just shifts, leaving the extra bits in what CoreVideo
        /// defines as padding), so swscale writes the 16-bit sibling, which has the same memory layout,
        /// and `ditherTo10Bit` orders it down to the 10 bits the format keeps.
        var dithers: Bool

        init(chroma: Chroma = .yuv420, depth: Depth, fullRange: Bool, dithers: Bool = false) {
            self.chroma = chroma
            self.depth = depth
            self.fullRange = fullRange
            self.dithers = dithers
        }

        init(tenBit: Bool, fullRange: Bool) {
            self.init(depth: tenBit ? .ten : .eight, fullRange: fullRange)
        }

        var tenBit: Bool { depth != .eight }

        var pixelFormatType: OSType {
            switch (chroma, depth, fullRange) {
            case (.yuv420, .eight, false): kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            case (.yuv420, .eight, true): kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            // No 16-bit 4:2:0 bi-planar format exists; `outputFormat` never asks for one.
            case (.yuv420, _, false): kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            case (.yuv420, _, true): kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            case (.yuv422, .eight, false): kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
            case (.yuv422, .eight, true): kCVPixelFormatType_422YpCbCr8BiPlanarFullRange
            case (.yuv422, .ten, false): kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            case (.yuv422, .ten, true): kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
            case (.yuv422, .sixteen, _): kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange
            case (.yuv444, .eight, false): kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange
            case (.yuv444, .eight, true): kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
            case (.yuv444, .ten, false): kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
            case (.yuv444, .ten, true): kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
            case (.yuv444, .sixteen, _): kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange
            }
        }

        var swscaleFormat: AVPixelFormat {
            switch (chroma, depth == .sixteen || dithers ? Depth.sixteen : depth) {
            case (.yuv420, .eight): AV_PIX_FMT_NV12
            case (.yuv420, .ten): AV_PIX_FMT_P010LE
            case (.yuv420, .sixteen): AV_PIX_FMT_P016LE
            case (.yuv422, .eight): AV_PIX_FMT_NV16
            case (.yuv422, .ten): AV_PIX_FMT_P210LE
            case (.yuv422, .sixteen): AV_PIX_FMT_P216LE
            case (.yuv444, .eight): AV_PIX_FMT_NV24
            case (.yuv444, .ten): AV_PIX_FMT_P410LE
            case (.yuv444, .sixteen): AV_PIX_FMT_P416LE
            }
        }

        /// The buffer's own format read back, for a buffer this decoder did not convert (the
        /// hardware deinterlacer's surfaces): nil for a format no `OutputFormat` describes.
        init?(pixelFormatType type: OSType) {
            guard let match = Self.all.first(where: { $0.pixelFormatType == type }) else { return nil }
            self = match
        }

        private static let all: [OutputFormat] = [Chroma.yuv420, .yuv422, .yuv444].flatMap { chroma in
            [Depth.eight, .ten, .sixteen].flatMap { depth in
                [false, true].map { OutputFormat(chroma: chroma, depth: depth, fullRange: $0) }
            }
        }

        /// `x422 (10-bit 4:2:2), video range`, for the one-per-change output line.
        var logDescription: String {
            let code = pixelFormatType
            let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
            let bits = switch depth { case .eight: "8-bit"; case .ten: "10-bit"; case .sixteen: "16-bit" }
            let subsampling = switch chroma { case .yuv420: "4:2:0"; case .yuv422: "4:2:2"; case .yuv444: "4:4:4" }
            return "\(fourCC) (\(bits) \(subsampling)\(dithers ? ", dithered from 12+ bits" : "")), "
                + "\(fullRange ? "full" : "video") range"
        }
    }

    /// #8: what a 12-bit 4:2:0 picture goes out as. No 16-bit 4:2:0 bi-planar format exists, so it is
    /// either cut to 10 bits (ordered dither, the default: 4:2:0 stays 4:2:0, at P010's size and on the
    /// display path every other 10-bit stream takes) or kept at full depth in 4:2:2 `sv22`, which
    /// costs twice the chroma and swscale's vertical chroma upsample, for the measurement of whether
    /// more than 10 bits survive the display path at all. Read at `open`.
    enum TwelveBit420Output: String, CaseIterable, Sendable {
        case p010Dithered = "p010-dither"
        case sv22 = "sv22"
    }

    private static let twelveBit420Switch = OSAllocatedUnfairLock(initialState: TwelveBit420Output.p010Dithered)

    static var twelveBit420Output: TwelveBit420Output {
        get { twelveBit420Switch.withLock { $0 } }
        set { twelveBit420Switch.withLock { $0 = newValue } }
    }

    /// This session's `twelveBit420Output`, read once at `open`.
    private var twelveBit420 = TwelveBit420Output.p010Dithered

    /// `streamIs10Bit` is the open-time verdict (declared depth or an HDR transfer) and only ever widens
    /// the answer. The range is a LABEL: swscale is told the same range on both sides (`SwscaleSetup`),
    /// so a full-range frame is copied across untouched and only has to be tagged as what it is. Asking
    /// swscale to convert would take 4K off its unscaled NV12 / P010 path. A yuvj source is full range
    /// by its pixel format whatever `color_range` says, and stays full range here; it used to be
    /// converted to video range by swscale itself.
    ///
    /// #8: subsampling from the descriptor. Full horizontal chroma is 4:4:4 (RGB and 4:4:0 included),
    /// horizontal and vertical subsampling 4:2:0 (4:1:0 included), horizontal only 4:2:2 (4:1:1
    /// included); grey goes out as 4:2:0 with neutral chroma.
    nonisolated static func outputFormat(pixelFormat: Int32, colorRange: AVColorRange,
                                         streamIs10Bit: Bool,
                                         twelveBit420: TwelveBit420Output = .p010Dithered) -> OutputFormat {
        let format = AVPixelFormat(rawValue: pixelFormat)
        let desc = av_pix_fmt_desc_get(format)?.pointee
        let depth = desc?.comp.0.depth ?? 8
        let isRGB = ((desc?.flags ?? 0) & UInt64(AV_PIX_FMT_FLAG_RGB)) != 0
        // RGB has no range of its own to keep: it is converted, to video range like every other source.
        let fullRange = !isRGB && (colorRange == AVCOL_RANGE_JPEG || isJPEGFormat(format))

        let chroma: OutputFormat.Chroma
        if let desc, desc.nb_components >= 3 {
            chroma = desc.log2_chroma_w == 0 ? .yuv444 : (desc.log2_chroma_h > 0 ? .yuv420 : .yuv422)
        } else {
            chroma = .yuv420
        }
        guard depth > 10 else {
            return OutputFormat(chroma: chroma, depth: streamIs10Bit || depth > 8 ? .ten : .eight,
                                fullRange: fullRange)
        }
        switch (chroma, fullRange) {
        case (.yuv420, false) where twelveBit420 == .sv22:
            return OutputFormat(chroma: .yuv422, depth: .sixteen, fullRange: false)
        case (.yuv420, _), (_, true):
            return OutputFormat(chroma: chroma, depth: .ten, fullRange: fullRange, dithers: true)
        case (_, false):
            return OutputFormat(chroma: chroma, depth: .sixteen, fullRange: false)
        }
    }

    /// #8: order 16-bit MSB-aligned words down to the 10 bits P010 / P210 / P410 keep, in place: an
    /// 8x8 Bayer threshold (0...63, one sixty-fourth of a 10-bit step) added before the low six bits are
    /// cleared, saturating at the top code. Unbiased to half a 16-bit unit, and a smooth 12-bit
    /// gradient comes out as a pattern of adjacent 10-bit codes instead of 4-code-wide bands.
    static func ditherTo10Bit(plane base: UnsafeMutableRawPointer, bytesPerRow: Int, width words: Int, height: Int) {
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt16.self)
            let threshold = bayer8x8Rows[y & 7]
            var x = 0
            while x + 8 <= words {
                let raw = UnsafeMutableRawPointer(row + x)
                let w = raw.loadUnaligned(as: SIMD8<UInt16>.self)
                let sum = w &+ threshold
                var out = sum & 0xFFC0
                out.replace(with: 0xFFC0, where: sum .< w)
                raw.storeBytes(of: out, as: SIMD8<UInt16>.self)
                x += 8
            }
            while x < words {
                let w = UInt32(row[x]) + UInt32(threshold[x & 7])
                row[x] = UInt16(min(w, 0xFFFF)) & 0xFFC0
                x += 1
            }
        }
    }

    /// The 8x8 Bayer matrix (0...63), one SIMD row per line.
    private static let bayer8x8Rows: [SIMD8<UInt16>] = [
        [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21],
    ]

    /// AE#499: what the container declared about colour, captured at `open` before a single frame
    /// exists. A decoded frame carries the VUI alone, and a remux whose VUI is empty would otherwise
    /// reach `attachColorSpace` as an untagged picture, so an HDR10 file decoded in software lost its
    /// PQ / BT.2020 attachments while the same file through the hardware decoder (which reads
    /// `codecpar`) kept them. Written once in `open`, before the host can feed a packet, and read on
    /// the decode thread afterwards, the same discipline `use10Bit` and the other open-time fields keep.
    private var containerColor = ColorDescription.unspecified

    /// HDR10 static metadata the container declared, the fallback for a frame that carries none, and
    /// the value last attached, kept so every frame of a stream gets the same `NSData` object (and the
    /// renderer's format-description key equal bytes). Same open-time discipline as `containerColor`;
    /// `attachedHDRStatic` is guarded by `lock`, like everything `emit` touches.
    private var containerHDRStatic = HDRStaticMetadata.none
    private var attachedHDRStatic = HDRStaticMetadata.none
    /// A declared colour value CoreVideo has no constant for is named once per decoder. Guarded by `lock`.
    private var loggedUnmappedColor = false

    /// Deinterlaced frames dropped for carrying no PTS (see the drop site in decode()). Guarded by `lock`.
    private var droppedUntimestampedFields = 0

    /// #407: frames whose PTS was reconstructed from `best_effort_timestamp` (see the repair site
    /// in drainDecodedFrames()). Guarded by `lock`.
    private var repairedTimestamps = 0

    /// GPU-side copy from the hw-deinterlace filter's pool buffers into `pixelBufferPool` (see
    /// the VT branch in emit()). Created lazily on the first hw frame; guarded by `lock`.
    private var transferSession: VTPixelTransferSession?
    private var loggedTransferFailure = false

    /// #220: a send failure that survives the drain-and-retry is release-visible once per
    /// decoder, so a wedge that is a genuine decode error is distinguishable in a field log
    /// from one that is not.
    private var loggedSendFailure = false

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame
        deinterlacer.config = deinterlaceConfig

        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base

        // Container SAR fallback; see streamSAR. Frames usually carry their own (MPEG-2 seq header, from frame 1).
        //
        // Both fields, because they carry different sources and only one of them is the container's.
        // `codecpar` holds what the bitstream declared (mpegts/mpeg-ps fill it from the parser), while
        // a container-declared ratio reaches AVStream alone: Matroska writes its DisplayWidth quotient
        // to `st->sample_aspect_ratio` (matroskadec.c) and MP4 does the same with `pasp` (mov.c),
        // leaving codecpar at 0:1. Reading codecpar alone left this fallback dead in exactly the case
        // it exists for, an anamorphic source whose ratio lives in the container rather than in the
        // stream, which is every DVD remuxed to MKV in a codec whose bitstream cannot carry SAR.
        streamSAR = Self.declaredStreamSAR(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: stream.pointee.sample_aspect_ratio
        )

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw VideoDecoderError.sessionCreationFailed(status: -1)
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw VideoDecoderError.noCodecParameters
        }

        // Reject VideoToolbox pixel format to force pure software decode (some decoders ignore this).
        ctx.pointee.get_format = { _, fmts in
            guard let fmts = fmts else { return AV_PIX_FMT_NONE }
            var i = 0
            while fmts[i] != AV_PIX_FMT_NONE {
                if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX {
                    return fmts[i]
                }
                i += 1
            }
            return AV_PIX_FMT_YUV420P
        }

        if decodesSingleThreaded {
            // #544: a still run is one short GOP decoded once. Frame-level threading buys throughput
            // nobody is waiting for and costs output delay plus a second worker pool.
            ctx.pointee.thread_count = 1
            ctx.pointee.thread_type = 0
        } else {
            ctx.pointee.thread_count = Int32(ProcessInfo.processInfo.activeProcessorCount)
            ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        }

        // Belt-and-suspenders hwaccel=none: some decoders ignore get_format.
        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)

        guard avcodec_open2(ctx, codec, &opts) >= 0 else {
            av_dict_free(&opts)
            throw VideoDecoderError.sessionCreationFailed(status: -2)
        }
        av_dict_free(&opts)

        containerColor = ColorDescription(codecpar: codecpar)
        containerHDRStatic = HDRStaticMetadata(codecpar: codecpar)
        twelveBit420 = Self.twelveBit420Output
        let bitsPerSample = codecpar.pointee.bits_per_raw_sample
        let isHDRTransfer = ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        use10Bit = bitsPerSample > 8 || isHDRTransfer

        // Release-visible log (no #if DEBUG): needed for TestFlight users and DrHurt #4 black-screen reports.
        EngineLog.emit("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count), \(use10Bit ? "10-bit" : "8-bit")", category: .swPlayback)
    }

    /// #407: the timestamp to put on a decoded frame that carries none, or nil when the frame is
    /// already timed (the common case, and the one that must stay untouched: a decoder-set PTS is
    /// always at least as good as the reconstruction, and `best_effort_timestamp` can trail it).
    ///
    /// `AV_NOPTS_VALUE` is `Int64.min`. `best_effort_timestamp` is libavcodec's own
    /// `guess_correct_pts(pts, pkt_dts)`, so a frame with neither cannot be timed by any means the
    /// decoder has and stays unschedulable; the layer below drops it rather than wedging the queue.
    static func repairedPTS(pts: Int64, bestEffort: Int64) -> Int64? {
        guard pts == Int64.min, bestEffort != Int64.min else { return nil }
        return bestEffort
    }

    /// What to do with a packet after `avcodec_send_packet` returned `ret` (#220).
    enum PacketSendDisposition: Equatable {
        /// The decoder took the packet.
        case accepted
        /// `AVERROR(EAGAIN)`: the packet was NOT consumed. The decoder's output queue is full
        /// and has to be read before it accepts more input, which is legal at any time under
        /// frame threading (a packet that yields no frame, reorder delay, thread_count packets
        /// in flight). Drain, then send the same packet again.
        case drainAndRetry
        /// A real decode error. Drop the packet; the decoder stays usable for the next one.
        case dropped
    }

    nonisolated static func disposition(forSendResult ret: Int32) -> PacketSendDisposition {
        if ret >= 0 { return .accepted }
        return ret == FFmpegErr.eagain ? .drainAndRetry : .dropped
    }

    /// Feed one packet and deliver whatever the decoder produces.
    ///
    /// #220: this used to `return` on any negative send result without draining. EAGAIN is not
    /// an error, and returning on it both dropped the packet and left the output queue full, so
    /// every subsequent send hit the same wall: video wedged permanently until a seek flushed
    /// the decoder, while audio kept playing.
    func decode(packet: UnsafeMutablePointer<AVPacket>, epoch: UInt64? = nil) {
        lock.lock()
        // AE#492: a packet decided on before a flush must not be sent after it. Checked here rather
        // than at the caller because only this lock orders the two: `flush()` takes it to retire the
        // epoch, so either the send happens first and the flush drops what it produced, or the flush
        // happens first and the send never runs.
        if let epoch, epoch != _feedEpoch { lock.unlock(); return }
        guard let ctx = codecContext else { lock.unlock(); return }
        var sendRet = avcodec_send_packet(ctx, packet)
        lock.unlock()

        if Self.disposition(forSendResult: sendRet) == .drainAndRetry {
            drainDecodedFrames()
            lock.lock()
            // Audit DEC-1: the drain drops the lock between frames, so a flush can land in it.
            if let epoch, epoch != _feedEpoch { lock.unlock(); return }
            sendRet = codecContext == nil ? FFmpegErr.einval : avcodec_send_packet(ctx, packet)
            lock.unlock()
        }
        if Self.disposition(forSendResult: sendRet) == .dropped, !loggedSendFailure {
            loggedSendFailure = true
            EngineLog.emit("[SWDecoder] send_packet returned \(sendRet); packet dropped (logged once)",
                           category: .swPlayback)
        }
        // Drain regardless: a dropped packet does not invalidate frames the decoder already holds.
        drainDecodedFrames()
    }

    /// Pull every frame the decoder can currently produce, through the deinterlacer when one is
    /// active. Exits on EAGAIN (needs more input) or EOF, the same condition the receive loop
    /// has always used.
    private func drainDecodedFrames() {
        lock.lock()
        guard let ctx = codecContext else { lock.unlock(); return }
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { lock.unlock(); return }
        lock.unlock()

        var filtered: UnsafeMutablePointer<AVFrame>? = nil

        while true {
            lock.lock()
            guard codecContext != nil else { lock.unlock(); break }
            let ret = avcodec_receive_frame(ctx, f)
            guard ret >= 0 else { lock.unlock(); break }

            // AE#499: fill the fields the VUI left open from the container's declaration BEFORE any
            // consumer reads the frame, for the same reason the timestamp repair below runs here.
            ColorDescription.backfill(frame: f, container: containerColor)
            decodedFormatKey = DecodedFormatKey(pixelFormat: f.pointee.format, color: ColorDescription(frame: f))

            // #407: repair the frame's own timestamp BEFORE anything reads it. A frame that reaches
            // the renderer with no PTS is unschedulable and gets dropped there, so every consumer
            // below (captions, the deinterlace graph, emit) has to see the repaired value, not just
            // the one that happens to be looked at last. `best_effort_timestamp` is libavcodec's
            // guess_correct_pts(pts, pkt_dts), the same reconstruction every other FFmpeg-based
            // player consumes, and it is the only timestamp left when the container carried decode
            // timestamps alone: Matroska V_MS/VFW/FOURCC tracks (VC-1, the legacy MS codecs) put the
            // block time in DTS, and live MPEG-TS delivers untimed pictures outright. The demuxer's
            // `+genpts` normally fills those in a packet earlier; this is the layer that has to hold
            // when it cannot (an open that never got the flag, a frame the reconstruction skipped).
            if let repaired = Self.repairedPTS(
                pts: f.pointee.pts, bestEffort: f.pointee.best_effort_timestamp
            ) {
                f.pointee.pts = repaired
                repairedTimestamps += 1
                if repairedTimestamps == 1 || repairedTimestamps % 250 == 0 {
                    EngineLog.emit(
                        "[SWDecoder] repaired \(repairedTimestamps) frame timestamp(s) from best_effort_timestamp",
                        category: .swPlayback
                    )
                }
            }

            // #131: A53 captions surface as decoded-frame side data on the FFmpeg path (MPEG-2
            // picture user data and friends). Presentation order by construction of decoder output.
            if let onA53 = onA53Captions,
               let sd = av_frame_get_side_data(f, AV_FRAME_DATA_A53_CC),
               let sdData = sd.pointee.data, sd.pointee.size >= 3,
               f.pointee.pts != Int64.min, timeBase.den > 0 {
                let extracted = CCDataParser.parseCCDataTriplets(bytes: sdData, count: Int(sd.pointee.size))
                if !extracted.isEmpty {
                    let pts = Double(f.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
                    onA53(extracted, pts)
                }
            }

            let isInterlaced = (f.pointee.flags & (1 << 3)) != 0  // AV_FRAME_FLAG_INTERLACED
            if isInterlaced || deinterlacer.isActive {
                if deinterlacer.ensureGraph(frame: f, timeBase: timeBase),
                   deinterlacer.push(f) >= 0 {
                    if filtered == nil { filtered = av_frame_alloc() }
                    if let out = filtered {
                        while deinterlacer.pull(into: out) >= 0 {  // filter holds 1-2 frames lookahead; push can yield EAGAIN
                            // Untimestamped output is unschedulable: yadif's SECOND field is
                            // cur.pts + next.pts, which is NOPTS whenever either source frame
                            // lacked a PTS (live TS delivers those); an invalid-PTS sample
                            // can't be paced by the render synchronizer and can wedge the
                            // display queue. Drop it; at field rate the neighbor field covers.
                            if out.pointee.pts == Int64.min {
                                droppedUntimestampedFields += 1
                                if droppedUntimestampedFields == 1 || droppedUntimestampedFields % 250 == 0 {
                                    EngineLog.emit(
                                        "[SWDecoder] dropped \(droppedUntimestampedFields) untimestamped deinterlaced frame(s)",
                                        category: .swPlayback
                                    )
                                }
                                av_frame_unref(out)
                                continue
                            }
                            // Filtered PTS rides the sink's time_base, NOT the stream's: yadif/bwdif
                            // halve the link time_base, and send_field puts the two fields of a frame
                            // on odd/even ticks of that halved base (see DeinterlaceFilter class doc).
                            emit(out, timeBase: deinterlacer.outputTimeBase)
                            av_frame_unref(out)
                        }
                    }
                    lock.unlock()
                    continue
                }
                // No deinterlacer in linked build or graph failure: fall through and render as-is (combing, but playing).
            }
            // emit() must stay under `lock`: close() frees swsContext/pixelBufferPool under the same lock;
            // emitting unlocked raced a stop() into a use-after-free of the sws context.
            emit(f, timeBase: timeBase)
            lock.unlock()
        }

        av_frame_free(&frame)
        if filtered != nil { av_frame_free(&filtered) }
    }

    /// Convert + deliver one decoded (or deinterlaced) frame: skip threshold, pixel buffer
    /// extraction, HDR10+ side data, onFrame. Shared by the direct and deinterlaced paths.
    /// `tb` is the time_base the frame's PTS rides on: the stream time_base for direct frames,
    /// `DeinterlaceFilter.outputTimeBase` for filtered ones (halved by yadif/bwdif; with
    /// send_field the fields sit on odd/even ticks, so rescaling into the stream base would
    /// collapse each pair to duplicate timestamps).
    private func emit(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational) {
        // Per-frame autorelease pool: the decode/feed loops are single long-running dispatch
        // blocks, so without this, ObjC transients (VTPixelTransferSession internals, CV
        // bridging) accumulate in the block's last-resort pool and only pop at session end,
        // AFTER close() tore the session down, crashing the pop with an over-release
        // (EXC_BAD_ACCESS in AutoreleasePoolPage::releaseUntil on engine.sw.feed), and
        // bloating memory for the whole channel visit meanwhile.
        autoreleasepool { emitInner(f, timeBase: tb) }
    }

    private func emitInner(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational) {
        let cmPTS = SourceTimestampBounds.cmTime(ticks: f.pointee.pts, timeBase: tb)
        if let threshold = skipUntilPTS, cmPTS.isValid {
            if CMTimeCompare(cmPTS, threshold) < 0 {
                return
            }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }

        let pixelBuffer: CVPixelBuffer
        if f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
            // Hardware deinterlace path: the frame wraps a CVPixelBuffer from FFmpeg's
            // VideoToolbox hwframes pool (data[3]). Do NOT hand that buffer to the display
            // layer: its IOSurfaces carry different properties than our pool's, and on tvOS
            // the display's direct video plane wedges on the first such frame, while GPU
            // compositing keeps rendering them (visible through translucent overlays). A
            // VTPixelTransferSession copies GPU-side into a buffer from our own pool (the
            // same attributes the sw path has always displayed); still no sws, no CPU copy.
            guard let raw = f.pointee.data.3 else { return }
            let src = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
            if let copied = transferToOwnPool(src) {
                pixelBuffer = copied
            } else {
                // Transfer unavailable: pass the pool buffer through (frozen-plane risk, but
                // better than dropping video entirely).
                if !loggedTransferFailure {
                    loggedTransferFailure = true
                    EngineLog.emit("[SWDecoder] VT pixel transfer failed; passing filter pool buffer through", category: .swPlayback)
                }
                pixelBuffer = src
            }
            attachColorSpace(from: f, to: pixelBuffer)
            attachPixelAspectRatio(from: f, to: pixelBuffer)
        } else {
            guard let converted = convertFrameToPixelBuffer(f) else { return }
            pixelBuffer = converted
        }

        reportDecodedFormat(pixelBuffer: pixelBuffer)

        // HDR10+: read dynamic metadata from post-decode AVFrame side data (T.35 SEI bytes).
        // Can't reuse the VT path's packet-side stash; this decoder owns its own packet flow.
        let hdr10PlusData = extractHDR10PlusBytes(from: f)
        if hdr10PlusData != nil, !seenHDR10Plus {
            seenHDR10Plus = true
            onFirstHDR10PlusDetected?()
        }

        onFrame?(pixelBuffer, cmPTS, hdr10PlusData)
    }

    /// #544: `resetFilterGraph: false` keeps the deinterlace graph across the flush. The still
    /// extractor flushes before every run, and rebuilding the graph means a fresh Metal pipeline, a
    /// fresh full-resolution hwframes pool AND an unconditional `[Deinterlace] engaged` line, about
    /// sixteen times a second while a viewer holds the scrub. That line alone overwrites a host's
    /// whole diagnostic ring in half a minute. A still run decodes a full GOP and returns the frame
    /// at its target, so the filter has context from this position by the time that frame is made.
    func flush() {
        flush(resetFilterGraph: true)
    }

    func flush(resetFilterGraph: Bool) {
        lock.lock()
        defer { lock.unlock() }
        // AE#492: retires every packet a caller had already decided to send. Bumped under the lock,
        // so a feed that has not reached `avcodec_send_packet` yet is refused from here on.
        _feedEpoch &+= 1
        // Deinterlacer temporal references are stale across seeks; drop the graph (lazily rebuilt on next interlaced frame).
        if resetFilterGraph { deinterlacer.teardown() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
    }

    /// Serialise HDR10+ dynamic metadata from AVFrame side data to T.35 SEI bytes (kCMSampleAttachmentKey_HDR10PlusPerFrameData).
    /// Returns nil when the frame carries no AV_FRAME_DATA_DYNAMIC_HDR_PLUS side data.
    private func extractHDR10PlusBytes(
        from frame: UnsafeMutablePointer<AVFrame>
    ) -> Data? {
        let count = Int(frame.pointee.nb_side_data)
        guard count > 0, let sideData = frame.pointee.side_data else {
            return nil
        }
        for i in 0..<count {
            guard let entry = sideData[i] else { continue }
            guard entry.pointee.type == AV_FRAME_DATA_DYNAMIC_HDR_PLUS else { continue }
            guard let raw = entry.pointee.data, entry.pointee.size > 0 else { continue }
            return raw.withMemoryRebound(
                to: AVDynamicHDRPlus.self,
                capacity: 1
            ) { recordPtr -> Data? in
                var dataPtr: UnsafeMutablePointer<UInt8>? = nil
                var size: Int = 0
                let result = av_dynamic_hdr_plus_to_t35(recordPtr, &dataPtr, &size)
                guard result >= 0, let buf = dataPtr, size > 0 else { return nil }
                let data = Data(bytes: buf, count: size)
                av_free(buf)  // use av_free, not plain free(): libavutil allocator contract
                return data
            }
        }
        return nil
    }

    func close() {
        lock.lock()
        deinterlacer.teardown()
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        if swsContext != nil {
            sws_freeContext(swsContext)
            swsContext = nil
        }
        swsKey = nil
        pixelBufferPool = nil
        poolWidth = 0
        poolHeight = 0
        loggedOutputFormat = nil
        if let session = transferSession {
            VTPixelTransferSessionInvalidate(session)
            transferSession = nil
        }
        // Nil onFrame inside the lock: emit() reads it under the same lock; unsynchronized write is a data race.
        onFrame = nil
        lock.unlock()
    }

    deinit {
        close()
    }

    // MARK: - Decoder-owned pixel buffer pool

    /// Create (or reuse) the decoder-owned CVPixelBufferPool for the given geometry. These
    /// attributes (IOSurface + Metal compatible, NV12/P010) are the ones the display path has
    /// always accepted; both the sws path and the hw-deinterlace transfer draw from here.
    private func ensurePixelBufferPool(width: Int, height: Int, format: OutputFormat) -> CVPixelBufferPool? {
        if pixelBufferPool == nil || poolWidth != width || poolHeight != height || poolFormat != format {
            pixelBufferPool = nil
            let poolAttrs: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
            let pbAttrs: NSDictionary = [
                kCVPixelBufferPixelFormatTypeKey: format.pixelFormatType,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pbAttrs, &pixelBufferPool)
            poolWidth = width
            poolHeight = height
            poolFormat = format
        }
        return pixelBufferPool
    }

    /// GPU-side copy of a hw-deinterlace filter frame into a buffer from our own pool.
    /// Returns nil when the session or pool cannot be created or the transfer fails; the
    /// caller then passes the filter's buffer through as a last resort.
    private func transferToOwnPool(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        if transferSession == nil {
            var session: VTPixelTransferSession?
            let status = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
            guard status == noErr, let s = session else { return nil }
            transferSession = s
        }
        // #8: the surface's own format, so the transfer is a copy. It used to ask for 4:2:0 video range
        // at the stream's default depth whatever the deinterlacer uploaded, which squeezed a full-range
        // surface into video range and would have downsampled a 4:2:2 one.
        let format = OutputFormat(pixelFormatType: CVPixelBufferGetPixelFormatType(src))
            ?? OutputFormat(tenBit: use10Bit, fullRange: false)
        logOutputFormat(format, source: "VideoToolbox deinterlacer surface", colorRange: nil)
        guard let session = transferSession,
              let pool = ensurePixelBufferPool(
                  width: CVPixelBufferGetWidth(src),
                  height: CVPixelBufferGetHeight(src),
                  format: format
              ) else { return nil }
        var dst: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst) == kCVReturnSuccess,
              let out = dst else { return nil }
        guard VTPixelTransferSessionTransferImage(session, from: src, to: out) == noErr else { return nil }
        return out
    }

    private func reportDecodedFormat(pixelBuffer: CVPixelBuffer) {
        guard let onDecodedFormat, var key = decodedFormatKey else { return }
        key.pixelBufferType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard key != reportedFormatKey else { return }
        reportedFormatKey = key
        onDecodedFormat(DecodedVideoFormat(
            frame: VideoStreamFormat(
                pixelFormat: AVPixelFormat(rawValue: key.pixelFormat),
                declaredBitDepth: 0,
                color: key.color,
                codecID: codecContext?.pointee.codec_id ?? AV_CODEC_ID_NONE,
                profile: codecContext?.pointee.profile ?? AV_PROFILE_UNKNOWN),
            pixelBufferFormat: DecodedVideoFormat.fourCC(key.pixelBufferType)))
    }

    // MARK: - AVFrame → CVPixelBuffer (sws_scale)

    private func convertFrameToPixelBuffer(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }

        let srcFmt = AVPixelFormat(rawValue: frame.pointee.format)

        let outputFormat = Self.outputFormat(
            pixelFormat: frame.pointee.format, colorRange: frame.pointee.color_range, streamIs10Bit: use10Bit,
            twelveBit420: twelveBit420)
        let dstFmt = outputFormat.swscaleFormat
        logOutputFormat(outputFormat, source: av_get_pix_fmt_name(srcFmt).map { String(cString: $0) } ?? "?",
                        colorRange: frame.pointee.color_range)

        let directShift = Self.directCopyShift(source: srcFmt, destination: dstFmt)
        if directShift == nil {
            let setup = SwscaleSetup(
                width: Int32(width), height: Int32(height), source: srcFmt, destination: dstFmt,
                sourceFullRange: frame.pointee.color_range == AVCOL_RANGE_JPEG || Self.isJPEGFormat(srcFmt),
                destinationFullRange: outputFormat.fullRange,
                colorspace: Self.swscaleColorspace(ColorAttachments.presented(
                    ColorDescription(frame: frame), frameSize: (frame.pointee.width, frame.pointee.height)).matrix))
            if setup != swsKey {
                sws_freeContext(swsContext)
                swsContext = setup.makeContext()
                swsKey = swsContext == nil ? nil : setup
            }
            guard swsContext != nil else { return nil }
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = ensurePixelBufferPool(width: width, height: height, format: outputFormat) else { return nil }
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pb = pixelBuffer else { return nil }

        attachColorSpace(from: frame, to: pb)
        attachPixelAspectRatio(from: frame, to: pb)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if let directShift {
            Self.copyPlanarToBiPlanar(frame, into: pb, shift: directShift)
            if outputFormat.dithers { Self.ditherTo10Bit(pb) }
            return pb
        }

        let yPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            .assumingMemoryBound(to: UInt8.self)
        let cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            .assumingMemoryBound(to: UInt8.self)

        var dstData: (UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?,
                      UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?, UnsafeMutablePointer<UInt8>?)
        dstData.0 = yPlane
        dstData.1 = cbcrPlane
        dstData.2 = nil
        dstData.3 = nil

        var dstLinesize: (Int32, Int32, Int32, Int32, Int32, Int32, Int32, Int32) = (0, 0, 0, 0, 0, 0, 0, 0)
        dstLinesize.0 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        dstLinesize.1 = Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1))

        withUnsafePointer(to: &frame.pointee.data) { srcDataPtr in
            withUnsafePointer(to: &frame.pointee.linesize) { srcLinesizePtr in
                withUnsafeMutablePointer(to: &dstData) { dstPtr in
                    withUnsafeMutablePointer(to: &dstLinesize) { dstLsPtr in
                        let srcSlice = UnsafeRawPointer(srcDataPtr)
                            .assumingMemoryBound(to: UnsafePointer<UInt8>?.self)
                        let srcLs = UnsafeRawPointer(srcLinesizePtr)
                            .assumingMemoryBound(to: Int32.self)
                        let dstSlice = UnsafeMutableRawPointer(dstPtr)
                            .assumingMemoryBound(to: UnsafeMutablePointer<UInt8>?.self)
                        let dstLs = UnsafeMutableRawPointer(dstLsPtr)
                            .assumingMemoryBound(to: Int32.self)

                        sws_scale(
                            swsContext,
                            srcSlice, srcLs,
                            0, Int32(height),
                            dstSlice, dstLs
                        )
                    }
                }
            }
        }

        if outputFormat.dithers { Self.ditherTo10Bit(pb) }

        return pb
    }

    /// Both planes of a locked bi-planar 16-bit buffer, through `ditherTo10Bit(plane:...)`.
    static func ditherTo10Bit(_ pb: CVPixelBuffer) {
        for plane in 0..<2 {
            // Words per row: one per luma pixel, two per sample of the interleaved chroma plane.
            ditherTo10Bit(plane: CVPixelBufferGetBaseAddressOfPlane(pb, plane)!,
                          bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pb, plane),
                          width: CVPixelBufferGetWidthOfPlane(pb, plane) * (plane == 0 ? 1 : 2),
                          height: CVPixelBufferGetHeightOfPlane(pb, plane))
        }
    }

    /// #8: the left shift that turns the source's planar samples into the destination's bi-planar
    /// words, when the conversion is nothing more than that: planar YCbCr into the bi-planar format
    /// with the same subsampling and the same sample size (8-bit into 8-bit, 9...16-bit into 16-bit
    /// words, MSB-aligned). nil otherwise, and for 4:2:0, where swscale has unscaled converters of its
    /// own (NV12 0.17 ms, P010 0.70 ms per 4K frame). For 4:2:2 and 4:4:4 it has none and runs its full
    /// vertical scaler at the identity size: 4.9 ms for NV16, 9.2 ms for P210, 15 ms for P410 per 4K
    /// frame on an M4 Pro, against well under a millisecond for this copy. The range and the matrix
    /// are unchanged by construction (`SwscaleSetup` would copy the levels across all the same).
    static func directCopyShift(source: AVPixelFormat, destination: AVPixelFormat) -> Int? {
        guard let src = av_pix_fmt_desc_get(source)?.pointee,
              let dst = av_pix_fmt_desc_get(destination)?.pointee else { return nil }
        let excluded = UInt64(AV_PIX_FMT_FLAG_RGB) | UInt64(AV_PIX_FMT_FLAG_ALPHA) | UInt64(AV_PIX_FMT_FLAG_FLOAT)
            | UInt64(AV_PIX_FMT_FLAG_BE) | UInt64(AV_PIX_FMT_FLAG_PAL) | UInt64(AV_PIX_FMT_FLAG_BITSTREAM)
        guard src.nb_components == 3, (src.flags & UInt64(AV_PIX_FMT_FLAG_PLANAR)) != 0, (src.flags & excluded) == 0,
              src.log2_chroma_h == 0, src.log2_chroma_w <= 1,
              src.log2_chroma_w == dst.log2_chroma_w, src.log2_chroma_h == dst.log2_chroma_h,
              src.comp.0.plane == 0, src.comp.1.plane == 1, src.comp.2.plane == 2,
              src.comp.0.shift == 0, src.comp.1.shift == 0, src.comp.2.shift == 0,
              dst.comp.0.plane == 0, dst.comp.1.plane == 1, dst.comp.2.plane == 1,
              (dst.flags & UInt64(AV_PIX_FMT_FLAG_BE)) == 0 else { return nil }
        let srcBytes = Int(src.comp.0.step), dstBytes = Int(dst.comp.0.step)
        guard srcBytes == dstBytes, srcBytes == 1 || srcBytes == 2,
              src.comp.1.step == src.comp.0.step, src.comp.2.step == src.comp.0.step else { return nil }
        let shift = Int(dst.comp.0.depth + dst.comp.0.shift) - Int(src.comp.0.depth)
        guard shift >= 0, shift < 8 * srcBytes else { return nil }
        return shift
    }

    /// The copy `directCopyShift` allows: luma shifted row by row, the two chroma planes shifted and
    /// interleaved into the bi-planar chroma plane. Buffer locked by the caller.
    static func copyPlanarToBiPlanar(_ frame: UnsafePointer<AVFrame>, into pb: CVPixelBuffer, shift: Int) {
        let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format))!.pointee
        let wide = desc.comp.0.step == 2
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        let chromaWidth = (width + (1 << Int(desc.log2_chroma_w)) - 1) >> Int(desc.log2_chroma_w)
        let srcY = UnsafeRawPointer(frame.pointee.data.0!), srcU = UnsafeRawPointer(frame.pointee.data.1!)
        let srcV = UnsafeRawPointer(frame.pointee.data.2!)
        let lumaStride = Int(frame.pointee.linesize.0), chromaStride = Int(frame.pointee.linesize.1)
        let chromaStrideV = Int(frame.pointee.linesize.2)
        let dstY = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!, dstC = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
        let dstYStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0), dstCStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for y in 0..<height {
            let sy = srcY + y * lumaStride, dy = dstY + y * dstYStride
            let su = srcU + y * chromaStride, sv = srcV + y * chromaStrideV, dc = dstC + y * dstCStride
            if wide {
                let s = UInt16(shift)
                var x = 0
                while x + 8 <= width {
                    dy.storeBytes(of: sy.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self) &<< s,
                                  toByteOffset: 2 * x, as: SIMD8<UInt16>.self)
                    x += 8
                }
                while x < width {
                    dy.storeBytes(of: sy.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) << s,
                                  toByteOffset: 2 * x, as: UInt16.self)
                    x += 1
                }
                x = 0
                while x + 8 <= chromaWidth {
                    let u = su.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self) &<< s
                    let v = sv.loadUnaligned(fromByteOffset: 2 * x, as: SIMD8<UInt16>.self) &<< s
                    dc.storeBytes(of: SIMD8(u[0], v[0], u[1], v[1], u[2], v[2], u[3], v[3]),
                                  toByteOffset: 4 * x, as: SIMD8<UInt16>.self)
                    dc.storeBytes(of: SIMD8(u[4], v[4], u[5], v[5], u[6], v[6], u[7], v[7]),
                                  toByteOffset: 4 * x + 16, as: SIMD8<UInt16>.self)
                    x += 8
                }
                while x < chromaWidth {
                    dc.storeBytes(of: sv.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) << s,
                                  toByteOffset: 4 * x + 2, as: UInt16.self)
                    dc.storeBytes(of: su.loadUnaligned(fromByteOffset: 2 * x, as: UInt16.self) << s,
                                  toByteOffset: 4 * x, as: UInt16.self)
                    x += 1
                }
            } else {
                dy.copyMemory(from: sy, byteCount: width)
                var x = 0
                while x + 16 <= chromaWidth {
                    let u = su.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                    let v = sv.loadUnaligned(fromByteOffset: x, as: SIMD16<UInt8>.self)
                    dc.storeBytes(of: SIMD16(u[0], v[0], u[1], v[1], u[2], v[2], u[3], v[3],
                                             u[4], v[4], u[5], v[5], u[6], v[6], u[7], v[7]),
                                  toByteOffset: 2 * x, as: SIMD16<UInt8>.self)
                    dc.storeBytes(of: SIMD16(u[8], v[8], u[9], v[9], u[10], v[10], u[11], v[11],
                                             u[12], v[12], u[13], v[13], u[14], v[14], u[15], v[15]),
                                  toByteOffset: 2 * x + 16, as: SIMD16<UInt8>.self)
                    x += 16
                }
                while x < chromaWidth {
                    dc.storeBytes(of: su.load(fromByteOffset: x, as: UInt8.self), toByteOffset: 2 * x, as: UInt8.self)
                    dc.storeBytes(of: sv.load(fromByteOffset: x, as: UInt8.self), toByteOffset: 2 * x + 1, as: UInt8.self)
                    x += 1
                }
            }
        }
    }

    /// Everything a conversion context is built from (`sws_getCachedContext` exposes neither range nor
    /// matrix, so the decoder keeps its own key).
    ///
    /// - Ranges: equal on both sides wherever the picture stays YCbCr, so swscale copies the levels
    ///   across and keeps its unscaled converters (NV12 / P010 at 4K). A yuvj source is full range on
    ///   both sides too: it used to be squeezed to video range, which also pushed it off the unscaled
    ///   path. Only RGB has a real range conversion, to whatever the buffer is tagged.
    /// - Matrix: one table for both sides, the one the buffer is tagged with. YCbCr to YCbCr is then a
    ///   copy (different tables would make swscale cascade through RGB), and RGB is converted with the
    ///   coefficients the display layer will decode it with: it used to get swscale's default BT.601
    ///   on a buffer tagged BT.709.
    /// - Flags: `SWS_ACCURATE_RND` for exact rounding where the vertical scaler runs, and, only when
    ///   chroma is resampled (4:2:0 into `sv22`, 4:1:1, 4:4:0, RGB), bicubic with full-resolution chroma
    ///   in and out instead of bilinear. Luma is never scaled: the destination is the source size, so
    ///   the filter choice only reaches chroma. swscale's own `sws_dither` is left alone: it applies to
    ///   RGB and 8-bit outputs, neither of which this decoder writes from a deeper source (the one
    ///   depth reduction left, 12+ to 10 bits, is `ditherTo10Bit`).
    struct SwscaleSetup: Equatable {
        var width: Int32
        var height: Int32
        var source: AVPixelFormat
        var destination: AVPixelFormat
        var sourceFullRange: Bool
        var destinationFullRange: Bool
        var colorspace: Int32

        var resamplesChroma: Bool {
            guard let src = av_pix_fmt_desc_get(source)?.pointee,
                  let dst = av_pix_fmt_desc_get(destination)?.pointee else { return true }
            return (src.flags & UInt64(AV_PIX_FMT_FLAG_RGB)) != 0 || src.nb_components < 3
                || src.log2_chroma_w != dst.log2_chroma_w || src.log2_chroma_h != dst.log2_chroma_h
        }

        var flags: Int32 {
            // FFmpeg 8 turned the SWS_* constants into a typed `SwsFlags` enum; the option wants an int.
            resamplesChroma
                ? Int32(SWS_BICUBIC.rawValue | SWS_ACCURATE_RND.rawValue | SWS_FULL_CHR_H_INT.rawValue
                        | SWS_FULL_CHR_H_INP.rawValue)
                : Int32(SWS_BILINEAR.rawValue | SWS_ACCURATE_RND.rawValue)
        }

        func makeContext() -> UnsafeMutablePointer<SwsContext>? {
            guard let ctx = sws_alloc_context() else { return nil }
            var owned: UnsafeMutablePointer<SwsContext>? = ctx
            let raw = UnsafeMutableRawPointer(ctx)
            av_opt_set_int(raw, "srcw", Int64(width), 0)
            av_opt_set_int(raw, "srch", Int64(height), 0)
            av_opt_set_int(raw, "dstw", Int64(width), 0)
            av_opt_set_int(raw, "dsth", Int64(height), 0)
            av_opt_set_int(raw, "src_format", Int64(source.rawValue), 0)
            av_opt_set_int(raw, "dst_format", Int64(destination.rawValue), 0)
            av_opt_set_int(raw, "src_range", sourceFullRange ? 1 : 0, 0)
            av_opt_set_int(raw, "dst_range", destinationFullRange ? 1 : 0, 0)
            av_opt_set_int(raw, "sws_flags", Int64(flags), 0)
            guard sws_init_context(ctx, nil, nil) >= 0 else {
                sws_freeContext(owned)
                return nil
            }
            let table = sws_getCoefficients(colorspace)
            guard sws_setColorspaceDetails(ctx, table, sourceFullRange ? 1 : 0, table, destinationFullRange ? 1 : 0,
                                           0, 1 << 16, 1 << 16) >= 0 else {
                sws_freeContext(owned)
                owned = nil
                return nil
            }
            return owned
        }
    }

    nonisolated static func isJPEGFormat(_ format: AVPixelFormat) -> Bool {
        switch format {
        case AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P:
            true
        default:
            false
        }
    }

    /// The swscale coefficient table for the matrix the buffer is tagged with.
    nonisolated static func swscaleColorspace(_ matrix: CFString) -> Int32 {
        switch matrix {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: SWS_CS_ITU601
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: SWS_CS_BT2020
        case kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: SWS_CS_SMPTE240M
        default: SWS_CS_ITU709
        }
    }

    /// One release-visible line whenever the buffer format changes, naming what it was chosen from.
    private func logOutputFormat(_ format: OutputFormat, source: String, colorRange: AVColorRange?) {
        guard format != loggedOutputFormat else { return }
        loggedOutputFormat = format
        EngineLog.emit(
            "[SWDecoder] output \(format.logDescription) (frame \(source)"
            + (colorRange.map { ", color_range=\($0.rawValue))" } ?? ")"),
            category: .swPlayback
        )
    }

    // MARK: - Color Space Metadata

    /// Map FFmpeg color metadata to CVPixelBuffer attachments for correct HDR10 rendering (BT.2020 + PQ).
    /// Every field is written, a gap included (AE#654): VideoToolbox never hands the display layer an
    /// untagged buffer, and neither may this decoder.
    private func attachColorSpace(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let description = ColorDescription(frame: frame)
        let tags = ColorAttachments.presented(description, frameSize: (frame.pointee.width, frame.pointee.height))
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, tags.primaries, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, tags.transfer, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, tags.matrix, .shouldPropagate)
        if let gamma = tags.gammaLevel {
            CVBufferSetAttachment(pb, kCVImageBufferGammaLevelKey, gamma as NSNumber, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(pb, kCVImageBufferGammaLevelKey)
        }
        if !loggedUnmappedColor, let gaps = ColorAttachments.unmapped(description) {
            loggedUnmappedColor = true
            EngineLog.emit("[SWDecoder] no CoreVideo tag for \(gaps); presented as primaries=\(tags.primaries) "
                           + "matrix=\(tags.matrix) (logged once)", category: .swPlayback)
        }
        attachHDRStaticMetadata(from: frame, to: pb)
        attachChromaLocation(from: frame, to: pb)
    }

    /// Where the subsampled chroma samples sit, which the display layer's upsampler needs to put the
    /// colour back on the right pixels; nothing told it before. Same value for both fields: what
    /// leaves this decoder is progressive.
    private func attachChromaLocation(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let chroma = OutputFormat(pixelFormatType: CVPixelBufferGetPixelFormatType(pb))?.chroma ?? .yuv420
        guard let location = Self.chromaLocation(
            frame.pointee.chroma_location, output: chroma,
            isJPEG: Self.isJPEGFormat(AVPixelFormat(rawValue: frame.pointee.format))) else {
            CVBufferRemoveAttachment(pb, kCVImageBufferChromaLocationTopFieldKey)
            CVBufferRemoveAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey)
            return
        }
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, location, .shouldPropagate)
    }

    /// The CoreVideo chroma location for the frame's `chroma_location` on a buffer with `output`
    /// subsampling. nil for 4:4:4, which has nothing to site.
    ///
    /// Unspecified is filled the way mpv fills it: left (co-sited horizontally, between the lines
    /// vertically), the MPEG-2 / H.264 / HEVC / AV1 convention and so what an unlabelled stream on this
    /// route almost always is, except a JPEG-family picture, which is centred. Left rather than no
    /// attachment, because a buffer without one leaves the choice to whatever the display layer
    /// assumes, and nothing documents that. On a 4:2:2 buffer only the horizontal half of the siting
    /// exists, so the vertical variants fold onto Left / Center (a 4:2:0 picture swscale widened into
    /// `sv22` keeps its horizontal siting).
    nonisolated static func chromaLocation(_ location: AVChromaLocation, output: OutputFormat.Chroma,
                                           isJPEG: Bool) -> CFString? {
        let resolved = location == AVCHROMA_LOC_UNSPECIFIED
            ? (isJPEG ? AVCHROMA_LOC_CENTER : AVCHROMA_LOC_LEFT) : location
        switch output {
        case .yuv444:
            return nil
        case .yuv422:
            switch resolved {
            case AVCHROMA_LOC_CENTER, AVCHROMA_LOC_TOP, AVCHROMA_LOC_BOTTOM:
                return kCVImageBufferChromaLocation_Center
            default:
                return kCVImageBufferChromaLocation_Left
            }
        case .yuv420:
            switch resolved {
            case AVCHROMA_LOC_CENTER: return kCVImageBufferChromaLocation_Center
            case AVCHROMA_LOC_TOPLEFT: return kCVImageBufferChromaLocation_TopLeft
            case AVCHROMA_LOC_TOP: return kCVImageBufferChromaLocation_Top
            case AVCHROMA_LOC_BOTTOMLEFT: return kCVImageBufferChromaLocation_BottomLeft
            case AVCHROMA_LOC_BOTTOM: return kCVImageBufferChromaLocation_Bottom
            default: return kCVImageBufferChromaLocation_Left
            }
        }
    }

    /// The mastering display and content light level travel with the colour tags: the frame's own
    /// (bitstream SEI / AV1 metadata OBU) first, the container's declaration for what it lacks. A
    /// comparison per frame; the attached objects only change when the stream's metadata does.
    private func attachHDRStaticMetadata(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let current = HDRStaticMetadata(frame: frame).filled(from: containerHDRStatic)
        if current != attachedHDRStatic { attachedHDRStatic = current }
        attachedHDRStatic.attach(to: pb)
    }

    // MARK: - Pixel Aspect Ratio (anamorphic SD)

    /// The stream's declared SAR. Neither field alone is the whole answer: codecpar carries what the
    /// bitstream said (the mpegts / mpeg-ps parsers fill it), while a container-declared ratio
    /// reaches AVStream alone (Matroska's DisplayWidth quotient, MP4's `pasp`).
    ///
    /// A container that declares a real correction wins, because it is the later authoring layer:
    /// `mkvmerge --aspect-ratio` writes DisplayWidth and leaves the bitstream alone, so the two
    /// disagree by design and the newer one is the intent. This is also what every ffmpeg-based
    /// player resolves to (`av_guess_sample_aspect_ratio` returns the stream ratio wherever it is
    /// set), and what an MP4 `pasp` means to AVFoundation. A SQUARE declaration is not a
    /// correction and therefore not a claim to prefer, on either side: reading `1:1` out of the
    /// bitstream as "declared" is what hid a container-declared ratio entirely.
    ///
    /// Sanity is not judged here; the caller runs both gates against the frame.
    static func declaredStreamSAR(bitstream: AVRational, container: AVRational) -> AVRational {
        if container.num > 0, container.den > 0, container.num != container.den { return container }
        if bitstream.num > 0, bitstream.den > 0 { return bitstream }
        return container
    }

    /// #177 resolution order: frame -> codec context -> stream, first sane wins. The frame usually
    /// carries its own (MPEG-2 seq header from frame 1); the codec context covers codecs that only
    /// populate it there; the container-declared stream SAR is the last resort.
    ///
    /// #290: sanity is judged against the coded dimensions, so a SAR whose numbers are plausible
    /// but whose display aspect is not (a live 1080p channel declaring 3:1) drops through to the
    /// next source, and to square pixels when no source survives. See `PixelAspectPolicy`.
    ///
    /// A square candidate does not end the search either. It corrects nothing, so treating it as an
    /// answer only means the axes behind it are never read: an anamorphic MKV whose H.264 VUI says
    /// square (the shape `mkvmerge --aspect-ratio` leaves behind) was drawn at its coded size while
    /// the ratio sat in the container, one axis further down. nil and 1:1 attach the same nothing.
    static func resolveSAR(
        frame: AVRational, codecCtx: AVRational, stream: AVRational, width: Int32, height: Int32
    ) -> AVRational? {
        for candidate in [frame, codecCtx, stream] {
            if let sane = PixelAspectPolicy.saneSAR(candidate, width: width, height: height),
               sane.num != sane.den {
                return sane
            }
        }
        return nil
    }

    /// #177 per-stream latch: the first sane non-square SAR wins for the rest of the stream, so
    /// per-field oscillation on interlaced content cannot flicker the display geometry. Square or
    /// unknown SAR before any latch attaches nothing (coded dimensions are correct then).
    static func sarForAttachment(
        resolved: AVRational?, latched: AVRational?
    ) -> (attach: AVRational?, latch: AVRational?) {
        if let latched { return (latched, latched) }
        guard let resolved, resolved.num != resolved.den else { return (nil, nil) }
        return (resolved, resolved)
    }

    /// Attach SAR as kCVImageBufferPixelAspectRatioKey for anamorphic content. The renderer keys
    /// its CMVideoFormatDescription cache on this attachment (#177), so it must be stable per stream.
    private func attachPixelAspectRatio(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let ctxSAR = codecContext?.pointee.sample_aspect_ratio ?? AVRational(num: 0, den: 1)
        let width = frame.pointee.width
        let height = frame.pointee.height
        let resolved = Self.resolveSAR(
            frame: frame.pointee.sample_aspect_ratio,
            codecCtx: ctxSAR,
            stream: streamSAR,
            width: width,
            height: height
        )
        if resolved == nil, !loggedSARReject, latchedSAR == nil {
            logRejectedSAR(frame: frame.pointee.sample_aspect_ratio, ctx: ctxSAR, width: width, height: height)
        }
        let (attach, latch) = Self.sarForAttachment(resolved: resolved, latched: latchedSAR)
        latchedSAR = latch
        guard let sar = attach else {
            // Recycled pool buffers can carry a stale attachment from an earlier frame.
            CVBufferRemoveAttachment(pb, kCVImageBufferPixelAspectRatioKey)
            return
        }
        if !loggedSARLatch {
            loggedSARLatch = true
            let frameSAR = frame.pointee.sample_aspect_ratio
            EngineLog.emit(
                "[SWDecoder] SAR latched \(sar.num):\(sar.den) "
                + "(frame=\(frameSAR.num):\(frameSAR.den) ctx=\(ctxSAR.num):\(ctxSAR.den) "
                + "stream=\(streamSAR.num):\(streamSAR.den))",
                category: .swPlayback
            )
        }

        let aspect: NSDictionary = [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: Int(sar.num),
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: Int(sar.den),
        ]
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, aspect, .shouldPropagate)
    }

    /// #290: name the dropped ratio and the aspect it would have produced, once per stream. Only a
    /// SAR that cleared the component gate and failed on the display aspect reaches this; an unset
    /// or square SAR is the ordinary case and stays silent.
    private func logRejectedSAR(frame: AVRational, ctx: AVRational, width: Int32, height: Int32) {
        guard let message = Self.rejectedSARMessage(
            frame: frame, ctx: ctx, stream: streamSAR, width: width, height: height
        ) else { return }
        loggedSARReject = true
        EngineLog.emit(message, category: .swPlayback)
    }

    /// The rejection line, including the three axes the ratio could have arrived on.
    ///
    /// #290 (axes): a rejected SAR never latches, so the latch line that names frame / ctx / stream
    /// cannot fire for it, and this line was the only one a bad ratio produced. That made the axis
    /// unreadable in exactly the case where it is asked for. The axes separate the two hypotheses a
    /// smeared live channel leaves open: on MPEG-TS, where no container ratio exists, `stream=` is
    /// the parser's reading of the SPS VUI at open time and `frame=` is the SPS in force for this
    /// frame, so agreement means the VUI genuinely declares the ratio and disagreement is the
    /// fingerprint of a declaration that changed between the join and the frame.
    ///
    /// Nil unless some axis actually lost on the display aspect: an unset or square SAR everywhere
    /// is the ordinary case and has nothing to report.
    static func rejectedSARMessage(
        frame: AVRational, ctx: AVRational, stream: AVRational, width: Int32, height: Int32
    ) -> String? {
        let candidates = [frame, ctx, stream]
        let rejectedByAspect = { (sar: AVRational) in
            PixelAspectPolicy.saneSAR(sar) != nil
                && PixelAspectPolicy.saneSAR(sar, width: width, height: height) == nil
        }
        guard let rejected = candidates.first(where: rejectedByAspect) else { return nil }
        let aspect = PixelAspectPolicy.displayAspect(sar: rejected, width: width, height: height)
        return "[SWDecoder] SAR \(rejected.num):\(rejected.den) rejected on \(width)x\(height): "
            + String(format: "display aspect %.2f outside %.2f...%.2f",
                     aspect, PixelAspectPolicy.minDisplayAspect, PixelAspectPolicy.maxDisplayAspect)
            + ", using square pixels "
            + "(frame=\(frame.num):\(frame.den) ctx=\(ctx.num):\(ctx.den) "
            + "stream=\(stream.num):\(stream.den))"
    }
}

extension AetherEngine {
    /// #8: what the software decoder hands the display layer for a 12-bit 4:2:0 picture, for which no
    /// 16-bit 4:2:0 bi-planar format exists. See `SoftwareVideoDecoder.TwelveBit420Output`.
    @_spi(Diagnostics)
    public enum SoftwareTwelveBit420Output: String, CaseIterable, Sendable {
        /// 10-bit `x420`, ordered-dithered from the 12-bit picture. The default.
        case p010Dithered = "p010-dither"
        /// 16-bit 4:2:2 `sv22`: all 12 bits of luma kept, chroma upsampled vertically by swscale.
        case sv22 = "sv22"
    }

    /// Takes effect from the next software decoder opened and applies to every session in the process.
    @_spi(Diagnostics)
    public nonisolated static var softwareTwelveBit420Output: SoftwareTwelveBit420Output {
        get { SoftwareTwelveBit420Output(rawValue: SoftwareVideoDecoder.twelveBit420Output.rawValue) ?? .p010Dithered }
        set { SoftwareVideoDecoder.twelveBit420Output = .init(rawValue: newValue.rawValue) ?? .p010Dithered }
    }
}
