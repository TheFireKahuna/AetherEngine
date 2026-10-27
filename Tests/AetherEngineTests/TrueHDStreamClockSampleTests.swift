// Only with the TrueHDObjectAudio trait (off by default): the decoder and its library are not built without it.
#if TrueHDObjectAudio
import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// TrueHD placed by its own clock (output_timing), on a library title's real stream. The samples are not in
/// the repository: `AE_TRUEHD_CLOCK_SAMPLES` names a directory holding `head.mka` (the TrueHD Atmos track's
/// first seconds) and `mid.mka` (seconds of it from an hour in, original timestamps kept), cut with
/// `ffmpeg [-ss 3600 -t 4] -copyts -i <title> -map 0:a:0 -c copy`. Measured on "28 Years Later": the
/// stream's first restart header is at access unit 114 with output_timing 21664, so its clock reads zero
/// 114 × 40 − 21664 = −17104 frames from its start.
@Suite("TrueHD stream clock, library sample")
struct TrueHDStreamClockSampleTests {

    static let expectedHeadOffset: Int64 = -17_104

    private static func sample(_ name: String) -> URL? {
        ProcessInfo.processInfo.environment["AE_TRUEHD_CLOCK_SAMPLES"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Every packet of the file's audio stream with its timestamp, through `body`.
    private static func packets(_ url: URL, _ body: (UnsafeMutablePointer<AVPacket>) throws -> Void) throws {
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        // The sample holds the audio track alone.
        let index: Int32 = 0
        try #require(demuxer.stream(at: index)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD)
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            if packet.pointee.stream_index == index { try body(packet) }
        }
    }

    @Test("the stream's clock against its start, read off its head, is the restart header's own")
    func headOffset() throws {
        guard let head = Self.sample("head.mka") else { return }
        let decoder = try TrueHDObjectAudioDecoder()
        var offset: Int64?
        try Self.packets(head) { packet in
            guard offset == nil, let data = packet.pointee.data else { return }
            try decoder.push(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)), pts: packet.pointee.pts)
            while let block = try decoder.nextBlock() {
                if offset == nil, let clock = block.clockFrame { offset = block.inputFrameOffset - clock }
            }
        }
        #expect(offset == Self.expectedHeadOffset)
    }

    @Test("an hour in, the clock places the run as one encoder run, the same whatever the timestamps say")
    func midStreamRun() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *),
              let mid = Self.sample("mid.mka") else { return }
        func run(drift: (Int) -> Int64) throws -> [Int64] {
            let bridge = try SpatialAudioBridge(srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
                                                decoder: try TrueHDObjectAudioDecoder())
            defer { bridge.close() }
            bridge.setSourceStart(0)
            bridge.setStreamClock(anchors: StreamClockAnchors(headOffset: Self.expectedHeadOffset))
            var out: [Int64] = [], i = 0
            try Self.packets(mid) { packet in
                packet.pointee.pts -= drift(i)
                packet.pointee.dts = packet.pointee.pts
                i += 1
                for p in try bridge.feed(packet: packet) {
                    out.append(p.pointee.pts)
                    var q: UnsafeMutablePointer<AVPacket>? = p
                    trackedPacketFree(&q)
                }
            }
            // Everything the encoder still holds: what a feed returns depends on how far its queue has got.
            for p in bridge.flush() {
                out.append(p.pointee.pts)
                var q: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&q)
            }
            return out
        }
        // The file's own timestamps: its first packet sits 96 ms early, the rest a millisecond's rounding off.
        let own = try run { _ in 0 }
        try #require(own.count > 100)
        #expect(zip(own, own.dropFirst()).allSatisfy { $1 - $0 == 1024 }, "one encoder run, no restart")
        // The same timestamps falling up to 2 ms behind and snapping back every 60 packets.
        #expect(try run { Int64(($0 % 60) / 25) } == own)
    }
}
#endif
