import AetherLibavcodec
import Foundation
import Testing
@testable import AetherEngine

/// HLS takes a presentation to be one continuous encode cut into segments, so segment N must be the same
/// bytes however playback reached it. The parts are held to that below the producer (`AudioSegmentRunsTests`,
/// `SpatialSegmentRunsTests`, `CopiedAudioTimingTests`); this holds the whole of it, a real session's
/// producer, gate and muxer: every segment a seeking session serves is the one a session playing straight
/// through served, per audio route. When one differs, the failure names the segment, the track and the
/// first sample that differs, and how.
@Suite("The producer's segments are the same however playback reached them", .serialized)
struct ProducerDeterminismTests {

    struct Route: CustomTestStringConvertible, Sendable {
        let clip: String
        var mode: AudioBridgeMode = .surroundCompat
        var delay: Double = 0
        var testDescription: String {
            clip + (["opus.mkv", "dts.mkv", "truehd.mkv"].contains(clip) ? " \(mode)" : "")
                + (delay == 0 ? "" : " delay \(delay)")
        }
    }

    /// Copied from Matroska (Cues), MPEG-TS (the uniform grid) and MP4; bridged from Opus, DTS and TrueHD
    /// in both bridge modes; an audio delay either way.
    static let routes: [Route] = [
        .init(clip: "aac.mkv"), .init(clip: "ac3.ts"), .init(clip: "eac3.mp4"), .init(clip: "flac.mkv"),
        .init(clip: "opus.mkv"), .init(clip: "dts.mkv"), .init(clip: "dts.mkv", mode: .lossless),
        .init(clip: "truehd.mkv"), .init(clip: "truehd.mkv", mode: .lossless),
        .init(clip: "truehd.mkv", delay: 0.15), .init(clip: "aac.mkv", delay: -0.15),
    ]

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/determinism").appendingPathComponent(name)
    }

    @Test("every segment a seeking session serves is the one continuous playback served",
          .timeLimit(.minutes(4)), arguments: routes)
    func seeksServeContinuousSegments(_ route: Route) throws {
        let url = Self.fixture(route.clip)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/determinism/")

        let continuous = HLSVideoEngine(url: url, dvModeAvailable: false, audioBridgeMode: route.mode)
        continuous.audioDelaySeconds = route.delay
        let playback = try continuous.start()
        defer { continuous.stop() }
        let reference = try #require(continuous.provider)
        let count = reference.segmentCount
        try #require(count >= 6, "\(count) segments")
        var want: [Int: Data] = [:]
        for index in 0..<count { want[index] = reference.mediaSegment(at: index) }
        try #require(want.count == count && want.values.allSatisfy { !$0.isEmpty }, "continuous playback served every segment")
        #expect(continuous.audioBridge != nil || !["opus.mkv", "dts.mkv", "truehd.mkv"].contains(route.clip))
        let wantTracks = Fragments(want[1]!).tracks.count
        #expect(wantTracks == 2, "video and audio: \(wantTracks) tracks")

        // A segment has sound from its first picture: a packet that straddles a boundary opens the
        // segment after it, so a seek to a segment's start is not silent until the next audio frame.
        // From segment 1: before the timeline's start there is nothing to play.
        var base = try #require(URLComponents(url: playback.deletingLastPathComponent(), resolvingAgainstBaseURL: false))
        base.query = nil
        let scales = Fragments.timescales(init: try Data(contentsOf: try #require(base.url).appendingPathComponent("init.mp4")))
        for index in 1..<count {
            let f = Fragments(want[index]!)
            guard let video = f.tracks[1], let audio = f.tracks[2], let vs = scales[1], let aus = scales[2],
                  let picture = video.samples.map(\.presentationTime).min(), let sound = audio.samples.first else {
                Issue.record("seg\(index): no video and audio to compare")
                continue
            }
            let lead = Double(picture) / Double(vs) - Double(sound.presentationTime) / Double(aus)
            #expect(lead >= 0, "seg\(index): sound starts \(String(format: "%.1f", -lead * 1000)) ms after the picture")
        }

        // A window of one counted segment, so a seek lands where nothing was cut and starts a run there.
        let seeking = HLSVideoEngine(url: url, dvModeAvailable: false, audioBridgeMode: route.mode,
                                     forwardBufferSegments: 1)
        seeking.audioDelaySeconds = route.delay
        _ = try seeking.start()
        defer { seeking.stop() }
        let served = try #require(seeking.provider)
        try #require(served.segmentCount == count, "both sessions plan alike")
        let cache = try #require(seeking.cache)

        // Forward past the window, back between the two runs, to the end, and back into the first run's
        // segments, which the restart cuts again. The MPEG-TS clip has no index and plans on the 4 s grid,
        // half as many segments.
        let far = count * 2 / 3, near = count / 3
        let seeks = [(far, far + 1), (near, far - 1), (count - 2, count - 1), (1, 2)]
        var compared = 0
        func check(_ index: Int) throws {
            let got = try #require(served.mediaSegment(at: index), "seg\(index) after seeks")
            compared += 1
            let a = Fragments(want[index]!), b = Fragments(got)
            #expect(b.normalized == a.normalized,
                    "seg\(index) (\(route.testDescription)): \(Fragments.difference(a, b))")
        }
        func seek(to index: Int) throws {
            let before = cache.peekURL(index: index).flatMap(Self.inode)
            let restarts = seeking.producerRestartCount
            seeking.requestRestart(at: index)
            // The new run counts itself when its pump starts.
            let started = Date().addingTimeInterval(60)
            while seeking.producerRestartCount <= restarts, Date() < started { usleep(5_000) }
            try #require(seeking.producerRestartCount > restarts, "the seek to seg\(index) started a run")
            if let before {
                // A resident segment is cut again by the new run and renamed into place.
                let deadline = Date().addingTimeInterval(60)
                while cache.peekURL(index: index).flatMap(Self.inode) == before, Date() < deadline { usleep(20_000) }
                try #require(cache.peekURL(index: index).flatMap(Self.inode) != before, "seg\(index) was not cut again")
            }
        }
        try check(0)
        for (target, through) in seeks {
            try seek(to: target)
            for index in target...through { try check(index) }
        }
        #expect(compared == 1 + seeks.map { $0.1 - $0.0 + 1 }.reduce(0, +))
    }

    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.systemFileNumber] as? NSNumber }?.uint64Value
    }
}

