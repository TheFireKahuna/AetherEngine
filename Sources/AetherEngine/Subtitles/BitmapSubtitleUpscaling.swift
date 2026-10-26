import CoreGraphics
import Foundation
import Metal
#if MLSubtitleUpscale
@_exported import LibMLSubUpscaler
#endif

/// The overlay drain's bitmap subtitles upscaled before they publish (trait `MLSubtitleUpscale`): each image cue that
/// can still show is upscaled by ArtCNN on the Neural Engine (LibMLSubUpscaler) to the pixels the host draws it at,
/// `AetherEngine.bitmapSubtitlePixelSize`, inside the drain tick's decode half, so a cue enters `subtitleCues` sharp
/// and the main actor never waits for it. Without the trait, or with no pixel size, cues publish as decoded.
///
/// What cannot be upscaled publishes as decoded and is owed: in the background, where the GPU is refused, a tick
/// does not try, and a failed upscale is reported (`takeFailures`); either way the channel is re-landed on the return
/// to the foreground (`AetherEngine.resumeBitmapSubtitleUpscale`), which decodes it again, upscaled.
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

    /// What a tick's upscale did, for its log line: cues upscaled, cues found kept, and the wall time.
    struct Tally {
        var upscaled = 0
        var reused = 0
        var milliseconds = 0.0

        mutating func add(_ other: Tally) {
            upscaled += other.upscaled
            reused += other.reused
            milliseconds += other.milliseconds
        }

        /// One line per tick that upscaled anything.
        func report() {
            guard upscaled > 0 else { return }
            EngineLog.emit("[BitmapSubtitleUpscaling] upscaled \(upscaled) cue\(upscaled == 1 ? "" : "s") in "
                           + String(format: "%.1f", milliseconds) + " ms (\(reused) kept)", category: .engine)
        }
    }

    /// Below this scale a cue is drawn as decoded: a 1080p canvas on a 1080p panel needs nothing.
    static let minimumScale: CGFloat = 1.2

    /// Upscales kept within this many seconds of the playhead, either side: the drain's 15 s backscan and 60 s
    /// lead, with room for a seek back.
    static let keptSeconds: Double = 180

    #if MLSubtitleUpscale
    private let lock = NSLock()
    /// Made and prepared once; a failed preparation is not kept, so the next cue tries again (a GPU refused in the
    /// background works again in the foreground).
    private var upscaler: SubtitleUpscaler?
    private var kept: [Key: CGImage] = [:]
    private var reportedFailure = false
    private var failed = false

    private struct Key: Hashable {
        let stream: Int32
        let start: Double
        let position: [CGFloat]
        let width: Int
        let height: Int
    }
    #endif

    #if MLSubtitleUpscale
    /// The upscaler's submission, for the process: a queue of its own, so its windows' event waits hold back only its
    /// work, never the video's. Its pipelines are made through it at app open.
    private static let gpu: SubtitleUpscaleGPU? = MTLCreateSystemDefaultDevice()
        .flatMap { GPUSubmitter(device: $0, label: "SubtitleUpscaler") }.map(SubtitleUpscaleGPU.init)
    #endif

    /// Makes the pipelines and loads the models at app open, in the background; `ready()` and the first tick then find
    /// them made and loaded.
    static func prewarm() {
        #if MLSubtitleUpscale
        if let gpu { SubtitleUpscaler.prewarm(.balanced, submission: gpu) }
        #endif
    }

    /// LibMLSubUpscaler's benchmark on the upscaler's submission.
    static func benchmark(iterations: Int) -> String? {
        #if MLSubtitleUpscale
        return gpu.map { SubtitleUpscaler.benchmark(iterations: iterations, submission: $0) }
        #else
        return nil
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
    @discardableResult
    func upscale(_ events: inout [EmbeddedSubtitleDecoder.SubtitleEvent?], stream: Int32, request: Request) -> Tally {
        var tally = Tally()
        #if MLSubtitleUpscale
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { tally.milliseconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        let first = Self.firstShowable(events, playhead: request.playhead)
        guard first < events.count else { return tally }
        lock.withLock { kept = kept.filter { abs($0.key.start - request.playhead) <= Self.keptSeconds } }
        for i in first..<events.count {
            guard let event = events[i], event.cues.contains(where: { if case .image = $0.body { true } else { false } }) else { continue }
            let cues = event.cues.map { cue -> SubtitleCue in
                guard case .image(let image) = cue.body,
                      let size = Self.outputSize(image, pixelSize: request.pixelSize) else { return cue }
                guard let (upscaled, kept) = upscaled(image, size: size, stream: stream, start: cue.startTime) else { return cue }
                if kept { tally.reused += 1 } else { tally.upscaled += 1 }
                return cue.with(body: .image(SubtitleImage(cgImage: upscaled, position: image.position,
                                                           canvasSize: image.canvasSize, isForced: image.isForced)))
            }
            events[i] = EmbeddedSubtitleDecoder.SubtitleEvent(cues: cues, isPGS: event.isPGS, pgsTrimAt: event.pgsTrimAt,
                                                              textTrimAt: event.textTrimAt,
                                                              isSelfContainedPGS: event.isSelfContainedPGS)
        }
        #endif
        return tally
    }

    /// The index of the last event with cues starting at or before `playhead`, or 0 when none does.
    static func firstShowable(_ events: [EmbeddedSubtitleDecoder.SubtitleEvent?], playhead: Double) -> Int {
        events.lastIndex { $0.map { !$0.cues.isEmpty && $0.cues.allSatisfy { $0.startTime <= playhead } } ?? false } ?? 0
    }

    /// The pixel size `image` is drawn at: its canvas scaled to cover the picture's `pixelSize`, centred, as hosts
    /// place it (the picture is a crop or a rescale of the canvas, so the canvas covers it). nil when that is less than
    /// ``minimumScale`` of its own, or the canvas is unknown.
    static func outputSize(_ image: SubtitleImage, pixelSize: CGSize) -> CGSize? {
        let canvas = image.canvasSize
        guard canvas.width > 0, canvas.height > 0, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let scale = max(pixelSize.width / canvas.width, pixelSize.height / canvas.height)
        guard scale >= minimumScale else { return nil }
        return CGSize(width: (CGFloat(image.cgImage.width) * scale).rounded(),
                      height: (CGFloat(image.cgImage.height) * scale).rounded())
    }

    /// Whether an upscale failed since the last call, so the tick that ran it can owe its channels a redo.
    func takeFailures() -> Bool {
        #if MLSubtitleUpscale
        lock.withLock {
            defer { failed = false }
            return failed
        }
        #else
        false
        #endif
    }

    #if MLSubtitleUpscale
    /// The upscale of `image`, and whether it was kept from before.
    private func upscaled(_ image: SubtitleImage, size: CGSize, stream: Int32, start: Double) -> (CGImage, Bool)? {
        let p = image.position
        let key = Key(stream: stream, start: start, position: [p.minX, p.minY, p.width, p.height],
                      width: Int(size.width), height: Int(size.height))
        if let made = lock.withLock({ kept[key] }) { return (made, true) }
        do {
            let made = try upscalerLocked().upscale(image.cgImage, size: size)
            lock.withLock { kept[key] = made }
            return (made, false)
        } catch {
            let first = lock.withLock { () -> Bool in
                failed = true
                defer { reportedFailure = true }
                return !reportedFailure
            }
            if first {
                EngineLog.emit("[BitmapSubtitleUpscaling] upscale failed; the cue publishes as decoded until the foreground re-lands it: \(error)", category: .engine)
            }
            return nil
        }
    }

    private func upscalerLocked() throws -> SubtitleUpscaler {
        try lock.withLock {
            if let made = upscaler { return made }
            guard let gpu = Self.gpu else { throw SubtitleUpscaler.UpscaleError.unavailable("no GPU submission") }
            let made = try SubtitleUpscaler(configuration: .balanced, submission: gpu)
            try made.prepare()
            upscaler = made
            return made
        }
    }
    #endif
}
