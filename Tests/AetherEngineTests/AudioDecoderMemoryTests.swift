import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import AetherLibswresample
import Foundation
import Testing
@testable import AetherEngine

func decmemFixture(_ name: String) -> String {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/decmem").appendingPathComponent(name).path
}

/// The bridge's stages against what they declare (`AudioStageSpan`): a run started anywhere puts out
/// what a continuous run does, byte for byte, from `memory` after its start. Each clip under
/// Fixtures/decmem/ is 12 s of music-like audio in one codec the bridge decodes.
@Suite("A run started anywhere matches continuous playback past its declared memory")
struct AudioDecoderMemoryTests {

    private struct Clip {
        var packets: [UnsafeMutablePointer<AVPacket>] = []
        let codecpar: UnsafeMutablePointer<AVCodecParameters>
        let timeBase: AVRational
        func free() {
            for p in packets { var q: UnsafeMutablePointer<AVPacket>? = p; av_packet_free(&q) }
            var c: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&c)
        }
    }

    private func read(_ name: String) throws -> Clip {
        let path = decmemFixture(name)
        try #require(FileManager.default.fileExists(atPath: path), "run Scripts/fetch-fixtures.sh to generate Fixtures/decmem/")
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&fmt, path, nil, nil) == 0)
        defer { avformat_close_input(&fmt) }
        try #require(avformat_find_stream_info(fmt, nil) >= 0)
        let index = av_find_best_stream(fmt, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        try #require(index >= 0)
        let stream = fmt!.pointee.streams[Int(index)]!
        var clip = Clip(codecpar: avcodec_parameters_alloc()!, timeBase: stream.pointee.time_base)
        avcodec_parameters_copy(clip.codecpar, stream.pointee.codecpar)
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        while av_read_frame(fmt, pkt) >= 0 {
            if pkt!.pointee.stream_index == index, let c = av_packet_clone(pkt) { clip.packets.append(c) }
            av_packet_unref(pkt)
        }
        return clip
    }

    /// A decoder opened as the bridge opens one; `decode` returns a packet's output as the decoder's
    /// frames hand it over, plane after plane, and how many frames of audio it holds.
    private final class Decoder {
        let ctx: UnsafeMutablePointer<AVCodecContext>
        let frame = av_frame_alloc()!
        init(_ clip: Clip) throws {
            let codec = try #require(avcodec_find_decoder(clip.codecpar.pointee.codec_id))
            ctx = avcodec_alloc_context3(codec)!
            avcodec_parameters_to_context(ctx, clip.codecpar)
            ctx.pointee.pkt_timebase = clip.timeBase
            try #require(openAudioDecoder(ctx, codec) >= 0)
        }
        deinit {
            var c: UnsafeMutablePointer<AVCodecContext>? = ctx
            avcodec_free_context(&c)
            var f: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&f)
        }
        func decode(_ pkt: UnsafeMutablePointer<AVPacket>) -> (bytes: [UInt8], frames: Int) {
            var bytes: [UInt8] = [], frames = 0
            guard avcodec_send_packet(ctx, pkt) >= 0 else { return (bytes, frames) }
            while avcodec_receive_frame(ctx, frame) >= 0 {
                let f = frame.pointee
                let format = AVSampleFormat(rawValue: f.format)
                let planar = av_sample_fmt_is_planar(format) != 0
                let channels = Int(f.ch_layout.nb_channels)
                let planeBytes = Int(f.nb_samples) * Int(av_get_bytes_per_sample(format)) * (planar ? 1 : channels)
                for c in 0..<(planar ? channels : 1) {
                    bytes += UnsafeBufferPointer(start: f.extended_data[c]!, count: planeBytes)
                }
                frames += Int(f.nb_samples)
                av_frame_unref(frame)
            }
            return (bytes, frames)
        }
    }

    @Test("a decoder settles within its declared memory",
          arguments: ["mp2.mkv", "mp3-64k.mp3", "mp3-vbr.mkv", "mp3-lsf.mp3", "vorbis.ogg", "opus.mkv",
                      "dts-51.mkv", "truehd-51.mkv", "truehd-96k.mkv", "flac.mkv"])
    func decoderSettles(_ name: String) throws {
        let clip = try read(name)
        defer { clip.free() }
        let rate = clip.codecpar.pointee.sample_rate
        let memory = try #require(AudioStageSpan.decoder(clip.codecpar, outputRate: rate)).memory
        let continuous = try Decoder(clip)
        let outputs = clip.packets.map { continuous.decode($0) }
        // Where each packet's output begins in the continuous decode.
        var starts = [0]
        for o in outputs { starts.append(starts.last! + o.frames) }
        let checked = Int(rate)   // a second of output past the declared memory
        let lastStart = try #require(starts.lastIndex { $0 + memory + checked <= starts.last! })
        try #require(lastStart > 1, "the clip is shorter than the declared memory")

        for i in 0..<12 {
            let k = 1 + (lastStart - 1) * i / 11
            let fresh = try Decoder(clip)
            for j in k..<clip.packets.count {
                let out = fresh.decode(clip.packets[j])
                let offset = starts[j] - starts[k]
                guard offset >= memory else { continue }
                if offset > memory + checked { break }
                #expect(out.frames == outputs[j].frames && out.bytes == outputs[j].bytes,
                        "\(name): a decode from packet \(k) differs at packet \(j), \(offset) frames in (declared \(memory))")
                if out.bytes != outputs[j].bytes { break }
            }
        }
    }

    /// The whole clip decoded, plane by plane, as S32P or FLTP (a packed decode is split into planes).
    private func decodeAll(_ clip: Clip) throws -> (format: AVSampleFormat, planes: [[UInt32]]) {
        let dec = try Decoder(clip)
        let channels = Int(clip.codecpar.pointee.ch_layout.nb_channels)
        var planes = [[UInt32]](repeating: [], count: channels)
        var format = AV_SAMPLE_FMT_NONE
        for p in clip.packets {
            let out = dec.decode(p)
            guard out.frames > 0 else { continue }
            format = dec.ctx.pointee.sample_fmt
            let planar = av_sample_fmt_is_planar(format) != 0
            out.bytes.withUnsafeBytes { raw in
                let s = raw.bindMemory(to: UInt32.self)
                for c in 0..<channels {
                    planes[c] += planar ? Array(s[(c * out.frames)..<((c + 1) * out.frames)])
                        : (0..<out.frames).map { s[$0 * channels + c] }
                }
            }
        }
        format = av_get_planar_sample_fmt(format)
        try #require(format == AV_SAMPLE_FMT_S32P || format == AV_SAMPLE_FMT_FLTP)
        return (format, planes)
    }

    @Test("the resampler settles within its declared span, 96 kHz into 48")
    func resamplerSettles() throws {
        let clip = try read("truehd-96k.mkv")
        defer { clip.free() }
        let (format, planes) = try decodeAll(clip)
        try #require(format == AV_SAMPLE_FMT_S32P)
        let span = AudioStageSpan.resampler(inputRate: 96_000, outputRate: 48_000)
        func resample(from first: Int) throws -> [UInt32] {
            var layout = AVChannelLayout()
            av_channel_layout_default(&layout, Int32(planes.count))
            defer { av_channel_layout_uninit(&layout) }
            var swr: OpaquePointer?
            try #require(swr_alloc_set_opts2(&swr, &layout, AV_SAMPLE_FMT_S32, 48_000, &layout, AV_SAMPLE_FMT_S32P, 96_000, 0, nil) >= 0)
            defer { swr_free(&swr) }
            AudioBridge.applyResamplerQuality(swr!, outputFormat: AV_SAMPLE_FMT_S32)
            try #require(swr_init(swr) >= 0)
            let inputs = planes.map { plane -> UnsafeMutablePointer<UInt32> in
                let p = UnsafeMutablePointer<UInt32>.allocate(capacity: plane.count)
                p.initialize(from: plane, count: plane.count)
                return p
            }
            defer { inputs.forEach { $0.deallocate() } }
            let chunk = 1024, room = chunk / 2 + 64
            let buffer = UnsafeMutablePointer<UInt32>.allocate(capacity: room * planes.count)
            defer { buffer.deallocate() }
            var out: [UInt32] = []
            var at = first
            while at + chunk <= planes[0].count {
                var ins: [UnsafePointer<UInt8>?] = inputs.map { UnsafeRawPointer($0 + at).assumingMemoryBound(to: UInt8.self) }
                var outs: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutableRawPointer(buffer).assumingMemoryBound(to: UInt8.self)]
                let got = Int(swr_convert(swr, &outs, Int32(room), &ins, Int32(chunk)))
                try #require(got >= 0)
                out += UnsafeBufferPointer(start: buffer, count: got * planes.count)
                at += chunk
            }
            return out
        }
        let continuous = try resample(from: 0)
        let channels = planes.count
        for i in 0..<10 {
            let first = (96_000 + i * 85_000) / 2 * 2   // on the 2:1 phase grid
            let fresh = try resample(from: first)
            let base = first / 2
            let compared = min(fresh.count / channels, continuous.count / channels - base) - span.memory
            let from = span.memory
            #expect(Array(fresh[(from * channels)..<((from + compared) * channels)])
                    == Array(continuous[((base + from) * channels)..<((base + from + compared) * channels)]),
                    "a run from input frame \(first) differs within \(compared) frames past \(span.memory)")
        }
    }

    @Test("the E-AC-3 encoder settles within its declared span")
    func eac3EncoderSettles() throws {
        let clip = try read("dts-51.mkv")
        defer { clip.free() }
        let (format, planes) = try decodeAll(clip)
        let codec = try #require(avcodec_find_encoder(AV_CODEC_ID_EAC3))
        var declared: AudioStageSpan?
        func encode(from first: Int, frames count: Int) throws -> [[UInt8]] {
            var ctx = avcodec_alloc_context3(codec)
            defer { avcodec_free_context(&ctx) }
            let c = try #require(ctx)
            c.pointee.sample_rate = 48_000
            c.pointee.sample_fmt = AV_SAMPLE_FMT_FLTP
            c.pointee.bit_rate = AudioBridge.eac3BitRate(channels: 6)
            c.pointee.time_base = AVRational(num: 1, den: 48_000)
            av_channel_layout_default(&c.pointee.ch_layout, 6)
            try #require(avcodec_open2(c, codec, nil) >= 0)
            let n = Int(c.pointee.frame_size)
            declared = .eac3Encoder(frameSize: n, initialPadding: Int(c.pointee.initial_padding))
            var frame = av_frame_alloc()
            defer { av_frame_free(&frame) }
            var pkt = av_packet_alloc()
            defer { av_packet_free(&pkt) }
            var out: [[UInt8]] = []
            for i in 0..<count {
                let f = frame!
                f.pointee.nb_samples = Int32(n)
                f.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
                f.pointee.sample_rate = 48_000
                f.pointee.pts = Int64((first + i) * n)
                av_channel_layout_default(&f.pointee.ch_layout, 6)
                try #require(av_frame_get_buffer(f, 0) >= 0)
                for ch in 0..<6 {
                    let dst = UnsafeMutableRawPointer(f.pointee.extended_data[ch]!).assumingMemoryBound(to: Float.self)
                    for s in 0..<n {
                        let v = planes[ch][(first + i) * n + s]
                        dst[s] = format == AV_SAMPLE_FMT_FLTP ? Float(bitPattern: v) : Float(Int32(bitPattern: v)) / 2_147_483_648
                    }
                }
                try #require(avcodec_send_frame(c, f) >= 0)
                av_frame_unref(f)
                while avcodec_receive_packet(c, pkt) >= 0 {
                    out.append(Array(UnsafeBufferPointer(start: pkt!.pointee.data, count: Int(pkt!.pointee.size))))
                    av_packet_unref(pkt)
                }
            }
            return out
        }
        let total = planes[0].count / 1536
        let continuous = try encode(from: 0, frames: total)
        let span = try #require(declared)
        let settledPackets = (span.memory + 1535) / 1536
        for i in 0..<12 {
            let first = 1 + (total - 60) * i / 11
            let fresh = try encode(from: first, frames: 40)
            for j in settledPackets..<fresh.count {
                #expect(fresh[j] == continuous[first + j], "a run from frame \(first) differs at packet \(j)")
            }
        }
    }

    @Test("the bridge declares its decoder, resampler and encoder in series; nil for a decoder not known")
    func bridgeComposes() throws {
        let clip = try read("dts-51.mkv")
        defer { clip.free() }
        let bridge = try AudioBridge(srcCodecpar: clip.codecpar, srcTimeBase: clip.timeBase, mode: .surroundCompat)
        #expect(bridge.output == .eac3)
        #expect(bridge.span == AudioStageSpan(latency: 256, memory: AudioStageSpan.dtsDecoderMemory + 1536))

        let pcm = try AudioBridge(srcCodecpar: clip.codecpar, srcTimeBase: clip.timeBase, mode: .lossless)
        #expect(pcm.output == .pcm)
        #expect(pcm.span == AudioStageSpan(latency: 0, memory: AudioStageSpan.dtsDecoderMemory))

        let unknown = try #require(avcodec_parameters_alloc())
        var u: UnsafeMutablePointer<AVCodecParameters>? = unknown
        defer { avcodec_parameters_free(&u) }
        unknown.pointee.codec_id = AV_CODEC_ID_NELLYMOSER
        unknown.pointee.sample_rate = 44_100
        #expect(AudioStageSpan.decoder(unknown, outputRate: 44_100) == nil)
    }
}
