import Foundation
import AVFoundation
import Testing
@testable import AetherEngine

/// A native seek lands while AVPlayer is still prerolling the new position. That tail is the seek's, so the
/// phase stays `.seeking` until the transport rolls, instead of reading `.rebuffering` (which made a host's
/// rebuffer backdrop fade to black and back after every seek).
@Suite("Native seek settle")
@MainActor
struct NativeSeekSettleTests {

    @Test("a landing that is still prerolling reads as the seek, not a rebuffer")
    func settlingReadsSeeking() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, settlingSeek: true,
                                     stall: .flowing, transportHasRolled: true) == .seeking)
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, settlingSeek: false,
                                     stall: .flowing, transportHasRolled: true) == .rebuffering)
    }

    @Test("a source stall still wins over the settle")
    func stallWins() {
        #expect(PlaybackPhase.derive(state: .playing, isBuffering: true, isSeeking: false, settlingSeek: true,
                                     stall: .reconnecting, transportHasRolled: true) == .stalled(reconnecting: true))
    }

    @Test("only an ordinary playing landing that waits on the rate is a preroll")
    func prerollRule() {
        #expect(AetherEngine.nativeSeekPrerolls(isStarved: false, recoveredState: .playing,
                                                liveStatus: .waitingToPlayAtSpecifiedRate))
        #expect(!AetherEngine.nativeSeekPrerolls(isStarved: true, recoveredState: .playing,
                                                 liveStatus: .waitingToPlayAtSpecifiedRate),
                "a deadline recovery's landing is starved, and reads as one")
        #expect(!AetherEngine.nativeSeekPrerolls(isStarved: false, recoveredState: .paused,
                                                 liveStatus: .waitingToPlayAtSpecifiedRate))
        #expect(!AetherEngine.nativeSeekPrerolls(isStarved: false, recoveredState: .playing, liveStatus: .playing))
    }

    @Test("the settle ends on the roll, and the phase goes straight from seeking to playing")
    func endsOnRoll() async throws {
        let engine = try AetherEngine()
        engine.hasTransportRolled = true
        engine.state = .playing
        var phases: [PlaybackPhase] = []
        let watch = engine.$playbackPhase.sink { phases.append($0) }
        defer { watch.cancel() }
        engine.nativeSeekSettling = true
        engine.isBuffering = true
        engine.isBuffering = false
        engine.endNativeSeekSettle()
        #expect(!phases.contains(.rebuffering))
        #expect(phases.last == .playing)
    }
}
