import AVFoundation
import Foundation
@testable import AetherEngine

/// Every picture a software overlay hands its layer (`SoftwareOverlayRenderer.onPresented`), with the item clock at
/// the moment it was handed over, and the checks the overlay's presentation has to pass on a run of them.
final class OverlayPresentations: @unchecked Sendable {
    struct Entry: Sendable {
        /// The picture's own item time, and the item clock when it reached the layer.
        let time: Double
        let clock: Double
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    init(_ renderer: SoftwareOverlayRenderer, timebase: CMTimebase) {
        renderer.onPresented = { [self] time, _ in
            let clock = CMTimebaseGetTime(timebase).seconds
            lock.withLock { entries.append(Entry(time: time.seconds, clock: clock)) }
        }
    }

    var all: [Entry] { lock.withLock { entries } }
    var count: Int { lock.withLock { entries.count } }

    /// Waits until a picture at or past `seconds`, and short of `before`, has been presented after the first `after`
    /// entries. The bound keeps pictures queued for a position a seek left from counting.
    func wait(forPictureAt seconds: Double, before: Double = .infinity, after: Int = 0,
              timeout: TimeInterval = 15) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if all.dropFirst(after).contains(where: { $0.time >= seconds && $0.time < before }) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// What is wrong with a run of presented pictures, empty when nothing is: every step between pictures is one
    /// picture `interval` (none presented twice, none out of order, none left out), and from `steadyFrom` (item
    /// seconds) on every picture reaches the layer ahead of its time and no further ahead than the renderer's
    /// look-ahead. Times are whole milliseconds in some containers, so a step may be off by one.
    static func faults(in run: ArraySlice<Entry>, interval: Double, steadyFrom: Double) -> [String] {
        var faults: [String] = []
        for (a, b) in zip(run, run.dropFirst()) where abs((b.time - a.time) - interval) > 0.0015 {
            faults.append(String(format: "step %.4f -> %.4f s", a.time, b.time))
        }
        let ceiling = Double(SoftwareOverlayRenderer.lookaheadFrames) * interval + 0.005
        for e in run where e.time >= steadyFrom {
            let lead = e.time - e.clock
            if lead <= 0 || lead > ceiling { faults.append(String(format: "%.4f s presented %.1f ms ahead", e.time, lead * 1000)) }
        }
        return faults
    }

    /// The entries after the first `after`, from the first picture of the position a seek to `target` reached: the
    /// pictures before it were queued for the position the seek left.
    func run(afterSeekTo target: Double, after: Int, interval: Double) -> ArraySlice<Entry> {
        let later = all.dropFirst(after)
        guard let start = later.firstIndex(where: { abs($0.time - target) <= max(interval, 0.25) }) else { return [] }
        return later[start...]
    }
}
