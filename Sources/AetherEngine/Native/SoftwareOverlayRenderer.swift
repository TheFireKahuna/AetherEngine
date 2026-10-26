import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import IOSurface
import os

/// How the overlay's pictures follow AVPlayer.
enum OverlayPacing: Equatable {
    /// One picture for each frame AVPlayer's output hands over, made from it (`makePicture`), in order.
    case outputFrames
    /// AVPlayer's frames as they are: the I-frame tier's stills while it scans.
    case showOutput
    /// The source's own pictures at their own times (`pictures(after:at:)`), whatever AVPlayer decodes.
    case clock
}

/// What ``SoftwareOverlayRenderer`` shows in place of AVPlayer's picture.
protocol OverlayFrameSource: AnyObject, Sendable {
    /// How AVPlayer hands over the frames it decodes (`AVPlayerItemVideoOutput`'s pixel buffer attributes).
    var outputAttributes: [String: any Sendable] { get }
    /// The renderer's recommended pixel buffer attributes, for the pool the source's pictures come from.
    func followRenderer(_ attributes: [String: Any])
    /// AVPlayer's clock, in item seconds: what the source works toward.
    func advance(to itemSeconds: Double)
    /// How the pictures follow AVPlayer while the item plays at `rate`.
    func pacing(atRate rate: Double) -> OverlayPacing
    /// `.outputFrames`: the item time of the frame after `itemSeconds` as AVPlayer is served them, in whole
    /// milliseconds; nil while it is not known.
    func frameTime(after itemSeconds: Double) -> Double?
    /// `.outputFrames`: the picture for AVPlayer's frame `output` at `frameTime`, handed to `done` on any thread (nil
    /// when it could not be made). False, with `done` never called, when the source has nothing for that time yet:
    /// the renderer offers the same frame again at the next refresh. `output` is valid until `done` runs.
    func makePicture(from output: CVPixelBuffer, at frameTime: CMTime,
                     done: @escaping @Sendable (CVPixelBuffer?) -> Void) -> Bool
    /// `.clock`: the source's pictures to queue after `last` (nil when none is queued), in order, from the one on
    /// screen at `itemSeconds` on; empty while the source has none to show.
    func pictures(after last: CMTime?, at itemSeconds: Double) -> [(picture: CVPixelBuffer, time: CMTime)]
    /// The source's own state, for the renderer's periodic log line.
    func logSummary() -> String
    /// What the source's stages cost per frame since the last call (``StageTimes``), nil when it measures none.
    func drainStageTimes() -> String?
}

/// Draws our own picture over an `AVPlayer` whose rendering is suppressed: a Profile 7 FEL's composition over the
/// base layer AVPlayer plays (``FelCompositionSource``), or the session's own decode of a stream AVPlayer is served
/// a placeholder of (``DecodedPictureSource``).
///
/// AVPlayer keeps everything it is good at (loading, seeking, audio, AVKit's transport, menus and native
/// subtitles); with `suppressesPlayerRendering` it renders nothing itself and hands every decoded frame to an
/// `AVPlayerItemVideoOutput` instead.
///
/// The layer's timebase follows the item's one for one (a child timebase at rate 1), so a picture stamped with its
/// item time shows when AVPlayer would have shown it, against the clock AVPlayer keeps for the audio output, and
/// pauses, seeks, stalls and rate changes reach the layer with no second clock to steer. The renderer works ahead
/// of that clock: at each display refresh it tops the layer up to ``lookaheadFrames`` pictures ahead, taking
/// AVPlayer's frames off the output in order, each at its own time and as soon as AVPlayer has decoded it, and having
/// the ``OverlayFrameSource`` make the picture for each (or, paced by the clock, queueing the source's own pictures).
/// The layer then chooses the refresh for every picture itself, as AVPlayer's own video path does.
///
/// Scanning (the I-frame tier's stills), the layer runs on the host clock instead, and each still is stamped for the
/// refresh it was chosen for.
///
/// The layer belongs inside the `AVPlayerLayer`, between the video and the subtitle layers, so native
/// subtitles stay on top (``install(in:)``).
public final class SoftwareOverlayRenderer: @unchecked Sendable {

    public struct Counters: Sendable {
        public var pulled = 0
        public var presented = 0
        /// Frames the source had nothing for yet.
        public var notReady = 0
        /// Frames the source could not make a picture for.
        public var failed = 0
        /// Pictures that reached the layer after their own time.
        public var late = 0
        /// Frames AVPlayer decoded that never reached the layer.
        public var skipped = 0
        /// Refreshes passed over because a later one was already waiting behind them.
        public var staleRefreshes = 0
        /// Refreshes that left the layer at the look-ahead, and refreshes that ended at the newest frame AVPlayer had
        /// decoded short of it.
        public var atLookahead = 0
        public var atOutputEdge = 0
        /// Longest picture and longest gap between refreshes since the last log line, in ms.
        public var maxPictureMs = 0.0
        public var maxRefreshGapMs = 0.0
    }

