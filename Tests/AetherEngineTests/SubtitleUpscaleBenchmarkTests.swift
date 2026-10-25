import Testing
import Foundation
@testable import AetherEngine

/// GPU time of the subtitle upscaler per picture (``SubtitleUpscaler/benchmark(iterations:batch:)``, the same
/// numbers a probe app gets on a device). Not a test: it asserts nothing and only runs with `SUBTITLE_UPSCALE_BENCH=1`.
@Suite(.serialized)
struct SubtitleUpscaleBenchmarkTests {
    static let enabled = ProcessInfo.processInfo.environment["SUBTITLE_UPSCALE_BENCH"] == "1"

    @Test("steady-state GPU time per picture", .enabled(if: enabled))
    func benchmark() {
        print(SubtitleUpscaler.benchmark())
    }
}
