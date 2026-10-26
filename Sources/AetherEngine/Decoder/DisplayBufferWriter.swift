import Foundation
import CoreVideo
import Metal
import os
import AetherLibavcodec
import AetherLibavutil

/// A software-decoded picture into the display buffer the player shows: libavcodec decodes into slabs
/// (``DecodeFrameAllocator``), the GPU finisher reads them and writes the buffer, tagged with the picture's colour,
/// chroma siting and HDR static metadata. The sample aspect is the caller's (playback latches one per stream, a still
/// resolves its own). Playback's software decoder and the still decoder both make their buffers here
/// (docs/software-route-gpu.md Parts 2 and 7).
///
/// Not thread-safe: the owner serialises every call (the decoder under its `lock`, the still decoder on its queue).
final class DisplayBufferWriter {
    typealias OutputFormat = SoftwareVideoDecoder.OutputFormat

    /// Where the decoder writes its pictures, and the GPU pass that reads them.
    let allocator: DecodeFrameAllocator
    let finisher: PlanarFrameFinisher

    /// The attributes of every display buffer the finisher writes. Format and size are the pool's own.
    static var displayBufferAttributes: CFDictionary {
        [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary(),
        ] as NSDictionary
    }

    /// What a plan is decided by: the frame's format and range, the output, the siting and matrix it is written
    /// with, and whether the picture is interlaced (no vertical chroma resampling then).
    struct PlanKey: Hashable {
        var pixelFormat: Int32
        var output: OutputFormat
        var sourceFullRange: Bool
        var chromaLocation: UInt32
        var matrix: String
        var interlaced: Bool
        var representation: ColourRepresentation
        var grain: Bool
    }

    /// Every log line's prefix: whose buffers these are.
    private let logTag: String
    /// The open-time verdict (declared depth or an HDR transfer); see ``SoftwareVideoDecoder/outputFormat``.
    private let streamIs10Bit: Bool
    private let twelveBit420: SoftwareVideoDecoder.TwelveBit420Output
    /// HDR10 static metadata the container declared, the fallback for a frame that carries none, and the value last
    /// attached, kept so every frame of a stream gets the same `NSData` object (and the renderer's format-description
    /// key equal bytes).
    private let containerHDRStatic: HDRStaticMetadata
    private var attachedHDRStatic = HDRStaticMetadata.none
    /// The finisher's plan per frame description, and the descriptions it refused (logged once each).
    private var plans: [PlanKey: PlanarFrameFinisher.Plan] = [:]
    private var refusedPlans: Set<PlanKey> = []
    private var refusedRepresentations: Set<String> = []
    private var pool: (width: Int, height: Int, format: OutputFormat, pool: CVPixelBufferPool)?
    /// The format the last picture asked for, so a change is logged once rather than per frame.
    private var loggedOutputFormat: OutputFormat?
    /// A declared colour value CoreVideo has no constant for is named once.
    private var loggedUnmappedColor = false
    /// A failed GPU finish is logged once; set from the completion queue.
    private let finishFailureLogged = OnceFlag()

    init(device: MTLDevice, streamIs10Bit: Bool, twelveBit420: SoftwareVideoDecoder.TwelveBit420Output,
         containerHDRStatic: HDRStaticMetadata, logTag: String) throws {
        guard let allocator = DecodeFrameAllocator(device: device) else { throw VideoDecoderError.metalUnavailable }
        self.allocator = allocator
        finisher = try PlanarFrameFinisher(device: device)
        self.streamIs10Bit = streamIs10Bit
        self.twelveBit420 = twelveBit420
        self.containerHDRStatic = containerHDRStatic
        self.logTag = logTag
    }

