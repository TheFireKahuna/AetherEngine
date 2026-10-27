import Testing
import AetherLibavutil
@testable import AetherEngine

@Suite("FrameRateSnap")
struct FrameRateSnapTests {

    @Test("Standard rates pass through unchanged")
    func standardRatesIdentity() {
        #expect(FrameRateSnap.snap(25) == 25)
        #expect(FrameRateSnap.snap(29.97) == 29.97)
        #expect(FrameRateSnap.snap(30) == 30)
        #expect(FrameRateSnap.snap(50) == 50)
        #expect(FrameRateSnap.snap(59.94) == 59.94)
        #expect(FrameRateSnap.snap(60) == 60)
        #expect(FrameRateSnap.snap(48) == 48)
    }

    @Test("Film cadence shortcut: 23.5...24.05 → 23.976 unless the rate is exactly 24")
    func filmCadencePrefers23976() {
        // Film-cadence shortcut beats the 24.0 nearest-match because
        // panels that support 24 also support 23.976; reverse isn't
        // guaranteed.
        #expect(FrameRateSnap.snap(23.976) == 23.976)
        #expect(FrameRateSnap.snap(23.97) == 23.976)
        #expect(FrameRateSnap.snap(23.98) == 23.976)
        #expect(FrameRateSnap.snap(23.99) == 23.976)
        #expect(FrameRateSnap.snap(24.01) == 23.976)
        #expect(FrameRateSnap.snap(23.5) == 23.976)
        #expect(FrameRateSnap.snap(24.05) == 23.976)
    }

    @Test("A rational 24/1 asks for 24 Hz; 24000/1001 and noisy film probes stay 23.976")
    func exactTwentyFourIsNotFilmNTSC() {
        // 24/1 played at 23.976 Hz repeats a frame every ~41.7 s.
        #expect(FrameRateSnap.snap(24.0 / 1) == 24)
        // Matroska DefaultDuration 41666667 ns (1e9 / 41666667 = 23.9999998).
        #expect(FrameRateSnap.snap(1_000_000_000.0 / 41_666_667) == 24)
        #expect(FrameRateSnap.snap(24000.0 / 1001) == 23.976)
        // Matroska DefaultDuration 41708333 ns, and 1 ms timebase estimates either side of 24.
        #expect(FrameRateSnap.snap(1_000_000_000.0 / 41_708_333) == 23.976)
        #expect(FrameRateSnap.snap(23.98) == 23.976)
        #expect(FrameRateSnap.snap(23.995) == 23.976)
        #expect(FrameRateSnap.snap(24.002) == 23.976)
    }

    @Test("The stream's rationals: 24/1 reaches 24 Hz unless r_frame_rate says 24000/1001")
    func streamRationalsResolveTwentyFour() {
        func snapped(_ avg: (Int32, Int32), _ r: (Int32, Int32)) -> Double? {
            AetherEngine.frameRate(avg: AVRational(num: avg.0, den: avg.1), r: AVRational(num: r.0, den: r.1))
                .flatMap(FrameRateSnap.snap)
        }
        #expect(snapped((24, 1), (24, 1)) == 24)
        #expect(snapped((24, 1), (0, 0)) == 24)
        #expect(snapped((0, 0), (24, 1)) == 24)
        #expect(snapped((24000, 1001), (24000, 1001)) == 23.976)
        #expect(snapped((24000, 1001), (24, 1)) == 23.976)
        // The two estimates disagree on 24 against film NTSC (a 1 ms timebase cannot tell them apart): ambiguous.
        #expect(snapped((24, 1), (24000, 1001)) == 23.976)
        // A field-rate r_frame_rate is not a disagreement about 24.
        #expect(snapped((24, 1), (48, 1)) == 24)
        #expect(snapped((30, 1), (30000, 1001)) == 30)
        #expect(snapped((0, 0), (0, 0)) == nil)
    }

    @Test("30/60 and their 1001 rates snap to themselves; 25/1 to 25")
    func exactVersusNTSCVideoRates() {
        #expect(FrameRateSnap.snap(30.0 / 1) == 30)
        #expect(FrameRateSnap.snap(30000.0 / 1001) == 29.97)
        #expect(FrameRateSnap.snap(60.0 / 1) == 60)
        #expect(FrameRateSnap.snap(60000.0 / 1001) == 59.94)
        #expect(FrameRateSnap.snap(25.0 / 1) == 25)
        #expect(FrameRateSnap.snap(50.0 / 1) == 50)
    }

    @Test("Nearby probes snap to standard within ±0.5")
    func nearestMatchWithinTolerance() {
        #expect(FrameRateSnap.snap(24.99) == 25)
        #expect(FrameRateSnap.snap(25.4) == 25)
        #expect(FrameRateSnap.snap(29.5) == 29.97)
        #expect(FrameRateSnap.snap(60.3) == 60)
    }

    @Test("Out-of-tolerance probes return nil")
    func outOfToleranceReturnsNil() {
        #expect(FrameRateSnap.snap(35) == nil)   // >0.5 from any standard rate
        #expect(FrameRateSnap.snap(45) == nil)   // between 30 and 48, >0.5 from each
        #expect(FrameRateSnap.snap(120) == nil)  // above all standard rates
    }

    @Test("Invalid inputs return nil")
    func invalidInputsReturnNil() {
        #expect(FrameRateSnap.snap(0) == nil)
        #expect(FrameRateSnap.snap(-1) == nil)
        #expect(FrameRateSnap.snap(-23.976) == nil)
        #expect(FrameRateSnap.snap(.nan) == nil)
        #expect(FrameRateSnap.snap(.infinity) == nil)
    }

    @Test("Standard set is the documented contract")
    func standardSetMatchesDocumentation() {
        // Locks the documented contract: changes here are intentional
        // API breaks for hosts that depend on a specific set.
        #expect(FrameRateSnap.standard == [23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60])
    }
}
