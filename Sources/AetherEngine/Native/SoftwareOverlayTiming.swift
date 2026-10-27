import Foundation
import AVFoundation
import os
import QuartzCore
import IOSurface
import CoreMedia
#if os(macOS)
import AppKit
#endif

/// The software overlay's timing as its pictures reach the screen: what a frame costs us, how early it reaches the
/// renderer, and how its picture fared on screen.
///
/// The last comes from each picture's buffer coming back (``SurfaceReturnWatch``): the compositor holds a buffer in
/// use while it shows it and lets go once the next picture has replaced it, so the time between two pictures' returns
/// is how long the second stayed on screen, in whole refreshes at any display rate (at a matched rate one each; two is
/// a repeat, a picture whose buffer was never used was never shown). A return measured against the next picture's own
/// time is the release lag, constant, plus how late the next picture came on: its spread is the jitter on screen.
final class OverlayTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var pictureMs: [Double] = []
    private var leadMs: [Double] = []
    private var refreshMs: [Double] = []
    private var lastRefresh: CFTimeInterval?
    private var frameDuration: Double?
    /// First and last (host, audio, item) reading while playing, and the refresh count between them.
    private var clockFirst: (host: Double, audio: Double?, item: Double)?
    private var clockLast: (host: Double, audio: Double?, item: Double)?
    private var refreshTimes: (first: Double, last: Double, count: Int)?
    /// The refresh interval as the display link gives it, `targetTimestamp - timestamp`.
    private var statedRefresh: Double?
    /// The last picture returned: its item time, and the host and item clocks at its return.
    private var lastReturn: (item: Double, host: Double, clock: Double)?
    /// Pictures by the refreshes they stayed on screen, returned out of order, and never used.
    private var onScreen: [Int: Int] = [:]
    private var outOfOrder: [(item: Double, after: Double)] = []
    private var neverShown = 0
    /// Pictures whose return fell between two polls: the pool had reused the buffer before the watch saw it free.
    private var unseen = 0
    /// Each return measured from the next picture's item time, in ms.
    private var replacedMs: [Double] = []

    func made(ms: Double, leadMs lead: Double, frameDuration: Double?) {
        lock.withLock {
            pictureMs.append(ms)
            leadMs.append(lead)
            if let frameDuration { self.frameDuration = frameDuration }
        }
    }

    /// One display refresh, `stated` its interval by the display link.
    func refresh(at timestamp: CFTimeInterval, stated: CFTimeInterval) {
        lock.withLock {
            if stated > 0 { statedRefresh = stated }
            if let lastRefresh { refreshMs.append((timestamp - lastRefresh) * 1000) }
            lastRefresh = timestamp
            if let times = refreshTimes {
                refreshTimes = (times.first, timestamp, times.count + 1)
            } else {
                refreshTimes = (timestamp, timestamp, 1)
            }
        }
    }

    /// The picture at `item` (item seconds) came back from the compositor at `host` (host seconds), the item clock
    /// then reading `clock`; `next` is the item time of the picture after it, when one is queued. The time since the
    /// last return is this picture's time on screen only when that return was the picture before it (`follows`: no
    /// earlier picture still waiting), and only while the clock runs at about real time (not across a pause, a seek
    /// or a scan).
    func returned(item: Double, host: Double, clock: Double, next: Double?, follows: Bool) {
        lock.withLock {
            defer { lastReturn = (item, host, clock) }
            if let next { replacedMs.append((clock - next) * 1000) }
            guard let last = lastReturn else { return }
            if item < last.item { outOfOrder.append((item, last.item)); return }
            guard follows else { return }
            let hostSpan = host - last.host, itemSpan = clock - last.clock
            guard let refresh = statedRefresh, refresh > 0, hostSpan > 0, itemSpan / hostSpan > 0.5, itemSpan / hostSpan < 2
            else { return }
            onScreen[Int((hostSpan / refresh).rounded()), default: 0] += 1
        }
    }

    /// A picture whose buffer the compositor never took: it was never on screen.
    func neverUsed() { lock.withLock { neverShown += 1 } }

    /// A picture whose return the watch did not see: its buffer was reused before a poll found it free. The next
    /// return measures no time on screen, since the last one seen is not the picture before it.
    func returnUnseen() {
        lock.withLock {
            unseen += 1
            lastReturn = nil
        }
    }

    /// The presentation started over (a seek): the next return measures nothing against the last.
    func restarted() { lock.withLock { lastReturn = nil } }

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
                refreshMs.removeAll(keepingCapacity: true)
                replacedMs.removeAll(keepingCapacity: true)
                onScreen.removeAll()
                outOfOrder.removeAll()
                neverShown = 0
                unseen = 0
            }
            let refreshes = onScreen.keys.sorted().map { "\($0): \(onScreen[$0]!)" }.joined(separator: ", ")
            let disorder = outOfOrder.prefix(4).map { String(format: "%.3f after %.3f s", $0.item, $0.after) }
            return "on screen (buffers returned): pictures by refreshes on screen [\(refreshes)], "
                + "out of order \(outOfOrder.count)\(disorder.isEmpty ? "" : " (\(disorder.joined(separator: ", ")))"), "
                + "never shown \(neverShown), return not seen (buffer reused first) \(unseen); "
                + "replaced after the next picture's time \(Self.spread(replacedMs)); "
                + "refresh interval \(Self.spread(refreshMs)); picture \(Self.spread(pictureMs)); lead \(Self.spread(leadMs))"
        }
    }

    /// min / median / max in ms.
}

