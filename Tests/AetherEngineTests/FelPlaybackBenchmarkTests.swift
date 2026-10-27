// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

/// A FEL clip played through the overlay as the app plays it (``FelPlaybackBenchmark``). Not a test of speed: it prints
/// the overlay's log windows and only runs with `FEL_PLAYBACK_BENCH=1` and the FEL clips (`DV_FEL_TESTS_DIR`).
@Suite(.serialized)
struct FelPlaybackBenchmarkTests {

    static let enabled = ProcessInfo.processInfo.environment["FEL_PLAYBACK_BENCH"] == "1"
        && DoviFelRealFileTests.available("fel-clip-a.mkv")

    @Test("FEL playback through the overlay: per-frame stages, screen and drops", .enabled(if: enabled))
    @MainActor
    func playback() async {
        // The clip is 15 s: a short run that seeks back.
        let report = await FelPlaybackBenchmark.run(
            url: DoviFelRealFileTests.url("fel-clip-a.mkv"),
            scenario: .init(play: 5, pause: 1, afterPause: 2, seekBy: -6, afterSeek: 5))
        #expect(!report.contains("[bench] failed"))
        #expect(report.contains("overlay totals"))
    }
}
#endif
