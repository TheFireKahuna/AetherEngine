// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import IOSurface
import os

/// Draws a Profile 7 FEL picture over an `AVPlayer` that plays the source's base layer.
///
/// AVPlayer keeps everything it is good at (loading, seeking, audio, AVKit's transport, menus and native
/// subtitles) and decodes the base layer; with `suppressesPlayerRendering` it renders nothing itself and
/// hands every decoded frame to an `AVPlayerItemVideoOutput` instead (bit-identical to a VideoToolbox decode
/// of the base layer, before any reshaping). The overlay is driven the way that output is documented to be
/// used, by a display link: at each refresh it asks which frame belongs at the refresh after next
/// (`itemTime(forHostTime:)`, the item's clock, which is the audio clock), pairs it by item time with its
/// enhancement picture and parameters from the session's ``FelEnhancementTap``, composes it with its
/// composed-form RPU, and enqueues it on ``layer`` stamped for that refresh on a host-clock timebase, the
/// clock the display link reports in. Every frame shows on the refresh chosen for it, and the picture
/// follows the audio by construction: there is no second clock to correct.
///
/// The layer belongs inside the `AVPlayerLayer`, between the video and the subtitle layers, so native
/// subtitles stay on top (``install(in:)``). A frame whose enhancement picture has not decoded is composed
/// with its residual off.
public final class FelOverlayRenderer: @unchecked Sendable {

    public struct Counters: Sendable {
        public var pulled = 0
        public var composed = 0
        public var residualOff = 0
        public var notReady = 0
        public var composeFailed = 0
        /// Composed frames that reached the layer after the refresh they were chosen for.
        public var late = 0
        /// Frames AVPlayer decoded that no refresh was chosen for.
        public var skipped = 0
        /// Longest compose and longest gap between refreshes since the last log line, in ms.
        public var maxComposeMs = 0.0
        public var maxRefreshGapMs = 0.0
    }

    public let layer = AVSampleBufferDisplayLayer()
    /// Test seam: every composed frame with the item time it shows, on the render queue.
    public var onComposed: (@Sendable (CMTime, CVPixelBuffer) -> Void)?

    /// With no new frame for this long (paused, a still), the display link pauses until the output says frames
    /// are coming again.
    static let quiesceAfter = 0.5

    private let output: AVPlayerItemVideoOutput
    private weak var item: AVPlayerItem?
    private let tap: FelEnhancementTap
    private let composer: DoviFelComposer
    private let queue = DispatchQueue(label: "aether.fel-overlay", qos: .userInteractive)
    private var displayLink: FelOverlayDisplayLink?
    private var outputDelegate: FelOverlayOutputDelegate?
    private var lastNewFrame = CACurrentMediaTime()
    private var jumpObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var gravityObservation: NSKeyValueObservation?
    private let timing = FelOverlayTiming()
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
    /// Bumped on every clock jump: a composition finishing for an older generation is for a left position.
    private var generation = 0
    /// The mean step between pulled frames: the stream's frame duration (container timestamps can be whole
    /// milliseconds, so single steps are not), for counting skips.
    private var frameSteps: (sum: Double, count: Int) = (0, 0)
    private var frameDuration: Double? { frameSteps.count > 0 ? frameSteps.sum / Double(frameSteps.count) : nil }
    private var frameIndex: UInt32 = 0
    private var lastRefresh: CFTimeInterval?
    private var blankEnhancement: CVPixelBuffer?
    private var lastLog = CACurrentMediaTime()
    private let countersLock = NSLock()
    private var _counters = Counters()

    public var counters: Counters { countersLock.withLock { _counters } }