/// The samples of a segment's fragments, read for a diff that says where two segments part.
private struct Fragments {
    struct Sample: Equatable {
        let decodeTime: Int64
        let duration: UInt32
        let compositionOffset: Int32
        let flags: UInt32
        let bytes: Data
        var presentationTime: Int64 { decodeTime + Int64(compositionOffset) }
    }

    let raw: Data
    /// Per track id, the first fragment's `tfdt` and every sample in order.
    private(set) var tracks: [UInt32: (tfdt: Int64, samples: [Sample])] = [:]
    private(set) var events: [Data] = []

    init(_ data: Data) {
        raw = data
        for box in Self.boxes(data, 0..<data.count) {
            switch box.type {
            case "emsg": events.append(data[box.range])
            case "moof": readFragment(moof: box.range.lowerBound, body: box.body)
            default: break
            }
        }
    }

    /// The segment with each fragment's sequence number zeroed: it counts a muxer's fragments, so it is
    /// a run's, not the segment's.
    var normalized: Data {
        var d = raw
        for moof in Self.boxes(raw, 0..<raw.count) where moof.type == "moof" {
            for mfhd in Self.boxes(raw, moof.body) where mfhd.type == "mfhd" {
                d.replaceSubrange(mfhd.body.lowerBound + 4..<mfhd.body.lowerBound + 8, with: [0, 0, 0, 0])
            }
        }
        return d
    }

