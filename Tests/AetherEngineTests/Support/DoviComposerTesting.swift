#if DualLayerDolbyVision
@testable import AetherEngine

extension DoviFelComposer {
    /// A composer pinned to the 4:2:0 P010 path, bit-exact with Dolby's reference, whatever the process
    /// default (`sv22` since the on-device 12-bit result). The GPU math tests check that reference path.
    static func p010ForTesting() -> DoviFelComposer? {
        let composer = DoviFelComposer()
        composer?.outputModeOverride = .p010
        return composer
    }
}
#endif
