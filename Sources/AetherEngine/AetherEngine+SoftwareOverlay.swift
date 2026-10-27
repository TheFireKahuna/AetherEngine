import Combine
import Foundation

extension AetherEngine {

    /// Builds the software overlay for the current native item, or tears the old one down. Runs whenever
    /// `currentAVPlayerItem` changes: a session whose video AVPlayer cannot decode (`HLSVideoEngine.overlayDecodeTap`)
    /// or a Profile 7 FEL composed over its base layer.
    func refreshSoftwareOverlay() {
        softwareOverlay?.stop()
        softwareOverlay = nil
        softwarePiPSource = nil
        overlaySubtitleCues = nil
        defer { followOverlayWithExternalPlayback() }
        guard let item = currentAVPlayerItem, let source = makeOverlaySource() else { return }
        let renderer = SoftwareOverlayRenderer(item: item, source: source)
        renderer.start()
        softwareOverlay = renderer
        softwarePiPSource = SoftwarePiPSource(layer: renderer.layer, isLive: isLive, engine: self)
        // A published value reaches a sink before the property holds it, so the cues are taken from the sink.
        overlaySubtitleCues = Publishers.CombineLatest($subtitleCues, $secondarySubtitleCues)
            .sink { [weak self] primary, secondary in self?.syncOverlaySubtitles(cues: primary + secondary) }
        EngineLog.emit("[AetherEngine] software overlay attached to the native item", category: .engine)
    }

    /// A placeholder stream must never reach an AirPlay receiver: AVPlayer's external playback stays off while the
    /// overlay draws the session's own decode, so the picture stays here and the audio follows the route
    /// (`airPlayPictureStaysLocal`). A FEL overlay's base layer is real video and keeps it.
    func followOverlayWithExternalPlayback() {
        currentAVPlayer?.allowsExternalPlayback = !pictureDrawnLocally
        recomputeAirPlayPictureStaysLocal()
    }

    /// Hands the overlay what a Picture in Picture window shows over its pictures: whether the window is up, the cues of
    /// both channels, the viewer's delay, and the offset of the source axis the cues are timed on from the item's.
    func syncOverlaySubtitles(cues: [SubtitleCue]? = nil) {
        guard let overlay = softwareOverlay else { return }
        let itemSeconds = currentAVPlayerItem?.currentTime().seconds ?? 0
        let shift = itemSeconds.isFinite ? nativeSourceSeconds(atItemSeconds: itemSeconds) - itemSeconds : 0
        let active = pictureInPictureActive, delay = currentSubtitleDelaySeconds
        let cues = cues ?? subtitleCues + secondarySubtitleCues
        overlay.subtitles.update(.init(active: active, cues: cues, delaySeconds: delay, sourceShift: shift))
    }

    /// What the current session's overlay shows, nil when AVPlayer's own picture is the one to show.
    private func makeOverlaySource() -> (any OverlayFrameSource)? {
        if let tap = nativeVideoSession?.overlayDecodeTap { return DecodedPictureSource(tap: tap) }
        #if DualLayerDolbyVision
        if felOverlayWanted, let session = nativeVideoSession, let tap = session.felTap {
            guard let source = FelCompositionSource(tap: tap, baseLayerFullRange: session.parameterSetsStateFullRange) else {
                EngineLog.emit("[AetherEngine] FEL overlay unavailable (no composer); the base layer plays alone", category: .engine)
                return nil
            }
            return source
        }
        #endif
        return nil
    }
}