    /// Where `b` parts from `a`: the event message, each track's start, sample count and first sample whose
    /// timing, flags or bytes differ, or else the first byte that differs and the box holding it.
    static func difference(_ a: Fragments, _ b: Fragments) -> String {
        var found: [String] = []
        if a.events != b.events { found.append("the emsg differs") }
        if Set(a.tracks.keys) != Set(b.tracks.keys) { found.append("tracks \(a.tracks.keys.sorted()) against \(b.tracks.keys.sorted())") }
        for track in a.tracks.keys.sorted() {
            guard let x = a.tracks[track], let y = b.tracks[track] else { continue }
            if x.tfdt != y.tfdt { found.append("track \(track) starts at tfdt \(y.tfdt), not \(x.tfdt) (\(y.tfdt - x.tfdt))") }
            if x.samples.count != y.samples.count {
                found.append("track \(track) has \(y.samples.count) samples, not \(x.samples.count)")
            }
            // Matched by presentation time, so a segment that starts a sample early or late still shows
            // whether the samples both hold agree.
            let ys = Dictionary(y.samples.map { ($0.presentationTime, $0) }, uniquingKeysWith: { f, _ in f })
            let shared = x.samples.filter { ys[$0.presentationTime] != nil }.count
            if shared != x.samples.count || shared != y.samples.count {
                let onlyA = x.samples.filter { ys[$0.presentationTime] == nil }.map(\.presentationTime)
                let xs = Set(x.samples.map(\.presentationTime))
                let onlyB = y.samples.filter { !xs.contains($0.presentationTime) }.map(\.presentationTime)
                found.append("track \(track): \(shared) samples at shared times, continuous alone at \(onlyA.prefix(4)), seek alone at \(onlyB.prefix(4))")
            }
            for (i, s) in x.samples.enumerated() {
                guard let t = ys[s.presentationTime], t != s else { continue }
                var what: [String] = []
                if s.decodeTime != t.decodeTime { what.append("decode time \(t.decodeTime), not \(s.decodeTime)") }
                if s.duration != t.duration { what.append("duration \(t.duration), not \(s.duration)") }
                if s.flags != t.flags { what.append(String(format: "flags %08x, not %08x", t.flags, s.flags)) }
                if s.bytes != t.bytes { what.append("\(t.bytes.count) bytes against \(s.bytes.count), differing") }
                found.append("track \(track) sample \(i) presenting at \(s.presentationTime): " + what.joined(separator: ", "))
                break
            }
        }
        if found.isEmpty {
            let n = min(a.raw.count, b.raw.count)
            let at = (0..<n).first { a.raw[a.raw.startIndex + $0] != b.raw[b.raw.startIndex + $0] } ?? n
            let path = a.path(at: at)
            found.append("\(b.raw.count) bytes against \(a.raw.count), first differing at \(at) in \(path)")
        }
        return found.joined(separator: "; ")
    }

    /// The boxes enclosing byte `at`, outermost first.
    func path(at: Int) -> String {
        var names: [String] = []
        var range = 0..<raw.count
        while let box = Self.boxes(raw, range).first(where: { $0.range.contains(at) }) {
            names.append(box.type)
            guard ["moof", "traf", "moov", "trak", "mdia", "minf", "stbl"].contains(box.type) else { break }
            range = box.body
        }
        return names.joined(separator: "/")
    }

    /// Each track's media timescale, from an init segment's `tkhd` and `mdhd`.
    static func timescales(init data: Data) -> [UInt32: UInt32] {
        var out: [UInt32: UInt32] = [:]
        func walk(_ range: Range<Int>, track: UInt32?) {
            var track = track
            for box in boxes(data, range) {
                let at = box.body.lowerBound
                let version = data[data.startIndex + at]
                switch box.type {
                case "tkhd": track = u32(data, at + (version == 1 ? 20 : 12))
                case "mdhd": if let track { out[track] = u32(data, at + (version == 1 ? 20 : 12)) }
                case "moov", "trak", "mdia": walk(box.body, track: track)
                default: break
                }
            }
        }
        walk(0..<data.count, track: nil)
        return out
    }

