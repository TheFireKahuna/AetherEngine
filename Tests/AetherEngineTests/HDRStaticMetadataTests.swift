import Foundation
import CoreVideo
import CoreMedia
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// HDR10 static metadata on the software route: the mastering display (ST 2086) and content light
/// level (CTA-861.3) the stream declares reach the display buffer as the CoreVideo attachments, in
/// the big-endian SEI payload form CoreVideo defines for them. Before, `attachColorSpace` wrote the
/// three colour tags and nothing else, so an HDR10 grade decoded in software lost its peak.
@Suite("HDR10 static metadata attachments")
struct HDRStaticMetadataTests {

    /// x265 `master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50)`
    /// and `max-cll=1000,400`, i.e. P3-D65 primaries, 1000 / 0.005 cd/m², written in the exact SEI
    /// layout: G, B, R, white point (u16 each), max then min luminance (u32 each), big-endian.
    static let expectedMDCV: [UInt8] = [
        0x33, 0xC2, 0x86, 0xC4,   // G 13250, 34500
        0x1D, 0x4C, 0x0B, 0xB8,   // B 7500, 3000
        0x84, 0xD0, 0x3E, 0x80,   // R 34000, 16000
        0x3D, 0x13, 0x40, 0x42,   // WP 15635, 16450
        0x00, 0x98, 0x96, 0x80,   // max 10000000
        0x00, 0x00, 0x00, 0x32,   // min 50
    ]
    static let expectedCLL: [UInt8] = [0x03, 0xE8, 0x01, 0x90]  // MaxCLL 1000, MaxFALL 400

    // MARK: - The encoding

    @Test("FFmpeg's R, G, B rationals become the SEI's G, B, R words")
    func masteringDisplayEncoding() throws {
        var m = AVMasteringDisplayMetadata()
        m.display_primaries = ((AVRational(num: 34000, den: 50000), AVRational(num: 16000, den: 50000)),
                               (AVRational(num: 13250, den: 50000), AVRational(num: 34500, den: 50000)),
                               (AVRational(num: 7500, den: 50000), AVRational(num: 3000, den: 50000)))
        m.white_point = (AVRational(num: 15635, den: 50000), AVRational(num: 16450, den: 50000))
        m.max_luminance = AVRational(num: 10000000, den: 10000)
        m.min_luminance = AVRational(num: 50, den: 10000)
        m.has_primaries = 1
        m.has_luminance = 1
        let payload = try #require(HDRStaticMetadata.masteringDisplayPayload(m))
        #expect([UInt8](payload) == Self.expectedMDCV)
    }

    @Test("half a mastering display is no mastering display")
    func incompleteMasteringDisplayIsDropped() {
        var m = AVMasteringDisplayMetadata()
        m.max_luminance = AVRational(num: 1000, den: 1)
        m.min_luminance = AVRational(num: 1, den: 10000)
        m.has_luminance = 1
        #expect(HDRStaticMetadata.masteringDisplayPayload(m) == nil)
    }

    @Test("content light level is MaxCLL then MaxFALL; an all-zero pair says nothing")
    func contentLightLevelEncoding() {
        let cll = HDRStaticMetadata.contentLightLevelPayload(AVContentLightMetadata(MaxCLL: 1000, MaxFALL: 400))
        #expect(cll.map { [UInt8]($0) } == Self.expectedCLL)
        #expect(HDRStaticMetadata.contentLightLevelPayload(AVContentLightMetadata(MaxCLL: 0, MaxFALL: 0)) == nil)
    }

    /// 314 lux under D65, the H.274 example for a dim reference room.
    @Test("ambient viewing environment is u32 illuminance in 0.0001 lux, then x / y in 0.00002, big-endian")
    func ambientViewingEnvironmentEncoding() throws {
        let ambient = AVAmbientViewingEnvironment(
            ambient_illuminance: AVRational(num: 314, den: 1),
            ambient_light_x: AVRational(num: 15635, den: 50000),
            ambient_light_y: AVRational(num: 16450, den: 50000))
        let payload = try #require(HDRStaticMetadata.ambientViewingEnvironmentPayload(ambient))
        #expect([UInt8](payload) == [0x00, 0x2F, 0xE9, 0xA0, 0x3D, 0x13, 0x40, 0x42])
    }