/// The overlay's pictures as the compositor gives their buffers back: each enqueued picture's IOSurface is watched,
/// and once the compositor has held it in use (`IOSurfaceIsInUse`, the count a buffer pool waits on before it reuses a
/// surface) and let it go, the picture has been on screen and replaced. Read every millisecond on a thread of its
/// own. A buffer never taken within `neverUsedAfter` was never shown; pictures flushed by a restart are dropped
/// unwatched.
///
/// A pool can reuse a surface within the millisecond between the compositor letting it go and the next poll, and the
/// new picture's work marks it in use again: the return is never seen. A surface is only ever reused once it is free,
/// so a surface enqueued again while an older picture on it is still watched closes that picture (``OverlayTiming/
/// returnUnseen()``), and a return with an earlier picture still waiting measures no time on screen.
final class SurfaceReturnWatch: @unchecked Sendable {
    static let pollInterval = 0.001
    static let neverUsedAfter = 2.0

    private struct Watched {
        let surface: IOSurfaceRef
        let item: Double
        let since: CFTimeInterval
        var used = false
    }

    private let lock = NSLock()
    private var watched: [Watched] = []
    private var thread: Thread?
    private let itemTimebase: CMTimebase
    private let timing: OverlayTiming

    init(itemTimebase: CMTimebase, timing: OverlayTiming) {
        self.itemTimebase = itemTimebase
        self.timing = timing
    }

    func watch(_ surface: IOSurfaceRef, item: Double) {
        let id = IOSurfaceGetID(surface)
        let reused = lock.withLock { () -> Int in
            let before = watched.count
            watched.removeAll { IOSurfaceGetID($0.surface) == id }
            watched.append(Watched(surface: surface, item: item, since: CACurrentMediaTime()))
            return before + 1 - watched.count
        }
        for _ in 0..<reused { timing.returnUnseen() }
    }

    /// The layer was flushed: what it held is never shown.
    func clear() {
        lock.withLock { watched.removeAll() }
        timing.restarted()
    }

    func start() {
        let thread = Thread { [self] in
            while !Thread.current.isCancelled {
                Thread.sleep(forTimeInterval: Self.pollInterval)
                poll()
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "aether.software-overlay.surface-returns"
        thread.start()
        self.thread = thread
    }

    func stop() { thread?.cancel() }

    private func poll() {
        let now = CACurrentMediaTime()
        var returned: [(item: Double, next: Double?, follows: Bool)] = []
        var neverUsed = 0
        lock.withLock {
            var kept: [Watched] = []
            for var entry in watched {
                if IOSurfaceIsInUse(entry.surface) {
                    entry.used = true
                    kept.append(entry)
                } else if entry.used {
                    returned.append((entry.item, nil, false))
                } else if now - entry.since > Self.neverUsedAfter {
                    neverUsed += 1
                } else {
                    kept.append(entry)
                }
            }
            watched = kept
            let waiting = kept.map(\.item)
            returned = returned.sorted { $0.item < $1.item }.map { r in
                (r.item, waiting.filter { $0 > r.item }.min(), !waiting.contains { $0 < r.item })
            }
        }
        guard !returned.isEmpty || neverUsed > 0 else { return }
        let clock = CMSyncConvertTime(CMTime(seconds: now, preferredTimescale: 1_000_000_000),
                                      from: CMClockGetHostTimeClock(), to: itemTimebase).seconds
        for r in returned { timing.returned(item: r.item, host: now, clock: clock, next: r.next, follows: r.follows) }
        for _ in 0..<neverUsed { timing.neverUsed() }
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
/// resumes (the header's sample for quiescing a display link driving an `AVPlayerItemVideoOutput`), and says when
/// the output starts a new sequence (a seek, a change of direction), so frames queued from the old one go.
final class OverlayOutputDelegate: NSObject, AVPlayerItemOutputPullDelegate, @unchecked Sendable {
    private let onWillChange: () -> Void
    private let onFlushed: () -> Void
    init(onWillChange: @escaping () -> Void, onFlushed: @escaping () -> Void) {
        self.onWillChange = onWillChange
        self.onFlushed = onFlushed
    }
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) { onWillChange() }
    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) { onFlushed() }
}
