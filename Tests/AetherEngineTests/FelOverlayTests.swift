// The FEL overlay route: AVPlayer plays a Profile 7 FEL's base layer on the native route, and
// FelOverlayRenderer composes the enhancement layer (read by FelEnhancementSource) over its picture.
import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

@Suite("FEL overlay")
struct FelOverlayTests {

    @Test("the overlay is off unless asked for")
    func optionDefaultsOff() {
        #expect(LoadOptions().felOverlay == false)
    }
}

#if DualLayerDolbyVision
extension FelOverlayTests {

    private func makeRenderer() throws -> FelOverlayRenderer {
        try #require(FelOverlayRenderer(item: AVPlayerItem(url: URL(fileURLWithPath: "/dev/null")),
                                        sourceURL: URL(fileURLWithPath: "/dev/null")))
    }

    /// AVPlayerLayer builds its private sublayers at init: an intermediate layer holding the video
    /// container and `FigSubtitleCALayer`. This pins that shape, which `install(in:)` depends on.
    @Test("the overlay goes directly below AVPlayerLayer's subtitle layer")
    func installBelowSubtitles() throws {
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        let renderer = try makeRenderer()
        defer { renderer.stop() }
        #expect(renderer.install(in: playerLayer))
        let host = try #require(renderer.layer.superlayer)
        let siblings = try #require(host.sublayers)
        let mine = try #require(siblings.firstIndex { $0 === renderer.layer })
        #expect(mine + 1 < siblings.count)
        if mine + 1 < siblings.count {
            #expect(String(describing: type(of: siblings[mine + 1])) == "FigSubtitleCALayer")
        }
        #expect(renderer.layer.frame == host.bounds)
        // It keeps the player layer's gravity, which a host's picture mode changes.
        playerLayer.videoGravity = .resizeAspectFill
        #expect(renderer.layer.videoGravity == .resizeAspectFill)
    }

    @Test("without that shape the overlay goes on top of the player layer")
    func installFallsBackToTop() throws {
        let playerLayer = AVPlayerLayer()
        playerLayer.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
        playerLayer.sublayers?.forEach { $0.isHidden = true }
        let renderer = try makeRenderer()
        defer { renderer.stop() }
        #expect(renderer.install(in: playerLayer) == false)
        #expect(renderer.layer.superlayer === playerLayer)
        #expect(renderer.layer.frame == playerLayer.bounds)
    }
}

/// On the real clips `DoviFelRealFileTests` uses (not checked in; every test skips without them).
@Suite(.offCooperativePoolOneLane)
struct FelOverlayRealFileTests {

    private static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    @Test("the enhancement source reads a bounded window ahead of the clock",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    func readsBoundedWindow() throws {
        let source = FelEnhancementSource(url: DoviFelRealFileTests.url("fel-clip-a.mkv"))
        defer { source.close() }
        source.start(at: 0)
        // The first frames arrive with their enhancement picture decoded.
        #expect(Self.waitUntil(10) { source.heldFrames.enhancement >= 10 })
        // Held: what is behind the clock by at most `keepBehindSeconds`, ahead by about `readAheadSeconds`.
        Thread.sleep(forTimeInterval: 0.5)
        let ceiling = Int((FelEnhancementSource.readAheadSeconds + FelEnhancementSource.keepBehindSeconds + 0.5) * 60)
        #expect(source.heldFrames.side <= ceiling)
        // Moving the clock trims behind it and reads further.
        for step in 1...8 {
            source.advance(to: Double(step) * 0.25)
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(Self.waitUntil(5) { source.frame(at: 2.0) != nil || source.frame(at: 2.002) != nil || source.heldFrames.side > 0 })
        #expect(source.heldFrames.side <= ceiling)
    }

    @Test("a far reposition starts over at the target",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    func repositionsFar() throws {
        let url = DoviFelRealFileTests.url("fel-clip-a.mkv")
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        let duration = demuxer.duration
        demuxer.close()
        try #require(duration > 8)
        let target = (duration / 2).rounded(.down)

        let source = FelEnhancementSource(url: url)
        defer { source.close() }
        source.start(at: 0)
        #expect(Self.waitUntil(10) { source.heldFrames.side > 0 })
        source.reposition(to: target)
        // Some frame within a second of the target arrives with its parameters and enhancement picture.
        let found = Self.waitUntil(10) {
            stride(from: target, to: target + 1, by: 0.001).contains { t in
                guard let f = source.frame(at: t) else { return false }
                return f.enhancement != nil
            }
        }
        #expect(found)
    }

    @Test("a FEL loaded with felOverlay stays native and composes over AVPlayer",
          .enabled(if: DoviFelRealFileTests.available("fel-clip-a.mkv"), DoviFelRealFileTests.needsClips))
    @MainActor
    func engineComposesOverAVPlayer() async throws {
        let engine = try AetherEngine()
        defer { engine.stop() }
        var options = LoadOptions()
        options.felOverlay = true
        _ = try await engine.load(url: DoviFelRealFileTests.url("fel-clip-a.mkv"), options: options)
        let player = try #require(engine.currentAVPlayer, "a FEL with felOverlay plays on the native route")
        player.isMuted = true
        engine.play()
        let renderer = try #require(engine.felOverlay)
        let deadline = Date().addingTimeInterval(15)
        while renderer.counters.composed < 24, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let counters = renderer.counters
        #expect(counters.composed >= 24)
        #expect(counters.composeFailed == 0)
    }
}
#endif
