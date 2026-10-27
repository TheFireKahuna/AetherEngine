import Foundation
import Testing
@testable import AetherEngine

/// The hold an overlay's decode puts on a run's first segment, shared by the software overlay and the FEL overlay.
struct OverlayRunStartTests {

    @Test("A run's first unit is worked toward until the player moves the clock")
    func runStartDrivesTheDecodeUntilThePlayerMoves() {
        let runStart = OverlayRunStart()
        #expect(runStart.noteUnit(at: 10, opensRun: false) == 10)
        #expect(runStart.noteUnit(at: 10.04, opensRun: false) == nil)
        #expect(runStart.notePlayerMoved(to: 3))
        // A playing clock far behind the run: the decode stays with the player.
        #expect(runStart.noteUnit(at: 30, opensRun: true) == nil)
    }

    @Test("The hold waits for the picture at the run's start and releases once it is there")
    func holdWaitsForThePicture() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        var asked = 0
        let ready = runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: { 0 }, hasPicture: { start in
            #expect(start == 10)
            asked += 1
            return asked >= 3
        }, shouldStop: { false })
        #expect(ready)
        #expect(asked == 3)
    }

    @Test("A seek or a resume inside a run is waited for at the time AVPlayer reports, and the decode is sent there")
    func reportedTargetInsideTheRun() {
        let runStart = OverlayRunStart()
        runStart.follow(reportedTime: { 420.667 })
        _ = runStart.noteUnit(at: 420.337, opensRun: true)
        _ = runStart.noteUnit(at: 422.0, opensRun: false)
        var asked: [Double] = [], decodedTo: [Double] = []
        #expect(runStart.awaitPicture(decodeClock: { 0 }, decodeTo: { decodedTo.append($0) }, timeout: 5,
                                      progress: { 0 }, hasPicture: { asked.append($0); return true }, shouldStop: { false }))
        #expect(asked == [420.667])
        #expect(decodedTo == [420.667])
    }

    @Test("A report still at the position a seek left from is waited out, then the seek's target is held for")
    func staleReportIsWaitedOut() {
        let runStart = OverlayRunStart()
        let began = ContinuousClock.now
        // AVPlayer asks for the seek's segment before it reports the target: the old position first.
        runStart.follow(reportedTime: { ContinuousClock.now - began < .milliseconds(60) ? 1218.8 : 900.45 })
        _ = runStart.noteUnit(at: 900.191, opensRun: true)
        _ = runStart.noteUnit(at: 902.0, opensRun: false)
        var asked: [Double] = [], decodedTo: [Double] = []
        #expect(!runStart.awaitPicture(decodeClock: { 1218.8 }, decodeTo: { decodedTo.append($0) }, timeout: 0.4,
                                       progress: { 0 }, hasPicture: { asked.append($0); return false },
                                       shouldStop: { false }))
        #expect(!asked.isEmpty && Set(asked) == [900.45])
        #expect(decodedTo == [900.45])
    }

    @Test("Once AVPlayer reports a target in the run, a clock still where the seek left from is not followed")
    func staleClockIsNotFollowed() {
        let runStart = OverlayRunStart()
        runStart.follow(reportedTime: { 900.45 })
        #expect(runStart.notePlayerMoved(to: 2420.2))
        _ = runStart.noteUnit(at: 900.191, opensRun: true)
        _ = runStart.noteUnit(at: 902.5, opensRun: false)
        _ = runStart.awaitPicture(decodeClock: { 900.45 }, decodeTo: { _ in }, timeout: 5, progress: { 0 },
                                  hasPicture: { _ in true }, shouldStop: { false })
        #expect(!runStart.notePlayerMoved(to: 2420.3))
        // The seek completes: the clock lands in the run and is followed again, as it plays on.
        #expect(runStart.notePlayerMoved(to: 900.45))
        _ = runStart.noteUnit(at: 904.0, opensRun: false)
        #expect(runStart.notePlayerMoved(to: 903.2))
    }

    @Test("A run cut ahead of a playing player is let go once its report stays outside the run")
    func runAheadOfAPlayingPlayer() {
        let runStart = OverlayRunStart()
        runStart.follow(reportedTime: { 10 })
        #expect(runStart.notePlayerMoved(to: 10))
        _ = runStart.noteUnit(at: 40, opensRun: true)
        _ = runStart.noteUnit(at: 42, opensRun: false)
        let began = ContinuousClock.now
        #expect(runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: { 0 },
                                      hasPicture: { _ in false }, shouldStop: { false }))
        let waited = ContinuousClock.now - began
        #expect(waited >= .seconds(OverlayRunStart.reportSeconds) && waited < .seconds(1), "\(waited)")
    }

    @Test("AVPlayer's staging at the run's start is neither followed nor taken as the target, in either order")
    func stagingIsIgnored() {
        // AVPlayer reports the target; its clock then stages at the run's first picture and returns.
        let reported = OverlayRunStart()
        reported.follow(reportedTime: { 420.667 })
        _ = reported.noteUnit(at: 420.337, opensRun: true)
        _ = reported.noteUnit(at: 422.0, opensRun: false)
        _ = reported.awaitPicture(decodeClock: { 420.667 }, decodeTo: { _ in }, timeout: 5, progress: { 0 },
                                  hasPicture: { _ in true }, shouldStop: { false })
        #expect(!reported.notePlayerMoved(to: 420.337))
        #expect(reported.notePlayerMoved(to: 420.667))

        // No player to report yet: the staging arrives before the run's first unit, and the clock before it is the
        // target.
        let before = OverlayRunStart()
        #expect(before.notePlayerMoved(to: 420.667))
        #expect(before.notePlayerMoved(to: 420.337))
        _ = before.noteUnit(at: 420.337, opensRun: true)
        _ = before.noteUnit(at: 422.0, opensRun: false)
        var asked: [Double] = []
        _ = before.awaitPicture(decodeClock: { 420.337 }, decodeTo: { _ in }, timeout: 5, progress: { 0 },
                                hasPicture: { asked.append($0); return true }, shouldStop: { false })
        #expect(asked == [420.667])
    }

    @Test("A resume's start position is the target before the player exists")
    func startPositionSeedsTheTarget() {
        let runStart = OverlayRunStart()
        runStart.noteStart(at: 13.3)
        #expect(runStart.noteUnit(at: 11.64, opensRun: true) == 13.3)
    }

    @Test("A run cut ahead of the clock holds nothing")
    func runAheadOfTheClockHoldsNothing() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 40, opensRun: true)
        #expect(runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: { 0 }, hasPicture: { _ in false },
                                      shouldStop: { false }))
    }

    @Test("A clock past everything the run has cut holds nothing")
    func clockPastTheRunHoldsNothing() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        _ = runStart.noteUnit(at: 12, opensRun: false)
        #expect(runStart.notePlayerMoved(to: 20))
        #expect(runStart.awaitPicture(decodeClock: { 20 }, decodeTo: { _ in }, timeout: 5, progress: { 0 }, hasPicture: { _ in false },
                                      shouldStop: { false }))
    }

    @Test("The hold ends at its bound or when the producer stops, without the picture")
    func holdEndsAtTheBound() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        #expect(!runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 0.02, progress: { 0 }, hasPicture: { _ in false },
                                       shouldStop: { false }))
        #expect(!runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: { 0 }, hasPicture: { _ in false },
                                       shouldStop: { true }))
    }

    @Test("A decoder that worked toward the picture and then stalls is let go after the stall, not the bound",
          .timeLimit(.minutes(1)))
    func stalledDecoderIsReleasedEarly() {
        let runStart = OverlayRunStart()
        _ = runStart.noteUnit(at: 10, opensRun: true)
        let began = ContinuousClock.now
        var units = 0
        let ready = runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: {
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
        let ready = runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 5, progress: {
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
        #expect(!runStart.awaitPicture(decodeClock: { 10 }, decodeTo: { _ in }, timeout: 0.3, progress: { 0 }, hasPicture: { _ in false },
                                       shouldStop: { false }))
        #expect(ContinuousClock.now - began >= .seconds(0.3))
    }
}
