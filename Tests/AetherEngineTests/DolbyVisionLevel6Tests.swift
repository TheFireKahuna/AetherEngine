import Testing
import CoreVideo
import Foundation
import AetherLibavcodec
import AetherLibavutil
import Dovi
@testable import AetherEngine

/// A picture composed from a Profile 7 FEL is the master, so its HDR10 static metadata is the RPU's L6, not the base
/// layer's grade. John Wick's values (research/colour-range-dv, section 6.1): master 0.005 / 4000 nits, MaxCLL 1355 /
/// MaxFALL 332; base layer SEI 0.0001 / 1000 nits.
@Suite("Composed FEL frames state the master's HDR10 metadata")
struct DolbyVisionLevel6Tests {

    static let johnWick = DolbyVisionLevel6(minLuminance: 50, maxLuminance: 4000,
                                            maxContentLightLevel: 1355, maxFrameAverageLightLevel: 332)

    /// The base layer's SEI: x265's `master-display` G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450),
    /// 1000 / 0.0001 nits, and MaxCLL 1000 / MaxFALL 400.
    static var baseLayer: HDRStaticMetadata {
        HDRStaticMetadata(masteringDisplay: Data(InBandHDRStaticMetadataTests.expectedMDCV) as NSData,
                          contentLightLevel: Data([0x03, 0xe8, 0x01, 0x90]) as NSData)
    }

    static func be32(_ d: Data, _ at: Int) -> UInt32 { d[at..<(at + 4)].reduce(0) { $0 << 8 | UInt32($1) } }

    @Test("L6 is read from a real Profile 7 RPU")
    func readsFromRPU() throws {
        let nal = DoviComposedFrameRpuTests.felNAL
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) })
        defer { dovi_rpu_free(rpu) }
        // dovi_tool's fel_orig: L6 0.0001 / 1000 nits, MaxCLL 1712, MaxFALL 175.
        #expect(DolbyVisionLevel6(rpu: rpu) == DolbyVisionLevel6(minLuminance: 1, maxLuminance: 1000,
                                                               maxContentLightLevel: 1712, maxFrameAverageLightLevel: 175))
    }

    @Test("the master's luminance and light level, the stream's primaries")
    func describesMaster() throws {
        let out = Self.johnWick.describingMaster(Self.baseLayer)
        let md = try #require(out.masteringDisplay as Data?)
        #expect(md.prefix(16) == Data(InBandHDRStaticMetadataTests.expectedMDCV).prefix(16))
        #expect(Self.be32(md, 16) == 4000 * 10000)   // max, 0.0001 cd/m2 units
        #expect(Self.be32(md, 20) == 50)             // min: 0.005 nit, the master's black
        #expect(out.contentLightLevel as Data? == Data([0x05, 0x4b, 0x01, 0x4c]))   // 1355 / 332
    }

    @Test("a light level L6 leaves unknown is reported unknown, not as the base layer's")
    func unknownLightLevel() {
        var l6 = Self.johnWick
        l6.maxContentLightLevel = 0
        l6.maxFrameAverageLightLevel = 0
        #expect(l6.describingMaster(Self.baseLayer).contentLightLevel == nil)
    }

    @Test("a luminance L6 does not state keeps the stream's; no stream primaries, no mastering display")
    func incompleteLevel6() {
        var l6 = Self.johnWick
        l6.maxLuminance = 0
        #expect(l6.describingMaster(Self.baseLayer).masteringDisplay == Self.baseLayer.masteringDisplay)
        l6 = Self.johnWick
        l6.minLuminance = UInt16.max
        l6.maxLuminance = 1
        #expect(l6.describingMaster(Self.baseLayer).masteringDisplay == Self.baseLayer.masteringDisplay)
        #expect(Self.johnWick.describingMaster(HDRStaticMetadata()).masteringDisplay == nil)
    }

    @Test("the init's codec parameters get the same rewrite")
    func codecParameters() throws {
        var p: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&p) }
        let par = try #require(p)
        let lifted = InBandHDRStaticMetadataTests.collect(
            InBandHDRStaticMetadataTests.annexB([InBandHDRStaticMetadataTests.hevcCLL, InBandHDRStaticMetadataTests.hevcMDCV]),
            codecID: AV_CODEC_ID_HEVC, framing: .annexB)
        lifted.attach(to: par)
        #expect(Self.johnWick.describeMaster(on: par) == ["mdcv luminance 0.005 / 4000 nits", "clli 1355 / 332"])
        let stated = HDRStaticMetadata(codecpar: UnsafePointer(par))
        let md = try #require(stated.masteringDisplay as Data?)
        #expect(Self.be32(md, 16) == 4000 * 10000)
        #expect(Self.be32(md, 20) == 50)
        #expect(stated.contentLightLevel as Data? == Data([0x05, 0x4b, 0x01, 0x4c]))

        var unknown = Self.johnWick
        unknown.maxContentLightLevel = 0
        unknown.maxFrameAverageLightLevel = 0
        #expect(unknown.describeMaster(on: par).contains("clli removed (L6 states it unknown)"))
        #expect(HDRStaticMetadata(codecpar: UnsafePointer(par)).contentLightLevel == nil)
    }
}

