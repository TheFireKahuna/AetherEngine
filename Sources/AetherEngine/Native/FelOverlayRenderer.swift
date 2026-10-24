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
/// subtitles) and decodes the base layer as usual; `AVPlayerItemVideoOutput` hands each decoded frame back,
/// bit-identical to a VideoToolbox decode of the base layer and before any reshaping. Each one is paired by
/// item time with its enhancement picture and parameters from the session's ``FelEnhancementTap``, composed
/// on the dual-layer composer, given its composed-form RPU, and enqueued on ``layer``: an
/// `AVSampleBufferDisplayLayer` whose timebase follows the item's 1:1, so it shows each frame when AVPlayer
/// would have shown its own.
///
/// The layer covers AVPlayer's picture, so AVPlayer dropping or holding a frame never shows. It belongs
/// inside the `AVPlayerLayer`, between the video and the subtitle layers, so native subtitles stay on top
/// (``install(in:)``). A frame whose enhancement picture has not decoded is composed with its residual off.
public final class FelOverlayRenderer: @unchecked Sendable {

    public struct Counters: Sendable {
        public var pulled = 0
        public var composed = 0
        public var residualOff = 0
        public var notReady = 0
        public var composeFailed = 0
        /// Composed frames that reached the layer after their own display time (the layer drops those).
        public var late = 0
        /// Frames AVPlayer decoded that the render loop never pulled (it skipped past them).
        public var skipped = 0
        /// Longest compose (pull to enqueue) and longest render-loop gap since the last log line, in ms.
        public var maxComposeMs = 0.0
        public var maxTickGapMs = 0.0
    }

    public let layer = AVSampleBufferDisplayLayer()
    /// Test seam: every composed frame with the item time it was enqueued for, on the render queue.
    public var onComposed: (@Sendable (CMTime, CVPixelBuffer) -> Void)?

