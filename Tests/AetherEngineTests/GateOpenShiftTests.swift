import Testing
@testable import AetherEngine

/// What a gate open states about its epoch: how far its first presented picture sits from the
/// segment's advertised start (`presentedShiftPts`, the axis a live epoch publishes), and how far after
/// its own decode time that picture is presented (`presentationLeadPts`, named on the gate-open line).
@Suite("Gate open: the presented shift and the presentation lead")
struct GateOpenShiftTests {

    @Test("the shift is the first presented picture's distance from the advertised start")
    func presentedShift() {
        // A gate re-aimed below a boundary at 52.000 s and opened at 43.000 s.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 43_000, desiredTfdtPts: 52_000) == -9_000)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 44_000, desiredTfdtPts: 44_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 55_000, desiredTfdtPts: 52_000) == 3_000)
    }

    @Test("taken on the presented picture, not the decoded one")
    func presentedNotDecoded() {
        // `tc-bframes.mkv`: the random-access point is decoded at 42917 and presented at 43000.
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 43_000, desiredTfdtPts: 52_000) == -9_000)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 42_917, desiredTfdtPts: 52_000) == -9_083)
    }

    @Test("an unresolved timestamp states nothing")
    func unresolved() {
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: .min, desiredTfdtPts: 52_000) == 0)
        #expect(HLSSegmentProducer.presentedShiftPts(actualFirstPts: 43_000, desiredTfdtPts: .min) == 0)
    }

    @Test("the lead is how far after its own decode time the gating picture is presented")
    func lead() {
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: 42_917) == 83)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: 43_000) == 0)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: .min, actualFirstDts: 42_917) == 0)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 43_000, actualFirstDts: .min) == 0)
        #expect(HLSSegmentProducer.presentationLeadPts(actualFirstPts: 42_917, actualFirstDts: 43_000) == 0)
    }
}
