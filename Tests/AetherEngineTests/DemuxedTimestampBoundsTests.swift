import CoreMedia
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// A minimal Matroska file with one S_TEXT/UTF8 track, one Cluster per block, built by hand because
/// the pinned FFmpeg carries no Matroska muxer. Every field is written verbatim, which is the point:
/// matroskadec stores a uint64 Cluster Timestamp into an int64 pts unchecked, clamps BlockDuration to
/// INT64_MAX, and derives the stream time base from TimestampScale, so a crafted file reaches any
/// magnitude and a time base whose numerator is above one.
enum HostileTimestampMatroska {
    struct Block {
        var cluster: UInt64
        var duration: UInt64?
    }

    private static func vintSize(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = [0x01]
        for shift in stride(from: 48, through: 0, by: -8) {
            bytes.append(UInt8((n >> shift) & 0xFF))
        }
        return bytes
    }

    private static func element(_ id: [UInt8], _ payload: [UInt8]) -> [UInt8] {
        id + vintSize(payload.count) + payload
    }

    private static func uint(_ value: UInt64) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return bytes
    }

    static func make(timestampScale: UInt64 = 1_000_000, blocks: [Block]) -> Data {
        let header = element([0x1A, 0x45, 0xDF, 0xA3],
                             element([0x42, 0x86], uint(1)) +
                             element([0x42, 0xF7], uint(1)) +
                             element([0x42, 0xF2], uint(4)) +
                             element([0x42, 0xF3], uint(8)) +
                             element([0x42, 0x82], Array("matroska".utf8)) +
                             element([0x42, 0x87], uint(4)) +
                             element([0x42, 0x85], uint(2)))
        let info = element([0x15, 0x49, 0xA9, 0x66],
                           element([0x2A, 0xD7, 0xB1], uint(timestampScale)) +
                           element([0x4D, 0x80], Array("aether-audit".utf8)) +
                           element([0x57, 0x41], Array("aether-audit".utf8)))
        let track = element([0xD7], uint(1)) +
            element([0x73, 0xC5], uint(1)) +
            element([0x83], uint(0x11)) +
            element([0x9C], uint(0)) +
            element([0x86], Array("S_TEXT/UTF8".utf8))
        let tracks = element([0x16, 0x54, 0xAE, 0x6B], element([0xAE], track))
        var clusters: [UInt8] = []
        for (index, block) in blocks.enumerated() {
            let payload: [UInt8] = [0x81, 0x00, 0x00, 0x00] + Array("line \(index)".utf8)
            var group = element([0xA1], payload)
            if let duration = block.duration { group += element([0x9B], uint(duration)) }
            clusters += element([0x1F, 0x43, 0xB6, 0x75],
                                element([0xE7], uint(block.cluster)) + element([0xA0], group))
        }
        return Data(header + element([0x18, 0x53, 0x80, 0x67], info + tracks + clusters))
    }

    /// Every packet the engine's demuxer hands out, as (pts, dts, duration), with the stream's time base.
    static func readBack(_ data: Data) throws -> (timeBase: AVRational, packets: [(pts: Int64, dts: Int64, duration: Int64)]) {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        let stream = try #require(demuxer.stream(at: 0))
        var packets: [(pts: Int64, dts: Int64, duration: Int64)] = []
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            packets.append((packet.pointee.pts, packet.pointee.dts, packet.pointee.duration))
        }
        return (stream.pointee.time_base, packets)
    }
}

@Suite("Demuxed timestamps are bounded before any consumer does arithmetic on them")
struct DemuxedTimestampBoundsTests {

    private static let unset = Int64.min

    /// matroskadec derives 3/1e9 from TimestampScale 3, so the seconds rule and the tick rule both
    /// have something to catch: 2^61 ticks are 6.9e9 s, 2^62 ticks fail on their own.
    @Test("out-of-range timestamps leave the demuxer unset, and an INT64_MAX duration leaves it 0")
    func outOfRangeTimestampsLeaveTheDemuxerUnset() throws {
        let read = try HostileTimestampMatroska.readBack(HostileTimestampMatroska.make(
            timestampScale: 3,
            blocks: [.init(cluster: 1000, duration: 500),
                     .init(cluster: 1 << 61, duration: 500),
                     .init(cluster: 1 << 62, duration: 500),
                     .init(cluster: 2000, duration: UInt64.max),
                     .init(cluster: 3000, duration: 1)]))
        #expect(read.timeBase.num == 3 && read.timeBase.den == 1_000_000_000)
        try #require(read.packets.count == 5)
        #expect(read.packets[0] == (1000, 1000, 500))
        #expect(read.packets[1] == (Self.unset, Self.unset, 500))
        #expect(read.packets[2] == (Self.unset, Self.unset, 500))
        #expect(read.packets[3] == (2000, 2000, 0))
        #expect(read.packets[4] == (3000, 3000, 1))
    }

