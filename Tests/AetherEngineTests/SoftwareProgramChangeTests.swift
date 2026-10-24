import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The software path across a PMT change: its decoders are for the stream that carries each role
/// where it starts, a same-codec move goes on into them, another codec is held out for one rebuild,
/// and the stream a packet came from survives the read-ahead spool and the live ring.
@Suite("Software path across a PMT change")
struct SoftwareProgramChangeTests {

    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var summaries: [String] = []
        func note(_ s: String) { lock.withLock { summaries.append(s) } }
        var all: [String] { lock.withLock { summaries } }
    }

    @Test("same codec on a new stream decodes on; another codec is held out and asks for one rebuild")
    func watchVerdicts() {
        let codecs: [Int32: AVCodecID] = [0: AV_CODEC_ID_H264, 1: AV_CODEC_ID_AC3, 2: AV_CODEC_ID_H264,
                                          3: AV_CODEC_ID_HEVC, 4: AV_CODEC_ID_EAC3]
        let asked = Asked()
        let watch = SoftwareSourceWatch(videoIndex: 0, videoSource: 0, audioIndex: 1, audioSource: 1,
                                        codec: { codecs[$0] }, onCodecChange: { asked.note($0) })
        #expect(watch.verdict(streamIndex: 0, source: 0) == .decode)
        #expect(watch.verdict(streamIndex: 0, source: 2) == .decode, "an ad on its own PID, same codec")
        #expect(watch.verdict(streamIndex: 0, source: 3) == .drop, "HEVC under an H.264 decoder")
        #expect(watch.verdict(streamIndex: 0, source: 3) == .drop)
        #expect(watch.verdict(streamIndex: 1, source: 4) == .drop, "E-AC-3 under an AC-3 decoder")
        #expect(watch.verdict(streamIndex: 7, source: 7) == .decode, "not a role the decoders hold")
        #expect(asked.all.count == 1, "one rebuild, whichever role asked first")
    }

    @Test("the stream a packet came from survives the spool envelope and comes back on the packet")
    func spoolCarriesTheSource() throws {
        let stored = SoftwareStoredPacket(pts: 10, dts: 9, duration: 1, position: 188, streamIndex: 0, flags: 1,
                                          timeBaseNumerator: 1, timeBaseDenominator: 90_000,
                                          bytes: Data([1, 2, 3]), sideData: [], sourceStream: 2)
        let decoded = try SoftwareStoredPacket.decode(try stored.encoded())
        #expect(decoded == stored)
        let packet = try decoded.makeAVPacket()
        defer { av_packet_unref(packet); av_packet_free_safe(packet) }
        #expect(packet.pointee.stream_index == 0)
        #expect(Demuxer.sourceStream(of: packet) == 2)
        let own = SoftwareStoredPacket(pts: 10, dts: 9, duration: 1, position: 188, streamIndex: 0, flags: 1,
                                       timeBaseNumerator: 1, timeBaseDenominator: 90_000, bytes: Data([1]), sideData: [])
        let ownPacket = try own.makeAVPacket()
        defer { av_packet_unref(ownPacket); av_packet_free_safe(ownPacket) }
        #expect(Demuxer.sourceStream(of: ownPacket) == 0)
    }

    @Test("a packet read through the stored form keeps where it came from", .timeLimit(.minutes(1)))
    func storedFormFromTheDemuxer() throws {
        let written = TransportStreamFixture.write([.init(frames: 60), .init(frames: 60, videoPID: 0x1021, pmtVersion: 1)])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: written.data))
        defer { demuxer.close() }
        var sources: Set<Int32> = []
        while let packet = try demuxer.readPacket() {
            defer { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
            let rebuilt = try SoftwareStoredPacket(copying: packet).makeAVPacket()
            defer { av_packet_unref(rebuilt); av_packet_free_safe(rebuilt) }
            #expect(Demuxer.sourceStream(of: rebuilt) == Demuxer.sourceStream(of: packet))
            sources.insert(Demuxer.sourceStream(of: rebuilt))
        }
        #expect(sources.count == 2)
    }

    @Test("the decoders are for the stream each role is on where the host starts", .timeLimit(.minutes(1)))
    func roleSourcesAtTheStart() throws {
        let written = TransportStreamFixture.write([
            .init(frames: 60, audioPID: 0x1100),
            .init(frames: 60, videoPID: 0x1021, videoStreamType: 0x24, pmtVersion: 1, audioPID: 0x1100),
        ])
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: written.data))
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex, audio = demuxer.audioStreamIndex
        #expect(SoftwarePlaybackHost.roleSources(demuxer, video: video, audio: audio) == (video, audio) as (Int32, Int32))
        #expect(demuxer.seek(to: Double(written.frames[90].dts) / 90_000))
        let past = SoftwarePlaybackHost.roleSources(demuxer, video: video, audio: audio)
        #expect(past.video != video && past.audio == audio)
        #expect(demuxer.stream(at: past.video)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC)
        // Peeked, not read: the first packet is still there for the loop.
        let first = try #require(try demuxer.readPacket())
        defer { var p: UnsafeMutablePointer<AVPacket>? = first; trackedPacketFree(&p) }
        #expect(first.pointee.stream_index == video || first.pointee.stream_index == audio)
    }
}
