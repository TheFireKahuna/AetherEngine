import Testing
import Foundation
import AetherLibavformat
@testable import AetherEngine

/// The session's one subtitle reader against real files (`MP4SampleIndexTests`' fixtures, written to
/// disk): each stream's route, the text renditions the index fills whole without any reading ahead, the
/// walk for every other stream feeding the packet store and its cue store through the same decoder, and
/// the reading that follows its consumers' demand.
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
        var playhead: Double = 0
        var restarting = false
        var endsOfFile = 0
        var stops: [SubtitleDrainStopReason?] = []
        var source: SubtitleSource!

        init(_ data: Data) throws {
            url = FileManager.default.temporaryDirectory.appending(path: "subsource-\(UUID().uuidString).mp4")
            try data.write(to: url)
            demuxer = Demuxer()
            try demuxer.open(url: url, extraHeaders: [:],
                             profile: .subtitleSideDemuxer(callerProbesize: nil, callerMaxAnalyzeDuration: nil))
            cueStores = Dictionary(uniqueKeysWithValues: demuxer.subtitleStreamIndices().map { ($0, NativeSubtitleCueStore()) })
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
                duration: { 12 },
                videoRestarting: { [weak self] in self?.restarting ?? false },
                linkGate: SideReaderLinkGate(),
                fence: { .init() },
                cuesArrived: {},
                endOfFile: { [weak self] in self?.endsOfFile += 1 },
                stopped: { [weak self] in self?.stops.append($0) }))
        }

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

    @Test("an indexed text rendition is complete at once, with nothing read ahead and no walk")
    func indexedRenditionsWhole() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        try await waitFor { rig.cueStores.values.allSatisfy(\.isFinished) }
        let counts = rig.cueStores.keys.sorted().map { rig.cues($0).count }
        #expect(counts.sorted() == [2, 3])
        #expect(!rig.source.isReading)
        #expect(rig.source.walkDemuxer == nil)
        #expect(rig.packetStore.frontier(streamIndex: rig.cueStores.keys.min()!) == nil)
    }

    @Test("the walk decodes its streams into their cue stores with the decoder the index uses")
    func walkDecodesLikeTheIndex() async throws {
        let indexed = try Rig(MP4SampleIndexTests.movText)
        defer { indexed.close() }
        try await waitFor { indexed.cueStores.values.allSatisfy(\.isFinished) }

        let walked = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { walked.close() }
        walked.source.demand(.rendition, lead: { _ in 3600 }, from: 0)
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

    @Test("one loop reads an indexed and a walked stream into the packet store; the index fills its rendition")
    func mixedRoutesOneLoop() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextCut)
        defer { rig.close() }
        let routes = await rig.source.routes()
        let walkedStream = try #require(routes.first { $0.value == .walked }?.key)
        let indexedStream = try #require(routes.first { $0.value != .walked }?.key)
        try await waitFor { rig.cueStores[indexedStream]?.isFinished == true }
        #expect(rig.cueStores[walkedStream]?.isFinished == false)

        rig.source.demand(.overlay, lead: { _ in 3600 }, from: 0)
        try await waitFor { rig.endsOfFile == 1 }
        #expect(!rig.packetStore.entries(streamIndex: walkedStream, from: 0, through: 20).isEmpty)
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
        rig.source.demand(.overlay, lead: { _ in 1 }, from: 0)
        try await waitFor { (rig.packetStore.frontier(streamIndex: stream) ?? -1) >= 0 }
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(rig.endsOfFile == 0)
        #expect((rig.packetStore.frontier(streamIndex: stream) ?? 0) < 6)
        rig.source.demand(.rendition, lead: { _ in 3600 })
        try await waitFor { rig.endsOfFile == 1 }
        #expect((rig.packetStore.frontier(streamIndex: stream) ?? 0) >= 6)
    }

    @Test("the reading stops once nobody asks, with the last reason; a re-ask in the same turn keeps it")
    func demandLifecycle() async throws {
        let rig = try Rig(MP4SampleIndexTests.movTextFragmented)
        defer { rig.close() }
        rig.restarting = true   // holds the walk before its open, so nothing races the assertions
        #expect(!rig.source.isReading)
        rig.source.demand(.ocr, lead: { _ in 60 })
        #expect(rig.source.isReading)
        rig.source.withdraw(.ocr)
        rig.source.demand(.ocr, lead: { _ in 60 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(rig.source.isReading)
        #expect(rig.stops.isEmpty)

        rig.source.demand(.overlay, lead: { _ in 75 })
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
        rig.source.demand(.rendition, lead: { _ in 3600 }, from: 0)
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(rig.source.walkDemuxer == nil)
        #expect(rig.cueStores.values.allSatisfy { $0.cueCount == 0 })
        rig.restarting = false
        try await waitFor { rig.endsOfFile == 1 }
        #expect(rig.cueStores.values.allSatisfy { $0.cueCount > 0 })
    }

    @Test("an index-only session needs no walk and ignores a restart in flight")
    func indexOnlyNeedsNoWalk() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        rig.restarting = true
        rig.source.demand(.overlay, lead: { _ in 3600 }, from: 0)
        try await waitFor { rig.endsOfFile == 1 }
        #expect(rig.source.walkDemuxer == nil)
        for stream in rig.cueStores.keys {
            #expect(!rig.packetStore.entries(streamIndex: stream, from: 0, through: 20).isEmpty)
        }
    }

    @Test("a move while the session opens is taken when it is positioned")
    func moveBeforeTheSessionIsPositioned() async throws {
        let rig = try Rig(MP4SampleIndexTests.movText)
        defer { rig.close() }
        rig.source.demand(.overlay, lead: { _ in 3600 }, from: 0)
        rig.source.move(to: 8)
        try await waitFor { rig.endsOfFile == 1 }
        let spans = rig.packetStore.harvestCoverageSpans
        #expect(spans.contains { $0.from >= 7.9 })
    }
}
