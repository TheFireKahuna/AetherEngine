import Testing
import CoreVideo
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// yadif_videotoolbox hardware path (FFmpegBuild >= 2.1): the graph engages, emits
/// AV_PIX_FMT_VIDEOTOOLBOX frames wrapping CVPixelBuffers, and mode=send_field doubles the
/// output cadence on the sink's time_base.
///
/// The three tests are reported as skipped (not passed) when the linked build has no
/// yadif_videotoolbox or the machine has no Metal device (CI VMs): the engine then falls back to
/// .software, and the fallback itself is covered by the software tests.
struct DeinterlaceHardwareTests {

    /// Built once: the probe stands up and tears down a whole filter graph.
    private static let hardwareAvailable = DeinterlaceFilter.prewarmHardwarePipeline()
    private static let needsHardware: Comment = "needs yadif_videotoolbox and a Metal device"

    private func makeFrame(pts: Int64, format: AVPixelFormat = AV_PIX_FMT_YUV420P) -> UnsafeMutablePointer<AVFrame> {
        let f = av_frame_alloc()!
        f.pointee.width = 64
        f.pointee.height = 64
        f.pointee.format = format.rawValue
        f.pointee.pts = pts
        f.pointee.flags |= (1 << 3)  // AV_FRAME_FLAG_INTERLACED
        _ = av_frame_get_buffer(f, 0)
        return f
    }

    /// Run `count` frames through a filter with the given field rate; returns output seconds
    /// (converted via outputTimeBase) and whether the hw engine engaged.
    private func run(
        fieldRate: DeinterlaceFieldRate,
        count: Int64,
        format: AVPixelFormat = AV_PIX_FMT_YUV420P,
        onFrame: ((UnsafeMutablePointer<AVFrame>) -> Void)? = nil
    ) -> (seconds: [Double], hardware: Bool) {
        let streamTB = AVRational(num: 1, den: 30)
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(mode: .auto, fieldRate: fieldRate)
        defer { filter.teardown() }

        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }

