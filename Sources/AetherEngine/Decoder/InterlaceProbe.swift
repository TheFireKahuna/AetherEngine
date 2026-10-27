import Foundation
import Metal
import LibDeinterlace
import AetherLibavcodec
import AetherLibavutil

/// #232: verifies a DECLARED interlaced H.264 stream against what the decoder actually emits.
///
/// The declaration and the decoder disagree systematically on progressive-in-interlaced-carriage
/// (PsF). Blu-ray has no 1080p25, so European 25 fps masters ship as 1080i25: interlaced carriage,
/// progressive pictures. FFmpeg then answers the same SEI two different ways:
///
/// - `h264_parser.c` (feeds `codecpar.field_order`, which is what the routing rule reads) sets
///   `AV_FIELD_TT` for a FRAME-coded picture on SEI `pic_struct == TOP_BOTTOM` alone. It weighs
///   neither `ct_type` nor how the slices were actually coded.
/// - `h264_slice.c` (feeds `AV_FRAME_FLAG_INTERLACED`) flags that same picture only when it is
///   field- or MBAFF-coded, and a `clock_timestamp` carrying `ct_type` overrides even that.
///
/// So the routing rule consumes the structurally less informed of the two values.
///
/// The probe deliberately does NOT try to answer "is this content progressive". It answers the
/// narrower question the routing rule actually rests on: WILL THE DEINTERLACER EVER ENGAGE.
/// `SoftwareVideoDecoder` engages it on `AV_FRAME_FLAG_INTERLACED` and on nothing else, so a
/// sample in which that flag never appears proves the software detour is a no-op for this stream:
/// what plays today is already the un-deinterlaced picture, and the native path renders the same
/// frames with hardware decode.
///
/// Because the probe's predicate IS the engagement predicate, its false positives are harmless by
/// construction. A stream whose first frame is flagged only because of libavcodec's
/// `prev_interlaced_frame = 1` decoder-init bias (h264_slice.c, the pic_struct=3 without ct_type
/// case) is exactly the stream on which the real software path would engage the deinterlacer at
/// that same frame and latch it. Reporting "interlaced" there is not a miss, it is agreement with
/// the runtime.
enum InterlaceProbe {

    enum Verdict: Equatable {
        /// A decoded frame carried `AV_FRAME_FLAG_INTERLACED`: the declaration holds, keep software.
        case interlaced(afterFrames: Int)
        /// The sample decoded and no frame was flagged: the deinterlacer would never engage.
        case progressive(framesDecoded: Int)
        /// Too little evidence to overrule the declaration (open failed, read error, short sample).
        case inconclusive(reason: String)
    }

    /// Decoded frames that end a clean sample. ~1.5 s at 25 fps, past the first GOP on broadcast
    /// and Blu-ray GOP lengths, so a sample is never confined to one intra period.
    static let sampleFrameTarget = 40
    /// Below this the sample is not evidence; a truncated read must not hand a stream to the
    /// native path on two frames of luck.
    static let minimumFrames = 12
    /// Packet ceiling, so a stream with a long non-video packet run cannot spin here.
    static let packetBudget = 600
    /// Wall-clock ceiling for the whole sample. Expiry yields `.inconclusive`, i.e. today's routing.
    static let wallClockBudget: TimeInterval = 3.0

    /// True when the verdict is strong enough to overrule a declared interlaced field order.
    static func refutesDeclaredInterlace(_ verdict: Verdict) -> Bool {
        if case .progressive = verdict { return true }
        return false
    }

