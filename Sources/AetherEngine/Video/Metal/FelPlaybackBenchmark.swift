// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import AVFoundation
import Foundation

/// A Dolby Vision FEL title played as the app plays it, timed by the overlay's own instruments: the engine loads it
/// with `LoadOptions.felOverlay`, AVPlayer decodes the base layer and the session the enhancement layer, the overlay
/// pulls ahead and composes in batches, and every overlay and composer log window of the run is collected (the
/// per-frame stages, what reached the screen, the clocks, the display layer's drops). Nothing is simulated: the cost it
/// reports is playback's, on the device it runs on, so a change can be measured without someone watching the TV.
///
/// The scenario: playback from `startSeconds`, a pause, playback on, a seek, playback on. Audio is muted.
public enum FelPlaybackBenchmark {

    /// Seconds of each phase of a run.
    public struct Scenario: Sendable {
        public var play: Double
        public var pause: Double
        public var afterPause: Double
        /// How far the seek moves from where playback is, negative for back.
        public var seekBy: Double
        public var afterSeek: Double

        public init(play: Double, pause: Double, afterPause: Double, seekBy: Double, afterSeek: Double) {
            self.play = play; self.pause = pause; self.afterPause = afterPause; self.seekBy = seekBy; self.afterSeek = afterSeek
        }

        /// A film: half a minute of playback, a pause, a minute's seek forward.
        public static let film = Scenario(play: 30, pause: 3, afterPause: 10, seekBy: 60, afterSeek: 15)
    }

    /// Plays `url` (with `httpHeaders` for a remote one) through the scenario and returns the run's `[SoftwareOverlay]`
    /// and `[DoviFelComposer]` lines, each also handed to `emit` as it is logged, then the overlay's final counters.
    @MainActor
    public static func run(url: URL, httpHeaders: [String: String] = [:], startSeconds: Double = 0,
                           scenario: Scenario = .film,
                           emit: @escaping @Sendable (String) -> Void = { print($0) }) async -> String {
        let lines = Lines(emit: emit)
        let previous = EngineLog.handler
        EngineLog.handler = { line in
            previous?(line)
            if line.contains("[SoftwareOverlay]") || line.contains("[DoviFelComposer]") || line.contains("[GPU]") {
                lines.add(line)
            }
        }
        defer { EngineLog.handler = previous }
        lines.add(String(format: "[bench] FEL playback from %.0f s: play %.0f s, pause %.0f s, play %.0f s, seek %+.0f s, play %.0f s",
                         startSeconds, scenario.play, scenario.pause, scenario.afterPause, scenario.seekBy, scenario.afterSeek))
        do {
            let engine = try AetherEngine()
            defer { engine.stop() }
            var options = LoadOptions()
            options.felOverlay = true
            options.httpHeaders = httpHeaders
            _ = try await engine.load(url: url, startPosition: startSeconds > 0 ? startSeconds : nil, options: options)
            guard let player = engine.currentAVPlayer else {
                lines.add("[bench] failed: the title did not play on the native route")
                return lines.joined
            }
            player.isMuted = true
            engine.play()
            try await Task.sleep(for: .seconds(scenario.play))
            lines.add("[bench] pause")
            engine.pause()
            try await Task.sleep(for: .seconds(scenario.pause))
            lines.add("[bench] resume")
            engine.play()
            try await Task.sleep(for: .seconds(scenario.afterPause))
            let target = max(0, engine.currentTime + scenario.seekBy)
            lines.add(String(format: "[bench] seek to %.1f s", target))
            await engine.seek(to: target)
            try await Task.sleep(for: .seconds(scenario.afterSeek))
            if let renderer = engine.softwareOverlay {
                let c = renderer.counters
                lines.add("[bench] overlay totals: pulled \(c.pulled), presented \(c.presented), skipped \(c.skipped), "
                          + "late \(c.late), stale refreshes \(c.staleRefreshes), not ready \(c.notReady), failed \(c.failed)")
            } else {
                lines.add("[bench] failed: no FEL overlay attached")
            }
        } catch {
            lines.add("[bench] failed: \(error)")
        }
        return lines.joined
    }

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        private let emit: @Sendable (String) -> Void

        init(emit: @escaping @Sendable (String) -> Void) { self.emit = emit }

        func add(_ line: String) {
            lock.withLock { lines.append(line) }
            emit(line)
        }

        var joined: String { lock.withLock { lines.joined(separator: "\n") } }
    }
}
#endif
