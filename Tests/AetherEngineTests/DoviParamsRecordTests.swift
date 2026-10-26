// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
@testable import AetherEngine

/// A FEL unit's composer parameters kept on disk (`OverlayPacketTap`) come back as they were cut.
@Suite("Composer parameters as a unit record")
struct DoviParamsRecordTests {

    @Test("a record reads back to the same GPU layout, Level 6 and output range")
    func roundTrip() throws {
        var params = DoviLayoutProbeTests.sentinelParams()
        params.nlqCr.nlqMethod = .none
        params.masterLevel6 = DolbyVisionLevel6(minLuminance: 50, maxLuminance: 4000, maxContentLightLevel: 3172,
                                                maxFrameAverageLightLevel: 523)
        params.outputFullRange = true
        let read = try #require(DoviMetalParams(unitRecord: params.unitRecord()))
        #expect(read.serialize() == params.serialize())
        #expect(read.masterLevel6 == params.masterLevel6)
        #expect(read.outputFullRange)

        params.masterLevel6 = nil
        params.outputFullRange = false
        let plain = try #require(DoviMetalParams(unitRecord: params.unitRecord()))
        #expect(plain.masterLevel6 == nil)
        #expect(!plain.outputFullRange)
    }

    @Test("bytes that are not a record read as none")
    func notARecord() {
        #expect(DoviMetalParams(unitRecord: Data(count: 12)) == nil)
        var record = DoviMetalParams().unitRecord()
        record.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(77).littleEndian, toByteOffset: 20, as: UInt32.self) }
        #expect(DoviMetalParams(unitRecord: record) == nil)   // no such dither mode
    }
}
#endif
