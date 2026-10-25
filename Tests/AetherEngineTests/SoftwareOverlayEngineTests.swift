import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// A codec AVPlayer cannot decode plays on the native route: AVPlayer is served a placeholder, the session decodes
/// the source, and the software overlay presents it (docs/software-route-gpu.md Part 1).
/// Needs `Fixtures/overlay-mpeg2.mkv` (Scripts/fetch-fixtures.sh).
@Suite("Software overlay, end to end", .serialized)
@MainActor
struct SoftwareOverlayEngineTests {
    nonisolated static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/overlay-mpeg2.mkv")
    nonisolated static var hasFixture: Bool { FileManager.default.fileExists(atPath: fixture.path) }

    @Test("MPEG-2 plays through AVPlayer with the overlay presenting the session's own decode", .enabled(if: hasFixture))
    func mpeg2PlaysInTheOverlay() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        _ = try await engine.load(url: Self.fixture, options: LoadOptions())
        let player = try #require(engine.currentAVPlayer, "the native route serves AVPlayer")
        #expect(engine.playbackBackend == .native)
        #expect(engine.nativeVideoSession?.overlayDecodeTap != nil)
        player.isMuted = true
        engine.play()
        // The overlay comes with the item, which the engine learns of on the main actor after the player has it.
        let deadline = Date().addingTimeInterval(15)
        while engine.softwareOverlay == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let renderer = try #require(engine.softwareOverlay)
        #expect(renderer.source is DecodedPictureSource)
        while renderer.counters.presented < 50, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let counters = renderer.counters
        #expect(counters.presented >= 50, "two seconds of pictures")
        #expect(counters.failed == 0)
        #expect(counters.pulled > 0, "AVPlayer decodes the placeholder")
    }
}
