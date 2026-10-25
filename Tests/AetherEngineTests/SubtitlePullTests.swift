import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Layer 3 step 3: an indexed subtitle stream is read on request (`SubtitleSource.pull`), each frame where
/// the container's index places it, through the readers a session uses (a file read by `FileIOReader`, as
/// `AetherEngine.indexReader` opens it), into a packet store that keeps what was pulled.
@Suite("Pulls from the container's index")
struct SubtitlePullTests {

    /// The parser fixture's subtitle tracks as libavformat would list them: SubRip 2, zlib PGS 3,
    /// header-stripped PGS 4, each with the frame count its cues match.
    private static func listed(webVTT: Bool = false) -> [IndexedSubtitleStream] {
        let tb = AVRational(num: 1, den: 1000)
        return [
            .init(streamIndex: 10, codecName: webVTT ? "webvtt" : "subrip", frames: 2, timeBase: tb),
            .init(streamIndex: 11, codecName: "hdmv_pgs_subtitle", frames: 1, timeBase: tb),
            .init(streamIndex: 12, codecName: "hdmv_pgs_subtitle", frames: 1, timeBase: tb),
        ]
    }

    /// The fixture as a file on disk, its index read through the reader a session opens for it, and its
    /// streams as the source plans them.
    private struct Fixture {
        let url: URL
        let fixture: MatroskaCueIndexTests.Fixture
        let index: MatroskaCueIndex
        let streams: [SubtitleSource.IndexedStream]
        var readers: SubtitleSource.FrameReaders { .url(url, headers: [:]) }

        init(webVTT: Bool = false) throws {
            fixture = MatroskaCueIndexTests.fixture(webVTT: webVTT)
            url = FileManager.default.temporaryDirectory.appending(path: "pull-\(UUID().uuidString).mkv")
            try Data(fixture.bytes).write(to: url)
            let reader = try #require(AetherEngine.indexReader(url: url, headers: [:], label: "test"))
            defer { reader.close() }
            index = try MatroskaCueIndex.read(from: IOReaderByteSource(reader, closesReader: false),
                                              token: .forParserTests)
            let plan = SubtitleSource.plan(index: index, listed: SubtitlePullTests.listed(webVTT: webVTT),
                                           streams: [10, 11, 12])
            try #require(plan.refused.isEmpty, "\(plan.refused)")
            streams = plan.streams
        }

        func remove() { try? FileManager.default.removeItem(at: url) }

        /// Every frame of `stream` read and stored; the position of the first one not read.
        @discardableResult
        func pull(_ stream: SubtitleSource.IndexedStream, into store: SubtitlePacketStore,
                  readers: SubtitleSource.FrameReaders? = nil) -> Int? {
            let frames = SubtitleSource.readFrames(stream.blocks, track: stream.track, index: index,
                                                   readers: readers ?? self.readers, stop: .init())
            return SubtitleSource.storeFrames(frames, of: stream.blocks, stream: stream, index: index, into: store)
        }

        func stream(_ index: Int32) throws -> SubtitleSource.IndexedStream {
            try #require(streams.first { $0.streamIndex == index })
        }
    }

