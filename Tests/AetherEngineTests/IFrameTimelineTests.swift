// Tests/AetherEngineTests/IFrameTimelineTests.swift
import Testing
@testable import AetherEngine

struct IFrameTimelineTests {
    private typealias Segment = HLSVideoEngine.Segment

    /// Two 2.31 s segments over keyframes every 0.77 s (ms timebase), as a Blu-ray remux plans them.
    private let plan = [
        Segment(startPts: 0, endPts: 2310, startSeconds: 0, durationSeconds: 2.31),
        Segment(startPts: 2310, endPts: 4620, startSeconds: 2.31, durationSeconds: 2.31),
    ]
    private let keyframes: [Int64] = [0, 770, 1540, 2310, 3080, 3850]

    @Test("every indexed keyframe at least 0.75 s from its neighbours joins the segments' own")
    func denserThanSegments() {
        let entries = HLSVideoEngine.iFrameEntries(plan: plan, keyframes: keyframes, timeBaseSeconds: 0.001)
        #expect(entries.map(\.startPts) == [0, 770, 1540, 2310, 3080, 3850])
        #expect(abs(entries.map(\.durationSeconds).reduce(0, +) - 4.62) < 1e-9)
        #expect(entries.allSatisfy { abs($0.durationSeconds - 0.77) < 1e-9 })
    }

    @Test("keyframes closer than the spacing are skipped, and each segment's opening keyframe stays")
    func thinned() {
        let dense: [Int64] = Array(stride(from: 0, to: 4620, by: 250))
        let entries = HLSVideoEngine.iFrameEntries(plan: plan, keyframes: dense, timeBaseSeconds: 0.001)
        #expect(entries.contains { $0.startPts == 2310 })
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $1.startSeconds - $0.startSeconds >= 0.75 - 1e-9 })
        #expect(entries.last.map { $0.startSeconds + $0.durationSeconds } == 4.62)
    }

    @Test("positions are measured from their segment, so they follow the plan's axis")
    func planAxis() {
        // The plan's seconds start at the first keyframe, 10 s into the source.
        let shifted = [Segment(startPts: 10_000, endPts: 12_310, startSeconds: 0, durationSeconds: 2.31)]
        let entries = HLSVideoEngine.iFrameEntries(plan: shifted, keyframes: [10_000, 11_000], timeBaseSeconds: 0.001)
        #expect(entries.map(\.startSeconds) == [0, 1.0])
    }

    @Test("without an index the timeline is one entry per segment")
    func noKeyframes() {
        let entries = HLSVideoEngine.iFrameEntries(plan: plan, keyframes: [], timeBaseSeconds: 0.001)
        #expect(entries.map(\.startPts) == [0, 2310])
        #expect(entries.map(\.durationSeconds) == [2.31, 2.31])
    }
}
