import Testing
import Foundation
import CoreGraphics
import os
@testable import AetherEngine

/// `LoadOptions.forcedSubtitleTrack`: forced subtitles handed to tvOS as one FORCED=YES rendition,
/// a forced-only rendition made from a bitmap track's flagged lines, and the reading that lets a sparse
/// (forced) rendition be selected when it is truthfully empty at the playhead.
@Suite("Forced subtitle renditions")
struct ForcedSubtitleRenditionTests {

    private typealias Entry = AetherEngine.NativeSubtitleTrackEntry

    private func cue(_ start: Double, _ end: Double, _ text: String) -> SubtitleCue {
        SubtitleCue(id: Int(start * 1000), startTime: start, endTime: end, body: .text(text))
    }

    // MARK: - The table

    @Test("a named full bitmap track gets one forced-only entry, declared forced")
    func namedBitmapSource() {
        var text: [Entry] = [Entry(sourceStreamIndex: 3, language: "en", isForced: false)]
        var bitmap: [Entry] = [
            Entry(sourceStreamIndex: 4, language: "en", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 5, language: "en", isForced: false, needsOCR: true),
        ]
        #expect(AetherEngine.declareForcedSubtitleSource(5, text: &text, bitmap: &bitmap) == .flaggedLines)
        #expect(bitmap.count == 3)
        #expect(bitmap[2].sourceStreamIndex == 5 && bitmap[2].forcedCuesOnly && bitmap[2].declaresForced)
        #expect(bitmap.filter(\.declaresForced).count == 1)
        #expect(!text[0].declaresForced)
    }

    @Test("a named forced track declares its own rendition; a full text track or an external .sup declares none")
    func namedOwnOrNone() {
        var text: [Entry] = [Entry(sourceStreamIndex: 2, language: "en", isForced: true),
                             Entry(sourceStreamIndex: 3, language: "en", isForced: false)]
        var bitmap: [Entry] = [Entry(sourceStreamIndex: nil, externalID: 9000, language: "en", isForced: false,
                                     needsOCR: true)]
        #expect(AetherEngine.declareForcedSubtitleSource(2, text: &text, bitmap: &bitmap) == .ownRendition)
        #expect(text[0].declaresForced)
        var text2 = text.map { var e = $0; e.declaresForced = false; return e }
        #expect(AetherEngine.declareForcedSubtitleSource(3, text: &text2, bitmap: &bitmap) == .none)
        #expect(AetherEngine.declareForcedSubtitleSource(9000, text: &text2, bitmap: &bitmap) == .none)
        #expect(AetherEngine.declareForcedSubtitleSource(77, text: &text2, bitmap: &bitmap) == .none)
        #expect(bitmap.count == 1)
    }

    @Test("only the declared entry is FORCED=YES, and the forced-only rendition is named apart")
    func renditionInfosDeclareOnlyTheNamed() {
        let entries: [Entry] = [
            Entry(sourceStreamIndex: 3, language: "en", isForced: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: false, needsOCR: true),
            Entry(sourceStreamIndex: 4, language: "en", isForced: true, needsOCR: true, forcedCuesOnly: true,
                  declaresForced: true),
        ]
        let infos = AetherEngine.nativeSubtitleRenditionInfos(for: entries)
        #expect(infos.map(\.isForced) == [false, false, true])
        #expect(Set(infos.map(\.name)).count == 3)
        #expect(infos[2].name.hasSuffix("(Forced)"))
    }

    @Test("a store counts as being filled only while a feeder started on it or read it recently")
    func feedingActivity() {
        let store = NativeSubtitleCueStore()
        #expect(!store.isBeingFed(within: 5))
        store.markFeeding()
        #expect(store.isBeingFed(within: 5))
        let read = NativeSubtitleCueStore()
        read.noteRead(from: 0, through: 10)
        #expect(read.isBeingFed(within: 5))
    }

    @Test("the player asking for a rendition reaches its handler")
    func renditionRequestHook() {
        let store = NativeSubtitleCueStore()
        let count = OSAllocatedUnfairLock(initialState: 0)
        store.onRenditionRequested { count.withLock { $0 += 1 } }
        store.noteRenditionRequested()
        store.noteRenditionRequested()
        #expect(count.withLock { $0 } == 2)
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
