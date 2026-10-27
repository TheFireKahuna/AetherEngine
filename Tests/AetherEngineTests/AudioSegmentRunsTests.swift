import AetherLibavcodec
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// A clip under Fixtures/decmem/: 12 s of music-like audio in one codec the bridge decodes, read as the engine reads a
/// file.
struct DecmemClip {
    let packets: [UnsafeMutablePointer<AVPacket>]
    let codecpar: UnsafeMutablePointer<AVCodecParameters>
    let timeBase: AVRational
    let start: Int64?

    func free() {
        for p in packets { var q: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&q) }
        var c: UnsafeMutablePointer<AVCodecParameters>? = codecpar
        avcodec_parameters_free(&c)
    }

    static func read(_ name: String) throws -> DecmemClip {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/decmem/\(name)")
        try #require(FileManager.default.fileExists(atPath: url.path), "run Scripts/fetch-fixtures.sh to generate Fixtures/decmem/")
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let index = demuxer.audioStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let par = avcodec_parameters_alloc()!
        avcodec_parameters_copy(par, stream.pointee.codecpar)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        while let pkt = try demuxer.readPacket() {
            if pkt.pointee.stream_index == index { packets.append(pkt) } else { var q: UnsafeMutablePointer<AVPacket>? = pkt; trackedPacketFree(&q) }
        }
        return DecmemClip(packets: packets, codecpar: par, timeBase: stream.pointee.time_base,
                          start: stream.pointee.start_time == Int64.min ? nil : stream.pointee.start_time)
    }
}

/// A segment's bridged audio comes out the same however playback reached it (`AudioSegmentRuns`):
/// a seek, which reads the source from its pre-roll before the segment, makes the segments that
/// continuous playback made, byte for byte and on the same timestamps; and continuous playback's
/// segments follow one another a packet at a time across every run's handoff.
@Suite("Segment runs: a seek makes continuous playback's segments")
struct AudioSegmentRunsTests {

    /// Two-second segments from 0, on a 90 kHz video axis.
    private func plan(from base: Int, bridge: any AudioTranscodingBridge, seconds: Int, delay: Double) -> AudioRunPlan {
        AudioRunPlan(baseIndex: base, boundaries: stride(from: base * 2, through: seconds + 2, by: 2).map { Int64($0) * 90_000 },
                     planAnchor: 0, videoTimeBase: AVRational(num: 1, den: 90_000),
                     outputTimeBase: bridge.encoderTimeBase,
                     delayTicks: Int64((delay * Double(bridge.encoderTimeBase.den)).rounded()))
    }

    private struct Out: Equatable {
        let pts: Int64
        let bytes: [UInt8]
    }

