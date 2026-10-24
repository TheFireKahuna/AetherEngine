import AVFoundation
import AVKit
import CoreMedia
import UIKit

// The `placeholder` arms: can the software route live inside AVPlayer? AVPlayer plays a placeholder clip
// (a flat picture in the source's real format, with the source's audio) in an AVPlayerViewController, its
// rendering suppressed through an AVPlayerItemVideoOutput. The picture comes from frames we decode ourselves
// (here VideoToolbox through AVAssetReader, standing in for dav1d), enqueued on an AVSampleBufferDisplayLayer
// inside AVKit's player layer and timed by the item's clock. What the arm shows:
//
// - the display mode tvOS picks from the placeholder (top-left readout);
// - whose Dolby Vision metadata reaches the panel, the overlay's or AVPlayer's (the pulse clips switch only
//   the RPU, so a visible pulse names the side it came from);
// - whether the soundbar shows Atmos (the placeholder carries E-AC-3 JOC);
// - whether AVKit's transport bar runs, and whether the overlay follows pauses and seeks (press the remote);
// - every second, how far the frame on screen is from the item's clock (`[Placeholder] tick` lines).
//
// Params: `src=<clip>` (required, absolute or relative to the placeholder): the clip the overlay decodes;
// `strip=1`: drop the Dolby Vision attachments from the overlay's frames (HDR10 from the overlay);
// `suppress=0`: leave AVPlayer's own rendering on (the placeholder shows under the overlay);
// `clock=item|copy`: the overlay layer's timebase is a child of the item's (default), or a host-clock copy
// re-anchored to it on every jump and rate change; `controls=0`: hide the transport bar;
// `seeks=at@to,...`: seek at `at` seconds into the arm to `to` seconds of the clip; `secs=N` (default 40);
// `criteria=src`: the display criteria come from the `src=` clip's format (set by the host, as the engine does
// on the FEL overlay route) instead of AVKit's automatic criteria from the placeholder.
//
// Device result 2026-10-24: with a `dvh1` placeholder AVPlayer's own RPU reaches the panel and the overlay's
// does not (GD steady, GX pulsing). The FEL overlay route avoids that by serving AVPlayer `hvc1` with Dolby
// Vision only as a supplemental codec and setting Dolby Vision criteria itself; `criteria=src` on the HDR10
// placeholder is that arrangement.

