import Foundation
import Testing
@testable import AetherEngine

/// #250 (cmcpherson274): an external conformance harness adjudicating seek-time subtitle
/// correctness has to decide, from the log alone, whether the pipeline has DETERMINED the display
/// state at the rendered position or has merely produced nothing yet. On a PGS track with no
/// acquisition point those are indistinguishable from outside.
///
/// Every case here is one way the statement could lie, since a diagnostic that over-claims is worse
/// than no diagnostic: the harness would adjudicate on it. Pure values throughout, with the read
/// frontier the store states (`SubtitlePacketStore.harvestReach`, `pulledReach`) passed in.
struct Issue250SubtitleResolutionTests {

    private static let fence = SubtitleResolutionStatement.Fence(loadGeneration: 3,
                                                                 seekGeneration: 7)

    private static func statement(
        coveredFrom: Double = 1185,
        windowThrough: Double = 1260,
        decodedThrough: Double = 1204,
        readThrough: Double? = nil,
        retainedFrom: Double? = 1185,
        reason: SubtitleResolutionStatement.Reason = .reconstruction
    ) -> SubtitleResolutionStatement.Statement {
        SubtitleResolutionStatement.make(
            fence: fence, streamIndex: 4,
            coveredFrom: coveredFrom, windowThrough: windowThrough,
            decodedThrough: decodedThrough,
            readThrough: readThrough,
            retainedFrom: retainedFrom,
            reason: reason)
    }

    // MARK: - What resolvedThrough may claim

    /// The defect the whole line exists to avoid. The drain window runs to playhead + 60 s whether
    /// or not anybody has read that far, so taking its edge as the answer claims determination over
    /// bytes nobody fetched, which is exactly the ambiguity the harness is trying to remove.
    @Test("an unread window is not claimed as determined")
    func frontierBoundsTheWindow() {
        let s = Self.statement(readThrough: 1218)
        #expect(s.via == .read)
        #expect(s.resolvedThrough == 1218)
    }

    /// The mirror image: a reader that has run past the lead edge does not extend the claim beyond
    /// the window the drainer actually decoded.
    @Test("a frontier beyond the lead edge is clamped to the window")
    func windowBoundsTheFrontier() {
        #expect(Self.statement(readThrough: 1900).resolvedThrough == 1260)
    }

    /// The other tempting answer, and why the drain cursor cannot be it while the reading is known: on
    /// a sparse or forced track the last decoded cue stands still for minutes, so a cursor-based
    /// statement would report every dialogue pause as unresolved. The pump states its reading from the
    /// video it reads, so the frontier moves between cues and keeps stating determination through
    /// silence.
    @Test("a sparse stretch is resolved past the last decoded cue")
    func sparseTrackResolvesPastTheCursor() {
        let s = Self.statement(decodedThrough: 1190, readThrough: 1249)
        #expect(s.resolvedThrough == 1249)
        #expect(s.decodedThrough == 1190, "the cursor is still reported, just not as the answer")
    }

    /// The pump read to the end of the source, so an empty position inside the window means "no cue
    /// here" rather than "not yet". This is the strongest state the line can report and the one the
    /// harness can adjudicate on outright.
    @Test("end of file determines the whole window")
    func endOfFileDeterminesTheWindow() {
        let s = Self.statement(readThrough: .infinity)
        #expect(s.via == .eof)
        #expect(s.resolvedThrough == 1260)
    }

    /// With the playhead itself not known to be read (the pump has not reached it, a pull has not landed)
    /// the claim collapses to what was actually decoded, and says so through `via`.
    @Test("no reading at the playhead collapses the claim onto the drain cursor")
    func pumpFallbackIsTheCursor() {
        let s = Self.statement(readThrough: nil)
        #expect(s.via == .cursor)
        #expect(s.resolvedThrough == 1204)
    }

    /// A fresh window with nothing decoded and no reader is the honest "nothing determined", and it
    /// has to be distinguishable from "determined, and empty".
    @Test("nothing decoded and no reader resolves to nothing")
    func nothingDeterminedReportsNone() {
        let s = Self.statement(decodedThrough: .nan, readThrough: nil)
        #expect(s.via == .cursor)
        #expect(s.resolvedThrough == nil)
        #expect(SubtitleResolutionStatement.format(s).contains("resolvedThrough=none"))
    }

    /// A frontier below the window start says nothing about the region now being decoded, so it is not a
    /// claim over it.
    @Test("a frontier behind the window start resolves to nothing")
    func frontierBehindCoverageResolvesToNone() {
        #expect(Self.statement(coveredFrom: 1185, readThrough: 900).resolvedThrough == nil)
    }

    // MARK: - The frontier from the store

    /// The store's reach is stated per run of the reading, and every reposition announces a new run, so
    /// a seek past what was read leaves nothing to claim at the landing until the pump reads there.
    @Test("the frontier is the reading's reach from the playhead, and a seek past it claims nothing")
    func frontierFromTheStore() {
        let store = SubtitlePacketStore()
        store.noteHarvestAnchor(at: 1180)
        for position in stride(from: 1180.5, through: 1249, by: 0.5) { store.noteHarvestProgress(through: position) }
        #expect(SubtitleResolutionStatement.via(readThrough: store.harvestReach(from: 1200)) == .read)
        #expect(store.harvestReach(from: 1200) == 1249)
        // A seek to 1500: the producer restarts there and has read nothing yet.
        store.noteHarvestAnchor(at: 1500)
        #expect(SubtitleResolutionStatement.via(readThrough: store.harvestReach(from: 1505)) == .cursor)
        store.noteHarvestProgress(through: 1506)
        store.noteHarvestEnd()
        #expect(SubtitleResolutionStatement.via(readThrough: store.harvestReach(from: 1505)) == .eof)
    }

    // MARK: - Line shape

    /// The harness taps EngineLog.handler and archives it, so the field set is the contract.
    @Test("the statement formats as one parseable line")
    func formatsAsOneLine() {
        let line = SubtitleResolutionStatement.format(
            Self.statement(readThrough: 1218, reason: .tick))
        #expect(line.hasPrefix("[AetherEngine] #250 subtitle-resolution "))
        #expect(line.contains("loadGen=3 seekGen=7 "))
        #expect(line.contains("stream=4 "))
        #expect(line.contains("coveredFrom=1185.00 "))
        #expect(line.contains("retainedFrom=1185.00 "))   // #276
        #expect(line.contains("resolvedThrough=1218.00 "))
        #expect(line.contains("via=read "))
        #expect(line.contains("decodedThrough=1204.00 "))
        #expect(line.hasSuffix("reason=tick"))
        #expect(!line.contains("\n"))
    }
}