    @Test("a read stores every frame as its own packet, as libavformat hands it over")
    func framesAreStoredAsPackets() throws {
        let rig = try Fixture()
        defer { rig.remove() }
        let store = SubtitlePacketStore()
        for stream in rig.streams { #expect(rig.pull(stream, into: store) == nil) }

        let text = store.entries(streamIndex: 10, from: 0, through: 10)
        #expect(text.map(\.ptsSeconds) == [0.010, 5.100])
        #expect(text.map(\.payload) == [Data("Hello".utf8), Data("World".utf8)])
        #expect(text.map(\.durationSeconds) == [1.2, 0.9])
        #expect(text.allSatisfy { $0.flags & AV_PKT_FLAG_KEY != 0 })
        // The header-stripped track's frame comes back with its stripped bytes restored.
        let stripped = try #require(rig.fixture.expected[4]?.first?.1)
        #expect(store.entries(streamIndex: 12, from: 0, through: 10).map(\.payload) == [Data(stripped)])
        #expect(store.entries(streamIndex: 11, from: 0, through: 10).count == 1)
    }

    /// WebVTT is no reason to walk: its blocks are split the way libavformat splits them, so the store holds
    /// the cue text with its settings beside it, exactly what the walk stores (#233).
    @Test("a WebVTT stream's frames are stored with their settings")
    func webVTTKeepsItsSettings() throws {
        let rig = try Fixture(webVTT: true)
        defer { rig.remove() }
        let store = SubtitlePacketStore()
        rig.pull(try rig.stream(10), into: store)
        let cues = store.entries(streamIndex: 10, from: 0, through: 10)
        #expect(cues.map(\.payload) == [Data("Hello".utf8), Data("World".utf8)])
        #expect(cues.map(\.webvttSettings) == ["line:90% align:start", nil])
        #expect(cues.map(\.ptsSeconds) == [0.010, 5.100])
    }

    @Test("a pulled span runs through what was read and stops short of the first frame that was not")
    func pulledSpanFollowsTheRead() throws {
        let rig = try Fixture()
        defer { rig.remove() }
        let stream = try rig.stream(10)

        let first = rig.index.seconds(ticks: stream.blocks[0].ticks, track: stream.track)
        // A source that cannot be opened reads nothing: what is claimed is only the stretch before the first
        // frame, which the index itself says holds none.
        let missing = SubtitleSource.FrameReaders.url(rig.url.appending(path: "gone"), headers: [:])
        let unread = SubtitlePacketStore()
        let firstMissing = rig.pull(stream, into: unread, readers: missing)
        #expect(firstMissing == 0)
        SubtitleSource.notePulled(stream, from: 0, through: 10, blocks: stream.blocks, firstMissing: firstMissing,
                                  index: rig.index, focus: 0, into: unread)
        #expect(unread.pulledReach(streamIndex: 10, from: 0) == first.nextDown)
        #expect(unread.pulledReach(streamIndex: 10, from: first) == nil)

        // The second frame unread: the span ends just short of it, so the drain waits for its pull.
        let partial = SubtitlePacketStore()
        SubtitleSource.notePulled(stream, from: 0, through: 10, blocks: stream.blocks, firstMissing: 1,
                                  index: rig.index, focus: 0, into: partial)
        let second = rig.index.seconds(ticks: stream.blocks[1].ticks, track: stream.track)
        #expect(partial.pulledReach(streamIndex: 10, from: 0) == second.nextDown)

        let whole = SubtitlePacketStore()
        #expect(rig.pull(stream, into: whole) == nil)
        SubtitleSource.notePulled(stream, from: 0, through: 10, blocks: stream.blocks, firstMissing: nil,
                                  index: rig.index, focus: 0, into: whole)
        #expect(whole.pulledReach(streamIndex: 10, from: 3) == 10)
    }

    @Test("the next frame after a time is found by search, at or after it when asked to include it")
    func firstBlockSearch() throws {
        let rig = try Fixture()
        defer { rig.remove() }
        let stream = try rig.stream(10)
        let seconds = { (block: SourceIndexBlock) in rig.index.seconds(ticks: block.ticks, track: stream.track) }
        #expect(SubtitleSource.firstBlock(stream.blocks, after: 0, inclusive: false, seconds: seconds) == 0)
        #expect(SubtitleSource.firstBlock(stream.blocks, after: 0.010, inclusive: false, seconds: seconds) == 1)
        #expect(SubtitleSource.firstBlock(stream.blocks, after: 0.010, inclusive: true, seconds: seconds) == 0)
        #expect(SubtitleSource.firstBlock(stream.blocks, after: 9, inclusive: false, seconds: seconds) == 2)
    }

    @Test("per stream: a stream the index cannot stand in for is the walk's, and only that one")
    func planIsPerStream() throws {
        let rig = try Fixture()
        defer { rig.remove() }
        let index = rig.index
        // A stream whose codec disagrees with its track's makes the pairing itself untrustworthy, so no
        // stream is the index's.
        var mismatched = Self.listed()
        mismatched[0] = .init(streamIndex: 10, codecName: "webvtt", frames: 2, timeBase: mismatched[0].timeBase)
        let unpaired = SubtitleSource.plan(index: index, listed: mismatched, streams: [10, 11, 12])
        #expect(unpaired.streams.isEmpty)
        #expect(unpaired.refused == ["10: no track", "11: no track", "12: no track"])
        var incomplete = Self.listed()
        incomplete[0] = .init(streamIndex: 10, codecName: "subrip", frames: 3, timeBase: incomplete[0].timeBase)
        let partial = SubtitleSource.plan(index: index, listed: incomplete, streams: [10, 11, 12])
        #expect(partial.streams.map(\.streamIndex) == [11, 12])
        #expect(partial.refused == ["10: incomplete"])
        let unlisted = SubtitleSource.plan(index: index, listed: Self.listed(), streams: [10, 11, 12, 13])
        #expect(unlisted.streams.map(\.streamIndex) == [10, 11, 12])
        #expect(unlisted.refused == ["13: not listed"])
    }
}

/// The packet store as a cache of what was pulled.
@Suite("The packet store's pulled streams")
struct SubtitlePacketStorePullTests {

