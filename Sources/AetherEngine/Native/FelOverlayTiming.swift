// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import QuartzCore

/// The FEL overlay's timing as its frames reach the screen: what a frame costs us, how early it reaches the
/// renderer, and how many display refreshes it actually stays on screen. The last is the cadence the viewer
/// sees: at a matched refresh rate every frame should stay exactly one refresh; two is a hold, a frame never
/// seen is a skip. A frame on time from us and held or skipped on screen spent the difference in the
/// compositor, which has no timing API of its own.
final class FelOverlayTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var composeMs: [Double] = []
    private var leadMs: [Double] = []
    private var refreshMs: [Double] = []
    /// Refreshes on screen -> frames.
    private var holds: [Int: Int] = [:]
    private var skipped = 0
    private var lastShown: Double?
    private var lastShownRefreshes = 0
    private var lastRefresh: CFTimeInterval?
    private var frameDuration: Double?

    func composed(ms: Double, leadMs lead: Double, frameDuration: Double?) {
        lock.withLock {
            composeMs.append(ms)
            leadMs.append(lead)
            if let frameDuration { self.frameDuration = frameDuration }
        }
    }

    /// One display refresh: `shown` is the presentation time of the frame on screen, nil when none is.
    /// While the clock stands still (paused, scrubbing) nothing is counted.
    func refresh(at timestamp: CFTimeInterval, shown: Double?, playing: Bool) {
        lock.withLock {
            if let lastRefresh { refreshMs.append((timestamp - lastRefresh) * 1000) }
            lastRefresh = timestamp
            guard playing, let shown else {
                lastShown = nil
                lastShownRefreshes = 0
                return
            }
            if shown == lastShown {
                lastShownRefreshes += 1
                return
            }
            if let last = lastShown {
                holds[lastShownRefreshes, default: 0] += 1
                if let frameDuration, frameDuration > 0, shown > last {
                    let missing = Int(((shown - last) / frameDuration).rounded()) - 1
                    if missing > 0, missing < 12 { skipped += missing }
                }
            }
            lastShown = shown
            lastShownRefreshes = 1
        }
    }

    /// The window's summary, and a fresh window.
    func drain() -> String {
        lock.withLock {
            defer {
                composeMs.removeAll(keepingCapacity: true)
                leadMs.removeAll(keepingCapacity: true)
                refreshMs.removeAll(keepingCapacity: true)
                holds.removeAll()
                skipped = 0
            }
            let held = holds.filter { $0.key >= 3 }.values.reduce(0, +)
            return "on screen: 1 refresh \(holds[1] ?? 0), 2 refreshes \(holds[2] ?? 0), 3+ \(held), skipped \(skipped); "
                + "refresh interval \(Self.spread(refreshMs)); compose \(Self.spread(composeMs)); "
                + "lead \(Self.spread(leadMs))"
        }
    }

    /// min / median / max in ms.
    private static func spread(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        return String(format: "%.1f/%.1f/%.1f ms", sorted.first!, sorted[sorted.count / 2], sorted.last!)
    }
}

#if os(tvOS) || os(iOS)
/// A display link on its own thread, for reading what is on screen at every refresh.
final class FelOverlayRefreshProbe: NSObject, @unchecked Sendable {
    private let onRefresh: (CADisplayLink) -> Void
    private var thread: Thread?

    init(onRefresh: @escaping (CADisplayLink) -> Void) {
        self.onRefresh = onRefresh
    }

    func start() {
        let thread = Thread { [self] in
            let link = CADisplayLink(target: self, selector: #selector(fire(_:)))
            link.add(to: .current, forMode: .common)
            while !Thread.current.isCancelled {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            link.invalidate()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "aether.fel-overlay.refresh"
        thread.start()
        self.thread = thread
    }

    func stop() { thread?.cancel() }

    @objc private func fire(_ link: CADisplayLink) { onRefresh(link) }
}
#endif
#endif
