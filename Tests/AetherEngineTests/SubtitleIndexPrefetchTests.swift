import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// The forward prefetch read from the container's index (#151): the same packets the stream walk
/// would store, in one time order, through the one prefetch loop.
@Suite("Forward subtitle prefetch from the container's index")
struct SubtitleIndexPrefetchTests {

    /// The parser fixture's subtitle tracks as libavformat would list them: SubRip 2, zlib PGS 3,
    /// header-stripped PGS 4, each with the frame count its cues match.
    private static func listed() -> [IndexedSubtitleStream] {
        let tb = AVRational(num: 1, den: 1000)
        return [
            .init(streamIndex: 10, codecName: "subrip", frames: 2, timeBase: tb),
            .init(streamIndex: 11, codecName: "hdmv_pgs_subtitle", frames: 1, timeBase: tb),
            .init(streamIndex: 12, codecName: "hdmv_pgs_subtitle", frames: 1, timeBase: tb),
        ]
    }

    private static func indexed() throws -> (MatroskaCueIndex, MatroskaCueIndexTests.Fixture) {
        let fixture = MatroskaCueIndexTests.fixture()
        let index = try MatroskaCueIndex.read(
            from: IOReaderByteSource(DataIOReader(data: Data(fixture.bytes))), token: .forParserTests)
        return (index, fixture)
    }

    private static func source(_ index: MatroskaCueIndex, _ fixture: MatroskaCueIndexTests.Fixture,
                               from seconds: Double = 0) throws -> SubtitleForwardPrefetcher.IndexSource {
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(
            index: index, listed: listed(), streams: [10, 11, 12])
        try #require(plan.refused.isEmpty, "\(plan.refused)")
        return SubtitleForwardPrefetcher.IndexSource(
            index: index, bytes: IOReaderByteSource(DataIOReader(data: Data(fixture.bytes))),
            streams: plan.streams, assemblyIndices: [], from: seconds)
    }

    @Test("Every stream's blocks come in one time order, each stored as its own packet")
    func blocksComeInOneTimeOrder() throws {
        let (index, fixture) = try Self.indexed()
        let source = try Self.source(index, fixture)
        let store = SubtitlePacketStore()
        var positions: [Double] = []
        while case .harvested(let at) = try source.step(into: store) { positions.append(try #require(at)) }
        #expect(positions == [0.010, 0.020, 5.100, 5.200])

        let text = store.entries(streamIndex: 10, from: 0, through: 10)
        #expect(text.map(\.ptsSeconds) == [0.010, 5.100])
        #expect(text.map(\.payload) == [Data("Hello".utf8), Data("World".utf8)])
        #expect(text.map(\.durationSeconds) == [1.2, 0.9])
        #expect(text.allSatisfy { $0.flags & AV_PKT_FLAG_KEY != 0 })
        // The header-stripped track's frame comes back with its stripped bytes restored.
        let stripped = try #require(fixture.expected[4]?.first?.1)
        #expect(store.entries(streamIndex: 12, from: 0, through: 10).map(\.payload) == [Data(stripped)])
        #expect(store.entries(streamIndex: 11, from: 0, through: 10).count == 1)
    }

    @Test("A re-anchor moves every stream's cursor to the target, less the walk's backscan")
    func reanchorMovesTheCursors() throws {
        let (index, fixture) = try Self.indexed()
        let source = try Self.source(index, fixture)
        let reanchor = SubtitleForwardPrefetcher.SideReaderReanchor(
            anchorStreamIndex: 10, fallbackDuration: 0, seekTimeout: 1)
        #expect(source.reposition(to: 6.0, reanchor: reanchor) == "index")
        let store = SubtitlePacketStore()
        var positions: [Double] = []
        while case .harvested(let at) = try source.step(into: store) { positions.append(try #require(at)) }
        #expect(positions == [5.100, 5.200])
    }

    @Test("A dropped connection ends the session as a read failure; one misplaced block is skipped")
    func unreadableBlocks() throws {
        let (index, _) = try Self.indexed()
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: Self.listed(), streams: [10, 11, 12])
        let dead = IOReaderByteSource(DataIOReader(data: Data()))
        let source = SubtitleForwardPrefetcher.IndexSource(
            index: index, bytes: dead, streams: plan.streams, assemblyIndices: [], from: 0)
        let store = SubtitlePacketStore()
        // Four blocks in the fixture, all unreadable: skipped one by one, then the end of the index.
        for _ in 0..<4 { #expect(try source.step(into: store) == .skipped) }
        #expect(try source.step(into: store) == .endOfFile)

        let many = SubtitleForwardPrefetcher.IndexSource.Stream(
            streamIndex: 10, track: 2,
            blocks: Array(repeating: index.blocksByTrack[2]![0], count: SubtitleForwardPrefetcher.IndexSource.readFailureLimit))
        let failing = SubtitleForwardPrefetcher.IndexSource(
            index: index, bytes: dead, streams: [many], assemblyIndices: [], from: 0)
        for _ in 1..<SubtitleForwardPrefetcher.IndexSource.readFailureLimit {
            #expect(try failing.step(into: store) == .skipped)
        }
        #expect(throws: SubtitleForwardPrefetcher.IndexSource.IndexReadFailure.self) {
            try failing.step(into: store)
        }
    }

    @Test("All or nothing: one stream the index cannot stand in for leaves the whole session to the walk")
    func planIsAllOrNothing() throws {
        let (index, _) = try Self.indexed()
        var webvtt = Self.listed()
        webvtt[0] = .init(streamIndex: 10, codecName: "webvtt", frames: 2, timeBase: webvtt[0].timeBase)
        #expect(!SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: webvtt, streams: [10, 11, 12])
            .refused.isEmpty)
        var incomplete = Self.listed()
        incomplete[0] = .init(streamIndex: 10, codecName: "subrip", frames: 3, timeBase: incomplete[0].timeBase)
        #expect(!SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: incomplete, streams: [10, 11, 12])
            .refused.isEmpty)
        #expect(SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: Self.listed(), streams: [10, 11, 12])
            .refused.isEmpty)
    }

