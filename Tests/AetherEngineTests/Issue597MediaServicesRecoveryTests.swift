import Foundation
import AVFoundation
import Testing
@testable import AetherEngine

/// AE#597 round 2: a media services reset is answered when it happens. The session is declared again, an open
/// foreground session is rebuilt at its position, a load in flight is rebuilt when it exits, and anything else waits
/// for the next load. While the server is lost or being recovered, the failures its objects report are its symptoms.
@Suite("Media services recovery (AE#597)", .serialized)
struct Issue597MediaServicesRecoveryTests {

    @Test("an open foreground session is rebuilt now, a load in flight when it exits, anything else by the next load")
    func actionMatrix() {
        typealias E = AetherEngine
        #expect(E.mediaServicesRecoveryAction(sessionOpen: true, backgrounded: false, loadInFlight: false) == .rebuildNow)
        #expect(E.mediaServicesRecoveryAction(sessionOpen: true, backgrounded: false, loadInFlight: true) == .rebuildAfterLoad)
        #expect(E.mediaServicesRecoveryAction(sessionOpen: false, backgrounded: false, loadInFlight: true) == .rebuildAfterLoad)
        #expect(E.mediaServicesRecoveryAction(sessionOpen: true, backgrounded: true, loadInFlight: false) == .nextLoad)
        #expect(E.mediaServicesRecoveryAction(sessionOpen: true, backgrounded: true, loadInFlight: true) == .nextLoad)
        #expect(E.mediaServicesRecoveryAction(sessionOpen: false, backgrounded: false, loadInFlight: false) == .nextLoad)
    }

    @Test("failures are the reset's symptoms while it is pending, briefly after it, and while the server is lost, not forever")
    func coverage() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
        typealias E = AetherEngine
        #expect(!E.mediaServicesRecoveryCovers(now: t0, lostAt: nil, lastReset: nil, recoveryPending: false))
        #expect(E.mediaServicesRecoveryCovers(now: t0, lostAt: nil, lastReset: nil, recoveryPending: true))
        #expect(E.mediaServicesRecoveryCovers(now: t0.addingTimeInterval(3), lostAt: t0, lastReset: nil, recoveryPending: false))
        #expect(!E.mediaServicesRecoveryCovers(now: t0.addingTimeInterval(E.mediaServicesLostWindow + 1), lostAt: t0,
                                               lastReset: nil, recoveryPending: false),
                "a lost server whose reset never comes stops swallowing failures")
        #expect(E.mediaServicesRecoveryCovers(now: t0.addingTimeInterval(1), lostAt: nil, lastReset: t0, recoveryPending: false))
        #expect(!E.mediaServicesRecoveryCovers(now: t0.addingTimeInterval(E.mediaServicesResetEchoWindow + 1), lostAt: nil,
                                               lastReset: t0, recoveryPending: false))
    }

    @Test("only AVFoundation's -11819 reads as a media services reset")
    func resetErrorIdentity() {
        let reset = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x", underlyingDomain: AVFoundationErrorDomain,
                                      underlyingCode: -11819)
        let other = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x", underlyingDomain: AVFoundationErrorDomain,
                                      underlyingCode: -11800)
        let elsewhere = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x", underlyingDomain: NSURLErrorDomain,
                                          underlyingCode: -11819)
        #expect(AetherEngine.isMediaServicesResetError(reset))
        #expect(!AetherEngine.isMediaServicesResetError(other))
        #expect(!AetherEngine.isMediaServicesResetError(elsewhere))
    }

    @MainActor
    @Test("with nothing open the reset is left to the next load, as before")
    func idleResetWaitsForTheNextLoad() throws {
        let engine = try AetherEngine()
        engine.noteMediaServicesReset(lost: false)
        #expect(!engine.mediaServicesRecoveryOwed)
        #expect(!engine.mediaServicesRebuildInFlight)
        #expect(engine.errorInfo == nil)
        #expect(engine.consumeMediaServicesReset())
    }

    @MainActor
    @Test("a renderer failing while the server is lost takes no ladder step")
    func lostServerHoldsTheLadder() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.noteMediaServicesReset(lost: true)
        engine.climbRendererRecovery(.audio, error: "test")
        engine.climbRendererRecovery(.audio, error: "test")
        #expect(engine.errorInfo == nil)
        #expect(engine.rendererRecoveryLadder.next(at: Date()) == .reposition, "no step was taken")
    }

    @MainActor
    @Test("a -11819 no reset follows is published after the grace, and any other failure is not taken over")
    func unaccompaniedResetErrorIsPublished() async throws {
        let engine = try AetherEngine()
        let reset = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x", underlyingDomain: AVFoundationErrorDomain,
                                      underlyingCode: -11819)
        var published: [PlaybackErrorInfo] = []
        #expect(engine.takeOverMediaServicesResetFailure(reset) { published.append($0) })
        #expect(published.isEmpty)
        #expect(try await waitFor(upTo: .seconds(5)) { published.count == 1 })
        let other = PlaybackErrorInfo(kind: .nativeItemFailed, message: "y")
        #expect(!engine.takeOverMediaServicesResetFailure(other) { published.append($0) })
    }

    @MainActor
    @Test("a -11819 the reset accompanies is left to the recovery")
    func accompaniedResetErrorIsTakenOver() async throws {
        let engine = try AetherEngine()
        engine.noteMediaServicesReset(lost: false)
        let reset = PlaybackErrorInfo(kind: .nativeItemFailed, message: "x", underlyingDomain: AVFoundationErrorDomain,
                                      underlyingCode: -11819)
        var published: [PlaybackErrorInfo] = []
        #expect(engine.takeOverMediaServicesResetFailure(reset) { published.append($0) })
        try await Task.sleep(for: .seconds(2.5))
        #expect(published.isEmpty)
    }
}
