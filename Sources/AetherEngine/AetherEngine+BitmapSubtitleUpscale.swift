import Foundation

extension AetherEngine {
    /// Loads the bitmap subtitle upscaler's models in the background (`bitmapSubtitlePixelSize`), for a host to call
    /// at app open: the first session then finds them loaded. Under 2 s the first time after an install or an OS
    /// update, well under one otherwise. Without the `MLSubtitleUpscale` trait it does nothing.
    public nonisolated static func prewarmBitmapSubtitleUpscaler() {
        BitmapSubtitleUpscaling.prewarm()
    }

    /// LibMLSubUpscaler's report of the upscaler's costs on this device (app open, first picture, steady state),
    /// its GPU passes on the engine's own upscaler submission. For a device benchmark, never playback: it runs for
    /// seconds. Nil without the `MLSubtitleUpscale` trait or a GPU.
    public nonisolated static func bitmapSubtitleUpscalerBenchmark(iterations: Int = 40) -> String? {
        BitmapSubtitleUpscaling.benchmark(iterations: iterations)
    }

    /// The upscale a drain tick applies, nil when the build or the host asks for none.
    func bitmapSubtitleUpscaleRequest(playhead: Double) -> BitmapSubtitleUpscaling.Request? {
        guard AetherEngine.OptionalComponent.mlSubtitleUpscale.isBuiltIn, let size = bitmapSubtitlePixelSize else { return nil }
        return BitmapSubtitleUpscaling.Request(pixelSize: size, playhead: playhead)
    }

    /// Starts readying the upscaler as a load begins, so the playback-start gate finds it ready.
    func startBitmapSubtitleUpscaler() {
        guard AetherEngine.OptionalComponent.mlSubtitleUpscale.isBuiltIn, bitmapSubtitlePixelSize != nil else { return }
        _ = BlockingWork.detached(priority: .userInitiated) { try? BitmapSubtitleUpscaling.shared.ready() }
    }

    /// Back in the foreground, re-lands each channel that published bitmap cues as decoded while the upscale could
    /// not run: the drain decodes its window again in place, the landing line first, and each re-decoded cue
    /// replaces its own copy (same start, same geometry), upscaled. What was upscaled before is a lookup.
    func resumeBitmapSubtitleUpscale() {
        guard !bitmapSubtitleUpscaleOwed.isEmpty else { return }
        bitmapSubtitleRelanding.formUnion(bitmapSubtitleUpscaleOwed.intersection(subtitleDrainTargets.keys))
        bitmapSubtitleUpscaleOwed = []
        requestSubtitleDrainTick()
    }

    /// The playback-start gate: a session with a bitmap track starts once the upscaler is ready, so its first
    /// subtitle publishes upscaled like every other. A ready upscaler returns at once; a failed one is logged when a
    /// cue first needs it, and the session starts regardless.
    func awaitBitmapSubtitleUpscaler() async {
        guard AetherEngine.OptionalComponent.mlSubtitleUpscale.isBuiltIn, bitmapSubtitlePixelSize != nil,
              subtitleTracks.contains(where: { Self.isBitmapSubtitleCodec($0.codec) }) else { return }
        let t0 = DispatchTime.now().uptimeNanoseconds
        await BlockingWork.detached(priority: .userInitiated) { try? BitmapSubtitleUpscaling.shared.ready() }.value
        let waited = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if waited >= 50 {
            EngineLog.emit("[BitmapSubtitleUpscaling] playback start waited \(Int(waited)) ms for the upscaler", category: .engine)
        }
    }
}
