// A native VOD seek waits for the whole segment holding its target and then for AVPlayer's
// stall-avoidance judgement of the next one. The keyframe plan cuts at 2 s so the first wait is a
// short segment, and a landing over a proven cushion is started by hand so the second one goes.
import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("VOD seek latency: 2 s keyframe plan and the landing start")
struct VODSeekLatencyTests {

    private let mkvMs = AVRational(num: 1, den: 1_000)

    @Test("one-second GOPs cut every two seconds")
    func twoSecondCuts() {
        let keyframes = (0..<60).map { Int64($0) * 1_000 }
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(keyframes: keyframes, videoTimeBase: mkvMs,
                                                           sourceDurationSeconds: 60)
        #expect(plan.count == 30)
        #expect(plan.dropLast().allSatisfy { abs($0.durationSeconds - 2) < 0.001 })
    }

    @Test("a GOP longer than the target still cuts once per GOP")
    func longGOP() {
        let keyframes = (0..<10).map { Int64($0) * 5_000 }
        let plan = HLSVideoEngine.buildKeyframeSegmentPlan(keyframes: keyframes, videoTimeBase: mkvMs,
                                                           sourceDurationSeconds: 50)
        #expect(plan.count == 10)
        #expect(plan.allSatisfy { abs($0.durationSeconds - 5) < 0.001 })
    }

    @Test("the VOD window keeps its depth in seconds; live keeps its own count")
    func windowScales() {
        #expect(HLSVideoEngine.vodSegmentsPerCountedSegment == 2)
        #expect(HLSVideoEngine.sessionForwardWindow(requested: nil, isLive: false) == 20)
        #expect(HLSVideoEngine.sessionForwardWindow(requested: nil, isLive: true) == 10)
        #expect(HLSVideoEngine.sessionForwardWindow(requested: 15, isLive: false) == 30)
        #expect(HLSVideoEngine.sessionForwardWindow(requested: Int.max, isLive: false) == 5400)
        #expect(HLSVideoEngine.sessionForwardWindow(requested: 1, isLive: false) == 8)
    }

    @Test("a media playlist loaded without its master still declares independent segments")
    func mediaPlaylistDeclaresIndependence() {
        let plan = (0..<5).map { i in
            HLSVideoEngine.Segment(startPts: Int64(i) * 2000, endPts: Int64(i + 1) * 2000,
                                   startSeconds: Double(i) * 2.0, durationSeconds: 2.0)
        }
        let provider = VideoSegmentProvider(
            cache: SegmentCache(forwardWindow: 20, backwardWindow: 40),
            segments: plan,
            codecsString: "hvc1.2.4.L153.B0,ec-3",
            supplementalCodecs: "dvh1.08.06/db1p",
            resolution: (3840, 2160),
            videoRange: .pq,
            frameRate: 23.976,
            hdcpLevel: nil,
            sourceBitrate: 60_000_000,
            isLive: false
        )
        let lines = HLSLocalServer.buildMediaPlaylistText(provider: provider).split(separator: "\n")
        #expect(lines.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        #expect(lines.contains("#EXT-X-TARGETDURATION:2"))
        #expect(lines.contains("#EXT-X-ENDLIST"))
    }

    @Test("a landing starts by hand only over a ready, non-empty cushion of the floor")
    func landingDecision() {
        let floor = NativeAVPlayerHost.minimumSeekLandingBufferAhead
        #expect(NativeAVPlayerHost.shouldStartSeekLandingImmediately(
            bufferEmpty: false, bufferedAheadSeconds: floor, itemIsReadyToPlay: true))
        #expect(!NativeAVPlayerHost.shouldStartSeekLandingImmediately(
            bufferEmpty: false, bufferedAheadSeconds: floor - 0.01, itemIsReadyToPlay: true))
        #expect(!NativeAVPlayerHost.shouldStartSeekLandingImmediately(
            bufferEmpty: true, bufferedAheadSeconds: 4, itemIsReadyToPlay: true))
        #expect(!NativeAVPlayerHost.shouldStartSeekLandingImmediately(
            bufferEmpty: false, bufferedAheadSeconds: 4, itemIsReadyToPlay: false))
        #expect(!NativeAVPlayerHost.shouldStartSeekLandingImmediately(
            bufferEmpty: false, bufferedAheadSeconds: .nan, itemIsReadyToPlay: true))
    }
}
