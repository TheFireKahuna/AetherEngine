import Foundation
import Testing
@testable import AetherEngine

/// A renderer that stays failed gets one reposition to the playhead, the documented reset of a failed renderer; a
/// second failure inside the window means the reset does not hold, and the session fails where the host can see it.
@Suite("Software host renderer failure policy")
struct RendererFailurePolicyTests {
    @Test("the first failure repositions, a second inside the window fails the session, a later one repositions")
    func policy() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        #expect(SoftwarePlaybackHost.rendererFailureAction(now: t0, lastRecovery: nil) == .reposition)
        #expect(SoftwarePlaybackHost.rendererFailureAction(now: t0.addingTimeInterval(5), lastRecovery: t0) == .fail)
        #expect(SoftwarePlaybackHost.rendererFailureAction(
            now: t0.addingTimeInterval(SoftwarePlaybackHost.rendererRecoveryWindow + 1), lastRecovery: t0) == .reposition)
    }
}
