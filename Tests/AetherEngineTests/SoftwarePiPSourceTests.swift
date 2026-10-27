import Testing
import CoreMedia
@testable import AetherEngine

/// The sample-buffer PiP window needs the playable range on the axis of the layer's timebase: the overlay's layer
/// reads item time, which can sit apart from the session's `currentTime`.
@Suite("Software PiP time range")
struct SoftwarePiPSourceTests {
    @Test("VOD with the layer on the session axis: range starts at 0 for the full duration")
    func vodZeroBased() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, layerTime: 12.0, currentTime: 12.0, duration: 3600)
        #expect(abs(r.start.seconds - 0) < 0.001)
        #expect(abs(r.duration.seconds - 3600) < 0.001)
    }

    @Test("VOD with the layer offset from the session axis: range starts at the offset")
    func vodWithOffset() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, layerTime: 152.5, currentTime: 2.5, duration: 600)
        #expect(abs(r.start.seconds - 150.0) < 0.001)
        #expect(abs(r.duration.seconds - 600) < 0.001)
    }

    @Test("live: indefinite range")
    func liveIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: true, layerTime: 500, currentTime: 100, duration: 0)
        #expect(r.start == .negativeInfinity)
        #expect(r.duration == .positiveInfinity)
    }

    @Test("unknown duration falls back to indefinite")
    func unknownDurationIndefinite() {
        let r = AetherEngine.softwarePiPTimeRange(isLive: false, layerTime: 5, currentTime: 5, duration: 0)
        #expect(r.start == .negativeInfinity)
    }
}