    @Test("ambient viewing environment reaches the buffer and the format description, and is cleared when absent")
    @MainActor
    func ambientViewingEnvironmentAttachment() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &pb)
        let buffer = try #require(pb)
        let bytes: [UInt8] = [0x00, 0x2F, 0xE9, 0xA0, 0x3D, 0x13, 0x40, 0x42]
        HDRStaticMetadata(ambientViewingEnvironment: Data(bytes) as NSData).attach(to: buffer)
        #expect(attachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey) == bytes)
        let sample = try #require(SampleBufferRenderer().createSampleBuffer(from: buffer, pts: .zero))
        let desc = try #require(CMSampleBufferGetFormatDescription(sample))
        let ext = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_AmbientViewingEnvironment)
        #expect((ext as? Data).map { [UInt8]($0) } == bytes)
        HDRStaticMetadata.none.attach(to: buffer)
        #expect(attachment(buffer, kCVImageBufferAmbientViewingEnvironmentKey) == nil)
    }

    @Test("the container's declaration is read off codecpar, the hardware decoder's only source")
    func containerDeclarationFromCodecpar() throws {
        let data = try #require(Data(base64Encoded: Self.vp9ContainerHDR10Base64, options: .ignoreUnknownCharacters))
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "matroska")
        defer { demuxer.close() }
        let codecpar = try #require(demuxer.stream(at: demuxer.videoStreamIndex)?.pointee.codecpar)
        let declared = HDRStaticMetadata(codecpar: codecpar)
        #expect(declared.masteringDisplay.map { [UInt8]($0 as Data) } == Self.expectedMDCV)
        #expect(declared.contentLightLevel.map { [UInt8]($0 as Data) } == Self.expectedCLL)
    }

    /// VideoToolbox output: what VT attached from the bitstream's SEI stays, the container fills the rest.
    @Test("attachWhereAbsent keeps an attachment the buffer already has and fills a missing one")
    func whereAbsentKeepsTheDecodersOwn() throws {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, nil, &pb)
        let buffer = try #require(pb)
        let own: [UInt8] = [0x00, 0x64, 0x00, 0x32]
        CVBufferSetAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, Data(own) as CFData, .shouldPropagate)
        let container = HDRStaticMetadata(masteringDisplay: Data(Self.expectedMDCV) as NSData,
                                          contentLightLevel: Data(Self.expectedCLL) as NSData)
        container.attachWhereAbsent(to: buffer)
        #expect(attachment(buffer, kCVImageBufferContentLightLevelInfoKey) == own)
        #expect(attachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) == Self.expectedMDCV)
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
        decoder.awaitDelivered()
        return try #require(box.first, "the fixture must decode to at least one frame")
    }

    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func keepFirst(_ candidate: CVPixelBuffer) { lock.withLock { if buffer == nil { buffer = candidate } } }
        var first: CVPixelBuffer? { lock.withLock { buffer } }
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> [UInt8]? {
        (CVBufferCopyAttachment(buffer, key, nil) as? Data).map { [UInt8]($0) }
    }

    @Test("an x265 HDR10 stream decoded in software carries its SEI's mastering display and MaxCLL")
    func hevcSEIReachesTheBuffer() throws {
        let buffer = try firstPixelBuffer(base64: Self.hevcHDR10Base64, formatHint: "mp4")
        #expect(attachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) == Self.expectedMDCV)
        #expect(attachment(buffer, kCVImageBufferContentLightLevelInfoKey) == Self.expectedCLL)
    }

    /// VP9 has no SEI: Matroska's MasteringMetadata element (floats) is the only declaration.
    @Test("a container-only declaration (VP9 in Matroska) reaches the buffer as the same bytes")
    func containerDeclarationReachesTheBuffer() throws {
        let buffer = try firstPixelBuffer(base64: Self.vp9ContainerHDR10Base64, formatHint: "matroska")
        #expect(attachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey) == Self.expectedMDCV)
        #expect(attachment(buffer, kCVImageBufferContentLightLevelInfoKey) == Self.expectedCLL)
    }

    @Test("the format description built from the buffer carries both as extensions")
    @MainActor
    func formatDescriptionCarriesThem() throws {
        let buffer = try firstPixelBuffer(base64: Self.hevcHDR10Base64, formatHint: "mp4")
        let sample = try #require(SampleBufferRenderer().createSampleBuffer(
            from: buffer, pts: CMTime(value: 0, timescale: 90000)))
        let desc = try #require(CMSampleBufferGetFormatDescription(sample))
        let mdcv = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume)
        let cll = CMFormatDescriptionGetExtension(desc, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo)
        #expect((mdcv as? Data).map { [UInt8]($0) } == Self.expectedMDCV)
        #expect((cll as? Data).map { [UInt8]($0) } == Self.expectedCLL)
    }

    /// The renderer caches its format description on a key read off the buffer. Without the HDR
    /// attachments in that key, a stream whose metadata arrives (or changes) after the first frame
    /// keeps the description built before it.
    @Test("a change in the static metadata alone builds a new format description")
    @MainActor
    func formatDescriptionCacheKeysOnTheMetadata() throws {
        func buffer(_ cll: [UInt8]?) -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                [kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()] as NSDictionary, &pb)
            if let cll {
                CVBufferSetAttachment(pb!, kCVImageBufferContentLightLevelInfoKey, Data(cll) as CFData, .shouldPropagate)
            }
            return pb!
        }
        let renderer = SampleBufferRenderer()
        let first = try #require(renderer.createSampleBuffer(from: buffer(nil), pts: .zero))
        let second = try #require(renderer.createSampleBuffer(from: buffer(Self.expectedCLL), pts: .zero))
        let firstDesc = try #require(CMSampleBufferGetFormatDescription(first))
        let secondDesc = try #require(CMSampleBufferGetFormatDescription(second))
        #expect(CMFormatDescriptionGetExtension(firstDesc, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) == nil)
        let cll = CMFormatDescriptionGetExtension(secondDesc, extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo)
        #expect((cll as? Data).map { [UInt8]($0) } == Self.expectedCLL)
    }

    /// 64x64 10-bit, 3 frames. Regenerate:
    ///   ffmpeg -f lavfi -i "color=c=0x808080:s=64x64:r=10:d=0.3" -vf format=yuv420p10le -c:v libx265 \
    ///     -preset ultrafast -x265-params "log-level=error:info=0:hdr10=1:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,50):max-cll=1000,400:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
    ///     -tag:v hvc1 -map_metadata -1 -fflags +bitexact -flags:v +bitexact hdr10.mp4
    static let hevcHDR10Base64 = """
        AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAX21kYXQAAAAJTgGQBAPoAZCAAAAAHk4BiRgzwobEHUwLuITQ
        PoA9E0BCAJiWgAAAAwAygAAAAAooAaxGAv/AMkX4AAAACQIB0BFWIISgxAAAAAkAAeAkvggznLwAAAPEbW9vdgAAAGxtdmhkAAAA
        AAAAAAAAAAAAAAAD6AAAASwAAQAAAQAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAgAAAxN0cmFrAAAAXHRraGQAAAADAAAAAAAAAAAAAAABAAAAAAAAASwAAAAAAAAAAAAAAAAA
        AAAAAAEAAAAAAAAAAAAAAAAAAAABAAAAAAAAAAAAAAAAAABAAAAAAEAAAABAAAAAAAAkZWR0cwAAABxlbHN0AAAAAAAAAAEAAAEs
        AAAIAAABAAAAAAKLbWRpYQAAACBtZGhkAAAAAAAAAAAAAAAAAAAoAAAADABVxAAAAAAALWhkbHIAAAAAAAAAAHZpZGUAAAAAAAAA
        AAAAAABWaWRlb0hhbmRsZXIAAAACNm1pbmYAAAAUdm1oZAAAAAEAAAAAAAAAAAAAACRkaW5mAAAAHGRyZWYAAAAAAAAAAQAAAAx1
        cmwgAAAAAQAAAfZzdGJsAAABO3N0c2QAAAAAAAAAAQAAAStodmMxAAAAAAAAAAEAAAAAAAAAAAAAAAAAAAAAAEAAQABIAAAASAAA
        AAAAAAABDExhdmMgbGlieDI2NQAAAAAAAAAAAAAAAAAAAAAAAAAAGP//AAAAp2h2Y0MBAiAAAACQAAAAAAAe8AD8/fr6AAAPBKAA
        AQAYQAEMAf//AiAAAAMAkAAAAwAAAwAelZQJoQABAC1CAQECIAAAAwCQAAADAAADAB6gIIEE2WVlSkwvAWoSIBIIAAADAAgAAAMA
        UECiAAEABkQBwHPAiScAAgAJTgGQBAPoAZCAAB5OAYkYM8KGxB1MC7iE0D6APRNAQgCYloAAAAMAMoAAAAAKZmllbAEAAAAAEHBh
        c3AAAAABAAAAAQAAABRidHJ0AAAAAAAACRAAAAAAAAAAGHN0dHMAAAAAAAAAAQAAAAMAAAQAAAAAFHN0c3MAAAAAAAAAAQAAAAEA
        AAAPc2R0cAAAAAAgEBgAAAAoY3R0cwAAAAAAAAADAAAAAQAACAAAAAABAAAMAAAAAAEAAAQAAAAAHHN0c2MAAAAAAAAAAQAAAAEA
        AAADAAAAAQAAACBzdHN6AAAAAAAAAAAAAAADAAAAPQAAAA0AAAANAAAAFHN0Y28AAAAAAAAAAQAAACwAAAA9dWR0YQAAADVtZXRh
        AAAAAAAAACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAAhpbHN0
        """

    /// The same picture re-encoded to 10-bit VP9 in Matroska; ffmpeg carries the decoded side data to
    /// the muxer, which writes it as Colour/MasteringMetadata. Regenerate from hdr10.mp4 above:
    ///   ffmpeg -i hdr10.mp4 -c:v libvpx-vp9 -pix_fmt yuv420p10le -profile:v 2 -b:v 50k -deadline realtime \
    ///     -cpu-used 8 -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -map_metadata -1 \
    ///     -fflags +bitexact -flags:v +bitexact vp9hdr.mkv
    static let vp9ContainerHDR10Base64 = """
        GkXfo6NChoEBQveBAULygQRC84EIQoKIbWF0cm9za2FCh4EEQoWBAhhTgGcBAAAAAAACdRFNm3TAv4Sa0XTgTbuLU6uEFUmpZlOs
        gaFNu4tTq4QWVK5rU6yBzE27jFOrhBJUw2dTrIIBvU27jFOrhBxTu2tTrIICWewBAAAAAAAAUwAAAAAAAAAAAAAAAAAAAAAAAAAA
        AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAFUmpZqa/hEm2L/Iq
        17GDD0JATYCETGF2ZldBhExhdmZEiYhAWQAAAAAAABZUrmtA67+Ei3A5Mq4BAAAAAAAA3NeBAXPFiAAAAAAAAAABnIEAIrWcg3Vu
        ZIaFVl9WUDmDgQEj44OEBfXhAOBAoLCBQLqBQJqBAlWwQJNVuoEQVbGBCVW7gQlVuYEBVbeBAVW4gQJVvIID6FW9ggGQVdDuVdGI
        P+XCj1wo9cNV0og/1HrhR64Ue1XTiD/Q9cKPXCj2VdSIP+YUeuFHrhRV1Yg/wzMzMzMzM1XWiD+uuFHrhR64VdeIP9QDRtxdY4hV
        2Ig/1Q5WBBiTdVXZiECPQAAAAAAAVdqIP3R64UeuFHtV7oEA7AEAAAAAAAACAAASVMNn2r+ESXg3zHNz0WPAi2PFiAAAAAAAAAAB
        Z8icRaOHRU5DT0RFUkSHj0xhdmMgbGlidnB4LXZwOWfIoUWjiERVUkFUSU9ORIeTMDA6MDA6MDAuMTAwMDAwMDAwAB9DtnW4v4T6
        2TiJ54EAo62BAACAkkmDQlAB+AH7AxwSDgwpAAAQQABsWV6s9nwhRwnjzEPA/QR0MQAAcgAcU7trl7+EBDn/ZbuPs4EAt4r3gQHx
        ggIc8IEJ
        """
}
