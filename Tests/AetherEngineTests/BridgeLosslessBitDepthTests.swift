import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #4: the `.lossless` bridge classified "lossless" by a codec list, and every codec off that list
/// went out at 16 bits. 24-bit Blu-ray LPCM (`pcm_bluray`, the M2TS PCM track) was off the list,
/// so the "lossless" mode cut its bottom 8 bits. The output depth now follows the format the opened
/// decoder produces: a real 24-bit source through the bridge has to come out identical, not merely close.
@Suite("#4 the lossless bridge keeps a 24-bit source's 24 bits")
struct BridgeLosslessBitDepthTests {

    @Test("24-bit Blu-ray LPCM comes out of the lossless bridge bit for bit")
    func pcmBlurayIsBitExact() throws {
        // Stereo, 48 kHz, 24-bit: every sample's low 8 bits live, so a truncation to 16 cannot pass.
        let bd = BluRayLPCMTests.packet(assignment: 3, depth: 3, frames: 240, stored: 2, bytes: 3)
        let (bySpeaker, codecpar) = try BluRayLPCMTests.reference(bd)
        var par: UnsafeMutablePointer<AVCodecParameters>? = codecpar
        defer { avcodec_parameters_free(&par) }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: AVRational(num: 1, den: 48_000), mode: .lossless)
        defer { bridge.close() }

        var out: [UInt8] = []
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for p in packets {
                out += UnsafeBufferPointer(start: p.pointee.data, count: Int(p.pointee.size))
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
        }
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        for i in 0..<20 {
            try #require(av_new_packet(pkt, Int32(bd.count)) == 0)
            pkt!.pointee.data.update(from: bd, count: bd.count)
            pkt!.pointee.pts = Int64(i * 240)
            pkt!.pointee.dts = pkt!.pointee.pts
            pkt!.pointee.duration = 240
            take(try bridge.feed(packet: pkt!))
            av_packet_unref(pkt)
        }
        take(bridge.flush())

        #expect(bridge.output == .pcm)
        #expect(bridge.encoderCodecpar?.pointee.codec_id == AV_CODEC_ID_PCM_S24LE)
        let samples = stride(from: 0, to: out.count - 2, by: 3).map {
            Int32(bitPattern: UInt32(out[$0]) << 8 | UInt32(out[$0 + 1]) << 16 | UInt32(out[$0 + 2]) << 24) >> 8
        }
        let left = try #require(bySpeaker[AV_CHAN_FRONT_LEFT]), right = try #require(bySpeaker[AV_CHAN_FRONT_RIGHT])
        let packet = zip(left, right).flatMap { [$0, $1] }
        #expect(samples == Array((0..<20).map { _ in packet }.joined()), "the low 8 bits did not survive")
    }

    // MARK: - The choice itself

    @Test("only a decoder that produces 16 bits or fewer gets 16-bit PCM")
    func outputDepthFollowsTheDecodedFormat() {
        for fmt in [AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P] {
            let choice = AudioBridge.pcmEncoding(decodedFormat: fmt)
            #expect(choice.encoder == AV_CODEC_ID_PCM_S16LE && choice.bitsPerRawSample == 16)
        }
        // Integer 24/32-bit, and float decodes of lossy codecs (AAC, Opus, Vorbis, MP3 decode to fltp),
        // whose precision a 16-bit requantisation would throw away; NONE is a decoder that defers its
        // format to the first frame (TrueHD, DTS), which must never be guessed down.
        for fmt in [AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP,
                    AV_SAMPLE_FMT_DBLP, AV_SAMPLE_FMT_S64, AV_SAMPLE_FMT_NONE] {
            let choice = AudioBridge.pcmEncoding(decodedFormat: fmt)
            #expect(choice.encoder == AV_CODEC_ID_PCM_S24LE && choice.format == AV_SAMPLE_FMT_S32
                    && choice.bitsPerRawSample == 24, "\(fmt.rawValue)")
        }
    }
}
