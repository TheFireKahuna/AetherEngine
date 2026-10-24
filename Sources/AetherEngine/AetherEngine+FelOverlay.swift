import Foundation

extension AetherEngine {

    /// Builds the FEL overlay for the current native item, or tears the old one down
    /// (`LoadOptions.felOverlay`). Runs whenever `currentAVPlayerItem` changes.
    func refreshFelOverlay() {
        #if DualLayerDolbyVision
        felOverlay?.stop()
        felOverlay = nil
        guard felOverlayWanted, let item = currentAVPlayerItem, let tap = nativeVideoSession?.felTap else { return }
        guard let renderer = FelOverlayRenderer(item: item, tap: tap) else {
            EngineLog.emit("[AetherEngine] FEL overlay unavailable (no composer); the base layer plays alone", category: .engine)
            return
        }
        renderer.start()
        felOverlay = renderer
        EngineLog.emit("[AetherEngine] FEL overlay attached to the native item", category: .engine)
        #endif
    }
}
