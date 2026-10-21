import AVFoundation

/// Keeps a tvOS HDMI route in Dolby Atmos while the engine's `AVPlayer` plays an APAC track.
///
/// tvOS hands APAC to the receiver as Dolby MAT, and some sinks show Dolby Atmos for that on their own.
/// Not all do: a Samsung HW-Q990C fed by an Apple TV 4K (tvOS 27.2) played APAC without ever showing
/// Atmos, although `AVAudioSession` reported a MAT format throughout. A second, unmuted player looping
/// a silent E-AC-3 stream signalled as Dolby Atmos brought it to Atmos before the first frame and kept
/// it there across a seek. Nothing the app can read tracked the indicator; only the sink shows it.
///
/// The stream (`Resources/silent-atmos.mp4`, written bit by bit by `Scripts/make-silent-atmos.swift`)
/// decodes to digital silence, so nothing is mixed into the programme. It plays only while the host
/// player plays or waits to play an item `playsAPAC` accepts, and is released otherwise, since a
/// prerolled E-AC-3 stream would compete with other audio.
///
/// #834: it runs only while every output port is HDMI. On an AirPlay route there is no sink indicator
/// to light, and a second unmuted player restarting beside the programme on every resume left a
/// HomePod pair silent after a pause, then froze the picture after the second one.
@MainActor
final class AtmosOutputActivator {
    static let silentAtmosStream = Bundle.module.url(forResource: "silent-atmos", withExtension: "mp4")!

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private weak var host: AVPlayer?
    private var playsAPAC: @MainActor (AVPlayerItem) -> Bool = { _ in false }
    /// A programme that is not an `AVPlayer` (the software host): whether it plays APAC and is paused.
    /// It has nothing to observe, so its owner calls `refresh()` when either may have changed.
    private var programme: (playsAPAC: @MainActor () -> Bool, isPaused: @MainActor () -> Bool)?
    private var observations: [NSKeyValueObservation] = []
    private var selectionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private let outputPortTypes: @MainActor () -> [String]
    private var loggedRouteVerdict: Bool?

    init(outputPortTypes: @escaping @MainActor () -> [String] = AtmosOutputActivator.currentOutputPortTypes) {
        self.outputPortTypes = outputPortTypes
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

    /// Follows `host`: its item, its audio selection and whether it is playing.
    func attach(to host: AVPlayer, playsAPAC: @escaping @MainActor (AVPlayerItem) -> Bool) {
        detach()
        self.host = host
        self.playsAPAC = playsAPAC
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

    /// Follows a programme the engine plays without an `AVPlayer`: the software host, whose
    /// `AVSampleBufferAudioRenderer` sends APAC to the sink as multichannel PCM until this runs beside it.
    func attach(playsAPAC: @escaping @MainActor () -> Bool, isPaused: @escaping @MainActor () -> Bool) {
        detach()
        programme = (playsAPAC, isPaused)
        observeRoute()
        update()
    }

    /// Re-reads an `attach(playsAPAC:isPaused:)` programme's state.
    func refresh() {
        guard programme != nil else { return }
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
        observations.forEach { $0.invalidate() }
        observations = []
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        host = nil
        programme = nil
        loggedRouteVerdict = nil
        follow(nil)
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
        if let programme {
            guard programme.playsAPAC() else {
                release()
                return
            }
            paused = programme.isPaused()
        } else {
            guard let host, let item = host.currentItem, playsAPAC(item) else {
                release()
                return
            }
            paused = host.timeControlStatus == .paused
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
            player.pause()
            return
        }
        if looper == nil {
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: Self.silentAtmosStream))
        }
        player.play()
    }

    private func release() {
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
            activator.attach(to: player) { [weak self] _ in self?.nativeVideoSession?.audioIsAPAC == true }
        } else if let host = softwareHost, host.audioIsAPAC {
            // The software host plays APAC through its own renderer (the Dolby Vision FEL route): followed
            // by the engine's state, which `state`'s didSet refreshes. Loading and seeking count as playing,
            // as an AVPlayer waiting to play does on the HLS route: the TV's format banner reads the audio
            // when the panel finishes its Dolby Vision switch, which lands while the session still loads, and
            // started only at `.playing` the stream came too late for it to say Atmos.
            let activator = atmosOutputActivator ?? AtmosOutputActivator()
            atmosOutputActivator = activator
            activator.attach(
                playsAPAC: { [weak self, weak host] in host != nil && self?.softwareHost === host },
                isPaused: { [weak self] in
                    guard let state = self?.state else { return true }
                    return ![.playing, .loading, .seeking].contains(state)
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
        activator.attach(playsAPAC: { [weak self] in self?.state == .loading }, isPaused: { false })
        #endif
    }

    /// #597: a media services reset invalidates the activator's own `AVQueuePlayer` along with the engine's,
    /// and the engine only rebuilds its own. Dropped here, the next `currentAVPlayer` builds a fresh one.
    func dropAtmosOutputActivator() {
        atmosOutputActivator?.detach()
        atmosOutputActivator = nil
    }
}
