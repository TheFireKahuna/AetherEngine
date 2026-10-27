import Testing
@testable import AetherEngine

@Suite("Local rendered-frame evidence", .timeLimit(.minutes(1)))
@MainActor
struct RenderedVideoFrameTests {

    @Test("No session has no presented frame")
    func idleEngine() async throws {
        let engine = try AetherEngine()
        #expect(await engine.hasRenderedVideoFrame() == false)
    }
}
