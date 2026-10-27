import Foundation
import AVFoundation
#if os(tvOS)
import UIKit
import AVKit
import VideoToolbox
import Darwin
import notify
#endif

/// A diagnostic that logs every public reading of the display the engine could route on, beside the private
/// readings that say what the display is really doing, so a normal viewing session shows which public ones can be
/// trusted. Off unless the host starts it; tvOS only (elsewhere every entry point is a no-op).
///
/// What it reads, on each event and in follow-ups after it:
///
/// - Public, AVFoundation/AVKit: `AVPlayer.eligibleForHDRPlayback` and `availableHDRModes` with their change
///   notifications; `AVDisplayManager`'s matching and switch-in-progress flags (KVO) and its three notifications;
///   an HLS variant oracle (`VariantOracle`) that asks AVPlayer itself which HDR formats it will start on.
/// - Public, UIKit: the screen's mode, maximum frame rate, native bounds, EDR headroom, gamut, headroom-usage limit,
///   calibrated latency and reference-mode status with their notifications; the output refresh rate measured from a
///   display link's ticks; the app's lifecycle, with follow-ups at the 0.7 s and 2.5 s marks AE#535 measured.
/// - Public libc, private names, `DEBUG` builds only: the Darwin notify keys PineBoard publishes for a switch in
///   progress and for a display-state change.
/// - Public, audio: the route's ports and channels, rendering mode and spatial capability (the eARC end of the chain).
/// - Reference, private, `DEBUG` builds only: `CADisplay`'s current mode (its HDR mode, bit depth, colour mode, refresh) and HDR-mode
///   lists, and `PBSDisplayManager`'s separate dynamic-range and frame-rate matching flags. Read off the main
///   thread, since the PineBoard client's first use waits on its service.
///
/// The private names stay out of a Release binary, the build that goes to App Review; there `notifySwitch` reads `?`
/// and no reference line is logged.
///
/// Every line is `[DisplaySignals]` in the `display.signals` category; one event's lines share its `#n`.
public enum DisplaySignalProbe {

    /// Starts observing and logs a first snapshot. Idempotent.
    @MainActor public static func start() {
        #if os(tvOS)
        DisplaySignalRuntime.shared.start()
        #endif
    }

    /// The engine has a session from here to `sessionEnded`; the oracle never runs while any engine has one.
    @MainActor static func sessionBegan(_ owner: AnyObject) {
        #if os(tvOS)
        DisplaySignalRuntime.running?.sessionBegan(owner)
        #endif
    }

    @MainActor static func sessionEnded(_ owner: AnyObject) {
        #if os(tvOS)
        DisplaySignalRuntime.running?.sessionEnded(owner)
        #endif
    }

    /// A snapshot labelled by the engine's own moment (a criteria write, a readout), when the probe is running.
    @MainActor static func snapshot(trigger: String) {
        #if os(tvOS)
        DisplaySignalRuntime.running?.snapshot(trigger)
        #endif
    }
}

#if os(tvOS)

@MainActor
final class DisplaySignalRuntime {

    static let shared = DisplaySignalRuntime()
    /// The runtime once started, so the engine's hooks cost nothing when it never is.
    static var running: DisplaySignalRuntime? { shared.started ? shared : nil }

    private var started = false
    private var sequence = 0
    private var tokens: [NSObjectProtocol] = []
    private var switchObservation: NSKeyValueObservation?
    private var notifyTokens: [Int32] = []
    private var switchActiveToken: Int32 = NOTIFY_TOKEN_INVALID
    private var sessions: [ObjectIdentifier: WeakOwner] = [:]
    private var cadence: CadenceSampler?
    private var oracleTask: Task<Void, Never>?
    /// Which scheduled run `oracleTask` is, so a cancelled run finishing late does not clear a newer one's handle.
    private var oracleGeneration = 0
    private var lastOracleRun: ContinuousClock.Instant?
    #if DEBUG
    private let referenceQueue = DispatchQueue(label: "aetherengine.display-signals.reference")
    #endif

    /// The oracle is spent once per this interval at most, whatever asks for it.
    private static let oracleInterval: Duration = .seconds(60)

    private struct WeakOwner { weak var owner: AnyObject? }

    private func emit(_ line: String) {
        EngineLog.emit(line, category: .displaySignals)
    }

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    // MARK: - Start

