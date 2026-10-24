import Testing
import AetherLibavutil
import AetherLibavfilter
@testable import AetherEngine

/// Regression: bwdif/yadif halve the filter output time_base and double PTS. The filter exposes
/// that sink time_base as `outputTimeBase` and the decoder timestamps filtered frames with it
/// (rescaling back into the stream base is WRONG under mode=send_field: the two fields of a frame
/// sit on odd/even ticks of the halved base and would collapse to duplicate integer PTS).
/// This test pins the invariant that output PTS converted through `outputTimeBase` lands on the
/// source's real-time axis, the original bug was playback at half speed + resume freezes.
struct DeinterlaceTimebaseTests {

    @Test("Deinterlaced PTS via outputTimeBase stays on the stream's time axis (no 2x drift)",
          .enabled(if: DeinterlaceTestInput.available, DeinterlaceTestInput.needsHardware))
    func deinterlacedPTSMatchesStreamTimebase() {
        // 1 tick == 1/30 s; source PTS N must emerge at N/30 seconds when converted through
        // the filter's outputTimeBase (NOT the stream time_base, the filter halves it).
        let tbSeconds = 1.0 / 30.0
        let filter = DeinterlaceFilter()
        filter.config = DeinterlaceConfig(fieldRate: .frame)
        defer { filter.teardown() }

        let run = DeinterlaceTestInput.run(filter, count: 8)
        #expect(run.built)
        #expect(!run.seconds.isEmpty, "filter produced no frames")

        // Pre-fix outputs ran to ~14/30 s (2x). Deinterlacer holds one frame of lookahead.
        let maxInput = 7.0 * tbSeconds
        for s in run.seconds {
            #expect(s <= maxInput + tbSeconds * 0.5,
                    "output PTS \(s)s exceeds source range (max \(maxInput)s), time_base drift")
        }

        // send_frame: one output per input, so spacing stays at the frame interval.
        let sorted = run.seconds.sorted()
        if sorted.count >= 2 {
            for i in 1..<sorted.count {
                let delta = sorted[i] - sorted[i - 1]
                #expect(abs(delta - tbSeconds) < tbSeconds * 0.25,
                        "frame spacing \(delta)s is not ~\(tbSeconds)s (time_base drift)")
            }
        }
    }
}
