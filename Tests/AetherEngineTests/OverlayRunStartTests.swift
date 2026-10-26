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
        let ready = runStart.awaitPicture(clockSeconds: 10, timeout: 5, hasPicture: { start in
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
        #expect(runStart.awaitPicture(clockSeconds: 10, timeout: 5, hasPicture: { _ in false }, shouldStop: { false }))
    }

    @Test("The hold ends at its bound or when the producer stops, without the picture")
    func holdEndsAtTheBound() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        #expect(!runStart.awaitPicture(clockSeconds: 10, timeout: 0.02, hasPicture: { _ in false }, shouldStop: { false }))
        #expect(!runStart.awaitPicture(clockSeconds: 10, timeout: 5, hasPicture: { _ in false }, shouldStop: { true }))
    }
}