    @Test("The one prefetch loop runs the index to its end, with the walk's anchor and progress notes",
          .timeLimit(.minutes(1)))
    func theLoopRunsTheIndex() async throws {
        let (index, fixture) = try Self.indexed()
        let source = try Self.source(index, fixture)
        let store = SubtitlePacketStore()
        let outcome = await SubtitleForwardPrefetcher.run(
            source: source, store: store, leadSeconds: 60, parkPollNanoseconds: 1_000_000,
            playhead: { 0 })
        #expect(outcome.exit == .endOfFile)
        #expect(outcome.harvested == 4)
        #expect(store.entries(streamIndex: 10, from: 0, through: 10).count == 2)
        #expect(store.hasReadSpan(from: 0.5, through: 5.0))
    }

    /// WebVTT is no longer a reason to walk: its blocks are split the way libavformat splits them, so
    /// the store holds the cue text with its settings beside it, exactly what the walk stores (#233).
    @Test("a WebVTT stream is read from the index, its text stored with its settings")
    func webVTTFromTheIndex() throws {
        let fixture = MatroskaCueIndexTests.fixture(webVTT: true)
        let index = try MatroskaCueIndex.read(
            from: IOReaderByteSource(DataIOReader(data: Data(fixture.bytes))), token: .forParserTests)
        var listed = Self.listed()
        listed[0] = .init(streamIndex: 10, codecName: "webvtt", frames: 2, timeBase: listed[0].timeBase)
        let plan = SubtitleForwardPrefetcher.IndexSource.plan(index: index, listed: listed, streams: [10, 11, 12])
        #expect(plan.refused.isEmpty, "\(plan.refused)")
        let source = SubtitleForwardPrefetcher.IndexSource(
            index: index, bytes: IOReaderByteSource(DataIOReader(data: Data(fixture.bytes))),
            streams: plan.streams, assemblyIndices: [], from: 0)
        let store = SubtitlePacketStore()
        while case .harvested = try source.step(into: store) {}
        let cues = store.entries(streamIndex: 10, from: 0, through: 10)
        #expect(cues.map(\.payload) == [Data("Hello".utf8), Data("World".utf8)])
        #expect(cues.map(\.webvttSettings) == ["line:90% align:start", nil])
        #expect(cues.map(\.ptsSeconds) == [0.010, 5.100])
    }
}
