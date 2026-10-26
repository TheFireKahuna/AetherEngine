import Foundation
import os
import Synchronization
import CoreMedia
import CoreVideo
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import Metal
import LibDeinterlace

/// libavcodec software video decoder for codecs without VideoToolbox support (e.g. AV1/dav1d on Apple TV).
/// The decoder writes its pictures into GPU-visible memory (`DecodeFrameAllocator`) and one GPU pass
/// (`PlanarFrameFinisher`) turns each into the display buffer; the CPU never touches the pixels after decode.
final class SoftwareVideoDecoder: VideoDecodingPipeline, @unchecked Sendable {

    // Threading. The stream's state (the codec context, the writer and finisher, the deinterlacer's window, inverse
    // telecine, the film cadence, every counter below) belongs to the decode thread: `decode(packet:epoch:)` and
    // `drainForEndOfStream()`, which run under `gate`. Nothing else takes `gate` but `close()`, once, to wait out the call
    // in progress before it tears the state down; the frame path takes no lock any other thread contends for. A host's
    // `flush()`, the discard switch and the skip threshold are control state the decode thread reads at its next call:
    // atomics (the epoch, the reset and discard requests) it reads without a lock, and the skip threshold, a multi-word
    // CMTime, under `skipThreshold`. A finished frame reaches the host through `delivery`, in decode order, from the
    // GPU's completion: the decode thread never waits on the GPU.

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?
    /// Where the decoder writes its pictures and the GPU pass that turns them into display buffers. Made at `open`.
    private var writer: DisplayBufferWriter?
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)
    /// The host's callback, called on `delivery`'s queue with no lock of this decoder's held.
    var onFrame: DecodedFrameHandler? {
        get { delivery.currentOnFrame }
        set { delivery.setOnFrame(newValue) }
    }
    /// Finished frames to the host, by ticket, a flush's earlier frames dropped by epoch. Up to two frames (a frame's
    /// two fields) per finisher submission in flight.
    private let delivery = OrderedDelivery(maxFramesInFlight: 2 * PlanarFrameFinisher.slotCount, maxLayerSkew: 0,
                                           label: "engine.sw.delivery")
    /// The next frame's ticket and the epoch the numbering is for: every epoch numbers its frames from 0, as
    /// `flush()` resets the delivery line to 0.
    private var nextTicket: UInt64 = 0
    private var ticketEpoch: UInt64 = 0

    /// Fires once (demux thread) on first HDR10+ side data; engine flips videoFormat to .hdr10Plus.
    private var seenHDR10Plus = false
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    var onA53Captions: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    /// AE#658: fires (decode thread) on the first displayed frame and whenever the decoded format or the
    /// display buffer's format changes.
    var onDecodedFormat: (@Sendable (DecodedVideoFormat) -> Void)?
    private var decodedFormatKey: DecodedFormatKey?
    private var reportedFormatKey: DecodedFormatKey?

    /// The decoder's own output, taken when the frame is decoded (a deinterlaced picture is written from its
    /// planar equivalent, whose pixel format says nothing about the decode).
    struct DecodedFormatKey: Equatable {
        var pixelFormat: Int32
        var color: ColorDescription
        var pixelBufferType: OSType = 0
    }

    /// Container-declared SAR fallback for anamorphic DVD/SD content (NTSC 720x480, PAL 720x576, widescreen DVDs).
    /// Native VideoToolbox gets this from the container automatically; the software path must attach it explicitly.
    private var streamSAR = AVRational(num: 1, den: 1)

    /// #177: first sane non-square SAR of the stream. Once latched, every frame attaches this value;
    /// interlaced sources can oscillate SAR per-field and a garbage AVCodecContext value (1088:1 seen
    /// in the field) must never flicker the display geometry.
    private var latchedSAR: AVRational?
    private var loggedSARLatch = false
    /// #290: one line per stream when a declared SAR is dropped for the aspect it produces, so a
    /// smeared picture names its own cause instead of looking like a renderer bug.
    private var loggedSARReject = false

    /// Skip pre-seek frames; decoded for reference but not converted. Set by the host, read by the decode thread and the
    /// completions.
    var skipUntilPTS: CMTime? {
        get { skipThreshold.withLock { $0 } }
        set { skipThreshold.withLock { $0 = newValue } }
    }
    private let skipThreshold = Mutex<CMTime?>(nil)

    /// Set per packet by a caller that knows the packet's picture would be too late to show (it sets
    /// `skipUntilPTS` to the first picture that is not): a picture no other picture references is then
    /// dropped before it is decoded, so a decoder behind its clock catches up at the cost of the references
    /// alone. A stream whose captions come out of its decoded pictures keeps every picture, since a dropped
    /// one would take its caption bytes with it; it still catches up on what it does not convert.
    ///
    /// A chain that counts consecutive pictures (the deinterlacer's window, inverse telecine, a soft-telecine
    /// film run) is not handed the late pictures at all: it starts over on the first picture that is not
    /// late, as it does after a seek, so the pictures it shows keep their timestamps and cadence.
    func discardsNonReferencePictures(_ discard: Bool) {
        discardRequest.store(discard ? Self.discardOn : Self.discardOff, ordering: .releasing)
    }

    /// Late pictures are bypassing the consecutive-picture chain, which starts over on the first one that is
    /// not late (`discardsNonReferencePictures`).
    private var chainRestartPending = false
    /// The stream's decoded pictures have carried A53 captions.
    private var carriesDecodedCaptions = false

    // What the host's calls leave for the decode thread. The feed epoch (AE#492) is read lock-free between frames; a
    // flush's reset request and the discard switch are taken by the decode thread at its next call. `flush()` and
    // `close()` serialise with each other under `hostCalls`, which no frame path takes.
    private let epoch = Atomic<UInt64>(0)
    private let closed = Atomic<Bool>(false)
    /// Bit 0: a reset is pending; bit 1: it resets the consecutive-picture chains too.
    private let resetRequest = Atomic<UInt8>(0)
    private static let resetPending: UInt8 = 1, resetFilterGraph: UInt8 = 2
    /// The discard switch's latest value not yet applied: 0 none, else off or on.
    private let discardRequest = Atomic<UInt8>(0)
    private static let discardOff: UInt8 = 1, discardOn: UInt8 = 2
    private let hostCalls = Mutex<Void>(())
    var feedEpoch: UInt64 { epoch.load(ordering: .acquiring) }
    /// Whether `epoch` is still the feed's, for the decode thread between frames.
    private func isCurrent(_ e: UInt64) -> Bool { !closed.load(ordering: .acquiring) && epoch.load(ordering: .acquiring) == e }

    /// Clear the skip threshold only if it is still the one we acted on.
    private func clearSkip(ifStillAt threshold: CMTime) {
        skipThreshold.withLock { current in
            if let set = current, CMTimeCompare(set, threshold) == 0 { current = nil }
        }
    }

    /// Held by the decode thread for each call; `close()` takes it once (see Threading, above).
    private let gate = NSLock()

    /// The deinterlacer's schedule for interlaced MPEG-2 / VC-1 / MPEG-4 / H.264 (DVD rips, broadcast): FFmpeg's bwdif,
    /// the arithmetic on the GPU (``PlanarFrameFinisher/Field``). Made at `open`; engaged by the first interlaced
    /// frame, after which every frame goes through it.
    private var window: BwdifWindow?
    /// The source format's reader for the deinterlacer and the planar format it writes, per decoded format; nil
    /// where the deinterlacer does not take the format (logged once).
    private var deinterlaceFormats: [Int32: (layout: PictureLayout, planar: AVPixelFormat)?] = [:]

    /// Deinterlacer cadence from LoadOptions. Set by the host BEFORE `open`.
    var deinterlaceConfig = DeinterlaceConfig()

    /// Soft telecine: film runs re-timed onto the film rate's own grid (``FilmCadence``). Made at `open`.
    private var filmCadence: FilmCadence?

    /// Film in interlaced carriage (`deinterlaceConfig.film`): every picture through ``InverseTelecine`` instead of the
    /// deinterlacer. Made on the first picture, when its format and size are ones inverse telecine takes.
    private var inverseTelecine: InverseTelecine?
    private var loggedTelecineRefusal = false

    /// False puts every picture out as decoded, interlaced or not. Set before `open`; the format probe is
    /// the only caller, it counts the decoder's own pictures.
    var deinterlaces = true

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
    struct OutputFormat: Hashable {
        enum Chroma: Hashable { case yuv420, yuv422, yuv444 }
        enum Depth: Hashable { case eight, ten, sixteen }

        var chroma: Chroma
        var depth: Depth
        var fullRange: Bool
        /// The frame has more bits than `depth` keeps: the finisher forms each value with six fraction bits
        /// and orders it down to the 10 bits the format keeps.
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

        /// A display buffer's format read back: nil for a format no `OutputFormat` describes.
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
    /// costs twice the chroma and a vertical chroma upsample, for the measurement of whether more than
    /// 10 bits survive the display path at all. Read at `open`. An interlaced picture stays 4:2:0: its
    /// chroma rows alternate between the fields, so a vertical upsample would blend them.
    enum TwelveBit420Output: String, CaseIterable, Sendable {
        case p010Dithered = "p010-dither"
        case sv22 = "sv22"
    }

    private static let twelveBit420Switch = OSAllocatedUnfairLock(initialState: TwelveBit420Output.p010Dithered)

    static var twelveBit420Output: TwelveBit420Output {
        get { twelveBit420Switch.withLock { $0 } }
        set { twelveBit420Switch.withLock { $0 = newValue } }
    }

    /// `streamIs10Bit` is the open-time verdict (declared depth or an HDR transfer) and only ever widens
    /// the answer. The range is kept: a full-range frame goes out full range, its codes taken to the output
    /// depth as H.273 scales full range. A yuvj source is full range by its pixel format whatever
    /// `color_range` says.
    ///
    /// #8: subsampling from the descriptor. Full horizontal chroma is 4:4:4 (RGB, palette and 4:4:0
    /// included), horizontal and vertical subsampling 4:2:0 (4:1:0 included), horizontal only 4:2:2 (4:1:1
    /// included); grey goes out as 4:2:0 with neutral chroma.
    nonisolated static func outputFormat(pixelFormat: Int32, colorRange: AVColorRange,
                                         streamIs10Bit: Bool,
                                         twelveBit420: TwelveBit420Output = .p010Dithered,
                                         interlaced: Bool = false,
                                         representation: ColourRepresentation = .tagged) -> OutputFormat {
        let format = AVPixelFormat(rawValue: pixelFormat)
        let desc = av_pix_fmt_desc_get(format)?.pointee
        let depth = desc?.comp.0.depth ?? 8
        let isRGB = ((desc?.flags ?? 0) & UInt64(AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL)) != 0
            || representation == .identity
        // RGB has no Y'CbCr range of its own to keep: it is encoded at video range like every other source.
        let fullRange = !isRGB && (colorRange == AVCOL_RANGE_JPEG || isJPEGFormat(format))

        // A picture whose matrix is re-encoded goes out 4:4:4: the conversion is per pixel, after chroma is resampled
        // to every luma site, and nothing is subsampled again.
        let chroma: OutputFormat.Chroma
        if isRGB || representation.converts {
            chroma = .yuv444
        } else if let desc, desc.nb_components >= 3 {
            chroma = desc.log2_chroma_w == 0 ? .yuv444 : (desc.log2_chroma_h > 0 ? .yuv420 : .yuv422)
        } else {
            chroma = .yuv420
        }
        guard depth > 10 else {
            return OutputFormat(chroma: chroma, depth: streamIs10Bit || depth > 8 ? .ten : .eight,
                                fullRange: fullRange)
        }
        switch (chroma, fullRange) {
        case (.yuv420, false) where twelveBit420 == .sv22 && !interlaced:
            return OutputFormat(chroma: .yuv422, depth: .sixteen, fullRange: false)
        case (.yuv420, _), (_, true):
            return OutputFormat(chroma: chroma, depth: .ten, fullRange: fullRange, dithers: true)
        case (_, false):
            return OutputFormat(chroma: chroma, depth: .sixteen, fullRange: false)
        }
    }

    /// AE#499: what the container declared about colour, captured at `open` before a single frame
    /// exists. A decoded frame carries the VUI alone, and a remux whose VUI is empty would otherwise
    /// reach the display buffer as an untagged picture, so an HDR10 file decoded in software lost its
    /// PQ / BT.2020 attachments while the same file through the hardware decoder (which reads
    /// `codecpar`) kept them. Made in `open`, before the host can feed a packet; applied to each frame
    /// on the decode thread, where it learns which fields the bitstream states itself.
    private var colourFill = ColourBackfill(container: .unspecified)

    /// Deinterlaced or telecine-recovered pictures dropped for carrying no PTS: counted on the decode thread and, for
    /// inverse telecine, whose timestamps are known only when its pass has completed, on the completion queue.
    private let droppedUntimestamped = Atomic<Int>(0)

    private func noteUntimestamped() {
        let count = droppedUntimestamped.wrappingAdd(1, ordering: .relaxed).newValue
        if count == 1 || count % 250 == 0 {
            EngineLog.emit("[SWDecoder] dropped \(count) untimestamped deinterlaced picture(s)", category: .swPlayback)
        }
    }

    /// #407: frames whose PTS was reconstructed from `best_effort_timestamp` (see the repair site
    /// in drainDecodedFrames()).
    private var repairedTimestamps = 0

    /// #220: a send failure that survives the drain-and-retry is release-visible once per
    /// decoder, so a wedge that is a genuine decode error is distinguishable in a field log
    /// from one that is not.
    private var loggedSendFailure = false

    func open(stream: UnsafeMutablePointer<AVStream>, onFrame: @escaping DecodedFrameHandler) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw VideoDecoderError.noCodecParameters
        }
        try open(parameters: codecpar, timeBase: stream.pointee.time_base,
                 containerSAR: stream.pointee.sample_aspect_ratio, onFrame: onFrame)
    }

    /// `open(stream:)` from the stream's parts, for a caller that keeps them past the demuxer's life: the codec
    /// parameters, the time base packets are stamped in, and the container's sample aspect ratio.
    func open(parameters codecpar: UnsafePointer<AVCodecParameters>, timeBase: AVRational, containerSAR: AVRational,
              onFrame: @escaping DecodedFrameHandler) throws {
        self.onFrame = onFrame
        self.timeBase = timeBase

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
            container: containerSAR
        )

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw VideoDecoderError.unsupportedCodec(id: codecpar.pointee.codec_id.rawValue)
        }

        // The display path is the GPU finisher reading the decoder's own memory; without a Metal device there is
        // no display path, and a format its reader cannot describe has none either.
        let sourceFormat = AVPixelFormat(rawValue: codecpar.pointee.format)
        if sourceFormat != AV_PIX_FMT_NONE, !PlanarFrameFinisher.reads(sourceFormat) {
            throw VideoDecoderError.unsupportedPixelFormat(name: av_get_pix_fmt_name(sourceFormat).map { String(cString: $0) } ?? "\(sourceFormat.rawValue)")
        }
        guard let device = MTLCreateSystemDefaultDevice() else { throw VideoDecoderError.metalUnavailable }
        // >8-bit when the stream declares it or carries an HDR transfer (HDR10, AV1 HDR).
        let streamIs10Bit = codecpar.pointee.bits_per_raw_sample > 8 || ColorAttachments.isHDRTransfer(codecpar.pointee.color_trc)
        let made = try DisplayBufferWriter(device: device, streamIs10Bit: streamIs10Bit, twelveBit420: Self.twelveBit420Output,
                                           containerHDRStatic: HDRStaticMetadata(codecpar: codecpar), logTag: "SWDecoder")
        writer = made
        filmCadence = AetherEngine.filmDetection
            ? FilmCadence(timeBase: timeBase, filmCoded: deinterlaceConfig.softTelecine) : nil
        if deinterlaces {
            window = BwdifWindow(timeBase: timeBase, fieldRate: deinterlaceConfig.fieldRate == .field)
            // A stream that declares interlacing compiles the deinterlacer's pipeline now, off this thread, so its first
            // field does not wait for the compiler.
            if VideoRoutingPolicy.interlacedFieldOrders.contains(codecpar.pointee.field_order),
               let layout = PictureLayout(format: sourceFormat) {
                DispatchQueue.global(qos: .userInitiated).async { _ = try? made.finisher.kernels.pipeline(for: layout, function: "pf_bwdif") }
            }
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw VideoDecoderError.sessionCreationFailed(status: -1)
        }
        codecContext = ctx
        made.install(on: ctx, codec: codec)

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw VideoDecoderError.noCodecParameters
        }
        let container = ColorDescription(decoding: codecpar)
        ctx.pointee.color_range = container.range

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

        colourFill = ColourBackfill(container: container)

        // Release-visible log (no #if DEBUG): needed for TestFlight users and DrHurt #4 black-screen reports.
        EngineLog.emit("[SWDecoder] Opened: \(codecpar.pointee.width)x\(codecpar.pointee.height), codec=\(String(cString: codec.pointee.name)), threads=\(ctx.pointee.thread_count), \(streamIs10Bit ? "10-bit" : "8-bit")", category: .swPlayback)
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
        gate.lock()
        defer { gate.unlock() }
        // AE#492: a packet decided on before a flush is not sent after it. A flush that lands after this check
        // leaves the packet's frames on the retired epoch, which delivery drops, and its reset clears the decoder at
        // the next call.
        guard let current = takeControl(), let ctx = codecContext else { return }
        if let epoch, epoch != current { return }
        var sendRet = avcodec_send_packet(ctx, packet)
        if Self.disposition(forSendResult: sendRet) == .drainAndRetry {
            drainDecodedFrames(ctx, epoch: current)
            // Audit DEC-1: a flush can land in the drain.
            guard isCurrent(current) else { return }
            sendRet = avcodec_send_packet(ctx, packet)
        }
        if Self.disposition(forSendResult: sendRet) == .dropped, !loggedSendFailure {
            loggedSendFailure = true
            EngineLog.emit("[SWDecoder] send_packet returned \(sendRet); packet dropped (logged once)",
                           category: .swPlayback)
        }
        // Drain regardless: a dropped packet does not invalidate frames the decoder already holds.
        drainDecodedFrames(ctx, epoch: current)
    }

    /// What the host's calls have left since the decode thread's last call, applied on the decode thread: a flush's
    /// reset (the decoder's buffers, the consecutive-picture chains) and the discard switch. The current epoch, or nil
    /// once the decoder is closed. Caller holds `gate`.
    private func takeControl() -> UInt64? {
        guard !closed.load(ordering: .acquiring) else { return nil }
        // The epoch first: a flush stores its request before it moves the epoch, so a request it made for this epoch is
        // seen below.
        let current = epoch.load(ordering: .acquiring)
        let reset = resetRequest.exchange(0, ordering: .acquiring)
        if reset & Self.resetPending != 0 {
            // Deinterlacer temporal references are stale across seeks.
            if reset & Self.resetFilterGraph != 0 {
                window?.reset()
                inverseTelecine?.reset()
            }
            filmCadence?.reset()
            chainRestartPending = false
            if let ctx = codecContext { avcodec_flush_buffers(ctx) }
        }
        let discardValue = discardRequest.exchange(0, ordering: .acquiring)
        if discardValue != 0, let ctx = codecContext {
            let discard = discardValue == Self.discardOn
            ctx.pointee.skip_frame = discard && !carriesDecodedCaptions ? AVDISCARD_NONREF : AVDISCARD_DEFAULT
            if discard, window?.isActive == true || inverseTelecine != nil || filmCadence?.isActive == true {
                chainRestartPending = true
            }
        }
        return current
    }

    /// The next delivery ticket of `epoch`'s line, which starts at 0. Decode thread.
    private func takeTicket(_ epoch: UInt64) -> UInt64 {
        if epoch != ticketEpoch {
            ticketEpoch = epoch
            nextTicket = 0
        }
        defer { nextTicket &+= 1 }
        return nextTicket
    }

    /// Pull every frame the decoder can currently produce, through the deinterlacer when one is
    /// active. Exits on EAGAIN (needs more input) or EOF, the same condition the receive loop
    /// has always used.
    private func drainDecodedFrames(_ ctx: UnsafeMutablePointer<AVCodecContext>, epoch: UInt64) {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { return }

        // A flush between frames retires the rest: its reset clears the decoder at the next call.
        while isCurrent(epoch) {
            let ret = avcodec_receive_frame(ctx, f)
            guard ret >= 0 else { break }

            // AE#499: fill the fields the VUI left open from the container's declaration BEFORE any
            // consumer reads the frame, for the same reason the timestamp repair below runs here.
            colourFill.fill(f)
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

            // Soft telecine: a film run's pictures on the film rate's grid, before anything reads the timestamp.
            if let filmCadence {
                f.pointee.pts = filmCadence.retime(pts: f.pointee.pts, interlaced: f.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0,
                                                   repeatPict: f.pointee.repeat_pict, carriage: ctx.pointee.framerate)
            }

            // #131: A53 captions surface as decoded-frame side data on the FFmpeg path (MPEG-2
            // picture user data and friends). Presentation order by construction of decoder output.
            if let onA53 = onA53Captions,
               let sd = av_frame_get_side_data(f, AV_FRAME_DATA_A53_CC),
               let sdData = sd.pointee.data, sd.pointee.size >= 3,
               f.pointee.pts != Int64.min, timeBase.den > 0 {
                carriesDecodedCaptions = true
                let extracted = CCDataParser.parseCCDataTriplets(bytes: sdData, count: Int(sd.pointee.size))
                if !extracted.isEmpty {
                    let pts = Double(f.pointee.pts) * Double(timeBase.num) / Double(timeBase.den)
                    onA53(extracted, pts)
                }
            }

            if chainRestartPending {
                if let threshold = skipUntilPTS,
                   CMTimeCompare(SourceTimestampBounds.cmTime(ticks: f.pointee.pts, timeBase: timeBase), threshold) < 0 {
                    continue
                }
                window?.reset()
                inverseTelecine?.reset()
                filmCadence?.reset()
                chainRestartPending = false
            }

            if let ivtc = inverseTelecine(for: f), let picture = hold(f) {
                telecine(ivtc, picture, epoch: epoch)
                continue
            }
            let isInterlaced = (f.pointee.flags & AV_FRAME_FLAG_INTERLACED) != 0
            if let window, isInterlaced || window.isActive, let picture = hold(f) {
                render(window.push(picture), timeBase: window.outputTimeBase, epoch: epoch)
                continue
            }
            emit(f, timeBase: timeBase, epoch: epoch)
        }

        av_frame_free(&frame)
    }

    /// The inverse-telecine chain for `f`'s stream when the load found film in it: made on the first picture, nil (and one
    /// log line) when its format or size is not one inverse telecine takes. Decode thread.
    private func inverseTelecine(for f: UnsafePointer<AVFrame>) -> InverseTelecine? {
        if let inverseTelecine { return inverseTelecine }
        guard let film = deinterlaceConfig.film, !loggedTelecineRefusal, let writer, let ctx = codecContext else { return nil }
        let format = AVPixelFormat(rawValue: f.pointee.format)
        guard let made = InverseTelecine(kernels: writer.finisher.kernels, makePicture: Self.slabMaker(writer.allocator), format: format,
                                         width: Int(f.pointee.width), height: Int(f.pointee.height), timeBase: timeBase,
                                         frameRate: ctx.pointee.framerate, decimates: film == .pulldown32) else {
            loggedTelecineRefusal = true
            EngineLog.emit("[SWDecoder] inverse telecine does not take \(av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "?") "
                           + "\(f.pointee.width)x\(f.pointee.height); the deinterlacer runs instead", category: .swPlayback)
            return nil
        }
        EngineLog.emit("[SWDecoder] inverse telecine engaged (\(film.rawValue))", category: .swPlayback)
        inverseTelecine = made
        return made
    }

    /// Empty pictures for inverse telecine's weaves and deinterlaced frames, in slabs of `allocator`.
    static func slabMaker(_ allocator: DecodeFrameAllocator) -> InverseTelecine.PictureMaker {
        { [weak allocator] format, width, height in
            guard let allocator, let made = allocator.picture(format: format, width: Int32(width), height: Int32(height)) else { return nil }
            return (made.planes, { [weak allocator] in allocator?.release(made.slab) })
        }
    }

    /// `f` held for the deinterlacer: a reference to the frame and where its planes are (the decoder's own slab, or a
    /// copy in one for rawvideo and libavcodec's paletted buffers). Nil when the deinterlacer does not take the
    /// format or the picture (planes under 3 columns or 4 lines, as FFmpeg's bwdif), which then goes out as decoded.
    /// Decode thread.
    private func hold(_ f: UnsafeMutablePointer<AVFrame>) -> BwdifWindow.Picture? {
        guard let allocator = writer?.allocator, deinterlaceFormat(f) != nil, let held = av_frame_clone(f) else { return nil }
        if let slab = allocator.slab(of: held), let planes = PlanarFrameFinisher.planes(of: held, in: slab) {
            return BwdifWindow.Picture(storage: .init(frame: held, planes: planes, release: nil), pts: held.pointee.pts)
        }
        guard let copy = allocator.copy(held) else {
            var owned: UnsafeMutablePointer<AVFrame>? = held
            av_frame_free(&owned)
            return nil
        }
        return BwdifWindow.Picture(storage: .init(frame: held, planes: copy.planes, release: { [weak allocator] in
            allocator?.release(copy.slab)
        }), pts: held.pointee.pts)
    }

    /// The deinterlacer's reader and planar format for `f`'s format, or nil (logged once per format).
    private func deinterlaceFormat(_ f: UnsafePointer<AVFrame>) -> (layout: PictureLayout, planar: AVPixelFormat)? {
        let format = f.pointee.format
        if let known = deinterlaceFormats[format] { return known }
        let source = AVPixelFormat(rawValue: format)
        var found: (layout: PictureLayout, planar: AVPixelFormat)?
        if let layout = PictureLayout(format: source), let planar = PlanarFrameFinisher.planarEquivalent(of: source),
           BwdifWindow.referenceFormats.contains(planar.rawValue), let desc = av_pix_fmt_desc_get(source)?.pointee {
            let chromaW = (Int(f.pointee.width) + (1 << Int(desc.log2_chroma_w)) - 1) >> Int(desc.log2_chroma_w)
            let chromaH = (Int(f.pointee.height) + (1 << Int(desc.log2_chroma_h)) - 1) >> Int(desc.log2_chroma_h)
            if chromaW >= 3, chromaH >= 4 { found = (layout, planar) }
        }
        if found == nil {
            EngineLog.emit("[SWDecoder] the deinterlacer does not take \(av_get_pix_fmt_name(source).map { String(cString: $0) } ?? "?") "
                           + "\(f.pointee.width)x\(f.pointee.height); interlaced pictures go out as decoded", category: .swPlayback)
        }
        deinterlaceFormats[format] = .some(found)
        return found
    }

    /// Writes the window's outputs, all in one GPU submission, and emits them in order. Pictures before a seek's
    /// target and pictures without a timestamp (yadif's second field is `cur + next`, missing when either is) are not
    /// written. Each output takes its delivery ticket here, in order, and reaches the host when the submission completes;
    /// the pictures are held until then. Decode thread.
    private func render(_ outputs: [BwdifWindow.Output], timeBase tb: AVRational, epoch: UInt64) {
        guard !outputs.isEmpty, let finisher = writer?.finisher else { return }
        var jobs: [PlanarFrameFinisher.Job] = []
        var emits: [(ticket: UInt64, frame: DeliveredFrame)] = []
        var held: [BwdifWindow.Picture] = []
        for output in outputs {
            let picture: BwdifWindow.Picture, pts: Int64
            switch output {
            case .picture(let p, let t): (picture, pts) = (p, t)
            case .field(_, let cur, _, _, _, _, let t): (picture, pts) = (cur, t)
            }
            guard pts != Int64.min else {
                noteUntimestamped()
                continue
            }
            if let threshold = skipUntilPTS {
                let at = SourceTimestampBounds.cmTime(ticks: pts, timeBase: tb)
                if at.isValid, CMTimeCompare(at, threshold) < 0 { continue }
            }
            let source: PlanarFrameFinisher.Job.Source
            let prepared: (plan: PlanarFrameFinisher.Plan, buffer: CVPixelBuffer)?
            switch output {
            case .picture(let p, _):
                prepared = prepare(p.frame, planFormat: AVPixelFormat(rawValue: p.frame.pointee.format),
                                   interlaced: p.interlaced)
                source = .picture(p.storage.planes)
            case .field(let prev, let cur, let next, let parity, let fieldParity, let intra, _):
                guard let formats = deinterlaceFormat(cur.frame) else { continue }
                prepared = prepare(cur.frame, planFormat: formats.planar, interlaced: false)
                source = .field(.init(bwdif: .init(prev: prev.storage.planes, cur: cur.storage.planes, next: next.storage.planes,
                                                   parity: parity, fieldParity: fieldParity, intra: intra),
                                      layout: formats.layout))
            }
            guard let prepared, let frame = deliverable(picture.frame, timeBase: tb, pts: pts, buffer: prepared.buffer)
            else { continue }
            jobs.append(.init(source: source, plan: prepared.plan, width: Int(picture.frame.pointee.width),
                              height: Int(picture.frame.pointee.height), buffer: prepared.buffer))
            emits.append((takeTicket(epoch), frame))
            held.append(picture)
        }
        guard !jobs.isEmpty else { return }
        let delivery = delivery
        let failureLogged = finishFailureLogged
        nonisolated(unsafe) let pictures = held
        let tickets = emits
        finisher.finish(jobs) { failure in
            withExtendedLifetime(pictures) {}
            if let failure, failureLogged.claim() {
                EngineLog.emit("[SWDecoder] GPU deinterlace and finish failed: \(failure) (logged once)",
                               category: .swPlayback)
            }
            for e in tickets {
                if failure == nil {
                    delivery.fulfil(ticket: e.ticket, epoch: epoch, e.frame)
                } else {
                    delivery.skip(ticket: e.ticket, epoch: epoch)
                }
            }
        }
    }

    /// One decoded picture (nil: the end of the stream) through inverse telecine and the finish of the film pictures it
    /// releases, in one batch: the chain's work first (its decisions taken on the GPU), the finishes behind it. Each film
    /// picture takes its ticket here, in order; whether it goes out, and at what timestamp, is read when the batch
    /// completes (decimate drops one in five, and the skip threshold applies to the timestamp it gets). The chain's
    /// fences order its work after the earlier batches' chain work, whose state it reads, and the finishes after it.
    /// Decode thread.
    private func telecine(_ ivtc: InverseTelecine, _ picture: BwdifWindow.Picture?, epoch: UInt64) {
        guard let finisher = writer?.finisher else { return }
        finisher.finish { batch in
            let pushed = ivtc.push(picture, into: DeinterlaceGPU.batch(batch))
            var jobs: [PlanarFrameFinisher.Job] = []
            var films: [(ticket: UInt64, output: InverseTelecine.Output, buffer: SendableBuffer, hdr10: Data?)] = []
            for output in pushed.outputs {
                let frame = output.picture.frame
                guard let prepared = prepare(frame, planFormat: AVPixelFormat(rawValue: frame.pointee.format), interlaced: false)
                else { continue }
                // Decimate's drop is decided on the GPU in this batch; the dropped picture's finish dispatches nothing.
                // So is the window's: a picture it passed through is read from its weave, bwdif never having written it.
                jobs.append(.init(source: .picture(output.picture.storage.planes), plan: prepared.plan,
                                  width: Int(frame.pointee.width), height: Int(frame.pointee.height), buffer: prepared.buffer,
                                  kept: output.kept, passthrough: (output.passthrough.storage.planes, output.passedThrough)))
                reportDecodedFormat(pixelBuffer: prepared.buffer)
                films.append((takeTicket(epoch), output, SendableBuffer(value: prepared.buffer), extractHDR10PlusBytes(from: frame)))
            }
            nonisolated(unsafe) let held = pushed.touched + pushed.outputs.flatMap { [$0.picture, $0.passthrough] }
            let delivery = delivery, timeBase = ivtc.outputTimeBase
            // Read on the completion queue: the films' records (immutable from here) and the chain's results, which
            // `resolve` reads once the pass has completed.
            nonisolated(unsafe) let tickets = films
            nonisolated(unsafe) let chain = ivtc
            let failureLogged = finishFailureLogged
            return (jobs, ivtc.fence, { [weak self] failure in
                withExtendedLifetime(held) {}
                if let failure, failureLogged.claim() {
                    EngineLog.emit("[SWDecoder] GPU inverse telecine and finish failed: \(failure) (logged once)",
                                   category: .swPlayback)
                }
                for film in tickets {
                    guard failure == nil, let pts = chain.resolve(film.output) else {
                        delivery.skip(ticket: film.ticket, epoch: epoch)
                        continue
                    }
                    guard pts != Int64.min else {
                        self?.noteUntimestamped()
                        delivery.skip(ticket: film.ticket, epoch: epoch)
                        continue
                    }
                    let cmPTS = SourceTimestampBounds.cmTime(ticks: pts, timeBase: timeBase)
                    if let self, let threshold = self.skipUntilPTS, cmPTS.isValid {
                        if CMTimeCompare(cmPTS, threshold) < 0 {
                            delivery.skip(ticket: film.ticket, epoch: epoch)
                            continue
                        }
                        self.clearSkip(ifStillAt: threshold)
                    }
                    delivery.fulfil(ticket: film.ticket, epoch: epoch,
                                    DeliveredFrame(buffer: film.buffer, pts: cmPTS, hdr10Data: film.hdr10, dmNAL: nil))
                }
            })
        }
    }

    /// A deinterlaced or telecine-recovered picture's failed finish is logged once; set from the completion queue.
    private let finishFailureLogged = OnceFlag()

    /// End of source or a live seam: deliver what libavcodec and the deinterlacer still hold, then
    /// leave both ready to decode again. The protocol default did nothing here, so the host's
    /// `flush()` discarded it: frame threading keeps up to `thread_count` frames in flight on top of
    /// the reorder delay, and yadif/bwdif one frame of look-ahead (two fields at field rate), which
    /// were the last pictures of every software-decoded file and of every segment before a seam.
    ///
    /// The NULL packet puts libavcodec in draining mode, and a buffersrc fed EOF refuses frames for
    /// good, so both are reset here (`avcodec_flush_buffers`, graph teardown) rather than relying on
    /// the caller's `flush()`: the still extractor's `flush(resetFilterGraph: false)` would otherwise
    /// keep a graph that can never take another frame. The epoch is not moved, this is not a seek.
    func drainForEndOfStream() {
        gate.lock()
        guard let epoch = takeControl(), let ctx = codecContext else { gate.unlock(); return }
        var sendRet = avcodec_send_packet(ctx, nil)
        if Self.disposition(forSendResult: sendRet) == .drainAndRetry {
            drainDecodedFrames(ctx, epoch: epoch)
            sendRet = avcodec_send_packet(ctx, nil)
        }
        // Exits on AVERROR_EOF once the decoder has handed over its last frame.
        if sendRet >= 0 { drainDecodedFrames(ctx, epoch: epoch) }
        // A flush that landed during the drain retired this stream; its frames are not owed.
        if isCurrent(epoch), let window, window.isActive {
            render(window.finish(), timeBase: window.outputTimeBase, epoch: epoch)
        }
        if isCurrent(epoch), let ivtc = inverseTelecine {
            telecine(ivtc, nil, epoch: epoch)
        }
        window?.reset()
        inverseTelecine?.reset()
        filmCadence?.reset()
        avcodec_flush_buffers(ctx)
        let finisher = writer?.finisher
        gate.unlock()
        // Every frame owed is out before this returns: the GPU's last submissions, then their delivery.
        finisher?.waitUntilIdle()
        delivery.barrier()
    }

    /// Returns once every frame decoded so far has reached the host (or been dropped by a flush): the GPU's submissions
    /// so far, then their delivery. For offline callers that read what `onFrame` collected (the probe, stills), never on a
    /// playback path. Not from `onFrame` itself.
    func awaitDelivered() {
        gate.lock()
        let finisher = writer?.finisher
        gate.unlock()
        finisher?.waitUntilIdle()
        delivery.barrier()
    }

    /// One decoded frame to the host: past the skip threshold, prepared (its display buffer, with the stream's sample
    /// aspect), its ticket taken, and its finish submitted; it reaches the host when the GPU completes. Decode thread.
    private func emit(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational, epoch: UInt64) {
        // Per-frame autorelease pool: the decode/feed loops are single long-running dispatch blocks, so without this,
        // ObjC transients (Metal command buffers, CV bridging) accumulate in the block's last-resort pool and only pop at
        // session end, after close() tore the session down.
        autoreleasepool {
            guard let writer,
                  let prepared = prepare(f, planFormat: AVPixelFormat(rawValue: f.pointee.format),
                                         interlaced: f.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0,
                                         grain: FilmGrainParameters(frame: f) != nil),
                  let frame = deliverable(f, timeBase: tb, pts: f.pointee.pts, buffer: prepared.buffer) else { return }
            let ticket = takeTicket(epoch)
            let delivery = delivery
            writer.finish(f, into: prepared) { written in
                guard let written else { return delivery.skip(ticket: ticket, epoch: epoch) }
                delivery.fulfil(ticket: ticket, epoch: epoch, DeliveredFrame(buffer: written, pts: frame.pts,
                                                                             hdr10Data: frame.hdr10Data, dmNAL: nil))
            }
        }
    }

    /// What the host gets for a frame, or nil when it is before the skip threshold: its time on `tb`, the base `pts`
    /// rides on (the stream's for a decoded frame, `BwdifWindow.outputTimeBase` for a deinterlaced one, halved as
    /// FFmpeg's bwdif does, so send_field's fields keep distinct ticks), and its HDR10+ data. Reports the display
    /// buffer's format. Decode thread.
    private func deliverable(_ f: UnsafeMutablePointer<AVFrame>, timeBase tb: AVRational, pts: Int64,
                             buffer: CVPixelBuffer) -> DeliveredFrame? {
        let cmPTS = SourceTimestampBounds.cmTime(ticks: pts, timeBase: tb)
        if let threshold = skipUntilPTS, cmPTS.isValid {
            if CMTimeCompare(cmPTS, threshold) < 0 { return nil }
            // Compare-and-clear: a concurrent seek can install a new threshold; blindly nil-ing would discard it.
            clearSkip(ifStillAt: threshold)
        }
        reportDecodedFormat(pixelBuffer: buffer)
        // HDR10+: read dynamic metadata from post-decode AVFrame side data (T.35 SEI bytes).
        // Can't reuse the VT path's packet-side stash; this decoder owns its own packet flow.
        let hdr10PlusData = extractHDR10PlusBytes(from: f)
        if hdr10PlusData != nil, !seenHDR10Plus {
            seenHDR10Plus = true
            onFirstHDR10PlusDetected?()
        }
        return DeliveredFrame(buffer: SendableBuffer(value: buffer), pts: cmPTS, hdr10Data: hdr10PlusData, dmNAL: nil)
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
        // AE#492: retires every packet a caller had already decided to send, and every frame not yet delivered. The
        // delivery line is reset before the epoch moves, so no frame of the new epoch can reach it first; the decode
        // thread applies the reset itself at its next call.
        hostCalls.withLock { _ in
            let next = epoch.load(ordering: .relaxed) &+ 1
            delivery.resetAsync(epoch: next, nextTicket: 0)
            resetRequest.bitwiseOr(Self.resetPending | (resetFilterGraph ? Self.resetFilterGraph : 0), ordering: .releasing)
            epoch.store(next, ordering: .releasing)
        }
        delivery.barrier()
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
        hostCalls.withLock { _ in
            let next = epoch.load(ordering: .relaxed) &+ 1
            delivery.resetAsync(epoch: next, nextTicket: 0)
            closed.store(true, ordering: .releasing)
            epoch.store(next, ordering: .releasing)
        }
        delivery.setOnFrame(nil)
        // The one wait on the decode thread: its call in progress ends before the state goes. GPU work still in flight
        // holds its own references (the finisher's slots, the held pictures) and is dropped at delivery.
        gate.lock()
        window?.reset()
        inverseTelecine = nil
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        codecContext = nil
        writer = nil
        gate.unlock()
        delivery.barrier()
    }

    deinit {
        close()
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

    // MARK: - AVFrame → CVPixelBuffer (GPU finisher)

    /// The finisher's plan and display buffer for `frame` (``DisplayBufferWriter/prepare(_:planFormat:interlaced:grain:)``),
    /// with the stream's sample aspect attached before any GPU work is committed for it.
    private func prepare(_ frame: UnsafeMutablePointer<AVFrame>, planFormat: AVPixelFormat, interlaced: Bool,
                         grain: Bool = false) -> (plan: PlanarFrameFinisher.Plan, buffer: CVPixelBuffer)? {
        guard let prepared = writer?.prepare(frame, planFormat: planFormat, interlaced: interlaced, grain: grain) else {
            return nil
        }
        attachPixelAspectRatio(from: frame, to: prepared.buffer)
        return prepared
    }

    nonisolated static func isJPEGFormat(_ format: AVPixelFormat) -> Bool {
        switch format {
        case AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P, AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P:
            true
        default:
            false
        }
    }

    // MARK: - Chroma siting

    /// The CoreVideo chroma location for the frame's `chroma_location` on a buffer with `output`
    /// subsampling. nil for 4:4:4, which has nothing to site.
    ///
    /// Unspecified is filled the way mpv fills it: left (co-sited horizontally, between the lines
    /// vertically), the MPEG-2 / H.264 / HEVC / AV1 convention and so what an unlabelled stream on this
    /// route almost always is, except a JPEG-family picture, which is centred. Left rather than no
    /// attachment, because a buffer without one leaves the choice to whatever the display layer
    /// assumes, and nothing documents that. On a 4:2:2 buffer only the horizontal half of the siting
    /// exists, so the vertical variants fold onto Left / Center (a 4:2:0 picture the finisher widens into
    /// `sv22` keeps its horizontal siting).
    /// The frame's chroma siting with UNSPECIFIED filled: centred for JPEG (yuvj) formats, LEFT otherwise (the
    /// H.264 / HEVC inference when the VUI carries no chroma_loc_info, and MPEG-2's 4:2:0).
    nonisolated static func resolvedChromaLocation(_ location: AVChromaLocation, isJPEG: Bool) -> AVChromaLocation {
        location == AVCHROMA_LOC_UNSPECIFIED ? (isJPEG ? AVCHROMA_LOC_CENTER : AVCHROMA_LOC_LEFT) : location
    }

    nonisolated static func chromaLocation(_ location: AVChromaLocation, output: OutputFormat.Chroma,
                                           isJPEG: Bool) -> CFString? {
        let resolved = resolvedChromaLocation(location, isJPEG: isJPEG)
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
        /// 16-bit 4:2:2 `sv22`: all 12 bits of luma kept, chroma upsampled vertically by the finisher.
        case sv22 = "sv22"
    }

    /// Takes effect from the next software decoder opened and applies to every session in the process.
    @_spi(Diagnostics)
    public nonisolated static var softwareTwelveBit420Output: SoftwareTwelveBit420Output {
        get { SoftwareTwelveBit420Output(rawValue: SoftwareVideoDecoder.twelveBit420Output.rawValue) ?? .p010Dithered }
        set { SoftwareVideoDecoder.twelveBit420Output = .init(rawValue: newValue.rawValue) ?? .p010Dithered }
    }
}