    /// Decode a sample from `demuxer`'s video stream and report whether any frame is flagged
    /// interlaced. Reads packets, so it MOVES the demuxer's read position; callers that keep
    /// using the demuxer must reposition afterwards (`AetherEngine.load` seeks back to the head).
    ///
    /// No read deadline is armed here. `AVIOReader`'s deadline state is documented demux-thread-only
    /// and the session demuxer runs with prefetch enabled, so arming it from the load path would
    /// race the prefetch thread. The packet, frame, and wall-clock budgets bound the sample instead,
    /// and a stalled read is bounded by the same reader timeout the first playback read would hit.
    static func run(
        demuxer: Demuxer,
        streamIndex: Int32,
        sampleFrameTarget: Int = InterlaceProbe.sampleFrameTarget,
        minimumFrames: Int = InterlaceProbe.minimumFrames,
        packetBudget: Int = InterlaceProbe.packetBudget,
        wallClockBudget: TimeInterval = InterlaceProbe.wallClockBudget
    ) -> Verdict {
        var flaggedAt: Int?
        let sample = decodeSample(demuxer: demuxer, streamIndex: streamIndex, frameTarget: sampleFrameTarget,
                                  packetBudget: packetBudget, wallClockBudget: wallClockBudget) { frame, count, _ in
            guard frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0 else { return true }
            flaggedAt = count
            return false
        }
        if let flaggedAt { return .interlaced(afterFrames: flaggedAt) }
        if let failure = sample.failure { return .inconclusive(reason: failure) }
        guard sample.frames >= minimumFrames else {
            return .inconclusive(reason: "only \(sample.frames) frame(s) decoded")
        }
        return .progressive(framesDecoded: sample.frames)
    }

    /// Soft telecine (docs/software-route-gpu.md 6.1): the film rate when the sample is a film run, that is when
    /// ``FilmCadence`` has the sample's last picture on its grid and re-timed at least `minimumFrames` of them; nil
    /// otherwise. The rate is 4/5 of the decoder's carriage rate (24000/1001 from 30000/1001). Moves the demuxer's read
    /// position, as ``run(demuxer:streamIndex:sampleFrameTarget:minimumFrames:packetBudget:wallClockBudget:)`` does.
    static func filmRate(
        demuxer: Demuxer,
        streamIndex: Int32,
        sampleFrameTarget: Int = InterlaceProbe.sampleFrameTarget,
        minimumFrames: Int = InterlaceProbe.minimumFrames,
        packetBudget: Int = InterlaceProbe.packetBudget,
        wallClockBudget: TimeInterval = InterlaceProbe.wallClockBudget
    ) -> AVRational? {
        guard let stream = demuxer.stream(at: streamIndex) else { return nil }
        let cadence = FilmCadence(timeBase: stream.pointee.time_base)
        var retimed = 0
        var carriage = AVRational(num: 0, den: 1)
        let sample = decodeSample(demuxer: demuxer, streamIndex: streamIndex, frameTarget: sampleFrameTarget,
                                  packetBudget: packetBudget, wallClockBudget: wallClockBudget) { frame, _, ctx in
            carriage = ctx.pointee.framerate
            _ = cadence.retime(pts: frame.pointee.best_effort_timestamp, interlaced: frame.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0,
                               repeatPict: frame.pointee.repeat_pict, carriage: carriage)
            if cadence.isActive { retimed += 1 }
            return true
        }
        guard sample.failure == nil, cadence.isActive, retimed >= minimumFrames, carriage.num > 0, carriage.den > 0 else {
            return nil
        }
        var num: Int32 = 0, den: Int32 = 0
        av_reduce(&num, &den, Int64(carriage.num) * 4, Int64(carriage.den) * 5, Int64(Int32.max))
        return AVRational(num: num, den: den)
    }

