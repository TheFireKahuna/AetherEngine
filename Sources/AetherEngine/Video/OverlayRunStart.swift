import Foundation
import QuartzCore
import os

/// Where an overlay's decode should be at the start of a producer run, before AVPlayer moves its clock, and the hold
/// that keeps the run's first segment from AVPlayer until the picture for that start is decoded.
///
/// AVPlayer prerolls its own decode and starts its clock as soon as it has a run's first segment, so a decoder it
/// does not own (the software overlay's, the FEL overlay's enhancement layer) is waited for there and only there;
/// after it the decoder only has to keep pace. Shared by ``OverlayDecodeTap`` and ``FelEnhancementTap``.
final class OverlayRunStart: @unchecked Sendable {
    /// A clock the player moved within this long is AVPlayer's; otherwise the producer's run start stands in for it.
    static let playerClockSeconds = 0.5
    /// A run whose start is this far from the clock is cut ahead of a playing clock: nothing waits for it.
    static let runStartNearClockSeconds = 1.0

    /// Where the current run starts (item seconds), the producer side's; the player's last clock move.
    private let clock = OSAllocatedUnfairLock(initialState: (runStart: Double?.none, playerMoved: -Double.infinity))

    /// A unit the producer kept, at `seconds` (item time). True when the decode should work toward it now: the unit
    /// opens a run (or is the session's first) and the player has not moved the clock lately.
    func noteUnit(at seconds: Double, opensRun: Bool) -> Bool {
        clock.withLock { state -> Bool in
            guard opensRun || state.runStart == nil else { return false }
            state.runStart = seconds
            return CACurrentMediaTime() - state.playerMoved > Self.playerClockSeconds
        }
    }

    /// AVPlayer moved its clock.
    func notePlayerMoved() {
        clock.withLock { $0.playerMoved = CACurrentMediaTime() }
    }

    /// Blocks until `hasPicture(runStart)` holds, when the clock (`clockSeconds`) is at or heading for the current
    /// run's start. True when the picture is there or nothing needs to wait; false after `timeout` or once
    /// `shouldStop` says so.
    func awaitPicture(clockSeconds: Double, timeout: TimeInterval, hasPicture: (Double) -> Bool,
                      shouldStop: () -> Bool) -> Bool {
        guard let start = clock.withLock({ $0.runStart }),
              abs(clockSeconds - start) < Self.runStartNearClockSeconds else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !hasPicture(start) {
            if shouldStop() || Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return true
    }
}
