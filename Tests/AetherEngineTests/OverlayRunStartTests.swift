import Foundation
import Testing
@testable import AetherEngine

/// The hold an overlay's decode puts on a run's first segment, shared by the software overlay and the FEL overlay.
struct OverlayRunStartTests {

    @Test("A run's first unit is worked toward until the player moves the clock")
    func runStartDrivesTheDecodeUntilThePlayerMoves() {
        let runStart = OverlayRunStart()
        #expect(runStart.noteUnit(at: 10, opensRun: false))
        #expect(!runStart.noteUnit(at: 10.04, opensRun: false))
        runStart.notePlayerMoved()
        #expect(!runStart.noteUnit(at: 30, opensRun: true))
    }

    @Test("The hold waits for the picture at the run's start and releases once it is there")
    func holdWaitsForThePicture() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        var asked = 0
        let ready = runStart.awaitPicture(clockSeconds: 10, timeout: 5, progress: { 0 }, hasPicture: { start in
            #expect(start == 10)
            asked += 1
            return asked >= 3
        }, shouldStop: { false })
        #expect(ready)
        #expect(asked == 3)
    }

    @Test("A run cut ahead of the clock holds nothing")
    func runAheadOfTheClockHoldsNothing() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 40, opensRun: true)
        #expect(runStart.awaitPicture(clockSeconds: 10, timeout: 5, progress: { 0 }, hasPicture: { _ in false }, shouldStop: { false }))
    }

    @Test("The hold ends at its bound or when the producer stops, without the picture")
    func holdEndsAtTheBound() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        #expect(!runStart.awaitPicture(clockSeconds: 10, timeout: 0.02, progress: { 0 }, hasPicture: { _ in false }, shouldStop: { false }))
        #expect(!runStart.awaitPicture(clockSeconds: 10, timeout: 5, progress: { 0 }, hasPicture: { _ in false }, shouldStop: { true }))
    }

    @Test("A decoder that worked toward the picture and then stalls is let go after the stall, not the bound",
          .timeLimit(.minutes(1)))
    func stalledDecoderIsReleasedEarly() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        let began = ContinuousClock.now
        var units = 0
        let ready = runStart.awaitPicture(clockSeconds: 10, timeout: 5, progress: {
            if units < 5 { units += 1 }
            return units
        }, hasPicture: { _ in false }, shouldStop: { false })
        let waited = ContinuousClock.now - began
        #expect(!ready)
        #expect(waited >= .seconds(OverlayRunStart.stalledDecodeSeconds) && waited < .seconds(4),
                "released by the stall: \(waited)")
    }

    @Test("A decoder still producing units is waited for past the stall time, up to its picture",
          .timeLimit(.minutes(1)))
    func progressingDecoderIsWaitedFor() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        let began = ContinuousClock.now
        var units = 0
        let ready = runStart.awaitPicture(clockSeconds: 10, timeout: 5, progress: {
            units += 1
            return units
        }, hasPicture: { _ in ContinuousClock.now - began > .seconds(2.5) }, shouldStop: { false })
        #expect(ready)
    }

    @Test("A decoder that has not decoded its first unit yet is given the whole bound")
    func decoderWarmingUpGetsTheBound() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        let began = ContinuousClock.now
        #expect(!runStart.awaitPicture(clockSeconds: 10, timeout: 0.3, progress: { 0 }, hasPicture: { _ in false },
                                       shouldStop: { false }))
        #expect(ContinuousClock.now - began >= .seconds(0.3))
    }
}
