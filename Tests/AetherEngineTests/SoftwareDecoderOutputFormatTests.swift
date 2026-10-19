import Foundation
import CoreVideo
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit DEC-107: `SoftwareVideoDecoder` hard-wired its output to 8-bit or 10-bit VIDEO range from the
/// container declaration. `color_range` was never read, so a full-range AV1 / VP9 / HEVC picture was
/// labelled video range and shown crushed, and `bits_per_raw_sample` is 0 for libdav1d and the AV1 / VP9
/// parsers, so a 10-bit SDR stream was dithered down to 8 bit. The pool format now follows the frame.
@Suite("Software decoder output format follows the frame (DEC-107)")
struct SoftwareDecoderOutputFormatTests {

    // MARK: - The decision

    @Test("full range is carried as a label on 8-bit and on 10-bit output")
    func fullRangeIsALabel() {
        let eight = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(eight == .init(tenBit: false, fullRange: true))
        #expect(eight.pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        let ten = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(ten == .init(tenBit: true, fullRange: true))
        #expect(ten.pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
    }

    @Test("limited and unspecified range stay video range")
    func limitedStaysVideoRange() {
        for range in [AVCOL_RANGE_MPEG, AVCOL_RANGE_UNSPECIFIED] {
            let format = SoftwareVideoDecoder.outputFormat(
                pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: range, streamIs10Bit: false)
            #expect(format == .init(tenBit: false, fullRange: false))
            #expect(format.pixelFormatType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        }
    }

    @Test("a 10-bit frame is 10-bit output even when the stream declared no depth")
    func frameDepthWidensTheDeclaration() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P10LE.rawValue, colorRange: AVCOL_RANGE_MPEG, streamIs10Bit: false)
        #expect(format == .init(tenBit: true, fullRange: false))
        #expect(format.swscaleFormat == AV_PIX_FMT_P010LE)
    }

    @Test("the stream's own 10-bit verdict is never narrowed by an 8-bit frame")
    func declarationIsNeverNarrowed() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUV420P.rawValue, colorRange: AVCOL_RANGE_MPEG, streamIs10Bit: true)
        #expect(format.tenBit)
    }

    @Test("a yuvj source stays video range, because swscale converts it itself")
    func yuvjIsConvertedBySwscale() {
        let format = SoftwareVideoDecoder.outputFormat(
            pixelFormat: AV_PIX_FMT_YUVJ420P.rawValue, colorRange: AVCOL_RANGE_JPEG, streamIs10Bit: false)
        #expect(format == .init(tenBit: false, fullRange: false))
    }

    // MARK: - Native subsampling and depth (#8)

    private func format(_ pixelFormat: AVPixelFormat, _ range: AVColorRange = AVCOL_RANGE_MPEG,
                        twelveBit420: SoftwareVideoDecoder.TwelveBit420Output = .p010Dithered) -> SoftwareVideoDecoder.OutputFormat {
        SoftwareVideoDecoder.outputFormat(pixelFormat: pixelFormat.rawValue, colorRange: range, streamIs10Bit: false,
                                          twelveBit420: twelveBit420)
    }

    @Test("#8: 8- and 10-bit 4:2:2 / 4:4:4 keep their subsampling, in both ranges")
    func nativeSubsamplingKept() {
        #expect(format(AV_PIX_FMT_YUV422P).pixelFormatType == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV422P, AVCOL_RANGE_JPEG).pixelFormatType == kCVPixelFormatType_422YpCbCr8BiPlanarFullRange)
        #expect(format(AV_PIX_FMT_YUV444P).pixelFormatType == kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV444P, AVCOL_RANGE_JPEG).pixelFormatType == kCVPixelFormatType_444YpCbCr8BiPlanarFullRange)
        #expect(format(AV_PIX_FMT_YUV422P10LE).pixelFormatType == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV422P10LE, AVCOL_RANGE_JPEG).pixelFormatType == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        #expect(format(AV_PIX_FMT_YUV444P10LE).pixelFormatType == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV444P10LE, AVCOL_RANGE_JPEG).pixelFormatType == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
        #expect(format(AV_PIX_FMT_YUV422P10LE).swscaleFormat == AV_PIX_FMT_P210LE)
        #expect(format(AV_PIX_FMT_YUV444P).swscaleFormat == AV_PIX_FMT_NV24)
    }

    @Test("#8: 12-bit 4:2:2 / 4:4:4 keep all their bits in sv22 / sv44, video range only")
    func twelveBitKeptInSixteen() {
        #expect(format(AV_PIX_FMT_YUV422P12LE).pixelFormatType == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV444P12LE).pixelFormatType == kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange)
        #expect(format(AV_PIX_FMT_YUV422P12LE).swscaleFormat == AV_PIX_FMT_P216LE)
        #expect(!format(AV_PIX_FMT_YUV422P12LE).dithers)
        // sv22 / sv44 have no full-range variant: the 10-bit full-range format, dithered.
        let full422 = format(AV_PIX_FMT_YUV422P12LE, AVCOL_RANGE_JPEG)
        #expect(full422.pixelFormatType == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange)
        #expect(full422.dithers)
        #expect(full422.swscaleFormat == AV_PIX_FMT_P216LE, "swscale writes 16 bits; the dither cuts them to 10")
        #expect(format(AV_PIX_FMT_YUV444P12LE, AVCOL_RANGE_JPEG).pixelFormatType == kCVPixelFormatType_444YpCbCr10BiPlanarFullRange)
    }

    @Test("#8: 12-bit 4:2:0 is dithered x420 by default and sv22 when asked, video range only")
    func twelveBit420Option() {
        let dithered = format(AV_PIX_FMT_YUV420P12LE)
        #expect(dithered.pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(dithered.dithers)
        #expect(dithered.swscaleFormat == AV_PIX_FMT_P016LE)
        #expect(format(AV_PIX_FMT_YUV420P12LE, twelveBit420: .sv22).pixelFormatType
                == kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange)
        let fullSV22 = format(AV_PIX_FMT_YUV420P12LE, AVCOL_RANGE_JPEG, twelveBit420: .sv22)
        #expect(fullSV22.pixelFormatType == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(fullSV22.dithers)
    }

    @Test("#8: odd layouts land on the nearest kept subsampling; RGB is 4:4:4, grey 4:2:0")
    func oddLayouts() {
        #expect(format(AV_PIX_FMT_YUV411P).chroma == .yuv422)
        #expect(format(AV_PIX_FMT_YUV410P).chroma == .yuv420)
        #expect(format(AV_PIX_FMT_YUV440P).chroma == .yuv444)
        #expect(format(AV_PIX_FMT_GBRP).chroma == .yuv444)
        #expect(format(AV_PIX_FMT_GRAY8).chroma == .yuv420)
        #expect(format(AV_PIX_FMT_GBRP10LE).pixelFormatType == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange)
    }

    @Test("#8: every output format reads back from its own pixel format type")
    func roundTripsThroughThePixelFormatType() {
        for chroma in [SoftwareVideoDecoder.OutputFormat.Chroma.yuv420, .yuv422, .yuv444] {
            for depth in [SoftwareVideoDecoder.OutputFormat.Depth.eight, .ten] {
                for full in [false, true] {
                    let f = SoftwareVideoDecoder.OutputFormat(chroma: chroma, depth: depth, fullRange: full)
                    #expect(SoftwareVideoDecoder.OutputFormat(pixelFormatType: f.pixelFormatType) == f)
                }
            }
        }
        #expect(SoftwareVideoDecoder.OutputFormat(pixelFormatType: kCVPixelFormatType_32BGRA) == nil)
    }

    /// 12-bit 2049 is 10-bit 512.25: a quarter of the 8x8 cells must round up, so the block averages
    /// back to the 12-bit value, and every word is a clean 10-bit code (low six bits clear).
    @Test("#8: the ordered dither keeps a 12-bit level's mean in 10-bit codes, saturating at the top")
    func ditherKeepsTheMean() {
        var words = [UInt16](repeating: 2049 << 4, count: 8 * 8)
        words[63] = 0xFFFF
        words.withUnsafeMutableBytes { raw in
            SoftwareVideoDecoder.ditherTo10Bit(plane: raw.baseAddress!, bytesPerRow: 16, width: 8, height: 8)
        }
        #expect(words.allSatisfy { $0 & 0x3F == 0 })
        #expect(words[63] == 0xFFC0)
        let codes = words[0..<63].map { Int($0 >> 6) }
        #expect(Set(codes) == [512, 513])
        #expect(codes.filter { $0 == 513 }.count == 16, "the 16 Bayer cells at 48 or above; the saturated corner is not one of them")
    }

    // MARK: - Real decodes

    private func firstPixelBuffer(base64: String, formatHint: String?) throws -> CVPixelBuffer {
        let data = try #require(Data(base64Encoded: base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: formatHint)
        defer { demuxer.close() }
        let videoIndex = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: videoIndex))

        let box = FrameBox()
        let decoder = SoftwareVideoDecoder()
        decoder.decodesSingleThreaded = true
        try decoder.open(stream: stream) { buffer, _, _ in box.keepFirst(buffer) }
        defer { decoder.close() }

        while let pkt = try? demuxer.readPacket() {
            if pkt.pointee.stream_index == videoIndex { decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return try #require(box.first, "the fixture must decode to at least one frame")
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func keepFirst(_ candidate: CVPixelBuffer) { lock.withLock { if buffer == nil { buffer = candidate } } }
        var first: CVPixelBuffer? { lock.withLock { buffer } }
    }

    @Test("a full-range VP9 picture reaches the layer as full range, with its white still at 255")
    func fullRangeVP9() throws {
        let buffer = try firstPixelBuffer(base64: Self.vp9FullRangeBase64, formatHint: nil)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        #expect(luma[0] == 255, "no range conversion: the decoder's bytes are copied across and only labelled")
    }

    @Test("a 10-bit SDR AV1 picture stays 10-bit instead of being dithered to 8")
    func tenBitSDRAV1() throws {
        let buffer = try firstPixelBuffer(base64: Self.av1TenBitBase64, formatHint: "mp4")
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    }

    @Test("#8: a 10-bit 4:2:2 HEVC picture reaches the layer as x422")
    func tenBit422HEVC() throws {
        let buffer = try firstPixelBuffer(base64: Self.hevc422p10Base64, formatHint: "mp4")
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        #expect(CVPixelBufferGetHeightOfPlane(buffer, 1) == 64, "4:2:2 chroma is full height")
    }

    @Test("#8: a 12-bit 4:2:0 HEVC picture reaches the layer as dithered x420, every word a 10-bit code")
    func twelveBit420HEVC() throws {
        let buffer = try firstPixelBuffer(base64: Self.hevc420p12Base64, formatHint: "mp4")
        #expect(CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        var codes = Set<UInt16>()
        for y in 0..<64 { for x in 0..<64 { codes.insert(luma[y * stride + x]) } }
        #expect(codes.allSatisfy { $0 & 0x3F == 0 }, "nothing left in P010's padding bits")
        #expect(codes.count <= 2, "a flat 12-bit level is at most two adjacent 10-bit codes")
    }

    /// 64x64 gray, 3 frames, 10-bit 4:2:2. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=0x808080:s=64x64:r=10:d=0.3" -vf format=yuv422p10le -c:v libx265 -preset ultrafast \
    ///     -x265-params "log-level=error:info=0" -tag:v hvc1 -map_metadata -1 -fflags +bitexact -flags:v +bitexact h422p10.mp4
    static let hevc422p10Base64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAMG1kYXQAAAAKKAGsRgET6cw9UwAAAAkCAdARViCEoMQAAAAJ
        AAHgJL4IM5y8AAADkW1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAEsAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
        AAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAALgdHJhawAAAFx0a2hkAAAAAwAAAAAA
        AAAAAAAAAQAAAAAAAAEsAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAA
        AAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAABLAAACAAAAQAAAAACWG1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAKAAAAAwAVcQA
        AAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAgNtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAA
        AAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAHDc3RibAAAAQhzdHNkAAAAAAAAAAEAAAD4aHZjMQAAAAAAAAAB
        AAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAAAAAAAQxMYXZjIGxpYngyNjUAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAAAHRo
        dmNDAQQIAAAAnQgAAAAAHvAA/P76+gAADwOgAAEAF0ABDAH//wQIAAADAJ0IAAADAAAelZQJoQABAClCAQEECAAAAwCdCAAAAwAA
        HrAggQTZZWVKTC8BaAgAAAMACAAAAwBQQKIAAQAGRAHAc8CJAAAACmZpZWwBAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAA
        AAQqAAAAAAAAABhzdHRzAAAAAAAAAAEAAAADAAAEAAAAABRzdHNzAAAAAAAAAAEAAAABAAAAD3NkdHAAAAAAIBAYAAAAKGN0dHMA
        AAAAAAAAAwAAAAEAAAgAAAAAAQAADAAAAAABAAAEAAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAwAAAAEAAAAgc3RzegAAAAAAAAAA
        AAAAAwAAAA4AAAANAAAADQAAABRzdGNvAAAAAAAAAAEAAAAsAAAAPXVkdGEAAAA1bWV0YQAAAAAAAAAhaGRscgAAAAAAAAAAbWRp
        cmFwcGwAAAAAAAAAAAAAAAAIaWxzdA==
        """

    /// The same with `format=yuv420p12le` (HEVC Main 12). Regenerate as above, `h420p12.mp4`.
    static let hevc420p12Base64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAMG1kYXQAAAAKKAGsRgL/wDJF+AAAAAkCAdARViCEoMQAAAAJ
        AAHgJL4IM5y8AAADkG1vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAAEsAAEAAAEAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAA
        AAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAIAAALfdHJhawAAAFx0a2hkAAAAAwAAAAAA
        AAAAAAAAAQAAAAAAAAEsAAAAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAA
        AAAAJGVkdHMAAAAcZWxzdAAAAAAAAAABAAABLAAACAAAAQAAAAACV21kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAAKAAAAAwAVcQA
        AAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAgJtaW5mAAAAFHZtaGQAAAABAAAAAAAAAAAA
        AAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAAAAEAAAHCc3RibAAAAQdzdHNkAAAAAAAAAAEAAAD3aHZjMQAAAAAAAAAB
        AAAAAAAAAAAAAAAAAAAAAABAAEAASAAAAEgAAAAAAAAAAQxMYXZjIGxpYngyNjUAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAAAHNo
        dmNDAQQIAAAAmYgAAAAAHvAA/P38/AAADwOgAAEAF0ABDAH//wQIAAADAJmIAAADAAAelZQJoQABAChCAQEECAAAAwCZiAAAAwAA
        HqAggQRSllZUpMLwFoCAAAADAIAAAAUEogABAAZEAcBzwIkAAAAKZmllbAEAAAAAEHBhc3AAAAABAAAAAQAAABRidHJ0AAAAAAAA
        BCoAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAMAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAPc2R0cAAAAAAgEBgAAAAoY3R0cwAA
        AAAAAAADAAAAAQAACAAAAAABAAAMAAAAAAEAAAQAAAAAHHN0c2MAAAAAAAAAAQAAAAEAAAADAAAAAQAAACBzdHN6AAAAAAAAAAAA
        AAADAAAADgAAAA0AAAANAAAAFHN0Y28AAAAAAAAAAQAAACwAAAA9dWR0YQAAADVtZXRhAAAAAAAAACFoZGxyAAAAAAAAAABtZGly
        YXBwbAAAAAAAAAAAAAAAAAhpbHN0
        """

    /// 64x64 white, 3 frames, `-color_range pc`. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=white:s=64x64:r=10:d=0.3" -vf "scale=out_range=pc:out_color_matrix=bt709,format=yuv420p" \
    ///     -c:v libvpx-vp9 -color_range pc -b:v 100k -deadline realtime -cpu-used 8 -g 10 vp9fr.webm
    static let vp9FullRangeBase64 = """
        GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAJjEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZU
        rmtTrIHYTbuMU6uEElTDZ1OsggEpTbuMU6uEHFO7a1OsggJN7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsirXsYMPQkBNgI1M
        YXZmNjIuMTIuMTAxV0GNTGF2ZjYyLjEyLjEwMUSJiEBywAAAAAAAFlSua8yuAQAAAAAAAEPXgQFzxYjMgzwgXtS2wJyBACK1nIN1
        bmSIgQCGhVZfVlA5g4EBI+ODhAX14QDglLCBQLqBQJqBAlWwiFWxgQFVuYECElTDZ0CAc3OgY8CAZ8iaRaOHRU5DT0RFUkSHjUxh
        dmY2Mi4xMi4xMDFzc9pjwItjxYjMgzwgXtS2wGfIpUWjh0VOQ09ERVJEh5hMYXZjNjIuMjguMTAxIGxpYnZweC12cDlnyKFFo4hE
        VVJBVElPTkSHkzAwOjAwOjAwLjMwMDAwMDAwMAAfQ7Z1QJjngQCj6YEAAICCSYNCUAPwA/YGOCQcGEIAACBAAGxb///ZMyRz+Oqo
        thxUFRuF7BRUkRNywleB6KhH4xFBDtsK7OkcSQT//+C9lZfb5yBGkxAXMq8VCzCvy+wStgESyCieiKCHbYV2dI4kgNw6QKOTgQBk
        AIYAQJKcKElAAANwAABUcKOTgQDIAIYAQJKcLErAAANwAABUcBxTu2uRu4+zgQC3iveBAfGCAa/wgQM=
        """

    /// 64x64 gray, 3 frames, 10-bit 4:2:0, video range, no `bits_per_raw_sample` anywhere. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=0x808080:s=64x64:r=10:d=0.3" -vf format=yuv420p10le -c:v libsvtav1 \
    ///     -preset 12 -g 10 -pix_fmt yuv420p10le av110.mp4
    static let av1TenBitBase64 = """
        AAAAIGZ0eXBpc29tAAACAGlzb21hdjAxaXNvMm1wNDEAAAAIZnJlZQAAAEttZGF0CgoAAAACr/+JXygIMgwQAK8CCCBBAQAAAv4y
        ESgCACSSSRGMAAABAAEAAJwQMhEwAgQJJAAjGAAAAgADAACc6BoBiAAAAyNtb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPoAAAB
        LAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAACAAACTXRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAAAAEAAAAAAAABLAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAA
        AAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAASwAAAAAAAEAAAAAAcVtZGlh
        AAAAIG1kaGQAAAAAAAAAAAAAAAAAACgAAAAMAFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAAAAAAAAAAAFZpZGVvSGFuZGxl
        cgAAAAFwbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYAAAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAABMHN0YmwA
        AACsc3RzZAAAAAAAAAABAAAAnGF2MDEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEXTGF2YzYyLjI4
        LjEwMSBsaWJzdnRhdjEAAAAAAAAAAAAY//8AAAAYYXYxQ4EATAAKCgAAAAKv/4BfCAgAAAAKZmllbAEAAAAAEHBhc3AAAAABAAAA
        AQAAABRidHJ0AAAAAAAABvoAAAb6AAAAGHN0dHMAAAAAAAAAAQAAAAMAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEAAAAcc3RzYwAA
        AAAAAAABAAAAAQAAAAMAAAABAAAAIHN0c3oAAAAAAAAAAAAAAAMAAAAaAAAAJgAAAAMAAAAUc3RjbwAAAAAAAAABAAAAMAAAAGJ1
        ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAAAAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAA
        AQAAAABMYXZmNjIuMTIuMTAx
        """
}