extension DolbyVisionLevel6Tests {
    @Test("the head scan's collector reads John Wick's L6 from its own packets",
          .enabled(if: DoviFelRealFileTests.available(DoviFelRealFileTests.fixtures[0]), DoviFelRealFileTests.needsClips))
    func johnWickFromPackets() throws {
        // `fel-clip-a.mkv` is a John Wick slice (research/colour-range-dv, tools/fetch_slices.sh, remuxed).
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(url: DoviFelRealFileTests.url(DoviFelRealFileTests.fixtures[0]))
        var m = InBandHDRStaticMetadata()
        for _ in 0..<32 where m.dolbyVisionBaseLayerFullRange == nil {
            guard let pkt = try demuxer.readPacket() else { break }
            var owned: UnsafeMutablePointer<AVPacket>? = pkt
            defer { trackedPacketFree(&owned) }
            guard pkt.pointee.stream_index == demuxer.videoStreamIndex, let data = pkt.pointee.data else { continue }
            m.collectDolbyVisionRPU(from: data, size: Int(pkt.pointee.size), framing: .lengthPrefixed(size: 4))
        }
        #expect(m.dolbyVisionBaseLayerFullRange == false)
        #expect(m.dolbyVisionLevel6 == Self.johnWick)
    }
}

#if DualLayerDolbyVision
import Metal

extension DolbyVisionLevel6Tests {

    static func baseBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 256, 256, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        guard let out else { return nil }
        baseLayer.attach(to: out)
        return out
    }

    static func enhancementBuffer() -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 128, 128, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferMetalCompatibilityKey: true,
                             kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary, &out)
        return out
    }

    @Test("a composed frame carries the master's mastering display and light level, not the base layer's",
          .enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    func composedFrameStatesTheMaster() throws {
        let composer = try #require(DoviFelComposer.p010ForTesting())
        let bl = try #require(Self.baseBuffer()), el = try #require(Self.enhancementBuffer())
        var params = DoviMetalParams()
        params.blWidth = 256; params.blHeight = 256; params.elWidth = 128; params.elHeight = 128

        let plain = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 1))
        #expect(HDRStaticMetadata(buffer: plain) == Self.baseLayer)   // no L6: the base layer's, as propagated

        params.masterLevel6 = Self.johnWick
        let composed = try #require(composer.compose(baseBuffer: bl, enhancementBuffer: el, params: params, frameIndex: 2))
        #expect(HDRStaticMetadata(buffer: composed) == Self.johnWick.describingMaster(Self.baseLayer))
        let md = try #require(HDRStaticMetadata(buffer: composed).masteringDisplay as Data?)
        #expect(Self.be32(md, 20) == 50)
    }

    @Test("parseRpuParameters carries the RPU's L6 to the composer")
    func parametersCarryLevel6() throws {
        let nal = DoviComposedFrameRpuTests.felNAL
        let rpu = try #require(nal.withUnsafeBufferPointer { DoviRpuGuard.parse($0.baseAddress!, $0.count) })
        defer { dovi_rpu_free(rpu) }
        let params = try #require(DoviFelComposer.parseRpuParameters(rpu: rpu))
        #expect(params.masterLevel6?.maxContentLightLevel == 1712)
    }
}
#endif
