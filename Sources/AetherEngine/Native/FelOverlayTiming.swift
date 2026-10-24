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
    /// First and last (host, audio, item) reading while playing, and the refresh count between them.
    private var clockFirst: (host: Double, audio: Double?, item: Double)?
    private var clockLast: (host: Double, audio: Double?, item: Double)?
    private var refreshTimes: (first: Double, last: Double, count: Int)?
    /// The refresh interval the system states for the current display mode (`CADisplayLink.duration`).
    private var statedRefresh: Double?
    private var maxDriftMs = 0.0
    private var refollows = 0

    func composed(ms: Double, leadMs lead: Double, frameDuration: Double?) {
        lock.withLock {
            composeMs.append(ms)
            leadMs.append(lead)
            if let frameDuration { self.frameDuration = frameDuration }
        }
    }

    /// One display refresh: `shown` is the presentation time of the frame on screen, nil when none is.
    /// While the clock stands still (paused, scrubbing) nothing is counted.
    func refresh(at timestamp: CFTimeInterval, stated: CFTimeInterval, shown: Double?, playing: Bool) {
        lock.withLock {
            if stated > 0 { statedRefresh = stated }
            if let lastRefresh { refreshMs.append((timestamp - lastRefresh) * 1000) }
            lastRefresh = timestamp
            if let times = refreshTimes {
                refreshTimes = (times.first, timestamp, times.count + 1)
            } else {
                refreshTimes = (timestamp, timestamp, 1)
            }
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

    /// One reading of the three clocks, at a display refresh.
    func clocks(host: Double, audio: Double?, item: Double, playing: Bool) {
        lock.withLock {
            guard playing else { clockFirst = nil; clockLast = nil; return }
            if clockFirst == nil { clockFirst = (host, audio, item) }
            clockLast = (host, audio, item)
        }
    }

    func drift(ms: Double, refollowed: Bool) {
        lock.withLock {
            if abs(ms) > abs(maxDriftMs) { maxDriftMs = ms }
            if refollowed { refollows += 1 }
        }
    }

    /// The clocks over the window: each one's rate against the host clock in parts per million, the display's
    /// measured refresh against the interval the system states for its mode and against the content's frame
    /// duration, and audio against display as how often a frame has to slip.
    func drainClocks() -> String {
        lock.withLock {
            defer {
                clockFirst = clockLast
                refreshTimes = nil
                maxDriftMs = 0
                refollows = 0
            }
            var parts: [String] = []
            var audioPPM: Double?
            if let first = clockFirst, let last = clockLast, last.host - first.host > 1 {
                let span = last.host - first.host
                if let a0 = first.audio, let a1 = last.audio {
                    audioPPM = ((a1 - a0) / span - 1) * 1e6
                    parts.append(String(format: "audio %+.1f ppm vs host", audioPPM!))
                }
                parts.append(String(format: "item %+.1f ppm vs host", ((last.item - first.item) / span - 1) * 1e6))
            }
            var displayPPM: Double?
            var period: Double?
            if let refreshes = refreshTimes, refreshes.count > 10 {
                let measured = (refreshes.last - refreshes.first) / Double(refreshes.count - 1)
                period = measured
                var text = String(format: "display %.4f ms measured", measured * 1000)
                if let stated = statedRefresh {
                    displayPPM = (stated / measured - 1) * 1e6
                    text += String(format: ", %.4f ms stated (%+.1f ppm on the host clock)", stated * 1000, displayPPM!)
                }
                if let frameDuration {
                    text += String(format: ", content frame %.4f ms (%.3f refreshes per frame)", frameDuration * 1000, frameDuration / measured)
                }
                parts.append(text)
            }
            if let audioPPM, let displayPPM, let period {
                let relative = audioPPM - displayPPM
                let minutes = abs(relative) > 0.01 ? period / (abs(relative) * 1e-6) / 60 : .infinity
                parts.append(String(format: "audio vs display %+.1f ppm (a frame slips every %.0f min)", relative, minutes))
            }
            parts.append(String(format: "synchronizer drift max %+.1f ms, follows %d", maxDriftMs, refollows))
            return "clocks: " + parts.joined(separator: "; ")
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
