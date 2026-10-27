import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// A codec AVPlayer cannot decode plays on the native route: AVPlayer is served a placeholder, the session decodes
/// the source, and the software overlay presents it (docs/software-route-gpu.md Part 1). Needs the
/// `Fixtures/overlay-mpeg2*` clips (Scripts/fetch-fixtures.sh).
@Suite("Software overlay, end to end", .serialized)
@MainActor
struct SoftwareOverlayEngineTests {
    nonisolated static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    /// A clip and the spacing of the pictures the overlay shows for it, which need not be the placeholder's.
    struct Clip: Sendable, CustomTestStringConvertible {
        let file: String
        let interval: Double
        let testDescription: String
        var url: URL { SoftwareOverlayEngineTests.fixtures.appendingPathComponent(file) }
        var available: Bool { FileManager.default.fileExists(atPath: url.path) }
    }

    nonisolated static let clips = [
        Clip(file: "overlay-mpeg2.mkv", interval: 1.0 / 25, testDescription: "progressive, 25 pictures a second"),
        Clip(file: "overlay-mpeg2-interlaced.mkv", interval: 1.0 / 50,
             testDescription: "576i25 deinterlaced at the field rate, 50 pictures a second"),
        Clip(file: "overlay-mpeg2-telecine.mkv", interval: 1001.0 / 24000,
             testDescription: "3:2 hard telecine inverse telecined to the film rate"),
        Clip(file: "overlay-mpeg2-soft-telecine.ts", interval: 1001.0 / 24000,
             testDescription: "soft telecine on the film grid"),
    ]

    /// Loads `clip`, plays it muted and attaches to its overlay once the engine has it.
    private func play(_ clip: Clip) async throws -> (AetherEngine, SoftwareOverlayRenderer, OverlayPresentations) {
        let engine = try AetherEngine()
        _ = try await engine.load(url: clip.url, options: LoadOptions())
        let player = try #require(engine.currentAVPlayer, "the native route serves AVPlayer")
        #expect(engine.playbackBackend == .native)
        #expect(engine.nativeVideoSession?.overlayDecodeTap != nil)
        player.isMuted = true
        engine.play()
        // The overlay comes with the item, which the engine learns of on the main actor after the player has it.
        let deadline = Date().addingTimeInterval(15)
        while engine.softwareOverlay == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let renderer = try #require(engine.softwareOverlay)
        let timebase = try #require(player.currentItem?.timebase)
        return (engine, renderer, OverlayPresentations(renderer, timebase: timebase))
    }

    @Test("every picture reaches the layer once, in order, ahead of its time", arguments: clips)
    func everyPictureOnceInOrder(_ clip: Clip) async throws {
        try #require(clip.available, "Scripts/fetch-fixtures.sh makes \(clip.file)")
        let (engine, renderer, presented) = try await play(clip)
        defer { engine.stop() }
        #expect(renderer.source is DecodedPictureSource)
        #expect(try await presented.wait(forPictureAt: 0))
        let first = try #require(presented.all.first?.time)
        #expect(try await presented.wait(forPictureAt: first + 3))
        let entries = presented.all
        let faults = OverlayPresentations.faults(in: entries[...], interval: clip.interval, steadyFrom: first + 0.5)
        #expect(faults.isEmpty, "\(faults.count) faults: \(faults.prefix(8))")
        let counters = renderer.counters
        #expect(counters.failed == 0)
        #expect(counters.pulled > 0, "AVPlayer decodes the placeholder")
    }

    @Test("a seek forward, back, and while paused presents its target and runs on from it", arguments: clips)
    func seeks(_ clip: Clip) async throws {
        try #require(clip.available, "Scripts/fetch-fixtures.sh makes \(clip.file)")
        let (engine, _, presented) = try await play(clip)
        defer { engine.stop() }
        #expect(try await presented.wait(forPictureAt: 2))

        for target in [5.0, 1.0] {
            let before = presented.count
            await engine.seek(to: target)
            #expect(try await presented.wait(forPictureAt: target + 1.5, before: target + 3, after: before), "seek to \(target)")
            let run = presented.run(afterSeekTo: target, after: before, interval: clip.interval)
            // The picture on screen at the clock it reached the layer at, by the decode's hold rule: no later than the
            // target's own, and the one after it no more than the hold overdue then.
            let first = try #require(run.first, "a picture near \(target) after the seek")
            let overdueMs = (first.clock - (first.time + clip.interval)) * 1000
            #expect(first.time <= target + clip.interval + 0.002
                        && overdueMs <= OverlayPacketTap<Double>.heldPastSeconds * 1000 + 2,
                    "the first picture after the seek to \(target) is at \(first.time), clock \(first.clock)")
            let faults = OverlayPresentations.faults(in: run, interval: clip.interval, steadyFrom: target + 0.5)
            #expect(faults.isEmpty, "after the seek to \(target), \(faults.count) faults: \(faults.prefix(8))")
        }

        engine.pause()
        try await Task.sleep(for: .milliseconds(300))
        let before = presented.count
        let target = 3.0
        await engine.seek(to: target)
        try await Task.sleep(for: .seconds(2))
        let shown = presented.all.dropFirst(before)
        #expect(shown.contains { $0.time >= target - clip.interval - 0.002 && $0.time <= target + 0.002 },
                "paused, the seek to \(target) presents the picture there; presented \(shown.map(\.time).prefix(12))")
    }
}
