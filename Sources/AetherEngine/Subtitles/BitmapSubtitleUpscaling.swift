import CoreGraphics
import Foundation
#if MLSubtitleUpscale
@_exported import LibMLSubUpscaler
#endif

/// The overlay drain's bitmap subtitles upscaled before they publish (trait `MLSubtitleUpscale`): each image cue that
/// can still show is upscaled by ArtCNN on the Neural Engine (LibMLSubUpscaler) to the pixels the host draws it at,
/// `AetherEngine.bitmapSubtitlePixelSize`, inside the drain tick's decode half, so a cue enters `subtitleCues` sharp
/// and the main actor never waits for it. Without the trait, or with no pixel size, cues publish as decoded.
///
/// One upscaler serves the process, used by one tick at a time (`subtitleDrainTickInFlight`). Results are kept by
/// stream, start, geometry and output size, so a cue the drain decodes again (a seek back into the retained window,
/// an audio switch) costs a lookup.
final class BitmapSubtitleUpscaling: @unchecked Sendable {
    static let shared = BitmapSubtitleUpscaling()

    /// What a tick upscales to: the host's pixel size and the drain's playhead.
    struct Request: Sendable {
        let pixelSize: CGSize
        let playhead: Double
    }

    /// Below this scale a cue is drawn as decoded: a 1080p canvas on a 1080p panel needs nothing.
    static let minimumScale: CGFloat = 1.2

    /// Upscales kept within this many seconds of the playhead, either side: the drain's 15 s backscan and 60 s
    /// lead, with room for a seek back.
    static let keptSeconds: Double = 180

    #if MLSubtitleUpscale
    private let lock = NSLock()
    private var upscaler: Result<SubtitleUpscaler, Error>?
    private var kept: [Key: CGImage] = [:]
    private var reportedFailure = false

    private struct Key: Hashable {
        let stream: Int32
        let start: Double
        let position: [CGFloat]
        let width: Int
        let height: Int
    }
    #endif

    /// Loads the models at app open, in the background; `ready()` and the first tick then find them loaded.
    static func prewarm() {
        #if MLSubtitleUpscale
        SubtitleUpscaler.prewarm(.balanced)
        #endif
    }

    /// The upscaler, made and prepared (its models loaded) on first use. Blocks: for a blocking thread.
    func ready() throws {
        #if MLSubtitleUpscale
        _ = try upscalerLocked()
        #endif
    }

    /// Replaces each image cue of `events` that can still show at `request.playhead` with its upscale: every cue of
    /// the last event starting at or before the playhead (the line a landing shows), and of every event after it.
    /// Earlier events are history the reconstruction pass reads, which nothing will show. Blocks.
    func upscale(_ events: inout [EmbeddedSubtitleDecoder.SubtitleEvent?], stream: Int32, request: Request) {
        #if MLSubtitleUpscale
        let first = Self.firstShowable(events, playhead: request.playhead)
        guard first < events.count else { return }
        lock.withLock { kept = kept.filter { abs($0.key.start - request.playhead) <= Self.keptSeconds } }
        for i in first..<events.count {
            guard let event = events[i], event.cues.contains(where: { if case .image = $0.body { true } else { false } }) else { continue }
            let cues = event.cues.map { cue -> SubtitleCue in
                guard case .image(let image) = cue.body,
                      let size = Self.outputSize(image, pixelSize: request.pixelSize) else { return cue }
                guard let upscaled = upscaled(image, size: size, stream: stream, start: cue.startTime) else { return cue }
                return cue.with(body: .image(SubtitleImage(cgImage: upscaled, position: image.position,
                                                           canvasSize: image.canvasSize, isForced: image.isForced)))
            }
            events[i] = EmbeddedSubtitleDecoder.SubtitleEvent(cues: cues, isPGS: event.isPGS, pgsTrimAt: event.pgsTrimAt,
                                                              textTrimAt: event.textTrimAt,
                                                              isSelfContainedPGS: event.isSelfContainedPGS)
        }
        #endif
    }

    /// The index of the last event with cues starting at or before `playhead`, or 0 when none does.
    static func firstShowable(_ events: [EmbeddedSubtitleDecoder.SubtitleEvent?], playhead: Double) -> Int {
        events.lastIndex { $0.map { !$0.cues.isEmpty && $0.cues.allSatisfy { $0.startTime <= playhead } } ?? false } ?? 0
    }

    /// The pixel size `image` is drawn at: its canvas mapped width-aligned onto `pixelSize`, as hosts place it. nil
    /// when that is less than ``minimumScale`` of its own, or the canvas is unknown.
    static func outputSize(_ image: SubtitleImage, pixelSize: CGSize) -> CGSize? {
        guard image.canvasSize.width > 0, pixelSize.width > 0 else { return nil }
        let scale = pixelSize.width / image.canvasSize.width
        guard scale >= minimumScale else { return nil }
        return CGSize(width: (CGFloat(image.cgImage.width) * scale).rounded(),
                      height: (CGFloat(image.cgImage.height) * scale).rounded())
    }

    #if MLSubtitleUpscale
    private func upscaled(_ image: SubtitleImage, size: CGSize, stream: Int32, start: Double) -> CGImage? {
        let p = image.position
        let key = Key(stream: stream, start: start, position: [p.minX, p.minY, p.width, p.height],
                      width: Int(size.width), height: Int(size.height))
        if let made = lock.withLock({ kept[key] }) { return made }
        do {
            let made = try upscalerLocked().upscale(image.cgImage, size: size)
            lock.withLock { kept[key] = made }
            return made
        } catch {
            let first = lock.withLock { () -> Bool in
                defer { reportedFailure = true }
                return !reportedFailure
            }
            if first {
                EngineLog.emit("[BitmapSubtitleUpscaling] upscale failed, cues publish as decoded: \(error)", category: .engine)
            }
            return nil
        }
    }

    private func upscalerLocked() throws -> SubtitleUpscaler {
        try lock.withLock {
            if let made = upscaler { return try made.get() }
            let made = Result { () throws -> SubtitleUpscaler in
                let upscaler = try SubtitleUpscaler(configuration: .balanced)
                try upscaler.prepare()
                return upscaler
            }
            upscaler = made
            return try made.get()
        }
    }
    #endif
}
