import AetherLibavcodec
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// Blu-ray LPCM copies as `ipcm`: its header off, its samples as they are, its speakers declared in
/// the order the disc stores them (`BluRayLPCM`). libavcodec's own `pcm_bluray` decoder is the
/// reference for the format: for every packet here, each speaker's samples as `BluRayLPCM` declares
/// them equal what that decoder puts out for the same speaker.
@Suite("Blu-ray LPCM copies as ipcm")
struct BluRayLPCMTests {

    /// A packet of `frames` frames: the header, then every stored channel's samples, each a value
    /// of its own (channel c, frame f), big-endian; an odd layout's unused channel carries junk.
    static func packet(assignment: UInt8, depth: UInt8, frames: Int, stored: Int, bytes: Int) -> [UInt8] {
        var p: [UInt8] = [0, 0, assignment << 4 | 1, depth << 6]
        for f in 0..<frames {
            for c in 0..<stored {
                let value = Int32(c + 1) * 1000 + Int32(f) * 7
                let sample = UInt32(bitPattern: value << (bytes == 2 ? 0 : 8))
                if bytes == 2 { p += [UInt8(sample >> 8 & 0xFF), UInt8(sample & 0xFF)] }
                else { p += [UInt8(sample >> 24 & 0xFF), UInt8(sample >> 16 & 0xFF), UInt8(sample >> 8 & 0xFF)] }
            }
        }
        let payload = p.count - 4
        p[0] = UInt8(payload >> 8); p[1] = UInt8(payload & 0xFF)
        return p
    }

    /// What libavcodec's `pcm_bluray` decoder puts out for `bytes`, per speaker, and the codec
    /// parameters its context ends up with.
    static func reference(_ bytes: [UInt8]) throws -> (bySpeaker: [AVChannel: [Int32]], codecpar: UnsafeMutablePointer<AVCodecParameters>) {
        let codec = try #require(avcodec_find_decoder(AV_CODEC_ID_PCM_BLURAY))
        var ctx = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        try #require(avcodec_open2(c, codec, nil) == 0)
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        _ = av_new_packet(pkt, Int32(bytes.count))
        pkt!.pointee.data.update(from: bytes, count: bytes.count)
        try #require(avcodec_send_packet(c, pkt) == 0)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        try #require(avcodec_receive_frame(c, frame) == 0)
        let f = frame!.pointee
        let channels = Int(f.ch_layout.nb_channels)
        var bySpeaker: [AVChannel: [Int32]] = [:]
        for ch in 0..<channels {
            var layout = f.ch_layout
            let speaker = av_channel_layout_channel_from_index(&layout, UInt32(ch))
            bySpeaker[speaker] = (0..<Int(f.nb_samples)).map { i in
                f.format == AV_SAMPLE_FMT_S16.rawValue
                    ? Int32(UnsafeRawPointer(f.data.0!).assumingMemoryBound(to: Int16.self)[i * channels + ch])
                    : UnsafeRawPointer(f.data.0!).assumingMemoryBound(to: Int32.self)[i * channels + ch] >> 8
            }
        }
        let par = avcodec_parameters_alloc()!
        _ = avcodec_parameters_from_context(par, c)
        return (bySpeaker, par)
    }

    @Test("every speaker's samples are the decoder's, in the order the disc stores them",
          arguments: [(9, 1, 6, 6, 2), (11, 3, 8, 8, 3), (11, 2, 8, 8, 3), (8, 1, 5, 6, 2), (10, 3, 7, 8, 3),
                      (3, 3, 2, 2, 3), (1, 1, 1, 2, 2)])
    func samplesMatchTheDecoder(assignment: UInt8, depth: UInt8, channels: Int, stored: Int, bytes: Int) throws {
        let frames = 240
        let bd = Self.packet(assignment: assignment, depth: depth, frames: frames, stored: stored, bytes: bytes)
        let format = try #require(bd.withUnsafeBytes { BluRayLPCM(header: $0) })
        #expect(format.speakers.count == channels && format.storedChannels == stored)
        #expect(format.bytesPerSample == bytes)

        let (bySpeaker, par) = try Self.reference(bd)
        var p: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&p) }
        #expect(BluRayLPCM(codecpar: par) == format, "the probed parameters name the same format")

        let payload = try #require(bd.withUnsafeBytes { raw -> [UInt8]? in
            guard let samples = format.samples(raw) else { return nil }
            return format.isPadded ? format.droppingPadding(samples) : Array(samples)
        })
        #expect(payload.count == frames * channels * bytes)
        for (i, speaker) in format.speakers.enumerated() {
            let ours = (0..<frames).map { f -> Int32 in
                let o = (f * channels + i) * bytes
                return bytes == 2 ? Int32(Int16(bitPattern: UInt16(payload[o]) << 8 | UInt16(payload[o + 1])))
                    : Int32(bitPattern: UInt32(payload[o]) << 24 | UInt32(payload[o + 1]) << 16 | UInt32(payload[o + 2]) << 8) >> 8
            }
            #expect(ours == bySpeaker[speaker], "speaker \(speaker.rawValue)")
        }
    }

    @Test("the muxer is told big-endian samples, the stored speaker order, and 20-bit as its 24-bit words")
    func describesTheMuxerInput() throws {
        let bd = Self.packet(assignment: 9, depth: 2, frames: 4, stored: 6, bytes: 3)
        let format = try #require(bd.withUnsafeBytes { BluRayLPCM(header: $0) })
        var par: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&par) }
        #expect(format.describe(par!))
        #expect(par!.pointee.codec_id == AV_CODEC_ID_PCM_S24BE)
        #expect(par!.pointee.bits_per_raw_sample == 24, "pcmC's sample size: 16, 24 or 32")
        var layout = par!.pointee.ch_layout
        #expect((0..<6).map { av_channel_layout_channel_from_index(&layout, UInt32($0)) } == format.speakers)
        #expect(format.speakers.last == AV_CHAN_LOW_FREQUENCY, "the disc stores 5.1's LFE last")
    }

    @Test("a packet of another format is refused")
    func otherFormatRefused() throws {
        let stereo = Self.packet(assignment: 3, depth: 1, frames: 8, stored: 2, bytes: 2)
        let surround = Self.packet(assignment: 9, depth: 1, frames: 8, stored: 6, bytes: 2)
        let format = try #require(stereo.withUnsafeBytes { BluRayLPCM(header: $0) })
        #expect(surround.withUnsafeBytes { format.samples($0) } == nil)
        #expect(Array(stereo.dropLast()).withUnsafeBytes { format.samples($0) } == nil, "not whole frames")
    }
}
