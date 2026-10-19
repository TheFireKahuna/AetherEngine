import AVKit
import SwiftUI
import UIKit

// What tvOS is sending the television right now, for the on-screen readout: the camera then films the
// HDMI mode next to the picture it explains. The mode comes from PineBoardServices, private; every call
// is guarded, so an OS without it shows "mode: unavailable" instead of crashing. Public signals (EDR
// headroom, AVDisplayManager) ride along as a complement.

/// `PBSDisplayManager` in the private PineBoardServices framework, the object PineBoard itself describes
/// modes with (`{ 3840 x 2160 23.98Hz @2x, 16:9, Dolby Vision P3 [non-virtual, non-promoted] }` in a
/// sysdiagnose). `+sharedInstance` fetches the state from PineBoard over XPC when it is created, and
/// `-refreshValuesOnQueue:completion:` fetches it again; the queue must be the main queue (anything else
/// trips a `dispatch_assert_queue` inside PineBoardServices). Verified in the tvOS 27.0 simulator, which
/// reports `{ 3840 x 2160 60.00Hz @2x, 16:9, SDR RGB High P3 [non-virtual, non-promoted] }`.
@MainActor
enum PineBoardDisplayMode {
    private static let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PineBoardServices.framework/PineBoardServices", RTLD_NOW) != nil,
              let cls = NSClassFromString("PBSDisplayManager") as? NSObject.Type else { return nil }
        let shared = NSSelectorFromString("sharedInstance")
        guard cls.responds(to: shared) else { return nil }
        return cls.perform(shared)?.takeUnretainedValue() as? NSObject
    }()

    private static var refreshing = false

    /// `-[PBSDisplayMode description]` of `currentDisplayMode`, nil if any piece is missing.
    static func current() -> String? {
        guard let manager, manager.responds(to: NSSelectorFromString("currentDisplayMode")),
              let mode = manager.value(forKey: "currentDisplayMode") as? NSObject else { return nil }
        return mode.description
    }

    /// Asks PineBoard for the current state; `done` runs on the main queue once `current()` reflects it.
    /// One request at a time.
    static func refresh(_ done: @escaping @MainActor () -> Void) {
        let sel = NSSelectorFromString("refreshValuesOnQueue:completion:")
        guard !refreshing, let manager, manager.responds(to: sel), let imp = manager.method(for: sel) else { return }
        typealias Refresh = @convention(c) (AnyObject, Selector, DispatchQueue, @escaping @convention(block) () -> Void) -> Void
        refreshing = true
        unsafeBitCast(imp, to: Refresh.self)(manager, sel, .main) {
            MainActor.assumeIsolated {
                refreshing = false
                done()
            }
        }
    }

    /// `<PBSDisplayMode: 0x…>{ 3840 x 2160 23.98Hz @2x, 16:9, Dolby Vision P3 [non-virtual, non-promoted] }`
    /// as `Dolby Vision P3 · 3840x2160 23.98Hz`; anything not in that shape comes back as it is.
    static func summary(_ description: String) -> String {
        guard let open = description.firstIndex(of: "{"), let close = description.lastIndex(of: "}"), open < close else {
            return description
        }
        let body = description[description.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
        let fields = body.components(separatedBy: ", ")
        guard fields.count >= 3 else { return body }
        let geometry = fields[0].replacingOccurrences(of: " x ", with: "x")
            .components(separatedBy: " @").first ?? fields[0]
        let range = fields[2...].joined(separator: ", ").components(separatedBy: " [").first ?? fields[2]
        return "\(range) · \(geometry)"
    }
}

/// Polls the display mode once a second, publishes it for the overlay and logs every change.
@MainActor
final class DisplayModeMonitor: ObservableObject {
    @Published private(set) var mode = "mode: …"
    @Published private(set) var signals = ""
    private var lastMode = ""
    private var lastSignals = ""
    private var task: Task<Void, Never>?

    func start(window: @escaping @MainActor () -> UIWindow?, log: @escaping @Sendable (String) -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll(window: window(), log: log)
                PineBoardDisplayMode.refresh { [weak self] in self?.poll(window: window(), log: log) }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func poll(window: UIWindow?, log: @Sendable (String) -> Void) {
        let raw = PineBoardDisplayMode.current()
        let modeText = raw.map(PineBoardDisplayMode.summary) ?? "mode: unavailable"
        if raw ?? "unavailable" != lastMode {
            lastMode = raw ?? "unavailable"
            log("display mode: \(raw ?? "unavailable (PineBoardServices PBSDisplayManager not reachable)")")
        }
        mode = modeText

        let screen = window?.screen ?? UIScreen.main
        var parts = [String(format: "EDR %.2f/%.2f", screen.currentEDRHeadroom, screen.potentialEDRHeadroom)]
        if let dm = window?.avDisplayManager {
            parts.append(dm.isDisplayModeSwitchInProgress ? "switching" : "settled")
            parts.append(dm.preferredDisplayCriteria == nil ? "criteria none" : "criteria set")
            if !dm.isDisplayCriteriaMatchingEnabled { parts.append("match-content off") }
        }
        let signalText = parts.joined(separator: " · ")
        if signalText != lastSignals {
            lastSignals = signalText
            log("display signals: \(signalText)")
        }
        signals = signalText
    }
}

/// The persistent top-left label: which arm, its options, and what the TV is being sent.
struct DisplayModeOverlay: View {
    let arm: String
    @ObservedObject var monitor: DisplayModeMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !arm.isEmpty { Text(arm).font(.system(size: 30, weight: .bold, design: .monospaced)) }
            Text(monitor.mode).font(.system(size: 30, weight: .semibold, design: .monospaced))
            Text(monitor.signals).font(.system(size: 22, design: .monospaced)).foregroundColor(.gray)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
        // Right of the pulse clips' top-left corner marker (about 0-150 pt), above the card's first row.
        .padding(.leading, 170)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}
