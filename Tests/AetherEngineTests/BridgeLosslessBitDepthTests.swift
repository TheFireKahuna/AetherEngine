import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// #4: the `.lossless` bridge classified "lossless" by a codec list, and every codec off that list
/// went to a 16-bit FLAC. 24-bit Blu-ray LPCM (`pcm_bluray`, the M2TS PCM track) was off the list,
/// so the "lossless" mode cut its bottom 8 bits. The intermediate now follows the format the opened
/// decoder produces. These run real 24-bit sources through the bridge and decode its FLAC back:
/// every sample has to come out identical, not merely close.
@Suite("#4 the lossless bridge keeps a 24-bit source's 24 bits")
struct BridgeLosslessBitDepthTests {

    private static let sampleRate: Int32 = 48_000
    private static let channels = 2
    /// One Blu-ray LPCM frame: 5 ms at 48 kHz.
    private static let framesPerPacket = 240

    /// Deterministic 24-bit noise with every low bit live, so a truncation to 16 cannot pass.
    private func samples24(frames: Int) -> [Int32] {
        var state: UInt32 = 0x2545_F491
        return (0..<(frames * Self.channels)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return Int32(bitPattern: state) >> 9   // -2^22 ..< 2^22
        }
    }

    // MARK: - Sources

    /// Blu-ray LPCM as an M2TS carries it: a 4-byte header (payload size; channel assignment 3 =
    /// stereo, rate 1 = 48 kHz; bits 3 = 24) and big-endian 24-bit interleaved samples.
    private func pcmBlurayPackets(_ pcm: [Int32]) -> [UnsafeMutablePointer<AVPacket>] {
        let stride = Self.framesPerPacket * Self.channels
        return Swift.stride(from: 0, to: pcm.count, by: stride).map { start in
            let chunk = pcm[start..<min(start + stride, pcm.count)]
            let payload = chunk.count * 3
            let pkt = av_packet_alloc()!
            _ = av_new_packet(pkt, Int32(4 + payload))
            let d = pkt.pointee.data!
            d[0] = UInt8(payload >> 8); d[1] = UInt8(payload & 0xFF)
            d[2] = (3 << 4) | 1
            d[3] = 3 << 6
            for (i, s) in chunk.enumerated() {
                let u = UInt32(bitPattern: s)
                d[4 + i * 3] = UInt8((u >> 16) & 0xFF)
                d[5 + i * 3] = UInt8((u >> 8) & 0xFF)
                d[6 + i * 3] = UInt8(u & 0xFF)
            }
            pkt.pointee.pts = Int64(start / Self.channels)
            pkt.pointee.dts = pkt.pointee.pts
            pkt.pointee.duration = Int64(chunk.count / Self.channels)
            return pkt
        }
    }