@MainActor
final class PlaceholderSession {
    let player: AVPlayer
    let item: AVPlayerItem
    let overlay: PlaceholderOverlay
    let showsControls: Bool
    /// AVKit picks the display mode from the placeholder; false when the host sets it (`criteria=src`).
    let automaticCriteria: Bool
    private let output: AVPlayerItemVideoOutput
    private let drain: PlaceholderDrain
    private let log: @Sendable (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var kvo: [NSKeyValueObservation] = []

    init(placeholder: URL, source: AVURLAsset, track: AVAssetTrack, params: [String: String],
         log: @escaping @Sendable (String) -> Void) {
        self.log = log
        item = AVPlayerItem(url: placeholder)
        player = AVPlayer(playerItem: item)
        showsControls = params["controls"] != "0"
        automaticCriteria = params["criteria"] != "src"
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
        output.suppressesPlayerRendering = params["suppress"] != "0"
        drain = PlaceholderDrain(output: output)
        overlay = PlaceholderOverlay(asset: source, track: track, strip: params["strip"] == "1",
                                     clock: params["clock"] == "copy" ? .copy : .item, log: log)
        item.add(output)
        log("placeholder \(placeholder.lastPathComponent) source=\(source.url.lastPathComponent) "
            + "suppress=\(output.suppressesPlayerRendering) strip=\(params["strip"] == "1") clock=\(params["clock"] ?? "item")")
    }

    /// Plays for `seconds`, looping the clip, with `seeks` (arm seconds, clip seconds) along the way.
    func run(seconds: Double, seeks: [(at: Double, to: Double)]) async {
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log("placeholder looped")
                    self?.player.seek(to: .zero) { _ in }
                }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tb = self.item.timebase else { return }
                    self.overlay.timeJumped(itemTimebase: tb, to: CMTimebaseGetTime(tb))
                }
            })
        kvo.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log("timeControlStatus=\(player.timeControlStatus.rawValue) rate=\(player.rate)")
                if let tb = self.item.timebase { self.overlay.rateChanged(itemTimebase: tb) }
            }
        })
        defer { stop() }

        let readyBy = Date().addingTimeInterval(15)
        while item.status != .readyToPlay || item.timebase == nil {
            if item.status == .failed || Date() > readyBy {
                log("placeholder item not ready: status=\(item.status.rawValue) error=\(String(describing: item.error))")
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let itemTimebase = item.timebase else { return }
        await logTracks()
        overlay.start(itemTimebase: itemTimebase)
        drain.start()
        player.play()

        let started = Date()
        var pending = seeks.sorted { $0.at < $1.at }
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if item.status == .failed {
                log("placeholder item failed: \(String(describing: item.error))")
                break
            }
            let elapsed = Date().timeIntervalSince(started)
            if let next = pending.first, elapsed >= next.at {
                pending.removeFirst()
                log(String(format: "seek to=%.2f", next.to))
                await player.seek(to: CMTime(seconds: next.to, preferredTimescale: 24000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            log(overlay.tick(itemTimebase: itemTimebase) + " placeholderFrames=\(drain.count)")
        }
        log("placeholder end: " + overlay.summary() + " placeholderFrames=\(drain.count)")
    }

    private func logTracks() async {
        for track in item.tracks {
            guard let asset = track.assetTrack,
                  let fd = try? await asset.load(.formatDescriptions).first else { continue }
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "\(sub)"
            log("placeholder track \(asset.mediaType.rawValue) \(fourCC) enabled=\(track.isEnabled)")
        }
        let session = AVAudioSession.sharedInstance()
        log("audio route: \(session.currentRoute.outputs.map { "\($0.portType.rawValue)" }) "
            + "ch=\(session.outputNumberOfChannels) max=\(session.maximumOutputNumberOfChannels)")
    }

    private func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        kvo.forEach { $0.invalidate() }
        kvo = []
        drain.stop()
        player.pause()
        overlay.stop()
        if item.outputs.contains(output) { item.remove(output) }
    }
}

/// Pulls and drops what AVPlayer decodes from the placeholder, so its output never backs up. The count is the
/// placeholder frames AVPlayer decoded.
nonisolated final class PlaceholderDrain: @unchecked Sendable {
    private let output: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "dv-pulse.placeholder.drain")
    private var timer: DispatchSourceTimer?
    private var pulled = 0
    private let lock = NSLock()

    init(output: AVPlayerItemVideoOutput) { self.output = output }

    var count: Int { lock.withLock { pulled } }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(10))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = self.output.itemTime(forHostTime: CACurrentMediaTime())
            guard self.output.hasNewPixelBuffer(forItemTime: now),
                  self.output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil else { return }
            self.lock.withLock { self.pulled += 1 }
        }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// The overlay: frames decoded from the source clip, on a display layer whose clock is the player item's.
