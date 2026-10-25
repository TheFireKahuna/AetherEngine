import Testing
@testable import AetherEngine

struct DemuxerProfileTests {
    @Test("playback profile keeps the large probe budget + prefetch")
    func playbackDefaults() {
        let p = DemuxerOpenProfile.playback
        #expect(p.probesize == 50 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 60 * 1_000_000)
        #expect(p.avioPrefetch == true)
        #expect(p.avioChunkSize == 4 * 1024 * 1024)
    }

    @Test("stillExtraction profile is random-access tuned")
    func stillExtractionTuned() {
        let p = DemuxerOpenProfile.stillExtraction
        #expect(p.avioPrefetch == false)
        #expect(p.avioChunkSize < DemuxerOpenProfile.playback.avioChunkSize)
        #expect(p.probesize < DemuxerOpenProfile.playback.probesize)
        #expect(p.maxAnalyzeDuration < DemuxerOpenProfile.playback.maxAnalyzeDuration)
    }

    /// Issue #27 (Sodalite): a stalled still-extraction chunk read could ride a
    /// ~35s syncRequest park times up to 3 retries times 2 URL passes, freezing the
    /// scrub-preview. The disposable thumbnail fetch must cap its per-chunk budget
    /// and retries far below the playback path.
    @Test("stillExtraction caps the per-chunk request budget below playback")
    func stillExtractionReadBudget() {
        let still = DemuxerOpenProfile.stillExtraction
        let playback = DemuxerOpenProfile.playback
        #expect(still.avioRequestTimeout < playback.avioRequestTimeout)
        #expect(still.avioMaxRetries < playback.avioMaxRetries)
        #expect(still.avioMaxRetries >= 1)
    }

    // MARK: - withProbeBudget (#68: caller-bounded probe budget)

    @Test("withProbeBudget(nil, nil) leaves every field untouched")
    func withProbeBudgetNilKeepsDefault() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: nil, maxAnalyzeDuration: nil)
        #expect(p.probesize == base.probesize)
        #expect(p.maxAnalyzeDuration == base.maxAnalyzeDuration)
        #expect(p.avioPrefetch == base.avioPrefetch)
        #expect(p.avioChunkSize == base.avioChunkSize)
        #expect(p.avioRequestTimeout == base.avioRequestTimeout)
        #expect(p.avioMaxRetries == base.avioMaxRetries)
    }

    @Test("withProbeBudget overrides only probesize when maxAnalyzeDuration is nil")
    func withProbeBudgetProbesizeOnly() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: 4 * 1024 * 1024, maxAnalyzeDuration: nil)
        #expect(p.probesize == 4 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == base.maxAnalyzeDuration)
    }

    @Test("withProbeBudget overrides only maxAnalyzeDuration when probesize is nil")
    func withProbeBudgetAnalyzeOnly() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: nil, maxAnalyzeDuration: 5 * 1_000_000)
        #expect(p.probesize == base.probesize)
        #expect(p.maxAnalyzeDuration == 5 * 1_000_000)
    }

    @Test("withProbeBudget overrides both probe knobs but never disturbs AVIO tuning")
    func withProbeBudgetBothKeepsAVIO() {
        let base = DemuxerOpenProfile.playback
        let p = base.withProbeBudget(probesize: 1 * 1024 * 1024, maxAnalyzeDuration: 1 * 1_000_000)
        #expect(p.probesize == 1 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 1 * 1_000_000)
        // The two probe knobs are the ONLY thing a caller may tweak; the AVIO
        // tuning (prefetch / chunk size / read budget) must ride through unchanged.
        #expect(p.avioPrefetch == base.avioPrefetch)
        #expect(p.avioChunkSize == base.avioChunkSize)
        #expect(p.avioRequestTimeout == base.avioRequestTimeout)
        #expect(p.avioMaxRetries == base.avioMaxRetries)
    }

    @Test("withProbeBudget is receiver-agnostic and never promotes to playback AVIO")
    func withProbeBudgetReceiverAgnostic() {
        let still = DemuxerOpenProfile.stillExtraction
        let p = still.withProbeBudget(probesize: 9, maxAnalyzeDuration: nil)
        #expect(p.probesize == 9)
        // Applied to .stillExtraction it must keep stillExtraction's AVIO knobs,
        // not silently inherit the playback profile.
        #expect(p.avioPrefetch == false)
        #expect(p.avioChunkSize == still.avioChunkSize)
        #expect(p.avioMaxRetries == still.avioMaxRetries)
    }

    // MARK: - headPackets (#76, #87: a bounded open for a stream's first packets)

    @Test("headPackets caps the probe far below playback, keeps playback AVIO tuning and skips stream info")
    func headPacketsCapsProbe() {
        let playback = DemuxerOpenProfile.playback
        let p = DemuxerOpenProfile.headPackets
        #expect(p.probesize == 4 * 1024 * 1024)
        #expect(p.maxAnalyzeDuration == 5 * 1_000_000)
        #expect(p.probesize < playback.probesize)
        #expect(p.avioPrefetch == playback.avioPrefetch)
        #expect(p.avioChunkSize == playback.avioChunkSize)
        #expect(p.avioRequestTimeout == playback.avioRequestTimeout)
        #expect(p.avioMaxRetries == playback.avioMaxRetries)
        #expect(p.skipStreamInfo == true)
    }

    @Test("playback + stillExtraction keep find_stream_info")
    func mainProfilesKeepStreamInfo() {
        #expect(DemuxerOpenProfile.playback.skipStreamInfo == false)
        #expect(DemuxerOpenProfile.stillExtraction.skipStreamInfo == false)
    }

    @Test("withProbeBudget preserves the receiver's skipStreamInfo")
    func withProbeBudgetPreservesSkipStreamInfo() {
        var skipping = DemuxerOpenProfile.playback
        skipping.skipStreamInfo = true
        #expect(skipping.withProbeBudget(probesize: 1, maxAnalyzeDuration: nil).skipStreamInfo == true)
        #expect(DemuxerOpenProfile.playback.withProbeBudget(probesize: 1, maxAnalyzeDuration: nil).skipStreamInfo == false)
    }
}

