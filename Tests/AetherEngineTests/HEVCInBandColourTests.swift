import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

/// `HardwareVideoDecoder` tags each picture with the colour its own SPS and coded video sequence state, not the
/// stream's colour at open: a later SPS's colour (or its silence) and the alternative transfer SEI's scope (H.265 D.3).
struct HEVCInBandColourTests {
    // x265 parameter sets: BT.2020 / HLG / BT.2020 NCL, BT.2020 / BT.2020 10-bit / BT.2020 NCL (HLG's backward-compatible
    // declaration), and a VUI without colour.
    static let taggedVPS: [UInt8] = [0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x3c, 0x95, 0x98, 0x09]
    static let taggedSPS: [UInt8] = [0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x3c, 0xa0, 0x0a, 0x08, 0x0b, 0x9f, 0x6d, 0x96, 0x56, 0x69, 0x24, 0xca, 0xf0, 0x16, 0xa1, 0x22, 0x41, 0x20, 0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x0c, 0x84]
    static let taggedPPS: [UInt8] = [0x44, 0x01, 0xc1, 0x72, 0xb4, 0x62, 0x40]
    static let compatVPS: [UInt8] = [0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x1e, 0x95, 0x98, 0x09]
    static let compatSPS: [UInt8] = [0x42, 0x01, 0x01, 0x02, 0x20, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x1e, 0xa0, 0x20, 0x81, 0x04, 0xd9, 0x65, 0x66, 0x92, 0x4c, 0xaf, 0x01, 0x6a, 0x12, 0x1c, 0x12, 0x08, 0x00, 0x00, 0x03, 0x00, 0x08, 0x00, 0x00, 0x03, 0x00, 0xc8, 0x40]
    static let compatPPS: [UInt8] = [0x44, 0x01, 0xc1, 0x72, 0xb4, 0x22, 0x40]
    static let plainVPS: [UInt8] = [0x40, 0x01, 0x0c, 0x01, 0xff, 0xff, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9e, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x3c, 0x95, 0x98, 0x09]
    static let plainSPS: [UInt8] = [0x42, 0x01, 0x01, 0x04, 0x08, 0x00, 0x00, 0x03, 0x00, 0x9e, 0x08, 0x00, 0x00, 0x03, 0x00, 0x00, 0x3c, 0x90, 0x01, 0x41, 0x01, 0x73, 0xe5, 0xcb, 0x2b, 0x34, 0x92, 0x65, 0x78, 0x0b, 0x70, 0x20, 0x20, 0x00, 0x40, 0x00, 0x00, 0x03, 0x00, 0x40, 0x00, 0x00, 0x06, 0x42]
    static let plainPPS: [UInt8] = [0x44, 0x01, 0xc1, 0x72, 0x86, 0x0c, 0x46, 0x24]

    /// A prefix SEI holding one alternative_transfer_characteristics message.
    static func alternativeTransfer(_ value: UInt8) -> [UInt8] { [0x4e, 0x01, 0x93, 0x01, value, 0x80] }
    /// A VCL NAL header of `type` (the slice payload is never read).
    static func slice(_ type: UInt8) -> [UInt8] { [type << 1, 0x01, 0xaf, 0x00] }

    static func unit(_ nals: [[UInt8]]) -> [UInt8] {
        nals.flatMap { n in withUnsafeBytes(of: UInt32(n.count).bigEndian, Array.init) + n }
    }

    static let idr: UInt8 = 19, cra: UInt8 = 21, trail: UInt8 = 1

    static func tags(_ tracker: inout HEVCInBandColour, _ nals: [[UInt8]]) -> HEVCInBandColour.Tags {
        let bytes = unit(nals)
        return bytes.withUnsafeBufferPointer { tracker.tags(forAccessUnit: $0.baseAddress!, size: $0.count) }
    }

    static let bt709 = HEVCInBandColour.Tags(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
                                             transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
                                             matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)

    @Test("CoreMedia reads an SPS's VUI colour, and none from a VUI without it")
    func readsVUI() throws {
        let tagged = try #require(HEVCInBandColour.colour(vps: Self.taggedVPS, sps: Self.taggedSPS, pps: Self.taggedPPS))
        #expect(tagged == HEVCInBandColour.Tags(primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
                                                transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                                                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020))
        #expect(HEVCInBandColour.colour(vps: Self.plainVPS, sps: Self.plainSPS, pps: Self.plainPPS) == HEVCInBandColour.Tags())
    }

    @Test("A stream whose SPS never states colour keeps the container's throughout (AE#499)")
    func silentSPSKeepsContainer() {
        var tracker = HEVCInBandColour(framing: .lengthPrefixed(size: 4), container: Self.bt709)
        #expect(Self.tags(&tracker, [Self.plainVPS, Self.plainSPS, Self.plainPPS, Self.slice(Self.idr)]) == Self.bt709)
        #expect(Self.tags(&tracker, [Self.slice(Self.trail)]) == Self.bt709)
    }

    @Test("A later SPS's colour reaches its pictures, and its silence is unspecified once colour was stated")
    func laterSPS() {
        var tracker = HEVCInBandColour(framing: .lengthPrefixed(size: 4), container: Self.bt709)
        let hlg = Self.tags(&tracker, [Self.taggedVPS, Self.taggedSPS, Self.taggedPPS, Self.slice(Self.idr)])
        #expect(hlg.transfer.map { CFEqual($0, kCVImageBufferTransferFunction_ITU_R_2100_HLG) } == true)
        #expect(Self.tags(&tracker, [Self.slice(Self.trail)]) == hlg)
        #expect(Self.tags(&tracker, [Self.plainVPS, Self.plainSPS, Self.plainPPS, Self.slice(Self.idr)]) == HEVCInBandColour.Tags())
    }

    @Test("The alternative transfer SEI lasts its coded video sequence: kept through a CRA, ended by an IDR without it")
    func alternativeTransferScope() throws {
        // CoreMedia names TransferCharacteristics 14 (BT.2020 10-bit) by its curve, BT.709's.
        let compat = try #require(HEVCInBandColour.colour(vps: Self.compatVPS, sps: Self.compatSPS, pps: Self.compatPPS))
        #expect(compat.primaries.map { CFEqual($0, kCVImageBufferColorPrimaries_ITU_R_2020) } == true)
        var hlg = compat
        hlg.transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
        var tracker = HEVCInBandColour(framing: .lengthPrefixed(size: 4), container: compat)
        let sets = [Self.compatVPS, Self.compatSPS, Self.compatPPS]
        #expect(Self.tags(&tracker, sets + [Self.alternativeTransfer(18), Self.slice(Self.idr)]) == hlg)
        #expect(Self.tags(&tracker, [Self.slice(Self.trail)]) == hlg)
        #expect(Self.tags(&tracker, [Self.slice(Self.cra)]) == hlg, "a CRA mid-sequence does not start one")
        #expect(Self.tags(&tracker, sets + [Self.slice(Self.idr)]) == compat, "an IDR without the SEI ends it")
        // After a seek the decoder restarts at a CRA, which then starts a coded video sequence.
        _ = Self.tags(&tracker, sets + [Self.alternativeTransfer(18), Self.slice(Self.idr)])
        tracker.restart()
        #expect(Self.tags(&tracker, [Self.slice(Self.cra)]) == compat)
    }
}