    /// Before `avcodec_open2`: pictures go straight into the slabs the finisher reads (a decoder without DR1 keeps
    /// libavcodec's buffers and its pictures are copied), and the conformance window is kept exactly. libavcodec
    /// otherwise rounds a left crop down to keep the planes 32-byte aligned for CPU code, showing columns the stream
    /// crops; the GPU reads any offset.
    ///
    /// libdav1d hands AV1's film grain over as parameters instead of a second, grained picture: the finisher applies it
    /// (AV1 7.18.3, docs/software-route-gpu.md Part 5). Only libdav1d: the H.264 / HEVC decoders' grain is H.274's,
    /// which they apply themselves.
    func install(on ctx: UnsafeMutablePointer<AVCodecContext>, codec: UnsafePointer<AVCodec>) {
        if codec.pointee.capabilities & AV_CODEC_CAP_DR1 != 0 { allocator.install(on: ctx) }
        ctx.pointee.flags |= AV_CODEC_FLAG_UNALIGNED
        if String(cString: codec.pointee.name) == "libdav1d" {
            ctx.pointee.export_side_data |= Int32(AV_CODEC_EXPORT_DATA_FILM_GRAIN)
        }
    }

    /// A decoded picture's own planes (``prepare(_:planFormat:interlaced:grain:)``) written by the GPU into
    /// `prepared`'s display buffer. `completion` gets the buffer once the GPU has written it, or nil when it could not
    /// be (one log line), from the GPU's completion queue (hand off, never block), or on the caller's thread when the
    /// work could not be encoded. The picture's memory is held until then by a reference of the writer's own.
    func finish(_ frame: UnsafeMutablePointer<AVFrame>, into prepared: (plan: PlanarFrameFinisher.Plan, buffer: CVPixelBuffer),
                completion: @escaping @Sendable (SendableBuffer?) -> Void) {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        // The decoder's own slab, or (rawvideo, libavcodec's paletted buffers) a copy of the picture in one.
        let planes: PlanarFrameFinisher.Planes
        var copied: DecodeFrameAllocator.Slab?
        var reference: UnsafeMutablePointer<AVFrame>?
        if let slab = allocator.slab(of: frame), let own = PlanarFrameFinisher.planes(of: frame, in: slab),
           let held = av_frame_clone(frame) {
            planes = own
            reference = held
        } else if let copy = allocator.copy(frame) {
            planes = copy.planes
            copied = copy.slab
        } else {
            return completion(nil)
        }
        let held = HeldPicture(frame: reference, copy: copied, allocator: allocator)
        let written = SendableBuffer(value: prepared.buffer)
        let tag = logTag
        let failureLogged = finishFailureLogged
        finisher.finish(planes, plan: prepared.plan, width: width, height: height, into: prepared.buffer,
                        grain: FilmGrainParameters(frame: frame)) { ok in
            held.release()
            if !ok, failureLogged.claim() {
                EngineLog.emit("[\(tag)] GPU finish failed (logged once)", category: .swPlayback)
            }
            completion(ok ? written : nil)
        }
    }

    /// The display buffer for one decoded picture, prepared and finished, waited for: for offline callers (stills), never
    /// on a playback path. Nil (and one log line per kind) when the finisher cannot write this frame's format into the
    /// output, or the GPU could not.
    func finishAndWait(_ frame: UnsafeMutablePointer<AVFrame>) -> CVPixelBuffer? {
        guard let prepared = prepare(frame, planFormat: AVPixelFormat(rawValue: frame.pointee.format),
                                     interlaced: frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0,
                                     grain: FilmGrainParameters(frame: frame) != nil) else { return nil }
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<SendableBuffer?>(initialState: nil)
        finish(frame, into: prepared) { buffer in
            result.withLock { $0 = buffer }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }?.value
    }

    /// A finished picture's memory, held until its GPU work completes: a reference to the decoder's frame, or the slab
    /// it was copied into.
    private final class HeldPicture: @unchecked Sendable {
        private var frame: UnsafeMutablePointer<AVFrame>?
        private let copy: DecodeFrameAllocator.Slab?
        private let allocator: DecodeFrameAllocator

        init(frame: UnsafeMutablePointer<AVFrame>?, copy: DecodeFrameAllocator.Slab?, allocator: DecodeFrameAllocator) {
            (self.frame, self.copy, self.allocator) = (frame, copy, allocator)
        }

