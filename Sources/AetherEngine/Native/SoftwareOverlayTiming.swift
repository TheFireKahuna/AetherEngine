import Foundation
import AVFoundation
import os
import QuartzCore
#if os(macOS)
import AppKit
#endif

/// The software overlay's timing as its pictures reach the screen: what a frame costs us, how early it reaches the
/// renderer, and how many display refreshes it actually stays on screen. The last is the cadence the viewer
/// sees: at a matched refresh rate every frame should stay exactly one refresh; two is a hold, a frame never
/// seen is a skip. A frame on time from us and held or skipped on screen spent the difference in the
/// compositor, which has no timing API of its own.
final class OverlayTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var pictureMs: [Double] = []
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
    /// The refresh interval as the display link gives it, `targetTimestamp - timestamp`.
    private var statedRefresh: Double?
    /// The displayed frame's item time minus the item clock at that refresh: the picture against the audio.
    private var offsetMs: [Double] = []

    func made(ms: Double, leadMs lead: Double, frameDuration: Double?) {
        lock.withLock {
            pictureMs.append(ms)
            leadMs.append(lead)
            if let frameDuration { self.frameDuration = frameDuration }
        }
    }

    /// One display refresh: `shown` is the presentation time of the frame on screen, nil when none is.
    /// While the clock stands still (paused, scrubbing) nothing is counted.
    func refresh(at timestamp: CFTimeInterval, stated: CFTimeInterval, shown: Double?, offsetMs offset: Double?, playing: Bool) {
        lock.withLock {
            if stated > 0 { statedRefresh = stated }
            if playing, let offset { offsetMs.append(offset) }
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

    /// The clocks over the window: each one's rate against the host clock in parts per million, the display's
    /// measured refresh against the interval the system states for its mode and against the content's frame
    /// duration, and audio against display as how often a frame has to slip.
    func drainClocks() -> String {
        lock.withLock {
            defer {
                clockFirst = clockLast
                refreshTimes = nil
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
                    text += String(format: ", %.4f ms per refresh by targetTimestamp (%+.1f ppm)", stated * 1000, displayPPM!)
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
            return "clocks: " + parts.joined(separator: "; ")
        }
    }

    /// The window's summary, and a fresh window.
    func drain() -> String {
        lock.withLock {
            defer {
                pictureMs.removeAll(keepingCapacity: true)
                leadMs.removeAll(keepingCapacity: true)
                offsetMs.removeAll(keepingCapacity: true)
                refreshMs.removeAll(keepingCapacity: true)
                holds.removeAll()
                skipped = 0
            }
            let held = holds.filter { $0.key >= 3 }.values.reduce(0, +)
            return "on screen: 1 refresh \(holds[1] ?? 0), 2 refreshes \(holds[2] ?? 0), 3+ \(held), skipped \(skipped); "
                + "refresh interval \(Self.spread(refreshMs)); picture \(Self.spread(pictureMs)); "
                + "lead \(Self.spread(leadMs)); picture vs audio clock \(Self.spread(offsetMs))"
        }
    }

    /// min / median / max in ms.
    static func spread(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "-" }
        let sorted = values.sorted()
        return String(format: "%.1f/%.1f/%.1f ms", sorted.first!, sorted[sorted.count / 2], sorted.last!)
    }
}

/// What each stage of making an overlay picture costs per frame, min / median / max over a log window, in the
/// order the stages were first recorded. A window nobody drains keeps only its latest samples.
final class StageTimes: @unchecked Sendable {
    /// The still and thumbnail work that shares the GPU and the video decoder with playback (I-frame stills, scrub
    /// and chapter thumbnails, stills read off the source), each job's time; the overlay's log drains it beside its
    /// own stages.
    static let alongsidePlayback = StageTimes()

    private static let maxSamples = 4096
    private let lock = NSLock()
    private var order: [String] = []
    private var samples: [String: [Double]] = [:]

    func record(_ stage: String, ms: Double) {
        guard ms.isFinite else { return }
        lock.withLock {
            if samples[stage] == nil { order.append(stage) }
            samples[stage, default: []].append(ms)
            if samples[stage]!.count > Self.maxSamples { samples[stage]!.removeFirst(Self.maxSamples / 2) }
        }
    }

    /// The window's stages, and a fresh window; nil when nothing was recorded.
    func drain() -> String? {
        lock.withLock {
            defer { for stage in order { samples[stage]?.removeAll(keepingCapacity: true) } }
            let parts = order.compactMap { stage in
                samples[stage].flatMap { $0.isEmpty ? nil : "\(stage) \($0.count)x \(OverlayTiming.spread($0))" }
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }
}

/// The display link that drives the overlay, on its own thread. At every refresh it reports `timestamp`
/// (when the last frame displayed) and `targetTimestamp` (when the next one displays), in host time; their
/// difference is the actual refresh interval (`duration` is the interval at the screen's maximum rate). It
/// can be paused while nothing changes. On a Mac without a screen (tests), a 60 Hz timer stands in.
final class OverlayDisplayLink: NSObject, @unchecked Sendable {
    private let onRefresh: (_ timestamp: CFTimeInterval, _ targetTimestamp: CFTimeInterval) -> Void
    private var thread: Thread?
    private var link: CADisplayLink?
    private let pausedState = OSAllocatedUnfairLock(initialState: false)

    init(onRefresh: @escaping (_ timestamp: CFTimeInterval, _ targetTimestamp: CFTimeInterval) -> Void) {
        self.onRefresh = onRefresh
    }

    func start() {
        let thread = Thread { [self] in
            let link = makeLink()
            self.link = link
            link?.add(to: .current, forMode: .common)
            var fallback: Timer?
            if link == nil {
                fallback = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                    guard let self, !self.pausedState.withLock({ $0 }) else { return }
                    let now = CACurrentMediaTime()
                    self.onRefresh(now, now + 1.0 / 60)
                }
                RunLoop.current.add(fallback!, forMode: .common)
            }
            while !Thread.current.isCancelled {
                RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            }
            link?.invalidate()
            fallback?.invalidate()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "aether.software-overlay.display-link"
        thread.start()
        self.thread = thread
    }

    func stop() { thread?.cancel() }

    /// Pauses or resumes the callbacks, on the display link's own thread.
    func setPaused(_ paused: Bool) {
        guard pausedState.withLock({ state in
            defer { state = paused }
            return state != paused
        }), let thread else { return }
        perform(#selector(applyPaused), on: thread, with: nil, waitUntilDone: false)
    }

    @objc private func applyPaused() { link?.isPaused = pausedState.withLock { $0 } }

    private func makeLink() -> CADisplayLink? {
        #if os(macOS)
        return NSScreen.main?.displayLink(target: self, selector: #selector(fire(_:)))
        #else
        return CADisplayLink(target: self, selector: #selector(fire(_:)))
        #endif
    }

    @objc private func fire(_ link: CADisplayLink) { onRefresh(link.timestamp, link.targetTimestamp) }
}

/// The video output's pull delegate: AVFoundation says new frames are coming, so a paused display link
/// resumes (the header's sample for quiescing a display link driving an `AVPlayerItemVideoOutput`).
final class OverlayOutputDelegate: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    private let onWillChange: () -> Void
    init(onWillChange: @escaping () -> Void) { self.onWillChange = onWillChange }
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) { onWillChange() }
}