    /// Pictures queued on the layer or being made, ahead of the clock. The display layer drops frames it is handed
    /// with too little lead (`SampleBufferRenderer.felVideoLookaheadFrames`, measured on the Apple TV), and the
    /// composer's pool is sized for this many beside the one on screen and those in flight
    /// (`DoviFelComposer.outputPoolAllocationThreshold`).
    static let lookaheadFrames = SampleBufferRenderer.felVideoLookaheadFrames

    public let layer = AVSampleBufferDisplayLayer()
    /// The layer's queue, taken once at construction: `AVSampleBufferDisplayLayer` is the main actor's, its renderer
    /// is not, and the render queue enqueues through it.
    private let videoRenderer: AVSampleBufferVideoRenderer
    private let rendererIO: VideoRendererIO
    let source: any OverlayFrameSource
    /// Test seam: every presented picture with the item time it shows, on the render queue.
    public var onPresented: (@Sendable (CMTime, CVPixelBuffer) -> Void)?

    /// With no new frame for this long (paused, a still), the display link pauses until the output says frames
    /// are coming again.
    static let quiesceAfter = 0.5

    private let output: AVPlayerItemVideoOutput
    private weak var item: AVPlayerItem?
    private let queue = DispatchQueue(label: "aether.software-overlay", qos: .userInteractive)
    private var displayLink: OverlayDisplayLink?
    private var outputDelegate: OverlayOutputDelegate?
    private var lastNewFrame = CACurrentMediaTime()
    /// The latest refresh the display link has handed to the render queue.
    private let latestRefresh = OSAllocatedUnfairLock(initialState: UInt64(0))
    private var jumpObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var gravityObservation: NSKeyValueObservation?
    private let timing = OverlayTiming()
    /// The renderer's own stages per frame: the refresh on the render queue, taking AVPlayer's frame, handing it to
    /// the source, and the made picture's hop back to the render queue.
    private let stages = StageTimes()
    private var itemTimebase: CMTimebase?
    /// The layer's control timebase: the item's, followed one for one, or the host clock while scanning.
    private var layerTimebase: CMTimebase?
    /// The audio output's clock, for the clock readings in the log.
    private var audioClock: CMClock?
    private let lifecycle = NSLock()
    private var started = false
    private var stopped = false

    // Render-queue state.
    /// The layer follows the host clock (scanning) rather than the item's.
    private var followsHost = false
    /// The last frame taken off the output (or shown, paced by the clock).
    private var lastPulled = CMTime.invalid
    /// The newest picture enqueued, on the layer's timeline.
    private var lastQueued = CMTime.invalid
    /// Item times of the pictures enqueued and not yet passed by the clock, oldest first.
    private var queued: [CMTime] = []
    /// The newest enqueued picture the clock has reached: the one on screen.
    private var onScreen = CMTime.invalid
    /// The item clock as last read on the render queue.
    private var lastClock = CMTime.invalid
    /// Pictures handed to the source and not yet back.
    private var making = 0
    /// A frame the source had nothing for yet, offered again before the next is taken.
    private var waiting: (frame: OutputFrame, time: CMTime)?
    /// Bumped on every restart: a picture finishing for an older generation is for a left position.
    private var generation = 0
    /// The mean step between pulled frames: the stream's frame duration (container timestamps can be whole
    /// milliseconds, so single steps are not), for counting skips.
    private var frameSteps: (sum: Double, count: Int) = (0, 0)
    private var frameDuration: Double? { frameSteps.count > 0 ? frameSteps.sum / Double(frameSteps.count) : nil }
    private var lastRefresh: CFTimeInterval?
    private var lastLog = CACurrentMediaTime()
    private let countersLock = NSLock()
    private var _counters = Counters()

    public var counters: Counters { countersLock.withLock { _counters } }

