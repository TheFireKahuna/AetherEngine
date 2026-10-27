import Testing
@testable import AetherEngine

/// The muxer moves on to a segment once every track has reached it (`SegmentCutGate`), so the packets of a
/// track that is behind still land in the segment their own time names.
@Suite("The cut gate")
struct SegmentCutGateTests {

    private typealias Gate = SegmentCutGate<String>

    private func names(_ released: [(segment: Int, item: String)]) -> [String] {
        released.map { "\($0.segment):\($0.item)" }
    }

    @Test("a keyframe read before the last audio of the segment it closes waits for that audio")
    func videoWaitsForAudio() {
        var gate = Gate(tracks: [.video, .audio], segment: 3)
        #expect(names(gate.submit("v1", track: .video, segment: 3)) == ["3:v1"])
        #expect(names(gate.submit("a1", track: .audio, segment: 3)) == ["3:a1"])
        // The keyframe opening 4, then pictures after it: held.
        #expect(gate.submit("k4", track: .video, segment: 4).isEmpty)
        #expect(gate.submit("v4", track: .video, segment: 4).isEmpty)
        // Audio still in 3 goes into 3, ahead of the held pictures.
        #expect(names(gate.submit("a2", track: .audio, segment: 3)) == ["3:a2"])
        // Audio reaching 4 lets the cut through, the pictures first, as they were read.
        #expect(names(gate.submit("a3", track: .audio, segment: 4)) == ["4:k4", "4:v4", "4:a3"])
        #expect(gate.heldCount == 0)
    }

    @Test("audio read ahead of the keyframe that opens its segment waits for it")
    func audioWaitsForVideo() {
        var gate = Gate(tracks: [.video, .audio], segment: 0)
        #expect(gate.submit("a1", track: .audio, segment: 1).isEmpty)
        #expect(names(gate.submit("v0", track: .video, segment: 0)) == ["0:v0"])
        #expect(names(gate.submit("k1", track: .video, segment: 1)) == ["1:a1", "1:k1"])
    }

    @Test("a track a whole segment behind has nothing at the boundary and holds nothing up")
    func gapReleases() {
        var gate = Gate(tracks: [.video, .audio], segment: 0)
        #expect(gate.submit("k1", track: .video, segment: 1).isEmpty)
        // Video reaching 2 with no audio past 0: the audio has a gap, segment 1 is cut without it.
        #expect(names(gate.submit("k2", track: .video, segment: 2)) == ["1:k1"])
        #expect(gate.heldCount == 1)
    }

    @Test("one track is never held, and a drain hands everything on in segment order")
    func singleTrackAndDrain() {
        var alone = Gate(tracks: [.video], segment: 5)
        #expect(names(alone.submit("k6", track: .video, segment: 6)) == ["6:k6"])

        var gate = Gate(tracks: [.video, .audio], segment: 0)
        _ = gate.submit("k1", track: .video, segment: 1)
        _ = gate.submit("v1", track: .video, segment: 1)
        #expect(names(gate.drain()) == ["1:k1", "1:v1"])
        #expect(gate.heldCount == 0)
    }
}
