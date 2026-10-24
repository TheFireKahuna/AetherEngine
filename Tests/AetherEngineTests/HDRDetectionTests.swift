import Testing
import AetherLibavutil
@testable import AetherEngine

struct HDRDetectionTests {
    @Test("PQ and HLG transfer characteristics are HDR")
    func hdrTransfers() {
        #expect(ColorAttachments.isHDRTransfer(AVCOL_TRC_SMPTE2084))
        #expect(ColorAttachments.isHDRTransfer(AVCOL_TRC_ARIB_STD_B67))
    }
    @Test("SDR transfers are not HDR")
    func sdrTransfers() {
        #expect(!ColorAttachments.isHDRTransfer(AVCOL_TRC_BT709))
        #expect(!ColorAttachments.isHDRTransfer(AVCOL_TRC_UNSPECIFIED))
    }
}