/// Frames carry their source timestamps, so the layer shows each one when the item's clock reaches it; a
/// jump (seek, loop) restarts the decode at the new time.
nonisolated final class PlaceholderOverlay: @unchecked Sendable {
    enum Clock { case item, copy }

    let layer = AVSampleBufferDisplayLayer()
    nonisolated(unsafe) private let asset: AVURLAsset
    nonisolated(unsafe) private let track: AVAssetTrack
    private let strip: Bool
    private let clock: Clock
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dv-pulse.placeholder.feed")
    private let copier = PulseFrameCopier()

    // Feed-queue state.
    private var reader: AVAssetReader?
    private var generation = 0
    private var timebase: CMTimebase?

    // Shared with the main actor's tick.
    private let lock = NSLock()
    private var surfacePTS: [IOSurfaceID: Double] = [:]
    private var surfaceOrder: [IOSurfaceID] = []
    private var enqueued = 0, failures = 0, restarts = 0, rpuFrames = 0
    private var lags: [Double] = []

    init(asset: AVURLAsset, track: AVAssetTrack, strip: Bool, clock: Clock, log: @escaping @Sendable (String) -> Void) {
        self.asset = asset
        self.track = track
        self.strip = strip
        self.clock = clock
        self.log = log
        layer.videoGravity = .resizeAspect
        // AVPlayer's own picture is suppressed, so this layer is the one playing video.
        layer.preventsDisplaySleepDuringVideoPlayback = true
    }

    func start(itemTimebase: CMTimebase) {
        var tb: CMTimebase?
        switch clock {
        case .item:
            CMTimebaseCreateWithSourceTimebase(allocator: kCFAllocatorDefault, sourceTimebase: itemTimebase, timebaseOut: &tb)
            if let tb {
                let now = CMTimebaseGetTime(itemTimebase)
                CMTimebaseSetRateAndAnchorTime(tb, rate: 1, anchorTime: now, immediateSourceTime: now)
            }
        case .copy:
            CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        }
        guard let tb else { log("overlay timebase failed"); return }
        layer.controlTimebase = tb
        let at = CMTimebaseGetTime(itemTimebase)
        queue.async {
            self.timebase = tb
            self.syncCopy(itemTimebase)
            self.restart(at: at)
        }
    }

    func timeJumped(itemTimebase: CMTimebase, to time: CMTime) {
        queue.async {
            self.syncCopy(itemTimebase)
            self.restart(at: time)
        }
    }

    func rateChanged(itemTimebase: CMTimebase) {
        queue.async { self.syncCopy(itemTimebase) }
    }

    func stop() {
        queue.sync {
            generation += 1
            layer.sampleBufferRenderer.stopRequestingMediaData()
            reader?.cancelReading()
            reader = nil
        }
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        layer.removeFromSuperlayer()
    }

    /// `clock=copy`: our host-clock timebase set to the item's time and rate as of now.
    private func syncCopy(_ itemTimebase: CMTimebase) {
        guard clock == .copy, let timebase else { return }
        let host = CMClockGetHostTimeClock()
        let hostNow = CMClockGetTime(host)
        let itemNow = CMSyncConvertTime(hostNow, from: host, to: itemTimebase)
        CMTimebaseSetRateAndAnchorTime(timebase, rate: CMTimebaseGetRate(itemTimebase), anchorTime: itemNow,
                                       immediateSourceTime: hostNow)
    }

    /// Feed queue: drop what was queued for the old position and decode from `time`.
    private func restart(at time: CMTime) {
        generation += 1
        let gen = generation
        let renderer = layer.sampleBufferRenderer
        renderer.stopRequestingMediaData()
        reader?.cancelReading()
        reader = nil
        renderer.flush()
        lock.withLock { restarts += 1 }

        // Start at the requested time; the reader decodes from the keyframe before it on its own.
        let start = CMTimeMaximum(.zero, time)
        do {
            let r = try AVAssetReader(asset: asset)
            r.timeRange = CMTimeRange(start: start, end: .positiveInfinity)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
            out.alwaysCopiesSampleData = false
            r.add(out)
            guard r.startReading() else {
                log("overlay reader failed: \(String(describing: r.error))")
                return
            }
            reader = r
            log(String(format: "overlay restart at %.3f (restart %d)", start.seconds, gen))
            nonisolated(unsafe) let output = out
            renderer.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self, self.generation == gen else { return }
                while renderer.isReadyForMoreMediaData {
                    guard let sb = output.copyNextSampleBuffer() else {
                        renderer.stopRequestingMediaData()
                        return
                    }
                    let enq = self.strip ? self.copier.transform(sb, mode: "vtstrip") : sb
                    guard let enq, let pb = CMSampleBufferGetImageBuffer(enq) else {
                        self.lock.withLock { self.failures += 1 }
                        continue
                    }
                    let pts = CMSampleBufferGetPresentationTimeStamp(enq).seconds
                    let hasRPU = CVBufferCopyAttachment(pb, "DolbyVisionRPUData" as CFString, nil) != nil
                    if let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() {
                        self.remember(IOSurfaceGetID(surface), pts: pts)
                    }
                    self.lock.withLock {
                        self.enqueued += 1
                        if hasRPU { self.rpuFrames += 1 }
                    }
                    renderer.enqueue(enq)
                }
            }
        } catch {
            log("overlay reader error: \(error)")
        }
    }

    private func remember(_ id: IOSurfaceID, pts: Double) {
        lock.withLock {
            if surfacePTS.updateValue(pts, forKey: id) == nil { surfaceOrder.append(id) }
            if surfaceOrder.count > 96 { surfacePTS[surfaceOrder.removeFirst()] = nil }
        }
    }

    /// One line: the item's clock, the overlay's, the frame on screen and how far it is from the item's clock.
    func tick(itemTimebase: CMTimebase) -> String {
        let itemNow = CMTimebaseGetTime(itemTimebase).seconds
        let layerNow = layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? .nan
        let shownID = layer.sampleBufferRenderer.displayedPixelBuffer()
            .flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() }
            .map { IOSurfaceGetID($0) }
        return lock.withLock {
            let shown = shownID.flatMap { surfacePTS[$0] }
            let lag = shown.map { ($0 - itemNow) * 1000 }
            if let lag { lags.append(lag) }
            return String(format: "[Placeholder] tick item=%.3f layer=%.3f shown=%@ lag=%@ enq=%d rpu=%d fail=%d restarts=%d status=%d",
                          itemNow, layerNow, shown.map { String(format: "%.3f", $0) } ?? "-",
                          lag.map { String(format: "%.1fms", $0) } ?? "-", enqueued, rpuFrames, failures, restarts,
                          layer.sampleBufferRenderer.status.rawValue)
        }
    }

    func summary() -> String {
        lock.withLock {
            let sorted = lags.sorted()
            func pct(_ p: Double) -> String {
                sorted.isEmpty ? "-" : String(format: "%.1f", sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))])
            }
            return "enq=\(enqueued) rpu=\(rpuFrames) fail=\(failures) restarts=\(restarts) "
                + "lagMs(min/p50/max)=\(pct(0))/\(pct(0.5))/\(pct(0.999)) samples=\(sorted.count)"
        }
    }
}