    init(item: AVPlayerItem, source: any OverlayFrameSource) {
        self.item = item
        self.source = source
        videoRenderer = layer.sampleBufferRenderer
        rendererIO = VideoRendererIO(renderer: videoRenderer)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: source.outputAttributes)
        // The overlay is the item's picture: AVPlayer keeps decoding into the output but stops rendering its
        // own, so one video pipeline presents.
        output.suppressesPlayerRendering = true
        layer.videoGravity = .resizeAspect
        // AVPlayer no longer presents video, so the layer says that video is playing.
        layer.preventsDisplaySleepDuringVideoPlayback = true
        videoRenderer.presentationTimeExpectation = .monotonicallyIncreasing
    }

    deinit { stop() }

    /// Attaches to the item and starts, now or as soon as the item is ready to play (its timebase exists).
    public func start() {
        guard let item else { return }
        if item.timebase != nil {
            begin()
            return
        }
        readyObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            self?.begin()
        }
    }

    private func begin() {
        lifecycle.lock()
        guard !started, !stopped, let item, let itemTimebase = item.timebase else { lifecycle.unlock(); return }
        started = true
        lifecycle.unlock()
        readyObservation?.invalidate()
        readyObservation = nil
        item.add(output)
        self.itemTimebase = itemTimebase
        audioClock = Self.audioOutputClock() ?? CMTimebaseCopyUltimateSourceClock(itemTimebase)
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault, sourceTimebase: itemTimebase, timebaseOut: &timebase)
        if let timebase {
            Self.follow(itemTimebase, with: timebase)
            layerTimebase = timebase
            layer.controlTimebase = timebase
        }
        source.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
        // A seek moves the item's clock before its first frame decodes: point the source there at once.
        jumpObserver = NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: itemTimebase, queue: nil) { [weak self] _ in
            guard let self else { return }
            let clock = CMTimebaseGetTime(itemTimebase)
            let rate = CMTimebaseGetRate(itemTimebase)
            self.source.advance(to: clock.seconds)
            self.queue.async {
                let from = self.lastClock.isValid ? String(format: "%.3f", self.lastClock.seconds) : "none"
                self.clockMoved(to: clock, running: rate != 0,
                                because: String(format: "the item's clock jumped from %@ to %.3f s at rate %g",
                                                from, clock.seconds, rate))
                // A seek while paused still shows its target, when the source has it.
                self.lastNewFrame = CACurrentMediaTime()
                self.displayLink?.setPaused(false)
            }
        }
        // The source's pool is built the way the renderer asks frames to be made (CoreAnimation-compatible
        // surfaces, its cache mode): a picture the compositor can take as it is.
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            source.followRenderer(videoRenderer.__recommendedPixelBufferAttributes)
        }
        logDecoderFormat(item: item)
        let link = OverlayDisplayLink { [weak self] timestamp, targetTimestamp in
            guard let self else { return }
            let fired = CACurrentMediaTime()
            let sequence = self.latestRefresh.withLock { latest -> UInt64 in
                latest &+= 1
                return latest
            }
            self.queue.async {
                // Only the newest refresh tops the layer up. A render queue held up (a compose slot, a long
                // picture) would otherwise work through every refresh queued meanwhile for nothing.
                let stale = self.latestRefresh.withLock({ $0 }) != sequence
                if stale { self.countersLock.withLock { self._counters.staleRefreshes += 1 } }
                let start = CACurrentMediaTime()
                self.stages.record("refresh wait", ms: (start - fired) * 1000)
                self.refresh(at: timestamp, target: targetTimestamp, fills: !stale)
                self.stages.record("refresh", ms: (CACurrentMediaTime() - start) * 1000)
            }
        }
        let delegate = OverlayOutputDelegate(onWillChange: { [weak self] in
            self?.lastNewFrame = CACurrentMediaTime()
            self?.displayLink?.setPaused(false)
        }, onFlushed: { [weak self] in
            guard let self, let itemTimebase = self.itemTimebase else { return }
            self.clockMoved(to: CMTimebaseGetTime(itemTimebase), running: false, because: "the output started a new sequence")
        })
        output.setDelegate(delegate, queue: queue)
        outputDelegate = delegate
        link.start()
        displayLink = link
    }

    public func stop() {
        lifecycle.lock()
        stopped = true
        lifecycle.unlock()
        readyObservation?.invalidate()
        readyObservation = nil
        boundsObservation?.invalidate()
        boundsObservation = nil
        gravityObservation?.invalidate()
        gravityObservation = nil
        displayLink?.stop()
        displayLink = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        if let item, item.outputs.contains(output) { item.remove(output) }
    }

    /// Puts ``layer`` inside `playerLayer`, above its video and below its subtitles, sized to it.
    /// AVPlayerLayer's sublayers are private: the video container and `FigSubtitleCALayer` share an
    /// intermediate layer. Falls back to the top of `playerLayer` when that shape is not found.
    @discardableResult
    public func install(in playerLayer: AVPlayerLayer) -> Bool {
        func intermediate(of l: CALayer) -> CALayer? {
            l.sublayers?.first { String(describing: type(of: $0)) == "AVPlayerLayerIntermediateLayer" && !$0.isHidden }
        }
        let host: CALayer
        let belowSubtitles: Bool
        if let candidate = intermediate(of: playerLayer),
           let subtitles = candidate.sublayers?.firstIndex(where: { String(describing: type(of: $0)) == "FigSubtitleCALayer" }) {
            candidate.insertSublayer(layer, at: UInt32(subtitles))
            host = candidate
            belowSubtitles = true
        } else {
            playerLayer.addSublayer(layer)
            host = playerLayer
            belowSubtitles = false
        }
        layer.videoGravity = playerLayer.videoGravity
        layer.frame = host.bounds
        // AVKit resizes its player layer (PiP, picture modes, rotation on iOS); follow it.
        boundsObservation = host.observe(\.bounds, options: [.new]) { [weak self] host, _ in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.layer.frame = host.bounds
            CATransaction.commit()
        }
        // The host's picture modes (fit / fill) set the player layer's gravity; the overlay matches it.
        gravityObservation = playerLayer.observe(\.videoGravity, options: [.new]) { [weak self] playerLayer, _ in
            self?.layer.videoGravity = playerLayer.videoGravity
        }
        EngineLog.emit("[SoftwareOverlay] installed \(belowSubtitles ? "below the native subtitles" : "on top of the player layer (subtitle layer not found)")",
                       category: .swPlayback)
        return belowSubtitles
    }

    // MARK: - Render queue

    /// One display refresh. `timestamp` is when the last frame displayed and `target` when the next one does,
    /// so `target - timestamp` is the actual refresh interval. What reached the screen is measured, and the layer
    /// is topped up. A stale refresh (`fills` false) is still measured, so the timing log sees every refresh.
    private func refresh(at timestamp: CFTimeInterval, target: CFTimeInterval, fills: Bool) {
        guard let itemTimebase else { return }
        let duration = target - timestamp
        if let lastRefresh {
            countersLock.withLock { _counters.maxRefreshGapMs = max(_counters.maxRefreshGapMs, (timestamp - lastRefresh) * 1000) }
        }
        lastRefresh = timestamp
        measure(at: timestamp, duration: duration, itemTimebase: itemTimebase)
        logCountersIfDue()
        guard fills else { return }

        let rate = CMTimebaseGetRate(itemTimebase)
        let pacing = source.pacing(atRate: rate)
        followHost(pacing == .showOutput, itemTimebase: itemTimebase)
        switch pacing {
        case .outputFrames: fillFromOutput(itemTimebase: itemTimebase, rate: rate, refresh: duration)
        case .clock: fillFromSource(itemTimebase: itemTimebase, rate: rate, presentAt: target + duration, refresh: duration)
        case .showOutput: showOutput(rate: rate, presentAt: target + duration, refresh: duration)
        }
    }

    /// `.outputFrames`: takes AVPlayer's frames off the output in order, from the one after the last taken, each at
    /// its own item time, until the layer is ``lookaheadFrames`` ahead or AVPlayer has decoded no further, and has
    /// the source make each one's picture.
    private func fillFromOutput(itemTimebase: CMTimebase, rate: Double, refresh: CFTimeInterval) {
        let clock = CMTimebaseGetTime(itemTimebase)
        source.advance(to: clock.seconds)
        dropPassed(clock)
        var took = false
        while making + queued.count < Self.lookaheadFrames {
            if let held = waiting {
                guard make(held.frame, at: held.time) else { break }
                waiting = nil
                continue
            }
            // A frame AVPlayer is served is asked for half a millisecond past its whole-millisecond time: at or
            // past its own time, short of the next frame's. One the clock has passed is behind the picture
            // on screen, and the frame at the clock is taken instead. With none taken since a restart, the first is
            // the first AVPlayer has from the clock on: after a seek AVPlayer starts its clock short of the target,
            // and the frames before the target are never put out.
            let itemTime: CMTime
            if lastPulled.isValid {
                guard let next = source.frameTime(after: lastPulled.seconds) else { break }
                itemTime = CMTimeMaximum(CMTime(seconds: next + 0.0005, preferredTimescale: 1_000_000_000), clock)
            } else if let first = firstOutputTime(from: clock) {
                itemTime = first
            } else {
                countersLock.withLock { _counters.atOutputEdge += 1 }
                break
            }
            guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
                countersLock.withLock { _counters.atOutputEdge += 1 }
                break
            }
            let pullStart = CACurrentMediaTime()
            guard let (frame, frameTime) = outputFrame(forItemTime: itemTime), frameTime.isValid else { break }
            stages.record("pull", ms: (CACurrentMediaTime() - pullStart) * 1000)
            stages.record("pulled ahead of the clock", ms: (frameTime - clock).seconds * 1000)
            countersLock.withLock { _counters.pulled += 1 }
            noteFrame(frameTime)
            took = true
            guard make(frame, at: frameTime) else {
                waiting = (frame, frameTime)
                break
            }
        }
        if making + queued.count >= Self.lookaheadFrames { countersLock.withLock { _counters.atLookahead += 1 } }
        if lastQueued.isValid { stages.record("queued ahead of the clock", ms: (lastQueued - clock).seconds * 1000) }
        if took {
            lastNewFrame = CACurrentMediaTime()
        } else if rate == 0 {
            quiesceIfIdle(refresh)
        }
    }

    /// The item time to ask the output for the first frame it has at or after `clock`, walking the frames AVPlayer is
    /// served up to the look-ahead; nil when it has none of them yet.
    private func firstOutputTime(from clock: CMTime) -> CMTime? {
        if output.hasNewPixelBuffer(forItemTime: clock) { return clock }
        var cursor = clock.seconds
        for _ in 0..<Self.lookaheadFrames {
            guard let next = source.frameTime(after: cursor) else { return nil }
            let time = CMTime(seconds: next + 0.0005, preferredTimescale: 1_000_000_000)
            if output.hasNewPixelBuffer(forItemTime: time) { return time }
            cursor = next
        }
        return nil
    }

    /// Hands AVPlayer's frame at `frameTime` to the source; false when the source has nothing for it yet.
    private func make(_ frame: OutputFrame, at frameTime: CMTime) -> Bool {
        let generation = self.generation
        let pictureStart = CACurrentMediaTime()
        var accepted = false
        frame.withBuffer { base in
            accepted = source.makePicture(from: base, at: frameTime) { [weak self] picture in
                withExtendedLifetime(frame) {}
                guard let self else { return }
                let pictureMs = (CACurrentMediaTime() - pictureStart) * 1000
                self.countersLock.withLock { self._counters.maxPictureMs = max(self._counters.maxPictureMs, pictureMs) }
                let made = CACurrentMediaTime()
                self.queue.async {
                    guard generation == self.generation else { return }
                    self.making -= 1
                    guard let picture else {
                        self.countersLock.withLock { self._counters.failed += 1 }
                        return
                    }
                    self.stages.record("to render queue", ms: (CACurrentMediaTime() - made) * 1000)
                    self.enqueue(picture, at: frameTime, pictureMs: pictureMs)
                }
            }
        }
        stages.record("submit", ms: (CACurrentMediaTime() - pictureStart) * 1000)
        if accepted {
            making += 1
        } else {
            countersLock.withLock { _counters.notReady += 1 }
        }
        return accepted
    }

    /// `.clock`: queues the source's pictures from the one on screen at the clock on, up to ``lookaheadFrames``
    /// ahead. AVPlayer's frames are the placeholder's: taken off the output and dropped.
    private func fillFromSource(itemTimebase: CMTimebase, rate: Double, presentAt: CFTimeInterval, refresh: CFTimeInterval) {
        let placeholderTime = output.itemTime(forHostTime: presentAt)
        if output.hasNewPixelBuffer(forItemTime: placeholderTime), outputFrame(forItemTime: placeholderTime) != nil {
            countersLock.withLock { _counters.pulled += 1 }
        }
        let clock = CMTimebaseGetTime(itemTimebase)
        source.advance(to: clock.seconds)
        dropPassed(clock)
        let room = Self.lookaheadFrames - queued.count
        if room > 0 {
            let pictures = source.pictures(after: lastQueued.isValid ? lastQueued : nil, at: clock.seconds)
            if pictures.isEmpty, queued.isEmpty { countersLock.withLock { _counters.notReady += 1 } }
            if !pictures.isEmpty { lastNewFrame = CACurrentMediaTime() }
            for (picture, time) in pictures.prefix(room) {
                noteFrame(time)
                enqueue(picture, at: time, pictureMs: 0)
            }
        } else {
            countersLock.withLock { _counters.atLookahead += 1 }
        }
        if lastQueued.isValid { stages.record("queued ahead of the clock", ms: (lastQueued - clock).seconds * 1000) }
        if rate == 0 { quiesceIfIdle(refresh) }
    }

    /// `.showOutput`: AVPlayer's frame for the refresh after next, as it is, stamped for that refresh on the host
    /// clock, the clock the display link reports in.
    private func showOutput(rate: Double, presentAt: CFTimeInterval, refresh: CFTimeInterval) {
        let itemTime = output.itemTime(forHostTime: presentAt)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            if rate == 0 { quiesceIfIdle(refresh) }
            return
        }
        var frameTime = CMTime.invalid
        guard let picture = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &frameTime),
              frameTime.isValid else { return }
        lastNewFrame = CACurrentMediaTime()
        countersLock.withLock { _counters.pulled += 1 }
        source.advance(to: frameTime.seconds)
        // Stamped half a refresh before the refresh it was chosen for: that refresh, and no other, shows it.
        let presentation = CMTime(seconds: presentAt - refresh / 2, preferredTimescale: 1_000_000_000)
        enqueue(picture, at: presentation, frameTime: frameTime, pictureMs: 0)
    }

    /// Render queue: the item's clock moved, or AVPlayer's output started a new sequence. What the layer holds is
    /// kept when it is still what shows from `clock` on: the clock inside the pictures held, or, for a clock that is
    /// `running`, short of them with no picture to show before them. AVPlayer seeks with its clock stopped, and starts
    /// it running a little before the time it was seeked to (about 50 to 100 ms on a Mac), posting a jump for each;
    /// the start keeps the pictures queued for the seek. Otherwise the presentation starts over.
    private func clockMoved(to clock: CMTime, running: Bool, because reason: String) {
        lastClock = clock
        guard !followsHost, let held = heldSpan() else {
            restartPresentation(because: reason)
            return
        }
        let span = String(format: "(%.3f to %.3f s)", held.from.seconds, held.through.seconds)
        if CMTimeCompare(clock, held.from) >= 0, CMTimeCompare(clock, held.through) < 0 {
            EngineLog.emit("[SoftwareOverlay] \(reason), inside the pictures held \(span): kept", category: .swPlayback)
        } else if running, CMTimeCompare(clock, held.from) < 0, !hasPicture(at: clock, before: held.from) {
            EngineLog.emit("[SoftwareOverlay] \(reason), short of the pictures held \(span) with none to show before "
                           + "them: kept", category: .swPlayback)
        } else {
            restartPresentation(because: reason)
        }
    }

    /// Whether the source has a picture for `clock` older than `end` that the layer does not hold: AVPlayer's output
    /// has a frame for it not yet taken, or the decode has a picture at or before it.
    private func hasPicture(at clock: CMTime, before end: CMTime) -> Bool {
        guard let itemTimebase else { return true }
        switch source.pacing(atRate: CMTimebaseGetRate(itemTimebase)) {
        case .outputFrames:
            return output.hasNewPixelBuffer(forItemTime: clock)
        case .clock:
            return source.pictures(after: nil, at: clock.seconds).first.map { CMTimeCompare($0.time, end) < 0 } ?? false
        case .showOutput:
            return true
        }
    }

    /// Puts the layer on the host clock (scanning) or back on the item's, starting the presentation over.
    private func followHost(_ host: Bool, itemTimebase: CMTimebase) {
        guard host != followsHost, let layerTimebase else { return }
        followsHost = host
        if host {
            CMTimebaseSetSourceClock(layerTimebase, CMClockGetHostTimeClock())
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            CMTimebaseSetRateAndAnchorTime(layerTimebase, rate: 1, anchorTime: now, immediateSourceTime: now)
        } else {
            Self.follow(itemTimebase, with: layerTimebase)
        }
        restartPresentation(because: host ? "scanning: the layer follows the host clock" : "the layer follows the item's clock")
    }

    /// Makes `timebase` read what `itemTimebase` reads, always: sourced from it at rate 1, the two times anchored
    /// together.
    private static func follow(_ itemTimebase: CMTimebase, with timebase: CMTimebase) {
        CMTimebaseSetSourceTimebase(timebase, itemTimebase)
        let now = CMTimebaseGetTime(itemTimebase)
        CMTimebaseSetRateAndAnchorTime(timebase, rate: 1, anchorTime: now, immediateSourceTime: now)
    }

    /// Forgets the queued pictures the clock has reached: on screen or passed, no longer ahead of it.
    private func dropPassed(_ clock: CMTime) {
        lastClock = clock
        if let reached = queued.last(where: { CMTimeCompare($0, clock) <= 0 }) { onScreen = reached }
        queued.removeAll { CMTimeCompare($0, clock) <= 0 }
    }

    /// The item times the pictures held cover: from the one on screen (or the first queued) to one frame past the
    /// last queued. Nil with nothing held.
    private func heldSpan() -> (from: CMTime, through: CMTime)? {
        guard lastQueued.isValid, let from = onScreen.isValid ? onScreen : queued.first else { return nil }
        let frame = CMTime(seconds: frameDuration ?? 0, preferredTimescale: 1_000_000_000)
        return (from, lastQueued + frame)
    }

    /// Nothing new for a while with the clock stopped (paused, a seek prerolling): quiesce until the output says frames
    /// are coming. A running clock keeps the refreshes, so frames are taken as soon as AVPlayer has them.
    private func quiesceIfIdle(_ refresh: CFTimeInterval) {
        guard CACurrentMediaTime() - lastNewFrame > Self.quiesceAfter else { return }
        displayLink?.setPaused(true)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: refresh)
    }

    /// A new frame in the shown sequence at `frameTime`: frames between it and the last one were skipped.
    private func noteFrame(_ frameTime: CMTime) {
        if lastPulled.isValid, frameTime > lastPulled {
            let step = (frameTime - lastPulled).seconds
            if let frameDuration, frameDuration > 0 {
                let missed = Int((step / frameDuration).rounded()) - 1
                if missed > 0, missed < 12 { countersLock.withLock { _counters.skipped += missed } }
            }
            if step > 0.005, step < 0.2 { frameSteps = (frameSteps.sum + step, frameSteps.count + 1) }
        }
        lastPulled = frameTime
    }

    /// This refresh: the renderer's totals of what it displayed and when (``OverlayTiming``), and the clocks.
    private func measure(at timestamp: CFTimeInterval, duration: CFTimeInterval, itemTimebase: CMTimebase) {
        let playing = CMTimebaseGetRate(itemTimebase) != 0
        timing.refresh(at: timestamp, stated: duration)
        if playing {
            let timing = self.timing
            videoRenderer.loadVideoPerformanceMetrics { metrics in
                guard let metrics else { return }
                timing.rendererTotals(frames: metrics.totalNumberOfFrames, dropped: metrics.numberOfDroppedFrames,
                                      delay: metrics.totalAccumulatedFrameDelay, refresh: duration)
            }
        }
        timing.clocks(host: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                      audio: audioClock.map { CMClockGetTime($0).seconds },
                      item: CMTimebaseGetTime(itemTimebase).seconds, playing: playing)
    }

    /// Render queue: what the layer holds belongs to a position or a sequence the clock just left. The picture
    /// on screen stays until the next one replaces it.
    private func restartPresentation(because reason: String) {
        EngineLog.emit("[SoftwareOverlay] restart: \(reason); \(queued.count) queued, \(making) being made, last taken "
                       + (lastPulled.isValid ? String(format: "%.3f s", lastPulled.seconds) : "none"), category: .swPlayback)
        rendererIO.flush(removingDisplayedImage: false)
        videoRenderer.presentationTimeExpectation = .monotonicallyIncreasing
        lastPulled = .invalid
        lastQueued = .invalid
        onScreen = .invalid
        queued.removeAll()
        making = 0
        waiting = nil
        generation += 1
    }

    /// Render queue: enqueues `picture` for `presentation` on the layer's timeline (the picture's own item time, or
    /// a host time while scanning); `frameTime` is the item time it shows, for ``onPresented``.
    private func enqueue(_ picture: CVPixelBuffer, at presentation: CMTime, frameTime: CMTime? = nil, pictureMs: Double) {
        let frameTime = frameTime ?? presentation
        guard !lastQueued.isValid || CMTimeCompare(presentation, lastQueued) > 0 else {
            countersLock.withLock { _counters.skipped += 1 }
            return
        }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: picture, formatDescriptionOut: &format)
        guard let format else { return }
        var sampleTiming = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: picture, formatDescription: format,
                                                 sampleTiming: &sampleTiming, sampleBufferOut: &sample)
        guard let sample, let layerTimebase else { return }
        let lead = (presentation - CMTimebaseGetTime(layerTimebase)).seconds
        if lead < 0 { countersLock.withLock { _counters.late += 1 } }
        timing.made(ms: pictureMs, leadMs: lead * 1000, frameDuration: frameDuration)
        if case .failed(let reason) = rendererIO.enqueue(sample) {
            EngineLog.emit("[SoftwareOverlay] the layer refused a picture: \(reason)", category: .swPlayback)
            restartPresentation(because: "the layer refused a picture")
            return
        }
        lastQueued = presentation
        if !followsHost { queued.append(presentation) }
        countersLock.withLock { _counters.presented += 1 }
        onPresented?(frameTime, picture)
    }

    /// A frame from the output: tvOS 26's read-only buffer (`pixelBufferAndDisplayTime(forItemTime:)`), or the
    /// copied buffer before it. Its pixels are only read, inside `withBuffer`, and the frame is held until the
    /// source's picture is done.
    private enum OutputFrame: @unchecked Sendable {
        case readOnly(AnyObject)
        case copied(CVPixelBuffer)

        func withBuffer(_ body: (CVPixelBuffer) -> Void) {
            switch self {
            case .copied(let buffer):
                body(buffer)
            case .readOnly(let frame):
                if #available(macOS 26, iOS 26, tvOS 26, *), let frame = frame as? CVReadOnlyPixelBuffer {
                    frame.withUnsafeBuffer { body($0) }
                }
            }
        }
    }

    /// The output's frame for `itemTime` and the item time it is for.
    private func outputFrame(forItemTime itemTime: CMTime) -> (OutputFrame, CMTime)? {
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            let (readOnly, frameTime) = output.pixelBufferAndDisplayTime(forItemTime: itemTime)
            guard let readOnly else { return nil }
            return (.readOnly(readOnly), frameTime)
        }
        var frameTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &frameTime) else { return nil }
        return (.copied(buffer), frameTime)
    }

    /// The audio output's own clock: the clock AVPlayer's item time follows, read directly for the log.
    private static func audioOutputClock() -> CMClock? {
        #if os(macOS)
        return nil
        #else
        var clock: CMClock?
        CMAudioClockCreate(allocator: kCFAllocatorDefault, clockOut: &clock)
        return clock
        #endif
    }

    /// Logs, once, the format AVPlayer's decoder produces on its own (an output asking for nothing), beside the
    /// format the source asks for: when they differ, AVPlayer converts every frame to hand it over.
    private func logDecoderFormat(item: AVPlayerItem) {
        let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        let requested = (source.outputAttributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType).map(Self.fourCC) ?? "any"
        item.add(probe)
        queue.asyncAfter(deadline: .now() + 2) { [weak item] in
            defer { item?.remove(probe) }
            let now = probe.itemTime(forHostTime: CACurrentMediaTime())
            guard let buffer = probe.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) else {
                EngineLog.emit("[SoftwareOverlay] decoder format: no frame to read", category: .swPlayback)
                return
            }
            let surface = CVPixelBufferGetIOSurface(buffer) != nil
            EngineLog.emit("[SoftwareOverlay] decoder format \(Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))) "
                           + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) iosurface=\(surface); "
                           + "the overlay asks for \(requested)", category: .swPlayback)
        }
    }

    static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
    }

    private func logCountersIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastLog >= 10 else { return }
        lastLog = now
        let c = countersLock.withLock {
            let c = _counters
            _counters.maxPictureMs = 0
            _counters.maxRefreshGapMs = 0
            return c
        }
        EngineLog.emit("[SoftwareOverlay] pulled \(c.pulled), presented \(c.presented), skipped \(c.skipped), late \(c.late), "
                       + "stale refreshes \(c.staleRefreshes), at look-ahead \(c.atLookahead), at output edge \(c.atOutputEdge), "
                       + "not ready \(c.notReady), failed \(c.failed), "
                       + String(format: "max picture %.0f ms, max refresh gap %.0f ms; ", c.maxPictureMs, c.maxRefreshGapMs)
                       + source.logSummary(),
                       category: .swPlayback)
        EngineLog.emit("[SoftwareOverlay] \(timing.drain())", category: .swPlayback)
        let stageTimes = [stages.drain(), source.drainStageTimes()].compactMap { $0 }
        if !stageTimes.isEmpty {
            EngineLog.emit("[SoftwareOverlay] per frame (count, min/median/max): \(stageTimes.joined(separator: ", "))",
                           category: .swPlayback)
        }
        EngineLog.emit("[SoftwareOverlay] alongside playback (count, min/median/max per job): "
                       + (StageTimes.alongsidePlayback.drain() ?? "nothing"), category: .swPlayback)
        EngineLog.emit("[SoftwareOverlay] \(timing.drainClocks())"
                       + (AudioRouteDescription.latency().map { "; audio output \($0)" } ?? ""), category: .swPlayback)
        videoRenderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else { return }
            EngineLog.emit("[SoftwareOverlay] renderer metrics: frames \(metrics.totalNumberOfFrames), dropped \(metrics.numberOfDroppedFrames), "
                           + "corrupted \(metrics.numberOfCorruptedFrames), optimized compositing \(metrics.numberOfFramesDisplayedUsingOptimizedCompositing)",
                           category: .swPlayback)
        }
    }
}
