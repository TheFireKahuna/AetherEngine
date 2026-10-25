import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// A live stream that turns HDR mid-way moves the panel up once, when playback reaches it, and never back down.
struct LiveDisplayRangeLatchTests {
    static let hdrPanel = DisplayCapabilities(supportsHDR: true, supportsDolbyVision: true, supportsHDR10: true, supportsHLG: true)
    static let sdrPanel = DisplayCapabilities(supportsHDR: false, supportsDolbyVision: false, supportsHDR10: false, supportsHLG: false)

    static func colour(_ transfer: AVColorTransferCharacteristic) -> ColorDescription {
        ColorDescription(primaries: AVCOL_PRI_BT2020, transfer: transfer, matrix: AVCOL_SPC_BT2020_NCL, range: AVCOL_RANGE_MPEG)
    }

    @Test("The first HDR programme switches the panel when playback reaches it, once, and nothing after")
    func switchesUpOnce() {
        var latch = LiveDisplayRangeLatch(openedIn: .sdr, frameRate: 50)
        latch.note(itemSeconds: 40, colour: Self.colour(AVCOL_TRC_BT709), capabilities: Self.hdrPanel)
        #expect(latch.pending == nil, "an SDR programme asks for nothing")
        latch.note(itemSeconds: 100, colour: Self.colour(AVCOL_TRC_ARIB_STD_B67), capabilities: Self.hdrPanel)
        #expect(latch.crossing(99.9) == nil)
        #expect(latch.crossing(100) == .hlg)
        #expect(latch.crossing(101) == nil)
        // Latched: an SDR ad, then a PQ programme, ask for nothing.
        latch.note(itemSeconds: 200, colour: Self.colour(AVCOL_TRC_BT709), capabilities: Self.hdrPanel)
        latch.note(itemSeconds: 300, colour: Self.colour(AVCOL_TRC_SMPTE2084), capabilities: Self.hdrPanel)
        #expect(latch.pending == nil && latch.crossing(400) == nil)
    }

    @Test("A session that opened in HDR never switches; a panel without HDR is left alone")
    func latchedOrIncapable() {
        var opened = LiveDisplayRangeLatch(openedIn: .hdr10, frameRate: nil)
        opened.note(itemSeconds: 10, colour: Self.colour(AVCOL_TRC_ARIB_STD_B67), capabilities: Self.hdrPanel)
        #expect(opened.crossing(20) == nil)
        var sdrOnly = LiveDisplayRangeLatch(openedIn: .sdr, frameRate: nil)
        sdrOnly.note(itemSeconds: 10, colour: Self.colour(AVCOL_TRC_SMPTE2084), capabilities: Self.sdrPanel)
        #expect(sdrOnly.crossing(20) == nil)
    }

    @Test("HLG takes the HLG mode, or HDR10 on a panel without one; PQ takes HDR10")
    func modes() {
        let hdr10Only = DisplayCapabilities(supportsHDR: true, supportsDolbyVision: false, supportsHDR10: true, supportsHLG: false)
        #expect(LiveDisplayRangeLatch.format(for: Self.colour(AVCOL_TRC_ARIB_STD_B67), capabilities: Self.hdrPanel) == .hlg)
        #expect(LiveDisplayRangeLatch.format(for: Self.colour(AVCOL_TRC_ARIB_STD_B67), capabilities: hdr10Only) == .hdr10)
        #expect(LiveDisplayRangeLatch.format(for: Self.colour(AVCOL_TRC_SMPTE2084), capabilities: hdr10Only) == .hdr10)
        #expect(LiveDisplayRangeLatch.format(for: Self.colour(AVCOL_TRC_BT2020_10), capabilities: Self.hdrPanel) == nil)
    }
}
