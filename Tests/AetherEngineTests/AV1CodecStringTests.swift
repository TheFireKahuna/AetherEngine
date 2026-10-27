import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The plain-AV1 CODECS string, built from the av1C the init carries instead of guessed.
///
/// The route used to format `av01.P.LLM.DD.0.111.cp.tc.mc.0` with the tier always Main, chroma
/// `111` (4:2:0, vertical sample position) and full range `0` hard-coded, and the colour triplet
/// picked from the transfer alone: anything not PQ / HLG was declared `01.01.01`, a BT.601 or a
/// BT.2020 SDR encode included. Every fixture below is a real av1C (SVT-AV1 4.2.0 through ffmpeg,
/// 320x180), and every expected string is the one `MP4Box -info` prints for that file.
@Suite("AV1 RFC 6381 codecs string")
struct AV1CodecStringTests {

    /// 8-bit 4:2:0, BT.709 / BT.709 / BT.709, limited range, chroma position unknown.
    static let av1C709: [UInt8] = [
        0x81, 0x00, 0x0c, 0x00, 0x0a, 0x0e, 0x02, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc0, 0x80, 0x80, 0x80, 0x82,
    ]
    /// 10-bit 4:2:0, BT.2020 / PQ / BT.2020-NCL, limited range, colocated chroma (`112`).
    static let av1CPQ: [UInt8] = [
        0x81, 0x00, 0x4e, 0x00, 0x0a, 0x0e, 0x02, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc2, 0x84, 0x88, 0x04, 0xa2,
    ]
    /// 8-bit 4:2:0, BT.601 (6 / 6 / 6), FULL range, vertical chroma (`111`).
    static let av1C601Full: [UInt8] = [
        0x81, 0x00, 0x0d, 0x00, 0x0a, 0x0e, 0x02, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc0, 0x83, 0x03, 0x03, 0x52,
    ]
    /// 8-bit 4:2:0 whose sequence header states no colour description at all.
    static let av1CNoColour: [UInt8] = [
        0x81, 0x00, 0x0c, 0x00, 0x0a, 0x0b, 0x02, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc0, 0x02,
    ]
    /// ffmpeg's libsvtav1 wrapper forwarded only the matrix: the sequence header describes 2 / 2 / 1.
    static let av1CPartial: [UInt8] = [
        0x81, 0x00, 0x0c, 0x00, 0x0a, 0x0e, 0x02, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc0, 0x81, 0x01, 0x00, 0x82,
    ]
    /// Profile 1 (High), 8-bit 4:4:4, BT.709. No brew encoder emits 4:4:4 AV1, so this is the 709
    /// record rewritten field by field per AV1 §5.5.2 (seq_profile 1, no mono_chrome bit, no
    /// chroma_sample_position); MP4Box reads the patched file as `av01.1.00M.08.0.000.01.01.01.0`.
    static let av1C444: [UInt8] = [
        0x81, 0x20, 0x00, 0x00, 0x0a, 0x0e, 0x22, 0x00, 0x00, 0x05,
        0x61, 0xe7, 0xf6, 0x60, 0x17, 0xc1, 0x01, 0x01, 0x01, 0x10,
    ]