    /// Film in interlaced carriage (docs/software-route-gpu.md 6.4): decodes a sample, holds its pictures in slabs and
    /// classifies them (``classifyFilm(_:submission:allocator:format:width:height:timeBase:frameRate:)``). Nil for video, a
    /// format inverse telecine does not take, a short sample or no Metal device. Moves the demuxer's read position.
    static func filmCarriage(
        demuxer: Demuxer,
        streamIndex: Int32,
        sampleFrameTarget: Int = InterlaceProbe.sampleFrameTarget,
        packetBudget: Int = InterlaceProbe.packetBudget,
        wallClockBudget: TimeInterval = InterlaceProbe.wallClockBudget
    ) -> FilmCarriage? {
        var pictures: [BwdifWindow.Picture] = []
        var shape: (format: AVPixelFormat, width: Int, height: Int)?
        var carriage = AVRational(num: 0, den: 1)
        let sample = decodeSample(demuxer: demuxer, streamIndex: streamIndex, frameTarget: sampleFrameTarget,
                                  packetBudget: packetBudget, wallClockBudget: wallClockBudget, pixelsMatter: true) { frame, _, ctx in
            carriage = ctx.pointee.framerate
            let current = (AVPixelFormat(rawValue: frame.pointee.format), Int(frame.pointee.width), Int(frame.pointee.height))
            if let shape, shape != current { return false }
            shape = current
            guard let copy = allocator.copy(frame), let held = av_frame_clone(frame) else { return false }
            let storage = BwdifWindow.Storage(frame: held, planes: copy.planes, release: { allocator.release(copy.slab) })
            pictures.append(BwdifWindow.Picture(storage: storage, pts: frame.pointee.best_effort_timestamp))
            return true
        }
        guard sample.failure == nil, let shape, carriage.num > 0, carriage.den > 0 else { return nil }
        return classifyFilm(pictures, submission: DeinterlaceGPU(submitter), allocator: allocator, format: shape.format, width: shape.width,
                            height: shape.height, timeBase: stream.pointee.time_base, frameRate: carriage)
    }

    /// The verdict on a decoded sample (docs/software-route-gpu.md 6.4), from fieldmatch's own notion of a combed picture
    /// (calc_combed_score at least `combpel`): no picture combed and the pictures flagged interlaced is 2:2; combed
    /// pictures that the matcher makes progressive, with a duplicate in every full cycle of five, is 3:2; anything else
    /// is video (nil). Needs three cycles of pictures.
    static func classifyFilm(_ pictures: [BwdifWindow.Picture], submission: DeinterlaceGPU, allocator: DecodeFrameAllocator,
                             format: AVPixelFormat, width: Int, height: Int, timeBase: AVRational,
                             frameRate: AVRational) -> FilmCarriage? {
        guard pictures.count >= 15, InverseTelecine.takes(format: format, width: width, height: height),
              let layout = PictureLayout(format: format) else { return nil }
        let kernels = DeinterlaceKernels(submission: submission)
        func combed(_ p: PlaneSet) -> Bool {
            (kernels.combScore(src: p, other: p, srcParity: 0, layout: layout, width: width, height: height,
                               cthresh: InverseTelecine.cthresh) ?? Int.max) >= InverseTelecine.combpel
        }
        if !pictures.contains(where: { combed($0.storage.planes) }) {
            return pictures.allSatisfy(\.interlaced) ? .segmented22 : nil
        }
        guard let chain = InverseTelecine(kernels: kernels, makePicture: SoftwareVideoDecoder.slabMaker(allocator), format: format,
                                          width: width, height: height, timeBase: timeBase, frameRate: frameRate) else { return nil }
        // The sample through the chain, a batch a picture, waited for once: the decisions are read back at the end.
        var outputs: [InverseTelecine.Output] = []
        var held: [BwdifWindow.Picture] = []
        let done = DispatchGroup()
        for p in pictures {
            outputs += pushed.outputs
            held += pushed.touched
            done.enter()
            batch.commit { _ in done.leave() }
        }
        done.wait()
        withExtendedLifetime(held) {}
        let out = outputs.filter { chain.resolve($0) != nil }
        let cycles = chain.cycles, duplicates = chain.cyclesWithDuplicate
        let stillCombed = out.filter { combed(chain.shown($0).storage.planes) }.count
        if cycles >= 2, duplicates == cycles, stillCombed * 10 <= out.count { return .pulldown32 }
        return nil
    }

