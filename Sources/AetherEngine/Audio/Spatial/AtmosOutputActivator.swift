import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine plays an APAC track: through its `AVPlayer`,
/// or through the software host's sample-buffer audio renderer (the Dolby Vision FEL route).
///
/// tvOS hands APAC to the receiver as Dolby MAT, and some sinks show Dolby Atmos for that on their own.
/// Not all do: a Samsung HW-Q990C fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing
/// Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player looping
/// a silent E-AC-3 stream signalled as Dolby Atmos brought it to Atmos before the first frame and kept
/// it there across a seek. Nothing the app can read tracked the indicator; only the sink shows it.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts (and for a short grace after a pause,
/// see #848), and is released otherwise, since a prerolled E-AC-3 stream would compete with other audio.
///
/// #834: it runs only while every output port is HDMI. On an AirPlay route there is no sink indicator
/// to light, and a second unmuted player restarting beside the programme on every resume left a
/// HomePod pair silent after a pause, then froze the picture after the second one.
///
/// #848: a host pause no longer pauses it at once. Stopping the stream let the output leave Dolby
/// Atmos, and a Samsung HW-Q990H re-locked on every resume and scrub, sometimes with a short dropout.
/// It keeps playing for `pauseGrace` and pauses only if the host is still paused then. The grace is
/// bounded because a playing player keeps the receiver busy and counts as audio playing, and a long
/// pause re-locking once on resume is the lesser cost; it ends before tvOS's shortest screen saver
/// delay of two minutes.
///
/// The software host plays APAC through an `AVSampleBufferAudioRenderer`, and an Apple TV 4K (tvOS 26.6)
/// whose receiver showed Atmos for the AVPlayer route's APAC did not show it for the same title's APAC on
/// that renderer. There the activator follows the host's transport instead of a player (`attachRenderer`).
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    /// While the host is starting a programme that plays APAC: the stream plays whatever the host is doing,
    /// because the host is paused until the start and the sink reads the link as the display switch ends,
    /// before it.
    private var startingUp: @MainActor () -> Bool = { false }
    /// Set by `attachRenderer`: whether the renderer path is playing (or waiting to), nil once it is gone.
    private var rendererIsPlaying: (@MainActor () -> Bool?)?
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private let outputPortTypes: @MainActor () -> [String]
    private var loggedRouteVerdict: Bool?
    private let pauseGrace: Duration
    private var pauseAfterGrace: Task<Void, Never>?
    /// When the host the stream follows paused, while the stream plays on through the grace.
    private var hostPausedAt: ContinuousClock.Instant?

    nonisolated static let defaultPauseGrace: Duration = .seconds(60)

    init(
        outputPortTypes: @escaping @MainActor () -> [String] = AtmosOutputActivator.currentOutputPortTypes,
        pauseGrace: Duration = AtmosOutputActivator.defaultPauseGrace
    ) {
        self.outputPortTypes = outputPortTypes
        self.pauseGrace = pauseGrace
        player.automaticallyWaitsToMinimizeStalling = false
    }

    /// True only for a route whose every output is HDMI: the sink the stream exists for. An empty
    /// route is one in transition, and the route change that ends it re-evaluates.
    nonisolated static func routeTakesActivator(outputPortTypes: [String]) -> Bool {
        !outputPortTypes.isEmpty && outputPortTypes.allSatisfy { $0 == hdmiPortType }
    }

    /// `AVAudioSession.Port.HDMI.rawValue`, spelled out so the rule is testable where there is no session.
    /// The value is "HDMIOutput", as the session logs it (`AudioRouteDescription`); "HDMI" matched no
    /// route, and the activator stayed off on every HDMI sink.
    nonisolated static let hdmiPortType = "HDMIOutput"

    static func currentOutputPortTypes() -> [String] {
        #if os(iOS) || os(tvOS)
        AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
        #else
        []
        #endif
    }

    /// Follows `host`: its item, its audio selection and whether it is playing. While `startingUp` holds, the
    /// stream plays through the host's paused startup and the item swap that opens it.
    func attach(to host: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool,
                startingUp: @escaping @MainActor () -> Bool = { false }) {
        stopObserving()
        self.host = host
        self.playsAPAC = playsAPAC
        self.startingUp = startingUp
        observeRoute()
        // A host play() changes timeControlStatus synchronously on the main thread, so the stream
        // starts inside that call, ahead of the APAC output.
        observations = [
            host.observe(\.currentItem, options: [.initial]) { [weak self] _, _ in
                Self.onMain { self?.follow(self?.host?.currentItem) }
            },
            host.observe(\.timeControlStatus) { [weak self] _, _ in
                Self.onMain { self?.update() }
            },
        ]
    }

    /// Follows a renderer path that plays object audio (the software host, whose
    /// `AVSampleBufferAudioRenderer` sends APAC to the sink as multichannel PCM until this runs beside it).
    /// `isPlaying` answers true while it plays or waits to, false while paused, and nil once the session is
    /// gone; the engine calls `refresh()` whenever its transport state changes, since a renderer has nothing
    /// to observe.
    func attachRenderer(isPlaying: @escaping @MainActor () -> Bool?) {
        stopObserving()
        rendererIsPlaying = isPlaying
        observeRoute()
        update()
    }

    /// Re-reads the renderer path's transport, or the host's startup.
    func refresh() {
        guard rendererIsPlaying != nil || host != nil else { return }
        update()
    }

    private func observeRoute() {
        #if os(iOS) || os(tvOS)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Self.onMain { self?.update() }
        }
        #endif
    }

    func detach() {
        stopObserving()
        follow(nil)
    }

    /// Everything `detach()` drops except the stream itself, so a re-attach carries a playing stream across
    /// to the next thing it follows instead of stopping it in between.
    private func stopObserving() {
        observations.forEach { $0.invalidate() }
        observations = []
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = nil
        host = nil
        rendererIsPlaying = nil
        startingUp = { false }
        loggedRouteVerdict = nil
    }

    /// What the stream does beside an `AVPlayer` host: nil to release it, true to play, false to pause.
    /// `itemPlaysAPAC` is nil while the host has no item, which during a startup is the swap to the next one.
    nonisolated static func hostVerdict(itemPlaysAPAC: Bool?, hostPaused: Bool, startingUp: Bool) -> Bool? {
        switch itemPlaysAPAC {
        case false?: return nil
        case nil: return startingUp ? true : nil
        case true?: return !hostPaused || startingUp
        }
    }

    private func follow(_ item: AVPlayerItem?) {
        if let selectionObserver { NotificationCenter.default.removeObserver(selectionObserver) }
        selectionObserver = item.map {
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: $0, queue: .main
            ) { [weak self] _ in
                Self.onMain { self?.update() }
            }
        }
        update()
    }

    private func update() {
        let paused: Bool
        if let rendererIsPlaying {
            guard let playing = rendererIsPlaying() else {
                // The session is gone: drop the route observer with the stream, not just the stream.
                detach()
                return
            }
            paused = !playing
        } else {
            guard let host,
                  let plays = Self.hostVerdict(itemPlaysAPAC: host.currentItem.map { playsAPAC($0) },
                                               hostPaused: host.timeControlStatus == .paused,
                                               startingUp: startingUp()) else {
                release()
                return
            }
            paused = !plays
        }
        let ports = outputPortTypes()
        let routeTakesIt = Self.routeTakesActivator(outputPortTypes: ports)
        if loggedRouteVerdict != routeTakesIt {
            loggedRouteVerdict = routeTakesIt
            EngineLog.emit(
                "[AtmosOutputActivator] \(routeTakesIt ? "active" : "off") on route ports=[\(ports.joined(separator: ", "))]",
                category: .session
            )
        }
        guard routeTakesIt else {
            release()
            return
        }
        guard !paused else {
            holdThroughPause()
            return
        }
        pauseAfterGrace?.cancel()
        pauseAfterGrace = nil
        hostPausedAt = nil
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    /// True while the silent stream is playing.
    var isPlayingStream: Bool { player.rate != 0 }

    /// Keeps the stream playing through `pauseGrace` from the host's pause, then pauses it. The grace's end asks
    /// `update()` again rather than pausing outright, so a host that started playing without a refresh in between
    /// keeps its stream.
    private func holdThroughPause() {
        guard isPlayingStream else {
            hostPausedAt = nil
            return
        }
        let now = ContinuousClock.now
        let pausedAt = hostPausedAt ?? now
        hostPausedAt = pausedAt
        let remaining = pauseGrace - (now - pausedAt)
        guard remaining > .zero else {
            pauseAfterGrace?.cancel()
            pauseAfterGrace = nil
            hostPausedAt = nil
            player.pause()
            return
        }
        guard pauseAfterGrace == nil else { return }
        pauseAfterGrace = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled, let self else { return }
            self.pauseAfterGrace = nil
            self.update()
        }
    }

    private func release() {
        pauseAfterGrace?.cancel()
        pauseAfterGrace = nil
        hostPausedAt = nil
        guard let looper else { return }
        player.pause()
        looper.disableLooping()
        self.looper = nil
        player.removeAllItems()
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

extension AetherEngine {
    /// tvOS only: the switch is an HDMI one, and on iOS and macOS a second unmuted player beside the
    /// engine's would compete with it for Now Playing and the audio session for no gain.
    func followAtmosOutput() {
        #if os(tvOS)
        if let player = currentAVPlayer {
            let activator = atmosOutputActivator ?? AtmosOutputActivator()
            atmosOutputActivator = activator
            activator.attach(
                to: player,
                playsAPAC: { [weak self] _ in self?.nativeVideoSession?.audioIsAPAC == true },
                // The session is built before its player is published, so it already knows what it plays.
                startingUp: { [weak self] in
                    self?.state == .loading && self?.nativeVideoSession?.audioIsAPAC == true
                })
        } else {
            atmosOutputActivator?.detach()
        }
        #endif
    }

    /// From before the display criteria write to the end of the load: the session about to start will play
    /// APAC (`loadInternal` checked its track). The banner an LG G5 shows when the panel finishes its switch
    /// to Dolby Vision read Dolby Vision alone on the FEL route, whose activator otherwise starts only once
    /// the software host has loaded, after that switch; AVPlayer with both running from the start showed Dolby
    /// Vision and Atmos.
    /// The load's own `followAtmosOutput` (software host) or `currentAVPlayer` (native) takes over, and a load
    /// that ends some other way releases it as the state leaves `.loading`.
    func anticipateAtmosOutput() {
        #if os(tvOS)
        let activator = atmosOutputActivator ?? AtmosOutputActivator()
        atmosOutputActivator = activator
        activator.attachRenderer { [weak self] in self?.state == .loading ? true : nil }
        #endif
    }

    /// The software host's transport as the activator reads it: true while playing or about to (a seek,
    /// the load's own start), false while paused, nil once the session has ended or failed.
    nonisolated static func softwareAtmosOutputPlaying(_ state: PlaybackState) -> Bool? {
        switch state {
        case .playing, .seeking, .loading: return true
        case .paused: return false
        case .idle, .ended, .error: return nil
        }
    }

    /// #597: a media services reset invalidates the activator's own `AVQueuePlayer` along with the engine's,
    /// and the engine only rebuilds its own. Dropped here, the next `currentAVPlayer` builds a fresh one.
    func dropAtmosOutputActivator() {
        atmosOutputActivator?.detach()
        atmosOutputActivator = nil
    }
}
