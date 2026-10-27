import CoreVideo
import Testing
import AetherLibavutil
@testable import AetherEngine

struct ColorAttachmentsTests {

    private func described(
        _ primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
        _ transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
        _ matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED
    ) -> ColorDescription {
        ColorDescription(primaries: primaries, transfer: transfer, matrix: matrix, range: AVCOL_RANGE_MPEG)
    }

    /// The VideoToolbox answer, kept for a caller that passes no frame size (a still that has to match
    /// a hardware-decoded playback). The software decoder passes its frame size since #6, below.
    @Test("AE#654: without a frame size an untagged stream is presented as BT.709 in all three, as VideoToolbox does")
    func untaggedIsBT709() {
        let tags = ColorAttachments.presented(.unspecified)
        #expect(tags == ColorAttachments.Tags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
    }

    @Test("#6: an untagged NTSC-sized picture is BT.601 with SMPTE-C primaries and the BT.709 curve",
          arguments: [(Int32(720), Int32(480)), (720, 486), (704, 480), (352, 240), (640, 480)])
    func untaggedNTSCIsBT601(width: Int32, height: Int32) {
        let tags = ColorAttachments.presented(.unspecified, frameSize: (width, height))
        #expect(tags == ColorAttachments.Tags(
            primaries: kCVImageBufferColorPrimaries_SMPTE_C,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4))
    }

    @Test("#6: an untagged 625-line picture is BT.601 with EBU 3213 primaries",
          arguments: [(Int32(720), Int32(576)), (704, 576), (352, 288)])
    func untaggedPALIsBT601EBU(width: Int32, height: Int32) {
        let tags = ColorAttachments.presented(.unspecified, frameSize: (width, height))
        #expect(tags.primaries == kCVImageBufferColorPrimaries_EBU_3213)
        #expect(tags.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(tags.transfer == kCVImageBufferTransferFunction_ITU_R_709_2)
    }

    @Test("#6: an untagged HD picture stays BT.709, including a 1280-wide scope crop no taller than SD",
          arguments: [(Int32(1280), Int32(720)), (1920, 1080), (1280, 544), (1024, 768), (3840, 2160)])
    func untaggedHDStaysBT709(width: Int32, height: Int32) {
        let tags = ColorAttachments.presented(.unspecified, frameSize: (width, height))
        #expect(tags.primaries == kCVImageBufferColorPrimaries_ITU_R_709_2)
        #expect(tags.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
    }

    @Test("#6: the size guess only fills a picture that declares neither matrix nor primaries")
    func sizeGuessNeverOverridesADeclaration() {
        let sd = (Int32(720), Int32(480))
        let bt709Matrix = ColorAttachments.presented(described(AVCOL_PRI_UNSPECIFIED, AVCOL_TRC_UNSPECIFIED, AVCOL_SPC_BT709),
                                                     frameSize: sd)
        #expect(bt709Matrix.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        #expect(bt709Matrix.primaries == kCVImageBufferColorPrimaries_ITU_R_709_2)
        let bt709Primaries = ColorAttachments.presented(described(AVCOL_PRI_BT709), frameSize: sd)
        #expect(bt709Primaries.matrix == kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let pq = ColorAttachments.presented(described(AVCOL_PRI_UNSPECIFIED, AVCOL_TRC_SMPTE2084), frameSize: sd)
        #expect(pq.transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, "a declared curve is kept")
    }

    @Test("a pure power curve is UseGamma with its exponent, and a still can be made from it")
    func gammaCurves() throws {
        let g22 = ColorAttachments.presented(described(AVCOL_PRI_BT470BG, AVCOL_TRC_GAMMA22, AVCOL_SPC_BT470BG))
        #expect(g22.transfer == kCVImageBufferTransferFunction_UseGamma)
        #expect(g22.gammaLevel == 2.2)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT470BG, AVCOL_TRC_GAMMA28)).gammaLevel == 2.8)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT709, AVCOL_TRC_BT709)).gammaLevel == nil)
        #expect(ColorAttachments.colorSpace(for: g22) != nil)
    }

    @Test("code points CoreVideo has a constant for are mapped: EBU 3213 (22) is P22, SMPTE 428 has its curve")
    func newlyMappedCodePoints() {
        #expect(ColorAttachments.primaries(AVCOL_PRI_EBU3213) == kCVImageBufferColorPrimaries_P22)
        #expect(ColorAttachments.transfer(AVCOL_TRC_SMPTE428) == kCVImageBufferTransferFunction_SMPTE_ST_428_1)
    }

    @Test("what CoreVideo cannot carry is named, and only that")
    func unmappedIsNamed() {
        #expect(ColorAttachments.unmapped(described(AVCOL_PRI_BT470M)) == "primaries BT.470M")
        #expect(ColorAttachments.unmapped(described(AVCOL_PRI_FILM))?.contains("FILM") == true)
        #expect(ColorAttachments.unmapped(described(AVCOL_PRI_SMPTE428))?.contains("XYZ") == true)
        #expect(ColorAttachments.unmapped(described(AVCOL_PRI_BT2020, AVCOL_TRC_BT2020_10, AVCOL_SPC_BT2020_CL))?
            .contains("constant-luminance") == true)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT2020, AVCOL_TRC_BT2020_10, AVCOL_SPC_BT2020_CL)).matrix
                == kCVImageBufferYCbCrMatrix_ITU_R_2020)
        #expect(ColorAttachments.unmapped(described(AVCOL_PRI_BT709, AVCOL_TRC_BT709, AVCOL_SPC_BT709)) == nil)
        #expect(ColorAttachments.unmapped(.unspecified) == nil)
    }

    @Test("AE#654: a lone BT.601 matrix gets SMPTE-C primaries, as VideoToolbox fills it")
    func bt601MatrixImpliesSMPTEC() {
        let tags = ColorAttachments.presented(described(AVCOL_PRI_UNSPECIFIED, AVCOL_TRC_UNSPECIFIED, AVCOL_SPC_SMPTE170M))
        #expect(tags.primaries == kCVImageBufferColorPrimaries_SMPTE_C)
        #expect(tags.transfer == kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(tags.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    }

    @Test("AE#654: SD primaries without a matrix get the BT.601 matrix, not BT.709")
    func sdPrimariesImplyBT601Matrix() {
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT470BG)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_SMPTE170M)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        #expect(ColorAttachments.presented(described(AVCOL_PRI_BT2020)).matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020)
    }

    @Test("AE#654: a tagged SD stream keeps its tags; before, none of them had a CoreVideo mapping")
    func taggedSDIsNotGuessed() {
        let pal = ColorAttachments.presented(described(AVCOL_PRI_BT470BG, AVCOL_TRC_SMPTE170M, AVCOL_SPC_BT470BG))
        #expect(pal.primaries == kCVImageBufferColorPrimaries_EBU_3213)
        #expect(pal.transfer == kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(pal.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4)
    }

    @Test("AE#654: a declared HDR description passes through untouched")
    func hdrUntouched() {
        let tags = ColorAttachments.presented(described(AVCOL_PRI_BT2020, AVCOL_TRC_SMPTE2084, AVCOL_SPC_BT2020_NCL))
        #expect(tags == ColorAttachments.Tags(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020))
    }

    @Test("A still's colour space is the one CoreVideo manages the displayed buffer in")
    func stillColorSpaceFollowsPlayback() throws {
        let untagged = try #require(ColorAttachments.colorSpace(for: ColorAttachments.presented(.unspecified)))
        #expect(untagged.name as String? == "kCGColorSpaceCoreMedia709")
        let sd = ColorAttachments.presented(described(AVCOL_PRI_SMPTE170M, AVCOL_TRC_SMPTE170M, AVCOL_SPC_SMPTE170M))
        let sdSpace = try #require(ColorAttachments.colorSpace(for: sd))
        #expect(sdSpace != untagged)
        let sdr2020 = ColorAttachments.presented(described(AVCOL_PRI_BT2020, AVCOL_TRC_BT2020_10, AVCOL_SPC_BT2020_NCL))
        #expect(ColorAttachments.colorSpace(for: sdr2020) != nil)
    }
}
