import Testing
import CoreVideo
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// The deinterlacer on display buffers: yadif_videotoolbox takes the buffers the finisher writes and
/// makes its output with the same attributes (FFmpegBuild's `pixel_buffer_attributes` patch), so
/// what it puts out is displayed as it comes, and mode=send_field doubles the cadence on the sink's
/// time_base.
///
/// Reported as skipped (not passed) on a machine with no Metal device (CI VMs).
struct DeinterlaceHardwareTests {

    /// Every format the finisher writes.
    static let displayFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange,
    ]

    @Test("every display format goes through and comes out in its own format, size and range",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware),
          arguments: DeinterlaceHardwareTests.displayFormats)
    func displayFormatsPassThrough(_ type: OSType) throws {
        let filter = DeinterlaceFilter()
        defer { filter.teardown() }
        var types = Set<OSType>()
        var sizes = Set<[Int]>()
        let run = DeinterlaceTestInput.run(filter, count: 8, make: { DeinterlaceTestInput.buffer(type) }, onFrame: { out in
            guard let pb = DeinterlaceTestInput.pixelBuffer(of: out) else {
                Issue.record("output is not a VideoToolbox frame")
                return
            }
            types.insert(CVPixelBufferGetPixelFormatType(pb))
            sizes.insert([CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb)])
            #expect(CVPixelBufferGetIOSurface(pb) != nil)
        })
        #expect(run.built)
        #expect(!run.seconds.isEmpty)
        #expect(types == [type], "surfaces: \(types.map { String($0, radix: 16) })")
        #expect(sizes == [[64, 64]])
    }

    @Test("the output carries the attachments of the buffer it was made from",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func attachmentsPropagate() {
        let filter = DeinterlaceFilter()
        defer { filter.teardown() }
        var inputs: [CVPixelBuffer] = []
        var outputs = 0
        let run = DeinterlaceTestInput.run(filter, count: 8, make: {
            guard let pb = DeinterlaceTestInput.buffer() else { return nil }
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            inputs.append(pb)
            return pb
        }, onFrame: { out in
            guard let pb = DeinterlaceTestInput.pixelBuffer(of: out) else { return }
            outputs += 1
            #expect(!inputs.contains { $0 === pb }, "an interlaced picture comes out in a buffer of the filter's own")
            let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
            #expect(matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        })
        #expect(run.built)
        #expect(outputs > 0)
    }

    @Test("send_field doubles output cadence; send_frame keeps it",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func fieldRateControlsCadence() {
        let streamTBSeconds = 1.0 / 30.0
        let fieldFilter = DeinterlaceFilter()
        fieldFilter.config = DeinterlaceConfig(fieldRate: .field)
        let frameFilter = DeinterlaceFilter()
        frameFilter.config = DeinterlaceConfig(fieldRate: .frame)
        defer { fieldFilter.teardown(); frameFilter.teardown() }
        let field = DeinterlaceTestInput.run(fieldFilter, count: 8)
        let frame = DeinterlaceTestInput.run(frameFilter, count: 8)
        #expect(field.built && frame.built)

        // Field rate must produce ~2x the frames of frame rate (lookahead trims the tails).
        #expect(field.seconds.count > frame.seconds.count + 2,
                "send_field produced \(field.seconds.count) vs send_frame \(frame.seconds.count)")

        // Distinct, monotonic timestamps at ~half the frame interval: the send_field PTS
        // regression collapsed field pairs onto duplicate timestamps.
        let sorted = field.seconds.sorted()
        #expect(sorted == field.seconds, "field PTS must be monotonic")
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
        for s in field.seconds + frame.seconds {
            #expect(s <= maxInput + streamTBSeconds, "output PTS \(s)s exceeds source range (\(maxInput)s)")
        }
    }

    @Test("a progressive picture passes through as the buffer it came in",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func progressivePassesThrough() throws {
        let filter = DeinterlaceFilter()
        defer { filter.teardown() }
        // The graph engages on an interlaced picture; the progressive ones after it pass through.
        let first = try #require(DeinterlaceTestInput.buffer())
        var f: UnsafeMutablePointer<AVFrame>? = DeinterlaceTestInput.properties(pts: 0)
        defer { av_frame_free(&f) }
        try #require(filter.ensureGraph(buffer: first, properties: f!, timeBase: AVRational(num: 1, den: 30)))
        #expect(filter.push(first, properties: f!) >= 0)

        var progressive: [CVPixelBuffer] = []
        var passed = 0
        let out = av_frame_alloc()!
        defer { var o: UnsafeMutablePointer<AVFrame>? = out; av_frame_free(&o) }
        for pts in Int64(1)..<6 {
            let pb = try #require(DeinterlaceTestInput.buffer())
            progressive.append(pb)
            f!.pointee.pts = pts
            f!.pointee.flags &= ~(AV_FRAME_FLAG_INTERLACED | AV_FRAME_FLAG_TOP_FIELD_FIRST)
            #expect(filter.push(pb, properties: f!) >= 0)
            while filter.pull(into: out) >= 0 {
                if let outPB = DeinterlaceTestInput.pixelBuffer(of: out), progressive.contains(where: { $0 === outPB }) {
                    passed += 1
                }
                av_frame_unref(out)
            }
        }
        #expect(passed > 0, "progressive pictures came out in buffers of their own")
    }

    @Test("warm-up releases its temporary graph and a fresh graph remains usable",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func warmupLeavesFreshGraphUsable() {
        #expect(DeinterlaceFilter.prewarmHardwarePipeline())
        let filter = DeinterlaceFilter()
        defer { filter.teardown() }
        let run = DeinterlaceTestInput.run(filter, count: 8)
        #expect(run.built)
        #expect(!run.seconds.isEmpty)
    }
}
