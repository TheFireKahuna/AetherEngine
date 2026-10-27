import Testing
import AetherLibavcodec
@testable import AetherEngine

/// #7: the software route's deinterlacer emits one picture per field, so the display has to
/// be asked for the field rate. Measured through the decoder on generated clips: MPEG-2 1080i25 comes
/// out at 50.0 fps and MPEG-2 480i29.97 at 59.94, while the container reports 25 and 29.97.
@Suite("Display rate for field-rate deinterlacing (#7)")
struct InterlacedDisplayRateTests {

    private func rate(_ content: Double?, _ codec: AVCodecID = AV_CODEC_ID_MPEG2VIDEO,
                      _ order: AVFieldOrder = AV_FIELD_TT,
                      fieldRate: DeinterlaceFieldRate = .field) -> Double? {
        AetherEngine.displayFrameRate(contentRate: content, codecID: codec, fieldOrder: order,
                                      deinterlaceFieldRate: fieldRate)
    }

    @Test("1080i25 asks for 50 Hz and 480i29.97 for 59.94 Hz, after the snap")
    func doublesInterlacedFrameRates() {
        #expect(FrameRateSnap.snap(rate(25) ?? 0) == 50)
        #expect(FrameRateSnap.snap(rate(30000.0 / 1001, AV_CODEC_ID_MPEG2VIDEO, AV_FIELD_BB) ?? 0) == 59.94)
        #expect(FrameRateSnap.snap(rate(25, AV_CODEC_ID_H264, AV_FIELD_BT) ?? 0) == 50)
        #expect(rate(25, AV_CODEC_ID_VC1, AV_FIELD_TB) == 50)
    }

    @Test("a rate that is already a field rate is not doubled again")
    func fieldRateLeftAlone() {
        #expect(rate(50) == 50)
        #expect(rate(60000.0 / 1001) == 60000.0 / 1001)
    }

    @Test("frame-rate output keeps the content rate")
    func frameRateCadences() {
        #expect(rate(25, fieldRate: .frame) == 25)
    }

    @Test("progressive, undeclared and natively played interlaced streams keep the content rate")
    func notDeinterlacedBySoftware() {
        #expect(rate(25, AV_CODEC_ID_MPEG2VIDEO, AV_FIELD_PROGRESSIVE) == 25)
        #expect(rate(25, AV_CODEC_ID_MPEG2VIDEO, AV_FIELD_UNKNOWN) == 25)
        // Interlaced HEVC plays native and is not deinterlaced.
        #expect(rate(25, AV_CODEC_ID_HEVC, AV_FIELD_TT) == 25)
        #expect(rate(nil) == nil)
    }
}
