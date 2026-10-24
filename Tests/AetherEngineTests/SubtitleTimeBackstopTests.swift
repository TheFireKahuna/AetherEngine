import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Audit FEA-101 / SUB-105: cue times reach the stores and formatters from more than the demuxer
/// (live WebVTT renditions, external stores, a host calling the public builder), so every Double to
/// integer conversion on a cue time is total: a huge, infinite or NaN time degrades, it never traps.
@Suite("Hostile cue times never trap a subtitle store or formatter")
struct SubtitleTimeBackstopTests {

    private func subripDecoder() throws -> (Demuxer, EmbeddedSubtitleDecoder) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: HostileTimestampMatroska.make(
            blocks: [.init(cluster: 0, duration: 1000)])), formatHint: "matroska")
        let stream = try #require(demuxer.stream(at: 0))
        let decoder = try #require(EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 16, sourceVideoHeight: 16))
        return (demuxer, decoder)
    }

    @Test("the drain rebuilds a stored packet whose seconds do not fit Int64 milliseconds")
    func drainDecodeOfOutOfRangeSeconds() throws {
        let (demuxer, decoder) = try subripDecoder()
        defer { demuxer.close() }
        let payload = Data("line".utf8)
        let hugeDuration = StoredSubtitlePacket(ptsSeconds: 1, durationSeconds: 9.3e15, flags: 0, payload: payload)
        #expect(AetherEngine.decodeStoredSubtitlePacket(hugeDuration, with: decoder)?.cues.first?.startTime == 1)
        let hugePTS = StoredSubtitlePacket(ptsSeconds: Double(Int64.max) * 1e-3 * 1000, durationSeconds: 1,
                                           flags: 0, payload: payload)
        _ = AetherEngine.decodeStoredSubtitlePacket(hugePTS, with: decoder)
        let infinite = StoredSubtitlePacket(ptsSeconds: .infinity, durationSeconds: .nan, flags: 0, payload: payload)
        _ = AetherEngine.decodeStoredSubtitlePacket(infinite, with: decoder)
    }

    @Test("the store unsets implausible times and zeroes implausible durations for every writer")
    func harvestBoundsTimes() throws {
        let (demuxer, decoder) = try subripDecoder()
        defer { demuxer.close() }
        let store = SubtitlePacketStore()
        let payload = Data("line".utf8)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 1, durationSeconds: 9.2e15, flags: 0,
                           payload: payload, assembleSplitDisplaySets: false, writer: .prefetch)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 2, durationSeconds: .infinity, flags: 0,
                           payload: payload, assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 0, ptsSeconds: 3, durationSeconds: 0.5, flags: 0,
                           payload: payload, assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 0, ptsSeconds: .infinity, durationSeconds: 1, flags: 0,
                           payload: payload, assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 0, ptsSeconds: Double(Int64.max) * 1e-3, durationSeconds: 1, flags: 0,
                           payload: payload, assembleSplitDisplaySets: false)
        let entries = store.entries(streamIndex: 0, from: -.infinity, through: .infinity)
        #expect(entries.map(\.ptsSeconds) == [1, 2, 3])
        #expect(entries.map(\.durationSeconds) == [0, 0, 0.5])
        for entry in entries {
            #expect(AetherEngine.decodeStoredSubtitlePacket(entry, with: decoder) != nil)
        }
    }

    @Test("the native cue store dedupes cues at huge and non-finite times")
    func cueStoreKeys() {
        let store = NativeSubtitleCueStore()
        store.appendCues([
            SubtitleCue(id: 1, startTime: 1e16, endTime: 1e16 + 1, body: .text("far")),
            SubtitleCue(id: 2, startTime: .infinity, endTime: .infinity, body: .text("inf")),
            SubtitleCue(id: 3, startTime: .nan, endTime: .nan, body: .text("nan")),
            SubtitleCue(id: 4, startTime: 1, endTime: 2, body: .text("near")),
        ])
        #expect(store.cueCount == 4)
    }

    @Test("the public ASS timestamp formatter pins huge and non-finite input")
    func assTimestamp() {
        #expect(ASSScriptBuilder.timestamp(3661.5) == "1:01:01.50")
        #expect(ASSScriptBuilder.timestamp(-3) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(.nan) == "0:00:00.00")
        #expect(ASSScriptBuilder.timestamp(.infinity) == ASSScriptBuilder.timestamp(1e300))
        #expect(ASSScriptBuilder.timestamp(1e17) == ASSScriptBuilder.timestamp(4e9))
    }

    @Test("the WebVTT body survives cues at huge and non-finite times")
    func webVTTTimestamps() {
        let vtt = WebVTTBuilder.body(cues: [
            .init(start: 1, end: 2, text: "near"),
            .init(start: 1e19, end: .infinity, text: "far"),
            .init(start: .nan, end: .nan, text: "nan"),
        ])
        #expect(vtt.contains("00:00:01.000 --> 00:00:02.000\nnear"))
        #expect(vtt.contains("far"))
    }
}
