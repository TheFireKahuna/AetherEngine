@_spi(Diagnostics) import AetherEngine
import AVFoundation
import AVKit
import Combine
import CoreMedia
import SwiftUI
import UIKit

// Device harness for the Dolby Vision pulse test (see ../../README.md). Every arm plays a clip whose
// pixels are constant while only the RPU (or, for the EL clip, only the residual) switches, so a
// camera pointed at the television can tell whether the metadata reached the panel.
//
// Arms come from the environment variable `PULSE_ARMS`, which `devicectl device process launch
// --environment-variables` does deliver to an app process:
//
//   PULSE_ARMS="label|mode|url[|k=v;k=v],label|mode|url,..."
//
// Arms play back to back with a 5 s slate naming the arm in between, so one phone recording covers
// the whole sequence; an arm with `slate=off` follows the previous one directly. Modes:
//
// - `avplayer`: plain AVPlayer + AVPlayerLayer on the file (Apple's own path, the positive control).
// - `vt`: AVAssetReader (VideoToolbox) output straight into AVSampleBufferDisplayLayer, with the
//   attachments VideoToolbox set.
// - `vtcopy`: as `vt`, but every frame copied into a buffer from our own IOSurface pool, with all of
//   VideoToolbox's propagated attachments (Dolby Vision RPU included) copied across byte for byte.
// - `vtstrip`: as `vtcopy`, without `DolbyVisionRPUData` / `DolbyCompatibilityID`.
// - `engine`: AetherEngine with `preferDualLayerDolbyVision: true` (a Profile 7 FEL clip takes the
//   dual-layer route).
// - `enginenofel`: as `engine` with `preferDualLayerDolbyVision: false` (native 8.1 route, EL dropped).
//   `engine` takes `out=p010|p010-round|p010-bluenoise|p010-full|sv22` (default sv22, the engine's): the FEL composer's output
//   buffer, for the 12-bit display-path experiment (`AetherEngine.felOutputMode`); `rpu=<url>` (absolute, or
//   relative to the clip's): one Dolby Vision RPU NAL, fetched before the arm starts, that every composed frame
//   carries in place of its own for this arm only (`AetherEngine.felComposedRpuOverride`; a fetch or parse
//   failure skips the arm); `secs=N`: play N seconds, looping the clip, instead of once through (80 s cap); on `avplayer`
//   arms it only shortens the arm (no looping).
// - `overlay`: as `engine`, but the FEL plays on the native route (`LoadOptions.felOverlay`): AVPlayer plays the
//   8.1 base layer in an `AVPlayerViewController` and `FelOverlayRenderer` composes the enhancement layer over it
//   inside AVKit's render layer, as Sodalite shows it. Takes `out=`, `rpu=` and `secs=` like `engine`.
// - `soak`: `engine` for `minutes=` with a `seeks=at@to,...` schedule, sampled once a second, ending in
//   one `soak summary` line; takes `out=` like `engine` (default sv22, the engine's).
// - `placeholder`: AVPlayer plays a placeholder clip (Scripts/build_placeholder.sh) in an AVPlayerViewController
//   with its rendering suppressed, while frames decoded from `src=` show on a layer inside AVKit's player layer,
//   timed by the item's clock: the software route inside the native player (PulsePlaceholder.swift has the params).
// - `subs`: AVPlayer on Scripts/build_subs.sh's subtitle stream through an AVPlayerLayer, for AVKit's own subtitle
//   selection and `suppressesPlayerRendering` (PulseSubtitles.swift has the cases).
//
// The VT modes request Dolby Vision display criteria from the track's own format description, as an
// app on this path would.
//
// A label in the top-left corner names the arm and its options and shows the display mode tvOS is
// sending (DisplayModeReadout.swift); every change of that mode is logged.

@main
struct DolbyVisionPulseHostApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear {
                    // About eleven minutes of playback, partly not AVPlayer: keep the screensaver away.
                    UIApplication.shared.isIdleTimerDisabled = true
                    // Compile the FEL composer's shaders while the first slate is up, not on the first frame.
                    Task.detached { _ = await AetherEngine.prewarmDualLayerDolbyVision() }
                }
        }
    }
}

