import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// LATM is a transport around AAC: taken out of it, a stream's frames and its AudioSpecificConfig
/// are AAC like any other (`LATM`). The proof is libavcodec's own two decoders: the frames
/// unwrapped here, decoded as plain AAC with the configuration unwrapped with them, give exactly
/// the samples its LATM decoder gives for the stream as it was.
@Suite("LATM unwraps to AAC")
struct LATMTests {

    /// The demuxed LOAS frames and the stream's `extradata` after probing.
    private func demux(_ data: Data) throws -> (packets: [[UInt8]], extradata: [UInt8]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latm-\(UUID().uuidString).latm")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var input: UnsafeMutablePointer<AVFormatContext>?
        try #require(avformat_open_input(&input, url.path, nil, nil) == 0)
        defer { avformat_close_input(&input) }
        let ctx = try #require(input)
        try #require(avformat_find_stream_info(ctx, nil) >= 0)
        let par = try #require(ctx.pointee.streams[0]).pointee.codecpar!
        try #require(par.pointee.codec_id == AV_CODEC_ID_AAC_LATM)
        let extradata = Array(UnsafeBufferPointer(start: par.pointee.extradata, count: Int(par.pointee.extradata_size)))
        var packets: [[UInt8]] = []
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        while av_read_frame(ctx, pkt) >= 0 {
            packets.append(Array(UnsafeBufferPointer(start: pkt!.pointee.data, count: Int(pkt!.pointee.size))))
            av_packet_unref(pkt)
        }
        return (packets, extradata)
    }

    /// Every sample `packets` decode to through `codec`, planes concatenated per frame.
    private func decode(_ packets: [[UInt8]], codec id: AVCodecID, extradata: [UInt8]?) throws -> [Float] {
        let codec = try #require(avcodec_find_decoder(id))
        var ctx = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&ctx) }
        let c = try #require(ctx)
        if let extradata {
            c.pointee.extradata = av_mallocz(extradata.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?.assumingMemoryBound(to: UInt8.self)
            c.pointee.extradata.update(from: extradata, count: extradata.count)
            c.pointee.extradata_size = Int32(extradata.count)
        }
        try #require(avcodec_open2(c, codec, nil) == 0)
        var samples: [Float] = []
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        func drain() {
            while avcodec_receive_frame(c, frame) == 0 {
                let f = frame!.pointee
                for ch in 0..<Int(f.ch_layout.nb_channels) {
                    let plane = UnsafeRawPointer(f.extended_data[ch]!).assumingMemoryBound(to: Float.self)
                    samples += UnsafeBufferPointer(start: plane, count: Int(f.nb_samples))
                }
            }
        }
        var pkt = av_packet_alloc()
        defer { av_packet_free(&pkt) }
        for p in packets {
            _ = av_new_packet(pkt, Int32(p.count))
            pkt!.pointee.data.update(from: p, count: p.count)
            _ = avcodec_send_packet(c, pkt)
            av_packet_unref(pkt)
            drain()
        }
        _ = avcodec_send_packet(c, nil)
        drain()
        return samples
    }

    @Test("the unwrapped frames decode as AAC to exactly what the LATM decoder gives",
          arguments: ["lowComplexity", "highEfficiency"])
    func unwrapsLosslessly(fixture: String) throws {
        let (packets, extradata) = try demux(fixture == "lowComplexity" ? LATMFixture.lowComplexity : LATMFixture.highEfficiency)
        var reader = LATM.Reader()
        let frames = packets.compactMap { p in p.withUnsafeBytes { reader.payload($0) } }
        #expect(frames.count == packets.count, "every element unwraps")
        let config = try #require(reader.config)
        #expect(extradata.withUnsafeBytes { LATM.configuration(extradata: $0) } == config,
                "the probe's extradata, cut at its end, is the stream's configuration")
        let unwrapped = try decode(frames, codec: AV_CODEC_ID_AAC, extradata: config)
        let original = try decode(packets, codec: AV_CODEC_ID_AAC_LATM, extradata: nil)
        #expect(unwrapped.count > 40_000)
        #expect(unwrapped == original)
    }

    @Test("an element reusing a configuration no element has carried yet is not read")
    func needsAConfiguration() throws {
        let (packets, _) = try demux(LATMFixture.lowComplexity)
        var reader = LATM.Reader()
        // The muxer carries the configuration in every fifth element, the first included.
        #expect(packets[1].withUnsafeBytes { reader.payload($0) } == nil)
        #expect(packets[0].withUnsafeBytes { reader.payload($0) } != nil)
        #expect(packets[1].withUnsafeBytes { reader.payload($0) } != nil)
    }

    @Test("the configuration's length is read off its own syntax")
    func configurationLength() {
        func length(_ bytes: [UInt8]) -> Int? {
            bytes.withUnsafeBytes { AudioSpecificConfigReader.length(LATM.BitReader($0)) }
        }
        #expect(length([0x11, 0x90]) == 16)              // LC, 48 kHz, stereo: 5+4+4+3
        #expect(length([0x2b, 0x11, 0x88, 0x00]) == 25)  // HE-AAC, explicit: 5+4+4+4+5+3
        #expect(length([0xeb, 0x09, 0x88, 0x00]) == 25)  // HE-AACv2, explicit
        #expect(length([0x11, 0x80]) == nil)             // channel configuration 0: a PCE
    }
}