    @Test("8-bit BT.709 reads its own sequence header")
    func bt709() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: Self.av1C709)
                == "av01.0.00M.08.0.110.01.01.01.0")
    }

    @Test("10-bit PQ BT.2020 states its chroma position and depth")
    func pq2020() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: Self.av1CPQ)
                == "av01.0.00M.10.0.112.09.16.09.0")
    }

    @Test("BT.601 full range is not declared BT.709 limited")
    func bt601FullRange() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: Self.av1C601Full)
                == "av01.0.00M.08.0.111.06.06.06.1")
    }

    @Test("4:4:4 profile 1 declares 000 chroma")
    func fourFourFour() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: Self.av1C444)
                == "av01.1.00M.08.0.000.01.01.01.0")
    }

    @Test("a sequence header's own description outranks the container")
    func sequenceHeaderWins() {
        #expect(HLSVideoEngine.av1CodecsString(
            fromConfigRecord: Self.av1CPartial,
            primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709)
                == "av01.0.00M.08.0.110.02.02.01.0")
    }

    @Test("no colour description anywhere is the short form, as MP4Box prints it")
    func noColourIsShortForm() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: Self.av1CNoColour) == "av01.0.00M.08")
    }

    @Test("no description in the sequence header falls back to the container's colour")
    func containerFallback() {
        #expect(HLSVideoEngine.av1CodecsString(
            fromConfigRecord: Self.av1CNoColour,
            primaries: AVCOL_PRI_BT2020, transfer: AVCOL_TRC_ARIB_STD_B67, matrix: AVCOL_SPC_BT2020_NCL,
            range: AVCOL_RANGE_JPEG)
                // The range bit is the sequence header's (limited), not the container's.
                == "av01.0.00M.08.0.110.09.18.09.0")
    }

    @Test("tier and level come from the record")
    func tierAndLevel() {
        var record = Self.av1CPQ
        record[1] = (0 << 5) | 13      // seq_level_idx_0 13 = level 5.1
        record[2] |= 0x80              // seq_tier_0 = High
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: record)
                == "av01.0.13H.10.0.112.09.16.09.0")
    }

    @Test("not an av1C is nil")
    func rejectsNonRecord() {
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: [0x01, 0x00, 0x0c]) == nil)
        #expect(HLSVideoEngine.av1CodecsString(fromConfigRecord: [0x00, 0x00, 0x0c, 0x00]) == nil)
    }

    // MARK: - The route

    private static func route(av1C: [UInt8]?, trc: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
                              primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
                              matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED) throws -> HLSVideoEngine.CodecRoute {
        var p: UnsafeMutablePointer<AVCodecParameters>? = avcodec_parameters_alloc()
        defer { avcodec_parameters_free(&p) }
        let par = p!
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_AV1
        par.pointee.width = 320
        par.pointee.height = 180
        par.pointee.profile = 0
        par.pointee.level = 8
        par.pointee.color_trc = trc
        par.pointee.color_primaries = primaries
        par.pointee.color_space = matrix
        if let av1C {
            let extra = av_mallocz(av1C.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))!
            av1C.withUnsafeBytes { _ = memcpy(extra, $0.baseAddress!, av1C.count) }
            par.pointee.extradata = extra.assumingMemoryBound(to: UInt8.self)
            par.pointee.extradata_size = Int32(av1C.count)
        }
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/dev/null"), dvModeAvailable: false)
        return try engine.resolveCodecRoute(codecpar: UnsafePointer(par))
    }

    @Test("the plain av01 route declares what the av1C states")
    func routeUsesRecord() throws {
        let r = try Self.route(av1C: Self.av1C601Full, trc: AVCOL_TRC_SMPTE170M,
                               primaries: AVCOL_PRI_SMPTE170M, matrix: AVCOL_SPC_SMPTE170M)
        #expect(r.codecTagOverride == "av01")
        #expect(r.videoRange == .sdr)
        #expect(r.primaryCodecs == "av01.0.00M.08.0.111.06.06.06.1")
    }

    @Test("without an av1C the codecpar colour is stated, not picked from the transfer")
    func routeFallbackUsesCodecparColour() throws {
        // BT.2020 SDR (transfer BT.2020-10): the old branch declared it 01.01.01.
        let r = try Self.route(av1C: nil, trc: AVCOL_TRC_BT2020_10,
                               primaries: AVCOL_PRI_BT2020, matrix: AVCOL_SPC_BT2020_NCL)
        #expect(r.videoRange == .sdr)
        #expect(r.primaryCodecs == "av01.0.08M.08.0.110.09.14.09.0")
    }
}