    private let output: AVPlayerItemVideoOutput
    private weak var item: AVPlayerItem?
    private let tap: FelEnhancementTap
    private let composer: DoviFelComposer
    private let queue = DispatchQueue(label: "aether.fel-overlay", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var jumpObserver: NSObjectProtocol?
    private var readyObservation: NSKeyValueObservation?
    private var boundsObservation: NSKeyValueObservation?
    private var gravityObservation: NSKeyValueObservation?
    private let timing = FelOverlayTiming()
    /// The documented model for presenting your own frames against a clock: the renderer joins a synchronizer
    /// (through the tvOS 27 receiver, `VideoRendererIO`), and the synchronizer follows AVPlayer's item clock.
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let io: VideoRendererIO
    private var itemTimebase: CMTimebase?
    private var rateObserver: NSObjectProtocol?
    /// The item's ultimate source clock (the audio device's), for the clock readings in the log.
    private var audioClock: CMClock?
    private var lastFollowCheck = CACurrentMediaTime()
    /// The synchronizer runs on the host clock, the item on the audio clock: past this, it follows again.
    static let followTolerance = 0.015
    #if os(tvOS) || os(iOS)
    private var refreshProbe: FelOverlayRefreshProbe?
    #endif
    /// Presentation time of the frame each output surface last carried, for reading back what is on screen.
    /// Pool surfaces are reused, so this stays as small as the pool.
    private let surfaceTimes = OSAllocatedUnfairLock(initialState: [IOSurfaceID: Double]())
    private let lifecycle = NSLock()
    private var started = false
    private var stopped = false
    /// Render-queue state.
    private var lastPulled = CMTime.invalid
    /// Bumped on every clock jump: a composition finishing for an older generation is for a left position.
    private var generation = 0
    /// The shortest step between pulled frames: the stream's frame duration, for counting skips.
    private var frameDuration: Double?
    private var frameIndex: UInt32 = 0
    /// The latest compose time, handed to `timing` with the enqueue it belongs to.
    private var lastComposeMs = 0.0
    private var blankEnhancement: CVPixelBuffer?
    private var lastLog = CACurrentMediaTime()
    private var lastTick = CACurrentMediaTime()
    private let countersLock = NSLock()
    private var _counters = Counters()

    /// How far ahead of the clock frames are pulled and composed: enough for the GPU, short enough that a
    /// seek's first frame is not held back.
    static let pullLead = 0.1

    public var counters: Counters { countersLock.withLock { _counters } }

    /// Nil when the composer cannot be built (no Metal device).
    init?(item: AVPlayerItem, tap: FelEnhancementTap) {
        guard let composer = DoviFelComposer() else { return nil }
        self.composer = composer
        self.item = item
        self.tap = tap
        io = VideoRendererIO(renderer: layer.sampleBufferRenderer)
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
        audioClock = CMTimebaseCopyUltimateSourceClock(itemTimebase)
        io.join(synchronizer, throughReceiver: true)
        followItemClock()
        tap.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
        // Play, pause and rate changes reach the synchronizer as they reach the item.
        rateObserver = NotificationCenter.default.addObserver(forName: CMTimebase.effectiveRateChanged, object: itemTimebase, queue: nil) { [weak self] _ in
            self?.queue.async { self?.followItemClock() }
        }
        // A seek moves the item's clock before its first frame decodes: point the tap's decoder there at once,
        // and drop what the layer queued for the old position.
        jumpObserver = NotificationCenter.default.addObserver(forName: CMTimebase.timeJumped, object: itemTimebase, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.tap.advance(to: CMTimebaseGetTime(itemTimebase).seconds)
            self.queue.async {
                self.followItemClock()
                self.restartPresentation()
            }
        }
        #if os(tvOS) || os(iOS)
        let probe = FelOverlayRefreshProbe { [weak self] link in
            guard let self, let itemTimebase = self.itemTimebase else { return }
            let shown = self.layer.sampleBufferRenderer.displayedPixelBuffer()
                .flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
                .flatMap { self.surfaceTimes.withLock { [id = IOSurfaceGetID($0)] in $0[id] } }
            let playing = self.synchronizer.rate != 0
            self.timing.refresh(at: link.timestamp, stated: link.duration, shown: shown, playing: playing)
            self.timing.clocks(host: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
                               audio: self.audioClock.map { CMClockGetTime($0).seconds },
                               item: CMTimebaseGetTime(itemTimebase).seconds, playing: playing)
        }
        probe.start()
        refreshProbe = probe
        #endif
        // The output pool is built the way the renderer asks frames to be made (CoreAnimation-compatible
        // surfaces, its cache mode), as the software route's is: a frame the compositor can take as it is.
        if #available(macOS 26, iOS 26, tvOS 26, *) {
            let recommended = layer.sampleBufferRenderer.__recommendedPixelBufferAttributes
            composer.rendererRecommendedAttributesOverride = recommended
            EngineLog.emit("[FelOverlayRenderer] output pool follows the renderer's recommendation \(recommended.keys.sorted()); "
                           + "the composer delivers \(Self.fourCC(DoviFelComposer.outputMode.pixelFormat))", category: .swPlayback)
        }
        logDecoderFormat(item: item)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
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
        timer?.cancel()
        timer = nil
        #if os(tvOS) || os(iOS)
        refreshProbe?.stop()
        refreshProbe = nil
        #endif
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
        rateObserver = nil
        if started { io.leave(synchronizer) }
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

    private func tick() {
        checkFollow()
        let tickTime = CACurrentMediaTime()
        let gap = (tickTime - lastTick) * 1000
        lastTick = tickTime
        countersLock.withLock { _counters.maxTickGapMs = max(_counters.maxTickGapMs, gap) }
        let ahead = output.itemTime(forHostTime: CACurrentMediaTime() + Self.pullLead)
        guard output.hasNewPixelBuffer(forItemTime: ahead) else { return }
        var shown = CMTime.invalid
        guard let base = output.copyPixelBuffer(forItemTime: ahead, itemTimeForDisplay: &shown), shown.isValid else { return }
        countersLock.withLock { _counters.pulled += 1 }
        if lastPulled.isValid, shown > lastPulled, let rate = frameDuration, rate > 0 {
            let missed = Int(((shown - lastPulled).seconds / rate).rounded()) - 1
            if missed > 0, missed < 12 { countersLock.withLock { _counters.skipped += missed } }
        }
        if lastPulled.isValid, shown > lastPulled {
            let step = (shown - lastPulled).seconds
            if step > 0.01 { frameDuration = min(frameDuration ?? step, step) }
        }
        if lastPulled.isValid, shown < lastPulled { restartPresentation() }
        lastPulled = shown
        let generation = self.generation
        tap.advance(to: shown.seconds)
        logCountersIfDue()

        guard let frame = tap.frame(at: shown.seconds) else {
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
        let rpu = frame.composedRpu
        let pulledAt = CACurrentMediaTime()
        let shownTime = shown
        composer.composeAsync(baseBuffer: base, enhancementBuffer: enhancement, params: params, frameIndex: frameIndex) { [weak self] composed in
            guard let self else { return }
            let ms = (CACurrentMediaTime() - pulledAt) * 1000
            self.countersLock.withLock { self._counters.maxComposeMs = max(self._counters.maxComposeMs, ms) }
            self.lastComposeMs = ms
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
                self.enqueue(composed, at: shownTime)
            }
        }
    }

    /// Render queue: what the layer holds belongs to the position the clock just left.
    /// Render queue: sets the synchronizer to the item's rate and time at one host instant, the item's clock
    /// read at that same instant.
    private func followItemClock() {
        guard let itemTimebase else { return }
        let hostClock = CMClockGetHostTimeClock()
        let host = CMClockGetTime(hostClock)
        let time = CMSyncConvertTime(host, from: hostClock, to: itemTimebase)
        synchronizer.setRate(Float(CMTimebaseGetRate(itemTimebase)), time: time, atHostTime: host)
    }

    /// Render queue, about once a second: how far the synchronizer (host clock) has drifted from the item
    /// (audio clock), and a follow when it is past `followTolerance`.
    private func checkFollow() {
        let now = CACurrentMediaTime()
        guard now - lastFollowCheck >= 1, let itemTimebase else { return }
        lastFollowCheck = now
        let hostClock = CMClockGetHostTimeClock()
        let host = CMClockGetTime(hostClock)
        let drift = (CMSyncConvertTime(host, from: hostClock, to: synchronizer.timebase)
                     - CMSyncConvertTime(host, from: hostClock, to: itemTimebase)).seconds
        let refollow = synchronizer.rate != 0 && abs(drift) > Self.followTolerance
        timing.drift(ms: drift * 1000, refollowed: refollow)
        if refollow { followItemClock() }
    }

    private func restartPresentation() {
        io.flush(removingDisplayedImage: false)
        layer.sampleBufferRenderer.presentationTimeExpectation = .monotonicallyIncreasing
        lastPulled = .invalid
        generation += 1
    }

    private func enqueue(_ buffer: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format)
        guard let format else { return }
        let duration = frameDuration.map { CMTime(seconds: $0, preferredTimescale: 90_000) } ?? .invalid
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        do {
            let lead = (time - synchronizer.currentTime()).seconds
            if lead < 0 { countersLock.withLock { _counters.late += 1 } }
            self.timing.composed(ms: lastComposeMs, leadMs: lead * 1000, frameDuration: frameDuration)
        }
        _ = io.enqueue(sample)
        countersLock.withLock { _counters.composed += 1 }
        onComposed?(time, buffer)
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
            _counters.maxTickGapMs = 0
            return c
        }
        let held = tap.held
        EngineLog.emit("[FelOverlayRenderer] pulled \(c.pulled), composed \(c.composed), skipped \(c.skipped), late \(c.late), "
                       + "residual off \(c.residualOff), not ready \(c.notReady), compose failed \(c.composeFailed), "
                       + String(format: "max compose %.0f ms, max loop gap %.0f ms, ", c.maxComposeMs, c.maxTickGapMs)
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
