import Foundation
import Metal
import LibDeinterlace

public extension AetherEngine {

    /// Make the Dolby Vision Profile 7 FEL composer's GPU pipelines now, so the first composed frame
    /// does not wait for them.
    ///
    /// The composer makes its pipelines on the first FEL frame of a process. Its kernels ship compiled, and on
    /// an Apple TV 4K (A15) running the tvOS release the engine's pipeline archive was built for, the pipelines
    /// come from that archive in milliseconds; anywhere else they are compiled for the GPU, hundreds of
    /// milliseconds the first time, then from Metal's shader cache until an app update or a cache purge. A host
    /// that calls this at launch, or when a Profile 7 title is selected, spends that while the viewer is still in
    /// its UI. It works at utility priority off Swift's cooperative pool and returns when the pipelines are ready;
    /// a host need not wait for it.
    ///
    /// Safe to call any number of times, and concurrently with playback: the compile happens once per
    /// process, and a composition that starts while it runs waits for it rather than compiling again.
    ///
    /// - Returns: Whether the pipelines are ready. False without the `DualLayerDolbyVision` trait (there is
    ///   nothing to warm), with no Metal device, or when a pipeline cannot be made; that failure is kept,
    ///   so the dual-layer route then plays the base layer exactly as it would have without the warm.
    @discardableResult
    nonisolated static func prewarmDualLayerDolbyVision() async -> Bool {
        #if DualLayerDolbyVision
        // BlockingWork, not the cooperative pool: the compile blocks its thread for hundreds of milliseconds.
        await BlockingWork.detached(priority: .utility) { DoviFelComposer.prewarmPipelines() }.value
        #else
        false
        #endif
    }

    /// Make the GPU pipelines software decode uses now, so a stream that opens finds its own made.
    ///
    /// A software-decoded picture reaches the display through one GPU pass whose pipeline depends on its pixel
    /// format, range and colour handling, with deinterlacing and inverse telecine passes before it for
    /// interlaced and telecined streams. This makes those of the formats software decode meets (MPEG-2, H.264,
    /// VC-1, AV1 and the intermediate codecs, 8 to 12 bits, every chroma siting, grain, interlacing), about a
    /// hundred and fifty pipelines. On an Apple TV 4K (A15) running the tvOS release the pipeline archives were built for,
    /// they come from the archives the engine and LibDeinterlace ship; anywhere else they are compiled, seconds
    /// of GPU compiler time the first time, then from Metal's shader cache until an app update. A stream outside
    /// this set makes its own when it opens. Works at utility priority off Swift's cooperative pool; a host
    /// calls it once at launch and need not wait for it.
    ///
    /// - Returns: Whether there was a Metal device to warm.
    @discardableResult
    nonisolated static func prewarmSoftwareDecode() async -> Bool {
        await BlockingWork.detached(priority: .utility) { () -> Bool in
            guard let device = MTLCreateSystemDefaultDevice(),
                  let submitter = GPUSubmitter(device: device, label: "Prewarm") else { return false }
            let start = CFAbsoluteTimeGetCurrent()
            PlanarFrameFinisher.prewarmPlanned(device: device)
            DeinterlaceKernels(submission: DeinterlaceGPU(submitter)).prewarm()
            EngineLog.emit(String(format: "[Prewarm] software decode pipelines ready after %.0f ms",
                                  (CFAbsoluteTimeGetCurrent() - start) * 1000), category: .swPlayback)
            return true
        }.value
    }

    /// The default number of source bytes a warm retains, 8 MB.
    ///
    /// A byte budget rather than a duration, because a duration would need the bitrate, and the
    /// bitrate is known only after the probe, which is the round trip the warm exists to remove.
    static var defaultPrewarmByteBudget: Int { SourcePrewarmFetcher.defaultByteBudget }

    /// Fetch the opening bytes of a source the engine is not playing, so that a later `load()` of
    /// the same URL starts without paying for them (#551).
    ///
    /// For a host whose UI knows what comes next: the next episode, the item under the cursor. A
    /// cold open is two to three sequential round trips before the first sample read on a
    /// non-fast-start MP4, and on a slow origin the first byte of the data connection is the whole
    /// perceived start time. Those are spendable in advance, and this is how a host spends them.
    ///
    /// `nonisolated` and `static`: warming needs no engine, no audio session and no layer, so a
    /// host warms while its player is still on the current item. Call it from a detached task.
    ///
    /// What it does: one ranged GET from byte zero for `byteBudget` bytes, plus a second one for
    /// the trailing object only where the head says a cold open would go looking for it (an MP4
    /// whose `moov` sits behind the media). The bytes are held in memory, keyed by the exact URL,
    /// and the first `load()` of that URL takes them. They do not survive the app, and they are not
    /// a download: this is a head start, not an offline copy.
    ///
    /// What it deliberately does not do:
    ///
    /// - **It never queues for the origin.** A warm takes a request slot only if one is free right
    ///   now, and declines when the origin is metered down to one request at a time or is pacing
    ///   the engine (#377). A prewarm that would have to wait for the playing session's uplink has
    ///   stopped helping, and the report says so.
    /// - **It does not apply to `LoadOptions.nativeRemoteHLS`.** On that route AVPlayer issues the
    ///   requests and the engine sees none of them, so there is nothing here to adopt.
    ///
    /// Cancelling the task cancels the fetch and stores nothing: a host that has moved on must not
    /// find half a source warm for a URL it left behind.
    ///
    /// - Parameters:
    ///   - url: The exact source URL a later `load()` will use. A signed URL warmed under one
    ///     signature is not adopted under another, which is the conservative reading and the only
    ///     one that cannot serve the wrong bytes.
    ///   - httpHeaders: The same headers the load will carry (`LoadOptions.httpHeaders`), for
    ///     origins that enforce Referer / User-Agent / Authorization.
    ///   - byteBudget: How many bytes to retain from the head. Defaults to
    ///     ``defaultPrewarmByteBudget``.
    /// - Returns: A ``SourcePrewarmReport`` naming what was retained, or why nothing was.
    @discardableResult
    nonisolated static func prewarm(url: URL,
                                    httpHeaders: [String: String] = [:],
                                    byteBudget: Int? = nil) async -> SourcePrewarmReport {
        await SourcePrewarmFetcher.warm(url: url,
                                        extraHeaders: httpHeaders,
                                        byteBudget: byteBudget ?? SourcePrewarmFetcher.defaultByteBudget)
    }

    /// Whether a source's head is warm right now, for the request a load will make (`httpHeaders` as
    /// that load carries them).
    ///
    /// For a host that wants to skip re-warming an item it already warmed. Warm bytes live in the
    /// engine's source cache, shared with every reader of the source rather than taken by the first,
    /// so a source stays warm after the load that used it, until the cache lets it go.
    nonisolated static func isPrewarmed(url: URL, httpHeaders: [String: String] = [:]) -> Bool {
        SourceByteCache.shared.heldLength(SourceCacheKey(url: url, headers: httpHeaders), at: 0,
                                          expectedSize: nil) > 0
    }

    /// Drop every warmed source no session is reading.
    ///
    /// For a host leaving the context the warms were made for (a user signing out, a server
    /// changing): their bytes are let go now rather than after the cache's grace.
    nonisolated static func discardPrewarmedSources() {
        SourceByteCache.shared.releaseIdleSources()
    }
}