/// #93 residual: the #79 wedged-restart fresh reopen paid the FULL first-open cost
/// (find_stream_info probe budget) over an already-starved link, so the reopen shrinks the
/// budget. It must NOT skip find_stream_info: with the pass skipped, video_delay stays 0 and
/// matroska B-frame content arrives with NOPTS / presentation-ordered dts, which the producer
/// repair turns into telescoped durations and mass frame drops (#93 post-recovery judder).
extension DemuxerProfileTests {
    @Test("restartReopen keeps find_stream_info but bounds its probe budget")
    func restartReopenProfile() {
        let p = DemuxerOpenProfile.restartReopen
        #expect(!p.skipStreamInfo)
        #expect(p.probesize < DemuxerOpenProfile.playback.probesize)
        #expect(p.maxAnalyzeDuration < DemuxerOpenProfile.playback.maxAnalyzeDuration)
        // Sustained pump reads follow the reopen: keep the playback AVIO tuning.
        #expect(p.avioPrefetch == DemuxerOpenProfile.playback.avioPrefetch)
        #expect(p.avioChunkSize == DemuxerOpenProfile.playback.avioChunkSize)
        #expect(p.avioRequestTimeout == DemuxerOpenProfile.playback.avioRequestTimeout)
        #expect(p.avioMaxRetries == DemuxerOpenProfile.playback.avioMaxRetries)
    }

    /// #93 residual latency: the reopen open reads only the header + the bounded find_stream_info
    /// probe, then the producer seeks to the target and streams from there on its own connection, so
    /// the open-ended `bytes=0-` GET (which an origin can serve as a slow dribble: device trace, one
    /// offset=0 read spending stallWaits=14/20.5 s while a bounded sibling range answered ~300 ms) is
    /// pure cost. The reopen therefore bounds the open connection to comfortably above the probe
    /// budget so the header + probe still fit inside one fast finite range.
    @Test("restartReopen bounds the open connection above its probe budget")
    func restartReopenBoundsOpenConnection() {
        let p = DemuxerOpenProfile.restartReopen
        #expect(p.boundedInitialFetch != nil)
        // Must cover the header + the full find_stream_info probe (plus AVIO-buffer straddle margin).
        #expect((p.boundedInitialFetch ?? 0) > p.probesize)
    }

    /// The bound is scoped to the reopen alone. Playback must keep streaming from byte 0 open-ended
    /// (it plays forward from the start), and neither the still-extraction nor the head-packets
    /// opens should acquire a finite open range.
    @Test("every non-reopen profile keeps the open-ended `bytes=0-` open")
    func nonReopenProfilesStayOpenEnded() {
        #expect(DemuxerOpenProfile.playback.boundedInitialFetch == nil)
        #expect(DemuxerOpenProfile.stillExtraction.boundedInitialFetch == nil)
        #expect(DemuxerOpenProfile.headPackets.boundedInitialFetch == nil)
        // withProbeBudget must not fabricate a bound when the receiver had none.
        #expect(DemuxerOpenProfile.playback.withProbeBudget(
            probesize: 1, maxAnalyzeDuration: nil).boundedInitialFetch == nil)
    }
}
