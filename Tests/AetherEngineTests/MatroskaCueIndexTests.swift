import Testing
import Foundation
import Compression
import AetherLibavutil
@testable import AetherEngine

/// `MatroskaCueIndex` on a Matroska file assembled here byte by byte: the index is read through the
/// SeekHead, blocks are found from their cue positions whatever length their cluster's size field has,
/// a track is complete only when its cues number its frames, and frames come back as libavformat hands
/// them over (a stripped header restored, zlib inflated, a WebVTT block split).
@Suite("Matroska cue index")
struct MatroskaCueIndexTests {

    // MARK: - A small Matroska writer

    private static func idBytes(_ id: UInt32) -> [UInt8] {
        var bytes: [UInt8] = []
        var value = id
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return bytes
    }

    private static func size(_ n: Int, length: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: length)
        var value = UInt64(n)
        for k in stride(from: length - 1, through: 0, by: -1) { bytes[k] = UInt8(value & 0xFF); value >>= 8 }
        bytes[0] |= UInt8(0x80 >> (length - 1))
        return bytes
    }

    private static func element(_ id: UInt32, _ data: [UInt8], sizeLength: Int = 8) -> [UInt8] {
        idBytes(id) + size(data.count, length: sizeLength) + data
    }

    private static func uint(_ id: UInt32, _ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return element(id, bytes)
    }

    private static func block(track: UInt8, payload: [UInt8], duration: UInt64? = nil, simple: Bool = false) -> [UInt8] {
        let body = [0x80 | track, 0x00, 0x00, simple ? 0x80 : 0x00] + payload
        if simple { return element(0xA3, body) }
        var group = element(0xA1, body)
        if let duration { group += uint(0x9B, duration) }
        return element(0xA0, group)
    }

    struct Fixture {
        var bytes: [UInt8]
        /// Per track: (ticks, expected payload, duration).
        var expected: [UInt64: [(Int64, [UInt8], Int64?)]]
    }

    /// Video track 1, text track 2, zlib PGS track 3, header-stripped track 4; clusters with 3- and
    /// 8-byte size fields; cues for every subtitle block, and for one video block without a relative
    /// position.
    /// `webVTT`: track 2 is S_TEXT/WEBVTT, its blocks an identifier line, a settings line and the text,
    /// the way libavformat reads them (`matroska_parse_webvtt`).
    static func fixture(dropCueFor dropTrack: UInt64? = nil, webVTT: Bool = false) -> Fixture {
        let ebml = element(0x1A45DFA3, element(0x4282, Array("matroska".utf8)))
        let info = element(0x1549A966, uint(0x2AD7B1, 1_000_000))
        let tracks = element(0x1654AE6B,
            element(0xAE, uint(0xD7, 1) + uint(0x83, 1))
            + element(0xAE, uint(0xD7, 2) + uint(0x83, 0x11)
                      + element(0x86, Array((webVTT ? "S_TEXT/WEBVTT" : "S_TEXT/UTF8").utf8)))
            + element(0xAE, uint(0xD7, 3) + uint(0x83, 0x11) + element(0x86, Array("S_HDMV/PGS".utf8))
                      + element(0x6D80, element(0x6240, element(0x5034, uint(0x4254, 0)))))
            + element(0xAE, uint(0xD7, 5) + uint(0x83, 0x11) + element(0x86, Array("X_NOT_A_SUBTITLE".utf8)))
            + element(0xAE, uint(0xD7, 4) + uint(0x83, 0x11) + element(0x86, Array("S_HDMV/PGS".utf8))
                      + element(0x6D80, element(0x6240, element(0x5034, uint(0x4254, 3)
                                                                      + element(0x4255, [0xAB, 0xCD]))))))
        let pgsPlain = pgsDisplaySet(state: 0x80, forced: true)
        let pgs = zlibWrapped(pgsPlain)
        let stripped: [UInt8] = [0x01, 0x02]
        // Cluster contents: (track, ticks, payload, duration, simple).
        let clusters: [(sizeLength: Int, ticks: Int64, blocks: [(UInt8, Int64, [UInt8], UInt64?, Bool)])] = [
            (3, 0, [(1, 0, [UInt8](repeating: 0x11, count: 300), nil, true),
                    (2, 10, Array((webVTT ? "cue-1\nline:90% align:start\nHello" : "Hello").utf8), 1200, false),
                    (3, 20, pgs, nil, false)]),
            (8, 5000, [(1, 5000, [UInt8](repeating: 0x22, count: 500), nil, true),
                       (2, 5100, Array((webVTT ? "\r\n\r\nWorld\r\n" : "World").utf8), 900, false),
                       (4, 5200, stripped, nil, true)]),
        ]
        // Layout: SeekHead (fixed size, filled in after), Info, Tracks, clusters, Cues.
        let seekHeadSize = 80
        var body: [UInt8] = []
        var positions: [UInt32: Int] = [:]
        body += [UInt8](repeating: 0, count: seekHeadSize)
        positions[0x1549A966] = body.count; body += info
        positions[0x1654AE6B] = body.count; body += tracks
        var cues: [UInt8] = []
        var expected: [UInt64: [(Int64, [UInt8], Int64?)]] = [:]
        for cluster in clusters {
            let clusterPosition = body.count
            var data = uint(0xE7, UInt64(cluster.ticks))
            for (track, ticks, payload, duration, simple) in cluster.blocks {
                let relative = data.count
                data += block(track: track, payload: payload, duration: duration, simple: simple)
                if track != 1 || dropTrack == 1 {
                    if UInt64(track) != dropTrack {
                        cues += element(0xBB, uint(0xB3, UInt64(ticks)) + element(0xB7,
                            uint(0xF7, UInt64(track)) + uint(0xF1, UInt64(clusterPosition)) + uint(0xF0, UInt64(relative))))
                    }
                } else {
                    cues += element(0xBB, uint(0xB3, UInt64(ticks)) + element(0xB7,
                        uint(0xF7, 1) + uint(0xF1, UInt64(clusterPosition))))
                }
                if track != 1 {
                    // As libavformat hands frames over: stripped bytes restored, zlib inflated.
                    let restored = track == 4 ? [0xAB, 0xCD] + payload : track == 3 ? pgsPlain : payload
                    expected[UInt64(track), default: []].append((ticks, restored, duration.map { Int64($0) }))
                }
            }
            body += idBytes(0x1F43B675) + size(data.count, length: cluster.sizeLength) + data
        }
        positions[0x1C53BB6B] = body.count
        body += element(0x1C53BB6B, cues)
        var seek: [UInt8] = []
        for id in [UInt32(0x1549A966), 0x1654AE6B, 0x1C53BB6B] {
            let position = UInt32(positions[id]!)
            let positionBytes: [UInt8] = [UInt8(position >> 24), UInt8((position >> 16) & 0xFF),
                                          UInt8((position >> 8) & 0xFF), UInt8(position & 0xFF)]
            seek += element(0x4DBB, element(0x53AB, idBytes(id), sizeLength: 1)
                            + element(0x53AC, positionBytes, sizeLength: 1), sizeLength: 1)
        }
        var seekHead = element(0x114D9B74, seek)
        precondition(seekHead.count <= seekHeadSize)
        // Pad with a Void element so the next element starts where the positions say.
        let pad = seekHeadSize - seekHead.count
        if pad > 0 { seekHead += [0xEC] + size(pad - 9, length: 8) + [UInt8](repeating: 0, count: pad - 9) }
        body.replaceSubrange(0..<seekHeadSize, with: seekHead)
        return Fixture(bytes: ebml + element(0x18538067, body), expected: expected)
    }

    private static func pgsDisplaySet(state: UInt8, forced: Bool) -> [UInt8] {
        // PCS: 1920x1080, frame rate, composition 1, state, no palette update, palette 0, one object.
        let pcs: [UInt8] = [0x07, 0x80, 0x04, 0x38, 0x10, 0x00, 0x01, state, 0x00, 0x00, 0x01,
                            0x00, 0x00, 0x00, forced ? 0x40 : 0x00, 0x00, 0x10, 0x03, 0x00]
        // An object segment of incompressible bytes, so a short read of the frame is a true prefix of it.
        let ods: [UInt8] = (0..<600).map { UInt8(($0 * 7919 + 13) % 251) }
        return [0x16, 0x00, UInt8(pcs.count)] + pcs + [0x15, 0x02, 0x58] + ods + [0x80, 0x00, 0x00]
    }

    private static func zlibWrapped(_ bytes: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: bytes.count + 64)
        let n = compression_encode_buffer(&out, out.count, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        return [0x78, 0x9C] + out.prefix(n) + [0, 0, 0, 0]
    }

    private func source(_ fixture: Fixture) -> IOReaderByteSource {
        IOReaderByteSource(DataIOReader(data: Data(fixture.bytes)))
    }

    // MARK: - Tests

    /// libavformat's split, case for case: what the walk's packet would carry is what the index's does.
    @Test("a WebVTT block splits into text and settings as libavformat splits it")
    func webVTTSplitMatchesTheDemuxer() throws {
        let plain = try #require(MatroskaCueIndex.webVTTCue(Array("cue-1\nline:90% align:start\nHello\nthere\n".utf8)))
        #expect(String(decoding: plain.text, as: UTF8.self) == "Hello\nthere")
        #expect(plain.settings == "line:90% align:start")
        let crlf = try #require(MatroskaCueIndex.webVTTCue(Array("\r\n\r\nWorld\r\n".utf8)))
        #expect(String(decoding: crlf.text, as: UTF8.self) == "World")
        #expect(crlf.settings.isEmpty)
        #expect(MatroskaCueIndex.webVTTCue(Array("no settings line".utf8)) == nil)
        #expect(MatroskaCueIndex.webVTTCue(Array("id\nsettings\n\n".utf8)) == nil, "an empty text is refused")
    }

    @Test("a WebVTT block is read as its packet: the cue text, with the settings beside it")
    func webVTTFrames() throws {
        let fixture = Self.fixture(webVTT: true)
        let src = source(fixture)
        let index = try MatroskaCueIndex.read(from: src, token: .forParserTests)
        let frames = try index.blocks(track: 2).map { try #require(index.readFrame($0, track: 2, from: src)) }
        #expect(frames.map(\.payload) == [Array("Hello".utf8), Array("World".utf8)])
        #expect(frames.map(\.webVTTSettings) == ["line:90% align:start", nil])
    }

    /// The video track's cues are its keyframes: kept with the cluster they name even where the muxer
    /// wrote no relative position (the fixture's video cues have none), in time order, and each one's
    /// byte offset is where its cluster begins.
    @Test("video keyframes are listed with their clusters, relative position or not")
    func videoKeyframes() throws {
        let fixture = Self.fixture()
        let index = try MatroskaCueIndex.read(from: source(fixture), token: .forParserTests)
        #expect(index.videoTracks.map(\.number) == [1])
        let keyframes = index.keyframes(track: 1)
        #expect(keyframes.map(\.ticks) == [0, 5000])
        #expect(keyframes.allSatisfy { $0.relativePosition == nil })
        for keyframe in keyframes {
            let at = Int(index.byteOffset(of: keyframe))
            #expect(Array(fixture.bytes[at..<(at + 4)]) == [0x1F, 0x43, 0xB6, 0x75],
                    "keyframe at \(keyframe.ticks) does not point at a Cluster")
        }
        #expect(index.keyframes(track: 2).isEmpty, "a subtitle track is not a video track")
    }

    @Test("the index is found through the SeekHead and lists every subtitle block in time order")
    func readsIndex() throws {
        let fixture = Self.fixture()
        let index = try MatroskaCueIndex.read(from: source(fixture), token: .forParserTests)
        #expect(index.timestampScale == 1_000_000)
        #expect(index.blocksByTrack[2]?.map(\.ticks) == [10, 5100])
        #expect(index.blocksByTrack[3]?.count == 1)
        #expect(index.blocksByTrack[4]?.count == 1)
        #expect(index.tracksMissingRelativePosition == [1])
        #expect(index.encodingByTrack[3] == .zlib)
        #expect(index.encodingByTrack[4] == .strippedHeader([0xAB, 0xCD]))
    }

    @Test("a block is read whatever its cluster's size field length, with its duration, a stripped header restored and zlib inflated")
    func readsFrames() throws {
        let fixture = Self.fixture()
        let src = source(fixture)
        let index = try MatroskaCueIndex.read(from: src, token: .forParserTests)
        for track: UInt64 in [2, 3, 4] {
            for (block, expected) in zip(index.blocksByTrack[track]!, fixture.expected[track]!) {
                let frame = try #require(index.readFrame(block, track: track, from: src))
                #expect(frame.ticks == expected.0)
                #expect(frame.payload == expected.1)
                #expect(frame.durationTicks == expected.2)
            }
        }
    }

    @Test("a track is complete only when its cues number its frames, all addressable and decodable")
    func completeness() throws {
        let index = try MatroskaCueIndex.read(from: source(Self.fixture()), token: .forParserTests)
        #expect(index.isComplete(track: 2, frameCount: 2))
        #expect(!index.isComplete(track: 2, frameCount: 3))
        #expect(!index.isComplete(track: 2, frameCount: nil))
        #expect(!index.isComplete(track: 1, frameCount: 2))
        let dropped = try MatroskaCueIndex.read(from: source(Self.fixture(dropCueFor: 3)), token: .forParserTests)
        #expect(!dropped.isComplete(track: 3, frameCount: 1))
    }

    @Test("a file that is not Matroska, or has no Cues, is refused")
    func refusals() {
        #expect(throws: SourceIndexError.unsupportedContainer) {
            try MatroskaCueIndex.read(from: IOReaderByteSource(DataIOReader(data: Data(repeating: 7, count: 4096))), token: .forParserTests)
        }
    }

    // MARK: - Streams to tracks

    private static let ms = AVRational(num: 1, den: 1000)

    private static func mappingIndex() -> MatroskaCueIndex {
        var index = MatroskaCueIndex(segmentDataStart: 0, timestampScale: 1_000_000, blocksByTrack: [:],
                                          tracksMissingRelativePosition: [], encodingByTrack: [:])
        index.subtitleTracks = [
            .init(number: 18, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 30_000_000),
            .init(number: 19, codecName: "subrip", language: "eng", frames: 1326, bytes: 40_000),
            .init(number: 22, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 31_000_000),
        ]
        return index
    }

    @Test("a stream carrying its TrackNumber maps to that track")
    func mapsByTrackID() {
        let index = Self.mappingIndex()
        let streams: [IndexedSubtitleStream] = [
            .init(streamIndex: 17, trackID: 18, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 30_000_000, timeBase: Self.ms),
            .init(streamIndex: 18, trackID: 19, codecName: "subrip", language: "eng", frames: 1326, bytes: 40_000, timeBase: Self.ms),
            .init(streamIndex: 21, trackID: 22, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 31_000_000, timeBase: Self.ms),
        ]
        #expect(index.trackNumbers(for: streams) == [17: 18, 18: 19, 21: 22])
    }

    @Test("without track numbers the order maps, and a pair whose statistics disagree refuses the whole map")
    func mapsByOrderAndRefuses() {
        let index = Self.mappingIndex()
        var streams: [IndexedSubtitleStream] = [
            .init(streamIndex: 17, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 30_000_000, timeBase: Self.ms),
            .init(streamIndex: 18, codecName: "subrip", language: "eng", frames: 1326, bytes: 40_000, timeBase: Self.ms),
            .init(streamIndex: 21, codecName: "hdmv_pgs_subtitle", language: "eng", frames: 2909, bytes: 31_000_000, timeBase: Self.ms),
        ]
        #expect(index.trackNumbers(for: streams) == [17: 18, 18: 19, 21: 22])
        // Two PGS tracks with the same frame count swapped: only the byte count tells them apart.
        streams[0].bytes = 31_000_000
        streams[2].bytes = 30_000_000
        #expect(index.trackNumbers(for: streams).isEmpty)
        // A count that does not line up maps nothing.
        #expect(index.trackNumbers(for: Array(streams.prefix(2))).isEmpty)
    }

    @Test("a subtitle TrackEntry libavformat skips (no S or D CodecID) is not counted")
    func skippedEntriesAreNotCounted() throws {
        let fixture = Self.fixture()
        let index = try MatroskaCueIndex.read(from: source(fixture), token: .forParserTests)
        #expect(index.subtitleTracks.map(\.number) == [2, 3, 4])
    }

    // MARK: - Reading as far ahead as the player asks

    @Test("a feeder reads past its fixed lead to where the player asked, plus a margin")
    func demandLead() {
        #expect(AetherEngine.subtitleReadAhead(base: 300, playhead: 100, requested: nil) == 300)
        #expect(AetherEngine.subtitleReadAhead(base: 300, playhead: 100, requested: 200) == 300)
        #expect(AetherEngine.subtitleReadAhead(base: 240, playhead: 100, requested: 450)
                == 350 + AetherEngine.subtitleDemandMarginSeconds)
    }

    @Test("the store keeps the furthest window the player asked for, on the source axis")
    func requestedHorizon() {
        let store = NativeSubtitleCueStore()
        #expect(store.furthestRequestedSourceSeconds() == nil)
        store.setShiftSeconds(2)
        store.noteRequested(through: 400)
        store.noteRequested(through: 380)
        #expect(store.furthestRequestedSourceSeconds() == 402)
    }
}