/// The arm's picture: AVKit plays the placeholder and picks the display mode from it; the overlay sits in
/// AVKit's player layer above the (suppressed) video and below the subtitles.
final class PlaceholderPlayerController: AVPlayerViewController {
    private let session: PlaceholderSession
    private var installed = false

    init(session: PlaceholderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        showsPlaybackControls = session.showsControls
        appliesPreferredDisplayCriteriaAutomatically = session.automaticCriteria
        player = session.player
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        install()
        if let host = session.overlay.layer.superlayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            session.overlay.layer.frame = host.bounds
            CATransaction.commit()
        }
    }

    /// FelOverlayRenderer.install(in:)'s placement: inside AVPlayerLayer's intermediate layer, under
    /// `FigSubtitleCALayer`; on top of the player layer when that shape is not found.
    private func install() {
        guard !installed, let root = viewIfLoaded?.layer, let playerLayer = Self.playerLayer(of: session.player, in: root) else { return }
        installed = true
        let overlay = session.overlay.layer
        overlay.videoGravity = playerLayer.videoGravity
        let intermediate = playerLayer.sublayers?.first {
            String(describing: type(of: $0)) == "AVPlayerLayerIntermediateLayer" && !$0.isHidden
        }
        if let intermediate,
           let subtitles = intermediate.sublayers?.firstIndex(where: { String(describing: type(of: $0)) == "FigSubtitleCALayer" }) {
            intermediate.insertSublayer(overlay, at: UInt32(subtitles))
            overlay.frame = intermediate.bounds
            PulseLog.shared.note("[Placeholder] overlay installed below AVKit's subtitles")
        } else {
            playerLayer.addSublayer(overlay)
            overlay.frame = playerLayer.bounds
            PulseLog.shared.note("[Placeholder] overlay installed on top of the player layer (subtitle layer not found)")
        }
    }

    private static func playerLayer(of player: AVPlayer, in layer: CALayer) -> AVPlayerLayer? {
        if let candidate = layer as? AVPlayerLayer, candidate.player === player { return candidate }
        for sub in layer.sublayers ?? [] {
            if let hit = playerLayer(of: player, in: sub) { return hit }
        }
        return nil
    }
}