private struct RootView: View {
    var body: some View {
        if let arms = PulseArm.fromEnvironment() {
            PulseHarnessView(arms: arms)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                Text("Dolby Vision pulse host").font(.title2)
                Text("No PULSE_ARMS in the environment.").font(.title3)
                Text("""
                    Launch with devicectl device process launch --environment-variables \
                    '{"PULSE_ARMS":"label|mode|url,..."}'. Scripts/run_tv.sh does it.
                    """)
                    .foregroundStyle(.secondary)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct PulseArm {
    let label: String
    let mode: String
    let url: URL
    /// Optional 4th field, `key=value;key=value` (soak: `minutes=5;seeks=60@1800,150@600`).
    let params: [String: String]

    static func fromEnvironment() -> [PulseArm]? {
        guard let raw = ProcessInfo.processInfo.environment["PULSE_ARMS"] else { return nil }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [PulseArm]? {
        // Arms are comma separated, but a soak's `seeks=` list contains commas too: a new arm starts
        // only at a piece shaped `label|mode|...`, anything else belongs to the previous arm's params.
        var items: [String] = []
        for piece in raw.split(separator: ",", omittingEmptySubsequences: true).map(String.init) {
            if piece.contains("|") || items.isEmpty { items.append(piece) } else { items[items.count - 1] += "," + piece }
        }
        let arms = items.compactMap { item -> PulseArm? in
            let parts = item.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count >= 3, let url = URL(string: parts[2]) else { return nil }
            var params: [String: String] = [:]
            if parts.count == 4 {
                for kv in parts[3].split(separator: ";") {
                    let p = kv.split(separator: "=", maxSplits: 1).map(String.init)
                    if p.count == 2 { params[p[0]] = p[1] }
                }
            }
            return PulseArm(label: parts[0], mode: parts[1], url: url, params: params)
        }
        return arms.isEmpty ? nil : arms
    }
}

struct PulseHarnessView: View {
    let arms: [PulseArm]
    @State private var engine: AetherEngine?
    /// The engine of an `overlay` arm, shown through AVKit instead of `AetherPlayerSurface`.
    @State private var overlayEngine: AetherEngine?
    @State private var placeholder: PlaceholderSession?
    @State private var subtitleProbe: SubtitleProbeSession?
    @State private var slate: String = ""
    @State private var host = PulseHostView()
    @State private var armInfo = ""
    @StateObject private var displayMode = DisplayModeMonitor()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PulseHostRepresentable(host: host).ignoresSafeArea()
            if let engine {
                AetherPlayerSurface(engine: engine).ignoresSafeArea()
            }
            if let overlayEngine {
                OverlayPlayerRepresentable(engine: overlayEngine).ignoresSafeArea()
            }
            if let placeholder {
                PlaceholderRepresentable(session: placeholder).ignoresSafeArea()
            }
            if let subtitleProbe {
                SubtitleProbeRepresentable(session: subtitleProbe).ignoresSafeArea()
            }
            if !slate.isEmpty {
                VStack(spacing: 30) {
                    Text(slate).font(.system(size: 160, weight: .heavy)).foregroundColor(.white)
                    // Live UTC clock: one readable slate frame pins the video time to wall time.
                    TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                        Text(Self.clock(ctx.date))
                            .font(.system(size: 96, weight: .bold).monospacedDigit())
                            .foregroundColor(.white)
                    }
                    Text("dv-pulse").font(.system(size: 48)).foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            }
            DisplayModeOverlay(arm: armInfo, monitor: displayMode).ignoresSafeArea()
        }
        .task { await run() }
    }

    private static func clock(_ d: Date) -> String {
        let s = d.timeIntervalSince1970
        let day = s.truncatingRemainder(dividingBy: 86400)
        return String(format: "%02d:%02d:%04.1f UTC", Int(day / 3600), Int(day / 60) % 60,
                      day.truncatingRemainder(dividingBy: 60))
    }

    @MainActor
    private func run() async {
        EngineLog.handler = { line in
            PulseLog.shared.note(line)
            print(line)
            fflush(stdout)
        }
        let started = Date()
        // Wall-clock epoch seconds on every line, so the phone video (whose creation date and the
        // slate clock give its own wall-clock start) can be cut per arm afterwards.
        let say: @Sendable (String) -> Void = { s in
            let now = Date()
            let line = String(format: "[Pulse] wall=%.3f t=%.1f %@", now.timeIntervalSince1970,
                              now.timeIntervalSince(started), s)
            print(line)
            fflush(stdout)
            PulseLog.shared.note(line)
        }
        say("sequence: " + arms.map { "\($0.label)(\($0.mode))" }.joined(separator: " "))
        displayMode.start(window: { [host] in host.window }, log: say)
        // Without the trait the engine accepts preferDualLayerDolbyVision and plays the native route, so
        // every `engine` and `soak` arm would film the wrong thing. Refuse the whole sequence instead.
        if arms.contains(where: { ["engine", "overlay", "soak"].contains($0.mode) }),
           !AetherEngine.OptionalComponent.dualLayerDolbyVision.isBuiltIn {
            slate = "AetherEngine was built without the DualLayerDolbyVision trait"
            say("ERROR: the engine and soak arms need AetherEngine's DualLayerDolbyVision trait, which this "
                + "build lacks (PulseEngine/Package.swift sets it); refusing the sequence")
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            exit(70)
        }
        for (n, arm) in arms.enumerated() {
            slate = "\(n + 1)/\(arms.count)  \(arm.label)"
            armInfo = ([arm.label, arm.mode] + arm.params.sorted { $0.key < $1.key }.map { key, value in
                key == "rpu" ? "rpu=\((value as NSString).lastPathComponent)" : "\(key)=\(value)"
            }).joined(separator: " · ")
            // `slate=off`: straight on from the previous arm with the panel left as it is, for by-eye A/B where
            // a black gap between arms hides the difference (the top-left label still names the arm).
            if arm.params["slate"] == "off" {
                slate = ""
                say("slate \(arm.label) skipped")
            } else {
                host.window?.avDisplayManager.preferredDisplayCriteria = nil
                say("slate \(arm.label)")
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                slate = ""
            }
            say("arm \(arm.label) start mode=\(arm.mode) url=\(arm.url.lastPathComponent)")
            switch arm.mode {
            case "avplayer":
                await host.playAVPlayer(arm.url, seconds: arm.params["secs"].flatMap(Double.init), log: say)
            case "vt", "vtcopy", "vtstrip":
                await host.playVT(arm.url, mode: arm.mode, log: say)
            case "engine", "overlay":
                let out = arm.params["out"] ?? AetherEngine.FelOutputMode.sv22.rawValue
                guard let mode = AetherEngine.FelOutputMode(rawValue: out) else {
                    say("unknown out=\(out), arm skipped")
                    break
                }
                if let spec = arm.params["rpu"] {
                    guard let rpu = await fetchRpu(spec, relativeTo: arm.url, log: say) else {
                        say("rpu=\(spec) not usable, arm skipped")
                        break
                    }
                    AetherEngine.felComposedRpuOverride = rpu
                    guard let attached = AetherEngine.felComposedRpuOverride else {
                        say("rpu=\(spec): \(rpu.count) bytes do not parse as a Dolby Vision RPU NAL, arm skipped")
                        break
                    }
                    say("rpu override \((spec as NSString).lastPathComponent): \(attached.count) bytes, "
                        + attached.prefix(12).map { String(format: "%02x", $0) }.joined())
                }
                AetherEngine.felOutputMode = mode
                say("fel output \(mode.rawValue)")
                await playEngine(arm.url, fel: true, overlay: arm.mode == "overlay",
                                 seconds: arm.params["secs"].flatMap(Double.init), log: say)
                AetherEngine.felOutputMode = .sv22   // back to the engine default
                AetherEngine.felComposedRpuOverride = nil
            case "enginenofel":
                await playEngine(arm.url, fel: false, log: say)
            case "placeholder":
                await playPlaceholder(arm, log: say)
            case "subs":
                let session = SubtitleProbeSession(url: arm.url, params: arm.params, log: say)
                subtitleProbe = session
                await session.run()
                subtitleProbe = nil
            case "soak":
                // `out=` as on `engine` arms, so a soak measures the output buffer it will ship with.
                let out = arm.params["out"] ?? AetherEngine.FelOutputMode.sv22.rawValue
                guard let mode = AetherEngine.FelOutputMode(rawValue: out) else {
                    say("unknown out=\(out), arm skipped")
                    break
                }
                AetherEngine.felOutputMode = mode
                say("fel output \(mode.rawValue)")
                await playSoak(arm, log: say)
                AetherEngine.felOutputMode = .sv22   // back to the engine default
            default:
                say("unknown mode \(arm.mode), skipped")
            }
            say("arm \(arm.label) end")
        }
        slate = "done"
        host.window?.avDisplayManager.preferredDisplayCriteria = nil
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        say("sequence done")
        exit(0)
    }

    /// The bytes at `spec` (a URL, absolute or relative to the arm's clip), or nil with the reason logged.
    private func fetchRpu(_ spec: String, relativeTo clip: URL, log: @Sendable (String) -> Void) async -> Data? {
        guard let url = URL(string: spec, relativeTo: clip)?.absoluteURL else { log("rpu=\(spec): not a URL"); return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                log("rpu fetch \(url.absoluteString): HTTP \(http.statusCode)")
                return nil
            }
            guard !data.isEmpty else { log("rpu fetch \(url.absoluteString): empty"); return nil }
            return data
        } catch {
            log("rpu fetch \(url.absoluteString) failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Plays `url` once through (at most 80 s), or for `seconds`, starting the clip over each time it ends.
    /// `overlay` composes the FEL over AVPlayer on the native route (`LoadOptions.felOverlay`), shown through AVKit.
    @MainActor
    private func playEngine(_ url: URL, fel: Bool, overlay: Bool = false, seconds: Double? = nil,
                            log: @Sendable (String) -> Void) async {
        guard let e = try? AetherEngine() else { log("engine init failed"); return }
        if overlay { overlayEngine = e } else { engine = e }
        defer { engine = nil; overlayEngine = nil }
        do {
            try await e.load(url: url, startPosition: nil,
                             options: LoadOptions(dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: fel,
                                                  felOverlay: overlay, audioBridgeMode: .surroundCompat),
                             audioSourceStreamIndex: nil)
            e.play()
        } catch {
            log("engine load failed: \(error)")
            return
        }
        // The overlay is published after load returns; `[FelOverlayRenderer] installed` and its counters confirm it.
        if overlay { log("route=\(e.videoRoute.rawValue)") }
        let deadline = Date().addingTimeInterval(min(seconds ?? 80, 80))
        while Date() < deadline {
            if e.state == .ended {
                guard seconds != nil else { break }
                await e.seek(to: 0)
                e.play()
                log("engine looped")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("engine state=\(e.state) t=\(e.currentTime)")
        e.stop()
    }

    /// A `placeholder` arm: the placeholder clip in AVKit, the `src=` clip's frames over it.
    @MainActor
    private func playPlaceholder(_ arm: PulseArm, log: @escaping @Sendable (String) -> Void) async {
        guard let spec = arm.params["src"], let src = URL(string: spec, relativeTo: arm.url)?.absoluteURL else {
            log("placeholder arm needs src=<clip>, skipped")
            return
        }
        do {
            // AVAssetReader only reads local files.
            let (tmp, _) = try await URLSession.shared.download(from: src)
            let local = FileManager.default.temporaryDirectory.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.removeItem(at: local)
            try FileManager.default.moveItem(at: tmp, to: local)
            let asset = AVURLAsset(url: local)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                log("placeholder src \(src.lastPathComponent): no video track")
                return
            }
            var seeks: [(at: Double, to: Double)] = []
            for item in (arm.params["seeks"] ?? "").split(separator: ",") {
                let p = item.split(separator: "@")
                if p.count == 2, let at = Double(p[0]), let to = Double(p[1]) { seeks.append((at, to)) }
            }
            if arm.params["criteria"] == "src", let fd = try await track.load(.formatDescriptions).first {
                let fps = try await track.load(.nominalFrameRate)
                host.window?.avDisplayManager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: fps, formatDescription: fd)
                let sub = CMFormatDescriptionGetMediaSubType(fd)
                log("criteria from src: \(String(bytes: [24, 16, 8, 0].map { UInt8((sub >> $0) & 0xff) }, encoding: .ascii) ?? "?") fps=\(fps)")
            }
            let session = PlaceholderSession(placeholder: arm.url, source: asset, track: track, params: arm.params, log: log)
            placeholder = session
            defer { placeholder = nil }
            await session.run(seconds: min(arm.params["secs"].flatMap(Double.init) ?? 40, 300), seeks: seeks)
        } catch {
            log("placeholder src \(src.lastPathComponent): \(error)")
        }
    }

    /// Long-run FEL playback with a seek schedule. Measures only what the engine exposes publicly:
    /// - droppedFrames: `liveTelemetry.droppedFrameCount` (render synchronizer's dropped frames on the
    ///   software path, session total; nil reads as -1).
    /// - composeFailures: sum of `composeFailures=` over the engine's `[DualLayerVideoDecoder] summary`
    ///   lines (seen through EngineLog.handler; the counter itself is internal). The engine writes that
    ///   line every second at `.verbose`, which never reaches the handler, and at the default level only
    ///   for a second that counted a failure, so the sum is exact. Stays 0 if the FEL route never ran,
    ///   so `route=` is the thing to check first.
    /// - footprint: task_vm_info phys_footprint, sampled each second.
    @MainActor
    private func playSoak(_ arm: PulseArm, log: @Sendable (String) -> Void) async {
        let minutes = arm.params["minutes"].flatMap(Double.init) ?? 5
        var seeks: [(at: Double, to: Double)] = []
        for item in (arm.params["seeks"] ?? "").split(separator: ",") {
            let p = item.split(separator: "@")
            if p.count == 2, let at = Double(p[0]), let to = Double(p[1]) { seeks.append((at, to)) }
        }
        seeks.sort { $0.at < $1.at }
        let tally = SoakTally()
        let previous = EngineLog.handler
        EngineLog.handler = { line in
            previous?(line)
            tally.ingest(line)
        }
        defer { EngineLog.handler = previous }
        // `film=off`: the load does not look for film in interlaced carriage (SEQ=film's A/B control).
        AetherEngine.filmDetection = arm.params["film"] != "off"
        defer { AetherEngine.filmDetection = true }
        guard let e = try? AetherEngine() else { log("engine init failed"); return }
        engine = e
        do {
            // `fieldrate=frame` deinterlaces at frame rate (SEQ=deint); the engine's default is field rate.
            let fieldRate = arm.params["fieldrate"].flatMap(DeinterlaceFieldRate.init(rawValue:)) ?? .field
            try await e.load(url: arm.url, startPosition: nil,
                             options: LoadOptions(dolbyVisionHandling: .automatic, preferDualLayerDolbyVision: true,
                                                  felOverlay: false, audioBridgeMode: .surroundCompat,
                                                  deinterlaceFieldRate: fieldRate),
                             audioSourceStreamIndex: nil)
            e.play()
        } catch {
            log("engine load failed: \(error)")
            engine = nil
            return
        }
        log("soak start minutes=\(minutes) seeks=\(seeks.count)")
        let started = Date()
        let deadline = started.addingTimeInterval(minutes * 60)
        var peak = Self.footprintMB()
        var played = 0.0
        var nSeeks = 0
        var lastTick = Date()
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let now = Date()
            if e.state == .playing { played += now.timeIntervalSince(lastTick) }
            lastTick = now
            peak = max(peak, Self.footprintMB())
            if let next = seeks.first, now.timeIntervalSince(started) >= next.at {
                seeks.removeFirst()
                nSeeks += 1
                await e.seek(to: next.to)
                log(String(format: "seek to=%.1f landed=%.1f", next.to, e.currentTime))
                lastTick = Date()
            }
            if e.state == .ended { log("soak ended early"); break }
        }
        let dropped = e.liveTelemetry?.droppedFrameCount ?? -1
        let route = tally.sawDualLayer ? "FEL" : "\(e.videoRoute.rawValue)-noDualLayerSummary"
        log(String(format: "soak summary: played=%.0fs seeks=%d droppedFrames=%d composeFailures=%d peakFootprintMB=%d endFootprintMB=%d route=%@",
                   played, nSeeks, dropped, tally.composeFailures, peak, Self.footprintMB(), route))
        e.stop()
        engine = nil
    }

    /// `phys_footprint` (what jetsam judges), MB.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / 1024 / 1024) : -1
    }
}

/// Accumulates the engine's `[DualLayerVideoDecoder] summary: ... composeFailures=N ...` lines (per-second
/// deltas; only the seconds with a failure reach the handler). The FEL route is recognised by its
/// open-time line, since a healthy summary does not reach the handler.
private final class SoakTally: @unchecked Sendable {
    private let lock = NSLock()
    private var failures = 0
    private var seen = false
    var composeFailures: Int { lock.lock(); defer { lock.unlock() }; return failures }
    var sawDualLayer: Bool { lock.lock(); defer { lock.unlock() }; return seen }
    func ingest(_ line: String) {
        if line.contains("[DualLayerVideoDecoder] FEL stream detected") {
            lock.lock(); seen = true; lock.unlock()
            return
        }
        guard line.contains("[DualLayerVideoDecoder] summary:") else { return }
        lock.lock(); defer { lock.unlock() }
        seen = true
        if let r = line.range(of: "composeFailures="),
           let n = Int(line[r.upperBound...].prefix { $0.isNumber }) { failures += n }
    }
}

private struct PulseHostRepresentable: UIViewRepresentable {
    let host: PulseHostView
    func makeUIView(context: Context) -> PulseHostView { host }
    func updateUIView(_ uiView: PulseHostView, context: Context) {}
}

private struct PlaceholderRepresentable: UIViewControllerRepresentable {
    let session: PlaceholderSession

    func makeUIViewController(context: Context) -> PlaceholderPlayerController { PlaceholderPlayerController(session: session) }
    func updateUIViewController(_ controller: PlaceholderPlayerController, context: Context) {}
}

/// An `overlay` arm's picture: the engine's AVPlayer in an `AVPlayerViewController`, with the engine's FEL
/// overlay installed in AVKit's render layer (Sodalite's `PlayerHostController.installFelOverlay`).
private struct OverlayPlayerRepresentable: UIViewControllerRepresentable {
    let engine: AetherEngine

    func makeUIViewController(context: Context) -> OverlayPlayerController { OverlayPlayerController(engine: engine) }
    func updateUIViewController(_ controller: OverlayPlayerController, context: Context) {}
}

private final class OverlayPlayerController: AVPlayerViewController {
    private let engine: AetherEngine
    private var subscriptions: Set<AnyCancellable> = []

    init(engine: AetherEngine) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
        showsPlaybackControls = false
        // The engine writes the display criteria, as in Sodalite.
        appliesPreferredDisplayCriteriaAutomatically = false
        engine.$currentAVPlayer
            .receive(on: DispatchQueue.main)
            .sink { [weak self] player in
                self?.player = player
                self?.installOverlay()
            }
            .store(in: &subscriptions)
        engine.$felOverlay
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.installOverlay() }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        installOverlay()
    }

    /// Puts the overlay inside AVKit's player layer once both exist; a no-op when it is already there.
    private func installOverlay() {
        guard let overlay = engine.felOverlay, let player, let root = viewIfLoaded?.layer,
              let renderLayer = Self.playerLayer(of: player, in: root) else { return }
        var ancestor = overlay.layer.superlayer
        while let current = ancestor, current !== renderLayer { ancestor = current.superlayer }
        if ancestor === renderLayer { return }
        overlay.layer.removeFromSuperlayer()
        let belowSubtitles = overlay.install(in: renderLayer)
        PulseLog.shared.note("[Pulse] FEL overlay installed in AVKit's render layer (\(belowSubtitles ? "below its subtitles" : "on top"))")
    }

    private static func playerLayer(of player: AVPlayer, in layer: CALayer) -> AVPlayerLayer? {
        if let candidate = layer as? AVPlayerLayer, candidate.player === player { return candidate }
        for sub in layer.sublayers ?? [] {
            if let hit = playerLayer(of: player, in: sub) { return hit }
        }
        return nil
    }
}
