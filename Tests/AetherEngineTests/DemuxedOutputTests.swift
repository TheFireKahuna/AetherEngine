import Foundation
import Testing
@testable import AetherEngine

/// The demuxed shape's output (docs/demuxed-audio.md): the master names the audio rendition, the two media playlists
/// list the same segments, an index with no audio is served without samples, and the audio rendition's requests do
/// not move the producer.
@Suite("The audio as a rendition of its own", .serialized)
struct DemuxedOutputTests {

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/determinism").appendingPathComponent(name)
    }

    private static func boxes(_ d: [UInt8], _ range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            let size = Int(d[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) })
            guard size >= 8, at + size <= range.upperBound else { break }
            out.append((String(decoding: d[at + 4..<at + 8], as: UTF8.self), at + 8..<at + size))
            at += size
        }
        return out
    }

    @Test("a fragment with no sample is a moof of one run-less track fragment at its decode time, and an empty mdat")
    func emptyFragment() {
        let d = [UInt8](MP4SegmentMuxer.emptyFragment(trackID: 1, sequence: 7, baseMediaDecodeTime: 96_000))
        let top = Self.boxes(d, 0..<d.count)
        #expect(top.map(\.type) == ["moof", "mdat"])
        #expect(top[1].body.isEmpty)
        let moof = Self.boxes(d, top[0].body)
        #expect(moof.map(\.type) == ["mfhd", "traf"])
        let traf = Self.boxes(d, moof[1].body)
        #expect(traf.map(\.type) == ["tfhd", "tfdt"], "no trun")
        let tfhd = traf[0].body
        #expect(d[tfhd.lowerBound + 4..<tfhd.lowerBound + 8].reduce(0) { $0 << 8 | UInt32($1) } == 1)
        let tfdt = traf[1].body
        #expect(d[tfdt.lowerBound] == 1, "version 1")
        #expect(d[tfdt.lowerBound + 4..<tfdt.lowerBound + 12].reduce(0) { $0 << 8 | UInt64($1) } == 96_000)
    }

    @Test("segment paths name their rendition")
    func segmentRoutes() {
        #expect(HLSLocalServer.segmentRoute("/seg12.mp4").map { "\($0.rendition)\($0.index)" } == "video12")
        #expect(HLSLocalServer.segmentRoute("/audio3.mp4").map { "\($0.rendition)\($0.index)" } == "audio3")
        #expect(HLSLocalServer.segmentRoute("/init.mp4") == nil)
        #expect(HLSLocalServer.segmentRoute("/seg3.m4s") == nil)
    }

    @Test("a planned master is demuxed; no plan, and a media playlist plan, are muxed")
    func shapeForPlan() {
        #expect(HLSOutputShape.forPlan(servesMaster: true, carriesAudio: true) == .demuxed)
        #expect(HLSOutputShape.forPlan(servesMaster: true, carriesAudio: false) == .muxed)
        #expect(HLSOutputShape.forPlan(servesMaster: false, carriesAudio: true) == .muxed)
        #expect(HLSOutputShape.forPlan(servesMaster: nil, carriesAudio: true) == .muxed)
    }

    @Test("the master names the audio rendition, whose playlist lists the video's segments", .timeLimit(.minutes(2)),
          arguments: ["aac.mkv", "truehd.mkv", "ac3.ts"])
    func playlistsAgree(_ clip: String) throws {
        let url = Self.fixture(clip)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/determinism/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.plannedPanelIsInHDRMode = false
        let playback = try engine.start()
        defer { engine.stop() }
        try #require(engine.outputShape == .demuxed)
        let master = try String(contentsOf: playback, encoding: .utf8)
        let audioTag = try #require(master.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MEDIA:TYPE=AUDIO") })
        #expect(audioTag.contains("URI=\"audio.m3u8\""))
        #expect(audioTag.contains("LANGUAGE="), "a rendition of its own states its language (8.10)")
        let base = playback.deletingLastPathComponent()
        let media = try String(contentsOf: base.appendingPathComponent("media.m3u8"), encoding: .utf8)
        let audio = try String(contentsOf: base.appendingPathComponent("audio.m3u8"), encoding: .utf8)
        func shape(_ text: String) -> [String] {
            text.split(separator: "\n").map(String.init).map { line in
                line.hasPrefix("#EXT-X-MAP") ? "MAP" : line.hasSuffix(".mp4") && !line.hasPrefix("#") ? "SEGMENT" : line
            }
        }
        #expect(shape(audio) == shape(media), "the same indices, durations and tags")
        #expect(audio.contains("audio-init.mp4") && audio.contains("audio0.mp4"))
        #expect(!media.contains("audio"))
    }

    @Test("the audio rendition's requests wait for the producer rather than restart it", .timeLimit(.minutes(2)))
    func audioRequestsDoNotRestart() throws {
        let url = Self.fixture("aac.mkv")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/determinism/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.plannedPanelIsInHDRMode = false
        _ = try engine.start()
        defer { engine.stop() }
        let provider = try #require(engine.provider)
        let restarts = engine.producerRestartCount
        // Ahead of the video, as AVPlayer's audio requests can be: the producer reaches them on its march.
        for index in 0..<4 {
            let audio = VideoSegmentProvider.drain(provider.audioSegmentSource(at: index, onSlow: nil))
            #expect(audio?.isEmpty == false, "audio\(index)")
        }
        #expect(engine.producerRestartCount == restarts)
    }
}
