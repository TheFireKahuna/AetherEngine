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
        #expect(audioTag.contains("LANGUAGE="), "a rendition of its own states its language")
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

    @Test("the joined view gives each video fragment one moof of a traf per track over one mdat, every sample as the renditions cut it",
          .timeLimit(.minutes(2)), arguments: ["aac.mkv", "truehd.mkv", "eac3.mp4"])
    func joinedView(_ clip: String) throws {
        let url = Self.fixture(clip)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/determinism/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.plannedPanelIsInHDRMode = false
        _ = try engine.start()
        defer { engine.stop() }
        try #require(engine.outputShape == .demuxed)
        #expect(engine.mediaPlaylistURL?.lastPathComponent == "muxed.m3u8", "the playlist that plays alone is the joined view")
        let provider = try #require(engine.provider)
        let joinedInit = try #require(provider.muxedInitSegment(versionID: 0))
        let scales = Fragments.timescales(init: joinedInit)
        #expect(scales[1] != nil && scales[2] != nil, "both tracks in the joined init: \(scales)")
        for index in 1..<4 {
            let video = try #require(provider.mediaSegment(at: index))
            let audio = try #require(VideoSegmentProvider.drain(provider.audioSegmentSource(at: index, onSlow: nil)))
            let joined = try #require(VideoSegmentProvider.drain(provider.muxedSegmentSource(at: index, onSlow: nil)))
            // VOD segments are written in short fragments so they can be served while being written;
            // the joined view keeps the video's fragmenting and folds the audio into each fragment.
            let d = [UInt8](joined), vd = [UInt8](video)
            let top = Self.boxes(d, 0..<d.count).map(\.type).filter { $0 != "emsg" }
            let videoTop = Self.boxes(vd, 0..<vd.count).map(\.type).filter { $0 != "emsg" }
            #expect(top == videoTop, "seg\(index): \(top) against the video's \(videoTop)")
            #expect(!top.isEmpty && top.count.isMultiple(of: 2)
                    && zip(top, top.dropFirst()).enumerated().allSatisfy { i, pair in
                        i.isMultiple(of: 2) ? pair == ("moof", "mdat") : pair == ("mdat", "moof") },
                    "seg\(index): \(top)")
            let j = Fragments(joined), v = Fragments(video), a = Fragments(audio)
            #expect(j.tracks[1]?.samples == v.tracks[1]?.samples, "seg\(index): the video's samples")
            #expect(j.tracks[2]?.samples == a.tracks[1]?.samples, "seg\(index): the audio's samples, as track 2")
            #expect(j.tracks[2]?.tfdt == a.tracks[1]?.tfdt && j.tracks[1]?.tfdt == v.tracks[1]?.tfdt)
        }
    }

    @Test("audio that stops early is padded in the final audio segment, the indices between served without samples (#847)",
          .timeLimit(.minutes(2)))
    func tailPaddingLandsInTheFinalSegment() throws {
        let url = Self.fixture("ac3-short.mkv")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/determinism/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.plannedPanelIsInHDRMode = false
        let playback = try engine.start()
        defer { engine.stop() }
        try #require(engine.outputShape == .demuxed)
        let provider = try #require(engine.provider)
        // 24 s of picture over 9 s of 48 kHz AC-3; the plan's segments come from the media playlist.
        let media = try String(contentsOf: playback.deletingLastPathComponent().appendingPathComponent("media.m3u8"),
                               encoding: .utf8)
        let durations = media.split(separator: "\n").compactMap { line -> Double? in
            guard line.hasPrefix("#EXTINF:") else { return nil }
            return Double(line.dropFirst("#EXTINF:".count).prefix { $0 != "," })
        }
        let last = durations.count - 1
        let finalStart = durations.dropLast().reduce(0, +)
        try #require(last > 5 && abs(durations.reduce(0, +) - 24) < 0.05, "plan: \(durations)")
        let rate = 48_000.0
        var audio: [Fragments] = []
        for index in 0...last {
            let bytes = try #require(VideoSegmentProvider.drain(provider.audioSegmentSource(at: index, onSlow: nil)),
                                     "audio\(index)")
            audio.append(Fragments(bytes))
        }
        #expect(audio[4].tracks[1]?.samples.isEmpty == false, "audio4 holds the end of the source's audio")
        for index in 5..<last {
            #expect(audio[index].tracks[1]?.samples.isEmpty != false, "audio\(index) is served without samples")
        }
        let fill = try #require(audio[last].tracks[1]?.samples, "the final segment carries the fill")
        let first = try #require(fill.first), final = try #require(fill.last)
        let start = Double(first.decodeTime) / rate
        let end = Double(final.decodeTime + Int64(final.duration)) / rate
        #expect(abs(start - finalStart) < 0.05, "the fill starts at the final segment's start \(finalStart): \(start)")
        #expect(end <= 24.0 + 0.001 && end > 24.0 - 0.04, "the fill reaches the picture's end: \(end)")
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