    func start() {
        guard !started else { return }
        started = true
        let process = ProcessInfo.processInfo
        emit(DisplaySignals.line("start", [
            ("os", process.operatingSystemVersionString),
            ("model", UIDevice.current.model),
            ("hevcHW", DisplaySignals.yn(VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC))),
            ("dvHW", DisplaySignals.yn(VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC))),
        ]))
        observeNotifications()
        #if DEBUG
        observeNotifyKeys()
        #endif
        snapshot("start")
        measureCadence("start", after: .milliseconds(500))
        scheduleOracle("start", after: .seconds(5))
    }

    // MARK: - Sessions

    func sessionBegan(_ owner: AnyObject) {
        sessions[ObjectIdentifier(owner)] = WeakOwner(owner: owner)
        if oracleTask != nil {
            emit(DisplaySignals.line("oracle", [("event", "abandoned"), ("reason", "session began")]))
            oracleTask?.cancel()
            oracleTask = nil
        }
    }

    func sessionEnded(_ owner: AnyObject) {
        sessions[ObjectIdentifier(owner)] = nil
        // After the stop's criteria reset has had time to switch the panel back.
        if activeSessions == 0 { scheduleOracle("idle", after: .seconds(8)) }
    }

    private var activeSessions: Int {
        sessions = sessions.filter { $0.value.owner != nil }
        return sessions.count
    }

    // MARK: - Observation

    private func observeNotifications() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ handler: @escaping @MainActor (Posted) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let posted = Posted(note)
                MainActor.assumeIsolated { handler(posted) }
            })
        }

        // AVKit posts these three from its private shared manager, never from `window.avDisplayManager`, so the
        // object is nil (AE#667). Settings-changed fires on every PineBoard display-state change, mode switches
        // included, not only on a change in Settings.
        on(.AVDisplayManagerModeSwitchStart) { [weak self] note in self?.event("modeSwitchStart", note) }
        on(.AVDisplayManagerModeSwitchEnd) { [weak self] note in
            guard let self else { return }
            event("modeSwitchEnd", note, followUps: [.seconds(1), .seconds(3)])
            measureCadence("modeSwitchEnd", after: .milliseconds(500))
        }
        on(.AVDisplayManagerModeSwitchSettingsChanged) { [weak self] note in
            guard let self else { return }
            event("modeSwitchSettingsChanged", note)
            scheduleOracle("settingsChanged", after: .seconds(4))
        }
        on(AVPlayer.eligibleForHDRPlaybackDidChangeNotification) { [weak self] note in
            guard let self else { return }
            event("eligibleForHDRChanged", note, followUps: [.seconds(1)])
            scheduleOracle("eligibleChanged", after: .seconds(4))
        }
        // Deprecated in the 26 SDKs with its property, which is still the only per-mode table; by name, so the
        // observation itself does not carry the deprecation.
        on(Notification.Name("AVPlayerAvailableHDRModesDidChangeNotification")) { [weak self] note in
            self?.event("availableHDRModesChanged", note)
        }
        on(UIScreen.modeDidChangeNotification) { [weak self] note in
            guard let self else { return }
            event("screenModeChanged", note)
            measureCadence("screenModeChanged", after: .milliseconds(500))
        }
        on(UIScreen.referenceDisplayModeStatusDidChangeNotification) { [weak self] note in
            self?.event("referenceModeStatusChanged", note)
        }
        on(AVAudioSession.routeChangeNotification) { [weak self] note in
            let reason = note.routeChangeReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            self?.event("audioRouteChanged", note, detail: [("reason", Self.name(reason))])
        }
        on(AVAudioSession.renderingModeChangeNotification) { [weak self] note in
            self?.event("audioRenderingModeChanged", note)
        }
        on(AVAudioSession.spatialPlaybackCapabilitiesChangedNotification) { [weak self] note in
            self?.event("spatialCapabilitiesChanged", note)
        }
        // AE#535: the capability table and the Match-Content flag were measured revoked 0.7 s and 2.5 s into the
        // background and restored on return; the follow-ups land on those marks.
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
        ]
        for (name, label) in lifecycle {
            on(name) { [weak self] note in
                guard let self else { return }
                event(label, note, followUps: [.milliseconds(700), .milliseconds(2500)])
                if label == "didBecomeActive" {
                    measureCadence(label, after: .seconds(1))
                    scheduleOracle(label, after: .seconds(5))
                }
            }
        }
    }

    /// The flag's own KVO, attached once a window exists to ask for the manager.
    private func observeSwitchFlagIfPossible(_ manager: AVDisplayManager) {
        guard switchObservation == nil else { return }
        switchObservation = manager.observe(\.isDisplayModeSwitchInProgress, options: [.new]) { [weak self] _, change in
            let value = change.newValue
            Task { @MainActor in
                self?.event("switchInProgressKVO", nil, detail: [("value", value.map(DisplaySignals.yn) ?? "?")])
            }
        }
    }

    #if DEBUG
    /// PineBoard's Darwin keys, through the public notify API. `display_mode_switch_active` carries state (1 during
    /// a switch, 0 after; AVKit reads exactly this); `PBSDisplayStateChangedModification` is the ping PineBoard's
    /// client refetches its display state on.
    private func observeNotifyKeys() {
        for key in ["com.apple.pineboard.display_mode_switch_active", "PBSDisplayStateChangedModification"] {
            var token: Int32 = NOTIFY_TOKEN_INVALID
            let status = notify_register_dispatch(key, &token, DispatchQueue.main) { [weak self] token in
                MainActor.assumeIsolated {
                    var state: UInt64 = 0
                    let read = notify_get_state(token, &state)
                    self?.event("notify", nil, detail: [("key", key),
                                                        ("state", read == NOTIFY_STATUS_OK ? String(state) : "err\(read)")],
                                followUps: [.milliseconds(500)])
                }
            }
            emit(DisplaySignals.line("notify", [("key", key), ("registered", status == NOTIFY_STATUS_OK ? "y" : "err\(status)")]))
            guard status == NOTIFY_STATUS_OK else { continue }
            notifyTokens.append(token)
            if key.hasSuffix("display_mode_switch_active") { switchActiveToken = token }
        }
    }
    #endif

    // MARK: - Events and snapshots

    /// What the probe keeps of a notification: its sender's type and its userInfo, as text, so nothing
    /// non-sendable crosses into the main actor's closure.
    struct Posted: Sendable {
        let object: String
        let userInfo: String?
        let routeChangeReason: UInt?

        init(_ note: Notification) {
            object = note.object.map { String(describing: type(of: $0)) } ?? "nil"
            let info = note.userInfo ?? [:]
            userInfo = info.isEmpty ? nil
                : DisplaySignals.brief(info.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ","))
            routeChangeReason = info[AVAudioSessionRouteChangeReasonKey] as? UInt
        }
    }

    private func event(_ name: String, _ note: Posted?, detail: [(String, String)] = [],
                       followUps: [Duration] = []) {
        var fields: [(String, String)] = [("name", name)]
        if let note {
            fields.append(("object", note.object))
            if let info = note.userInfo { fields.append(("userInfo", info)) }
        }
        fields += detail
        let n = snapshot(name, extra: fields)
        for delay in followUps {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: delay)
                self?.snapshot("\(name)+\(Self.label(delay))", extra: [("after", "#\(n)")])
            }
        }
    }

    @discardableResult
    func snapshot(_ trigger: String, extra: [(String, String)] = []) -> Int {
        let n = nextSequence()
        let window = Self.window()
        emit(DisplaySignals.line("#\(n) display", [("trigger", trigger)] + extra + displayFields(window)))
        emit(DisplaySignals.line("#\(n) audio", audioFields()))
        #if DEBUG
        readReference(n)
        #endif
        return n
    }

    private func displayFields(_ window: UIWindow?) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("app", Self.name(UIApplication.shared.applicationState)),
            ("sessions", String(activeSessions)),
            ("eligible", DisplaySignals.yn(AVPlayer.eligibleForHDRPlayback)),
            ("modes", Self.modes(AVPlayer.availableHDRModes)),
        ]
        guard let window else { return fields + [("window", "none")] }
        let manager = window.avDisplayManager
        observeSwitchFlagIfPossible(manager)
        let screen = window.screen
        var switchActive = "?"
        if switchActiveToken != NOTIFY_TOKEN_INVALID {
            var state: UInt64 = 0
            if notify_get_state(switchActiveToken, &state) == NOTIFY_STATUS_OK { switchActive = String(state) }
        }
        fields += [
            ("matching", DisplaySignals.yn(manager.isDisplayCriteriaMatchingEnabled)),
            ("switching", DisplaySignals.yn(manager.isDisplayModeSwitchInProgress)),
            ("notifySwitch", switchActive),
            ("criteria", manager.preferredDisplayCriteria == nil ? "nil" : "set"),
            ("screenMode", screen.currentMode.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"),
            ("par", screen.currentMode.map { String(format: "%.3f", $0.pixelAspectRatio) } ?? "nil"),
            ("maxFPS", String(screen.maximumFramesPerSecond)),
            ("native", "\(Int(screen.nativeBounds.width))x\(Int(screen.nativeBounds.height))@\(screen.nativeScale)"),
            ("edr", String(format: "%.2f/%.2f", screen.currentEDRHeadroom, screen.potentialEDRHeadroom)),
            ("gamut", Self.name(window.traitCollection.displayGamut)),
            ("screenGamut", Self.name(screen.traitCollection.displayGamut)),
            ("latency", String(format: "%.4f", screen.calibratedLatency)),
            ("referenceStatus", Self.name(screen.referenceDisplayModeStatus)),
        ]
        if #available(tvOS 26.0, *) {
            fields.append(("headroomLimit", Self.name(window.traitCollection.hdrHeadroomUsageLimit)))
        }
        return fields
    }

    private func audioFields() -> [(String, String)] {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { port in
            "\(port.portType.rawValue):\(port.portName):\(port.channels?.count ?? 0)ch:spatial=\(DisplaySignals.yn(port.isSpatialAudioEnabled))"
        }
        return [
            ("route", outputs.joined(separator: "|")),
            ("outCh", String(session.outputNumberOfChannels)),
            ("maxOutCh", String(session.maximumOutputNumberOfChannels)),
            ("multichannel", DisplaySignals.yn(session.supportsMultichannelContent)),
            ("rendering", Self.name(session.renderingMode)),
            ("rate", String(format: "%.0f", session.sampleRate)),
            ("outLatency", String(format: "%.4f", session.outputLatency)),
        ]
    }

    // MARK: - Reference (private)

    #if DEBUG

    private func readReference(_ n: Int) {
        referenceQueue.async {
            let fields = Self.referenceFields()
            EngineLog.emit(DisplaySignals.line("#\(n) reference", fields), category: .displaySignals)
        }
    }

    /// `CADisplay` (what MediaToolbox derives `availableHDRModes` from) and PineBoard's display-state client (what
    /// AVKit derives `isDisplayCriteriaMatchingEnabled` from, as range || rate). Every read is checked with
    /// `responds(to:)` first, so a renamed selector reads "n/a" instead of raising.
    nonisolated private static func referenceFields() -> [(String, String)] {
        var fields: [(String, String)] = []
        if let display = classValue("CADisplay", "mainDisplay") {
            if let mode = value(display, "currentMode") as? NSObject {
                let width = value(mode, "width").map { "\($0)" } ?? "?"
                let height = value(mode, "height").map { "\($0)" } ?? "?"
                let rate = (value(mode, "refreshRate") as? NSNumber).map { String(format: "%.3f", $0.doubleValue) } ?? "?"
                fields += [
                    ("ca.mode", "\(width)x\(height)@\(rate)"),
                    ("ca.hdr", text(value(mode, "hdrMode"))),
                    ("ca.bitDepth", text(value(mode, "bitDepth"))),
                    ("ca.colorMode", text(value(mode, "colorMode"))),
                    ("ca.gamut", text(value(mode, "colorGamut"))),
                    ("ca.virtual", text(value(mode, "isVirtual"))),
                ]
            } else {
                fields.append(("ca.mode", "n/a"))
            }
            fields += [
                ("ca.supportedHDR", DisplaySignals.brief(value(display, "supportedHDRModes"))),
                ("ca.preferredHDR", DisplaySignals.brief(value(display, "preferredHDRModes"))),
            ]
        } else {
            fields.append(("ca", "n/a"))
        }
        if let pineBoard = classValue("PBSDisplayManager", "sharedInstance") {
            fields += [
                ("pbs.range", text(value(pineBoard, "shouldModeSwitchForDynamicRange"))),
                ("pbs.rate", text(value(pineBoard, "shouldModeSwitchForFrameRate"))),
                ("pbs.atmos", text(value(pineBoard, "atmosEnabled"))),
                ("pbs.audioFormat", text(value(pineBoard, "preferredAudioFormat"))),
                ("pbs.mode", DisplaySignals.brief(value(pineBoard, "currentDisplayMode"))),
                ("pbs.connection", DisplaySignals.brief(value(pineBoard, "displayConnection"))),
            ]
        } else {
            fields.append(("pbs", "n/a"))
        }
        return fields
    }

    nonisolated private static func classValue(_ className: String, _ key: String) -> NSObject? {
        guard let type = NSClassFromString(className) as? NSObject.Type,
              type.responds(to: NSSelectorFromString(key)) else { return nil }
        return type.value(forKey: key) as? NSObject
    }

    nonisolated private static func value(_ object: NSObject, _ key: String) -> Any? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key)
    }

    nonisolated private static func text(_ value: Any?) -> String {
        guard let value else { return "n/a" }
        if let number = value as? NSNumber { return number.stringValue }
        return DisplaySignals.brief(value)
    }

    #endif

    // MARK: - Refresh cadence

    /// The output refresh rate as the display link sees it, about two seconds' worth. One measurement at a time;
    /// a request while one runs is dropped, since the running one covers it.
    private func measureCadence(_ trigger: String, after delay: Duration) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, cadence == nil, let window = Self.window() else { return }
            let sampler = CadenceSampler()
            cadence = sampler
            let link: CADisplayLink?
            if #available(tvOS 27.0, *), let scene = window.windowScene {
                link = scene.displayLink(target: sampler, selector: #selector(CadenceSampler.tick(_:)))
            } else {
                link = window.screen.displayLink(withTarget: sampler, selector: #selector(CadenceSampler.tick(_:)))
            }
            guard let link else {
                cadence = nil
                emit(DisplaySignals.line("cadence", [("trigger", trigger), ("link", "none")]))
                return
            }
            link.add(to: .main, forMode: .common)
            try? await Task.sleep(for: .seconds(2))
            link.invalidate()
            cadence = nil
            let measured = DisplaySignals.cadence(timestamps: sampler.timestamps)
            emit(DisplaySignals.line("cadence", [
                ("trigger", trigger),
                ("hz", measured.map { String(format: "%.3f", $0.hz) } ?? "n/a"),
                ("jitterMs", measured.map { String(format: "%.2f", $0.jitterMs) } ?? "n/a"),
                ("intervals", String(measured?.intervals ?? 0)),
                ("linkHz", sampler.lastDuration > 0 ? String(format: "%.3f", 1 / sampler.lastDuration) : "n/a"),
                ("targetHz", sampler.lastFrame > 0 ? String(format: "%.3f", 1 / sampler.lastFrame) : "n/a"),
                ("maxFPS", String(window.screen.maximumFramesPerSecond)),
            ]))
        }
    }

    @MainActor
    final class CadenceSampler: NSObject {
        private(set) var timestamps: [Double] = []
        private(set) var lastDuration: Double = 0
        /// `targetTimestamp - timestamp`: the frame the link is preparing for, which follows the output's rate.
        private(set) var lastFrame: Double = 0

        @objc func tick(_ link: CADisplayLink) {
            timestamps.append(link.timestamp)
            lastDuration = link.duration
            lastFrame = link.targetTimestamp - link.timestamp
        }
    }

    // MARK: - Variant oracle

    /// Runs the oracle `delay` from now if nothing else asked within `oracleInterval`, and only while the app is
    /// active with no engine session and no mode switch, re-checked before every ladder.
    private func scheduleOracle(_ reason: String, after delay: Duration) {
        guard oracleTask == nil else { return }
        if let last = lastOracleRun, ContinuousClock.now - last < Self.oracleInterval {
            emit(DisplaySignals.line("oracle", [("event", "skipped"), ("reason", reason), ("why", "ran recently")]))
            return
        }
        oracleGeneration += 1
        let generation = oracleGeneration
        oracleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self else { return }
            if !Task.isCancelled { await runOracle(reason) }
            if oracleGeneration == generation { oracleTask = nil }
        }
    }

    private var oracleBlocker: String? {
        if UIApplication.shared.applicationState != .active { return "app not active" }
        if activeSessions > 0 { return "engine session" }
        if Self.window()?.avDisplayManager.isDisplayModeSwitchInProgress == true { return "mode switch in progress" }
        return nil
    }

    private func runOracle(_ reason: String) async {
        if let blocker = oracleBlocker {
            emit(DisplaySignals.line("oracle", [("event", "deferred"), ("reason", reason), ("why", blocker)]))
            return
        }
        lastOracleRun = .now
        let n = snapshot("oracle:\(reason)")
        var picks: [String: [String: String]] = [:]
        for attachment in ["none", "layer"] {
            var row: [String: String] = [:]
            for ladder in DisplaySignals.Ladder.all {
                if Task.isCancelled { return }
                if let blocker = oracleBlocker {
                    emit(DisplaySignals.line("oracle", [("event", "abandoned"), ("reason", reason), ("why", blocker)]))
                    return
                }
                let attach: ((AVPlayer) -> (() -> Void))? = attachment == "layer" ? { Self.attachLayer($0) } : nil
                let result = await VariantOracle.run(ladder, attachment: attachment, attach: attach)
                let pick: String = result.firstPick?.rawValue ?? "-"
                let error: String = result.errorDomain.map { "\($0)/\(result.errorCode ?? 0)" } ?? "-"
                let fields: [(String, String)] = [
                    ("after", "#\(n)"),
                    ("ladder", ladder.name),
                    ("layer", attachment),
                    ("pick", pick),
                    ("verdict", result.verdict.rawValue),
                    ("status", result.status),
                    ("error", error),
                    ("requests", result.requests.joined(separator: ",")),
                    ("ms", String(result.elapsedMs)),
                    ("ended", result.ended.rawValue),
                ]
                emit(DisplaySignals.line("oracle", fields))
                if ladder.asks == nil {
                    row["rule"] = DisplaySignals.startRule(controlPick: result.firstPick) ?? "none"
                } else {
                    row[ladder.name] = result.verdict.rawValue
                }
            }
            picks[attachment] = row
        }
        for (attachment, row) in picks.sorted(by: { $0.key < $1.key }) {
            emit(DisplaySignals.line("oracle summary", [("after", "#\(n)"), ("layer", attachment)]
                 + row.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }))
        }
    }

    /// A 2-point player layer in the key window for the run: a display-bound player, which may be filtered
    /// differently from a bare one. Nothing is ever decoded into it.
    private static func attachLayer(_ player: AVPlayer) -> (() -> Void) {
        guard let window = window() else { return {} }
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        window.layer.addSublayer(layer)
        return { layer.player = nil; layer.removeFromSuperlayer() }
    }

    // MARK: - Names

    private static func window() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return active?.windows.first { $0.isKeyWindow } ?? active?.windows.first
    }

    private static func label(_ duration: Duration) -> String {
        let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        return ms % 1000 == 0 ? "\(ms / 1000)s" : String(format: "%.1fs", Double(ms) / 1000)
    }

    private static func modes(_ modes: AVPlayer.HDRMode) -> String {
        var names: [String] = []
        if modes.contains(.hdr10) { names.append("hdr10") }
        if modes.contains(.hlg) { names.append("hlg") }
        if modes.contains(.dolbyVision) { names.append("dv") }
        return names.isEmpty ? "none" : names.joined(separator: "+")
    }

    private static func name(_ state: UIApplication.State) -> String {
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "?"
        }
    }

    private static func name(_ gamut: UIDisplayGamut) -> String {
        switch gamut {
        case .SRGB: return "srgb"
        case .P3: return "p3"
        case .unspecified: return "unspecified"
        @unknown default: return "?"
        }
    }

    private static func name(_ status: UIScreen.ReferenceDisplayModeStatus) -> String {
        switch status {
        case .notSupported: return "notSupported"
        case .notEnabled: return "notEnabled"
        case .limited: return "limited"
        case .enabled: return "enabled"
        @unknown default: return "?"
        }
    }

    @available(tvOS 26.0, *)
    private static func name(_ limit: UIHDRHeadroomUsageLimit) -> String {
        switch limit {
        case .active: return "active"
        case .inactive: return "inactive"
        case .unspecified: return "unspecified"
        @unknown default: return "?"
        }
    }

    private static func name(_ mode: AVAudioSession.RenderingMode) -> String {
        switch mode {
        case .notApplicable: return "notApplicable"
        case .monoStereo: return "monoStereo"
        case .surround: return "surround"
        case .spatialAudio: return "spatialAudio"
        case .dolbyAudio: return "dolbyAudio"
        case .dolbyAtmos: return "dolbyAtmos"
        @unknown default: return "?"
        }
    }

    private static func name(_ reason: AVAudioSession.RouteChangeReason?) -> String {
        guard let reason else { return "?" }
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDevice"
        case .oldDeviceUnavailable: return "oldDeviceGone"
        case .categoryChange: return "category"
        case .override: return "override"
        case .wakeFromSleep: return "wake"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange: return "configuration"
        @unknown default: return "?"
        }
    }
}

#endif
