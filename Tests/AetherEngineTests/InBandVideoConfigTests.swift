import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// An init built from in-band H.264 parameter sets (a live join, an SSAI creative, a same-PID parameter-set change)
/// describes their colour: the new SPS's VUI, and HLG where the keyframe's alternative transfer SEI names it over a
/// backward-compatible declaration. Before, its codec parameters carried none and the init had no `colr`.
struct InBandVideoConfigTests {
    // x264, 64x64: BT.709 with video range, and a VUI without colour.
    static let tagged = Data(base64Encoded: "AAAAAWdkAAqs2UQmwFqAgICgAAADACAAAAZB4kSywAAAAAFo6+PLIsAAAAFliIQAN//+9vD+A0JQlxHN6Hz9AAVXa9rh4i//VGEAAAABQZokbEL//ozTYAAAAAFBnkJ4hf8JuQAAAAEBnmF0Qr8MOAAAAAEBnmNqQr8MOQAAAAFBmmVJqEFomUwIV//+OI3B")!
    static let plain = Data(base64Encoded: "AAAAAWdkAAqs2UQmwEQAAAMABAAAAwDIPEiWWAAAAAFo6+PLIsAAAAFliIQAN//+9vD+A0JQlxHN6Hz9AAVXa9rh4i//VGEAAAABQZokbEL//ozTYAAAAAFBnkJ4hf8JuQAAAAEBnmF0Qr8MOAAAAAEBnmNqQr8MOQAAAAFBmmVJqEFomUwIV//+OI3B")!
    // x264 10-bit, BT.2020 / BT.2020 10-bit: two IDR runs, the first with an alternative transfer SEI naming HLG.
    static let alternativeTransfer = Data(base64Encoded: "AAAAAWduAAqmzZRCbAWoSHBKAAADAAIAAAMAZB4kSywAAAABaOvjyyLAAAAAAQaTARKAAAAAAWWIhAAR//73iB8yjnK13IR56xU/UYjGW1z52a6GKd8AAAABQZokbEP//qmdNAAAAAFBnkJ4h/8ExQAAAAEBnmF0Q78FvAAAAAEBnmNqQ78FvQAAAAFBmmU0tEwEO//+qZ01AAAAAWduAAqmzZRCbAWoSHBKAAADAAIAAAMAZB4kSywAAAABaOvjyyLAAAABZYiEABH//veIHzKOcrXchHnrFT9RiMZbXPnZroYp3wAAAAFBmiRsQ//+qZ00AAAAAUGeQniH/wTFAAAAAQGeYXRDvwW8AAAAAQGeY2pDvwW9AAAAAUGaZTS0TAQ7//6pnTU=")!

    static func config(_ data: Data) -> HLSSegmentProducer.InBandVideoConfig? {
        [UInt8](data).withUnsafeBufferPointer { HLSSegmentProducer.InBandVideoConfig(annexB: $0, codec: .h264, requiresRandomAccess: true) }
    }

    @Test("The SPS's VUI colour, and unspecified where the VUI states none")
    func spsColour() throws {
        let tagged = try #require(Self.config(Self.tagged))
        #expect(tagged.colour == ColorDescription(primaries: AVCOL_PRI_BT709, transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709,
                                                  range: AVCOL_RANGE_MPEG))
        #expect(tagged.width == 64 && tagged.height == 64)
        #expect(try #require(Self.config(Self.plain)).colour == .unspecified)
    }

    @Test("HLG from the keyframe's alternative transfer SEI over BT.2020; the declared transfer without it")
    func alternativeTransferNamesHLG() throws {
        let first = try #require(Self.config(Self.alternativeTransfer))
        #expect(first.colour.primaries == AVCOL_PRI_BT2020 && first.colour.transfer == AVCOL_TRC_ARIB_STD_B67)
        // The second run's IDR carries no SEI.
        let bytes = [UInt8](Self.alternativeTransfer)
        let sps: [UInt8] = [0, 0, 0, 1, 0x67]
        let second = try #require((1..<bytes.count - 5).first { Array(bytes[$0..<($0 + 5)]) == sps })
        let secondRun = try #require(Self.config(Data(bytes[second...])))
        #expect(secondRun.colour.transfer == AVCOL_TRC_BT2020_10)
    }

    // MARK: - HEVC

    static func hevcUnit(_ nals: [[UInt8]]) -> [UInt8] { nals.flatMap { [0, 0, 0, 1] + $0 } }

    static func hevcConfig(_ nals: [[UInt8]], requiresRandomAccess: Bool = true) -> HLSSegmentProducer.InBandVideoConfig? {
        hevcUnit(nals).withUnsafeBufferPointer {
            HLSSegmentProducer.InBandVideoConfig(annexB: $0, codec: .hevc, requiresRandomAccess: requiresRandomAccess)
        }
    }

    typealias C = HEVCInBandColourTests

    @Test("HEVC: dimensions from the SPS, its colour as code points, and a record for the muxer")
    func hevcConfig() throws {
        let tagged = try #require(Self.hevcConfig([C.taggedVPS, C.taggedSPS, C.taggedPPS, C.slice(C.idr)]))
        #expect(tagged.codecID == AV_CODEC_ID_HEVC)
        #expect(tagged.width == 320 && tagged.height == 180)
        #expect(tagged.colour.primaries == AVCOL_PRI_BT2020 && tagged.colour.transfer == AVCOL_TRC_ARIB_STD_B67
                && tagged.colour.matrix == AVCOL_SPC_BT2020_NCL)
        #expect(tagged.lengthPrefixedRecord?.first == 1, "an hvcC record")
        let plain = try #require(Self.hevcConfig([C.plainVPS, C.plainSPS, C.plainPPS, C.slice(C.idr)]))
        #expect(plain.colour.primaries == AVCOL_PRI_UNSPECIFIED && plain.colour.matrix == AVCOL_SPC_UNSPECIFIED)
        // A unit with no IRAP is no entry point.
        #expect(Self.hevcConfig([C.taggedVPS, C.taggedSPS, C.taggedPPS, C.slice(C.trail)]) == nil)
    }

    @Test("HEVC: HLG from the keyframe's alternative transfer SEI over BT.2020")
    func hevcAlternativeTransfer() throws {
        let compat = try #require(Self.hevcConfig([C.compatVPS, C.compatSPS, C.compatPPS, C.slice(C.idr)]))
        #expect(compat.colour.transfer != AVCOL_TRC_ARIB_STD_B67)
        let hlg = try #require(Self.hevcConfig([C.compatVPS, C.compatSPS, C.compatPPS, C.alternativeTransfer(18),
                                                C.slice(C.idr)]))
        #expect(hlg.colour.transfer == AVCOL_TRC_ARIB_STD_B67)
        #expect(hlg.width == 64 && hlg.height == 64)
    }
}
