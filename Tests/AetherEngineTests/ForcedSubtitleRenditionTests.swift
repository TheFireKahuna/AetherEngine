import Testing
import Foundation
import CoreGraphics
@testable import AetherEngine

/// `LoadOptions.forcedSubtitleRenditions`: forced subtitles handed to AVFoundation as FORCED=YES renditions,
/// a forced-only rendition made from a bitmap track's flagged lines, and the reading that lets a sparse
/// (forced) rendition be selected when it is truthfully empty at the playhead.
@Suite("Forced subtitle renditions")
struct ForcedSubtitleRenditionTests {

    private typealias Entry = AetherEngine.NativeSubtitleTrackEntry

    private func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: Int(start * 1000), startTime: start, endTime: end, body: .text(text))
    }

    // MARK: - The table

    @Test("an embedded full bitmap track gets a forced-only entry; a forced or external one does not")
    func forcedCueEntries() {
        let bitmap: [Entry] = [
            Entry(sourceStreamIndex: 4, language: "eng", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 5, language: "eng", isForced: true, needsOCR: true),
            Entry(sourceStreamIndex: nil, externalID: 9000, language: "ger", isForced: false, needsOCR: true),
        ]
        let forced = AetherEngine.forcedCueSubtitleEntries(for: bitmap)
        #expect(forced.count == 1)
        #expect(forced[0].sourceStreamIndex == 4)
        #expect(forced[0].forcedCuesOnly)
        #expect(forced[0].isForced)
        #expect(forced[0].needsOCR)
    }

    @Test("FORCED is declared only when the option asks for it, and the forced-only rendition is named apart")
    func renditionInfosDeclareForcedOnlyWhenAsked() {
        let entries: [Entry] = [
            Entry(sourceStreamIndex: 3, language: "en", isForced: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: true, needsOCR: true, forcedCuesOnly: true),
        ]
        let off = AetherEngine.nativeSubtitleRenditionInfos(for: entries)
        #expect(off.allSatisfy { !$0.isForced })

        let on = AetherEngine.nativeSubtitleRenditionInfos(for: entries, declaresForced: true)
        #expect(on.map(\.isForced) == [true, false, true])
        #expect(Set(on.map(\.name)).count == 3)
        #expect(on[2].name.hasSuffix("(Forced)"))
    }

    @Test("a forced selection maps a full track to its forced-only rendition, a forced track to its own")
    func forcedOrdinalMapping() {
        let table: [Entry] = [
            Entry(sourceStreamIndex: 3, language: "en", isForced: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: true, needsOCR: true, forcedCuesOnly: true),
            Entry(sourceStreamIndex: 6, language: "de", isForced: false),
        ]
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 4, in: table) == 1)
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 4, in: table, forced: true) == 2)
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 3, in: table, forced: true) == 0)
        #expect(AetherEngine.nativeSubtitleOrdinal(forActiveTrack: 6, in: table, forced: true) == nil)
    }

    @Test("a #170 reload replays a forced selection onto the forced rendition")
    func carryoverReplaysForced() {
        let table: [Entry] = [
            Entry(sourceStreamIndex: 4, language: "en", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: true, needsOCR: true, forcedCuesOnly: true),
        ]
        let replay = AetherEngine.nativeOrdinalToReplay(
            previousOrdinal: 1, matchesActiveTrack: true, previousActiveTrack: 4,
            currentOrdinal: nil, table: table, forced: true)
        #expect(replay == 1)
    }

    // MARK: - The master

    @Test("a declared forced rendition is FORCED=YES, AUTOSELECT=YES, DEFAULT=NO (HLS Authoring Spec 5.11)")
    func masterForcedAttributes() {
        let provider = ForcedMasterProvider(renditions: [(0, "ger", "Deutsch (Forced)", true),
                                                         (1, "ger", "Deutsch", false)])
        let m = HLSLocalServer.buildMasterPlaylistText(provider: provider)
        #expect(m.contains("NAME=\"Deutsch (Forced)\",LANGUAGE=\"ger\",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI=\"subs_0.m3u8\""))
        #expect(m.contains("NAME=\"Deutsch\",LANGUAGE=\"ger\",DEFAULT=NO,AUTOSELECT=NO,URI=\"subs_1.m3u8\""))
    }

    // MARK: - The reading

    @Test("a track read past the playhead with no line there reads as read, not as unread")
    func sparseTrackReadsAsRead() {
        let store = NativeSubtitleCueStore()
        store.appendCues([cue(10, 12, "alien")])
        #expect(store.readThrough(at: 60) == 12)
        store.noteRead(from: 0, through: 200)
        #expect(store.readThrough(at: 60) == 200)
        // Outside the span nothing is claimed beyond the cues.
        #expect(store.readThrough(at: 300) == 12)
    }

    @Test("a continuing note extends the span; one that does not replaces it")
    func readSpanContinuesOrReplaces() {
        let store = NativeSubtitleCueStore()
        store.noteRead(from: 100, through: 150)
        store.noteRead(from: 150.1, through: 180)
        #expect(store.readThrough(at: 120) == 180)
        store.noteRead(from: 400, through: 420)
        #expect(store.readThrough(at: 120) == 0)
        #expect(store.readThrough(at: 410) == 420)
    }

    @Test("the reading follows the playlist shift, as the cues do")
    func readSpanShifted() {
        let store = NativeSubtitleCueStore()
        store.setShiftSeconds(5)
        store.noteRead(from: 10, through: 100)
        #expect(store.readThrough(at: 20) == 95)
    }

    @Test("clearing the store forgets the reading")
    func clearForgetsReading() {
        let store = NativeSubtitleCueStore()
        store.noteRead(from: 0, through: 100)
        store.clear()
        #expect(store.readThrough(at: 10) == 0)
    }

    @Test("the harvest's reach runs on through seams and stops at a hole")
    func harvestReach() {
        var coverage = SubtitleHarvestCoverage()
        #expect(coverage.reach(from: 10) == nil)
        coverage.noteAnchor(.pump, at: 0)
        coverage.noteProgress(.pump, through: 20)
        coverage.noteAnchor(.prefetch, at: 20.1)
        for t in stride(from: 20.5, through: 40, by: 0.5) { coverage.noteProgress(.prefetch, through: t) }
        #expect(coverage.reach(from: 10) == 40)
        coverage.noteAnchor(.pump, at: 60)
        coverage.noteProgress(.pump, through: 70)
        #expect(coverage.reach(from: 10) == 40)
        #expect(coverage.reach(from: 65) == 70)
        #expect(coverage.reach(from: 50) == nil)
    }

    @Test("an open composition holds the reading back to its start")
    func pendingCompositionStart() {
        var pending = SubtitleOCRPendingState()
        #expect(pending.earliestPendingStart == nil)
        let image = SubtitleImage(cgImage: Self.pixel(), position: .zero)
        _ = pending.consume(eventPts: 30, cues: [SubtitleCue(id: 1, startTime: 30, endTime: 35, body: .image(image))],
                            trimAt: nil)
        #expect(pending.earliestPendingStart == 30)
    }

    private static func pixel() -> CGImage {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }
}

private final class ForcedMasterProvider: HLSSegmentProvider, @unchecked Sendable {
    let renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)]
    init(renditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)]) { self.renditions = renditions }
    func initSegment() -> Data? { Data([0x00]) }
    func mediaSegment(at index: Int) -> Data? { Data([0x00]) }
    var segmentCount: Int { 1 }
    func segmentDuration(at index: Int) -> Double { 4.0 }
    var playlistType: HLSPlaylistType { .vod }
    var masterCodecs: String? { "hvc1.1.6.L120.90,mp4a.40.2" }
    var masterVideoRange: HLSVideoRange? { .sdr }
    var nativeSubtitleRenditions: [(ordinal: Int, language: String?, name: String, isForced: Bool)] { renditions }
}
