import AVFoundation
import CoreMedia

/// What a host needs to build an `AVPictureInPictureController` around the software overlay: its layer, and the
/// answers behind `AVPictureInPictureSampleBufferPlaybackDelegate`. AVPlayer's own rendering is suppressed under the
/// overlay, so the overlay's layer is the picture a PiP window has to take; AVPlayer stays the transport.
@MainActor
public final class SoftwarePiPSource {
    public let layer: AVSampleBufferDisplayLayer
    let isLive: Bool
    private weak var engine: AetherEngine?

    init(layer: AVSampleBufferDisplayLayer, isLive: Bool, engine: AetherEngine) {
        self.layer = layer
        self.isLive = isLive
        self.engine = engine
    }

    /// The playable range on the layer's timebase, which must contain the layer's current time. Live sources report
    /// an indefinite range so the window shows live UI.
    public func timeRange() -> CMTimeRange {
        guard let engine else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
        return AetherEngine.softwarePiPTimeRange(
            isLive: isLive,
            layerTime: layer.sampleBufferRenderer.timebase.time.seconds,
            currentTime: engine.currentTime,
            duration: engine.duration
        )
    }

    public var isPaused: Bool { engine?.state != .playing }

    public func setPlaying(_ playing: Bool) {
        if playing { engine?.play() } else { engine?.pause() }
    }

    /// Seeks by `seconds` and calls `completion` once the seek has landed, as the window's skip contract asks.
    public func skip(by seconds: Double, completion: @escaping () -> Void) {
        guard let engine else { completion(); return }
        let target = max(0, engine.currentTime + seconds)
        Task {
            await engine.seek(to: target)
            completion()
        }
    }
}