    // MARK: - ISO BMFF

    private struct Box {
        let type: String
        let range: Range<Int>
        var body: Range<Int> { range.lowerBound + 8..<range.upperBound }
    }

    private static func boxes(_ d: Data, _ range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var at = range.lowerBound
        while at + 8 <= range.upperBound {
            let size = Int(u32(d, at))
            guard size >= 8, at + size <= range.upperBound else { break }
            out.append(Box(type: String(decoding: d[d.startIndex + at + 4..<d.startIndex + at + 8], as: UTF8.self),
                           range: at..<at + size))
            at += size
        }
        return out
    }

    private static func u32(_ d: Data, _ at: Int) -> UInt32 {
        d[d.startIndex + at..<d.startIndex + at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func u64(_ d: Data, _ at: Int) -> UInt64 {
        UInt64(u32(d, at)) << 32 | UInt64(u32(d, at + 4))
    }

    private mutating func readFragment(moof: Int, body: Range<Int>) {
        let d = raw
        for traf in Self.boxes(d, body) where traf.type == "traf" {
            var track: UInt32 = 0
            var base = moof
            var defaultDuration: UInt32 = 0, defaultSize: UInt32 = 0, defaultFlags: UInt32 = 0
            var decodeTime: Int64?
            for box in Self.boxes(d, traf.body) {
                let at = box.body.lowerBound
                let flags = Self.u32(d, at) & 0xFF_FFFF
                switch box.type {
                case "tfhd":
                    track = Self.u32(d, at + 4)
                    var p = at + 8
                    if flags & 0x1 != 0 { base = Int(Self.u64(d, p)); p += 8 }
                    if flags & 0x2 != 0 { p += 4 }
                    if flags & 0x8 != 0 { defaultDuration = Self.u32(d, p); p += 4 }
                    if flags & 0x10 != 0 { defaultSize = Self.u32(d, p); p += 4 }
                    if flags & 0x20 != 0 { defaultFlags = Self.u32(d, p) }
                case "tfdt":
                    decodeTime = d[d.startIndex + at] == 1 ? Int64(Self.u64(d, at + 4)) : Int64(Self.u32(d, at + 4))
                    if tracks[track] == nil { tracks[track] = (decodeTime!, []) }
                case "trun":
                    let count = Int(Self.u32(d, at + 4))
                    var p = at + 8
                    var offset = base
                    if flags & 0x1 != 0 { offset = base + Int(Int32(bitPattern: Self.u32(d, p))); p += 4 }
                    var firstFlags: UInt32?
                    if flags & 0x4 != 0 { firstFlags = Self.u32(d, p); p += 4 }
                    var time = decodeTime ?? 0
                    for i in 0..<count {
                        var duration = defaultDuration, size = defaultSize, sampleFlags = defaultFlags
                        var cto: Int32 = 0
                        if flags & 0x100 != 0 { duration = Self.u32(d, p); p += 4 }
                        if flags & 0x200 != 0 { size = Self.u32(d, p); p += 4 }
                        if flags & 0x400 != 0 { sampleFlags = Self.u32(d, p); p += 4 }
                        else if i == 0, let firstFlags { sampleFlags = firstFlags }
                        if flags & 0x800 != 0 { cto = Int32(bitPattern: Self.u32(d, p)); p += 4 }
                        let end = min(offset + Int(size), d.count)
                        let bytes = offset < end ? d[d.startIndex + offset..<d.startIndex + end] : Data()
                        tracks[track, default: (time, [])].samples.append(
                            Sample(decodeTime: time, duration: duration, compositionOffset: cto, flags: sampleFlags,
                                   bytes: Data(bytes)))
                        offset += Int(size)
                        time += Int64(duration)
                    }
                    decodeTime = time
                default: break
                }
            }
        }
    }
}