    /// The bound must not cost a real source its clock: epoch-anchored wall-clock timestamps at
    /// 1 GHz and 10 MHz are what live fMP4 and some Matroska writers emit.
    @Test("epoch-anchored nanosecond and 100 ns timestamps pass untouched")
    func epochAnchoredTimestampsSurvive() throws {
        let nanos: UInt64 = 1_790_000_000_000_000_000
        let atNanos = try HostileTimestampMatroska.readBack(HostileTimestampMatroska.make(
            timestampScale: 1, blocks: [.init(cluster: nanos, duration: 40_000_000)]))
        #expect(atNanos.timeBase.num == 1 && atNanos.timeBase.den == 1_000_000_000)
        #expect(atNanos.packets.map(\.pts) == [Int64(nanos)])
        #expect(atNanos.packets.map(\.duration) == [40_000_000])

        let hundreds: UInt64 = 17_900_000_000_000_000
        let atHundreds = try HostileTimestampMatroska.readBack(HostileTimestampMatroska.make(
            timestampScale: 100, blocks: [.init(cluster: hundreds, duration: 400_000)]))
        #expect(atHundreds.timeBase.num == 1 && atHundreds.timeBase.den == 10_000_000)
        #expect(atHundreds.packets.map(\.pts) == [Int64(hundreds)])
    }

    /// Audit FEA-101 / SUB-105: the sidecar decoder runs its own `av_read_frame` loop, a second raw
    /// channel next to the Demuxer.
    @Test("the sidecar subtitle reader bounds its own read loop")
    func sidecarReaderBoundsItsReadLoop() async throws {
        let data = HostileTimestampMatroska.make(blocks: [
            .init(cluster: 1000, duration: 500),
            .init(cluster: 2000, duration: UInt64.max),
            .init(cluster: 5_000_000_000_000, duration: 500),
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostile-timestamps-\(UUID().uuidString).mkv")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let cues = try await SubtitleDecoder.decodeFile(url: url).cues
        #expect(cues.count == 3)
        for cue in cues {
            #expect(cue.startTime.isFinite && cue.endTime.isFinite)
            #expect(abs(cue.startTime) < SourceTimestampBounds.maxPlausibleSeconds)
            #expect(abs(cue.endTime) < SourceTimestampBounds.maxPlausibleSeconds)
        }
        #expect(cues.contains { $0.startTime == 1 && $0.endTime == 1.5 })
    }

    /// Audit FEA-101, the software-route vector: the SW host's subtitle tap harvests what the demuxer
    /// hands it, and the drain rebuilt the packet with `Int64(durationSeconds * 1000)`. matroskadec
    /// clamps an all-ones BlockDuration to INT64_MAX, which at 1 ms is exactly 2^63 after the round
    /// trip through seconds.
    @Test("a subtitle block whose duration matroskadec clamps to INT64_MAX drains without trapping")
    func clampedBlockDurationDrains() throws {
        let data = HostileTimestampMatroska.make(blocks: [.init(cluster: 1000, duration: UInt64.max)])
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        let stream = try #require(demuxer.stream(at: 0))
        let decoder = try #require(EmbeddedSubtitleDecoder(stream: stream, sourceVideoWidth: 16, sourceVideoHeight: 16))
        let store = SubtitlePacketStore()
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            store.harvest(streamIndex: 0, packet: packet, timeBase: stream.pointee.time_base)
        }
        let entries = store.entries(streamIndex: 0, from: 0, through: 10)
        try #require(entries.count == 1)
        #expect(entries[0].durationSeconds == 0)
        let event = AetherEngine.decodeStoredSubtitlePacket(entries[0], with: decoder)
        #expect(event?.cues.first?.startTime == 1)
    }

    /// Audit DEC-101: the decoders turn a frame timestamp into a CMTime as `pts * num`. A value the
    /// demuxer bound would already have unset still reaches them through the fold and through
    /// decoder-computed frame timestamps, so the conversion itself has to be total.
    @Test("the software decoder survives a frame timestamp whose product with the numerator overflows")
    func softwareDecoderSurvivesNumeratorOverflow() throws {
        let data = try #require(Data(base64Encoded: Issue220SoftwareDecoderDrainTests.fixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        stream.pointee.time_base = AVRational(num: 3, den: 1_000_000_000)
        let frames = FrameTimes()
        let decoder = SoftwareVideoDecoder()
        try decoder.open(stream: stream) { _, pts, _ in frames.append(pts) }
        defer { decoder.close() }

        let base = (Int64(1) << 62) - 1_000_000
        var index: Int64 = 0
        while let packet = try? demuxer.readPacket() {
            if packet.pointee.stream_index == videoIndex {
                packet.pointee.pts = base + index * 1000
                packet.pointee.dts = packet.pointee.pts
                index += 1
                decoder.decode(packet: packet)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&owned)
        }
        let delivered = frames.values
        #expect(!delivered.isEmpty)
        #expect(delivered.allSatisfy { !$0.isValid })
    }

    @Test("the audio decoder survives a frame timestamp whose product with the numerator overflows")
    func audioDecoderSurvivesNumeratorOverflow() throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: ProbeTestFixtures.eac3()), formatHint: "mp4")
        let audioIndex = demuxer.audioStreamIndex
        let stream = try #require(demuxer.stream(at: audioIndex))
        stream.pointee.time_base = AVRational(num: 3, den: 1_000_000_000)
        let decoder = AudioDecoder()
        try decoder.open(stream: stream)
        defer { decoder.close() }

        let base = (Int64(1) << 62) - 1_000_000
        var index: Int64 = 0
        var buffers = 0
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == audioIndex else { continue }
            packet.pointee.pts = base + index * 1000
            packet.pointee.dts = packet.pointee.pts
            index += 1
            buffers += decoder.decode(packet: packet).count
        }
        #expect(index > 0)
        #expect(buffers > 0)
    }

    private final class FrameTimes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [CMTime] = []
        func append(_ time: CMTime) {
            lock.lock()
            storage.append(time)
            lock.unlock()
        }
        var values: [CMTime] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
