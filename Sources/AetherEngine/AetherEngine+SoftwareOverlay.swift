import Foundation

extension AetherEngine {

    /// Builds the software overlay for the current native item, or tears the old one down. Runs whenever
    /// `currentAVPlayerItem` changes.
    func refreshSoftwareOverlay() {
        softwareOverlay?.stop()
        softwareOverlay = nil
        guard let item = currentAVPlayerItem, let source = makeOverlaySource() else { return }
        let renderer = SoftwareOverlayRenderer(item: item, source: source)
        renderer.start()
        softwareOverlay = renderer
        EngineLog.emit("[AetherEngine] software overlay attached to the native item", category: .engine)
    }

    /// What the current session's overlay shows, nil when AVPlayer's own picture is the one to show.
    private func makeOverlaySource() -> (any OverlayFrameSource)? {
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
