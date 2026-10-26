// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

/// GPU cost of each composition kernel at UHD (``FelComposerBenchmark``). Not a test of speed: it prints the `[bench]`
/// lines and only runs with `DOVI_BENCH=1`; every variant that is a composition must match the baseline bit for bit.
@Suite(.serialized, .offCooperativePoolOneLane)
struct DoviGpuBenchmark {

    static let enabled = ProcessInfo.processInfo.environment["DOVI_BENCH"] == "1"

    @Test("UHD composition GPU time per kernel", .enabled(if: enabled, "set DOVI_BENCH=1"))
    func uhdKernelTimes() {
        let report = FelComposerBenchmark.run()
        #expect(!report.contains("[bench] failed"))
        #expect(!report.contains("DIFFERS"), "a composition variant differs from the baseline")
    }

    /// The composition's kernels one at a time, for a GPU counter recording (``FelComposerBenchmark/profile(emit:)``):
    /// only with `DOVI_PROFILE=1`.
    @Test("composition kernels run one at a time for a GPU counter recording",
          .enabled(if: ProcessInfo.processInfo.environment["DOVI_PROFILE"] == "1", "set DOVI_PROFILE=1"))
    func profileStretches() {
        #expect(!FelComposerBenchmark.profile().contains("[profile] failed"))
    }
}
#endif
