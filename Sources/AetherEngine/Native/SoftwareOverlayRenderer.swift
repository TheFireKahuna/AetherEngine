import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import IOSurface
import os

/// How the overlay's pictures follow AVPlayer.
enum OverlayPacing: Equatable {
    /// One picture for each frame AVPlayer's output hands over, made from it (`makePicture`).
    case outputFrames
    /// AVPlayer's frames as they are: the I-frame tier's stills while it scans.
    case showOutput
    /// The source's picture on screen at each refresh's item time (`picture(at:)`), whatever AVPlayer decodes.
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
    /// `.outputFrames`: the picture for AVPlayer's frame `output` at `frameTime`, handed to `done` on any thread (nil
    /// when it could not be made). False, with `done` never called, when the source has nothing for that time yet.
    /// `output` is valid until `done` runs.
    func makePicture(from output: CVPixelBuffer, at frameTime: CMTime,
                     done: @escaping @Sendable (CVPixelBuffer?) -> Void) -> Bool
    /// `.clock`: the picture on screen at `itemSeconds` and its own time, nil while the source has none.
    func picture(at itemSeconds: Double) -> (picture: CVPixelBuffer, seconds: Double)?
    /// The source's own state, for the renderer's periodic log line.
    func logSummary() -> String
}

/// Draws our own picture over an `AVPlayer` whose rendering is suppressed: a Profile 7 FEL's composition over the
/// base layer AVPlayer plays (``FelCompositionSource``), or the session's own decode of a stream AVPlayer is served
/// a placeholder of (``DecodedPictureSource``).
///
/// AVPlayer keeps everything it is good at (loading, seeking, audio, AVKit's transport, menus and native
/// subtitles); with `suppressesPlayerRendering` it renders nothing itself and hands every decoded frame to an
/// `AVPlayerItemVideoOutput` instead. The overlay is driven the way that output is documented to be used, by a
/// display link: at each refresh it asks which frame belongs at the refresh after next (`itemTime(forHostTime:)`,
/// the item's clock, which is the audio clock), has the ``OverlayFrameSource`` make the picture for it (or, paced by
/// the clock, give the picture on screen at that time), and enqueues that on ``layer`` stamped for that refresh on a
/// host-clock timebase, the clock the display link reports in. Every frame shows on the refresh chosen for it, and the picture follows the audio by construction: there is
/// no second clock to correct.
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
        /// Pictures that reached the layer after the refresh they were chosen for.
        public var late = 0
        /// Frames AVPlayer decoded that no refresh was chosen for.
        public var skipped = 0
        /// Refreshes passed over because a later one was already waiting behind them.
        public var staleRefreshes = 0
        /// Longest picture and longest gap between refreshes since the last log line, in ms.
        public var maxPictureMs = 0.0
        public var maxRefreshGapMs = 0.0
    }

    public let layer = AVSampleBufferDisplayLayer()
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
    private var itemTimebase: CMTimebase?
    /// The audio output's clock, for the clock readings in the log.
    private var audioClock: CMClock?
    /// Item time of the frame each output surface last carried, for reading back what is on screen. Pool
    /// surfaces are reused, so this stays as small as the pool.
    private let surfaceTimes = OSAllocatedUnfairLock(initialState: [IOSurfaceID: Double]())
    private let lifecycle = NSLock()
    private var started = false
    private var stopped = false
    /// Render-queue state.
    private var lastPulled = CMTime.invalid
    /// The time of the picture last presented, by the clock's pacing: a refresh with the same picture enqueues nothing.
    private var lastShown: Double?
    /// Bumped on every clock jump: a picture finishing for an older generation is for a left position.
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
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: source.outputAttributes)
        // The overlay is the item's picture: AVPlayer keeps decoding into the output but stops rendering its
        // own, so one video pipeline presents.
        output.suppressesPlayerRendering = true
        layer.videoGravity = .resizeAspect
        // AVPlayer no longer presents video, so the layer says that video is playing.
        layer.preventsDisplaySleepDuringVideoPlayback = true
        layer.sampleBufferRenderer.presentationTimeExpectation = .monotonicallyIncreasing
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
        // The layer's time is host time, the clock the display link stamps refreshes in.
        var hostTimebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &hostTimebase)
        if let hostTimebase {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            CMTimebaseSetRateAndAnchorTime(hostTimebase, rate: 1, anchorTime: now, immediateSourceTime: now)
            layer.controlTimebase = hostTimebase
        }
        source.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
        // A seek moves the item's clock before its first frame decodes: point the source there at once, and drop
        // what the layer queued for the old position.
        jumpObserver = NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: itemTimebase, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.source.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
            self.queue.async {
                self.restartPresentation()
                // A seek while paused still shows its target, when the source has it.
                self.lastNewFrame = CACurrentMediaTime()
                self.displayLink?.setPaused(false)
            }
        }
        // The source's pool is built the way the renderer asks frames to be made (CoreAnimation-compatible
        // surfaces, its cache mode): a picture the compositor can take as it is.
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            source.followRenderer(layer.sampleBufferRenderer.__recommendedPixelBufferAttributes)
        }
        logDecoderFormat(item: item)
        let link = OverlayDisplayLink { [weak self] timestamp, targetTimestamp in
            guard let self else { return }
            // What is on screen, read at the callback itself: queued behind other work it could be a frame late.
            let shownSurface = self.layer.sampleBufferRenderer.displayedPixelBuffer()
                .flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
                .map { IOSurfaceGetID($0) }
            let sequence = self.latestRefresh.withLock { latest -> UInt64 in
                latest &+= 1
                return latest
            }
            self.queue.async {
                // Only the newest refresh chooses a frame. A render queue held up (a compose slot, a long
                // picture) would otherwise work through every refresh queued meanwhile, each choosing a frame
                // for a moment already gone, and the picture would trail the audio by however many had piled up for as
                // long as the queue stayed that far behind.
                let stale = self.latestRefresh.withLock({ $0 }) != sequence
                if stale { self.countersLock.withLock { self._counters.staleRefreshes += 1 } }
                self.refresh(at: timestamp, target: targetTimestamp, shownSurface: shownSurface, choosesFrame: !stale)
            }
        }
        let delegate = OverlayOutputDelegate { [weak self] in
            self?.lastNewFrame = CACurrentMediaTime()
            self?.displayLink?.setPaused(false)
        }
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
    /// so `target - timestamp` is the actual refresh interval. What is on screen is measured; the frame for the
    /// refresh after `target` is chosen and made (one refresh of time to make it).
    /// A stale refresh (`choosesFrame` false) is still measured, so the timing log sees every refresh, but
    /// chooses no frame.
    private func refresh(at timestamp: CFTimeInterval, target: CFTimeInterval, shownSurface: IOSurfaceID?,
                         choosesFrame: Bool) {
        guard let itemTimebase else { return }
        let duration = target - timestamp
        if let lastRefresh {
            countersLock.withLock { _counters.maxRefreshGapMs = max(_counters.maxRefreshGapMs, (timestamp - lastRefresh) * 1000) }
        }
        lastRefresh = timestamp
        measure(at: timestamp, duration: duration, shownSurface: shownSurface, itemTimebase: itemTimebase)
        logCountersIfDue()
        guard choosesFrame else { return }

        // The documented use of the output: the item time for a coming refresh, and its frame if it is new.
        let presentAt = target + duration
        let itemTime = output.itemTime(forHostTime: presentAt)
        // Stamped half a refresh before the refresh it was chosen for: that refresh, and no other, shows it.
        let presentation = CMTime(seconds: presentAt - duration / 2, preferredTimescale: 1_000_000_000)
        let shownFor = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
        let rate = CMTimebaseGetRate(itemTimebase)
        let pacing = source.pacing(atRate: rate)
        let newOutput = output.hasNewPixelBuffer(forItemTime: itemTime)
        if pacing != .clock, !newOutput {
            quiesceIfIdle(duration)
            return
        }

        switch pacing {
        case .clock:
            // AVPlayer's frames are the placeholder's: taken off the output and dropped.
            if newOutput, output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) != nil {
                countersLock.withLock { _counters.pulled += 1 }
            }
            source.advance(to: itemTime.seconds)
            guard let (picture, seconds) = source.picture(at: itemTime.seconds) else {
                countersLock.withLock { _counters.notReady += 1 }
                return
            }
            guard seconds != lastShown else {
                if rate == 0 { quiesceIfIdle(duration) }
                return
            }
            lastShown = seconds
            lastNewFrame = CACurrentMediaTime()
            let frameTime = CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
            noteFrame(frameTime)
            present(picture, frameTime: frameTime, at: presentation, for: shownFor, pictureMs: 0)

        case .showOutput:
            var frameTime = CMTime.invalid
            guard let picture = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &frameTime),
                  frameTime.isValid else { return }
            lastNewFrame = CACurrentMediaTime()
            countersLock.withLock { _counters.pulled += 1 }
            source.advance(to: frameTime.seconds)
            present(picture, frameTime: frameTime, at: presentation, for: shownFor, pictureMs: 0)

        case .outputFrames:
            lastNewFrame = CACurrentMediaTime()
            guard let (frame, frameTime) = outputFrame(forItemTime: itemTime), frameTime.isValid else { return }
            countersLock.withLock { _counters.pulled += 1 }
            noteFrame(frameTime)
            source.advance(to: frameTime.seconds)

            let generation = self.generation
            let pictureStart = CACurrentMediaTime()
            frame.withBuffer { base in
                let accepted = source.makePicture(from: base, at: frameTime) { [weak self] picture in
                    withExtendedLifetime(frame) {}
                    guard let self else { return }
                    let pictureMs = (CACurrentMediaTime() - pictureStart) * 1000
                    self.countersLock.withLock { self._counters.maxPictureMs = max(self._counters.maxPictureMs, pictureMs) }
                    guard let picture else {
                        self.countersLock.withLock { self._counters.failed += 1 }
                        return
                    }
                    self.queue.async {
                        guard generation == self.generation else { return }
                        self.present(picture, frameTime: frameTime, at: presentation, for: shownFor, pictureMs: pictureMs)
                    }
                }
                if !accepted { countersLock.withLock { _counters.notReady += 1 } }
            }
        }
    }

    /// Nothing new for a while (paused, a still): quiesce until the output says frames are coming.
    private func quiesceIfIdle(_ refresh: CFTimeInterval) {
        guard CACurrentMediaTime() - lastNewFrame > Self.quiesceAfter else { return }
        displayLink?.setPaused(true)
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: refresh)
    }

    /// A new frame in the shown sequence at `frameTime`: frames between it and the last one were skipped, and a step
    /// back is a restart of the sequence.
    private func noteFrame(_ frameTime: CMTime) {
        if lastPulled.isValid, frameTime > lastPulled {
            let step = (frameTime - lastPulled).seconds
            if let frameDuration, frameDuration > 0 {
                let missed = Int((step / frameDuration).rounded()) - 1
                if missed > 0, missed < 12 { countersLock.withLock { _counters.skipped += missed } }
            }
            if step > 0.005, step < 0.2 { frameSteps = (frameSteps.sum + step, frameSteps.count + 1) }
        }
        if lastPulled.isValid, frameTime < lastPulled { restartPresentation() }
        lastPulled = frameTime
    }

    /// Render queue: records what `picture` shows for reading the screen back, and enqueues it.
    private func present(_ picture: CVPixelBuffer, frameTime: CMTime, at presentation: CMTime, for duration: CMTime,
                         pictureMs: Double) {
        if let surface = CVPixelBufferGetIOSurface(picture)?.takeUnretainedValue() {
            let id = IOSurfaceGetID(surface)
            surfaceTimes.withLock { $0[id] = frameTime.seconds }
        }
        enqueue(picture, at: presentation, for: duration, frameTime: frameTime, pictureMs: pictureMs)
    }

    /// What is on screen at this refresh: which frame (by its surface), how far its item time is from the item
    /// clock's at this refresh (the picture against the audio), and the clocks.
    private func measure(at timestamp: CFTimeInterval, duration: CFTimeInterval, shownSurface: IOSurfaceID?,
                         itemTimebase: CMTimebase) {
        let playing = CMTimebaseGetRate(itemTimebase) != 0
        let shown = shownSurface.flatMap { id in surfaceTimes.withLock { $0[id] } }
        let clockNow = output.itemTime(forHostTime: timestamp).seconds
        timing.refresh(at: timestamp, stated: duration, shown: shown,
                       offsetMs: shown.map { ($0 - clockNow) * 1000 }, playing: playing)
        timing.clocks(host: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                      audio: audioClock.map { CMClockGetTime($0).seconds },
                      item: CMTimebaseGetTime(itemTimebase).seconds, playing: playing)
    }

    /// Render queue: what the layer holds belongs to the position the clock just left.
    private func restartPresentation() {
        layer.sampleBufferRenderer.flush()
        layer.sampleBufferRenderer.presentationTimeExpectation = .monotonicallyIncreasing
        lastPulled = .invalid
        lastShown = nil
        generation += 1
    }

    private func enqueue(_ buffer: CVPixelBuffer, at presentation: CMTime, for duration: CMTime,
                         frameTime: CMTime, pictureMs: Double) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        var sampleTiming = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &sampleTiming, sampleBufferOut: &sample)
        guard let sample else { return }
        let lead = (presentation - CMClockGetTime(CMClockGetHostTimeClock())).seconds
        if lead < 0 { countersLock.withLock { _counters.late += 1 } }
        timing.made(ms: pictureMs, leadMs: lead * 1000, frameDuration: frameDuration)
        layer.sampleBufferRenderer.enqueue(sample)
        countersLock.withLock { _counters.presented += 1 }
        onPresented?(frameTime, buffer)
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
                       + "stale refreshes \(c.staleRefreshes), "
                       + "not ready \(c.notReady), failed \(c.failed), "
                       + String(format: "max picture %.0f ms, max refresh gap %.0f ms; ", c.maxPictureMs, c.maxRefreshGapMs)
                       + source.logSummary(),
                       category: .swPlayback)
        EngineLog.emit("[SoftwareOverlay] \(timing.drain())", category: .swPlayback)
        EngineLog.emit("[SoftwareOverlay] \(timing.drainClocks())", category: .swPlayback)
        layer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else { return }
            EngineLog.emit("[SoftwareOverlay] renderer metrics: frames \(metrics.totalNumberOfFrames), dropped \(metrics.numberOfDroppedFrames), "
                           + "corrupted \(metrics.numberOfCorruptedFrames), optimized compositing \(metrics.numberOfFramesDisplayedUsingOptimizedCompositing)",
                           category: .swPlayback)
        }
    }
}