    /// Nil when the composer cannot be built (no Metal device).
    init?(item: AVPlayerItem, tap: FelEnhancementTap) {
        guard let composer = DoviFelComposer() else { return nil }
        self.composer = composer
        self.item = item
        self.tap = tap
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        ])
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
        tap.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
        // A seek moves the item's clock before its first frame decodes: point the tap's decoder there at once,
        // and drop what the layer queued for the old position.
        jumpObserver = NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: itemTimebase, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.tap.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
            self.queue.async { self.restartPresentation() }
        }
        // The output pool is built the way the renderer asks frames to be made (CoreAnimation-compatible
        // surfaces, its cache mode), as the software route's is: a frame the compositor can take as it is.
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            let recommended = layer.sampleBufferRenderer.__recommendedPixelBufferAttributes
            composer.rendererRecommendedAttributesOverride = recommended
            EngineLog.emit("[FelOverlayRenderer] output pool follows the renderer's recommendation \(recommended.keys.sorted()); "
                           + "the composer delivers \(Self.fourCC(DoviFelComposer.outputMode.pixelFormat))", category: .swPlayback)
        }
        logDecoderFormat(item: item)
        let link = FelOverlayDisplayLink { [weak self] timestamp, targetTimestamp in
            guard let self else { return }
            // What is on screen, read at the callback itself: queued behind other work it could be a frame late.
            let shownSurface = self.layer.sampleBufferRenderer.displayedPixelBuffer()
                .flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
                .map { IOSurfaceGetID($0) }
            self.queue.async { self.refresh(at: timestamp, target: targetTimestamp, shownSurface: shownSurface) }
        }
        let delegate = FelOverlayOutputDelegate { [weak self] in
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
        EngineLog.emit("[FelOverlayRenderer] installed \(belowSubtitles ? "below the native subtitles" : "on top of the player layer (subtitle layer not found)")",
                       category: .swPlayback)
        return belowSubtitles
    }

    // MARK: - Render queue

    /// One display refresh. `timestamp` is when the last frame displayed and `target` when the next one does,
    /// so `target - timestamp` is the actual refresh interval. What is on screen is measured; the frame for the
    /// refresh after `target` is chosen and composed (one refresh of time to compose it).
    private func refresh(at timestamp: CFTimeInterval, target: CFTimeInterval, shownSurface: IOSurfaceID?) {
        guard let itemTimebase else { return }
        let duration = target - timestamp
        if let lastRefresh {
            countersLock.withLock { _counters.maxRefreshGapMs = max(_counters.maxRefreshGapMs, (timestamp - lastRefresh) * 1000) }
        }
        lastRefresh = timestamp
        measure(at: timestamp, duration: duration, shownSurface: shownSurface, itemTimebase: itemTimebase)
        logCountersIfDue()

        // The documented use of the output: the item time for a coming refresh, and its frame if it is new.
        let presentAt = target + duration
        let itemTime = output.itemTime(forHostTime: presentAt)
        guard output.hasNewPixelBuffer(forItemTime: itemTime) else {
            // Nothing new for a while (paused, a still): quiesce until the output says frames are coming.
            if CACurrentMediaTime() - lastNewFrame > Self.quiesceAfter {
                displayLink?.setPaused(true)
                output.requestNotificationOfMediaDataChange(withAdvanceInterval: duration)
            }
            return
        }
        lastNewFrame = CACurrentMediaTime()
        guard let (source, frameTime) = outputFrame(forItemTime: itemTime), frameTime.isValid else { return }
        countersLock.withLock { _counters.pulled += 1 }
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
        tap.advance(to: frameTime.seconds)

        source.withBuffer { base in
            guard let frame = tap.frame(at: frameTime.seconds) else {
                countersLock.withLock { _counters.notReady += 1 }
                return
            }
            var params = frame.params
            let enhancement: CVPixelBuffer
            if let el = frame.enhancement {
                enhancement = el
            } else if let blank = blankEnhancement(for: base) {
                params.flags.insert(.disableResidual)
                enhancement = blank
                countersLock.withLock { _counters.residualOff += 1 }
            } else {
                return
            }
            frameIndex &+= 1
            let generation = self.generation
            let shownTime = frameTime
            let rpu = frame.composedRpu
            let composeStart = CACurrentMediaTime()
            // Stamped half a refresh before the refresh it was chosen for: that refresh, and no other, shows it.
            let presentation = CMTime(seconds: presentAt - duration / 2, preferredTimescale: 1_000_000_000)
            let shownFor = CMTime(seconds: duration, preferredTimescale: 1_000_000_000)
            composer.composeAsync(baseBuffer: base, enhancementBuffer: enhancement, params: params, frameIndex: frameIndex) { [weak self] composed in
                withExtendedLifetime(source) {}
                guard let self else { return }
                let composeMs = (CACurrentMediaTime() - composeStart) * 1000
                self.countersLock.withLock { self._counters.maxComposeMs = max(self._counters.maxComposeMs, composeMs) }
                guard let composed else {
                    self.countersLock.withLock { self._counters.composeFailed += 1 }
                    return
                }
                DoviDisplayMetadata.attach(rpuNAL: rpu, to: composed)
                if let surface = CVPixelBufferGetIOSurface(composed)?.takeUnretainedValue() {
                    let id = IOSurfaceGetID(surface)
                    self.surfaceTimes.withLock { $0[id] = shownTime.seconds }
                }
                self.queue.async {
                    guard generation == self.generation else { return }
                    self.enqueue(composed, at: presentation, for: shownFor, frameTime: shownTime, composeMs: composeMs)
                }
            }
        }
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
        generation += 1
    }

    private func enqueue(_ buffer: CVPixelBuffer, at presentation: CMTime, for duration: CMTime,
                         frameTime: CMTime, composeMs: Double) {
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
        timing.composed(ms: composeMs, leadMs: lead * 1000, frameDuration: frameDuration)
        layer.sampleBufferRenderer.enqueue(sample)
        countersLock.withLock { _counters.composed += 1 }
        onComposed?(frameTime, buffer)
    }

    /// A frame from the output: tvOS 26's read-only buffer (`pixelBufferAndDisplayTime(forItemTime:)`), or the
    /// copied buffer before it. Its pixels are only read, inside `withBuffer`: the composer's Metal textures,
    /// made there, keep the buffer alive until the GPU is done, and the frame itself is held until then too.
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

    /// An enhancement-sized picture the kernels can bind when the residual is off; its content is never read.
    private func blankEnhancement(for base: CVPixelBuffer) -> CVPixelBuffer? {
        if let blankEnhancement { return blankEnhancement }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(base) / 2, CVPixelBufferGetHeight(base) / 2,
                            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                             kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &buffer)
        blankEnhancement = buffer
        return buffer
    }

    /// Logs, once, the format AVPlayer's decoder produces on its own (an output asking for nothing), beside the
    /// `x420` this renderer asks for: when they differ, AVPlayer converts every frame to hand it over.
    private func logDecoderFormat(item: AVPlayerItem) {
        let probe = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        item.add(probe)
        queue.asyncAfter(deadline: .now() + 2) { [weak item] in
            defer { item?.remove(probe) }
            let now = probe.itemTime(forHostTime: CACurrentMediaTime())
            guard let buffer = probe.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) else {
                EngineLog.emit("[FelOverlayRenderer] decoder format: no frame to read", category: .swPlayback)
                return
            }
            let surface = CVPixelBufferGetIOSurface(buffer) != nil
            EngineLog.emit("[FelOverlayRenderer] decoder format \(Self.fourCC(CVPixelBufferGetPixelFormatType(buffer))) "
                           + "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) iosurface=\(surface); "
                           + "the overlay asks for x420", category: .swPlayback)
        }
    }

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
    }

    private func logCountersIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastLog >= 10 else { return }
        lastLog = now
        let c = countersLock.withLock {
            let c = _counters
            _counters.maxComposeMs = 0
            _counters.maxRefreshGapMs = 0
            return c
        }
        let held = tap.held
        EngineLog.emit("[FelOverlayRenderer] pulled \(c.pulled), composed \(c.composed), skipped \(c.skipped), late \(c.late), "
                       + "residual off \(c.residualOff), not ready \(c.notReady), compose failed \(c.composeFailed), "
                       + String(format: "max compose %.0f ms, max refresh gap %.0f ms, ", c.maxComposeMs, c.maxRefreshGapMs)
                       + "held \(held.accessUnits) units / \(held.decoded) decoded",
                       category: .swPlayback)
        EngineLog.emit("[FelOverlayRenderer] \(timing.drain())", category: .swPlayback)
        EngineLog.emit("[FelOverlayRenderer] \(timing.drainClocks())", category: .swPlayback)
        layer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else { return }
            EngineLog.emit("[FelOverlayRenderer] renderer metrics: frames \(metrics.totalNumberOfFrames), dropped \(metrics.numberOfDroppedFrames), "
                           + "corrupted \(metrics.numberOfCorruptedFrames), optimized compositing \(metrics.numberOfFramesDisplayedUsingOptimizedCompositing)",
                           category: .swPlayback)
        }
    }
}
#endif
