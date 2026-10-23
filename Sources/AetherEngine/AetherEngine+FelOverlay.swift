import Foundation

extension AetherEngine {

    /// Builds the FEL overlay for the current native item, or tears the old one down
    /// (`LoadOptions.felOverlay`). Runs whenever `currentAVPlayerItem` changes.
    func refreshFelOverlay() {
        #if DualLayerDolbyVision
        felOverlay?.stop()
        felOverlay = nil
        guard felOverlayWanted, let item = currentAVPlayerItem, let url = loadedURL else { return }
        // The loopback HLS rebases the source onto zero at its first keyframe; the enhancement layer is
        // read from the source, on its own timeline.
        let origin = nativeVideoSession?.firstKeyframeSeconds ?? 0
        guard let renderer = FelOverlayRenderer(item: item, sourceURL: url, headers: loadedOptions.httpHeaders,
                                                sourceOffset: origin) else {
            EngineLog.emit("[AetherEngine] FEL overlay unavailable (no composer); the base layer plays alone", category: .engine)
            return
        }
        renderer.start()
        felOverlay = renderer
        EngineLog.emit(String(format: "[AetherEngine] FEL overlay attached to the native item (source origin %.3f s)", origin),
                       category: .engine)
        #endif
    }
}
