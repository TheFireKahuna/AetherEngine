import Foundation
import AetherLibavutil

/// A live stream that turns HDR mid-way (an HLG programme after an SDR one, an HDR ad, a new encoder) moves the panel
/// into that HDR mode once, when playback reaches it, and keeps it there for the rest of the session. Each mode change
/// is an HDMI renegotiation (a second or two of black, often an audio dropout on eARC), so the panel never comes back
/// down: SDR plays inside an HDR mode as tvOS maps it, and a later HLG / PQ change is converted by tvOS too. HDR is
/// never shown tone-mapped down to SDR, the one outcome that loses picture. A session that opened in HDR is latched
/// from the start.
struct LiveDisplayRangeLatch {
    /// The panel is in an HDR mode (the session opened in one, or switched once).
    private(set) var latched: Bool
    /// The first HDR programme still ahead of playback: where it starts on the item clock, and its mode.
    private(set) var pending: (itemSeconds: Double, format: VideoFormat)?
    let frameRate: Double?

    init(openedIn format: VideoFormat, frameRate: Double?) {
        latched = format != .sdr
        self.frameRate = frameRate
    }

    /// The display mode a live programme of `colour` asks for on a panel with `capabilities`: PQ in HDR10, HLG in
    /// HLG (or HDR10 where the panel has no HLG mode, which tvOS converts to), nil for SDR or a panel without HDR.
    static func format(for colour: ColorDescription, capabilities: DisplayCapabilities) -> VideoFormat? {
        switch colour.transfer {
        case AVCOL_TRC_SMPTE2084: capabilities.supportsHDR10 ? .hdr10 : nil
        case AVCOL_TRC_ARIB_STD_B67: capabilities.supportsHLG ? .hlg : (capabilities.supportsHDR10 ? .hdr10 : nil)
        default: nil
        }
    }

    /// A programme of `colour` starts at `itemSeconds`. Only the first HDR one matters.
    mutating func note(itemSeconds: Double, colour: ColorDescription, capabilities: DisplayCapabilities) {
        guard !latched, pending == nil, let format = Self.format(for: colour, capabilities: capabilities) else { return }
        pending = (itemSeconds, format)
    }

    /// Playback is at `itemSeconds`: the mode to switch to now, once.
    mutating func crossing(_ itemSeconds: Double) -> VideoFormat? {
        guard let pending, itemSeconds >= pending.itemSeconds else { return nil }
        self.pending = nil
        latched = true
        return pending.format
    }
}

extension AetherEngine {
    /// A live programme's colour from the item time it starts at (`HLSVideoEngine.onLiveVideoColour`).
    @MainActor
    func noteLiveVideoColour(itemSeconds: Double, colour: ColorDescription) {
        guard var latch = liveDisplayRange else { return }
        latch.note(itemSeconds: itemSeconds, colour: colour, capabilities: Self.displayCapabilities)
        if let pending = latch.pending, liveDisplayRange?.pending == nil {
            EngineLog.emit(
                "[AetherEngine] live programme in \(pending.format) from item \(String(format: "%.3f", itemSeconds))s; "
                + "the panel switches when playback reaches it, once", category: .engine)
        }
        liveDisplayRange = latch
    }

    /// From the native route's rendered-position tick: switches the panel when playback reaches the first HDR
    /// programme.
    @MainActor
    func crossLiveDisplayRange(at itemSeconds: Double) {
        guard var latch = liveDisplayRange, let format = latch.crossing(itemSeconds) else { return }
        liveDisplayRange = latch
        EngineLog.emit(
            "[AetherEngine] live stream turned \(format) at item \(String(format: "%.3f", itemSeconds))s: "
            + "switching the panel, latched for the session", category: .engine)
        displayCriteria.apply(format: format, frameRate: latch.frameRate, codecTag: nil,
                              omitColorExtensions: loadedOptions.omitCriteriaColorExtensions)
        sourceVideoFormat = format
        republishPanelPresentsHDR(effectiveFormat: format, because: "live stream turned \(format)")
    }
}