        func release() {
            av_frame_free(&frame)
            if let copy { allocator.release(copy) }
        }
    }

    /// The finisher's plan for `frame` and the display buffer it writes, tagged with the frame's colour. `planFormat` is
    /// the layout the finisher reads: the frame's own, or for a deinterlaced picture its planar equivalent
    /// (``PlanarFrameFinisher/planarEquivalent(of:)``), with `interlaced` false. Range, siting and colour come from the
    /// frame and its own format either way. `grain`: the frame carries AV1 film grain, applied as the finisher reads it.
    func prepare(_ frame: UnsafeMutablePointer<AVFrame>, planFormat: AVPixelFormat,
                 interlaced: Bool, grain: Bool = false) -> (plan: PlanarFrameFinisher.Plan, buffer: CVPixelBuffer)? {
        let width = Int(frame.pointee.width), height = Int(frame.pointee.height)
        guard width > 0, height > 0 else { return nil }
        let format = AVPixelFormat(rawValue: frame.pointee.format)
        let colour = ColorDescription(frame: frame)
        let representation = ColourRepresentation.resolve(format: format, matrix: colour.matrix, primaries: colour.primaries,
                                                          transfer: colour.transfer)
        if case .refused(let reason) = representation {
            if refusedRepresentations.insert(reason).inserted {
                EngineLog.emit("[\(logTag)] cannot represent this picture: \(reason); frames dropped", category: .swPlayback)
            }
            return nil
        }
        let outputFormat = SoftwareVideoDecoder.outputFormat(
            pixelFormat: frame.pointee.format, colorRange: frame.pointee.color_range, streamIs10Bit: streamIs10Bit,
            twelveBit420: twelveBit420, interlaced: interlaced, representation: representation)
        logOutputFormat(outputFormat, source: av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "?",
                        colorRange: frame.pointee.color_range)

        let isJPEG = SoftwareVideoDecoder.isJPEGFormat(format)
        let isRGB = (av_pix_fmt_desc_get(format)?.pointee.flags ?? 0) & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        // H.273: VideoFullRangeFlag applies to R'G'B' codes too. An RGB frame is full range unless it says
        // video range; a Y'CbCr frame (YCgCo's R'G'B' codes included) is video range unless it, or its yuvj
        // format, says full.
        let sourceFullRange = isRGB ? frame.pointee.color_range != AVCOL_RANGE_MPEG
            : (frame.pointee.color_range == AVCOL_RANGE_JPEG || isJPEG)
        // A converted picture is encoded with, and tagged as, the matrix its primaries call for.
        let convertedMatrix = representation.converts ? ColourRepresentation.targetMatrix(primaries: colour.primaries) : nil
        let matrix = convertedMatrix ?? ColorAttachments.presented(colour, frameSize: (frame.pointee.width, frame.pointee.height)).matrix
        let location = SoftwareVideoDecoder.resolvedChromaLocation(frame.pointee.chroma_location, isJPEG: isJPEG)
        let key = PlanKey(pixelFormat: planFormat.rawValue, output: outputFormat, sourceFullRange: sourceFullRange,
                          chromaLocation: UInt32(location.rawValue), matrix: matrix as String, interlaced: interlaced,
                          representation: representation, grain: grain)
        let plan: PlanarFrameFinisher.Plan
        if let known = plans[key] {
            plan = known
        } else if let made = PlanarFrameFinisher.plan(source: planFormat, output: outputFormat, sourceFullRange: sourceFullRange,
                                                      chromaLocation: location, matrix: matrix, interlaced: interlaced,
                                                      representation: representation, grain: grain) {
            plans[key] = made
            plan = made
        } else {
            if refusedPlans.insert(key).inserted {
                EngineLog.emit("[\(logTag)] cannot write \(av_get_pix_fmt_name(format).map { String(cString: $0) } ?? "?")"
                               + "\(interlaced ? " (interlaced)" : "")\(grain ? " with film grain" : "") as "
                               + "\(outputFormat.logDescription); frames dropped",
                               category: .swPlayback)
            }
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        guard let pool = bufferPool(width: width, height: height, format: outputFormat),
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer) == kCVReturnSuccess,
              let pb = pixelBuffer else { return nil }
        attachColorSpace(from: frame, to: pb)
        if let convertedMatrix { CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, convertedMatrix, .shouldPropagate) }
        return (plan, pb)
    }

    /// The pool the finisher writes display buffers into, for the given geometry, with `displayBufferAttributes`.
    private func bufferPool(width: Int, height: Int, format: OutputFormat) -> CVPixelBufferPool? {
        if let pool, pool.width == width, pool.height == height, pool.format == format { return pool.pool }
        self.pool = nil
        let poolAttrs: NSDictionary = [kCVPixelBufferPoolMinimumBufferCountKey: 6]
        let pbAttrs = NSMutableDictionary(dictionary: Self.displayBufferAttributes as NSDictionary)
        pbAttrs[kCVPixelBufferPixelFormatTypeKey] = format.pixelFormatType
        pbAttrs[kCVPixelBufferWidthKey] = width
        pbAttrs[kCVPixelBufferHeightKey] = height
        var made: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs, pbAttrs, &made) == kCVReturnSuccess,
              let made else { return nil }
        pool = (width, height, format, made)
        return made
    }

    /// One release-visible line whenever the buffer format changes, naming what it was chosen from.
    private func logOutputFormat(_ format: OutputFormat, source: String, colorRange: AVColorRange?) {
        guard format != loggedOutputFormat else { return }
        loggedOutputFormat = format
        EngineLog.emit(
            "[\(logTag)] output \(format.logDescription) (frame \(source)"
            + (colorRange.map { ", color_range=\($0.rawValue))" } ?? ")"),
            category: .swPlayback
        )
    }

    // MARK: - Color Space Metadata

    /// Map FFmpeg color metadata to CVPixelBuffer attachments for correct HDR10 rendering (BT.2020 + PQ).
    /// Every field is written, a gap included (AE#654): VideoToolbox never hands the display layer an
    /// untagged buffer, and neither may this writer.
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
            EngineLog.emit("[\(logTag)] no CoreVideo tag for \(gaps); presented as primaries=\(tags.primaries) "
                           + "matrix=\(tags.matrix) (logged once)", category: .swPlayback)
        }
        attachHDRStaticMetadata(from: frame, to: pb)
        attachChromaLocation(from: frame, to: pb)
    }

    /// Where the subsampled chroma samples sit, which the display layer's upsampler needs to put the
    /// colour back on the right pixels. Same value for both fields: what leaves the finisher is progressive.
    private func attachChromaLocation(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let chroma = OutputFormat(pixelFormatType: CVPixelBufferGetPixelFormatType(pb))?.chroma ?? .yuv420
        guard let location = SoftwareVideoDecoder.chromaLocation(
            frame.pointee.chroma_location, output: chroma,
            isJPEG: SoftwareVideoDecoder.isJPEGFormat(AVPixelFormat(rawValue: frame.pointee.format))) else {
            CVBufferRemoveAttachment(pb, kCVImageBufferChromaLocationTopFieldKey)
            CVBufferRemoveAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey)
            return
        }
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, location, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, location, .shouldPropagate)
    }

    /// The mastering display and content light level travel with the colour tags: the frame's own
    /// (bitstream SEI / AV1 metadata OBU) first, the container's declaration for what it lacks. A
    /// comparison per frame; the attached objects only change when the stream's metadata does.
    private func attachHDRStaticMetadata(from frame: UnsafeMutablePointer<AVFrame>, to pb: CVPixelBuffer) {
        let current = HDRStaticMetadata(frame: frame).filled(from: containerHDRStatic)
        if current != attachedHDRStatic { attachedHDRStatic = current }
        attachedHDRStatic.attach(to: pb)
    }
}
