// Tests/AetherEngineTests/IFrameRenditionEligibilityTests.swift
import Testing
@testable import AetherEngine

struct IFrameRenditionEligibilityTests {
    private func inputs(_ change: (inout IFrameRenditionEligibility.Inputs) -> Void = { _ in })
        -> IFrameRenditionEligibility.Inputs {
        var i = IFrameRenditionEligibility.Inputs(
            requested: true, isLive: false, planBoundariesClaimRandomAccess: true,
            seeksToTimeWithoutIndex: false, sequentialOrigin: false, heldSourceConnection: false,
            originIsSerial: false, secondReaderAvailable: true)
        change(&i)
        return i
    }

    @Test("every requirement met is a candidate on the plan's keyframes")
    func allMet() {
        #expect(IFrameRenditionEligibility.candidate(inputs()) == .served(.keyframes))
    }

    @Test("a plan without keyframes on a source that seeks to a time serves dense stills")
    func stillsWithoutAKeyframeList() {
        #expect(IFrameRenditionEligibility.candidate(inputs {
            $0.planBoundariesClaimRandomAccess = false
            $0.seeksToTimeWithoutIndex = true
        }) == .served(.stills))
        // A keyframe plan keeps its keyframes, whatever else the source can seek by.
        #expect(IFrameRenditionEligibility.candidate(inputs { $0.seeksToTimeWithoutIndex = true })
                == .served(.keyframes))
        // The stills need a picture as much as the keyframes do.
        #expect(IFrameRenditionEligibility.candidate(inputs {
            $0.planBoundariesClaimRandomAccess = false
            $0.seeksToTimeWithoutIndex = true
            $0.stillsUnavailable = true
        }) == .absent(.dolbyVisionStillsNotBuiltIn))
    }

    @Test("each failed requirement names its own reason",
          arguments: ["notRequested", "live", "planNotKeyframeAligned", "sequentialOrigin",
                      "heldSourceConnection", "serialOrigin", "noSecondReader",
                      "dolbyVisionStillsNotBuiltIn"])
    func eachReason(reason: String) throws {
        let expected = try #require(IFrameRenditionEligibility.AbsentReason(rawValue: reason))
        let verdict = IFrameRenditionEligibility.candidate(inputs { i in
            switch expected {
            case .notRequested: i.requested = false
            case .live: i.isLive = true
            case .planNotKeyframeAligned: i.planBoundariesClaimRandomAccess = false
            case .sequentialOrigin: i.sequentialOrigin = true
            case .heldSourceConnection: i.heldSourceConnection = true
            case .serialOrigin: i.originIsSerial = true
            case .noSecondReader: i.secondReaderAvailable = false
            case .dolbyVisionStillsNotBuiltIn: i.stillsUnavailable = true
            case .mediaPlaylistRouting: break
            }
        })
        #expect(verdict == .absent(expected))
    }

    @Test("not requested wins over every other reason, so an unflagged session logs nothing odd")
    func notRequestedFirst() {
        let v = IFrameRenditionEligibility.candidate(inputs { $0.requested = false; $0.isLive = true })
        #expect(v == .absent(.notRequested))
    }

    @Test("a candidate without a master is absent for routing")
    func mediaRouting() {
        #expect(IFrameRenditionEligibility.resolve(candidate: .served(.stills), servingMaster: false)
                == .absent(.mediaPlaylistRouting))
        #expect(IFrameRenditionEligibility.resolve(candidate: .served(.stills), servingMaster: true)
                == .served(.stills))
        #expect(IFrameRenditionEligibility.resolve(candidate: .absent(.live), servingMaster: true)
                == .absent(.live))
    }

    @Test("the dense stills sit a second apart on the plan's axis, the last running to the end")
    func denseStillEntries() {
        let plan = [
            HLSVideoEngine.Segment(startPts: 900_000, endPts: 900_000 + 4 * 90_000, startSeconds: 0, durationSeconds: 4),
            HLSVideoEngine.Segment(startPts: 900_000 + 4 * 90_000, endPts: 900_000 + 585_000,
                                   startSeconds: 4, durationSeconds: 2.5),
        ]
        let entries = HLSVideoEngine.denseStillEntries(plan: plan, timeBaseSeconds: 1.0 / 90_000)
        #expect(entries.map(\.startSeconds) == [0, 1, 2, 3, 4, 5, 6])
        #expect(entries.map(\.startPts) == (0..<7).map { 900_000 + Int64($0) * 90_000 })
        #expect(entries.dropLast().allSatisfy { $0.durationSeconds == 1 })
        #expect(entries.last?.durationSeconds == 0.5)
    }
}
