import Testing
@testable import AetherEngine

/// On an overlay session the AVPlayerLayer shows the placeholder stream, so its readiness says nothing about the picture
/// the viewer sees: a host lifting its poster on it showed black until the overlay's first picture.
@Suite("Rendered-frame evidence on overlay sessions", .timeLimit(.minutes(1)))
@MainActor
struct RenderedVideoFrameOverlayTests {

    @Test("an overlay that has presented nothing is no evidence, whatever the native latch says (#901)")
    func overlayWithoutPictureIsNotRendered() async throws {
        let engine = try AetherEngine()
        let overlay = try OverlayRendererFixture()
        defer { overlay.close() }
        engine.playbackBackend = .native
        engine.hasFirstFrameReadyForDisplay = true
        engine.softwareOverlay = overlay.renderer
        #expect(overlay.renderer.counters.presented == 0)
        #expect(await engine.hasRenderedVideoFrame() == false)
        engine.softwareOverlay = nil
    }
}
