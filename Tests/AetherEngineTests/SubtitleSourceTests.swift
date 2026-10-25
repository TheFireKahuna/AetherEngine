import Testing
import Foundation
import AetherLibavformat
@testable import AetherEngine

/// The session's one subtitle reader against real files (`MP4SampleIndexTests`' fixtures, written to
/// disk): each stream's route, the text renditions the index fills whole, which are their streams' pull,
/// pulls of an indexed stream on request, the walk for every other stream feeding the packet store and its
/// cue store through the same decoder, and the walk following its consumers' demand.
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
        var playhead: Double = 0 { didSet { clock.set(playhead) } }
        /// The playhead the walk paces against, as a session's clock would give it.
        let clock = AtomicDouble(0)
        var restarting = false
        var endsOfFile = 0
        var stops: [SubtitleDrainStopReason?] = []
        var settled: [Int32: SubtitleSource.Route]?
        var pulls: [Int32] = []
        var source: SubtitleSource!

        /// `renditions: false` gives the streams no cue stores, so nothing fills them at load.
        init(_ data: Data, renditions: Bool = true) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "subsource-\(UUID().uuidString).mp4")
            try data.write(to: url)
            demuxer = Demuxer()
            try demuxer.open(url: url, extraHeaders: [:],
                             profile: .subtitleSideDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
            cueStores = renditions
                ? Dictionary(uniqueKeysWithValues: demuxer.subtitleStreamIndices().map { ($0, NativeSubtitleCueStore()) })
                : [:]
            let demuxer = demuxer
            source = SubtitleSource(host: .init(
                url: url, headers: [:], headerStore: nil, customReader: nil, formatHint: nil,
                probesize: nil, maxAnalyzeDuration: nil, discTitleID: nil, isLive: false,
                packetStore: packetStore, cueStores: cueStores, demuxer: demuxer,
                makeDecoder: { stream in
                    demuxer.withStream(at: stream) {
                        EmbeddedSubtitleDecoder(stream: $0, sourceVideoWidth: 32, sourceVideoHeight: 32)
                    } ?? nil
                },
                playhead: { [weak self] in self?.playhead },
                pacingPlayhead: { [clock] in clock.get() },
                duration: { 12 },
                videoRestarting: { [weak self] in self?.restarting ?? false },
                linkGate: SideReaderLinkGate(),
                fence: { .init() },
                cuesArrived: {},
                endOfFile: { [weak self] in self?.endsOfFile += 1 },
                stopped: { [weak self] in self?.stops.append($0) },
                routesSettled: { [weak self] in self?.settled = $0 },
                pulled: { [weak self] in self?.pulls.append($0) }))
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
        #expect(Set(await whole.source.routes().values.map { $0 == .walked }) == [false])

        let cut = try Rig(MP4SampleIndexTests.movTextCut)
        defer { cut.close() }
        let cutRoutes = await cut.source.routes()
        #expect(cutRoutes.values.filter { $0 == .walked }.count == 1)
        #expect(cutRoutes.values.filter { $0 != .walked }.count == 1)

        let fragmented = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { fragmented.close() }
        #expect(Set(await fragmented.source.routes().values) == [.walked])
    }

    @Test("an indexed text rendition is complete at once, and its frames are its stream's pull for the film")
    func indexedRenditionsWhole() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        try await waitFor { rig.cueStores.values.allSatisfy(\.isFinished) }
        let counts = rig.cueStores.keys.sorted().map { rig.cues($0).count }
        #expect(counts.sorted() == [2, 3])
        #expect(!rig.source.isReading)
        #expect(rig.source.walkDemuxer == nil)
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
        #expect(!rig.source.isReading)
    }

    @Test("the walk decodes its streams into their cue stores with the decoder the index uses")
    func walkDecodesLikeTheIndex() async throws {
        let indexed = try Rig(MP4SampleIndexTests.movText)
        defer { indexed.close() }
        try await waitFor { indexed.cueStores.values.allSatisfy(\.isFinished) }

        let walked = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { walked.close() }
        walked.source.demand(.rendition, streams: walked.streams, lead: { _ in 3600 }, from: 0)
        try await waitFor { walked.endsOfFile == 1 }
        #expect(walked.source.walkDemuxer != nil || !walked.source.isReading)
        for stream in indexed.cueStores.keys.sorted() {
            let a = indexed.cues(stream), b = walked.cues(stream)
            #expect(!a.isEmpty)
            #expect(a.map(\.1) == b.map(\.1))
            // The indexed fixture puts the German track behind an empty edit of 0.75 s and the
            // fragmented copy does not, so a stream's times may differ by one constant.
            let offsets = zip(a, b).map { $1.0 - $0.0 }
            #expect(offsets.allSatisfy { abs($0 - offsets[0]) < 0.001 })
            #expect([0.0, -0.75].contains { abs(offsets[0] - $0) < 0.001 }, "\(offsets)")
            // The walk read the whole file, so it vouches for every stretch of it.
            #expect((walked.cueStores[stream]?.readThrough(at: 0.5) ?? 0) >= 10)
        }
    }

    @Test("the walk reads the walked stream; the indexed one is its fill's pull, decoded once")
    func mixedRoutes() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextCut)
        defer { rig.close() }
        let routes = await rig.source.routes()
        let walkedStream = try #require(routes.first { $0.value == .walked }?.key)
        let indexedStream = try #require(routes.first { $0.value != .walked }?.key)
        try await waitFor { rig.cueStores[indexedStream]?.isFinished == true }
        #expect(rig.cueStores[walkedStream]?.isFinished == false)

        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 3600 }, from: 0)
        try await waitFor { rig.endsOfFile == 1 }
        #expect(!rig.packetStore.entries(streamIndex: walkedStream, from: 0, through: 20).isEmpty)
        #expect(rig.packetStore.pulledReach(streamIndex: walkedStream, from: 0) == nil)
        #expect(!rig.packetStore.entries(streamIndex: indexedStream, from: 0, through: 20).isEmpty)
        // The walk's own stream reached its rendition; the indexed one was not decoded twice.
        #expect(!rig.cues(walkedStream).isEmpty)
        #expect(rig.cues(indexedStream).count == Set(rig.cues(indexedStream).map(\.1)).count)
    }

    @Test("the loop parks at the furthest lead and reads on when a lead is raised, without a move")
    func leadIsLive() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        let stream = try #require(rig.cueStores.keys.min())
        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 1 }, from: 0)
        try await waitFor { (rig.packetStore.frontier(streamIndex: stream) ?? -1) >= 0 }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(rig.endsOfFile == 0)
        #expect((rig.packetStore.frontier(streamIndex: stream) ?? 0) < 6)
        rig.source.demand(.rendition, streams: rig.streams, lead: { _ in 3600 })
        try await waitFor { rig.endsOfFile == 1 }
        #expect((rig.packetStore.frontier(streamIndex: stream) ?? 0) >= 6)
    }

    @Test("the reading stops once nobody asks, with the last reason; a re-ask in the same turn keeps it")
    func demandLifecycle() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        rig.restarting = true   // holds the walk before its open, so nothing races the assertions
        try await waitFor { rig.settled != nil }
        #expect(!rig.source.isReading)
        rig.source.demand(.ocr, streams: rig.streams, lead: { _ in 60 })
        #expect(rig.source.isReading)
        rig.source.withdraw(.ocr)
        rig.source.demand(.ocr, streams: rig.streams, lead: { _ in 60 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.source.isReading)
        #expect(rig.stops.isEmpty)

        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 75 })
        rig.source.withdraw(.ocr)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.source.isReading)
        rig.source.withdraw(.overlay, reason: .subtitlesCleared)
        try await waitFor { !rig.source.isReading }
        #expect(rig.stops == [.subtitlesCleared])
    }

    @Test("a producer restart in flight holds the walk's open until it settles", .timeLimit(.minutes(1)))
    func walkWaitsForARestart() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        rig.restarting = true
        rig.source.demand(.rendition, streams: rig.streams, lead: { _ in 3600 }, from: 0)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(rig.source.walkDemuxer == nil)
        #expect(rig.cueStores.values.allSatisfy { $0.cueCount == 0 })
        rig.restarting = false
        try await waitFor { rig.endsOfFile == 1 }
        #expect(rig.cueStores.values.allSatisfy { $0.cueCount > 0 })
    }

    @Test("a demand for indexed streams only starts no walk")
    func indexOnlyNeedsNoWalk() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        try await waitFor { rig.settled != nil }
        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 3600 }, from: 0)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(!rig.source.isReading)
        #expect(rig.source.walkDemuxer == nil)
        #expect(rig.endsOfFile == 0)
    }

    @Test("a move while the session opens is taken when it is positioned")
    func moveBeforeTheSessionIsPositioned() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        rig.source.demand(.overlay, streams: rig.streams, lead: { _ in 3600 }, from: 0)
        rig.source.move(to: 8)
        try await waitFor { rig.endsOfFile == 1 }
        let spans = rig.packetStore.harvestCoverageSpans
        #expect(spans.contains { $0.from >= 7.9 })
    }
}
