import Testing
@testable import AetherEngine

struct SubtitleOverlayDrainerTests {
    @Test("fresh target decodes from playhead minus backscan")
    func freshTargetBackscans() {
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: nil, playhead: 100,
                                                    lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode(let from, let through) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 85)
        #expect(through == 160)
    }

    @Test("steady playback advances from the cursor without reset")
    func steadyAdvance() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 100.5,
                                                    lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .decode(let from, let through) = plan else {
            Issue.record("expected decode, got \(plan)"); return
        }
        #expect(from > 150)
        #expect(through == 160.5)
    }

    @Test("a playhead jump beyond the threshold resets the decoder and backscans")
    func seekResets() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 400,
                                                    lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode(let from, _) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 385)
    }

    @Test("backward jump beyond the threshold also resets and backscans")
    func backwardSeekResets() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 40,
                                                    lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode(let from, let through) = plan else {
            Issue.record("expected resetAndDecode, got \(plan)"); return
        }
        #expect(from == 25)
        #expect(through == 100)
    }

    @Test("caught-up cursor idles instead of scanning sub-second windows")
    func caughtUpIdles() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 160, lastPlayhead: 100)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 100.2,
                                                    lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        #expect(plan == .idle)
    }

    // #143/#204: after the drain window decodes, a still-active reconstruction pass with a seeded
    // candidate has no renderable successor to end it. Raw packets ahead may be zero-object clears.

    @Test("reconstruction with a seeded candidate should finalize after the window decodes")
    func finalizeWithCandidate() {
        #expect(SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: true, hasCandidate: true))
    }

    @Test("finalize needs a seeded candidate: a true gap with nothing behind ends nothing")
    func noFinalizeWithoutCandidate() {
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: true, hasCandidate: false))
    }

    @Test("finalize only applies inside a reconstruction pass")
    func noFinalizeOutsideReconstruction() {
        #expect(!SubtitleOverlayDrainer.shouldFinalizeReconstruction(
            reconstructing: false, hasCandidate: true))
    }

    // MARK: - The playhead's axis (#107 round 2)

    /// The plan reads a step it cannot account for as a reposition, which is right when the
    /// playhead moved and wrong when only the axis it is stated on changed. A software live seek
    /// published its landing session-relative while every other publication on that path rides the
    /// raw source clock, so on a mid-stream-joined source one tick saw the whole offset as a jump,
    /// reset the cursor, and scanned a stretch the packet store has nothing at. The next tick saw
    /// the same offset again in the other direction. Two resets and a dark tick for a seek that
    /// moved the playhead a few seconds.
    @Test("an axis change reads as a reposition, twice, and scans where nothing is stored")
    func sessionAxisPlayheadResetsTheCursorTwice() {
        let sessionZero = 24_549.835
        let landing = 35.29
        let cursor = SubtitleDrainCursor(lastDecodedPts: sessionZero + 40, lastPlayhead: sessionZero + 38)

        // The session-axis publish: read as a reposition to a position nothing was harvested at.
        let onSessionAxis = SubtitleOverlayDrainer.drainPlan(
            cursor: cursor, playhead: landing, lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode(let from, _) = onSessionAxis else {
            Issue.record("expected resetAndDecode, got \(onSessionAxis)"); return
        }
        #expect(from == landing - 15)
        #expect(from < sessionZero)

        // The next tick, back on the raw clock: a second reposition, in the other direction.
        let backOnSourceAxis = SubtitleOverlayDrainer.drainPlan(
            cursor: SubtitleDrainCursor(lastDecodedPts: landing + 60, lastPlayhead: landing),
            playhead: sessionZero + landing, lead: 60, backscan: 15, repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode = backOnSourceAxis else {
            Issue.record("expected resetAndDecode, got \(backOnSourceAxis)"); return
        }

        // Carried onto the axis the cursor is already on, the same seek is the one reposition it
        // really is, and it backscans over ground the store actually holds.
        let carried = SubtitleOverlayDrainer.drainPlan(
            cursor: cursor, playhead: sessionZero + landing, lead: 60, backscan: 15,
            repositioning: .inferred(jumpThreshold: 2.5))
        guard case .resetAndDecode(let carriedFrom, _) = carried else {
            Issue.record("expected resetAndDecode, got \(carried)"); return
        }
        #expect(carriedFrom > sessionZero)
    }

    // MARK: - Landings the player states

    @Test("a stated landing resets once, however short the step")
    func signalledLandingResetsOnce() {
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100, landingGeneration: 3)
        let landed = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 101, lead: 60, backscan: 15,
                                                      repositioning: .signalled(generation: 4))
        guard case .resetAndDecode(let from, _) = landed else {
            Issue.record("expected resetAndDecode, got \(landed)"); return
        }
        #expect(from == 86)
        let followed = SubtitleDrainCursor(lastDecodedPts: 101, lastPlayhead: 101, landingGeneration: 4)
        let next = SubtitleOverlayDrainer.drainPlan(cursor: followed, playhead: 102.5, lead: 60, backscan: 15,
                                                    repositioning: .signalled(generation: 4))
        guard case .decode = next else { Issue.record("expected decode, got \(next)"); return }
    }

    @Test("without a stated landing a far step is playback, not a seek")
    func signalledStepIsNotASeek() {
        // A tick that ran long, or a picture catching up to a landing already followed.
        let cursor = SubtitleDrainCursor(lastDecodedPts: 150, lastPlayhead: 100, landingGeneration: 4)
        let plan = SubtitleOverlayDrainer.drainPlan(cursor: cursor, playhead: 140, lead: 60, backscan: 15,
                                                    repositioning: .signalled(generation: 4))
        guard case .decode(let from, let through) = plan else {
            Issue.record("expected decode, got \(plan)"); return
        }
        #expect(from > 150)
        #expect(through == 200)
    }
}

@MainActor
struct SubtitleLandingPlayheadTests {
    @Test("the drain stands at a landing until the picture reports a time of its own")
    func landingHeldUntilThePictureMoves() throws {
        let engine = try AetherEngine()
        engine.clock.sourceTime = 100
        let before = engine.subtitleLandingGeneration
        engine.subtitleLanded(atItemSeconds: 400)
        #expect(engine.subtitleLandingGeneration == before &+ 1)
        // Still the old frame (AVPlayer buffering towards the target): the landing is where the drain is.
        #expect(engine.subtitleDrainPlayhead() == 400)
        #expect(engine.subtitleDrainPlayhead() == 400)
        // The picture reports: from here on it is the playhead.
        engine.clock.sourceTime = 399.6
        #expect(engine.subtitleDrainPlayhead() == 399.6)
        #expect(engine.subtitleLanding == nil)
    }
}
