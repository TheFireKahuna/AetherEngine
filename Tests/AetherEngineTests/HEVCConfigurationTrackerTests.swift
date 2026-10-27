import Foundation
import Testing
import AetherLibavcodec
@testable import AetherEngine

/// HEVC VOD whose SPS changes mid-title (a spliced file) against an init built from the first: the H.264 tracker's
/// counterpart, so the session is rebuilt instead of decoding new slices against a stale `hvcC`.
struct HEVCConfigurationTrackerTests {
    typealias C = HEVCInBandColourTests

    static func tracker() throws -> HEVCConfigurationTracker {
        let annexB: [UInt8] = [C.taggedVPS, C.taggedSPS, C.taggedPPS].flatMap { [UInt8]([0, 0, 0, 1]) + $0 }
        let hvcC = try #require(VideoConfigRecord.fromAnnexB(annexB, codecID: AV_CODEC_ID_HEVC, width: 320, height: 180))
        return try #require(HEVCConfigurationTracker(hvcC: hvcC, framing: .lengthPrefixed(size: 4)))
    }

    static func observe(_ tracker: inout HEVCConfigurationTracker, _ nals: [[UInt8]]) -> HEVCConfigurationTracker.Mismatch? {
        C.unit(nals).withUnsafeBufferPointer { tracker.observe($0) }
    }

    @Test("The init's own parameter sets repeated in-band are no change")
    func repeatedSetsMatch() throws {
        var tracker = try Self.tracker()
        #expect(Self.observe(&tracker, [C.taggedVPS, C.taggedSPS, C.taggedPPS, C.slice(C.idr)]) == nil)
        #expect(Self.observe(&tracker, [C.slice(C.trail)]) == nil)
    }

    @Test("An IRAP on an SPS with other dimensions or depth is a mismatch, named with its size")
    func newSPSAtIRAP() throws {
        var tracker = try Self.tracker()
        let mismatch = Self.observe(&tracker, [C.compatVPS, C.compatSPS, C.compatPPS, C.slice(C.idr)])
        #expect(mismatch == HEVCConfigurationTracker.Mismatch(width: 64, height: 64, spsID: 0))
    }

    @Test("A new SPS announced without an IRAP that uses it is not one yet")
    func announcedOnly() throws {
        var tracker = try Self.tracker()
        #expect(Self.observe(&tracker, [C.compatVPS, C.compatSPS, C.compatPPS, C.slice(C.trail)]) == nil)
    }

    /// A NAL moved to nuh_layer_id 1: the header's layer bits set.
    static func layerOne(_ nal: [UInt8]) -> [UInt8] { [nal[0] & 0xFE, (nal[1] & 0x07) | (1 << 3)] + nal[2...] }

    @Test("A second layer's parameter sets and pictures (MV-HEVC, a scalable layer) are not the base layer's")
    func secondLayerIgnored() throws {
        var tracker = try Self.tracker()
        let other = [C.compatVPS, C.compatSPS, C.compatPPS, C.slice(C.idr)].map(Self.layerOne)
        #expect(Self.observe(&tracker, [C.taggedVPS, C.taggedSPS, C.taggedPPS, C.slice(C.idr)] + other) == nil)
        #expect(Self.observe(&tracker, [C.slice(C.idr)]) == nil, "the base layer's sets were not replaced")
    }
}
