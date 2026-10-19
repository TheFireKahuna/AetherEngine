import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import os

/// Audio output via AVSampleBufferAudioRenderer + AVSampleBufferRenderSynchronizer. The synchronizer is the
/// **master clock** for the whole player: video frames check synchronizer.currentTime() to decide presentation.
final class AudioOutput: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer
    let synchronizer: AVSampleBufferRenderSynchronizer

    /// AE#395: the renderers' axis. Every time this object takes or returns is on the source axis;
    /// the conversion happens here, at the renderer and synchronizer calls, and in the video renderer
    /// that shares this timeline.
    let timeline = RendererTimeline()

    private let lock = NSLock()

    /// AE#464: the host's audio presentation offset, applied to every buffer on its way into the
    /// renderer. Guarded because the host writes it from the main actor while the demux thread reads
    /// it in `enqueue`.
    private var presentationOffset: CMTime = .zero

    /// One line per offset change, not per buffer. Reset by `setPresentationOffset`.
    private var loggedOffsetInEffect = false

    /// Audit DEC-106: retired by every `flush()` and `stop()`, under `lock`. A feed loop reads it before
    /// it reads a packet and enqueues through `enqueue(sampleBuffer:ifEpoch:)`, which compares under the
    /// same lock, so a buffer decided on before a seek's flush can no longer land after it.
    private var _epoch: UInt64 = 0
    var epoch: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _epoch
    }

    /// Whether renderers join the synchronizer through `sampleBufferReceiver(adding:)` (tvOS / macOS 27) rather
    /// than the `addRenderer` / `removeRenderer` pair the 27 SDKs deprecate. Only the attach and detach move:
    /// buffers still go to the renderers themselves, which a receiver-attached renderer accepts (checked on
    /// macOS 27). Process-wide, read at each attach; a switch back to the old pair for A/B on a device,
    /// since this attach path is where tvOS has failed before (-12080, #351). Earlier systems always use it.
    static var usesSampleBufferReceivers: Bool {
        get { receiverSwitch.withLock { $0 } }
        set { receiverSwitch.withLock { $0 = newValue } }
    }
    private static let receiverSwitch = OSAllocatedUnfairLock(initialState: true)

    /// The receivers the renderers were attached with. Typed `AnyObject` because the receiver types exist
    /// only on 27. The video one is what `removeReceiver(_:at:)` takes; the audio renderer is never removed
    /// (it lives as long as the synchronizer), and its receiver is held anyway: dropping one did not detach
    /// its renderer on macOS 27, but that is not documented, so neither is let go while attached. Guarded
    /// by `lock`.
    private var audioReceiver: AnyObject?
    private var videoReceiver: AnyObject?

    init() {
        renderer = AVSampleBufferAudioRenderer()
        synchronizer = AVSampleBufferRenderSynchronizer()
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *), Self.usesSampleBufferReceivers {
            audioReceiver = synchronizer.sampleBufferReceiver(adding: renderer)
        } else {
            synchronizer.addRenderer(renderer)
        }

        // Spatial audio for AirPods Pro/Max and HomePod: renderer spatializes multichannel when system-enabled.
        renderer.allowedAudioSpatializationFormats = .multichannel

        // Rate changes ride the synchronizer timebase, and this renderer's algorithm is what decides
        // whether they keep pitch (#434). Pinned here, while the timebase is still stopped.
        AudioRatePolicy.apply(to: renderer)
        observeAutomaticFlush()
    }

    deinit {
        if let automaticFlushObserver {
            NotificationCenter.default.removeObserver(automaticFlushObserver)
        }
    }

    /// The synchronizer's rate. A stopped clock and a running clock whose timebase has stalled read
    /// differently here and nowhere else, which is the whole reason AE#549 needs it (see
    /// `RendererClockResume`).
    var rate: Float {
        synchronizer.rate
    }

    /// AE#395: the renderer's own view of its queue, for the diagnostic line: `status/sufficient/error`.
    /// A session that is silent on one route while its clock runs at 1.00 has nothing else that could
    /// say whether the renderer is playing what it was given, and the renderer error was only ever
    /// logged in DEBUG builds.
    var diagRendererState: String {
        let status: String
        switch renderer.status {
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        case .unknown: status = "unknown"
        @unknown default: status = "?"
        }
        let sufficient = renderer.hasSufficientMediaDataForReliablePlaybackStart ? "y" : "n"
        let error = (renderer.error as NSError?).map { "\($0.domain)/\($0.code)" } ?? "-"
        return "\(status)/\(sufficient)/\(error)"
    }

    /// AE#549: how often this renderer has flushed itself, for the diagnostic line.
    var automaticFlushCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _automaticFlushCount
    }

    private var automaticFlushObserver: NSObjectProtocol?
    private var _automaticFlushCount = 0

    /// Where the AE#549 flush runs. The posting thread must never wait on `lock`: `enqueue` holds it
    /// across `renderer.enqueue` (DEC-106), and a renderer that posts from inside that call would make the
    /// feed thread wait on a lock it already holds, with every `flush()` / `stop()` / `seekClock()` behind it.
    private let automaticFlushQueue = DispatchQueue(label: "engine.audio.autoflush")

    /// AE#549: the renderer throws its queue away when the route changes under it, and posts the
    /// timestamp of the first sample it dropped. Nothing in the engine observed that, so the lead
    /// that was discarded was neither re-fed nor mentioned anywhere.
    ///
    /// Two things happen here, both out of the header's own guidance. The second flush is its stated
    /// best practice: the notification arrives on an arbitrary thread, so a buffer enqueued
    /// concurrently with it survives, and a survivor sits in the queue stamped far ahead of the
    /// timebase, muting the session for as long as it takes the clock to reach it. Re-feeding from
    /// the timebase is deliberately NOT attempted: the demuxer stands at the audio lead by then and
    /// the sources this happens to are exactly the ones that cannot seek backwards, so the honest
    /// outcome is a gap of up to that lead, and then sync as before.
    ///
    /// The line is also the witness the field log lacked. Across an automatic flush the timebase
    /// keeps RUNNING at its rate, so a session that froze did not freeze because of this, and only a
    /// log carrying both can tell the two apart.
    private func observeAutomaticFlush() {
        automaticFlushObserver = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let flushedFrom = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)
                .map { self.timeline.sourceTime(forRenderer: $0.timeValue).seconds }
            automaticFlushQueue.async { [weak self] in
                guard let self else { return }
                lock.lock()
                _automaticFlushCount += 1
                let count = _automaticFlushCount
                renderer.flush()
                lock.unlock()
                EngineLog.emit(
                    "[AudioOutput] AE#549 renderer flushed itself (#\(count)): "
                    + "dropped from \(flushedFrom.map { String(format: "%.3f", $0) } ?? "unknown")s, "
                    + "clock at \(String(format: "%.3f", currentTimeSeconds))s rate=\(rate); "
                    + "audio returns once the feed reaches the clock",
                    category: .swPlayback
                )
            }
        }
    }

    /// Add the video renderer to the synchronizer for automatic A/V sync + frame pacing. The display layer's
    /// `sampleBufferRenderer`, never the layer: addRenderer(layer) still type-checks but on tvOS 26+ fails with
    /// FigVideoQueueRemote err=-12080 after the first enqueue. Taken as the renderer rather than read off the
    /// layer here, because the layer is main-actor isolated in the 27 SDKs and this runs off it (#351).
    func attachVideoRenderer(_ videoRenderer: AVSampleBufferVideoRenderer) {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *), Self.usesSampleBufferReceivers {
            let receiver = synchronizer.sampleBufferReceiver(adding: videoRenderer)
            lock.lock()
            videoReceiver = receiver
            lock.unlock()
        } else {
            synchronizer.addRenderer(videoRenderer)
        }
    }

    /// Remove the video renderer and block until removal completes. The synchronizer detaches asynchronously;
    /// if the caller immediately assigns displayLayer.controlTimebase for a new Atmos session the layer is briefly
    /// owned by both (Apple-documented UB). Symptom: first PCM->Atmos switch after launch throws FigVideoQueueRemote
    /// err=-12080 and the display layer stops rendering (audio keeps going). The semaphore wait (sub-100ms) makes
    /// the handoff deterministic.
    func detachVideoRenderer(_ videoRenderer: AVSampleBufferVideoRenderer) {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        let attachedReceiver = videoReceiver
        videoReceiver = nil
        lock.unlock()
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = attachedReceiver as? AVSampleBufferVideoRenderer.Receiver {
            // Attached through a receiver: removed through it, the async counterpart of removeRenderer.
            Self.removeReceiver(receiver, from: synchronizer, at: synchronizer.currentTime()) { semaphore.signal() }
        } else {
            synchronizer.removeRenderer(videoRenderer, at: synchronizer.currentTime()) { _ in
                semaphore.signal()
            }
        }
        let result = semaphore.wait(timeout: .now() + .seconds(1))
        #if DEBUG
        if result == .timedOut {
            EngineLog.emit("[AudioOutput] detachVideoRenderer: timed out waiting for synchronizer removal", category: .swPlayback)
        }
        #endif
    }

    /// Removes a receiver-attached video renderer and calls `done` once the synchronizer has, off the caller's
    /// thread. The receiver is handed over (`sending`): nothing else holds it once `detachVideoRenderer` cleared
    /// `videoReceiver`.
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    private static func removeReceiver(_ receiver: sending AVSampleBufferVideoRenderer.Receiver,
                                       from synchronizer: AVSampleBufferRenderSynchronizer,
                                       at time: CMTime, done: @escaping @Sendable () -> Void) {
        // A closure's captures cannot be `sending` (the compiler cannot know it runs once); this one
        // runs once and is the receiver's only holder, which is what the opt-out below asserts.
        nonisolated(unsafe) let handedOver = receiver
        // Off the caller's executor and off the cooperative pool (BlockingWork): the caller (the host's stop(),
        // on the main actor) blocks on `done` for up to a second, as it did on removeRenderer's callback.
        BlockingWork.detached {
            nonisolated(unsafe) let receiver = handedOver
            _ = await synchronizer.removeReceiver(receiver, at: time)
            done()
        }
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Set playback speed (0.5-2.0). Hosts own rate state (lastRate/pausedByHost); this object is stateless about it.
    func setRate(_ rate: Float) {
        // A host resumes right after it arms the clock; while a preroll waits, that rate is the one
        // the preroll starts at, not a start of its own.
        if rate > 0, updatePrerollRate(rate) { return }
        // A clock that stands still starts through the preroll on a session that has one: a seek
        // landed while paused anchors at rate 0 and never asks the gate, so the play that follows
        // would otherwise start it with nothing queued.
        if rate > 0, synchronizer.rate == 0, videoPrerollSatisfied?(currentTime.seconds) != nil {
            seekClock(to: currentTime, rate: rate)
            return
        }
        cancelPreroll()
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] setRate \(rate) at t=\(String(format: "%.3f", timeline.sourceSeconds(forRenderer: at.seconds)))", category: .swPlayback)
        synchronizer.setRate(rate, time: at)
    }

    /// Pause audio (and the master clock). Hosts resume via setRate (pausedByHost pattern); deliberately no resume() here.
    func pause() {
        cancelPreroll()
        let at = synchronizer.currentTime()
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", timeline.sourceSeconds(forRenderer: at.seconds)))", category: .swPlayback)
        synchronizer.setRate(0.0, time: at)
    }

    /// Pause the master clock, at `latest` if it has already run past it. A park deferred to the last
    /// sample runs whenever its task is scheduled, and on a starved main actor that is after the clock
    /// has walked on (#694: 1.149 s on a 1.0 s source on a CI runner).
    func pause(notAfter latest: Double) {
        cancelPreroll()
        let now = timeline.sourceTime(forRenderer: synchronizer.currentTime())
        let seconds = SoftwareEndOfMediaClock.parkSeconds(clockSeconds: CMTimeGetSeconds(now), notAfter: latest)
        let at = seconds.map { CMTime(seconds: $0, preferredTimescale: 90000) } ?? now
        EngineLog.emit("[AudioOutput] pause at t=\(String(format: "%.3f", at.seconds))", category: .swPlayback)
        synchronizer.setRate(0.0, time: timeline.rendererTime(forSource: at))
    }

    /// AE#464: set the audio presentation offset. Positive presents audio later than video, which on
    /// this path means stamping its samples further ahead on the synchronizer's timeline: at clock
    /// time t the renderer then plays what was recorded at t minus the offset, while the video layer
    /// still presents t. Applied to buffers enqueued from here on; the samples already inside the
    /// renderer keep the previous offset until something flushes them.
    func setPresentationOffset(seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        presentationOffset = seconds == 0 ? .zero : CMTime(seconds: seconds, preferredTimescale: 90000)
        loggedOffsetInEffect = false
    }

    /// Enqueue a decoded audio CMSampleBuffer. Always enqueues (renderer buffers internally); gating on
    /// isReadyForMoreMediaData dropped early samples before the synchronizer started, giving silence.
    ///
    /// Audit DEC-106: with `epoch`, the buffer is enqueued only if no flush has retired that epoch, and the
    /// comparison and the enqueue happen under the lock `flush` takes. Returns false, enqueuing nothing,
    /// for a buffer that predates a flush.
    ///
    /// AE#464: this is where a lip-sync offset is applied, and the position is the point. It is past
    /// the audio tap (whose `sourceTime` is documented as the SOURCE axis and feeds transcription),
    /// past the decoder's gapless clock (which would absorb a sub-100 ms offset as rounding), and
    /// past the caller's `lastEnqueuedAudioPtsSec` bookkeeping (whose lead is measured against the
    /// synchronizer clock, i.e. against the source axis too). Only the renderer sees the shift.
    @discardableResult
    func enqueue(sampleBuffer: CMSampleBuffer, ifEpoch epoch: UInt64? = nil) -> Bool {
        lock.lock()
        if let epoch, epoch != _epoch {
            lock.unlock()
            return false
        }
        let offset = presentationOffset
        // AE#395: the lip-sync offset and the move onto the renderer axis are one retime, not two copies.
        let shift = CMTimeSubtract(offset, timeline.offset(latchingFrom: sampleBuffer))
        let delivered = shift == .zero ? sampleBuffer : Self.retimed(sampleBuffer, by: shift)
        var offsetLine: String?
        if offset != .zero, !loggedOffsetInEffect, delivered !== sampleBuffer {
            loggedOffsetInEffect = true
            // Release-visible, once per offset change: an offset that was set and an offset that is being
            // DELIVERED are different claims, and without this line the difference is only measurable with
            // a capture card. The two timestamps are the whole proof.
            let source = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            offsetLine = "[AudioOutput] AE#464 audio delay in effect: "
                + String(format: "%+.0f ms", offset.seconds * 1000)
                + String(format: " (sample at %.3fs delivered at %.3fs)", source, source + offset.seconds)
        }
        renderer.enqueue(delivered)
        #if DEBUG
        afterRendererEnqueueForTesting?()
        #endif
        lock.unlock()
        if let offsetLine { EngineLog.emit(offsetLine, category: .swPlayback) }

        #if DEBUG
        // Once per session: first enqueue + any renderer rejection, to distinguish "nothing enqueued" from
        // "renderer rejected our format".
        if !_loggedFirstEnqueue {
            _loggedFirstEnqueue = true
            let fmt = CMSampleBufferGetFormatDescription(sampleBuffer).flatMap {
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }
            let sr = fmt.map { "\($0.mSampleRate)Hz" } ?? "?"
            let ch = fmt.map { "\($0.mChannelsPerFrame)ch" } ?? "?"
            let count = CMSampleBufferGetNumSamples(sampleBuffer)
            EngineLog.emit("[AudioOutput] first enqueue: \(sr) \(ch), \(count) samples, renderer.error=\(String(describing: renderer.error))", category: .swPlayback)
        } else if let err = renderer.error, !_loggedRendererError {
            _loggedRendererError = true
            EngineLog.emit("[AudioOutput] renderer error: \(err)", category: .swPlayback)
        }
        #endif
        return true
    }

    #if DEBUG
    /// Test-only: runs inside `enqueue`'s locked section, right after the renderer took the buffer, which
    /// is where a renderer that posts its notifications from inside `enqueue` would post them.
    var afterRendererEnqueueForTesting: (@Sendable () -> Void)?
    private var _loggedFirstEnqueue = false
    private var _loggedRendererError = false
    #endif

    /// The shift itself, pure so it can be checked without a renderer. Every timing entry moves
    /// by `offset`, presentation and decode alike; an entry with no valid presentation stamp is left
    /// alone rather than given one. A copy that cannot be made is delivered unshifted: an audible
    /// lip-sync error is a far better outcome than a dropped buffer, which is silence.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer {
        guard offset != .zero else { return sampleBuffer }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &count) == noErr,
              count > 0 else { return sampleBuffer }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: Int(count))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: count,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else {
            return sampleBuffer
        }
        for i in timings.indices where timings[i].presentationTimeStamp.isValid {
            timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset)
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset)
            }
        }
        var shifted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                    sampleBuffer: sampleBuffer,
                                                    sampleTimingEntryCount: count,
                                                    sampleTimingArray: &timings,
                                                    sampleBufferOut: &shifted) == noErr,
              let shifted else { return sampleBuffer }
        return shifted
    }

    var currentTime: CMTime {
        timeline.sourceTime(forRenderer: synchronizer.currentTime())
    }

    /// AE#395: the master clock on the source axis, for an overlay paced against it (#311). The
    /// synchronizer's own timebase until the origin latches at a non-zero value, then a child of it
    /// shifted by that origin, which follows every rate change of its parent by construction. Read it
    /// per use rather than holding it across a session start.
    var sourceTimebase: CMTimebase {
        guard let origin = timeline.origin, origin != 0 else { return synchronizer.timebase }
        lock.lock()
        defer { lock.unlock() }
        if let shiftedTimebase { return shiftedTimebase }
        var child: CMTimebase?
        guard CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault,
                                                 sourceTimebase: synchronizer.timebase,
                                                 timebaseOut: &child) == noErr,
              let child,
              CMTimebaseSetRateAndAnchorTime(child, rate: 1, anchorTime: RendererTimeline.cmTime(origin),
                                             immediateSourceTime: .zero) == noErr else {
            return synchronizer.timebase
        }
        shiftedTimebase = child
        return child
    }
    private var shiftedTimebase: CMTimebase?

    var currentTimeSeconds: Double {
        let t = CMTimeGetSeconds(currentTime)
        return t.isFinite ? t : 0
    }

    /// Whether the audio renderer can accept more samples. The combined demux loop normally paces on the
    /// video renderer; in background-audio-only mode (video dropped) it paces on this instead, so it does
    /// not buffer the rest of the file unbounded.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// Flush the audio renderer (call on seek).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        _epoch &+= 1
        renderer.flush()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        _epoch &+= 1
        disarmPreroll()
        synchronizer.setRate(0.0, time: .zero)
        renderer.flush()
    }

    /// Atomically jump the master clock to a time and resume at a rate. The ONLY way the clock is (re)anchored:
    /// demux loops call it once on the first decoded packet, seek paths call it directly. Avoids the
    /// falling-through-time races that pause -> flush -> setRate would expose.
    func seekClock(to time: CMTime, rate: Float) {
        // Asked before taking `lock`: the gate reads the video renderer's state under its own lock.
        let preroll = rate > 0 ? videoPrerollSatisfied?(time.seconds) : nil
        // Read before `lock` too: the route's latency is an audio-session query.
        let lead = preroll == true ? Self.currentPrerollStartLead() : 0
        lock.lock()
        defer { lock.unlock() }
        EngineLog.emit("[AudioOutput] seekClock to=\(String(format: "%.3f", time.seconds)) rate=\(rate)", category: .swPlayback)
        disarmPreroll()
        guard let preroll else {
            synchronizer.setRate(rate, time: timeline.rendererTime(forSource: time))
            return
        }
        if preroll {
            startAfterPreroll(rate: rate, time: time, lead: lead)
            return
        }
        synchronizer.setRate(0, time: timeline.rendererTime(forSource: time))
        let gen = prerollGeneration
        prerollRate = rate
        prerollTime = time
        prerollStarted = CACurrentMediaTime()
        prerollWake.withLock { $0 = PrerollWake(generation: gen) }
        // The fallback: one tick at the timeout, cancelled by whatever ends the wait first.
        let timer = DispatchSource.makeTimerSource(queue: prerollQueue)
        timer.schedule(deadline: .now() + (prerollTimeoutOverride ?? Self.prerollTimeout))
        timer.setEventHandler { [weak self] in self?.evaluatePreroll(gen: gen, timedOut: true) }
        prerollTimer = timer
        timer.resume()
        // Frames handed over between the question above and now told nobody: ask once more.
        videoPrerollAdvanced()
    }

    // MARK: - Video preroll

    /// Whether the video renderer holds enough to start the clock at a source time: nil when this
    /// session does not preroll, so the clock starts at once as it always has. Set by the software
    /// host (`SampleBufferRenderer.prerollSatisfied(clock:live:)`): the FEL route since #774, every
    /// other VOD route since #800.
    ///
    /// The video queue is filled with the timebase stopped and the clock starts only once that is done,
    /// the same idea as `AVPlayer.preroll(atRate:)`. Starting at full rate the moment
    /// the first packet arrives made the first composed FEL frames late on arrival: five dropped
    /// frames at every start and every seek on an Apple TV 4K (A12). With the preroll, `seekClock`
    /// anchors at rate 0, and the clock starts at the requested rate and the same source time once
    /// the renderer is ready, or after `prerollTimeout`. A pause, a rate change or another seek in the
    /// meantime cancels the start; `stop()` too. The gate is asked again only when the renderer hands
    /// a frame over (``videoPrerollAdvanced()``), not on a timer.
    var videoPrerollSatisfied: (@Sendable (Double) -> Bool?)? {
        get { lock.lock(); defer { lock.unlock() }; return _videoPrerollSatisfied }
        set { lock.lock(); _videoPrerollSatisfied = newValue; lock.unlock() }
    }
    private var _videoPrerollSatisfied: (@Sendable (Double) -> Bool?)?  // guarded by lock

    /// How long a preroll may hold the clock. A decoder that never delivers must not freeze playback.
    static let prerollTimeout: Double = 2
    /// Tests that prove a start came from a handover set this long, so the fallback timer cannot fire
    /// while a loaded test runner is still between its steps. Set before `seekClock`.
    var prerollTimeoutOverride: Double?

    /// How far ahead of now a prerolled start is scheduled, at most. On tvOS the synchronizer lives in
    /// another process, and the display path learns of a rate change about as late as the audio route's
    /// output latency (138 ms measured on HDMI): a clock started "now" has already run that far when the
    /// first frames are judged, and the ones due inside that window drop (3 to 5 a start on the A12 even
    /// with the queue full). Scheduling the start 250 ms out took starts and seeks to 0 drops in every
    /// run (8 of 8, 150 s soaks with 5 seeks; 500 ms was no better).
    ///
    /// The ceiling, not the lead: ``prerollStartLead(outputLatency:)`` follows the route, so a start on
    /// a route faster than that HDMI sink is not held for latency it does not have. Never longer than
    /// this, because a buffered AirPlay route reports seconds of latency the display path does not wait
    /// for, and because 250 ms is the measured, drop-free figure.
    static let prerollStartLeadCeiling: Double = 0.25

    /// What the lead adds to the route's output latency: 112 ms, so the measured HDMI route (138 ms)
    /// gets exactly the 250 ms that was validated on it. Process-wide and settable, for tuning on a device
    /// against the renderer's dropped-frame count (`AetherEngine.prerollStartMargin`).
    static var prerollStartMargin: Double {
        get { prerollStartMarginSwitch.withLock { $0 } }
        set { prerollStartMarginSwitch.withLock { $0 = max(0, newValue) } }
    }
    private static let prerollStartMarginSwitch = OSAllocatedUnfairLock(initialState: 0.112)

    /// The prerolled start's lead for a route reporting `outputLatency` seconds: that latency plus the
    /// margin, capped at the ceiling. Without a latency (no `AVAudioSession`, as on macOS), the ceiling.
    static func prerollStartLead(outputLatency: Double?, margin: Double = prerollStartMargin) -> Double {
        guard let latency = outputLatency, latency.isFinite, latency >= 0 else { return prerollStartLeadCeiling }
        return min(prerollStartLeadCeiling, latency + max(0, margin))
    }

    /// ``prerollStartLead(outputLatency:)`` for the current audio route.
    static func currentPrerollStartLead() -> Double {
        #if os(iOS) || os(tvOS)
        prerollStartLead(outputLatency: AVAudioSession.sharedInstance().outputLatency)
        #else
        prerollStartLead(outputLatency: nil)
        #endif
    }

    /// The lead the last prerolled start was scheduled with, in seconds; nil before the first.
    var lastPrerollStartLead: Double? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPrerollStartLead
    }
    private var _lastPrerollStartLead: Double?  // guarded by lock

    private var prerollGeneration = 0  // guarded by lock
    private var prerollRate: Float?  // guarded by lock; non-nil while a preroll waits: the rate it starts at
    private var prerollTime = CMTime.invalid  // guarded by lock; the source time a waiting preroll starts at
    private var prerollStarted: CFTimeInterval = 0  // guarded by lock
    private var prerollTimer: DispatchSourceTimer?  // guarded by lock; the waiting preroll's timeout
    private let prerollQueue = DispatchQueue(label: "aether.audio.preroll", qos: .userInteractive)

    /// What a handover needs to know to wake a waiting preroll, behind its own lock so the decode
    /// thread never waits on `lock` (held across synchronizer calls, which are IPC on tvOS). Taken
    /// inside `lock` when a preroll is armed or disarmed, and alone everywhere else; never the
    /// other way round. `queued` coalesces a burst of handovers into one evaluation.
    private struct PrerollWake {
        var generation: Int?
        var queued = false
    }
    private let prerollWake = OSAllocatedUnfairLock(initialState: PrerollWake())

    /// Whether a preroll holds the clock at rate 0 to start it later. A host must not read that
    /// standing clock as stalled (AE#549) and restart it.
    var prerollPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return prerollRate != nil
    }

    /// Prerolled starts so far, the immediate ones included; and whether the last waiting one was
    /// started by its timeout rather than by the gate. Diagnostics for tests: exactly one start per
    /// preroll, and the one the handover triggered.
    var prerollStartCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _prerollStartCount
    }
    private var _prerollStartCount = 0  // guarded by lock
    var lastPrerollTimedOut: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPrerollTimedOut
    }
    private var _lastPrerollTimedOut: Bool?  // guarded by lock

    /// The gate's inputs moved: the renderer handed a frame over (`SampleBufferRenderer.setPrerollAdvancedObserver`).
    /// Callable from any thread and never blocks: it queues one evaluation on `prerollQueue` if a
    /// preroll waits and none is queued yet. This replaced a poll every 2 ms, which kept the gate's
    /// lock and this one busy about 300 times a second through every wait (measured on macOS) and
    /// saw an opened gate a median 3.0 ms late (7.1 ms at worst, timer leeway); this sees it in 0.02 ms.
    func videoPrerollAdvanced() {
        let gen: Int? = prerollWake.withLock { wake in
            guard let gen = wake.generation, !wake.queued else { return nil }
            wake.queued = true
            return gen
        }
        guard let gen else { return }
        prerollQueue.async { [weak self] in self?.evaluatePreroll(gen: gen, timedOut: false) }
    }

    /// Asks the gate for the preroll armed as `gen`, and starts the clock if it is open or the
    /// timeout has come. On `prerollQueue` only, so a handover and the timeout are judged one at a
    /// time; the generation, read again under `lock` after the gate answered, makes the first of them
    /// the only start and lets a pause, seek or stop in the meantime win.
    private func evaluatePreroll(gen: Int, timedOut: Bool) {
        // A handover from here on queues another evaluation: this one may read the gate before it.
        prerollWake.withLock { if $0.generation == gen { $0.queued = false } }
        lock.lock()
        let current = prerollGeneration == gen && prerollRate != nil
        let time = prerollTime
        let started = prerollStarted
        lock.unlock()
        guard current else { return }
        let ready = videoPrerollSatisfied?(time.seconds) != false
        guard ready || timedOut else { return }
        let waited = CACurrentMediaTime() - started
        let lead = Self.currentPrerollStartLead()
        lock.lock()
        defer { lock.unlock() }
        guard prerollGeneration == gen, let rate = prerollRate else { return }
        disarmPreroll()
        _lastPrerollTimedOut = !ready
        EngineLog.emit("[AudioOutput] preroll \(ready ? "ready" : "timed out") after "
                       + "\(String(format: "%.0f", waited * 1000)) ms; starting at t=\(String(format: "%.3f", time.seconds)) rate=\(rate)",
                       category: .swPlayback)
        startAfterPreroll(rate: rate, time: time, lead: lead)
    }

    /// Starts the clock `lead` seconds from now (``currentPrerollStartLead()``, read by the caller before
    /// it took `lock`). Called with `lock` held.
    private func startAfterPreroll(rate: Float, time: CMTime, lead: Double) {
        _lastPrerollStartLead = lead
        _prerollStartCount += 1
        EngineLog.emit("[AudioOutput] start lead \(String(format: "%.0f", lead * 1000)) ms", category: .swPlayback, level: .verbose)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let host = CMTimeAdd(hostNow, CMTime(seconds: lead, preferredTimescale: 1_000_000_000))
        synchronizer.setRate(rate, time: timeline.rendererTime(forSource: time), atHostTime: host)
    }

    private func cancelPreroll() {
        lock.lock()
        disarmPreroll()
        lock.unlock()
    }

    /// Ends any waiting preroll: its generation moves on, so a handover or timeout already queued for
    /// it finds nothing to start. Called with `lock` held.
    private func disarmPreroll() {
        prerollGeneration &+= 1
        prerollRate = nil
        prerollTimer?.cancel()
        prerollTimer = nil
        prerollWake.withLock { $0 = PrerollWake() }
    }

    private func updatePrerollRate(_ rate: Float) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard prerollRate != nil else { return false }
        prerollRate = rate
        return true
    }
}
