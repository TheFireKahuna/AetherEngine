import Testing
import Foundation
import AetherLibavformat
@testable import AetherEngine

/// The session's one subtitle reader against real files (`MP4SampleIndexTests`' fixtures, written to
/// disk): each stream's route, the text renditions the index fills whole, which are their streams' pull,
/// pulls of an indexed stream on request, and every other stream's consumers asking the pump to read ahead.
@MainActor
@Suite(.serialized)
struct SubtitleSourceTests {

    /// One source over a fixture, with the knobs a test turns.
    @MainActor
    final class Rig {
        let url: URL
        let demuxer: Demuxer
        let packetStore = SubtitlePacketStore()
        let cueStores: [Int32: NativeSubtitleCueStore]
        let leads = SubtitleSource.Leads()
        var stops: [SubtitleDrainStopReason?] = []
        var settled: [Int32: SubtitleSource.Route]?
        var pulls: [Int32] = []
        var source: SubtitleSource!

        /// `renditions: false` gives the streams no cue stores, so nothing fills them at load.
        init(_ data: Data, renditions: Bool = true) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "subsource-\(UUID().uuidString).mp4")
            try data.write(to: url)
            demuxer = Demuxer()
            cueStores = renditions
                ? Dictionary(uniqueKeysWithValues: demuxer.subtitleStreamIndices().map { ($0, NativeSubtitleCueStore()) })
                : [:]
            let demuxer = demuxer
            source = SubtitleSource(host: .init(
                url: url, headers: [:], headerStore: nil, customReader: nil, discTitleID: nil, isLive: false,
                packetStore: packetStore, cueStores: cueStores, demuxer: demuxer,
                makeDecoder: { stream in
                    demuxer.withStream(at: stream) {
                        EmbeddedSubtitleDecoder(stream: $0, sourceVideoWidth: 32, sourceVideoHeight: 32)
                    } ?? nil
                },
                duration: { 12 },
                cuesArrived: {},
                stopped: { [weak self] in self?.stops.append($0) },
                routesSettled: { [weak self] in self?.settled = $0 },
                pulled: { [weak self] in self?.pulls.append($0) }),
                leads: leads)
        }

        var streams: Set<Int32> { Set(demuxer.subtitleStreamIndices()) }

        func close() {
            source.close()
            demuxer.close()
            try? FileManager.default.removeItem(at: url)
        }

        /// The cues of a stream's store as (start, text).
        func cues(_ stream: Int32) -> [(Double, String)] {
            (cueStores[stream]?.allCues() ?? []).map { ($0.start, $0.text) }
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double = 20) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @Test("each stream is routed by what the index lists in full: both, one of two, none")
    func routes() async throws {
        let whole = try Rig(MP4SampleIndexTests.movText)
        defer { whole.close() }
        #expect(Set(await whole.source.routes().values.map { $0 == .pumped }) == [false])

        let cut = try Rig(MP4SampleIndexTests.movTextCut)
        defer { cut.close() }
        let cutRoutes = await cut.source.routes()
        #expect(cutRoutes.values.filter { $0 == .pumped }.count == 1)
        #expect(cutRoutes.values.filter { $0 != .pumped }.count == 1)

        let fragmented = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { fragmented.close() }
        #expect(Set(await fragmented.source.routes().values) == [.pumped])
    }

    @Test("an indexed text rendition is complete at once, and its frames are its stream's pull for the film")
    func indexedRenditionsWhole() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        try await waitFor { rig.cueStores.values.allSatisfy(\.isFinished) }
        let counts = rig.cueStores.keys.sorted().map { rig.cues($0).count }
        #expect(counts.sorted() == [2, 3])
        #expect(!rig.source.isReadingAhead)
        for stream in rig.cueStores.keys {
            // Every frame, the empty gap samples mov_text times its silences with included.
            #expect(rig.packetStore.entries(streamIndex: stream, from: 0, through: 20).count >= rig.cues(stream).count)
            #expect(!rig.cues(stream).isEmpty)
            #expect(rig.packetStore.pulledReach(streamIndex: stream, from: 0) == .infinity)
            #expect(rig.packetStore.isPulled(stream))
        }
    }

    @Test("a pull stores the window's frames and its span, the next frame comes from the index, and a pulled span is not read again")
    func pullOnRequest() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText, renditions: false)
        defer { rig.close() }
        try await waitFor { rig.settled != nil }
        let stream = try #require(rig.streams.min())
        guard case .indexed = rig.source.route(of: stream) else { Issue.record("not indexed"); return }
        rig.source.pull(stream, from: 0, through: 1, focus: 0)
        try await waitFor { rig.pulls == [stream] }
        let entries = rig.packetStore.entries(streamIndex: stream, from: 0, through: 40)
        #expect(!entries.isEmpty)
        // Read through the asked span plus the read-ahead.
        #expect(rig.packetStore.pulledReach(streamIndex: stream, from: 0) == 1 + SubtitleSource.pullAheadSeconds)
        #expect(rig.source.nextFrameSeconds(stream, after: entries[0].ptsSeconds) == entries.dropFirst().first?.ptsSeconds)
        rig.source.pull(stream, from: 0, through: 20, focus: 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(rig.pulls == [stream])
        #expect(!rig.source.isReadingAhead)
    }

    @Test("a pumped stream's consumer asks the pump to read ahead; the indexed one is its fill's pull")
    func mixedRoutes() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextCut)
        defer { rig.close() }
        let routes = await rig.source.routes()
        let pumpedStream = try #require(routes.first { $0.value == .pumped }?.key)
        let indexedStream = try #require(routes.first { $0.value != .pumped }?.key)
        try await waitFor { rig.cueStores[indexedStream]?.isFinished == true }
        #expect(rig.cueStores[pumpedStream]?.isFinished == false)
        #expect(rig.packetStore.isPulled(indexedStream))
        #expect(!rig.packetStore.isPulled(pumpedStream))

        rig.source.demand(.overlay, streams: [indexedStream], lead: { _ in 75 })
        #expect(!rig.source.isReadingAhead)
        #expect(rig.leads.readAhead(playhead: 0) == nil)
        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 75 })
        #expect(rig.source.isReadingAhead)
        #expect(rig.leads.readAhead(playhead: 0) == 75)
    }

    @Test("before the routes settle every stream counts as the pump's")
    func unsettledStreamsArePumped() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 75 })
        if rig.settled == nil { #expect(rig.leads.readAhead(playhead: 0) == 75) }
        try await waitFor { rig.settled != nil }
        // Every stream turned out to be the index's: the pump has nothing to read ahead for.
        #expect(rig.leads.readAhead(playhead: 0) == nil)
        try await waitFor { !rig.source.isReadingAhead }
        #expect(rig.stops.allSatisfy { $0 == nil })
    }

    @Test("the read-ahead lapses once nobody asks, with the last reason; a re-ask in the same turn keeps it")
    func demandLifecycle() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        try await waitFor { rig.settled != nil }
        #expect(!rig.source.isReadingAhead)
        rig.source.demand(.ocr, streams: rig.streams, lead: { _ in 60 })
        #expect(rig.source.isReadingAhead)
        rig.source.withdraw(.ocr)
        rig.source.demand(.ocr, streams: rig.streams, lead: { _ in 60 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.source.isReadingAhead)
        #expect(rig.stops.isEmpty)

        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 75 })
        rig.source.withdraw(.ocr)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.source.isReadingAhead)
        #expect(rig.leads.readAhead(playhead: 0) == 75)
        rig.source.withdraw(.overlay, reason: .subtitlesCleared)
        try await waitFor { !rig.source.isReadingAhead }
        #expect(rig.stops == [.subtitlesCleared])
        #expect(rig.leads.readAhead(playhead: 0) == nil)
    }

    @Test("closing the source clears the leads the pump reads, and says it stopped")
    func closeClearsTheLeads() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        try await waitFor { rig.settled != nil }
        rig.source.demand(.rendition, streams: rig.streams, lead: { _ in 300 })
        rig.close()
        #expect(rig.leads.readAhead(playhead: 0) == nil)
        #expect(rig.stops == [.sessionStopped])
    }
}