        var seconds: [Double] = []
        var hardware = false
        for pts in Int64(0)..<count {
            let f = makeFrame(pts: pts, format: format)
            guard filter.ensureGraph(frame: f, timeBase: streamTB) else {
                var ff: UnsafeMutablePointer<AVFrame>? = f
                av_frame_free(&ff)
                return ([], false)
            }
            hardware = filter.engine == .hardware
            guard hardware else {
                var ff: UnsafeMutablePointer<AVFrame>? = f
                av_frame_free(&ff)
                return ([], false)
            }

            #expect(filter.push(f) >= 0)
            var ff: UnsafeMutablePointer<AVFrame>? = f
            av_frame_free(&ff)

            let outTB = filter.outputTimeBase
            let outTBSeconds = Double(outTB.num) / Double(outTB.den)
            while filter.pull(into: out) >= 0 {
                if out.pointee.pts != Int64.min {
                    seconds.append(Double(out.pointee.pts) * outTBSeconds)
                }
                onFrame?(out)
                av_frame_unref(out)
            }
        }
        return (seconds, hardware)
    }

    @Test("HW engine emits VideoToolbox frames wrapping CVPixelBuffers",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func hardwareEmitsVideoToolboxFrames() {
        var sawVTFrame = false
        let (seconds, hardware) = run(fieldRate: .field, count: 8) { out in
            #expect(out.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue,
                    "hw sink must emit AV_PIX_FMT_VIDEOTOOLBOX frames")
            if let raw = out.pointee.data.3 {
                sawVTFrame = true
                let pb = Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()
                // The renderer path relies on displayable bi-planar buffers straight from the pool.
                let fmt = CVPixelBufferGetPixelFormatType(pb)
                #expect(fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                        || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        "expected NV12-class pixel buffer, got 0x\(String(fmt, radix: 16))")
                #expect(CVPixelBufferGetWidth(pb) == 64 && CVPixelBufferGetHeight(pb) == 64)
            } else {
                Issue.record("AV_PIX_FMT_VIDEOTOOLBOX frame with nil data[3]")
            }
        }
        #expect(hardware)
        #expect(sawVTFrame, "hw graph engaged but produced no frames")
        #expect(!seconds.isEmpty)
    }

    /// #7: interlaced 4:2:2 is uploaded as 4:2:2, so the deinterlacer sees each field's own chroma
    /// lines instead of a 4:2:0 downsample that already mixed the two fields.
    @Test("interlaced 4:2:2 stays 4:2:2 through the hardware chain", arguments: [
        (AV_PIX_FMT_YUV422P, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
        (AV_PIX_FMT_YUV422P10LE, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
    ])
    func fourTwoTwoStaysFourTwoTwo(_ format: AVPixelFormat, _ expected: OSType) throws {
        try #require(DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware)
        var types = Set<OSType>()
        let (seconds, hardware) = run(fieldRate: .field, count: 8, format: format) { out in
            if let raw = out.pointee.data.3 {
                types.insert(CVPixelBufferGetPixelFormatType(
                    Unmanaged<CVPixelBuffer>.fromOpaque(UnsafeRawPointer(raw)).takeUnretainedValue()))
            }
        }
        #expect(hardware)
        #expect(!seconds.isEmpty)
        #expect(types == [expected], "surfaces: \(types.map { String($0, radix: 16) })")
    }

    @Test("the upload layout keeps the decoder's subsampling")
    func uploadFormat() {
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV420P.rawValue) == "nv12")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV420P10LE.rawValue) == "p010le")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV420P12LE.rawValue) == "p010le")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV422P.rawValue) == "nv16")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV422P10LE.rawValue) == "p210le")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV422P12LE.rawValue) == "p216le")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV444P.rawValue) == "nv24")
        #expect(DeinterlaceFilter.uploadFormat(for: AV_PIX_FMT_YUV411P.rawValue) == "nv16")
    }

    @Test("send_field doubles output cadence; send_frame keeps it",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func fieldRateControlsCadence() {
        let streamTBSeconds = 1.0 / 30.0
        let (fieldSeconds, hwField) = run(fieldRate: .field, count: 8)
        let (frameSeconds, hwFrame) = run(fieldRate: .frame, count: 8)
        #expect(hwField && hwFrame)

        // Field rate must produce ~2x the frames of frame rate (lookahead trims the tails).
        #expect(fieldSeconds.count > frameSeconds.count + 2,
                "send_field produced \(fieldSeconds.count) vs send_frame \(frameSeconds.count)")

        // Distinct, monotonic timestamps at ~half the frame interval: the send_field PTS
        // regression collapsed field pairs onto duplicate timestamps.
        let sorted = fieldSeconds.sorted()
        #expect(sorted == fieldSeconds, "field PTS must be monotonic")
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(delta > 0, "duplicate field PTS at index \(i)")
                #expect(abs(delta - streamTBSeconds / 2) < streamTBSeconds * 0.2,
                        "field spacing \(delta)s is not ~\(streamTBSeconds / 2)s")
            }
        }

        // Both cadences stay on the source's real-time axis.
        let maxInput = 7.0 * streamTBSeconds
        for s in fieldSeconds + frameSeconds {
            #expect(s <= maxInput + streamTBSeconds,
                    "output PTS \(s)s exceeds source range (\(maxInput)s)")
        }
    }

    @Test("warm-up releases its temporary graph and a fresh hardware graph remains usable",
          .enabled(if: DeinterlaceHardwareTests.hardwareAvailable, DeinterlaceHardwareTests.needsHardware))
    func warmupLeavesFreshGraphUsable() {
        #expect(DeinterlaceFilter.prewarmHardwarePipeline())

        let (seconds, hardware) = run(fieldRate: .field, count: 8)
        #expect(hardware)
        #expect(!seconds.isEmpty)
    }
}
