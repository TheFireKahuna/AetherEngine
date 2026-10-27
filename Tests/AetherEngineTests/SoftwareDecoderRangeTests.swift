import Foundation
import CoreVideo
import Testing
import AetherLibavutil
import AetherLibavcodec
@testable import AetherEngine

/// The software decoder takes a stream's range from its parameter sets, as VideoToolbox does, not from the container.
///
/// The clip is a 64x64 libx264 card, a black left half and a white right half coded at 16 / 235, whose SPS has a VUI
/// without `video_signal_type` (limited, as H.264 infers), stream-copied into MP4 under a full-range `colr`. FFmpeg
/// keeps the container's range in codecpar and its H.264 decoder only overwrites it from a signal type the SPS
/// carries, so with the container's range in the decoder context the picture came out `yuvj420p` and went to the
/// display layer as full range: black 16 shown as a lifted grey.
@Suite("Software decoder range follows the SPS")
struct SoftwareDecoderRangeTests {

    static let limitedSPSUnderFullColr = """
        AAAAIGZ0eXBpc29tAAACAGlzb21pc28yYXZjMW1wNDEAAAAIZnJlZQAAAvxtZGF0AAAAE2dkEAqsuITYCIAAAAMAgAAAGQIAAAAF
        aO4PLIsAAAJeBgX//1rcRem95tlIt5Ys2CDZI+7veDI2NCAtIGNvcmUgMTY1IHIzMjIyIGIzNTYwNWEgLSBILjI2NC9NUEVHLTQg
        QVZDIGNvZGVjIC0gQ29weWxlZnQgMjAwMy0yMDI1IC0gaHR0cDovL3d3dy52aWRlb2xhbi5vcmcveDI2NC5odG1sIC0gb3B0aW9u
        czogY2FiYWM9MSByZWY9MSBkZWJsb2NrPTE6MDowIGFuYWx5c2U9MHgzOjB4MTEzIG1lPWhleCBzdWJtZT03IHBzeT0xIHBzeV9y
        ZD0xLjAwOjAuMDAgbWl4ZWRfcmVmPTAgbWVfcmFuZ2U9MTYgY2hyb21hX21lPTEgdHJlbGxpcz0xIDh4OGRjdD0xIGNxbT0wIGRl
        YWR6b25lPTIxLDExIGZhc3RfcHNraXA9MSBjaHJvbWFfcXBfb2Zmc2V0PS0yIHRocmVhZHM9MiBsb29rYWhlYWRfdGhyZWFkcz0x
        IHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRf
        aW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD0xIGtleWludF9taW49MSBzY2VuZWN1dD00MCBpbnRyYV9yZWZyZXNo
        PTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0x
        LjQwIGFxPTE6MS4wMACAAAAAJWWIhAS//vet34FNwys1a7pIspdjRPlpKwIQEi2nhEppbM9lN8EAAAATZ2QQCqy4hNgIgAAAAwCA
        AAAZAgAAAAVo7g8siwAAACVliIIBX/73ye/Apuvb3rW/knSs9XRrzQmcTy4M5jXOk190G50HAAADKm1vb3YAAABsbXZoZAAAAAAA
        AAAAAAAAAAAST4AAAXcAAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAIAAAJVdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAXcAAAAAAAAAAAAAAAAAAAAA
        AAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAAAAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAF3AAAA
        AAAAAQAAAAABzW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAST4AAAXcAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAA
        AAAAVmlkZW9IYW5kbGVyAAAAAXhtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJs
        IAAAAAEAAAE4c3RibAAAAMxzdHNkAAAAAAAAAAEAAAC8YXZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAA
        AAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAAAC9hdmNDAWQQCv/hABNnZBAKrLiE2AiAAAADAIAAABkC
        AQAFaO4PLIv9+PgAAAAAE2NvbHJuY2x4AAEAAQABgAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAASdQAAEnUAAAABhzdHRz
        AAAAAAAAAAEAAAACAAC7gAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAAAAAAAAAAAgAAAqsAAABJAAAA
        FHN0Y28AAAAAAAAAAQAAADAAAABhdWR0YQAAAFltZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAACxp
        bHN0AAAAJKl0b28AAAAcZGF0YQAAAAEAAAAATGF2ZjYzLjEuMTAy
        """

    @Test("an SPS with no signal type decodes as video range under a full-range colr, its codes as coded")
    func noSignalTypeUnderFullColr() throws {
        let data = try #require(Data(base64Encoded: Self.limitedSPSUnderFullColr, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mp4")
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))
        #expect(stream.pointee.codecpar.pointee.color_range == AVCOL_RANGE_JPEG, "the container's range reaches codecpar")
        let box = Box()
        let decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { buffer, _, _ in box.keep(buffer) }
        defer { decoder.close() }
        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        let buffer = try #require(box.first)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let row = 32 * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        #expect(luma[row + 8] == 16)
        #expect(luma[row + 56] == 235)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func keep(_ b: CVPixelBuffer) { lock.withLock { if buffer == nil { buffer = b } } }
        var first: CVPixelBuffer? { lock.withLock { buffer } }
    }
}