    /// Decodes up to `frameTarget` pictures of `streamIndex` in software, handing each to `onFrame` with the count so
    /// far and the codec context; `onFrame` returns false to stop. `failure` names why nothing could be decoded.
    private static func decodeSample(
        demuxer: Demuxer,
        streamIndex: Int32,
        frameTarget: Int,
        packetBudget: Int,
        wallClockBudget: TimeInterval,
        pixelsMatter: Bool = false,
        onFrame: (UnsafeMutablePointer<AVFrame>, Int, UnsafeMutablePointer<AVCodecContext>) -> Bool
    ) -> (frames: Int, failure: String?) {
        guard streamIndex >= 0, let stream = demuxer.stream(at: streamIndex),
              let codecpar = stream.pointee.codecpar else {
            return (0, "no video stream")
        }
        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id),
              let ctx = avcodec_alloc_context3(codec) else {
            return (0, "no decoder")
        }
        var ownedCtx: UnsafeMutablePointer<AVCodecContext>? = ctx
        defer { avcodec_free_context(&ownedCtx) }

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            return (0, "parameters_to_context failed")
        }
        // Software decode only: the frame flags are what is being measured, and a hwaccel surface
        // adds nothing to that. Mirrors SoftwareVideoDecoder.open's get_format rejection.
        ctx.pointee.get_format = { _, fmts in
            guard let fmts = fmts else { return AV_PIX_FMT_NONE }
            var i = 0
            while fmts[i] != AV_PIX_FMT_NONE {
                if fmts[i] != AV_PIX_FMT_VIDEOTOOLBOX { return fmts[i] }
                i += 1
            }
            return AV_PIX_FMT_YUV420P
        }
        // A sample read for its per-frame flags skips deblocking, which touches none of them: the one cheap win
        // that cannot change the answer. A sample whose pixels are measured decodes them in full.
        if !pixelsMatter { ctx.pointee.skip_loop_filter = AVDISCARD_ALL }
        ctx.pointee.thread_count = Int32(min(4, ProcessInfo.processInfo.activeProcessorCount))
        ctx.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE

        var opts: OpaquePointer?
        av_dict_set(&opts, "hwaccel", "none", 0)
        let openRet = avcodec_open2(ctx, codec, &opts)
        av_dict_free(&opts)
        guard openRet >= 0 else {
            return (0, "decoder open failed (\(openRet))")
        }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard let f = frame else { return (0, "frame alloc failed") }
        defer { av_frame_free(&frame) }

        var framesDecoded = 0
        var packetsRead = 0
        var stopped = false
        let deadline = Date(timeIntervalSinceNow: wallClockBudget)

        func drain() {
            while !stopped, avcodec_receive_frame(ctx, f) >= 0 {
                framesDecoded += 1
                if !onFrame(f, framesDecoded, ctx) { stopped = true }
                av_frame_unref(f)
            }
        }

        while !stopped, framesDecoded < frameTarget, packetsRead < packetBudget, Date() < deadline {
            let packet: UnsafeMutablePointer<AVPacket>?
            do {
                packet = try demuxer.readPacket()
            } catch {
                break  // read error: whatever was decoded so far still counts
            }
            guard let packet else { break }  // EOF
            packetsRead += 1
            defer {
                av_packet_unref(packet)
                av_packet_free_safe(packet)  // demuxer allocs tracked; free must stay on the tracker
            }
            guard packet.pointee.stream_index == streamIndex else { continue }
            if avcodec_send_packet(ctx, packet) == FFmpegErr.eagain {
                drain()
                _ = avcodec_send_packet(ctx, packet)
            }
            drain()
        }

        // Flush: frame threading holds several frames back, and on a short sample those are a
        // meaningful part of the evidence.
        if !stopped {
            _ = avcodec_send_packet(ctx, nil)
            drain()
        }
        return (framesDecoded, nil)
    }
}
