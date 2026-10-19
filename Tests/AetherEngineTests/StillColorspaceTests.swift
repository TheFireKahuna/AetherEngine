import Testing
import AetherLibavutil
import AetherLibswscale
@testable import AetherEngine

struct StillColorspaceTests {

    private func described(_ primaries: AVColorPrimaries, _ matrix: AVColorSpace) -> ColorDescription {
        ColorDescription(primaries: primaries, transfer: AVCOL_TRC_UNSPECIFIED, matrix: matrix, range: AVCOL_RANGE_MPEG)
    }

    @Test("A BT.709 still is converted with the BT.709 matrix, not sws's BT.601 default")
    func bt709() {
        #expect(FrameDecodeContext.swsColorspace(for: described(AVCOL_PRI_BT709, AVCOL_SPC_BT709)) == SWS_CS_ITU709)
    }

    @Test("An untagged still takes the matrix the displayed buffer is tagged with (AE#654)")
    func untaggedFollowsPlayback() {
        #expect(FrameDecodeContext.swsColorspace(for: .unspecified) == SWS_CS_ITU709)
        #expect(FrameDecodeContext.swsColorspace(for: described(AVCOL_PRI_BT470BG, AVCOL_SPC_UNSPECIFIED)) == SWS_CS_ITU601)
    }

    @Test("An untagged SD still takes playback's BT.601 guess (#6); HD stays BT.709")
    func untaggedSDFollowsPlayback() {
        #expect(FrameDecodeContext.swsColorspace(for: .unspecified, frameSize: (720, 480)) == SWS_CS_ITU601)
        #expect(FrameDecodeContext.swsColorspace(for: .unspecified, frameSize: (720, 576)) == SWS_CS_ITU601)
        #expect(FrameDecodeContext.swsColorspace(for: .unspecified, frameSize: (1920, 1080)) == SWS_CS_ITU709)
    }

    @Test("SD and BT.2020 matrices keep their own tables")
    func declaredMatrices() {
        #expect(FrameDecodeContext.swsColorspace(for: described(AVCOL_PRI_UNSPECIFIED, AVCOL_SPC_SMPTE170M)) == SWS_CS_ITU601)
        #expect(FrameDecodeContext.swsColorspace(for: described(AVCOL_PRI_UNSPECIFIED, AVCOL_SPC_BT2020_NCL)) == SWS_CS_BT2020)
    }

    @Test("Full range is read from color_range and from the JPEG pixel formats")
    func fullRange() throws {
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        let f = try #require(frame)
        defer { av_frame_free(&frame) }
        f.pointee.format = AV_PIX_FMT_YUV420P10LE.rawValue
        f.pointee.color_range = AVCOL_RANGE_MPEG
        #expect(!FrameDecodeContext.isFullRange(f))
        f.pointee.color_range = AVCOL_RANGE_JPEG
        #expect(FrameDecodeContext.isFullRange(f))
        f.pointee.color_range = AVCOL_RANGE_UNSPECIFIED
        f.pointee.format = AV_PIX_FMT_YUVJ420P.rawValue
        #expect(FrameDecodeContext.isFullRange(f))
    }
}
