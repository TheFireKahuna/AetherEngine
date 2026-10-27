import Foundation
import Metal
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The software decoder makes its finisher pipelines when it opens, from what the stream declares
/// (`SoftwareVideoDecoder.expectedPlans`): worth it only if the first picture's plan is among them.
struct DecoderWarmupTests {
    struct Case: CustomStringConvertible, Sendable {
        let name: String
        let fixture: String
        let container: String
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "interlaced H.264", fixture: SoftwareDecoderCatchUpTests.interlacedBase64, container: "mp4"),
        Case(name: "hard-telecined H.264", fixture: SoftwareDecoderCatchUpTests.telecineBase64, container: "mp4"),
        Case(name: "soft-telecined MPEG-2", fixture: FilmCadenceTests.softTelecineBase64, container: "mpegts"),
    ]

    @Test("the first picture's plan is one the decoder made at open", arguments: cases)
    func firstPictureWarmed(_ c: Case) throws {
        let data = try #require(Data(base64Encoded: c.fixture, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: c.container)
        defer { demuxer.close() }
        let stream = try #require(demuxer.stream(at: demuxer.videoStreamIndex))
        let codecpar = try #require(stream.pointee.codecpar)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let writer = try DisplayBufferWriter(device: device, streamIs10Bit: false, twelveBit420: .p010Dithered,
                                             containerHDRStatic: .none, logTag: "DecoderWarmupTests")
        let expected = SoftwareVideoDecoder.expectedPlans(codecpar, writer: writer, deinterlaces: true)

        let codec = try #require(avcodec_find_decoder(codecpar.pointee.codec_id))
        var context = avcodec_alloc_context3(codec)
        defer { avcodec_free_context(&context) }
        let ctx = try #require(context)
        try #require(avcodec_parameters_to_context(ctx, codecpar) >= 0)
        writer.install(on: ctx, codec: codec)
        try #require(avcodec_open2(ctx, codec, nil) >= 0)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        var decoded = false
        while !decoded, let packet = try demuxer.readPacket() {
            if packet.pointee.stream_index == demuxer.videoStreamIndex {
                _ = avcodec_send_packet(ctx, packet)
                decoded = avcodec_receive_frame(ctx, f) >= 0
            }
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
        try #require(decoded, "no picture")
        // As the decoder prepares it: an interlaced picture's deinterlaced fields in the planar equivalent, a progressive
        // one (and every inverse-telecine output) in its own format.
        let format = AVPixelFormat(rawValue: f.pointee.format)
        let interlaced = f.pointee.flags & AV_FRAME_FLAG_INTERLACED != 0
        let planFormat = interlaced ? try #require(PlanarFrameFinisher.planarEquivalent(of: format)) : format
        let first = try #require(writer.prepare(f, planFormat: planFormat, interlaced: false)).plan
        #expect(expected.contains(first), "\(expected.count) made, the first picture's not among them")
        let own = try #require(writer.prepare(f, planFormat: format, interlaced: false)).plan
        #expect(expected.contains(own), "the stream's own plan (inverse telecine's outputs) not made")
    }
}
