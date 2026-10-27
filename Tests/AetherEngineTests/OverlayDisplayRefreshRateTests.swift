import Testing
@testable import AetherEngine

/// The refresh rate the overlay's display link asks a ProMotion panel for, from the content's frame rate.
struct OverlayDisplayRefreshRateTests {

    @Test("Film and video rates get their largest whole multiple up to 120 Hz", arguments: [
        (23.976, Float(120)), (24.0, 120), (25.0, 100), (29.97, 120), (30.0, 120),
        (48.0, 96), (50.0, 100), (59.94, 120), (60.0, 120), (120.0, 120),
    ])
    func wholeMultiple(fps: Double, expected: Float) {
        #expect(OverlayDisplayLink.refreshRate(forContentFrameRate: fps) == expected)
    }

    @Test("A rate the panel cannot hold a whole multiple of falls back to its fastest refresh")
    func outOfRange() {
        #expect(OverlayDisplayLink.refreshRate(forContentFrameRate: 0) == 120)
        #expect(OverlayDisplayLink.refreshRate(forContentFrameRate: 240) == 120)
    }
}