    /// Every packet the runs hand on from `first` on, by segment.
    private func produce(_ clip: DecmemClip, mode: AudioBridgeMode, from first: Int, base: Int, seconds: Int,
                         delay: Double = 0) throws
        -> (segments: [Int: [Out]], packetFrames: Int64, preRoll: Double) {
        let make = { try AudioBridge(srcCodecpar: clip.codecpar, srcTimeBase: clip.timeBase, mode: mode) as any AudioTranscodingBridge }
        let runs = try #require(AudioSegmentRuns(template: try make(), sourceCodecpar: clip.codecpar,
                                                 sourceTimeBase: clip.timeBase, makeRun: make))
        defer { runs.close() }
        runs.setSourceStart(clip.start)
        runs.setOutputOffset(seconds: delay)
        let plan = plan(from: base, bridge: runs, seconds: seconds, delay: delay)
        runs.setRunPlan(plan)
        var segments: [Int: [Out]] = [:]
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for p in packets {
                segments[plan.segment(ofOutputPts: p.pointee.pts, duration: p.pointee.duration), default: []]
                    .append(Out(pts: p.pointee.pts, bytes: Array(UnsafeBufferPointer(start: p.pointee.data, count: Int(p.pointee.size)))))
                var q: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&q)
            }
        }
        for p in clip.packets[first...] { take(try runs.feed(packet: p)) }
        take(runs.flush())
        return (segments, Int64(runs.runPacketFrames), runs.preRollSeconds)
    }

    @Test("a seek makes the segments continuous playback made",
          arguments: [("mp2.mkv", AudioBridgeMode.lossless), ("mp3-64k.mp3", .lossless), ("mp3-vbr.mkv", .lossless),
                      ("mp3-lsf.mp3", .lossless), ("vorbis.ogg", .lossless), ("opus.mkv", .lossless),
                      ("dts-51.mkv", .lossless), ("dts-51.mkv", .surroundCompat), ("truehd-51.mkv", .lossless),
                      ("truehd-51.mkv", .surroundCompat), ("truehd-96k.mkv", .lossless), ("flac.mkv", .lossless)])
    func seekMatchesContinuous(_ name: String, _ mode: AudioBridgeMode) throws {
        try check(name, mode, delay: 0)
    }

    @Test("with an audio delay, too", arguments: [("dts-51.mkv", AudioBridgeMode.surroundCompat, 0.15),
                                                  ("dts-51.mkv", .surroundCompat, -0.15), ("opus.mkv", .lossless, 0.15),
                                                  ("opus.mkv", .lossless, -0.15)])
    func seekMatchesContinuousWithDelay(_ name: String, _ mode: AudioBridgeMode, _ delay: Double) throws {
        try check(name, mode, delay: delay)
    }

    private func check(_ name: String, _ mode: AudioBridgeMode, delay: Double) throws {
        let clip = try DecmemClip.read(name)
        defer { clip.free() }
        let seconds = 12
        let continuous = try produce(clip, mode: mode, from: 0, base: 0, seconds: seconds, delay: delay)
        #expect(continuous.segments.values.joined().allSatisfy { $0.pts >= 0 }, "\(name): nothing below the timeline's zero")
        let rate = Int64(clip.codecpar.pointee.sample_rate)

        // Continuous playback: one packet after another on the grid, across every handoff.
        let all = continuous.segments.keys.sorted().flatMap { continuous.segments[$0]! }
        try #require(all.count > 100)
        for (a, b) in zip(all, all.dropFirst()) {
            #expect(b.pts - a.pts == continuous.packetFrames, "\(name): \(a.pts) then \(b.pts)")
        }

        for k in [1, 2, 4] {
            // The seek reads from the last packet at or before the pre-roll ahead of segment k, and a
            // positive delay earlier still: the sound that plays at the boundary was read that much before.
            let readFrom = Int64(k * 2) * Int64(clip.timeBase.den) / Int64(clip.timeBase.num)
                - Int64(((continuous.preRoll + max(0, delay)) * Double(clip.timeBase.den) / Double(clip.timeBase.num)).rounded(.up))
            let first = clip.packets.lastIndex { $0.pointee.pts <= readFrom } ?? 0
            let seek = try produce(clip, mode: mode, from: first, base: k, seconds: seconds, delay: delay)
            for segment in k...(k + 1) {
                let want = continuous.segments[segment] ?? []
                let got = seek.segments[segment] ?? []
                #expect(!want.isEmpty, "\(name): segment \(segment) is empty")
                #expect(got.map(\.pts) == want.map(\.pts), "\(name): segment \(segment)'s timestamps after a seek to \(k)")
                #expect(got == want, "\(name): segment \(segment)'s bytes after a seek to \(k) (\(rate) Hz)")
            }
            #expect(seek.segments.keys.min() == k, "\(name): nothing before the segment sought to")
        }
    }

    @Test("a producer a restart abandoned feeds only its own session, not the new producer's")
    func abandonedProducerCannotFeedTheNewOne() throws {
        let clip = try DecmemClip.read("dts-51.mkv")
        defer { clip.free() }
        let make = { try AudioBridge(srcCodecpar: clip.codecpar, srcTimeBase: clip.timeBase, mode: .surroundCompat)
            as any AudioTranscodingBridge }
        let engine = try #require(AudioSegmentRuns(template: try make(), sourceCodecpar: clip.codecpar,
                                                   sourceTimeBase: clip.timeBase, makeRun: make))
        defer { engine.close() }
        func session(base: Int) -> (any AudioTranscodingBridge, AudioRunPlan) {
            let bridge = engine.producerBridge()
            bridge.setSourceStart(clip.start)
            let plan = plan(from: base, bridge: bridge, seconds: 12, delay: 0)
            bridge.setRunPlan(plan)
            return (bridge, plan)
        }
        func bytes(_ packets: [UnsafeMutablePointer<AVPacket>]) -> [Out] {
            packets.map { p in
                defer { var q: UnsafeMutablePointer<AVPacket>? = p; trackedPacketFree(&q) }
                return Out(pts: p.pointee.pts, bytes: Array(UnsafeBufferPointer(start: p.pointee.data, count: Int(p.pointee.size))))
            }
        }
        // The new producer alone, from its pre-roll before segment 3.
        let first = clip.packets.firstIndex { $0.pointee.pts >= 4_000 } ?? 0
        let (alone, _) = session(base: 3)
        var want: [Out] = []
        for p in clip.packets[first...] { want += bytes(try alone.feed(packet: p)) }
        want += bytes(alone.flush())
        alone.producerFinished()
        // The same, while the producer it replaced keeps feeding from where it was.
        let (old, _) = session(base: 0)
        let (new, _) = session(base: 3)
        var got: [Out] = []
        for (i, p) in clip.packets[first...].enumerated() {
            _ = bytes(try old.feed(packet: clip.packets[i]))
            got += bytes(try new.feed(packet: p))
        }
        got += bytes(new.flush())
        old.producerFinished()
        new.producerFinished()
        #expect(!want.isEmpty)
        #expect(got == want)
        #expect(engine.outputBytesLifetime > 0, "the engine's counts the session's output")
    }

    @Test("an MP3 run starts where the stream's own reservoir says, short of the format's worst case")
    func mp3RunStartsAtItsReservoir() throws {
        let clip = try DecmemClip.read("mp3-lsf.mp3")
        defer { clip.free() }
        let buffers = clip.packets.map { UnsafeRawBufferPointer(start: $0.pointee.data, count: Int($0.pointee.size)) }
        // 32 kbps at 24 kHz: the format allows 255 bytes, 85 frames' worth at 8 kbps.
        let frameSamples: Int64 = 576
        var furthest = 0
        for needed in stride(from: 50, to: clip.packets.count, by: 7) {
            let first = try #require(MP3MainData.firstPacket(feeding: needed, of: buffers))
            furthest = max(furthest, needed - first)
        }
        let bound = Int64(AudioStageSpan.mp3DecoderMemory(sampleRate: 24_000, channels: 2) - AudioStageSpan.mp3OverlapFrames) / frameSamples
        #expect(furthest >= 1, "a reservoir that never reaches back is not one")
        #expect(Int64(furthest) < bound, "\(furthest) frames back against the format's \(bound)")
    }

}
