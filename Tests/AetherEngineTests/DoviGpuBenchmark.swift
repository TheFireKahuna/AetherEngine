// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

@Suite(.serialized, .offCooperativePoolOneLane)
struct DoviGpuBenchmark {

    static let enabled = ProcessInfo.processInfo.environment["DOVI_BENCH"] == "1"

    @Test("UHD composition GPU time per kernel", .enabled(if: enabled, "set DOVI_BENCH=1"))

    /// only with `DOVI_PROFILE=1`.
    @Test("composition kernels run one at a time for a GPU counter recording",
          .enabled(if: ProcessInfo.processInfo.environment["DOVI_PROFILE"] == "1", "set DOVI_PROFILE=1"))
}
#endif