    private static func payload(_ byte: UInt8, _ count: Int = 100) -> Data { Data(repeating: byte, count: count) }

    @Test("a pulled stream is the pulls' alone: a harvest of it is passed over, others are stored")
    func harvestPassesOverPulledStreams() {
        let store = SubtitlePacketStore()
        store.setPulledStreams([3])
        store.harvestChunk(streamIndex: 3, ptsSeconds: 1, durationSeconds: 1, flags: 0, payload: Self.payload(1),
                           assembleSplitDisplaySets: false)
        store.harvestChunk(streamIndex: 4, ptsSeconds: 1, durationSeconds: 1, flags: 0, payload: Self.payload(2),
                           assembleSplitDisplaySets: false)
        #expect(store.entries(streamIndex: 3, from: 0, through: 5).isEmpty)
        #expect(store.entries(streamIndex: 4, from: 0, through: 5).count == 1)
        store.append(streamIndex: 3, ptsSeconds: 2, durationSeconds: 1, payload: Self.payload(3))
        #expect(store.entries(streamIndex: 3, from: 0, through: 5).count == 1)
    }

    @Test("over its cap a pulled stream gives up what lies farthest from its reader, and its spans with it")
    func evictionKeepsTheFocus() {
        let store = SubtitlePacketStore(perStreamByteCap: 1000, aggregateByteCap: 1_000_000)
        store.setPulledStreams([3])
        store.notePulled(streamIndex: 3, from: 0, through: 100, focus: 80)
        for second in stride(from: 0.0, through: 100, by: 10) {
            store.append(streamIndex: 3, ptsSeconds: second, durationSeconds: 1, payload: Self.payload(UInt8(second)))
        }
        // Eleven 100-byte frames against a 1000-byte cap: evicted to 900, the far end (the start) first.
        let kept = store.entries(streamIndex: 3, from: 0, through: 100).map(\.ptsSeconds)
        #expect(kept.first == 20)
        #expect(kept.last == 100)
        // The evicted stretch is no longer claimed, so a drain landing there pulls it again.
        #expect(store.pulledReach(streamIndex: 3, from: 5) == nil)
        #expect(store.pulledReach(streamIndex: 3, from: 50) == 100)
        #expect(store.pulledSpans(streamIndex: 3).first?.from == 10.0.nextUp)
    }

    @Test("pulled spans merge where they touch, answer reach, and clip at either end")
    func spans() {
        var spans = PulledSpans()
        spans.insert(from: 0, through: 10)
        spans.insert(from: 20, through: 30)
        #expect(spans.spans.count == 2)
        spans.insert(from: 10, through: 20)
        #expect(spans.spans == [.init(from: 0, through: 30)])
        #expect(spans.reach(from: 5) == 30)
        #expect(spans.reach(from: 31) == nil)
        spans.clip(above: 5)
        spans.clip(below: 25)
        #expect(spans.spans == [.init(from: 5.0.nextUp, through: 25.0.nextDown)])
        spans.clip(above: 40)
        #expect(spans.spans.isEmpty)
    }
}