    /// What the mpegts demuxer reports for that track once its probe decoded a frame.
    private func pcmBlurayCodecpar() -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_BLURAY
        par.pointee.sample_rate = Self.sampleRate
        par.pointee.format = AV_SAMPLE_FMT_S32.rawValue
        par.pointee.bits_per_raw_sample = 24
        par.pointee.bits_per_coded_sample = 24
        av_channel_layout_default(&par.pointee.ch_layout, Int32(Self.channels))
        return par
    }

    /// A 24-bit FLAC track, encoded by the same libavcodec, with the parameters a demuxer reports.
    private func flac24(_ pcm: [Int32]) throws
        -> (packets: [UnsafeMutablePointer<AVPacket>], codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let codec = try #require(avcodec_find_encoder(AV_CODEC_ID_FLAC))
        var enc: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&enc) }
        let ctx = try #require(enc)
        ctx.pointee.sample_rate = Self.sampleRate
        ctx.pointee.sample_fmt = AV_SAMPLE_FMT_S32
        ctx.pointee.bits_per_raw_sample = 24
        ctx.pointee.time_base = AVRational(num: 1, den: Self.sampleRate)
        av_channel_layout_default(&ctx.pointee.ch_layout, Int32(Self.channels))
        #expect(avcodec_open2(ctx, codec, nil) >= 0)
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        func drain() {
            while true {
                let pkt = av_packet_alloc()!
                guard avcodec_receive_packet(ctx, pkt) >= 0 else {
                    var p: UnsafeMutablePointer<AVPacket>? = pkt
                    av_packet_free(&p)
                    return
                }
                packets.append(pkt)
            }
        }
        let frameSize = Int(ctx.pointee.frame_size)
        let total = pcm.count / Self.channels
        var offset = 0
        while offset < total {
            let n = min(frameSize, total - offset)
            var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
            defer { av_frame_free(&frame) }
            let f = try #require(frame)
            f.pointee.format = AV_SAMPLE_FMT_S32.rawValue
            f.pointee.nb_samples = Int32(n)
            f.pointee.sample_rate = Self.sampleRate
            av_channel_layout_copy(&f.pointee.ch_layout, &ctx.pointee.ch_layout)
            #expect(av_frame_get_buffer(f, 0) >= 0)
            let out = UnsafeMutableRawPointer(f.pointee.data.0!).assumingMemoryBound(to: Int32.self)
            for i in 0..<(n * Self.channels) { out[i] = pcm[offset * Self.channels + i] << 8 }
            f.pointee.pts = Int64(offset)
            #expect(avcodec_send_frame(ctx, f) >= 0)
            drain()
            offset += n
        }
        _ = avcodec_send_frame(ctx, nil)
        drain()
        let par = avcodec_parameters_alloc()!
        _ = avcodec_parameters_from_context(par, ctx)
        par.pointee.format = AV_SAMPLE_FMT_S32.rawValue
        return (packets, par)
    }

    // MARK: - Through the bridge and back

    /// Feeds every packet, flushes the tail, and decodes the bridge's FLAC to 24-bit values.
    private func roundTrip(packets: [UnsafeMutablePointer<AVPacket>],
                           codecpar: UnsafeMutablePointer<AVCodecParameters>) throws
        -> (samples: [Int32], encodedBits: Int32) {
        let bridge = try AudioBridge(srcCodecpar: codecpar,
                                     srcTimeBase: AVRational(num: 1, den: Self.sampleRate),
                                     mode: .lossless)
        bridge.setSourceStart(0)
        defer { bridge.close() }
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer {
            for p in outputs {
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
        }
        for p in packets { outputs.append(contentsOf: try bridge.feed(packet: p)) }
        outputs.append(contentsOf: bridge.flush())

        let encPar = try #require(bridge.encoderCodecpar)
        #expect(encPar.pointee.codec_id == AV_CODEC_ID_FLAC)
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_FLAC))
        var dec: UnsafeMutablePointer<AVCodecContext>? = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&dec) }
        let ctx = try #require(dec)
        #expect(avcodec_parameters_to_context(ctx, encPar) >= 0)
        #expect(avcodec_open2(ctx, codec, nil) >= 0)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        var decoded: [Int32] = []
        func receive() {
            while avcodec_receive_frame(ctx, f) >= 0 {
                let n = Int(f.pointee.nb_samples)
                let fmt = AVSampleFormat(rawValue: f.pointee.format)
                let planar = av_sample_fmt_is_planar(fmt) != 0
                let wide = av_get_bytes_per_sample(fmt) == 4
                for i in 0..<n {
                    for c in 0..<Self.channels {
                        let plane = UnsafeRawPointer(f.pointee.extended_data[planar ? c : 0]!)
                        let index = planar ? i : i * Self.channels + c
                        decoded.append(wide
                            ? plane.assumingMemoryBound(to: Int32.self)[index] >> 8
                            : Int32(plane.assumingMemoryBound(to: Int16.self)[index]) << 8)
                    }
                }
                av_frame_unref(f)
            }
        }
        for p in outputs {
            #expect(avcodec_send_packet(ctx, p) >= 0)
            receive()
        }
        _ = avcodec_send_packet(ctx, nil)
        receive()
        return (decoded, encPar.pointee.bits_per_raw_sample)
    }

    private func free(_ packets: [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            av_packet_free(&pp)
        }
    }

    @Test("24-bit Blu-ray LPCM comes out of the lossless bridge bit for bit")
    func pcmBlurayIsBitExact() throws {
        let pcm = samples24(frames: 24_000)
        let packets = pcmBlurayPackets(pcm)
        let codecpar = pcmBlurayCodecpar()
        defer {
            free(packets)
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let result = try roundTrip(packets: packets, codecpar: codecpar)
        #expect(result.encodedBits == 24, "the FLAC is \(result.encodedBits)-bit")
        #expect(result.samples.count == pcm.count)
        #expect(result.samples == pcm, "the low 8 bits did not survive")
    }

    @Test("24-bit FLAC comes out of the lossless bridge bit for bit")
    func flac24IsBitExact() throws {
        let pcm = samples24(frames: 24_000)
        let (packets, codecpar) = try flac24(pcm)
        defer {
            free(packets)
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let result = try roundTrip(packets: packets, codecpar: codecpar)
        #expect(result.encodedBits == 24)
        #expect(result.samples.count == pcm.count)
        #expect(result.samples == pcm)
    }

    // MARK: - The choice itself

    @Test("only a decoder that produces 16 bits or fewer gets a 16-bit FLAC")
    func intermediateFollowsTheDecodedFormat() {
        for fmt in [AV_SAMPLE_FMT_U8, AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P] {
            #expect(AudioBridge.flacIntermediate(decodedFormat: fmt).bitsPerRawSample == 16)
        }
        // Integer 24/32-bit, and float decodes of lossy codecs (AAC, Opus, Vorbis, MP3 decode to fltp),
        // whose precision a 16-bit requantisation would throw away; NONE is a decoder that defers its
        // format to the first frame (TrueHD, DTS), which must never be guessed down.
        for fmt in [AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P, AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP,
                    AV_SAMPLE_FMT_DBLP, AV_SAMPLE_FMT_S64, AV_SAMPLE_FMT_NONE] {
            let choice = AudioBridge.flacIntermediate(decodedFormat: fmt)
            #expect(choice.format == AV_SAMPLE_FMT_S32 && choice.bitsPerRawSample == 24, "\(fmt.rawValue)")
        }
    }
}
