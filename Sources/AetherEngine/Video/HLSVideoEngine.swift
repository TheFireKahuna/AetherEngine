import QuartzCore
import AVFoundation
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// HLS-fMP4 loopback session: libavformat `hls` muxer fed by `Demuxer`, fragments
/// redirected into `SegmentCache` via custom `io_open`/`io_close2`, served to
/// AVPlayer by a local HTTP server that blocks on a condvar until the requested
/// segment is muxed.
public final class HLSVideoEngine: @unchecked Sendable {

    // MARK: - Errors

    public enum HLSVideoEngineError: Error, CustomStringConvertible, LocalizedError {
        case openFailed(reason: String)
        case noVideoStream
        case unsupportedCodec(rawCodecID: UInt32)
        case zeroDuration
        case unsupportedDVProfile(profile: Int, compatID: Int)
        case muxerInit(underlying: Error)
        case alreadyStarted
        case notStarted

        public var description: String {
            switch self {
            case .openFailed(let r):     return "HLSVideoEngine: open failed (\(r))"
            case .noVideoStream:         return "HLSVideoEngine: source has no video stream"
            case .unsupportedCodec(let id): return "HLSVideoEngine: unsupported codec id \(id) (only HEVC and H.264 supported)"
            case .zeroDuration:          return "HLSVideoEngine: source has zero duration (cannot build segment plan)"
            case .unsupportedDVProfile(let p, let c): return "HLSVideoEngine: unsupported Dolby Vision profile \(p).\(c)"
            case .muxerInit(let e):      return "HLSVideoEngine: muxer init failed (\(e))"
            case .alreadyStarted:        return "HLSVideoEngine: session already started"
            case .notStarted:            return "HLSVideoEngine: session not started"
            }
        }

        public var errorDescription: String? { description }
    }

    // MARK: - State

    let sourceURL: URL
    /// AE#792: the session's live header set. Seeded from `sourceHTTPHeaders` at init; `AetherEngine`
    /// installs its session store here before `start()`, so the opens below and the playback demuxer it
    /// hands over read the same value, and `updateRequestHeaders(_:)` reaches both.
    var requestHeaders: RequestHeaderStore
    var sourceHTTPHeaders: [String: String] { requestHeaders.current }
    private let dvModeAvailable: Bool

    /// From `LoadOptions.keepDvh1TagWithoutDV`; default OFF, set only for misreporting DV panels.
    private let keepDvh1TagWithoutDV: Bool

    /// From `LoadOptions.forceDolbyVisionOnNonDVDisplay` (AE#455); default OFF. Read only by the P8.1
    /// route, and only while `effectiveDvMode` is false.
    let forceDolbyVisionOnNonDVDisplay: Bool

    /// From `LoadOptions.dolbyVisionHandling`; default `.automatic`. `.baseLayerOnly` sends a Dolby
    /// Vision source with a presentable base layer down the plain hvc1 / av01 route on every display
    /// (`VideoRoutingPolicy.presentsDolbyVisionBaseLayer`), ahead of every DV branch including AE#455.
    let dolbyVisionHandling: DolbyVisionHandling

    /// From `LoadOptions.stereoPresentation`: how a 3D source is presented (`StereoVideoSignal.resolve`).
    let stereoPresentation: StereoPresentation

    /// Diagnostic lever for `aetherctl serve --stereo`: resolve the stereo signal as visionOS does on a
    /// system that presents 2D, so a Mac can serve a visionOS simulator or device what it would get.
    let stereoOnAnySystem: Bool

    /// What this session tells AVPlayer about a stereo source; nil for 2D. Set with the video config.
    private(set) var stereoSignal: StereoVideoSignal?

    /// AE#532: the profile this source's own RPU reports, when the container record was worth doubting
    /// (`DolbyVisionRecordAudit`). nil when nothing was read, which is every source but a Profile 5
    /// record over a BT.2020 YCbCr HDR VUI. The route believes it over the record.
    let dolbyVisionRPUProfile: Int?

    /// Match Content master toggle at load time; one input to the master-vs-media-playlist routing decision.
    private let matchContentEnabled: Bool

    /// Whether the connected display can present any HDR (HDR10, HLG, HDR10+, or DV).
    private let displaySupportsHDR: Bool

    /// Whether the panel was already in HDR at load time (`currentEDRHeadroom > 1`). When true,
    /// master-playlist routing is safe regardless of `matchContentEnabled` (AetherEngine#4).
    private let panelIsInHDRMode: Bool
    /// The load's panel answer when its startup plan decided it before the display switch: the session is
    /// prepared for the playlist it implies (`plannedServesMaster`) and `serve(panelIsInHDRMode:)` serves it.
    /// nil leaves the answer to `serve(panelIsInHDRMode:)`, from the settled panel.
    var plannedPanelIsInHDRMode: Bool?
    /// The playlist `serve(panelIsInHDRMode:)` will hand AVPlayer, known from `prepare()` on when the load
    /// planned the panel answer: true for the master, false for the media playlist, nil until `serve`.
    private(set) var plannedServesMaster: Bool?
    /// How this session's output carries its audio (`HLSOutputShape`), decided in `prepare()` before the first
    /// producer is built, from the playlist the load planned.
    private(set) var outputShape: HLSOutputShape = .muxed
    /// The demuxed shape's audio rendition: its segments, on the video's indices. Nil when muxed. Guarded by
    /// `restartLock` with `cache`.
    var audioRenditionCache: SegmentCache?

    /// `dvModeAvailable || keepDvh1TagWithoutDV`; DV routing branches key off this.
    var effectiveDvMode: Bool { dvModeAvailable || keepDvh1TagWithoutDV }

    /// Caller-chosen audio stream index; nil falls back to `av_find_best_stream`. Enables
    /// host-driven track switching via `AetherEngine.selectAudioTrack(index:)` reload.
    private let audioSourceStreamIndexOverride: Int32?
    /// AE#641: the source audio streams this session already found undecodable (their bridge decoded
    /// nothing). When the pick lands on one again, the cascade goes straight to its video-only tail.
    let undecodableAudioStreamIndices: Set<Int32>

    /// Whether the cascade has to skip the stream it is about to build a pipeline for.
    nonisolated static func isKnownUndecodable(_ indices: Set<Int32>, sourceAudioStreamIndex: Int32) -> Bool {
        sourceAudioStreamIndex >= 0 && indices.contains(sourceAudioStreamIndex)
    }

    /// AE#443: whoever REPLACES one of these two mid-session owes the session the totals the outgoing
    /// instance held (`retireDemuxer` / `retireProducer` below). They carry the session's byte and
    /// restart counters, and a fresh instance starts them at zero.
    var demuxer: Demuxer?
    var cache: SegmentCache?   // internal for the teardown-partial witness test
    var producer: HLSSegmentProducer? {
        didSet {
            // Audit SEG-104: a gate open is checked against this under `anchorShiftLock`, atomically
            // with what it records, so a producer that was replaced cannot record after.
            anchorShiftLock.lock()
            installedProducerEpoch = producer?.epoch
            anchorShiftLock.unlock()
        }
    }
    private var server: HLSLocalServer?
    var provider: VideoSegmentProvider?
    let nativeLiveDVRPolicy = LiveDVRRetentionPolicy() // shared native retention contract; internal for integration witnesses
    private let liveRetentionQueue = DispatchQueue(label: "com.aetherengine.live-retention", qos: .utility)
    private var liveRetentionScheduled = false // restartLock; at most one pending I/O job
    private var liveRetentionRevision: UInt64 = 0 // restartLock; do not lose an update during I/O

    var nativeLiveDVRWindow: LiveDVRRetentionPolicy.Snapshot? { nativeLiveDVRPolicy.snapshot }
    var nativeLiveDVRMandatoryBytes: Int { subsystemSnapshot().cache?.nativeLiveMandatoryBytes ?? 0 }

    func setNativeLiveDVRLimits(_ limits: LiveDVRLimits, availableCapacityBytes: Int64?) -> Bool {
        restartLock.lock()
        let currentCache = cache
        let currentProvider = provider
        restartLock.unlock()
        guard isLiveSession, let currentCache, currentProvider != nil else { return false }
        nativeLiveDVRPolicy.update(limits, availableBytes: availableCapacityBytes, residentBytes: currentCache.totalBytes)
        currentCache.startNativeLiveDVRExpiryChecks()
        restartLock.lock()
        liveRetentionRevision &+= 1
        let schedule = !liveRetentionScheduled
        liveRetentionScheduled = true
        restartLock.unlock()
        if schedule {
            liveRetentionQueue.async { [weak self] in
                self?.drainNativeLiveRetentionUpdates()
            }
        }
        return true
    }

    private func drainNativeLiveRetentionUpdates() {
        while true {
            restartLock.lock()
            let revision = liveRetentionRevision
            let currentProvider = provider
            restartLock.unlock()
            currentProvider?.applyNativeLiveDVRRetention()
            restartLock.lock()
            let settled = liveRetentionRevision == revision
            if settled { liveRetentionScheduled = false }
            restartLock.unlock()
            if settled { return }
        }
    }

    /// The 2026-09-02 field session retained 64 segments spanning more than four minutes. Cache
    /// mutations can arrive much faster than a host timeline needs to redraw, so fold them into at
    /// most four snapshots a second while preserving every final resident shape.
    ///
    /// The fold is timed on a private-queue `DispatchSourceTimer`, not on `Task.sleep` in a detached
    /// task. The cooperative pool is capped at the core count and never overcommits, and this engine's
    /// own reader work blocks threads in it (AE#422), so a delayed job there arrives when a thread
    /// frees up rather than when it was due: `SlowServeSignal` records a `userInitiated` `asyncAfter`
    /// that did not fire within 15 s on a loaded CI runner. A band is wanted exactly while the engine
    /// is busiest, which is precisely when that queue is worst.
    private let residentRangesPublishLock = NSLock()
    private let residentRangesPublishQueue = DispatchQueue(
        label: "aether.residentranges.publish", qos: .utility)
    private var residentRangesPublishTimer: DispatchSourceTimer?
    private var residentRangesPublishPending = false
    private var residentRangesObserver: (@Sendable ([ClosedRange<Double>]) -> Void)?

    func setResidentRangesObserver(
        _ observer: (@Sendable ([ClosedRange<Double>]) -> Void)?
    ) {
        residentRangesPublishLock.lock()
        residentRangesObserver = observer
        residentRangesPublishLock.unlock()
    }

    func noteResidentSetChanged() {
        residentRangesPublishLock.lock()
        residentRangesPublishPending = true
        guard residentRangesPublishTimer == nil else {
            residentRangesPublishLock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: residentRangesPublishQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .never,
                       leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.publishResidentRanges() }
        residentRangesPublishTimer = timer
        residentRangesPublishLock.unlock()
        timer.resume()
    }

    /// Drops a fold that has not fired yet. The engine clears its published band on teardown, so a
    /// snapshot that lands after this would describe a cache that is already gone.
    private func cancelResidentRangesPublish() {
        residentRangesPublishLock.lock()
        let timer = residentRangesPublishTimer
        residentRangesPublishTimer = nil
        residentRangesPublishPending = false
        residentRangesPublishLock.unlock()
        timer?.cancel()
    }

    private func publishResidentRanges() {
        residentRangesPublishLock.lock()
        residentRangesPublishPending = false
        let observer = residentRangesObserver
        residentRangesPublishLock.unlock()

        observer?(residentPlaylistRanges())

        residentRangesPublishLock.lock()
        let fired = residentRangesPublishTimer
        residentRangesPublishTimer = nil
        let publishAgain = residentRangesPublishPending
        residentRangesPublishLock.unlock()
        fired?.cancel()
        if publishAgain { noteResidentSetChanged() }
    }

    /// Side demuxer for live HLS ingest with a separate audio rendition playlist; nil for muxed-audio
    /// sessions. Torn down by `stop()` identically to the main demuxer (markClosed + detached close).
    var sideAudioDemuxer: Demuxer?

    /// Packed-audio companion (Apple HLS packed audio: raw ADTS AAC + ID3 PRIV program-clock anchor).
    /// `startPts` is the PRIV timestamp rescaled into the side stream's time base; the fallback duration is
    /// one AAC frame. Both threaded onto the producer for synthesized side-audio timestamps. nil for TS / muxed.
    private var packedSideAudioStartPts: Int64?
    private var packedSideAudioFallbackDurationPts: Int64 = 0

    /// Stream index actually muxed (post override-validation and stream-copy/bridge cascade), or -1
    /// for video-only. For demuxed-audio sessions indexes the SIDE demuxer. Set once in `start()`;
    /// host reads this to avoid triggering a pointless reload of the track already on air.
    public private(set) var activeAudioSourceStreamIndex: Int32 = -1

    /// Audio tracks from the side demuxer, snapshotted at `start()`. Empty for muxed-audio sessions.
    public private(set) var companionAudioTracks: [TrackInfo] = []

    var videoStreamIndex: Int32 = -1
    /// The video stream the producer muxes: the source's on a native session, the placeholder's on an overlay one.
    var savedVideoConfig: HLSSegmentProducer.StreamConfig?
    /// The source's own video stream, for everything that decodes its pictures (the keyframe reader, scrub stills,
    /// the I-frame stills): `savedVideoConfig` on a native session.
    var sourceVideoConfig: HLSSegmentProducer.StreamConfig?
    var savedAudioConfig: HLSSegmentProducer.AudioConfig?

    /// When true, the session exposes the native subtitle WebVTT rendition (separate from the A/V
    /// variant, served by HLSLocalServer) and arms its cue readers on track selection (#15 / Sodalite#32).
    /// Set before `start()`.
    var enableNativeSubtitleTrackForSession: Bool = false

    /// AE#682: the host asked for an I-frame rendition. Whether the session can serve one is decided
    /// in `start()` and read back as `iFrameRenditionVerdict`.
    var iFramePlaylistRequested = false
    /// An independent reader for a custom-IO source, which this session cannot reopen by URL: what the
    /// session's keyframe reader reads through (`sessionKeyframeReader`). Set before `start()`. The session
    /// owns it from then on and closes it: through the keyframe reader that took it, or in `stop()`.
    var customKeyframeReader: (reader: IOReader, formatHint: String?)?
    /// The keyframe reader reads a custom source's clone, which has no origin to ration. Set with the reader.
    private var isCustomKeyframeSource = false
    private(set) var iFrameRenditionVerdict: IFrameRenditionEligibility.Verdict = .absent(.notRequested)
    /// False for a Dolby Vision Profile 5 / 10.0 source in a build without the
    /// `DualLayerDolbyVision` trait: none of its frames can become a correct still.
    private(set) var yieldsStills = true
    /// Dolby Vision without a displayable base layer (Profile 5, AV1 Profile 10.0): only the system
    /// compositor shows it in colour, so scrub previews go through `compositorPreviewFile`.
    private(set) var previewNeedsCompositor = false
    private let compositorPreviewLock = NSLock()
    private var compositorPreviewFiles: [(identity: String, file: CompositorPreviewFile)] = []
    private var compositorPreviewSerial = 0
    private var compositorHoldURL: URL?
    /// Bumped by every `compositorPreviewFile` call, so a source read queued behind newer requests
    /// is skipped instead of making the latest one wait for it.
    private var compositorPreviewRequest = 0
    /// Keyframes for previews outside the resident window: the served I-frame rendition when there
    /// is one, else a side reader of this session's own, built on the first request that needs it.
    /// Guarded by `restartLock`.
    private var previewKeyframes: IFrameRendition?
    private var previewKeyframeBuilder: PreviewKeyframeBuilder?
    /// Whether this session may read preview keyframes off the source: the I-frame rendition's own
    /// rule (keyframe-aligned plan, a reopenable URL, no serial or held origin, no disc), decided at
    /// start. A Profile 5 / 10.0 session never serves that rendition, so this is asked separately.
    private var previewReadsSource = false
    nonisolated static let compositorPreviewFileLimit = 12
    /// AE#682: the server withheld the JPEG I-frame playlist because AVPlayer never asked for a media
    /// segment, which is how a refused HDR variant looks next to an SDR I-frame rendition.
    var iFrameRenditionWithheld: Bool { server?.iFrameRenditionWithheld ?? false }
    private var iFrameRendition: IFrameRendition?

    /// Native subtitle rendition marked DEFAULT=YES in the master (Sodalite#32). Set before `start()`; the
    /// provider advertises this ordinal as the group default so a host-selected legible track renders.
    var nativeSubtitleDefaultOrdinal: Int = 0

    /// Source position (seconds, playlist axis) the session will start at (resume/seek). Set
    /// before `start()`; anchors the FIRST producer at the matching segment instead of seg0
    /// (#93 residual: the seg0 cold start was torn down unwatched on every resume, and the
    /// fetch/restart race could 404 the item into a host reload). nil/0 keeps baseIndex 0.
    // Public so aetherctl's serve --start-position can repro the anchored resume path (#99).
    public var initialStartSeconds: Double?
    /// Resolved in start() from `initialStartSeconds` once the segment plan exists.
    private(set) var initialProducerBaseIndex: Int = 0
    /// Set once the main demuxer sits at the initial producer's start (step 8's seek ran early).
    var demuxerAtInitialProducerStart = false

    /// One cue store per declared text track (#55, all-tracks), ordinal-aligned with
    /// `nativeSubtitleLanguagesForSession`. Re-threaded onto every producer restart so
    /// per-segment cue drain survives seek/audio-switch. Empty = no native subtitles active.
    var nativeSubtitleCueStoresForSession: [NativeSubtitleCueStore] = []

    /// ISO 639-2 / BCP-47 language tags parallel to `nativeSubtitleCueStoresForSession`.
    /// nil entry = no language box for that track.
    var nativeSubtitleLanguagesForSession: [String?] = []

    /// Per-rendition master metadata parallel to the stores (unique NAMEs + FORCED dispositions);
    /// empty falls back to per-ordinal locale names, which collapse in AVFoundation when a
    /// language repeats. Built by `AetherEngine.nativeSubtitleRenditionInfos(for:)` at load.
    var nativeSubtitleRenditionInfosForSession: [NativeSubtitleRenditionInfo] = []

    /// #77: in-band CC stream index + observer, re-threaded onto every producer so the tap survives
    /// seek/reload/wedge. Set before start(). -1 / nil = no CC tap.
    var closedCaptionStreamIndexForSession: Int32 = -1
    var closedCaptionObserverForSession: (@Sendable (UnsafePointer<AVPacket>, AVRational) -> Void)?

    /// #131: A53/SEI caption observer, re-threaded onto every producer like the #77 CC observer.
    /// Set before start() when the source has no demuxable CC stream.
    var a53CaptionObserverForSession: (@Sendable ([CCDataParser.CCTriplet], Int64, Int64, AVRational) -> Void)?

    /// #260: per-frame presentation times on both axes. Lock-guarded because the pump reads it once per muxed
    /// frame while the host can install or clear it from any thread at any time (a subtitle track switched
    /// mid-title must not have to wait for the next producer).
    private let frameTimeObserverLock = NSLock()
    private var _nativeVideoFrameTimeObserver: NativeVideoFrameTimeObserver?

    func setNativeVideoFrameTimeObserver(_ observer: NativeVideoFrameTimeObserver?) {
        frameTimeObserverLock.lock()
        _nativeVideoFrameTimeObserver = observer
        frameTimeObserverLock.unlock()
    }

    private func nativeVideoFrameTimeObserverSnapshot() -> NativeVideoFrameTimeObserver? {
        frameTimeObserverLock.lock(); defer { frameTimeObserverLock.unlock() }
        return _nativeVideoFrameTimeObserver
    }

    /// Monotonic producer generation handed to each producer (#260). Process-wide rather than per
    /// session (#314): a `load()` builds a new HLSVideoEngine, and a per-instance counter would restart
    /// under a host that is still holding the outgoing session's reports. Its own allocator, with its
    /// own lock, because `makeProducer` runs both under `restartLock` (live reopen) and outside it
    /// (initial bring-up), and because two sessions overlap while the outgoing one unwinds.
    private static let producerEpochs = FrameTimeSequence()

    private func nextProducerEpoch() -> UInt64 {
        HLSVideoEngine.producerEpochs.next()
    }

    /// Sodalite#32: ordinal-aligned source stream indices for the native subtitle cue stores (nil entry =
    /// no demuxable stream, e.g. a sidecar). Drives the producer's subtitle tap: the pump keeps these
    /// streams and hands their packets to the session tap, which decodes into the ordinal's store. Set
    /// before start() by the host, or by the auto-attach/attach APIs.
    var nativeSubtitleSourceStreamIndicesForSession: [Int32?] = []

    /// Session-lifetime tap decode routes keyed by source stream index. Decoders persist across producer
    /// restarts so their internal dedup absorbs the re-read overlap; the store dedups again on append.
    /// Guarded by subtitleTapLock: an abandoned wedged producer's final packets can race the replacement
    /// producer's tap.
    private var subtitleTapRoutes: [Int32: (decoder: EmbeddedSubtitleDecoder, store: NativeSubtitleCueStore)] = [:]
    /// Streams the tap leaves alone: the ones the session's subtitle source reads from the index, whose
    /// renditions the index fills whole at load. Under `subtitleTapLock`.
    private var subtitleTapExcludedStreams: Set<Int32> = []
    private let subtitleTapLock = NSLock()

    /// #112 rework: session-lifetime retention of every embedded subtitle stream's packets,
    /// harvested by the producer pump (no second connection, no side demuxer). The MainActor
    /// overlay drainer decodes from it near the playhead. Survives producer restarts.
    let subtitlePacketStore = SubtitlePacketStore()

    /// #112 rework: every embedded subtitle stream in the session demuxer, text AND bitmap.
    /// These all stay in the producer keep-set so late track enables need no restart.
    var allEmbeddedSubtitleStreamIndices: Set<Int32> {
        Set((demuxer?.subtitleTrackInfos() ?? []).map { Int32($0.id) })
    }

    /// #112 rework: build an overlay decoder for any embedded subtitle stream (text or
    /// bitmap), seeded exactly like the tap routes. The drainer owns the returned decoder.
    func makeOverlayDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        guard let dem = demuxer else { return nil }
        let w = savedVideoConfig.map { Int32($0.codecpar.pointee.width) } ?? 1920
        let h = savedVideoConfig.map { Int32($0.codecpar.pointee.height) } ?? 1080
        // Audit DMX-108: the decoder copies what it needs out of the stream inside the call, so a
        // live reopen's close() cannot free the stream underneath it.
        let made = dem.withStream(at: streamIndex) { stream in
            EmbeddedSubtitleDecoder(stream: stream,
                                    sourceVideoWidth: w > 0 ? w : 1920,
                                    sourceVideoHeight: h > 0 ? h : 1080,
                                    preserveASSMarkup: preserveASSMarkupForSubtitleTap,
                                    teletextPage: teletextPageForSubtitleTap)
        }
        return made ?? nil
    }

    /// Sodalite#32 Phase 2: tap decoders honor the host's markup preference so the overlay can render
    /// styled ASS from tap-fed cues; the WebVTT rendition strips the markup at serve time instead.
    /// Set before start() (AetherEngine+Loading).
    var preserveASSMarkupForSubtitleTap = false
    var teletextPageForSubtitleTap: Int? = nil

    var subtitleTapActive: Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return !subtitleTapRoutes.isEmpty
    }

    func subtitleTapCoversStream(_ idx: Int32) -> Bool {
        subtitleTapLock.lock(); defer { subtitleTapLock.unlock() }
        return subtitleTapRoutes[idx] != nil
    }

    /// Enable the native WebVTT subtitle renditions for the session (#55). Call before `start()`
    /// so the master playlist declares the SUBTITLES group. `aetherctl serve --native-subs` uses
    /// this; a full session wires it via `LoadOptions.prepareNativeSubtitles`.
    public func requestNativeSubtitleTrack() {
        enableNativeSubtitleTrackForSession = true
    }

    /// Ask for an I-frame rendition in the master (AE#682), the `LoadOptions.serveIFramePlaylist`
    /// path a full session uses. Must precede `start()`.
    public func requestIFramePlaylist() {
        iFramePlaylistRequested = true
    }

    /// Attach `count` fresh cue stores (one per declared text track) to the current producer (#55).
    /// Call after `start()`. `languages` and `sourceStreamIndices` are ordinal-aligned, nil-padded.
    public func attachNativeSubtitleStores(count: Int, languages: [String?] = [],
                                           sourceStreamIndices: [Int32?] = []) {
        guard count > 0 else { return }
        let stores = (0..<count).map { _ in NativeSubtitleCueStore() }
        let langs = (0..<count).map { i in i < languages.count ? languages[i] : nil }
        let indices = (0..<count).map { i in i < sourceStreamIndices.count ? sourceStreamIndices[i] : nil }
        // Guard the session arrays under restartLock: a runtime attach (this call, host thread) otherwise
        // races the pump thread iterating them in handleVideoShiftKnown and makeProducer's read (#55).
        restartLock.lock()
        nativeSubtitleCueStoresForSession = stores
        nativeSubtitleLanguagesForSession = langs
        nativeSubtitleSourceStreamIndicesForSession = indices
        let prod = producer
        restartLock.unlock()
        rebuildSubtitleTapRoutes()
        armSubtitleTap(on: prod)
    }

    /// Attach one store per non-bitmap subtitle track from the engine's demuxer (#55, all-tracks).
    /// Call after `start()`. Returns per-track languages for logging.
    @discardableResult
    public func attachAllNativeSubtitleStores() -> [String?] {
        // Decoder-name classifier: an exact-match Set of descriptor names here never matched TrackInfo.codec
        // (the libavcodec decoder name), so bitmap tracks leaked into the native subtitle store set.
        let text = (demuxer?.subtitleTrackInfos() ?? []).filter { !AetherEngine.isBitmapSubtitleCodec($0.codec) }
        let languages = text.map { $0.language }
        attachNativeSubtitleStores(count: text.count, languages: languages,
                                   sourceStreamIndices: text.map { Int32($0.id) })
        return languages
    }

    // MARK: - Subtitle pump tap (Sodalite#32)

    /// (Re)build the session tap routes from the current stores + stream indices. One
    /// EmbeddedSubtitleDecoder per demuxable text track, plain text (the native rendition carries no
    /// markup). Decoders live for the session, not the producer, so a restart's re-read dedups.
    private func rebuildSubtitleTapRoutes() {
        subtitleTapLock.lock()
        defer { subtitleTapLock.unlock() }
        subtitleTapRoutes.removeAll()
        guard demuxer != nil else { return }
        for (ordinal, sidx) in nativeSubtitleSourceStreamIndicesForSession.enumerated() {
            guard let sidx, !subtitleTapExcludedStreams.contains(sidx), ordinal < nativeSubtitleCueStoresForSession.count,
                  let decoder = makeOverlayDecoder(streamIndex: sidx) else { continue }
            subtitleTapRoutes[sidx] = (decoder, nativeSubtitleCueStoresForSession[ordinal])
        }
        if !subtitleTapRoutes.isEmpty {
            EngineLog.emit(
                "[HLSVideoEngine] subtitle pump tap armed for streams \(subtitleTapRoutes.keys.sorted())",
                category: .session
            )
        }
    }

    /// #364: re-seed the tap decoders after a session decode option changed under them (the teletext
    /// page). Same rebuild `attachNativeSubtitleStores` performs, minus the store swap, so the routes
    /// keep their cue stores and only the decoders are new. Cues already harvested keep the page they
    /// were decoded with: they are in the rendition the host is serving and are not ours to rewrite.
    func refreshSubtitleTapDecoders() {
        restartLock.lock()
        let hasRoutes = !nativeSubtitleSourceStreamIndicesForSession.isEmpty
        let prod = producer
        restartLock.unlock()
        guard hasRoutes else { return }
        rebuildSubtitleTapRoutes()
        armSubtitleTap(on: prod)
    }

    /// Layer 3 step 3: the subtitle source's routes are settled, and `streams` are read from the index. The
    /// tap stops decoding them, on this producer and every later one.
    func excludeFromSubtitleTap(_ streams: Set<Int32>) {
        subtitleTapLock.lock()
        subtitleTapExcludedStreams = streams
        subtitleTapLock.unlock()
        restartLock.lock()
        let prod = producer
        restartLock.unlock()
        rebuildSubtitleTapRoutes()
        armSubtitleTap(on: prod)
    }

    /// Wire the tap onto a producer (initial + every restart).
    private func armSubtitleTap(on prod: HLSSegmentProducer?) {
        guard let prod else { return }
        subtitleTapLock.lock()
        let indices = Set(subtitleTapRoutes.keys)
        subtitleTapLock.unlock()
        prod.subtitleTapStreamIndices = indices
        if indices.isEmpty {
            prod.subtitleTapObserver = nil
        } else {
            prod.subtitleTapObserver = { [weak self] idx, pkt, tb in
                self?.handleSubtitleTapPacket(streamIndex: idx, packet: pkt, timeBase: tb)
            }
        }
        // #112 rework: harvest every embedded subtitle stream's packets into the session
        // store. Runs on the pump thread; the store is lock-guarded. Split-PES PGS streams
        // (MPEG-TS) go through the store's display-set reassembly.
        let assemblyIndices = demuxer?.splitDisplaySetSubtitleStreamIndices() ?? []
        prod.subtitlePacketSink = { [subtitlePacketStore] idx, pkt, tb in
            subtitlePacketStore.harvest(streamIndex: idx, packet: pkt, timeBase: tb,
                                        assembleSplitDisplaySets: assemblyIndices.contains(idx))
        }
    }

    /// Where the installed producer began reading and how far it has read, for the cue stores' reading spans
    /// (`noteSourceRead`). Under `subtitleTapLock`.
    private var sourceReadRun: (epoch: UInt64, from: Double)?

    /// Pump thread: the installed producer has read the source through `seconds` (`.infinity`: to its end).
    /// Its run of the harvest coverage (#416) begins at its first read and extends with every later one, so
    /// the drain and the OCR worker can tell a stretch with no subtitle in it from one nobody read; each text
    /// stream the tap decodes has every cue before it, so its rendition can answer a request there at once.
    /// A cue store is told a margin short of the read: a muxer interleaves a subtitle block by its own time,
    /// which can trail the video packet in hand.
    private func noteSourceRead(through seconds: Double, producerEpoch: UInt64) {
        subtitleTapLock.lock()
        defer { subtitleTapLock.unlock() }
        guard let run = sourceReadRun, run.epoch == producerEpoch else {
            sourceReadRun = (producerEpoch, seconds)
            subtitlePacketStore.noteHarvestAnchor(at: seconds)
            return
        }
        guard seconds.isFinite else {
            subtitlePacketStore.noteHarvestEnd()
            for route in subtitleTapRoutes.values { route.store.noteRead(from: run.from, through: .infinity) }
            onSourceReadToEnd?()
            return
        }
        subtitlePacketStore.noteHarvestProgress(through: seconds)
        let through = seconds - AetherEngine.nativeSubtitleReadMarginSeconds
        guard through > run.from else { return }
        for route in subtitleTapRoutes.values { route.store.noteRead(from: run.from, through: through) }
    }

    /// The installed producer read the source to its end: every subtitle packet is in the store.
    var onSourceReadToEnd: (@Sendable () -> Void)?

    /// The segment that holds `subtitleReadAheadThrough`, one past it so the read covers its end; nil while
    /// nobody asks. On the playlist axis the plan is stamped on: source time less the seam shift.
    private func subtitleReadAheadSegmentIndex() -> Int? {
        guard let through = subtitleReadAheadThrough?(), through.isFinite else { return nil }
        return segmentIndexForPlaylistTime(through - playlistShiftSeconds) + 1
    }

    /// Pump-thread callback: decode the tapped packet into its ordinal's cue store. Text subtitle decode
    /// is a parse (microseconds), so it runs inline; the lock serializes an abandoned producer's tail
    /// against the replacement producer.
    private func handleSubtitleTapPacket(streamIndex: Int32, packet: UnsafeMutablePointer<AVPacket>,
                                         timeBase: AVRational) {
        subtitleTapLock.lock()
        defer { subtitleTapLock.unlock() }
        guard let route = subtitleTapRoutes[streamIndex] else { return }
        if let event = route.decoder.decode(packet: packet, streamTimeBase: timeBase),
           !event.cues.isEmpty {
            route.store.appendCues(event.cues)
        }
    }

    /// Per-frame fallback duration in source time_base for backfilling `pkt->duration` when the
    /// matroska demuxer drops per-block durations. Computed once in `start()`; audio's is its
    /// `AudioConfig.frameDuration`.
    private var videoFallbackDurationPts: Int64 = 40

    /// First video keyframe PTS in source video TB. Non-zero on MKV remuxes where the IDR lives
    /// past PTS=0. Producer subtracts this from every packet so seg-0's tfdt aligns with the
    /// playlist's cumulative-EXTINF origin of 0 (AVPlayer stalls at `waitingToPlay` otherwise).
    private var firstKeyframePts: Int64 = 0

    /// `firstKeyframePts` in seconds; diagnostic. The authoritative clock translation is
    /// `playlistShiftSeconds` (updated dynamically per gate open).
    public private(set) var firstKeyframeSeconds: Double = 0

    /// The video is decoded by the session's own decoder and shown in the software overlay, AVPlayer served a
    /// placeholder of its format (`OverlayPlaceholder`): a stream AVPlayer cannot decode itself. Set by the engine
    /// before `prepare()`.
    var overlayDecodesVideo = false
    /// That placeholder, made by `prepare()`; every producer of the session serves it in place of the source's video.
    private(set) var overlayPlaceholder: OverlayPlaceholder?
    /// The overlay session's own decode of the source, fed by every producer and shown by `DecodedPictureSource`.
    /// Made by `prepare()`.
    private(set) var overlayDecodeTap: OverlayDecodeTap?
    /// What the overlay's decoder does with interlaced carriage, as the load decided. Set before `prepare()`.
    var overlayDeinterlace = DeinterlaceConfig()
    /// The overlay decoder's A53 captions, in presentation order on the source axis (the native route's are read off
    /// the packets, `a53CaptionObserverForSession`, and AVPlayer is served placeholder bytes here).
    var overlayCaptionObserverForSession: (@Sendable ([CCDataParser.CCTriplet], Double) -> Void)?

    #if DualLayerDolbyVision
    /// `LoadOptions.felOverlay`: every producer of the session hands its enhancement layer to this tap, which
    /// the FEL overlay reads. Set by the engine before the session starts.
    var felTap: FelEnhancementTap?
    /// Whether the video's parameter sets state full range, which is the range AVPlayer decodes the picture with:
    /// the FEL overlay asks for the matching format so it reads the base layer's own codes. Set by `prepare()`.
    private(set) var parameterSetsStateFullRange = false
    #endif

    /// AE#270: source PTS the container's timeline starts at, clamped at 0. The published playhead folds
    /// it out so it stays on the same 0-based axis as `duration`.
    public private(set) var sourceStartSeconds: Double = 0
    /// Written during start(), consumed after that operation has joined. Does not poll the
    /// mutable demuxer from the main actor while playback is reading or tearing down.
    private(set) var openedSourceIsSeekable = false

    /// Result of the stream-copy / bridge / video-only cascade. Possible values:
    /// `"Stream-copy (EAC3+JOC Atmos)"`, `"Stream-copy (<CODEC>)"`, `"<CODEC> → PCM bridge"`, `"<CODEC> → EAC3 bridge"`.
    /// nil when no audio pipeline is live.
    public internal(set) var audioPipelineDescription: String?

    /// AE#462: the same cascade result as a typed fact, so a host can act on it. The label above is
    /// for a human and cannot separate the two ways of ending up with no pipeline: a source that has
    /// no audio track and a source whose audio could not be delivered both leave it nil, and only the
    /// second is a reason for a fallback ladder to demote. Set at each of the cascade's three exits.
    public internal(set) var audioDelivery: AudioDelivery = .none

    /// AE#520: the stream-copied audio bitstream carries JOC, so this session's `ec-3` track is
    /// Atmos and reaches the receiver as a 2-channel MAT carrier. A host that reads a channel count
    /// off the HDMI route has to know that, or it reads the carrier as a downmix.
    public internal(set) var audioIsAtmosStreamCopy = false

    /// The audio is TrueHD Atmos or DTS:X rendered to APAC (`objectAudioRendering`), which on tvOS needs
    /// `AtmosOutputActivator` beside the player to reach the receiver as Atmos.
    var audioIsAPAC = false

    /// The APAC track is TrueHD Atmos, not DTS:X: only then does `AtmosOutputActivator` bring the
    /// receiver to Dolby Atmos, which a DTS programme is not.
    var audioAPACIsFromDolbyAtmos = false

    /// The DTS:X decoder confirmed the playing track as DTS:X (#744), whatever FFmpeg's profile label said. The
    /// engine folds it into the published track's `isDTSX`.
    var audioIsConfirmedDTSX = false

    /// Producer's `videoShiftPts` in seconds, updated on every gate open. AVPlayer clock =
    /// `source_pts - playlistShiftSeconds`. Lock-guarded: written on pump thread, read on others.
    public var playlistShiftSeconds: Double {
        shiftLock.lock(); defer { shiftLock.unlock() }; return _playlistShiftSeconds
    }
    private func setPlaylistShiftSeconds(_ value: Double) {
        shiftLock.lock(); _playlistShiftSeconds = value; shiftLock.unlock()
    }

    private let anchorShiftLock = NSLock()
    /// The source-to-item normalization each VOD segment's bytes were written with, by index: a frame's
    /// time in the segment file plus this is its source time. Reported by the producer as each segment
    /// is finalized (`HLSSegmentProducer.onSegmentWritten`); read for scrub thumbnails, which decode
    /// the file itself. Guarded by `anchorShiftLock`.
    private var carriedSecondsByIndex: [Int: Double] = [:]
    /// docs/segment-axis.md: the in-band clock's last reading, from which the published axis moves only
    /// when a reading differs (`noteInBandClock`). Guarded by `anchorShiftLock`.
    private var lastClockReading: (itemSeconds: Double, axis: Double)?
    /// AE#412: the index the most recent gate open belongs to and how far below its boundary it
    /// opened. A re-cut BLOCKS on it, so it is signalled through `gateOpenCondition`.
    private var lastGateOpen: (index: Int, backoffSeconds: Double)?
    private let gateOpenCondition = NSCondition()
    /// The index of the last gate open a re-cut can wait on (internal read for the superseded-producer tests).
    var gateOpenedIndex: Int? {
        gateOpenCondition.lock(); defer { gateOpenCondition.unlock() }
        return lastGateOpen?.index
    }
    /// Epoch of `producer`, mirrored under `anchorShiftLock` (audit SEG-104).
    private var installedProducerEpoch: UInt64?
    private let shiftLock = NSLock()
    private var _playlistShiftSeconds: Double = 0

    private var sourceVideoTbSeconds: Double = 1.0 / 1000.0

    /// Source bitrate in bps for HLS BANDWIDTH/AVERAGE-BANDWIDTH. 0 when libavformat can't
    /// compute it; callers fall back to an over-declared estimate to avoid CoreMediaErrorDomain -12318.
    private var sourceBitrate: Int64 = 0
    /// AE#783: the highest per-segment source bitrate the keyframe index measures, nil when it cannot.
    private var sourcePeakBitrate: Int64?

    /// Fires on each gate open (initial + restart) so AetherEngine keeps its shift in step
    /// for subtitle cue lookup.
    /// `(shiftSeconds, seamItemSeconds)`: the new shift, and the item-axis position from which it applies
    /// (this producer's planned first tfdt). Content below that position was muxed under the previous shift
    /// and can still be in AVPlayer's buffer, so the host records a seam rather than replacing the scalar (#260).
    var onPlaylistShiftChanged: (@Sendable (Double, Double) -> Void)?

    /// #240: whether a seek is in flight, which a scrub thumbnail's read waits out. Set by `AetherEngine`
    /// before `start()`; nil when the session is driven without one (`aetherctl`, tests).
    var seekInFlight: SeekInFlightSignal?

    /// Layer 3 step 5: how far on the source axis the subtitle consumers want a stream only the pump reads
    /// to have been read; nil while nobody asks. Read by every producer where it parks, which then reads
    /// on past its forward window to the segment that holds it. Set by `AetherEngine` before `start()`.
    var subtitleReadAheadThrough: (@Sendable () -> Double?)?

    /// Fires when AVKit scrub drives a producer restart (AetherEngine#38). `(true, playlistTime)`
    /// at restart-run start; `(false, nil)` when settled. `playlistTime` folds with
    /// `playlistShiftSeconds` onto the source-PTS `seekTarget`, and is a LOWER BOUND on where the
    /// picture will land (the restart aims at the segment containing the requested time).
    ///
    /// The falling edge is "the producer is now producing at the new index", NOT "AVPlayer rendered it".
    /// The engine no longer treats it as a landing; see `AetherEngine.setNativeScrubSeek`.
    var onSeekStateChanged: (@Sendable (Bool, Double?) -> Void)?

    /// Source stall/reconnect transitions from the main demuxer's `AVIOReader` (#85). Forwarded to
    /// `demuxer` at every install site (start + live/restart reopen); the side-audio demuxer stays unwired.
    var onNetworkPhaseChanged: (@Sendable (ReaderNetworkPhase) -> Void)?

    /// AVPlayer's rendered (playlist-axis) position, readable off the main actor. Wired by AetherEngine
    /// to a thread-safe mirror of the host clock. Used to re-anchor the producer on AVPlayer's REAL
    /// position when a VOD backpressure wedge breaks (#65).
    var currentPlaybackPositionProvider: (@Sendable () -> Double?)?

    /// Whether AVPlayer wants to play (`timeControlStatus != .paused`), readable off the main actor. Wired
    /// by AetherEngine to a thread-safe mirror and threaded onto every producer so the VOD backpressure
    /// wedge detector suspends while the consumer is paused (a paused player issues no forward fetch, so its
    /// frozen fetch target is not a wedge, issue #65 pause false-positive).
    var playIntentProvider: (@Sendable () -> Bool)?

    /// AE#520 round 2: how long the consumer can keep playing out of what it already holds, readable
    /// off the main actor. Wired by AetherEngine to a thread-safe mirror the telemetry sampler writes,
    /// and handed to the segment provider, whose outage close spends a depth: the segments it has not
    /// fetched yet are only half of one. nil on the software path and between item swaps.
    var consumerBufferedSecondsProvider: (@Sendable () -> Double?)?

    /// Whether AVPlayer has ever presented a frame this item (its `timeControlStatus` reached `.playing`
    /// at least once), readable off the main actor. Wired by AetherEngine to a thread-safe mirror and
    /// threaded onto every producer so the VOD backpressure wedge detector stays suspended through cold
    /// pre-roll (#35/#93 startup: a flat clock before the first frame is not a wedge).
    var hasStartedRenderingProvider: (@Sendable () -> Bool)?

    /// The requested-but-unlanded user seek target (AVPlayer/item clock axis), readable off the main
    /// actor; nil = none pending. Wired by AetherEngine to a thread-safe mirror of its recovery seek
    /// intent (#93 retest). A wedge re-anchor must aim the producer here, not at the frozen clock:
    /// after a hard zero-tolerance seek AVPlayer only requests media at the TARGET, so re-producing
    /// the frozen position serves segments nobody will ever fetch (and its window refill can evict
    /// the target's segments from retention).
    var recoverySeekTargetProvider: (@Sendable () -> Double?)?

    /// Deep copy of AVCodecParameters decoupled from the demuxer's lifetime. Raw pointers into
    /// AVStreams become use-after-free on live reopen (avformat_close_input frees them while the
    /// continuation producer still reads via saved configs). Freed after pump unwinds.
    final class OwnedCodecParameters: @unchecked Sendable {
        let ptr: UnsafeMutablePointer<AVCodecParameters>

        init?(copying src: UnsafePointer<AVCodecParameters>) {
            guard let copy = avcodec_parameters_alloc() else { return nil }
            guard avcodec_parameters_copy(copy, src) >= 0 else {
                var c: UnsafeMutablePointer<AVCodecParameters>? = copy
                avcodec_parameters_free(&c)
                return nil
            }
            self.ptr = copy
        }

        deinit {
            var p: UnsafeMutablePointer<AVCodecParameters>? = ptr
            avcodec_parameters_free(&p)
        }
    }

    private var ownedCodecParams: [OwnedCodecParameters] = []

    /// In-flight live reopen demuxer, registered before its blocking open so `stop()` can abort it
    /// (prevents orphan reconnect loops across channel zaps).
    var reopenDemuxer: Demuxer?
    /// The #79 / #169 restart's replacement demuxer, from before its open until the restart installs
    /// or drops it, so `stop()` can abort that open and the seek after it (audit SEG-3 follow-up).
    private var restartReopenDemuxer: Demuxer?
    /// Fires on live program-boundary rebase: `(newShiftSeconds, seamOutputSeconds)`. AetherEngine
    /// defers applying the shift until playback crosses `seamOutputSeconds` so the clock doesn't jump.
    var onPlaylistShiftRebased: (@Sendable (Double, Double) -> Void)?
    /// A live programme's video colour from the item time it starts at (`HLSSegmentProducer.onLiveVideoColour`).
    var onLiveVideoColour: (@Sendable (_ itemSeconds: Double, _ colour: ColorDescription) -> Void)?
    /// Fires when a longer finalized segment requires a new live playlist URL.
    var onLivePlaylistRenewal: (@Sendable () -> Void)?
    func renewedLivePlaylistURL(replacing url: URL) -> URL? {
        server?.renewedLivePlaylistURL(replacing: url)
    }
    /// Fires when no in-engine source reopen can continue the session.
    var onLiveSourceReset: (@Sendable () -> Void)?
    var onLiveSourceReplayExhausted: (@Sendable () -> Void)?
    /// A fresh source may change format; the owner ends the old recording before that seam.
    var onLiveSourceReopening: (@Sendable () -> Void)?
    /// AE#627: the first join read video for the whole keyframe wait and found no point the native
    /// route can open a segment on. Reopening joins the same bitstream, so the engine decides between
    /// the software path and telling the host (`escalateLiveReopenExhaustion`) instead. Unset, the
    /// session falls back to the ordinary reopen budget.
    var onLiveJoinWithoutEntryPoint: (@Sendable () -> Void)?
    /// AE#641: the live audio bridge decoded not one frame of the selected stream (index, bridge
    /// summary). Nothing inside the session can recover it: a producer rebuild hands the same decoder
    /// the same bytes, and the served media keeps an audio track that will never be filled.
    var onLiveAudioDecodesNothing: (@Sendable (Int32, String) -> Void)?
    /// #126: fires when a VOD pump dies on a read error having produced nothing (zero packets
    /// written, empty cache). The playlist exists but no segment will ever land, so AVPlayer
    /// would sit in waitingToPlay forever; the engine surfaces a fatal error instead.
    ///
    /// Never call this directly; go through `surfaceVODSourceFailure` so the sequential startup
    /// gate is released with it (#370 follow-up).
    /// #377: the third parameter classifies the failure. A source that is being metered is not a
    /// source that is gone, and the reader's `-1` cannot say which, so the kind is decided here
    /// and published rather than inferred from the code downstream.
    var onVODSourceFailed: (@Sendable (Int32, String, PlaybackErrorKind) -> Void)?
    var onVODVideoConfigurationChanged: (@Sendable (UInt64, String) -> Void)?
    private var vodVideoConfigurationMismatch: (epoch: UInt64, summary: String)?

    /// Retained because the first pump can finish before loadNative installs this session.
    var pendingVODVideoConfigurationMismatch: (epoch: UInt64, summary: String)? {
        restartLock.lock(); defer { restartLock.unlock() }
        guard let event = vodVideoConfigurationMismatch, producer?.epoch == event.epoch else { return nil }
        return event
    }

    func recordVODVideoConfigurationMismatch(_ prod: HLSSegmentProducer, summary: String) {
        restartLock.lock()
        guard !isLiveSession, producer === prod else { restartLock.unlock(); return }
        vodVideoConfigurationMismatch = (prod.epoch, summary)
        restartLock.unlock()
        onVODVideoConfigurationChanged?(prod.epoch, summary)
    }

    /// The one way a VOD session surfaces a terminal source failure (#370 follow-up).
    ///
    /// #370 released a held startup-playlist GET at the two surfaces its own trace ran through, but
    /// a sequential origin reaches three more: `.muxerFailed` revives into `requestRestart`, which a
    /// sequential origin refuses, and the AE#366 moov-prime exhaustion and AE#169 read-error
    /// exhaustion end on their own surfaces. Each of those can fire before the first duration is
    /// published (an E-AC-3 archive whose first segment carries no audio packet is the field shape),
    /// and the server thread then sat out the remaining ~30 s of a session that had already failed.
    /// Pairing the release with the surface makes that structural instead of a call site to remember.
    func surfaceVODSourceFailure(_ code: Int32, _ reason: String,
                                 kind: PlaybackErrorKind = .vodSourceFailed) {
        // AE#641: a silent bridge is reported the moment it is structural and again by the muxer arms
        // that follow it on the E-AC-3 route; the session learns it once.
        if kind == .audioBridgeProducedNoOutput {
            silentBridgeSurfaceLock.lock()
            let first = !silentBridgeFailureSurfaced
            silentBridgeFailureSurfaced = true
            silentBridgeSurfaceLock.unlock()
            guard first else { return }
        }
        provider?.abortSequentialStartupWait()
        onVODSourceFailed?(code, reason, kind)
    }
    private let silentBridgeSurfaceLock = NSLock()
    private var silentBridgeFailureSurfaced = false
    /// Session-long audio bridge for codecs illegal in fMP4, or the runs that make each segment of a
    /// seekable VOD session (`AudioSegmentRuns`). Engine-owned (not producer-owned) so the muxer's
    /// parameters and a single run's encoder survive producer restarts; `startSegment()` rebases a
    /// single run's PTS on each restart, and drops the segment runs.
    var audioBridge: (any AudioTranscodingBridge)?
    var segmentPlan: [Segment] = []
    /// AE#682: every indexed keyframe of a keyframe-aligned plan, on its axis; the I-frame timeline is
    /// thinned from these (`iFrameEntries`). Empty for every other plan.
    var planKeyframePts: [Int64] = []

    /// AE#408: true only while `segmentPlan` is the keyframe-aligned plan, whose boundaries are
    /// container index entries and therefore CLAIM to be random-access points. The producer re-aims
    /// below a boundary that breaks that claim; it must not do so for the uniform grid (which never
    /// claimed it) or a source-declared plan (which aims below its IRAP by design, AE#268).
    var planBoundariesClaimRandomAccess = false

    /// AE#561: the axis `segmentPlan`'s boundaries are stamped on, handed to every producer this
    /// session builds so its cutter gate compares a packet on the plan's own axis. Set together with
    /// `planBoundariesClaimRandomAccess`, because it is the same plan that makes it meaningful: only
    /// the keyframe-aligned plan's boundaries ARE index entries. `.decode` for every other plan,
    /// which is what the cutter compared before the axis existed.
    var planBoundaryAxis: PlanBoundaryAxis = .decode

    /// Guards subsystem refs + `sessionEpoch`. Never held across waits or network I/O so
    /// `stop()` on the main thread is never blocked behind a restart's 5 s waitForFinish.
    let restartLock = NSLock()

    /// AE#464: the host's audio presentation offset, in seconds, that `makeProducer` hands to every
    /// muxer it builds. A muxer's offset is fixed for its life, so setting this alone changes nothing
    /// that has already been cut; `AetherEngine.setAudioDelay` writes it as part of a reload, which is
    /// what actually replaces the segments and the item holding them.
    public var audioDelaySeconds: Double = 0

    /// Serializes restart requests among themselves. Held across waits (unlike `restartLock`);
    /// only other restarts contend on it.
    private let restartGate = NSLock()

    /// Coalesces burst seek restart requests (#35). Mutated only under `restartLock`.
    private var restartCoalescer = RestartCoalescer()

    /// #65 wedge re-anchor storm guard (under `restartLock`). If AVPlayer never resumes requesting even
    /// after we re-anchor the producer on its real position, the producer re-wedges at the same spot;
    /// cap consecutive re-anchors to the same position so we stop spinning restarts (the clock is already
    /// reconciled by the engine-seek deadline path, so the engine no longer lies even if we give up here).
    var consecutiveWedgeReanchors = 0
    var lastWedgeReanchorPosition = -Double.greatestFiniteMagnitude
    static let maxConsecutiveWedgeReanchors = 5
    /// How many pumps must have folded the index the consumer waits on before the wedge handler
    /// treats the gap as unrecoverable rather than re-anchoring into it again (#358). One fold can
    /// still be filled by a rebase; two is the recovery reproducing its own trigger.
    static let foldsProvingUnrecoverableGap = 2

    /// #99: bounded revive for a VOD pump that died with muxerFailed (under `restartLock`).
    /// performRestart rebuilds muxer AND re-arms the audio bridge, so transient causes heal;
    /// a persistent cause exhausts the cap instead of restart-storming.
    var muxerFailureReviveGate = MuxerFailureReviveGate(maxAttempts: 2)

    /// AE#169 round 2: bounded revive for a VOD pump that died on a MID-SESSION read error (under
    /// `restartLock`). #126 only surfaced the nothing-ever-produced case as fatal and assumed the
    /// scrub/wedge arms covered the rest; a tail request within the forward-wait window of the dead
    /// producer's front reached neither (rrgomes: seg719 miss x11 into -12889), so the exit gets
    /// its own event-driven arm. Same gate shape as #99.
    var readErrorReviveGate = MuxerFailureReviveGate(maxAttempts: 2)
    /// #377: a separate, larger budget for read errors caused by an origin REFUSING us rather than
    /// failing. Separate because the two must not spend each other: two attempts is right for a
    /// source that may be gone, and wrong for one that is merely refusing for a while, where each
    /// attempt is spaced by a growing backoff and is expected to succeed eventually.
    ///
    /// Round 6 made it a wall clock per refusal window rather than an attempt count per session.
    /// See `RefusingSourceReviveBudget` for why: the old figure was the emergent product of two
    /// constants that did not know about each other, and it was never reset.
    var rateLimitReviveGate = RefusingSourceReviveBudget()
    /// AE#792 part 2: revives spent on a credential refusal the host has since renewed. Each one
    /// answers a renewal, so the bound only stops a host whose fresh credentials keep being refused.
    var credentialReviveGate = MuxerFailureReviveGate(maxAttempts: 3)

    /// AE#169 round 2 (under `restartLock`): the demuxer's last read threw, so the next
    /// performRestart replaces it via the #79 fresh-demuxer path instead of seeking a connection
    /// that just failed (a sticky pb error would burn the revive gate without one fresh attempt).
    var mainDemuxerSuspectDead = false

    /// AE#222 (under `restartLock`): one real audio frame from this source, kept for the whole session so
    /// every muxer built from here on writes moov (with the packet-derived dec3/dac3/dmlp built from THIS
    /// frame) at init. Set only after a pump proved the source cuts its first segment before any audio packet
    /// arrives, which no probe can predict: movenc rejects an immediate moov for E-AC-3 regardless of
    /// extradata, so a pre-flight cannot tell a video-first interleave apart from a healthy source.
    var sessionAudioMoovPrimeFrame: [UInt8]?
    /// AE#366: a producer searched the whole source for a frame that can build the audio sample
    /// entry and found none. Structural (never set from a read failure), so the session stops paying
    /// for the search on every later revive attempt.
    var sessionAudioMoovPrimeUnobtainable = false

    /// AE#222 (under `restartLock`): bounded rebuild for a pump that deferred its first cut. One attempt is
    /// enough by construction (the prime is captured before the restart and reused for the session's whole
    /// life); the gate exists so a source that somehow defers again cannot restart-storm.
    var audioSampleEntryPrimeGate = MuxerFailureReviveGate(maxAttempts: 1)

    /// AE#169 round 3 (under `restartLock`): bounded re-anchor for a VOD pump whose restart
    /// scan-forward gate starved to EOF (no runtime keyframe at/after the targeted plan boundary,
    /// the unproducible tail segment). Same gate shape as #99.
    var gateStarvationReviveGate = MuxerFailureReviveGate(maxAttempts: 2)

    /// #93 residual: a stalled AVPlayer sometimes never resumes REQUESTING after a wedge re-anchor
    /// (device: plain playback, one -15628 errorLog, then zero segment GETs while parked in
    /// waitingToMinimizeStalls forever, item never fails). The served playlist alone cannot reach
    /// it, so after this grace window with no fetch and intact play intent the engine asks the
    /// host to re-engage the consumer (zero-tolerance nudge seek, the same effect a manual
    /// back-out had). Fired at most once per re-anchor attempt; the re-anchor cap bounds the storm.
    var onConsumerReengageNeeded: (@Sendable (Double) -> Void)?
    static let consumerReengageGraceSeconds: TimeInterval = 6.0

    /// Locked snapshot/compare of the session epoch so detached watchdogs can verify the session
    /// they were armed for is still the live one (stop() bumps the epoch).
    func sessionEpochSnapshot() -> UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        return sessionEpoch
    }
    func isSessionEpochCurrent(_ epoch: UInt64) -> Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return sessionEpoch == epoch
    }

    /// Bumped by `stop()` under `restartLock`. Restarts re-validate before installing the new
    /// producer; a mid-restart stop() wins and the restart unwinds.
    private var sessionEpoch: UInt64 = 0

    /// Fires once per session on first HDR10+ T.35 detection so AetherEngine can upgrade
    /// `videoFormat` from `.hdr10` to `.hdr10Plus`. Debounced across producer restarts.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?
    private var hasReportedHDR10Plus = false
    private let hdr10PlusLock = NSLock()

    /// Target segment duration (4 s). Apple spec recommends 6 s; 4 s cuts ~370 ms first-segment
    /// latency on a 24 fps 1440p LAN source and stays within the spec's 2-6 s range.
    static let targetSegmentDuration: Double = 4.0

    /// Cut target of the VOD keyframe plan (2 s). A native seek is served the whole segment holding its
    /// target before AVPlayer sees a byte, and AVPlayer buffers about one segment before it starts, so the
    /// segment length is the seek latency: on a UHD remux a 4 s cut measured 0.62 s to serve and 1.46 s
    /// from seek to motion on the device. Live and the uniform-stride fallback keep `targetSegmentDuration`:
    /// live window sizing is tuned around it, and a grid finer than an unmeasured GOP advertises segments
    /// no keyframe opens (#358). A GOP longer than this still cuts once per GOP.
    static let vodKeyframeSegmentTarget: Double = 2.0

    /// `LoadOptions.forwardBufferSegments` and the cache's backward window count `targetSegmentDuration`
    /// segments. A VOD session holds this many of its own per counted one, so both keep their depth in
    /// seconds.
    static let vodSegmentsPerCountedSegment = Int((targetSegmentDuration / vodKeyframeSegmentTarget).rounded())

    /// The session's forward window in its own segments: the clamped request, scaled for VOD.
    static func sessionForwardWindow(requested: Int?, isLive: Bool) -> Int {
        let counted = clampedForwardWindow(requested)
        guard !isLive else { return counted }
        let (scaled, overflow) = counted.multipliedReportingOverflow(by: vodSegmentsPerCountedSegment)
        return overflow ? counted : scaled
    }

    /// Live cut target under `LiveJoinProfile.fastZap` (AE#195): cut at every keyframe past 0.5 s, so
    /// segments quantize to the source GOP and the served TARGETDURATION (whose 3 x holdback gates the
    /// first live manifest, AE#189) is driven by `ceil(max EXTINF)` instead of the
    /// `ceil(1.5 x cut target)` floor (which collapses to 1 at this value).
    static let fastZapLiveCutTargetSeconds: Double = 0.5

    /// Resolve a host `LiveJoinProfile` to the live segment cut target.
    static func liveCutTargetSeconds(for profile: LiveJoinProfile) -> Double {
        switch profile {
        case .standard: return targetSegmentDuration
        case .fastZap: return fastZapLiveCutTargetSeconds
        }
    }

    /// Cue-prewarm seek deadline. MKV Cues resolve in under 1 s; a missing/out-of-bounds index
    /// degrades into a multi-GB linear scan. Beyond this, abort and build a uniform-stride plan.
    static let cuePrewarmTimeout: TimeInterval = 10.0

    struct SessionCacheBudgetResolution: Sendable, Equatable {
        let requestedBytes: Int?
        let volumeSafetyLimitBytes: Int
        let baseEffectiveBytes: Int

        /// What the cache and the producer park enforce. 0 reads as "no byte bound" in
        /// `SegmentCache`, `PrefetchDiskBudget` and the window sizing, so an explicit request never
        /// hands them 0: the playback window stays resident, nothing past it does.
        var enforcedBytes: Int { requestedBytes == nil ? baseEffectiveBytes : max(1, baseEffectiveBytes) }
    }

    /// Resolve a caller-exact session budget without weakening the existing tmp-volume guard.
    /// nil keeps the historical automatic policy. Unknown capacity stays conservatively bounded
    /// at 2 GiB even for an explicit aggressive-prefetch request.
    static func resolveSessionCacheBudget(
        requestedBytes: Int?,
        volumeAvailableBytes: Int64?,
        capRelaxed: Bool = false
    ) -> SessionCacheBudgetResolution {
        let conservativeCap = 2 << 30
        let quarterOfFree = volumeAvailableBytes.map { available -> Int in
            let quarter = max(Int64(0), available / 4)
            return Int(min(quarter, Int64(Int.max)))
        }
        let safetyLimit = quarterOfFree ?? conservativeCap

        if let requestedBytes {
            let normalized = max(0, requestedBytes)
            return SessionCacheBudgetResolution(
                requestedBytes: normalized,
                volumeSafetyLimitBytes: safetyLimit,
                baseEffectiveBytes: min(normalized, safetyLimit)
            )
        }

        let effective = capRelaxed
            ? safetyLimit
            : min(conservativeCap, safetyLimit)
        return SessionCacheBudgetResolution(
            requestedBytes: nil,
            volumeSafetyLimitBytes: safetyLimit,
            baseEffectiveBytes: effective
        )
    }

    /// SegmentCache retention budget (#93 / Sodalite#32): capped at 2 GiB and clamped to a quarter
    /// of the tmp volume's available capacity, so a nearly-full device never trades playback
    /// headroom for seek history.
    ///
    /// Live used to pass 0 on the reasoning that the sliding playlist had already dropped
    /// everything behind the window, so retention would serve nothing. That had it backwards. The
    /// playlist is the LOOSER bound (`windowSegmentCount`, e.g. 300 segments for a 600 s DVR window
    /// at a 2 s cadence); `pruneOutsideWindow` is the tighter one, and with a 0 budget it takes the
    /// hard-window branch and cuts at `currentTargetIndex - backwardWindow`, i.e. 20 segments. A
    /// live session therefore retained ~42 s no matter what `dvrWindowSeconds` promised, while the
    /// playlist and `liveSeekableRange` advertised the full window: a rewind past ~42 s asked for a
    /// segment the cache had deleted, and live has no `restartHandler` to re-produce it. The budget
    /// is exactly the mechanism that keeps that history resident, so live gets it too.
    ///
    /// `capRelaxed` (#207) drops the 2 GiB default for a host that explicitly asked to pre-buffer more
    /// than the historical window could hold; the quarter-of-free-space clamp, which is what actually
    /// protects the volume, always applies. Unknown capacity keeps the conservative cap either way.
    static func sessionRetentionBudgetBytes(volumeAvailableBytes: Int64?, capRelaxed: Bool = false) -> Int {
        resolveSessionCacheBudget(
            requestedBytes: nil,
            volumeAvailableBytes: volumeAvailableBytes,
            capRelaxed: capRelaxed
        ).baseEffectiveBytes
    }

    /// Largest forward window the default 2 GiB retention budget covers by construction
    /// (150 segments x ~10 MB for 4K HEVC ~ 1.5 GB), i.e. the old `clampedForwardWindow` ceiling.
    static let defaultRetentionCapWindowCeiling = 150

    /// #207: a window past `defaultRetentionCapWindowCeiling` is an explicit host opt-in into a
    /// whole-source prefetch, so the budget follows it up (see `sessionRetentionBudgetBytes`).
    static func retentionCapRelaxed(forwardWindowSegments: Int) -> Bool {
        forwardWindowSegments > defaultRetentionCapWindowCeiling
    }

    // MARK: - Measurement spike: sliding-window prototype (superseded)
    //
    // Sliding MEDIA-SEQUENCE is now unconditional for live (see `LiveWindowSizing`).
    // The 2026-06-07 macOS spike (_liveSlidingPrototype flag, h264-ts-sample.ts, 300 s):
    //   - Baseline (append-only EVENT): phys flat after 90 s (~7088 MB); resident flat ~40 MB.
    //   - Sliding prototype: phys flat (~8311 MB); resident declining (-0.83 MB/min, eviction working)
    //     but AVPlayer STALLED at 81 s (lost playlist window when segments fell off the back).
    // Root cause of stall: EVENT-vs-removal contradiction + uncoordinated MEDIA-SEQUENCE slide.
    // Fix: `.live` playlist type + `minSafeSegments` floor (keeps AVPlayer's live-edge buffer
    // inside the window). macOS phys_footprint is not representative of tvOS jetsam pressure
    // (~500-800 MB budget vs 7-8 GB on macOS); device-level tvOS measurement still open.

    public init(
        url: URL,
        sourceHTTPHeaders: [String: String] = [:],
        dvModeAvailable: Bool = true,
        displaySupportsHDR: Bool = true,
        keepDvh1TagWithoutDV: Bool = false,
        forceDolbyVisionOnNonDVDisplay: Bool = false,
        dolbyVisionHandling: DolbyVisionHandling = .automatic,
        dolbyVisionRPUProfile: Int? = nil,
        matchContentEnabled: Bool = true,
        panelIsInHDRMode: Bool = false,
        audioSourceStreamIndexOverride: Int32? = nil,
        undecodableAudioStreamIndices: Set<Int32> = [],
        audioBridgeMode: AudioBridgeMode = .surroundCompat,
        objectAudioRendering: ObjectAudioRendering = .off,
        objectDialogueGain: Float = 0,
        stereoPresentation: StereoPresentation = .automatic,
        stereoOnAnySystem: Bool = false,
        isLiveSession: Bool = false,
        dvrWindowSeconds: Double? = nil,
        liveJoinProfile: LiveJoinProfile = .standard,
        sourceOpenPolicy: SourceOpenPolicy = .init(),
        diagnosticContext: SourceNetworkDiagnostics.Context? = nil,
        liveStartupGraceSeconds: TimeInterval? = nil,
        liveStartupSingleSegmentMinimumSeconds: TimeInterval? = nil,
        liveEdgeCushionSeconds: Double? = nil,
        liveCutTargetSeconds: Double? = nil,
        blockingReloadOverride: Bool? = nil,
        liveCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveClosedCadenceObservation: (@Sendable () -> Double?)? = nil,
        liveUpstreamSegmentDurationObservation: (@Sendable () -> Double?)? = nil,
        liveJoinBacklogObservation: (@Sendable () -> Double?)? = nil,
        liveJoinSpentObservation: (@Sendable () -> Bool?)? = nil,
        upstreamSelfReportedTargetDuration: Double? = nil,
        preopenedDemuxer: Demuxer? = nil,
        sourceReopenableByURL: Bool = true,
        customSourceReopenFactory: CustomSourceReopenFactory? = nil,
        companionAudioReader: IOReader? = nil,
        probesize: Int64? = nil,
        maxAnalyzeDuration: Int64? = nil,
        sequentialOrigin: Bool = false,
        heldSourceConnection: Bool = false,
        declaredDurationSeconds: Double? = nil,
        forwardBufferSegments: Int? = nil,
        sessionCacheByteBudget: Int? = nil
    ) {
        self.sourceURL = url
        self.requestHeaders = RequestHeaderStore(sourceHTTPHeaders)
        self.sequentialOrigin = sequentialOrigin
        self.heldSourceConnection = heldSourceConnection
        self.declaredDurationSeconds = declaredDurationSeconds
        // Caller-bounded find_stream_info budget (#68); nil keeps the .playback default. Applied only to the
        // fallback open / live reopen here; the happy path reuses the already-budgeted preopenedDemuxer.
        // #377: the held transport is carried too. It is chosen at open time, so a reopen that leaves
        // it out puts the session silently back on ranged requests against the one kind of origin the
        // host turned it on for, and the flag reads as having stopped working half way through.
        self.openProfile = DemuxerOpenProfile.playback.withProbeBudget(
            probesize: probesize, maxAnalyzeDuration: maxAnalyzeDuration)
            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds)
            .withHeldSourceConnection(heldSourceConnection)
            .withSourceOpenPolicy(sourceOpenPolicy)
            .withDiagnosticContext(diagnosticContext)
        self.dvModeAvailable = dvModeAvailable
        self.displaySupportsHDR = displaySupportsHDR
        self.keepDvh1TagWithoutDV = keepDvh1TagWithoutDV
        self.forceDolbyVisionOnNonDVDisplay = forceDolbyVisionOnNonDVDisplay
        self.dolbyVisionHandling = dolbyVisionHandling
        self.dolbyVisionRPUProfile = dolbyVisionRPUProfile
        self.matchContentEnabled = matchContentEnabled
        self.panelIsInHDRMode = panelIsInHDRMode
        self.audioSourceStreamIndexOverride = audioSourceStreamIndexOverride
        self.undecodableAudioStreamIndices = undecodableAudioStreamIndices
        self.audioBridgeMode = audioBridgeMode
        self.objectAudioRendering = objectAudioRendering
        self.objectDialogueGain = objectDialogueGain
        self.stereoPresentation = stereoPresentation
        self.stereoOnAnySystem = stereoOnAnySystem
        self.isLiveSession = isLiveSession
        self.dvrWindowSeconds = dvrWindowSeconds
        self.liveJoinProfile = liveJoinProfile
        self.liveStartupGraceSeconds = liveStartupGraceSeconds
        self.liveStartupSingleSegmentMinimumSeconds = liveStartupSingleSegmentMinimumSeconds
        self.liveEdgeCushionSeconds = LiveEdgePolicy.edgeCushion(liveEdgeCushionSeconds)
        // An explicit cut target keeps precedence for direct callers. Otherwise resolve the profile.
        let resolvedLiveCutTarget = liveCutTargetSeconds
            ?? Self.liveCutTargetSeconds(for: liveJoinProfile)
        self.liveCutTargetSeconds = resolvedLiveCutTarget
        self.blockingReloadOverride = blockingReloadOverride
        // Trust OBSERVED arrival cadence, not the upstream's self-reported TARGETDURATION, for blocking-reload
        // eligibility and the TARGETDURATION floor (-15410, AetherEngine#167). Built only for live ingest
        // sources that expose a cadence observation; URL live and VOD leave it nil and fall back to the
        // signal-less default (blocking-reload on, server's own 1.5x-cut-target floor). AE#447: the advert
        // is passed for the seal log, it no longer seeds the floor.
        self.liveCadencePolicy = liveCadenceObservation.map { observe in
            LiveCadencePolicy(
                observe: observe,
                cutTargetSeconds: resolvedLiveCutTarget,
                observeSealEvidence: {
                    LiveCadenceEvidence(
                        closedCadenceSeconds: liveClosedCadenceObservation?(),
                        servedSegmentDurationSeconds: liveUpstreamSegmentDurationObservation?(),
                        joinBacklogSeconds: liveJoinBacklogObservation?(),
                        joinIsSpent: liveJoinSpentObservation?()
                    )
                },
                selfReportedTargetDurationSeconds: upstreamSelfReportedTargetDuration
            )
        }
        self.preopenedDemuxer = preopenedDemuxer
        self.sourceReopenableByURL = sourceReopenableByURL
        self.customSourceReopenFactory = customSourceReopenFactory
        self.companionAudioReader = companionAudioReader
        self.forwardWindowSegments = Self.sessionForwardWindow(requested: forwardBufferSegments,
                                                               isLive: isLiveSession)
        self.requestedSessionCacheBudgetBytes = sessionCacheByteBudget.map { max(0, $0) }
    }

    /// Session forward-buffer window in segments. Drives BOTH the producer's race-ahead
    /// (`HLSSegmentProducer.bufferAheadSegments`) and the cache's forward window
    /// (`SegmentCache.forwardWindow`); the two MUST stay identical (a drift is exactly what stalls
    /// AVPlayer, see `SegmentCache`). From `LoadOptions.forwardBufferSegments`; nil -> historical 10.
    let forwardWindowSegments: Int

    /// Session retention budget resolved in `start()`; also bounds the producer's race-ahead on disk
    /// (#207, see `PrefetchDiskBudget`). Live resolves the same budget, so the DVR history the
    /// playlist advertises stays resident; the producer-side prefetch park it also feeds is
    /// VOD-only (`advanceMuxer`), so live cannot park on it.
    private var retentionBudgetBytes: Int = 0
    private let requestedSessionCacheBudgetBytes: Int?
    private var sessionCacheVolumeSafetyLimitBytes: Int?
    /// The clamped request the status reports; `retentionBudgetBytes` is what is enforced.
    private var sessionCacheBaseEffectiveBytes: Int = 0

    /// Lifecycle snapshots, including async close completion, are delivered here. The host may
    /// sample `sessionCacheStatus()` for current bytes; this callback is primarily for cleanup.
    public var onSessionCacheStatusChanged: (@Sendable (SessionCacheStatus) -> Void)?
    /// #687: this session's entry in the process-wide ledger, released on `stop()`.
    private var retentionClaim: RetentionClaims.Claim?

    /// Clamp for `forwardWindowSegments`: below 4 the window would undercut AVPlayer's own ~5-7-segment
    /// prefetch and starve it (see `LiveWindowSizing.minSafeSegments`). The 2700 ceiling (~3 h at 4 s
    /// segments) is a sanity bound against accidental values, not a cost bound: it covers a whole
    /// feature film, so a host's "buffer without limit" option can pass `Int.max` (#207). The disk cost
    /// is bounded in bytes rather than segments, by the session retention budget the producer parks on
    /// (`PrefetchDiskBudget`, `sessionRetentionBudgetBytes`). nil keeps the historical default of 10.
    static func clampedForwardWindow(_ requested: Int?) -> Int {
        min(max(requested ?? 10, 4), 2700)
    }

    /// When true, `start()` skips the VOD duration guard / cue prewarm / precomputed plan and
    /// uses the forward-only live cut mode (producer cuts at each IDR past the duration target).
    let isLiveSession: Bool

    /// Controls whether the first live manifest may take the bounded shallow-window path.
    private let liveJoinProfile: LiveJoinProfile
    private let liveStartupGraceSeconds: TimeInterval?
    private let liveStartupSingleSegmentMinimumSeconds: TimeInterval?
    /// `LoadOptions.liveEdgeCushionSeconds`, validated.
    private let liveEdgeCushionSeconds: Double?

    /// Live segment cut target for this session, resolved from the host's `LiveJoinProfile` (AE#195).
    /// Drives the producer's keyframe cut, `LiveWindowSizing`, and (via the served TARGETDURATION floor)
    /// the AE#189 startup-cushion depth. VOD ignores it (cuts come from the precomputed plan).
    let liveCutTargetSeconds: Double

    /// False for IOReader-backed sources (`aether-custom://source` placeholder); `handlePumpFinished`
    /// surfaces loss via `onLiveSourceReset` immediately instead of burning 6 reopen attempts.
    let sourceReopenableByURL: Bool

    /// #199: vends a fresh reader (plus FFmpeg format hint) for an engine-created ingest source, so a
    /// live pump exit reopens in-session instead of delegating to host retune. Called once per reopen
    /// attempt; each vended reader is owned by this session (closed on replacement and on stop). nil for
    /// URL sources and host-provided custom readers.
    public typealias CustomSourceReopenFactory = @Sendable () -> (reader: IOReader, formatHint: String?)?
    let customSourceReopenFactory: CustomSourceReopenFactory?

    /// #199: the reader vended by `customSourceReopenFactory` that the CURRENT demuxer reads from.
    /// Guarded by `restartLock`. The original load's reader stays engine-owned (AetherEngine closes it
    /// in stopInternal); only factory-vended replacements are owned here.
    var reopenCustomReader: IOReader?

    /// Demuxed audio rendition reader for live HLS ingest. When the main demuxer finds no audio and
    /// this is non-nil, `start()` opens `sideAudioDemuxer` over it. Engine owns the side demuxer, not
    /// this reader (owned by the host's main reader). nil for muxed-audio sessions.
    private let companionAudioReader: IOReader?

    /// Host override for LL-HLS blocking-reload (`LoadOptions.liveBlockingReload`); nil = auto (#167).
    private let blockingReloadOverride: Bool?

    /// Observed-cadence policy driving blocking-reload eligibility and the TARGETDURATION floor for live
    /// ingest sources; nil for URL live and VOD (#167).
    private let liveCadencePolicy: LiveCadencePolicy?

    /// DVR window in seconds; nil = live-only (window still bounded to `liveOnlyFloorSeconds`).
    private let dvrWindowSeconds: Double?

    /// Bridge encoder for codecs illegal in fMP4 (TrueHD, DTS, DTS-HD MA, MP3, Opus,
    /// EAC3 from MKV without dec3 extradata).
    let audioBridgeMode: AudioBridgeMode

    /// TrueHD Atmos and DTS:X delivery (#731, see `ObjectAudioRendering`); consulted before `audioBridgeMode`.
    let objectAudioRendering: ObjectAudioRendering
    /// `LoadOptions.objectDialogueGain`, in dB.
    let objectDialogueGain: Float

    /// Pre-opened demuxer reused by `start()` to skip `avformat_find_stream_info` (~1-3 s on slow CDN).
    /// Consumed in `start()`; unconsumed instances are closed by `stop()`.
    private var preopenedDemuxer: Demuxer?

    /// Open profile carrying the caller-bounded probe budget (#68) for the fallback open and live reopen;
    /// `.playback` unless the caller set `LoadOptions.probesize` / `maxAnalyzeDuration`. Read in the
    /// `+LiveReopen` extension, so it cannot be file-private.
    let openProfile: DemuxerOpenProfile
    /// #377: opt-in held source transport, carried onto every open this session makes itself.
    let heldSourceConnection: Bool

    /// The profile the VOD scrub restart opens its replacement demuxer with. Bounded
    /// find_stream_info budget, and the same SOURCE declarations as the first open: a ranged reopen
    /// would splice fabricated-position bytes into a sequential pump, and one that dropped the held
    /// transport would put a session the host asked to hold a connection back on ranged requests
    /// against the origin that punishes them, half way through and with nothing saying so.
    var restartReopenProfile: DemuxerOpenProfile {
        DemuxerOpenProfile.restartReopen
            .withSourceOpenPolicy(openProfile.sourceOpenPolicy)
            .withDiagnosticContext(openProfile.diagnosticContext)
            .withSequentialOrigin(sequentialOrigin, declaredDuration: declaredDurationSeconds)
            .withHeldSourceConnection(heldSourceConnection)
            .withRequestHeaders(requestHeaders)
    }

    /// `LoadOptions.sequentialOrigin` for this session. Gates the VOD readError revive
    /// (`+LiveReopen`): a revive's fresh demuxer can only reopen from byte 0 and then fails its
    /// anchor seek on the non-seekable pb, burning a connection slot on origins that are typically
    /// connection-capped, so the session surfaces `onVODSourceFailed` directly instead.
    let sequentialOrigin: Bool

    /// `LoadOptions.declaredDurationSeconds`, threaded into every fresh-demuxer profile this
    /// session builds (wedge restart) so a reopened demuxer reports the same trusted duration.
    let declaredDurationSeconds: Double?

    /// Every site that would set the producer down somewhere other than byte 0 asks this first:
    /// the readError revive (`+LiveReopen`), the restart coalescer (`requestRestart`), and the
    /// resume anchor for the first producer. A sequential origin answers only from byte 0, and
    /// the demuxer seek that would move the cursor fails silently on a non-seekable pb, so a
    /// reposition does not fail loudly, it mislabels content. Live sessions are untouched: their
    /// reopen path re-requests the feed by URL and never seeks.
    var sequentialOriginPinsProducerToZero: Bool { sequentialOrigin && !isLiveSession }


    // MARK: - Public API

    /// AE#246: map a failed fallback open onto the error the caller sees.
    ///
    /// The fallback open runs when the load-time probe did not hand over a demuxer, which includes
    /// the case where that probe failed for a transient reason. It is then the FIRST open to read
    /// the source body, so it is the one that produces the reader's HLS classification. Interpolating
    /// that typed error into `openFailed(reason:)` erased its domain and made a reroutable remote-HLS
    /// source terminal; the classification is rethrown verbatim so `load()` can still reach the AE#154
    /// reroute (`hlsPlaylistOnVODPath`) or the live-path classification (`hlsPlaylistOnRawLivePath`,
    /// which AE#363 routes onto the live ingest for a URL source and rejects for a custom reader).
    /// A refused source (`httpStatus`) keeps its status the same way, so `load()` can publish it as
    /// `PlaybackErrorKind.sourceRefused` instead of a wrapped "invalid data", and a refused handshake
    /// (`transportSecurityFailed`, AE#495) keeps its `NSURLError` code so it can publish as
    /// `sourceCertificateRejected` rather than as a source that is merely unreadable. Every other
    /// failure keeps the historical wrapped shape.
    static func openFailure(from error: Error) -> Error {
        if let readerError = error as? AVIOReaderError {
            switch readerError {
            case .hlsPlaylistOnVODPath, .hlsPlaylistOnRawLivePath, .httpStatus,
                 .transportSecurityFailed:
                return readerError
            default:
                break
            }
        }
        return HLSVideoEngineError.openFailed(reason: "\(error)")
    }

    public func start() throws -> URL {
        try prepare()
        return try serve(panelIsInHDRMode: panelIsInHDRMode)
    }

    /// What `prepare()` built and `serve(panelIsInHDRMode:)` needs (AE#348).
    private struct PreparedServe {
        let codecpar: UnsafeMutablePointer<AVCodecParameters>
        let demuxer: Demuxer
        let plan: [Segment]
        let segmentCache: SegmentCache
        let server: HLSLocalServer
        let provider: VideoSegmentProvider
        let frameRate: Double?
        let servedAudioLanguage: String?
        let servedAudioIsAtmosStreamCopy: Bool
        let videoRange: HLSVideoRange
        let dvVariant: DVVariant
        let convertP7ToProfile81: Bool
    }
    private var preparedServe: PreparedServe?

    /// The panel-independent half of `start()`; `serve(panelIsInHDRMode:)` finishes it.
    public func prepare() throws {
        guard demuxer == nil else { throw HLSVideoEngineError.alreadyStarted }

        // 1. Open the source; reuse the pre-opened demuxer when available (saves ~1-3 s on slow CDN).
        let dem: Demuxer
        if let preopened = preopenedDemuxer {
            dem = preopened
            preopenedDemuxer = nil
        } else {
            dem = Demuxer()
            do {
                try dem.open(url: sourceURL, extraHeaders: sourceHTTPHeaders,
                             profile: openProfile.withRequestHeaders(requestHeaders), isLive: isLiveSession)
            } catch {
                throw Self.openFailure(from: error)
            }
        }
        demuxer = dem
        openedSourceIsSeekable = dem.isSourceSeekable
        dem.onNetworkPhaseChanged = onNetworkPhaseChanged   // surface source stall/reconnect to playbackPhase (#85)
        dem.playIntentProvider = playIntentProvider   // a held connection ends on a pause, not on a parked producer

        let videoIndex = dem.videoStreamIndex
        guard videoIndex >= 0, let videoStream = dem.stream(at: videoIndex) else {
            throw HLSVideoEngineError.noVideoStream
        }
        let sourceCodecpar = videoStream.pointee.codecpar!
        let isHEVC = sourceCodecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        let isH264 = sourceCodecpar.pointee.codec_id == AV_CODEC_ID_H264
        let isAV1 = sourceCodecpar.pointee.codec_id == AV_CODEC_ID_AV1

        // Log codecpar for AVPlayer -11821 triage: interlaced field_order and malformed Annex-B
        // extradata are the two candidates when channels mux cleanly but VT chokes post readyToPlay.
        let extraSize = Int(sourceCodecpar.pointee.extradata_size)
        var extraHead = "none"
        if extraSize > 0, let extra = sourceCodecpar.pointee.extradata {
            let n = min(extraSize, 8)
            extraHead = (0..<n).map { String(format: "%02x", extra[$0]) }.joined()
        }
        EngineLog.emit(
            "[HLSVideoEngine] video codecpar: codec=\(sourceCodecpar.pointee.codec_id.rawValue) "
            + "\(sourceCodecpar.pointee.width)x\(sourceCodecpar.pointee.height) "
            + "profile=\(sourceCodecpar.pointee.profile) level=\(sourceCodecpar.pointee.level) "
            + "fieldOrder=\(sourceCodecpar.pointee.field_order.rawValue) "
            + "extradata=\(extraSize)B head=\(extraHead)",
            category: .session
        )

        // AVPlayer decodes HEVC, H.264 and, where VideoToolbox has it, AV1 (no current Apple TV chip). Everything
        // else (VP9, whose `vp09` CODECS AVPlayer's HLS parser rejects, MPEG-2, VC-1, AV1 in software) plays in
        // the software overlay, whatever its codec.
        let av1OK = isAV1 && VTCapabilityProbe.av1Available
        guard overlayDecodesVideo || isHEVC || isH264 || av1OK else {
            throw HLSVideoEngineError.unsupportedCodec(rawCodecID: sourceCodecpar.pointee.codec_id.rawValue)
        }

        let videoTimeBase = videoStream.pointee.time_base
        if videoTimeBase.num > 0, videoTimeBase.den > 0 {
            sourceVideoTbSeconds = Double(videoTimeBase.num) / Double(videoTimeBase.den)
        }
        // AE#270: the source PTS the container's own timeline starts at. `duration` is measured from here,
        // so this is the PTS that maps to display-0 for the host (0 for an MP4, 1.4 s for anything ffmpeg
        // wrote as MPEG-TS, hours for VOD carved out of a broadcast stream). A negative start time is an
        // encoder-side reorder artifact rather than an origin, so it clamps to 0.
        let formatStart = dem.formatStartTime
        sourceStartSeconds = formatStart == Int64.min ? 0 : max(0, Double(formatStart) / Double(AV_TIME_BASE))
        let durationSeconds = dem.duration
        var plan: [Segment]
        var keyframeBytePositions: [Int64: Int64] = [:]
        if isLiveSession {
            sourceBitrate = dem.bitRate
            self.firstKeyframePts = 0
            self.firstKeyframeSeconds = 0
            plan = []
            EngineLog.emit(
                "[HLSVideoEngine] LIVE session: skipping duration guard / prewarm / plan "
                + "(dem.duration=\(String(format: "%.1f", durationSeconds))s, producer cuts segments forward)",
                category: .session
            )
        } else {
            guard durationSeconds > 0 else {
                throw HLSVideoEngineError.zeroDuration
            }
            sourceBitrate = dem.bitRate

            // #409: settle the composition-offset repair while the demuxer still stands at the head.
            // It reads a short sample and holds those packets, so nothing is consumed; doing it later
            // would sample wherever the prewarm left the source, and hand the producer a head that is
            // six seconds into the file. The segment plan below needs the verdict either way, because
            // a repaired stream and the container's own index have to describe one ladder.
            dem.decideCompositionOffsetRepair()

            // 2. Prewarm MKV Cues so libavformat's keyframe index is populated (1-2 byte-range reads).
            //    Bounded: a missing/out-of-bounds Cues index degrades into a multi-GB linear scan;
            //    abort past the deadline and fall back to the uniform-stride plan.
            //    #268: a segmented time-seekable source (HLS VOD ingest) has no index libavformat could
            //    load, and each reposition refetches a segment, so prewarming would buy the same
            //    uniform-stride plan for the price of two segment downloads at every session start.
            if !Self.cuePrewarmMayRun(dem) {
                EngineLog.emit(
                    !dem.loadsIndexOnFirstSeek
                        ? "[HLSVideoEngine] cue prewarm: skipped, \(dem.containerFormatName ?? "this container") has no index a seek loads"
                        : dem.timeSeekableReader != nil
                        ? "[HLSVideoEngine] cue prewarm: skipped for a segmented source (no index to load, every reposition refetches a segment)"
                        : "[HLSVideoEngine] cue prewarm: skipped for a forward-only source (the seek would be a linear read, "
                          + "and the prefix it consumes is the producer's only pass)"
                )
            } else {
                let prewarmStart = DispatchTime.now()
                let prewarmOK = dem.seekBounded(to: durationSeconds * 0.5, timeout: Self.cuePrewarmTimeout)
                let prewarmMs = Double(DispatchTime.now().uptimeNanoseconds - prewarmStart.uptimeNanoseconds) / 1_000_000
                if prewarmOK {
                    EngineLog.emit("[HLSVideoEngine] cue prewarm: seek to \(String(format: "%.1f", durationSeconds * 0.5))s took \(String(format: "%.1f", prewarmMs))ms")
                } else {
                    EngineLog.emit("[HLSVideoEngine] cue prewarm: capped at \(String(format: "%.1f", prewarmMs))ms (no usable Cues index, index points past EOF or is absent); building plan from whatever keyframes were scanned")
                }
            }

            // 3. Build the segment plan. Uses the same cut algorithm as libavformat's hls muxer
            //    (first IDR at-or-after `(segIdx+1) * hls_time`); falls back to uniform stride
            //    if the index has < 2 entries (restart machinery handles any plan/muxer drift).
            let keyframeEntries = dem.indexedKeyframeEntries(streamIndex: videoIndex)
            let keyframes = keyframeEntries.map(\.pts)
            let indexTrustworthy = Self.keyframeIndexIsTrustworthy(
                keyframes: keyframes,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds
            )
            // AE#268: a segmented source declares its own random-access points. Prefer them over both
            // builders below: the index is sparse on MPEG-TS, and the uniform grid advertises
            // boundaries no keyframe sits on (a 4 s grid over a 10 s GOP is producible on one boundary
            // in five; a restart at any other one opens its gate a GOP late and skews every index
            // mapping until AVPlayer starves).
            let declaredSegmentStarts = dem.timeSeekableReader?.segmentStartTimesSeconds ?? []
            let segmentedAnchorPts: Int64 = keyframes.sorted().first
                ?? (videoStream.pointee.start_time != Int64.min
                    ? max(0, videoStream.pointee.start_time) : 0)
            let segmentedPlan = Self.buildSegmentedSourcePlan(
                segmentStartsSeconds: declaredSegmentStarts,
                videoTimeBase: videoTimeBase,
                sourceDurationSeconds: durationSeconds,
                startPts0: segmentedAnchorPts
            )
            if !segmentedPlan.isEmpty {
                plan = segmentedPlan
                self.firstKeyframePts = segmentedAnchorPts
                self.firstKeyframeSeconds = Double(segmentedAnchorPts)
                    * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: source-declared boundaries, "
                    + "\(plan.count) segments [anchorPts=\(segmentedAnchorPts) "
                    + "shortestSegment=\(String(format: "%.3f", plan.map { $0.durationSeconds }.min() ?? 0))s]",
                    category: .session
                )
            } else if keyframes.count >= 2, indexTrustworthy {
                plan = Self.buildKeyframeSegmentPlan(
                    keyframes: keyframes,
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds
                )
                planBoundariesClaimRandomAccess = true
                planKeyframePts = keyframes
                keyframeBytePositions = Dictionary(keyframeEntries.map { ($0.pts, $0.pos) },
                                                   uniquingKeysWith: { first, _ in first })
                // AE#561: these boundaries ARE the source's index entries (a Blu-ray title's EP maps),
                // so they carry its stamping. Read from the demuxer that produced them, never from the
                // URL or the host's metadata: on a remux session the delivered container is the one indexed.
                planBoundaryAxis = dem.keyframeIndexAxis
                let firstKeyframePts = keyframes.sorted().first ?? 0
                self.firstKeyframePts = firstKeyframePts
                let firstKeyframeSeconds = Double(firstKeyframePts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                self.firstKeyframeSeconds = firstKeyframeSeconds
                let videoStreamStart = videoStream.pointee.start_time
                let formatStart = dem.formatStartTime
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: keyframe-aligned, \(keyframes.count) IRAPs → \(plan.count) segments " +
                    "[firstKeyframePts=\(firstKeyframePts) (\(String(format: "%.3f", firstKeyframeSeconds))s) " +
                    "videoStream.start_time=\(videoStreamStart) format.start_time=\(formatStart)us " +
                    "plan[0].startSeconds=\(String(format: "%.3f", plan.first?.startSeconds ?? -1))]",
                    category: .session
                )
            } else {
                // Anchor the uniform plan at the content start so seg 0 is the first real keyframe, not an
                // empty source-0 segment the producer never emits (which strands AVPlayer's seg0 fetch; #64
                // follow-up): the first IRAP the spacing scan reads from the head (`uniformPlanAnchor`),
                // without a scan the first indexed entry or the stream's start_time.
                let sorted = keyframes.sorted()
                let streamStart = videoStream.pointee.start_time
                let provisionalAnchor = sorted.first ?? (streamStart != Int64.min ? max(0, streamStart) : 0)
                // #358: a grid finer than the GOP advertises boundaries no keyframe sits on, and the
                // keyframe-gated cutter leaves every one of them without a segment while the playlist
                // still offers it. Measure the spacing instead of assuming the target fits it.
                let spacing: KeyframeSpacing
                var scan: KeyframeScan?
                let stride: Double
                if sequentialOriginPinsProducerToZero {
                    // #370: the spacing scan starts with a seek (a silent no-op on the non-seekable
                    // sequential pb) and then consumes up to 30 s of the single byte-0-only
                    // connection; those packets never reach the pump, so the session starts late and
                    // silently drops the archive's first GOP(s). The #358 holes the scan exists to
                    // soften don't bite this path: the append playlist gives zero-duration holes no
                    // URI and its EXTINF is real by construction.
                    spacing = .unknown
                    stride = Self.targetSegmentDuration
                } else {
                    let measured = Self.measureKeyframeSpacing(
                        demuxer: dem,
                        videoStreamIndex: videoIndex,
                        videoTimeBase: videoTimeBase
                    )
                    scan = measured
                    spacing = measured.spacing
                    stride = Self.uniformStrideSeconds(spacing: spacing)
                }
                let anchorPts = Self.uniformPlanAnchor(scan: scan, axis: planBoundaryAxis, provisional: provisionalAnchor)
                plan = Self.buildUniformSegmentPlan(
                    videoTimeBase: videoTimeBase,
                    sourceDurationSeconds: durationSeconds,
                    startPts0: anchorPts,
                    strideSeconds: stride
                )
                self.firstKeyframePts = anchorPts
                self.firstKeyframeSeconds = Double(anchorPts) * Double(videoTimeBase.num) / Double(videoTimeBase.den)
                // A sparse/clustered index (MPEG-TS / M2TS: no Cues, only what find_stream_info + the
                // mid-file seek scanned) would otherwise build a multi-thousand-second first segment that
                // the frag_custom muxer buffers whole in RAM (#64). A bunched index (remote MKV whose Cues
                // tail read failed: only open-time keyframes, all within the first few seconds) would build
                // a single whole-file segment AVPlayer loads zero tracks from (#91). Report both witnesses.
                let tb = (videoTimeBase.num > 0 && videoTimeBase.den > 0)
                    ? Double(videoTimeBase.num) / Double(videoTimeBase.den) : 0
                var largestGapSeconds = 0.0
                if tb > 0, sorted.count >= 2 {
                    for i in 1..<sorted.count {
                        let g = Double(sorted[i] - sorted[i - 1]) * tb
                        if g > largestGapSeconds { largestGapSeconds = g }
                    }
                }
                let coverageSeconds = (tb > 0 && sorted.count >= 2)
                    ? Double(sorted[sorted.count - 1] - sorted[0]) * tb : 0
                let reason = keyframes.count < 2
                    ? "\(keyframes.count) IRAPs in index, need >=2"
                    : "index unusable (\(keyframes.count) IRAPs, coverage=\(String(format: "%.1f", coverageSeconds))s, largestGap=\(String(format: "%.1f", largestGapSeconds))s)"
                let spacingText: String
                if sequentialOriginPinsProducerToZero {
                    spacingText = "spacing scan skipped (sequential origin: the scan would consume the non-replayable prefix)"
                } else {
                    switch spacing {
                    case .measured(let s): spacingText = "measured IRAP spacing \(String(format: "%.3f", s))s"
                    case .exceedsBudget(let s): spacingText = "IRAP spacing exceeds the \(String(format: "%.0f", s))s scan budget"
                    case .singleKeyframeInSource: spacingText = "source holds one IRAP, no second to space against"
                    case .unknown: spacingText = "IRAP spacing unknown (no keyframe scanned)"
                    }
                }
                EngineLog.emit(
                    "[HLSVideoEngine] segment plan: uniform stride fallback (\(reason), anchorPts=\(anchorPts) "
                    + "(\(scan?.firstKeyframe != nil ? "first IRAP read" : "no IRAP read, index or stream start")), "
                    + "\(spacingText) → stride=\(String(format: "%.3f", stride))s, \(plan.count) segments)",
                    category: .session
                )
            }
        }

        // 3b. The software overlay: from here on the session describes the placeholder AVPlayer is served, and
        //     only the packet scans below read the source's own parameters.
        let sourceFraming = normalizeVideoFraming(demuxer: dem, videoStreamIndex: videoIndex,
                                                  codecpar: sourceCodecpar, isLive: isLiveSession)
        let codecpar: UnsafeMutablePointer<AVCodecParameters>
        if overlayDecodesVideo {
            let framing = sourceFraming.measuredFraming ?? A53SEIParser.nalFraming(
                codec: .hevc, extradata: sourceCodecpar.pointee.extradata.map { UnsafePointer($0) },
                size: Int(sourceCodecpar.pointee.extradata_size))
            guard let placeholder = OverlayPlaceholder(source: sourceCodecpar, framing: framing) else {
                throw HLSVideoEngineError.openFailed(reason: "no HEVC encoder for the overlay's placeholder")
            }
            let placeholderParams = try placeholder.codecParameters(source: sourceCodecpar)
            ownedCodecParams.append(placeholderParams)
            overlayPlaceholder = placeholder
            codecpar = placeholderParams.ptr
        } else {
            codecpar = sourceCodecpar
        }

        // 4. Classify DV variant; per-profile policy in `resolveCodecRoute`.
        let route = try resolveCodecRoute(codecpar: codecpar)
        let codecTagOverride = route.codecTagOverride
        var videoRange = route.videoRange
        let primaryCodecs = route.primaryCodecs
        let supplementalCodecs = route.supplementalCodecs
        let doviConfig = route.doviConfig
        let convertP7ToProfile81 = route.convertP7ToProfile81
        let dvVariant = route.dvVariant

        let resolution = (Int(codecpar.pointee.width), Int(codecpar.pointee.height))

        // #130: same avg -> r_frame_rate chain the host probe uses. A live MPEG-TS probe often
        // leaves avg_frame_rate unset while the parser still fills r_frame_rate; the master's
        // FRAME-RATE attribute is load-bearing for PQ/HLG variants (AVPlayer filters a
        // VIDEO-RANGE=PQ/HLG EXT-X-STREAM-INF without FRAME-RATE and fails -1002).
        let frameRate: Double? = AetherEngine.detectFrameRate(stream: videoStream)
        // HDCP-LEVEL omitted: local loopback has no DRM scope, and emitting TYPE-1 caused
        // AVFoundationErrorDomain -11868 / tracks count=0 when the HDMI link's HDCP 2.2
        // negotiation state didn't match (Vincent test 2026-05-26, HDR10 panel).
        let hdcpLevel: String? = nil

        // 5. Normalize the HEVC config record shipped in init.mp4:
        //    a) numOfArrays=0 (DV P5 MP4 encoders shipping VPS/SPS/PPS per-IRAP, #19 Wandering Earth 2):
        //       rebuild the hvcC from in-band parameter sets, else the dvh1 sample entry fails CME -4.
        //    b) numOfArrays>0 but carrying non-parameter-set arrays (libx265's user-data SEI_PREFIX, AE#187):
        //       strip everything but VPS/SPS/PPS. Apple TV hardware rejects an hvcC with an SEI array
        //       (tracks count=0 / -12848); macOS + the tvOS Simulator tolerate it, so it is device-only.
        //    c) Annex-B extradata (#365): a Matroska remux whose CodecPrivate is Annex B, or one with
        //       none at all where libavformat synthesised it from in-band parameter sets. The mp4
        //       muxer reads that as "the bitstream is Annex B too" and rewrites every sample; when the
        //       packets are in fact length-prefixed it empties them. Measured on packets, then the
        //       record is converted so the muxer's own test comes out right.
        //    The overlay's placeholder record is the encoder's own, length-prefixed: none of this applies.
        let framingNormalization = overlayDecodesVideo
            ? VideoFramingNormalization(extradataOverride: nil, measuredFraming: .lengthPrefixed(size: 4))
            : sourceFraming
        let measuredVideoNALFraming = framingNormalization.measuredFraming

        // Resolved here, before the config record is rebuilt: an MV-HEVC session keeps one SEI the AE#187
        // canonicalization would drop (`canonicalizeHEVCConfigRecord`).
        let stereo = StereoVideoSignal.resolve(
            presentation: stereoPresentation,
            codecID: codecpar.pointee.codec_id,
            multilayer: (videoStream.pointee.disposition & AV_DISPOSITION_MULTILAYER) != 0,
            containerStereo: StereoVideoSignal.containerStereo(codecpar),
            systemPresentsStereo: stereoOnAnySystem || StereoVideoSignal.systemPresentsStereo
        )
        let hevcExtradataOverride: [UInt8]?
        if overlayDecodesVideo {
            hevcExtradataOverride = nil
        } else if let normalized = framingNormalization.extradataOverride {
            hevcExtradataOverride = normalized
        } else if let rebuilt = rebuildHEVCExtradataWithInBandParameterSets(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: codecpar,
            rewindBeforeScan: !isLiveSession
        ) {
            hevcExtradataOverride = rebuilt
            EngineLog.emit(
                "[HLSVideoEngine] rebuilt hvcC with in-band parameter sets: "
                + "\(codecpar.pointee.extradata_size) B → \(rebuilt.count) B",
                category: .session
            )
        } else if codecpar.pointee.codec_id == AV_CODEC_ID_HEVC,
                  let ed = codecpar.pointee.extradata,
                  case let source = Array(UnsafeBufferPointer(start: ed, count: Int(codecpar.pointee.extradata_size))),
                  let canonical = Self.canonicalizeHEVCConfigRecord(
                      source, keepingSEIPayloadTypes: stereo.signal == .multiview
                          ? [Self.stereoReferenceDisplaysSEIPayloadType] : []) {
            hevcExtradataOverride = canonical
            EngineLog.emit(
                "[HLSVideoEngine] canonicalized hvcC (stripped non-parameter-set NAL arrays): "
                + "\(source.count) B → \(canonical.count) B (AE#187)",
                category: .session
            )
        } else {
            hevcExtradataOverride = nil
        }

        // 5b. HDR10 static metadata stated only in-band (MPEG-TS, a Matroska remuxed from one): read
        //     the SEI so movenc writes `mdcv` / `clli`, and for a `dvh1` sample entry or a composed FEL the
        //     first RPU's base-layer range and L6. See `InBandHDRStaticMetadata`.
        let inBandHDRMetadata = scanInBandHDRStaticMetadata(
            demuxer: dem,
            videoStreamIndex: videoIndex,
            codecpar: sourceCodecpar,
            framing: sourceFraming.measuredFraming,
            isLive: isLiveSession,
            readsDolbyVisionRPU: codecTagOverride == "dvh1" || composesFEL
        )
        let sdrUpgradedToHLG = inBandHDRMetadata.videoRange(upgrading: videoRange) != videoRange
        if sdrUpgradedToHLG {
            videoRange = .hlg
            EngineLog.emit(
                "[HLSVideoEngine] alternative transfer SEI names ARIB STD-B67 over a "
                + "trc=\(codecpar.pointee.color_trc.rawValue) VUI: backward-compatible HLG, "
                + "VIDEO-RANGE=HLG and colr transfer 18",
                category: .session
            )
        }

        // 6. Reset demuxer cursor to 0 (cue prewarm moved it mid-file). Skipped for live
        //    (no prewarm, forward-only feed), and for a forward-only VOD source: the prewarm did not
        //    run there, so the cursor never left the head, and a seek on a pb that cannot rewind
        //    drops the probe's buffered packets and leaves matroskadec resyncing from wherever the
        //    stream has got to (a remote MKV lost its first second, on the software path 30 s).
        if !isLiveSession {
            if dem.isSourceSeekable { dem.seek(to: 0) }
        }
        demuxerAtInitialProducerStart = false

        // volumeAvailableCapacityForImportantUsage is unavailable on tvOS; the plain capacity key
        // exists on every platform and is close enough for the quarter-of-free-space clamp.
        #if os(tvOS)
        let availableBytes = (try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        #else
        let availableBytes = (try? URL(fileURLWithPath: NSTemporaryDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
        // The ceiling counts 4 s segments, so the opt-in reads the host's request, not the scaled window.
        let capRelaxed = Self.retentionCapRelaxed(
            forwardWindowSegments: forwardWindowSegments / (isLiveSession ? 1 : Self.vodSegmentsPerCountedSegment))
        // Size the custom byte ceiling against capacity left by other running sessions.
        var resolvedBudget: SessionCacheBudgetResolution?
        let claim = RetentionClaims.shared.claim(volumeAvailableBytes: availableBytes) { remaining in
            let budget = Self.resolveSessionCacheBudget(
                requestedBytes: isLiveSession ? nil : requestedSessionCacheBudgetBytes,
                volumeAvailableBytes: remaining,
                capRelaxed: capRelaxed)
            resolvedBudget = budget
            return budget.enforcedBytes
        }
        let budget = resolvedBudget ?? Self.resolveSessionCacheBudget(
            requestedBytes: nil, volumeAvailableBytes: availableBytes, capRelaxed: capRelaxed)
        let retentionBudget = claim.bytes
        let segmentCache = SegmentCache(
            forwardWindow: forwardWindowSegments,
            backwardWindow: SegmentCache.defaultBackwardWindow
                * (isLiveSession ? 1 : Self.vodSegmentsPerCountedSegment),
            retentionBudgetBytes: retentionBudget,
            nativeLiveDVRPolicy: isLiveSession ? nativeLiveDVRPolicy : nil,
            onResidentSetChanged: { [weak self] in self?.noteResidentSetChanged() }
        )
        claim.track { [weak segmentCache] in segmentCache?.totalBytes ?? 0 }
        restartLock.lock()
        self.retentionBudgetBytes = retentionBudget
        self.sessionCacheVolumeSafetyLimitBytes = budget.volumeSafetyLimitBytes
        self.sessionCacheBaseEffectiveBytes = min(retentionBudget, budget.baseEffectiveBytes)
        self.retentionClaim = claim
        self.cache = segmentCache
        restartLock.unlock()
        onSessionCacheStatusChanged?(sessionCacheStatus())
        let requestedBudgetDescription = budget.requestedBytes
            .map { "\($0 / (1 << 20)) MiB" } ?? "automatic"
        EngineLog.emit(
            "[HLSVideoEngine] segment retention budget: requested=\(requestedBudgetDescription) "
            + "effective=\(retentionBudget / (1 << 20)) MiB "
            + "(volumeAvailable=\(availableBytes.map { "\($0 / (1 << 20)) MiB" } ?? "unknown"), "
            + "forwardWindow=\(forwardWindowSegments) seg"
            + (capRelaxed ? ", opt-in prefetch: default cap relaxed" : "")
            + (claim.heldBackBytes > 0
                ? ", \(claim.heldBackBytes / (1 << 20)) MiB held back for other sessions" : "") + ")",
            category: .session
        )

        // DV P5 MP4 encoders can omit the HEVC SPS VUI and `colr` atom (#19 Wandering Earth 2 WEB-DL):
        // color_trc/primaries/space all unspecified, so AVPlayer's DV decoder won't engage on the dvh1
        // sample entry (MKV reads Colour element directly into codecpar; MP4 demuxer has no fallback).
        // Forcing the canonical IPT-PQ-c2 tuple writes `colr nclx` so AVPlayer sees the PQ signal.
        // Primaries/transfer/matrix are spec-fixed for P5, so this is a repair (range: see below).
        // The AE#455 P8.1-as-P5 route needs the same guarantee for the same reason, and lands on the
        // same tuple: an HDR10 base layer is BT.2020 / PQ / BT.2020-NCL by definition.
        // The range is the RPU's `bl_video_full_range_flag` (a Profile 5 base layer is full range, and its SPS
        // often has no VUI to say so), then the parameter sets', then the container's, then limited.
        // Keyed on the sample entry the route chose, not on the variant: a Profile 5 record served as
        // its base layer (`dolbyVisionHandling = .baseLayerOnly`) is plain hvc1 whose VUI the muxer
        // stream-copies as it stands.
        // A record the engine synthesized from the RPU (AE#recordless) needs the repair most of all:
        // its gate IS an unspecified VUI, which is the signal shape #19 was reported on, and a source
        // is the same bytes whether the container recorded its profile or not. Measured on one
        // bitstream in two containers, Dolby's P5 asset with and without its `dvcC`: with the record
        // `init.mp4` is 883 B carrying `colr nclx` 9 / 16 / 9 full range, without it and without this
        // override 864 B and no `colr` at all, which would be two deliveries of one picture.
        // The range every init's `colr` states is the one its picture is decoded with: the parameter sets'
        // (`BitstreamVideoRange`), not codecpar's, where FFmpeg keeps a container's range over the SPS.
        let initRecord: [UInt8] = hevcExtradataOverride
            ?? codecpar.pointee.extradata.map { Array(UnsafeBufferPointer(start: $0, count: Int(codecpar.pointee.extradata_size))) }
            ?? []
        let parameterSetRange = BitstreamVideoRange.range(codecID: codecpar.pointee.codec_id, record: initRecord)
        #if DualLayerDolbyVision
        parameterSetsStateFullRange = parameterSetRange == AVCOL_RANGE_JPEG
        #endif
        let p5ColorOverride: MP4SegmentMuxer.ColorOverride?
        if codecTagOverride == "dvh1" {
            let sourceRange = codecpar.pointee.color_range
            // An overlay's placeholder is its own picture, coded limited; the source RPU describes the source's.
            let rpuRange = overlayDecodesVideo ? nil
                : inBandHDRMetadata.dolbyVisionBaseLayerFullRange.map { $0 ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG }
            let range = rpuRange ?? parameterSetRange
                ?? (sourceRange == AVCOL_RANGE_UNSPECIFIED ? AVCOL_RANGE_MPEG : sourceRange)
            EngineLog.emit(
                "[HLSVideoEngine] dvh1 colr range \(range == AVCOL_RANGE_JPEG ? "full" : "limited") from "
                + (rpuRange != nil ? "the RPU's bl_video_full_range_flag"
                   : parameterSetRange != nil ? "the parameter sets (no RPU read)" : "the container (no RPU, no sets)")
                + " (container: \(av_color_range_name(sourceRange).map { String(cString: $0) } ?? "?"))",
                category: .session
            )
            p5ColorOverride = MP4SegmentMuxer.ColorOverride(
                primaries: AVCOL_PRI_BT2020,
                trc: AVCOL_TRC_SMPTE2084,
                space: AVCOL_SPC_BT2020_NCL,
                range: range
            )
        } else {
            p5ColorOverride = nil
        }
        // Deep-copy codecpar so configs outlive the demuxer (live reopen closes it; see OwnedCodecParameters).
        guard let ownedVideoParams = OwnedCodecParameters(copying: codecpar) else {
            throw HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
        }
        ownedCodecParams.append(ownedVideoParams)
        if let parameterSetRange, parameterSetRange != ownedVideoParams.ptr.pointee.color_range {
            func name(_ r: AVColorRange) -> String { av_color_range_name(r).map { String(cString: $0) } ?? "?" }
            EngineLog.emit(
                "[HLSVideoEngine] colr range \(name(parameterSetRange)) from the parameter sets, over the "
                + "container's \(name(ownedVideoParams.ptr.pointee.color_range)): VideoToolbox decodes by the SPS",
                category: .session
            )
            ownedVideoParams.ptr.pointee.color_range = parameterSetRange
        }
        let liftedHDRBoxes = inBandHDRMetadata.attach(to: ownedVideoParams.ptr)
        // A session whose FEL is composed over AVPlayer shows the master, so its init describes the master: the
        // RPU's L6 over the base layer's grade (`DolbyVisionLevel6`).
        if composesFEL, let level6 = inBandHDRMetadata.dolbyVisionLevel6 {
            let described = level6.describeMaster(on: ownedVideoParams.ptr)
            if !described.isEmpty {
                EngineLog.emit("[HLSVideoEngine] composed FEL: init states the master's L6, "
                               + described.joined(separator: ", "), category: .session)
            }
        }
        // The `colr` the MPEG-TS delivery of the same stream carries (see `InBandHDRStaticMetadata`).
        if sdrUpgradedToHLG { ownedVideoParams.ptr.pointee.color_trc = AVCOL_TRC_ARIB_STD_B67 }
        if !liftedHDRBoxes.isEmpty {
            EngineLog.emit(
                "[HLSVideoEngine] HDR10 static metadata stated only in-band: lifted the SEI into the "
                + "stream side data, init carries \(liftedHDRBoxes.joined(separator: " + "))",
                category: .session
            )
        }
        // movenc writes `pasp` from the output codecpar alone, and a container-declared ratio never
        // reaches codecpar: Matroska's DisplayWidth quotient and MP4's own `pasp` land on AVStream
        // (matroskadec.c / mov.c), which is where a DVD remuxed to MKV carries its anamorphic ratio.
        // Without this the loopback item presented such a source at its coded shape, 720x576 for a
        // 1024x576 picture, and every consumer downstream of AVPlayer inherited the wrong rectangle.
        // Resolved through the same policy the two decoders run, so a ratio the software path
        // disbelieves (#290) is not one the native path stretches to.
        let declaredSAR = PixelAspectPolicy.declaredPixelAspect(
            bitstream: codecpar.pointee.sample_aspect_ratio,
            container: videoStream.pointee.sample_aspect_ratio,
            width: codecpar.pointee.width,
            height: codecpar.pointee.height
        )
        ownedVideoParams.ptr.pointee.sample_aspect_ratio = declaredSAR ?? AVRational(num: 0, den: 1)
        if let declaredSAR {
            EngineLog.emit(
                "[HLSVideoEngine] SAR \(declaredSAR.num):\(declaredSAR.den) on "
                + "\(codecpar.pointee.width)x\(codecpar.pointee.height) into the fMP4 sample entry "
                + "(bitstream=\(codecpar.pointee.sample_aspect_ratio.num):"
                + "\(codecpar.pointee.sample_aspect_ratio.den) "
                + "container=\(videoStream.pointee.sample_aspect_ratio.num):"
                + "\(videoStream.pointee.sample_aspect_ratio.den))",
                category: .session
            )
        }
        // Audit BIT-104: one framing verdict for the session, seeded only by a measurement (#365).
        // The extradata-derived framing is a claim, not a measurement.
        var framingMeasuredLengthPrefixed = false
        if case .lengthPrefixed? = measuredVideoNALFraming { framingMeasuredLengthPrefixed = true }
        stereoSignal = stereo.signal
        if stereo.signal != nil || stereoPresentation != .automatic
            || StereoVideoSignal.containerStereo(codecpar) != nil
            || (videoStream.pointee.disposition & AV_DISPOSITION_MULTILAYER) != 0 {
            EngineLog.emit("[HLSVideoEngine] stereo: \(stereo.reason)", category: .session)
        }
        // AE#886: built from stream fields only, so every producer of the session (and every init it
        // writes) agrees on the time base. A Matroska track with DefaultDuration probes its rate exactly.
        let frameGrid: CFRFrameGrid? = isLiveSession ? nil : CFRFrameGrid.make(
            sourceTimeBase: videoTimeBase,
            frameRate: videoStream.pointee.avg_frame_rate.num > 0
                ? videoStream.pointee.avg_frame_rate : videoStream.pointee.r_frame_rate,
            startPts: videoStream.pointee.start_time
        )
        if let frameGrid {
            EngineLog.emit(
                "[HLSVideoEngine] AE#886 frame grid: source TB \(videoTimeBase.num)/\(videoTimeBase.den) "
                + "is coarser than the frame, muxing on 1/\(frameGrid.outputTimeBase.den) "
                + "(\(frameGrid.frameTicks) ticks a frame, origin \(frameGrid.originPts))",
                category: .session
            )
        }
        let videoConfig = HLSSegmentProducer.StreamConfig(
            codecpar: UnsafePointer(ownedVideoParams.ptr),
            timeBase: videoTimeBase,
            codecTagOverride: codecTagOverride,
            doviConfig: doviConfig,
            convertP7ToProfile81: convertP7ToProfile81,
            colorOverride: p5ColorOverride,
            extradataOverride: hevcExtradataOverride,
            nalFramingOverride: measuredVideoNALFraming,
            convertsAnnexBSamples: framingNormalization.convertsAnnexBSamples,
            nalFramingLatch: NALFramingLatch(confirmed: framingMeasuredLengthPrefixed),
            stereo: stereo.signal,
            frameGrid: frameGrid
        )
        self.videoStreamIndex = videoIndex
        self.savedVideoConfig = videoConfig
        if overlayDecodesVideo {
            guard let ownedSourceParams = OwnedCodecParameters(copying: sourceCodecpar) else {
                throw HLSVideoEngineError.openFailed(reason: "codecpar copy failed")
            }
            ownedCodecParams.append(ownedSourceParams)
            self.sourceVideoConfig = HLSSegmentProducer.StreamConfig(
                codecpar: UnsafePointer(ownedSourceParams.ptr), timeBase: videoTimeBase, codecTagOverride: nil,
                nalFramingOverride: sourceFraming.measuredFraming)
            // The decode runs in the time base AVPlayer is served video in, so its pictures carry served times.
            overlayDecodeTap = OverlayDecodeTap(
                parameters: ownedSourceParams.ptr, timeBase: frameGrid?.outputTimeBase ?? videoTimeBase,
                containerSAR: videoStream.pointee.sample_aspect_ratio, deinterlace: overlayDeinterlace
            ) { [weak self] triplets, sourceSeconds in self?.overlayCaptionObserverForSession?(triplets, sourceSeconds) }
        } else {
            self.sourceVideoConfig = videoConfig
        }
        // Fold degenerate sub-frame segments (keyframe clusters make buildKeyframeSegmentPlan emit
        // ~40 ms segments the producer cannot cut, wedging the near-EOF resume; the plan and producer
        // share these boundaries, so the merge fixes both at once).
        plan = Self.collapseShortSegments(plan, minDurationSeconds: Self.minSegmentDurationSeconds)
        self.segmentPlan = plan
        if !keyframeBytePositions.isEmpty {
            sourcePeakBitrate = Self.peakSegmentBitrate(plan: plan, keyframeBytePositions: keyframeBytePositions)
            EngineLog.emit(
                "[HLSVideoEngine] peak segment bitrate: "
                + (sourcePeakBitrate.map { "\($0) bps (source average \(sourceBitrate) bps)" }
                   ?? "not measurable from the index byte positions"),
                category: .session
            )
        }

        // #93 residual: anchor the FIRST producer at the session's start position instead of seg0.
        // A resume start otherwise produces seg0 (torn down and discarded seconds later when
        // AVPlayer's initial seek fetches the resume segment), restarts, and the fetch/restart race
        // can 404 the item into a host reload (device: double spinner). The baseIndex > 0 anchor is
        // the battle-tested restart path (gate at plan[base].startPts, tfdt continuity per 4.9.1).
        if !isLiveSession, let startSeconds = initialStartSeconds, startSeconds > 0 {
            // A sequential origin cannot honour a resume anchor: the first producer would read
            // from byte 0 (the only addressable offset) while labelling those bytes segment
            // idx > 0, and the append playlist - which requires reports contiguous from 0 -
            // would drop every one of them and serve an empty asset. Produce from 0 and say so;
            // seeking into an archive means re-requesting it with a shifted start timestamp.
            if sequentialOriginPinsProducerToZero {
                EngineLog.emit(
                    "[HLSVideoEngine] sequential origin ignores startPosition="
                    + "\(String(format: "%.2f", startSeconds))s: only byte 0 is addressable, "
                    + "producing from the beginning",
                    category: .session
                )
            } else {
                initialProducerBaseIndex = segmentIndexForPlaylistTime(startSeconds)
                // The overlay's first run starts where AVPlayer will, before AVPlayer has a clock to say so.
                overlayDecodeTap?.noteStart(at: startSeconds)
                #if DualLayerDolbyVision
                felTap?.noteStart(at: startSeconds)
                #endif
                EngineLog.emit(
                    "[HLSVideoEngine] initial producer anchored at idx=\(initialProducerBaseIndex) "
                    + "(startPosition=\(String(format: "%.2f", startSeconds))s)",
                    category: .session
                )
            }
        }

        // Fallback duration from avg_frame_rate for MKVs that drop TrackEntry DefaultDuration
        // (HandBrake/web-rip pipelines). Without it, trun.last.duration=0 and AVPlayer parks on
        // WaitingToMinimizeStallsReason. 25 fps / 1 ms TB = 40 ticks; 23.976 fps = 41 ticks.
        let videoFallbackDuration: Int64 = {
            let avgFR = videoStream.pointee.avg_frame_rate
            guard avgFR.num > 0 && avgFR.den > 0,
                  videoTimeBase.num > 0, videoTimeBase.den > 0 else {
                return 40 // 25 fps / 1 ms TB defensive default
            }
            let num = Int64(avgFR.den) * Int64(videoTimeBase.den)
            let den = Int64(avgFR.num) * Int64(videoTimeBase.num)
            return max(1, num / den)
        }()
        self.videoFallbackDurationPts = videoFallbackDuration

        // 6a-pre. Open a side demuxer for demuxed-audio live HLS ingest (separate rendition
        //     playlist). Companion classifies its first segment to select "mpegts" vs "aac"
        //     format hint. Failure here fails the load so the host falls back to server-muxed.
        let audioDem: Demuxer
        if isLiveSession, dem.audioStreamIndex < 0, let companion = companionAudioReader {
            let formatHint: String
            if let info = companion as? LiveIngestSourceInfo {
                guard let resolved = info.resolveSegmentFormatHint() else {
                    // Terminal ingest (or no first segment inside the
                    // resolve bound): the companion can't deliver audio.
                    throw HLSVideoEngineError.openFailed(
                        reason: "demuxed-audio companion produced no classifiable first segment")
                }
                formatHint = resolved
            } else {
                // Non-ingest custom companions keep the previous TS contract.
                formatHint = "mpegts"
            }
            let side = Demuxer()
            do {
                try side.open(reader: companion, formatHint: formatHint, isLive: true)
            } catch {
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion open failed (\(error))")
            }
            guard side.audioStreamIndex >= 0,
                  let sideAudioStream = side.stream(at: side.audioStreamIndex) else {
                side.close()
                throw HLSVideoEngineError.openFailed(
                    reason: "demuxed-audio companion has no audio stream")
            }
            // Packed audio: anchor synthesized side-audio clock on the ID3 PRIV program-clock timestamp
            // rescaled into the side stream's own time base (raw "aac" demuxer: 1/28224000).
            if formatHint == "aac" {
                guard let offset90k = (companion as? LiveIngestSourceInfo)?
                    .packedAudioTimestampOffset90k else {
                    side.close()
                    throw HLSVideoEngineError.openFailed(
                        reason: "packed-audio companion carries no program-clock timestamp")
                }
                let tb = sideAudioStream.pointee.time_base
                packedSideAudioStartPts = av_rescale_q(
                    offset90k, AVRational(num: 1, den: 90000), tb)
            }
            restartLock.lock()
            sideAudioDemuxer = side
            restartLock.unlock()
            audioDem = side
            companionAudioTracks = side.audioTrackInfos()
            EngineLog.emit(
                "[HLSVideoEngine] demuxed-audio companion opened: format=\(formatHint) "
                + "side demuxer audioStreamIndex=\(side.audioStreamIndex)"
                + (packedSideAudioStartPts.map { " packedStartPts=\($0) (side TB)" } ?? ""),
                category: .session
            )
        } else {
            audioDem = dem
        }

        // 6a. Audio routing: stream-copy (common case: ec-3/Atmos JOC) → bridge (EINVAL on
        //     EAC3-from-MKV without dec3) → video-only. Override validated; stale index logs + falls back.
        var autoAudioStreamIndex = audioDem.audioStreamIndex
        // av_find_best_stream skips streams with empty codecpar (live TS probe bails early, -1381258232).
        // Fall back to first audio-type stream so the AAC repair below is reachable.
        if autoAudioStreamIndex < 0, isLiveSession {
            let byType = audioDem.firstAudioStreamIndexByType
            if byType >= 0 {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: av_find_best_stream found no usable audio "
                    + "(live probe left empty codecpar?); falling back to first "
                    + "audio-type stream \(byType)",
                    category: .session
                )
                autoAudioStreamIndex = byType
            }
        }
        let audioStreamIndex: Int32
        if let override = audioSourceStreamIndexOverride {
            if Self.isAudioStream(demuxer: audioDem, index: override) {
                audioStreamIndex = override
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override accepted, sourceStreamIndex=\(override) (auto would have picked \(autoAudioStreamIndex))",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSVideoEngine] audio: override sourceStreamIndex=\(override) invalid (not an audio stream), falling back to auto=\(autoAudioStreamIndex)",
                    category: .session
                )
                audioStreamIndex = autoAudioStreamIndex
            }
        } else {
            audioStreamIndex = autoAudioStreamIndex
        }
        var streamCopyAudio: HLSSegmentProducer.AudioConfig?
        var bridgePreferred = false
        var audioHLSCodecs: String?
        // AE#458: resolved once here so the stream-copy config and the bridge cascade below label the
        // track identically; both end up in the same fMP4 mdhd.
        let audioLanguage = AudioLanguageMap.iso639_2T(
            forSourceLanguage: audioStreamIndex >= 0
                ? audioDem.audioTrackInfos().first(where: { $0.id == Int(audioStreamIndex) })?.language
                : nil
        )

        if audioStreamIndex >= 0, let audioStream = audioDem.stream(at: audioStreamIndex) {
            let codecID = audioStream.pointee.codecpar.pointee.codec_id
            // Live MPEG-TS probe (KiKA repro): find_stream_info bails before decoding an audio frame,
            // leaving sample_rate=0. ASC synthesis and stream-copy both fail, silently degrading to
            // video-only. Fill 48 kHz stereo AAC-LC (Jellyfin live transcode + DVB/IPTV ADTS default).
            if isLiveSession, codecID == AV_CODEC_ID_AAC,
               audioStream.pointee.codecpar.pointee.sample_rate == 0 {
                audioStream.pointee.codecpar.pointee.sample_rate = 48000
                if audioStream.pointee.codecpar.pointee.ch_layout.nb_channels <= 0 {
                    av_channel_layout_default(&audioStream.pointee.codecpar.pointee.ch_layout, 2)
                }
                if audioStream.pointee.codecpar.pointee.profile < 0 {
                    audioStream.pointee.codecpar.pointee.profile = 1  // FF_PROFILE_AAC_LOW
                }
                EngineLog.emit(
                    "[HLSVideoEngine] audio: AAC stream had no codec parameters from the live "
                    + "probe; assuming 48 kHz stereo AAC-LC (Jellyfin live transcode default)",
                    category: .session
                )
            }
            resolveUnlabelledTrueHDAtmos(
                audioStream: audioStream, audioDemuxer: audioDem, streamIndex: audioStreamIndex)
            let compat = AudioCodecCompat.from(codecID)
            let sourceAudio = audioStream.pointee.codecpar.pointee
            let latmConfig = Self.latmConfiguration(audioStream.pointee.codecpar)
            let bluRayLPCM = BluRayLPCM(codecpar: audioStream.pointee.codecpar)
            // AE#764: CoreMedia refuses a FLAC min_blocksize under 192 and hangs on frames smaller than the
            // field claims, so a stream with small blocks cannot be copied, only decoded.
            let flacBlocksTooSmall = compat == .flac
                && FLACStreamInfo.coreMediaRejectsStreamCopy(UnsafePointer(audioStream.pointee.codecpar))
            if flacBlocksTooSmall {
                bridgePreferred = true
                let sizes = FLACStreamInfo.blockSizes(UnsafePointer(audioStream.pointee.codecpar))
                EngineLog.emit(
                    "[HLSVideoEngine] audio: FLAC STREAMINFO min_blocksize=\(sizes?.min ?? 0) "
                    + "max_blocksize=\(sizes?.max ?? 0) is below CoreMedia's floor of "
                    + "\(FLACStreamInfo.coreMediaMinimumBlockSize), bridging instead of stream-copy",
                    category: .session
                )
            } else if compat.requiresBridge || (compat == .aacLatm && latmConfig == nil)
                        || (compat == .bluRayLPCM && bluRayLPCM == nil) {
                bridgePreferred = true
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) "
                        + (compat == .aacLatm ? "(no AudioSpecificConfig read out of it while probing)"
                            : compat == .bluRayLPCM ? "(no format read out of it while probing)"
                            : "(bridge required)")
                        + ", decoding + "
                          + (Self.spatialRenderingLayout(
                                rendering: objectAudioRendering, codecID: sourceAudio.codec_id,
                                profile: sourceAudio.profile, sampleRate: sourceAudio.sample_rate)
                             .map { layout in
                                 Self.objectAudioSource(codecID: sourceAudio.codec_id, profile: sourceAudio.profile) == .trueHDAtmos
                                     ? "Atmos object render into \(layout.rawValue), APAC"
                                     : "DTS:X render into \(layout.rawValue) if its first frame decodes as DTS:X, APAC"
                             }
                             ?? (AudioBridge.output(for: audioBridgeMode,
                                                    sourceChannels: sourceAudio.ch_layout.nb_channels) == .eac3 ? "EAC3" : "PCM"))
                          + " re-encode",
                    category: .session
                )
            } else if compat != .unsupported {
                // ADTS-AAC from MPEG-TS has no ASC in extradata, so mp4a/esds can't be built
                // (EINVAL/"Could not find tag for codec aac"). Synthesize ASC + clear TS codec_tag;
                // pump strips per-frame ADTS headers.
                let stripAdts = Self.prepareAACForFMP4(audioStream.pointee.codecpar)
                if stripAdts {
                    let asc = audioStream.pointee.codecpar.pointee
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: AAC/ADTS, AudioSpecificConfig "
                        + (0..<Int(asc.extradata_size)).map { String(format: "%02x", asc.extradata[$0]) }.joined()
                        + " (object type \(Self.aacObjectType(profile: asc.profile, frameSize: asc.frame_size))) "
                        + "+ stripping ADTS for fMP4 stream-copy",
                        category: .session
                    )
                }
                // Deep-copy AFTER prepareAACForFMP4 so the synthesized ASC is included.
                guard let ownedAudioParams = OwnedCodecParameters(copying: audioStream.pointee.codecpar) else {
                    throw HLSVideoEngineError.openFailed(reason: "audio codecpar copy failed")
                }
                ownedCodecParams.append(ownedAudioParams)
                // LATM: the muxer is given the AAC inside it; the demuxer's own stream stays LATM.
                if let latmConfig {
                    guard Self.prepareLATMForFMP4(ownedAudioParams.ptr, config: latmConfig) else {
                        throw HLSVideoEngineError.openFailed(reason: "audio AudioSpecificConfig allocation failed")
                    }
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: AAC/LATM, AudioSpecificConfig "
                        + latmConfig.map { String(format: "%02x", $0) }.joined()
                        + " + unwrapping LATM for fMP4 stream-copy",
                        category: .session
                    )
                }
                // Linear PCM: the muxer names every channel's speaker.
                if compat == .pcm { Self.namePCMSpeakers(ownedAudioParams.ptr) }
                // Blu-ray LPCM: the muxer is given the samples behind its headers, as big-endian PCM.
                if let bluRayLPCM {
                    guard bluRayLPCM.describe(ownedAudioParams.ptr) else {
                        throw HLSVideoEngineError.openFailed(reason: "audio channel layout allocation failed")
                    }
                    EngineLog.emit(
                        "[HLSVideoEngine] audio: Blu-ray LPCM, \(bluRayLPCM.speakers.count) channels "
                        + "\(bluRayLPCM.bitsPerSample)-bit \(bluRayLPCM.sampleRate) Hz"
                        + (bluRayLPCM.isPadded ? ", its unused channel dropped," : "")
                        + " + taking the headers off for fMP4 stream-copy as ipcm",
                        category: .session
                    )
                }
                streamCopyAudio = HLSSegmentProducer.AudioConfig(
                    copying: audioStream,
                    codecpar: UnsafePointer(ownedAudioParams.ptr),
                    sourceStreamIndex: audioStreamIndex,
                    framing: latmConfig.map { .latm(config: $0) }
                        ?? bluRayLPCM.map { .bluRayLPCM($0) } ?? (stripAdts ? .adts : .raw),
                    language: audioLanguage
                )
                let acp = audioStream.pointee.codecpar.pointee
                // Always `ec-3` per RFC 6381 (never `ec+3`: tvOS 26.5 enforces strict RFC 6381,
                // same as iOS; `ec+3` produced -11848/-15517, Vincent test 2026-05-26). JOC/Atmos
                // signaling lives in the per-segment `dec3` box, not the CODECS string (#34).
                // The only EAC3 case that can't stream-copy is EAC3-from-MKV without dec3 extradata;
                // `probeWriteHeader` in buildProducerWithAudioCascade catches and bridges that.
                let isJOC = compat == .eac3 && acp.profile == 30
                audioIsAtmosStreamCopy = isJOC
                // RFC 6381: AAC is mp4a.40 and the object type, so HE-AAC is 40.5 and HE-AACv2
                // 40.29; PCM is its sample entry, `fpcm` for float and `ipcm` for integer.
                audioHLSCodecs = compat == .aac || compat == .aacLatm
                    ? "mp4a.40.\(Self.aacObjectType(profile: acp.profile, frameSize: acp.frame_size))"
                    : compat == .pcm && acp.codec_id == AV_CODEC_ID_PCM_F32LE ? "fpcm" : compat.hlsCodecsString
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec=\(compat) → stream-copy as `\(audioHLSCodecs ?? "?")` "
                    + "\(isJOC ? "[JOC=Atmos] " : "")"
                    + "(frame \(streamCopyAudio?.frameDuration ?? 0) samples)",
                    category: .session
                )
            } else {
                // Not video-only, and the line used to say so. The bridge cascade below asks for a
                // decoder by id, not for a routing-table entry, so a codec the table does not name
                // still gets sound as long as the FFmpeg build carries its decoder (measured
                // 2026-09-10 on Nellymoser-in-FLV before its table entry existed: this line, then a
                // NELLYMOSER -> bridge and a session with audio). What the missing entry costs
                // is the stream-copy decision, which is why the next thing that happens is a bridge.
                // The genuinely silent case is one line further down: no decoder in the build at
                // all, which the cascade reports as `falling back to SILENT video-only`.
                EngineLog.emit(
                    "[HLSVideoEngine] audio: codec id=\(codecID.rawValue) is not in the routing table, "
                    + "no stream-copy decision to make; the bridge cascade decides whether it plays",
                    category: .session
                )
            }
        }

        // 6a-post. Packed side audio: one AAC frame in the side stream's TB. Computed after the
        //     codec repair above so frame_size/sample_rate are fully filled in.
        if packedSideAudioStartPts != nil, audioStreamIndex >= 0,
           let sideStream = audioDem.stream(at: audioStreamIndex) {
            let acp = sideStream.pointee.codecpar.pointee
            let samples = acp.frame_size > 0 ? Int64(acp.frame_size) : 1024
            let rate = acp.sample_rate > 0 ? Int64(acp.sample_rate) : 48000
            let tb = sideStream.pointee.time_base
            packedSideAudioFallbackDurationPts = (tb.num > 0 && tb.den > 0)
                ? max(1, samples * Int64(tb.den) / (rate * Int64(tb.num)))
                : 1
        }

        // #15: native subtitles requested but no host pre-populated the cue stores (the `aetherctl serve
        // --native-subs` path). Auto-attach one store per non-bitmap text track BEFORE the producer is
        // built: the producer's init applies the demuxer discard set, and the subtitle tap streams must
        // be in it (Sodalite#32; a post-init arm only ever saw open-time queued packets). The host's
        // full-session path sets these before start() (AetherEngine+Loading), so the isEmpty guard makes
        // this a no-op there. makeProducer threads the stores + tap onto the producer.
        if enableNativeSubtitleTrackForSession && nativeSubtitleCueStoresForSession.isEmpty {
            let textTracks = dem.subtitleTrackInfos().filter { !AetherEngine.isBitmapSubtitleCodec($0.codec) }
            if !textTracks.isEmpty {
                nativeSubtitleCueStoresForSession = textTracks.map { _ in NativeSubtitleCueStore() }
                nativeSubtitleLanguagesForSession = textTracks.map { $0.language }
                nativeSubtitleSourceStreamIndicesForSession = textTracks.map { Int32($0.id) }
                EngineLog.emit(
                    "[HLSVideoEngine] #15 auto-attached \(nativeSubtitleCueStoresForSession.count) native "
                    + "subtitle store(s) for the WebVTT rendition "
                    + "(langs=\(nativeSubtitleLanguagesForSession.map { $0 ?? "und" }))",
                    category: .session
                )
            }
        }

        // docs/demuxed-audio.md: the playlist the load planned, and with it the output's shape, decided before the
        // first producer is built. The audio the source carries stands in for the cascade's verdict: the cascade
        // can only take audio away, and a master without an audio group plays a session left video-only.
        let carriesAudio = audioStreamIndex >= 0
        if let planned = plannedPanelIsInHDRMode {
            plannedServesMaster = playlistDecision(
                codecpar: codecpar, demuxer: dem, frameRate: frameRate, carriesAudio: carriesAudio,
                videoRange: videoRange, panelIsInHDRMode: planned).useMaster
        }
        outputShape = .forPlan(servesMaster: plannedServesMaster, carriesAudio: carriesAudio)
        if outputShape == .demuxed, let audioStream = audioDem.stream(at: audioStreamIndex) {
            makeAudioRenditionCache(audioCodecpar: audioStream.pointee.codecpar)
        }
        EngineLog.emit("[HLSVideoEngine] output shape: \(outputShape.rawValue) "
                       + "(planned master: \(plannedServesMaster.map { "\($0)" } ?? "at serve"))", category: .session)

        // 6b. Run the stream-copy / bridge / video-only cascade.
        let prod: HLSSegmentProducer
        prod = try buildProducerWithAudioCascade(
            preferBridge: bridgePreferred,
            streamCopyAudio: streamCopyAudio,
            sourceAudioStreamIndex: audioStreamIndex,
            sourceAudioStream: audioStreamIndex >= 0 ? audioDem.stream(at: audioStreamIndex) : nil,
            audioDemuxer: audioDem,
            sourceCarriesAudio: audioDem.firstAudioStreamIndexByType >= 0,
            audioHLSCodecs: &audioHLSCodecs,
            audioLanguage: audioLanguage
        )
        self.producer = prod
        self.activeAudioSourceStreamIndex = savedAudioConfig != nil ? audioStreamIndex : -1
        // A cascade that ended video-only has no audio to serve as a rendition: the session goes back to one
        // file per segment, its video's, and its cache takes the whole budget again.
        if savedAudioConfig == nil, let audioCache = audioRenditionCache {
            restartLock.lock()
            audioRenditionCache = nil
            restartLock.unlock()
            _ = audioCache.close(reason: .sessionStopped)
            if retentionBudgetBytes > 0 { segmentCache.setRetentionBudget(retentionBudgetBytes) }
            outputShape = .muxed
            EngineLog.emit("[HLSVideoEngine] output shape: muxed (the audio cascade left the session video-only)",
                           category: .session)
        }
        // AE#458: only when the audio actually reached the variant. A cascade that fell through to
        // video-only must not advertise an audio rendition that is not in the segments, and must not
        // force the master for one either.
        let servedAudioLanguage = savedAudioConfig != nil ? audioLanguage : nil
        // Same gate, for the rendition's CHANNELS: read the count off the config the MUXER got, so a
        // bridged track reports the encoder's layout rather than the source's. `audioIsAtmosStreamCopy`
        // is latched from the source probe (profile 30 = JOC) before the cascade runs, so it is still
        // true on a source whose stream-copy was rejected and bridged to FLAC; objects do not survive
        // that, hence the `.streamCopy` conjunct. Without it a downgraded session would advertise
        // `CHANNELS="16/JOC"` over a FLAC bed, which is worse than saying nothing.
        // #731: the APAC bed is muxed behind a 2-channel ALAC stand-in, so its bridge states the count.
        let servedAudioChannels: Int? = savedAudioConfig.map {
            $0.bridge?.servedChannelCount ?? Int($0.codecpar.pointee.ch_layout.nb_channels)
        }
        let servedAudioIsAtmosStreamCopy =
            audioIsAtmosStreamCopy && audioDelivery == .streamCopy && savedAudioConfig != nil

        // 7. Wire provider, server, and URL.
        let manifestCodecs = audioHLSCodecs.map { "\(primaryCodecs),\($0)" } ?? primaryCodecs
        let prov = VideoSegmentProvider(
            cache: segmentCache,
            audioRendition: audioRenditionCache,
            segments: plan,
            codecsString: manifestCodecs,
            supplementalCodecs: supplementalCodecs,
            resolution: resolution,
            videoRange: videoRange,
            frameRate: frameRate,
            hdcpLevel: hdcpLevel,
            sourceBitrate: sourceBitrate,
            sourcePeakBitrate: sourcePeakBitrate,
            bridgedAudioPeakBitrate: savedAudioConfig?.bridge?.peakOutputBitRate ?? 0,
            audioLanguage: servedAudioLanguage,
            audioChannelCount: servedAudioChannels,
            audioIsAtmosStreamCopy: servedAudioIsAtmosStreamCopy,
            videoLayout: stereoSignal != nil ? StereoVideoSignal.videoLayout : nil,
            isLive: isLiveSession,
            // Sequential archives: playlist grows with the producer's REAL cut durations. The
            // static plan's uniform EXTINF lies whenever the archive's GOP cadence does not
            // divide the cut target (1.92 s GOPs vs a 4.0 s plan put every segment's media up
            // to 1.9 s outside its advertised window; AVPlayer visibly jumped at each resync).
            sequentialAppendPlaylist: sequentialOrigin && !isLiveSession,
            liveWindowSizing: LiveWindowSizing(
                targetSegmentDurationSeconds: liveCutTargetSeconds,
                dvrWindowSeconds: dvrWindowSeconds,
                // AE#443: the window is a promise in seconds and the disk is a fact in bytes. Handing
                // the sizing the budget is what lets the two meet, instead of the producer meeting a
                // resident cap it can never pass.
                retentionBudgetBytes: retentionBudgetBytes,
                edgeCushionSeconds: isLiveSession ? liveEdgeCushionSeconds : nil
            ),
            nativeLiveDVRPolicy: isLiveSession ? nativeLiveDVRPolicy : nil,
            allowsBoundedDegradedStart: liveJoinProfile == .fastZap,
            startupGraceSeconds: liveStartupGraceSeconds,
            singleSegmentStartupMinimumSeconds: liveStartupSingleSegmentMinimumSeconds,
            boundedStartFloorsAtHoldback: LiveEdgePolicy.boundedStartFloorArmed,
            firstServeLatchCoversEngineCut: LiveEdgePolicy.firstServeLatchAllArmed,
            blockingReloadOverride: blockingReloadOverride,
            liveCadencePolicy: liveCadencePolicy,
            restartHandler: isLiveSession ? nil : { [weak self] idx in
                self?.requestRestart(at: idx)
            },
            // #358: a plan index no keyframe can open, asked for twice. Nothing downstream recovers
            // from it, so the session ends with an error the host can act on instead of a picture
            // that never moves again while the engine still reports playing.
            unrecoverableGapHandler: isLiveSession ? nil : { [weak self] _ in
                self?.surfaceVODSourceFailure(FFmpegErr.eio, "Source segment could not be produced")
            },
            restartActivity: isLiveSession ? nil : { [weak self] in
                self?.restartInFlight ?? false
            },
            activeProducerBase: isLiveSession ? nil : { [weak self] in
                self?.currentProducerBaseIndex
            },
            // AE#169 round 2: a finished pump can never march; the forward-window wait must
            // escalate to restart instead of parking on its frozen front.
            producerFinished: isLiveSession ? nil : { [weak self] in
                self?.currentProducerFinished ?? false
            },
            // #93 residual: the first producer may be anchored at the resume segment; without this
            // the cold-start heuristic (abs(index - lastRestartIndex) > 2) restarts it immediately.
            initialRestartIndex: initialProducerBaseIndex,
            nativeSubtitleStores: nativeSubtitleCueStoresForSession,
            nativeSubtitleLanguages: nativeSubtitleLanguagesForSession,
            nativeSubtitleRenditionInfos: nativeSubtitleRenditionInfosForSession,
            stripASSMarkupInVTT: preserveASSMarkupForSubtitleTap,
            nativeSubtitleDefaultOrdinal: nativeSubtitleDefaultOrdinal
        )
        self.provider = prov
        // AE#520 round 2: the close reads it on the playlist-build thread, so it is a closure over a
        // mirror rather than a read of the item.
        prov.consumerBufferedSecondsProvider = consumerBufferedSecondsProvider
        wireProviderCallbacks(prod, to: prov)

        EngineLog.emit(
            "[HLSVideoEngine] prepared: codec=\(manifestCodecs)"
            + (supplementalCodecs.map { " supplemental=\($0)" } ?? "")
            + " resolution=\(resolution.0)x\(resolution.1) "
            + "fps=\(frameRate.map { String(format: "%.3f", $0) } ?? "nil") "
            + "range=\(videoRange.rawValue) DV=\(dvVariant) segments=\(plan.count) "
            + "duration=\(String(format: "%.1f", durationSeconds))s"
        )

        let srv = HLSLocalServer(provider: prov)
        try srv.start()
        self.server = srv

        // 8. Kick the pump. Seek on the video stream's exact plan timestamp and forbid an earlier
        // landing. A global time seek can choose the previous sync point in a multi-stream MP4,
        // leaving the producer to scan a whole GOP over the origin before writing anything (#191).
        // The DTS:X verdict may already have put the cursor there and peeked from it (#744); a
        // second seek would drop those packets and read the same bytes again.
        if !demuxerAtInitialProducerStart {
            seekToInitialProducerStart(dem)
        }
        // #416: the pump harvests every subtitle packet it demuxes, so where it OPENS is where its
        // coverage of the source begins. The subtitle drain reads "nothing between this set and the
        // playhead" out of the same store, and below this position that answer means nothing.
        if !plan.isEmpty {
            let openIndex = max(0, min(initialProducerBaseIndex, plan.count - 1))
            let tb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
            subtitlePacketStore.noteHarvestAnchor(
                at: Double(plan[openIndex].startPts) * Double(tb.num) / Double(tb.den))
        }
        prod.start()
        preparedServe = PreparedServe(
            codecpar: codecpar, demuxer: dem, plan: plan, segmentCache: segmentCache, server: srv,
            provider: prov, frameRate: frameRate, servedAudioLanguage: servedAudioLanguage,
            servedAudioIsAtmosStreamCopy: servedAudioIsAtmosStreamCopy, videoRange: videoRange,
            dvVariant: dvVariant, convertP7ToProfile81: convertP7ToProfile81)
    }

    /// Choose the playlist AVPlayer is handed, once the panel can answer for itself.
    ///
    /// AE#348: `prepare()` does everything that does not depend on the panel (open, segment plan, local
    /// server, the producer cutting the first segments) and this does the one thing that does. Split so
    /// a load can run `prepare()` while the panel is still switching and only this has to wait for it.
    /// Reading `panelIsInHDRMode` mid-switch would route an HDR title as SDR for the whole session.
    public func serve(panelIsInHDRMode: Bool) throws -> URL {
        guard let prepared = preparedServe else {
            throw HLSVideoEngineError.openFailed(reason: "serve() without a prepared session")
        }
        preparedServe = nil
        let codecpar = prepared.codecpar
        let dem = prepared.demuxer
        let plan = prepared.plan
        let segmentCache = prepared.segmentCache
        let srv = prepared.server
        let prov = prepared.provider
        let frameRate = prepared.frameRate
        let servedAudioLanguage = prepared.servedAudioLanguage
        let servedAudioIsAtmosStreamCopy = prepared.servedAudioIsAtmosStreamCopy
        let videoRange = prepared.videoRange
        let dvVariant = prepared.dvVariant
        let convertP7ToProfile81 = prepared.convertP7ToProfile81

        // URL routing: master playlist (VIDEO-RANGE=PQ + SUPPLEMENTAL-CODECS=dvh1) only when
        // the panel is already in HDR at load time (`panelIsInHDRMode`). A master claiming HDR
        // while the panel sits in SDR fails with AVFoundationErrorDomain -11848. `panelIsInHDRMode`
        // is read after waitForSwitch settles so a transitioning panel already reads as HDR.
        //
        // `(displaySupportsHDR && matchContentEnabled)` was previously used as a proxy, but
        // tvOS exposes only one combined `isDisplayCriteriaMatchingEnabled` flag; rate-match ON +
        // range-match OFF caused -11848/-11868 (DrHurt #4 2026-05-27).
        //
        // DV P5 on non-DV panels: ALWAYS media. Single-variant P5 master has no backward-compat
        // brand (/db1p//db4h are P8.1/P8.4 only), so AVPlayer rejects with -11868
        // (AVErrorNoCompatibleAlternatesForExternalDisplay, Vincent test 2026-05-26, #4 #63).
        // DV8.1/8.4 on non-DV panels already downgrade to hvc1.* + strip DV side data above, so
        // the standard sourceIsHDR && panelReadyForHDR check routes them correctly.
        // #15: a SUBTITLES rendition lives only in a master; the pure decision below forces the
        // master for routing-safe subtitled sources so PiP can show subtitles.
        // The load's planned answer wins over a later one: the session was prepared for it (`plannedServesMaster`).
        let panelIsInHDRMode = plannedPanelIsInHDRMode ?? panelIsInHDRMode
        let decision = playlistDecision(codecpar: codecpar, demuxer: dem, frameRate: frameRate,
                                        carriesAudio: savedAudioConfig != nil,
                                        videoRange: videoRange, panelIsInHDRMode: panelIsInHDRMode)
        let stillsAvailable = decision.stillsAvailable
        yieldsStills = stillsAvailable
        previewNeedsCompositor = FrameDecodeContext.isDVNoBaseLayer(codecpar: codecpar)
        if !stillsAvailable {
            EngineLog.emit("[HLSVideoEngine] Dolby Vision Profile 5 / 10.0 stills are not built in "
                           + "(DualLayerDolbyVision trait off): no scrub thumbnails or I-frame stills; "
                           + "scrub previews and the held picture go through the system compositor", category: .session)
        }
        let iFrameCandidate = decision.iFrameCandidate
        // A scrub still past the resident window reads off the source by the same rule, whether or not the
        // rendition was asked for.
        if case .served(let timeline) = IFrameRenditionEligibility.candidate(.init(
            requested: true,
            isLive: isLiveSession,
            planBoundariesClaimRandomAccess: planBoundariesClaimRandomAccess,
            seeksToTimeWithoutIndex: dem.seeksToTimeWithoutIndex,
            sequentialOrigin: sequentialOrigin,
            heldSourceConnection: openProfile.avioHeldConnection,
            originIsSerial: sourceReopenableByURL
                && OriginRequestBudget.shared.requiresSerialRequests(sourceURL),
            secondReaderAvailable: sourceReopenableByURL || customKeyframeReader != nil,
            stillsUnavailable: !stillsAvailable)) {
            sourceStillTimeline = timeline
        } else {
            // Nothing will read a picture off this source, so a custom source's clone is not kept for it.
            closeUnusedCustomKeyframeReader()
        }
        // The compositor preview reads by URL only: a custom reader's clone belongs to the rendition. It reads
        // the plan's keyframes, so it needs the keyframe timeline.
        previewReadsSource = previewNeedsCompositor && IFrameRenditionEligibility.candidate(.init(
            requested: true,
            isLive: isLiveSession,
            planBoundariesClaimRandomAccess: planBoundariesClaimRandomAccess,
            seeksToTimeWithoutIndex: false,
            sequentialOrigin: sequentialOrigin,
            heldSourceConnection: openProfile.avioHeldConnection,
            originIsSerial: sourceReopenableByURL
                && OriginRequestBudget.shared.requiresSerialRequests(sourceURL),
            secondReaderAvailable: sourceReopenableByURL)) == .served(.keyframes)
        // A demuxed session's audio is a rendition, which only a master names: it was prepared for the master.
        let useMasterPlaylist = outputShape == .demuxed || decision.useMaster
        if let planned = plannedServesMaster, planned != useMasterPlaylist {
            EngineLog.emit("[HLSVideoEngine] planned playlist (\(planned ? "master" : "media")) differs from the "
                           + "one served (\(useMasterPlaylist ? "master" : "media"))", category: .session)
        }
        let resolvedURL: URL? = useMasterPlaylist
            ? srv.playlistURL
            : srv.mediaPlaylistURL
        guard let url = resolvedURL else {
            stop(reason: .loadFailed)
            throw HLSVideoEngineError.openFailed(reason: "server URL not ready")
        }
        self.servingMasterPlaylist = useMasterPlaylist
        iFrameRenditionVerdict = IFrameRenditionEligibility.resolve(
            candidate: iFrameCandidate, servingMaster: useMasterPlaylist)
        if case .served(let timeline) = iFrameRenditionVerdict,
           let rendition = makeIFrameRendition(plan: plan, timeline: timeline, cache: segmentCache,
                                               sourceIsHDR: videoRange != .sdr || dvVariant != .none,
                                               servedRange: videoRange) {
            iFrameRendition = rendition
            prov.setIFrameSource(rendition)
            EngineLog.emit("[HLSVideoEngine] i-frame rendition: served segments=\(plan.count) "
                           + "entries=\(rendition.entries.count) "
                           + "format=\(rendition.format.logName) "
                           + "sdrCompanion=\(rendition.companionFormat?.logName ?? "none")", category: .session)
        } else if iFramePlaylistRequested {
            if iFrameRenditionVerdict.isServed { iFrameRenditionVerdict = .absent(.noSecondReader) }
            if case .absent(let reason) = iFrameRenditionVerdict {
                EngineLog.emit("[HLSVideoEngine] i-frame rendition: absent reason=\(reason.rawValue)",
                               category: .session)
            }
        }
        self.servedSourceIsHDR = videoRange != .sdr
        self.servedDolbyVisionConversion = convertP7ToProfile81 ? .profile7ToProfile81 : nil
        EngineLog.emit("[HLSVideoEngine] serving on \(url.absoluteString) (dvModeAvailable=\(dvModeAvailable) effectiveDvMode=\(effectiveDvMode) panelIsHDR=\(panelIsInHDRMode) displaySupportsHDR=\(displaySupportsHDR) matchContent=\(matchContentEnabled) sourceIsHDR=\(videoRange != .sdr || effectiveDvMode) useMaster=\(useMasterPlaylist) videoRange=\(videoRange) dvVariant=\(dvVariant) audioLang=\(servedAudioLanguage ?? "none"))")
        return url
    }

    /// The demuxed shape's audio rendition cache, beside `cache`. Each keeps resident its rendition's share of the
    /// session's retention budget, the share of the session's bitrate its rendition is, so both keep about the
    /// same span of the title; the claim counts both.
    private func makeAudioRenditionCache(audioCodecpar: UnsafePointer<AVCodecParameters>) {
        guard let videoCache = cache else { return }
        let budget = retentionBudgetBytes
        let par = audioCodecpar.pointee
        let audioRate = AudioBridge.peakBitRate(bitRate: par.bit_rate, channels: par.ch_layout.nb_channels,
                                                sampleRate: par.sample_rate, bitsPerRawSample: par.bits_per_raw_sample)
        let sessionRate = max(sourceBitrate, audioRate + 1)
        let audioShare = budget > 0 ? Int(Int64(budget) * min(audioRate, sessionRate) / sessionRate) : 0
        let audioCache = SegmentCache(
            forwardWindow: forwardWindowSegments,
            backwardWindow: SegmentCache.defaultBackwardWindow
                * (isLiveSession ? 1 : Self.vodSegmentsPerCountedSegment),
            retentionBudgetBytes: audioShare,
            nativeLiveDVRPolicy: isLiveSession ? nativeLiveDVRPolicy : nil,
            onResidentSetChanged: { [weak self] in self?.noteResidentSetChanged() }
        )
        if budget > 0 { videoCache.setRetentionBudget(budget - audioShare) }
        restartLock.lock()
        audioRenditionCache = audioCache
        retentionClaim?.track { [weak videoCache, weak audioCache] in
            (videoCache?.totalBytes ?? 0) + (audioCache?.totalBytes ?? 0)
        }
        restartLock.unlock()
        EngineLog.emit("[HLSVideoEngine] audio rendition: \(audioShare / (1 << 20)) MiB of the "
                       + "\(budget / (1 << 20)) MiB retention budget (\(audioRate) of \(sessionRate) bps)",
                       category: .session)
    }

    /// Which playlist AVPlayer is handed, from facts `prepare()` already has and the panel answer.
    ///
    /// Side-effect free, so `prepare()` can ask it for a load that decided the panel answer before the display
    /// switch (`plannedPanelIsInHDRMode`) and `serve(panelIsInHDRMode:)` asks it again with the same inputs.
    private func playlistDecision(
        codecpar: UnsafeMutablePointer<AVCodecParameters>, demuxer dem: Demuxer, frameRate: Double?,
        carriesAudio: Bool, videoRange: HLSVideoRange, panelIsInHDRMode: Bool
    ) -> (useMaster: Bool, iFrameCandidate: IFrameRenditionEligibility.Verdict, stillsAvailable: Bool) {
        let stillsAvailable = FrameDecodeContext.yieldsStill(
            dolbyVisionNoBaseLayer: FrameDecodeContext.isDVNoBaseLayer(codecpar: codecpar))
        // AE#682: decided before the routing below, because an I-frame rendition is one of the
        // reasons to serve a master at all.
        let iFrameCandidate = IFrameRenditionEligibility.candidate(.init(
            requested: iFramePlaylistRequested,
            isLive: isLiveSession,
            planBoundariesClaimRandomAccess: planBoundariesClaimRandomAccess,
            seeksToTimeWithoutIndex: dem.seeksToTimeWithoutIndex,
            sequentialOrigin: sequentialOrigin,
            heldSourceConnection: openProfile.avioHeldConnection,
            originIsSerial: sourceReopenableByURL
                && OriginRequestBudget.shared.requiresSerialRequests(sourceURL),
            secondReaderAvailable: sourceReopenableByURL || customKeyframeReader != nil,
            stillsUnavailable: !stillsAvailable))
        let hasNativeSubs = enableNativeSubtitleTrackForSession && !nativeSubtitleCueStoresForSession.isEmpty
        // AE#187: tvOS HW HEVC needs the codec advertised in a master's CODECS attribute; a bare media
        // playlist (H.264 is fine media-direct) fails the item with tracks count=0 / -12848. Scope to
        // tvOS: iOS/macOS build the HEVC track from the init hvcC media-direct and are left unperturbed.
        #if os(tvOS)
        let videoCodecNeedsMasterSignaling = codecpar.pointee.codec_id == AV_CODEC_ID_HEVC
        #else
        let videoCodecNeedsMasterSignaling = false
        #endif
        // AE#849: an audio switch on a session the display refused the HDR master for stays on the
        // media playlist; planned with it, so the output is muxed too.
        let useMaster = !keepsMediaPlaylistRoute && (AetherEngine.forceMasterPlaylistForTesting
            || Self.resolveUseMasterPlaylist(
            videoRange: videoRange, effectiveDvMode: effectiveDvMode,
            panelIsInHDRMode: panelIsInHDRMode, displaySupportsHDR: displaySupportsHDR,
            hasNativeSubs: hasNativeSubs,
            builtInPanelEngagesOnDemand: Self.builtInPanelEngagesOnDemand,
            frameRateKnown: frameRate != nil,
            videoCodecNeedsMasterSignaling: videoCodecNeedsMasterSignaling,
            // Audio is served as a rendition of its own, and a rendition lives in the master: any audio is a reason
            // to serve one where it plays.
            hasAudioRendition: carriesAudio,
            hasIFrameRendition: iFrameCandidate.isServed))
        return (useMaster, iFrameCandidate, stillsAvailable)
    }

    /// Built-in panels that engage EDR on demand once HDR content renders; the tvOS SDR-parked-
    /// panel failure mode (-11848) exists only behind the HDMI mode switch, so HDR-eligibility is
    /// the readiness signal on these platforms (Sodalite AE#88 retest: every HDR/DV film on iPhone
    /// routed media-direct and PiP subtitles silently never worked for them). macOS composites EDR
    /// per-window with no display mode switch, same physics as the iOS built-in panel; an SDR-only
    /// Mac reads ineligible and stays media-direct (#98).
    static let builtInPanelEngagesOnDemand: Bool = {
        #if os(iOS) || os(macOS)
        return true
        #else
        return false
        #endif
    }()

    /// Pure master-vs-media playlist routing decision (#4, #15, #63, #98). A master claiming HDR
    /// while the panel sits in SDR fails with -11848, so HDR/DV sources need a ready panel. SDR
    /// content is routable on any panel, so native subtitles force the master there.
    /// `builtInPanelEngagesOnDemand` (iOS/macOS) treats HDR-eligibility
    /// (`AVPlayer.eligibleForHDRPlayback`, passed as `displaySupportsHDR`) as panel readiness: the
    /// built-in panel engages EDR when HDR content renders, and an SDR-only device or route still
    /// reads ineligible and stays media-direct.
    ///
    /// P5 has no routing special-case. The single-variant `dvh1.05` master (no backward-compat
    /// brand) is accepted on a non-DV HDR10 panel and tonemapped by the system DV decoder (tvOS 26.5
    /// device test 2026-07-05, iOS 26.5 DrHurt #98). The removed always-media-direct P5 guard was
    /// compensating for an earlier engine deficiency that emitted a P5 master AVPlayer rejected with
    /// -11868 (2026-05-26); the engine now emits a well-formed one, so P5 follows the standard HDR
    /// gate: master on a ready HDR panel, media-direct on an SDR route (also the graceful path for
    /// DrHurt's external SDR monitor, #98). Do not reinstate an OS-version gate: the fault was the
    /// engine's own master, not a stricter platform codec filter.
    ///
    /// AE#458: `hasAudioRendition` is the same shape of reason as `hasNativeSubs`. An
    /// `EXT-X-MEDIA:TYPE=AUDIO` tag lives only in a master, and it is the only place AVFoundation reads
    /// an audio language from on an HLS asset, so a media-direct SDR source reports
    /// `languageCode == nil` and AVKit's audio menu reads "Not Specified" no matter what the segment's
    /// mdhd says. 6.60.0 wrote the rendition but did not route to it, so the label landed only where
    /// HDR or AE#187 had already forced the master; SDR H.264 (and SDR HEVC off tvOS) kept the old
    /// symptom (htrung14, tvOS transport bar, Apple TV 4K 3rd gen). Routing-safety still decides: an
    /// unready HDR panel is a -11848 rejection, and a language is not worth one.
    ///
    /// AE#682: `hasIFrameRendition` is a third reason of the same shape. `EXT-X-I-FRAME-STREAM-INF`
    /// lives only in a master, and it is likewise not worth a display rejection.
    ///
    /// #130: `frameRateKnown` gates PQ/HLG masters. AVPlayer filters a VIDEO-RANGE=PQ/HLG
    /// EXT-X-STREAM-INF that has no FRAME-RATE attribute out of the master at parse time and fails
    /// the item with NSURLErrorDomain -1002 without ever fetching media.m3u8 (byte-exact local
    /// repro; SDR variants are accepted without FRAME-RATE). Live MPEG-TS probes can leave the
    /// frame rate unknown even after the r_frame_rate fallback, so a frame-rate-less HDR source
    /// routes media-direct instead of serving a master AVPlayer provably rejects.
    static func resolveUseMasterPlaylist(
        videoRange: HLSVideoRange,
        effectiveDvMode: Bool,
        panelIsInHDRMode: Bool,
        displaySupportsHDR: Bool,
        hasNativeSubs: Bool,
        builtInPanelEngagesOnDemand: Bool,
        frameRateKnown: Bool,
        videoCodecNeedsMasterSignaling: Bool = false,
        hasAudioRendition: Bool = false,
        hasIFrameRendition: Bool = false
    ) -> Bool {
        let sourceIsHDR = videoRange != .sdr || effectiveDvMode
        let panelReadyForHDR = panelIsInHDRMode
            || (builtInPanelEngagesOnDemand && displaySupportsHDR)
        // #130: a PQ/HLG master without FRAME-RATE is unloadable regardless of panel state.
        let masterManifestViable = (videoRange == .sdr) || frameRateKnown
        guard masterManifestViable else { return false }
        // Gate on the ACTUAL videoRange, not sourceIsHDR: sourceIsHDR is inflated by
        // effectiveDvMode (a device DV capability) even for SDR content, which wrongly sent SDR
        // sources on DV-capable devices to media-direct, so the WebVTT rendition never appeared (#15).
        let routingSafeForMaster = (videoRange == .sdr) || panelReadyForHDR
        // AE#187: Apple TV HW builds an H.264 track from a bare media playlist + init, but HEVC needs
        // the codec advertised in a master's EXT-X-STREAM-INF CODECS. SDR HEVC otherwise routed
        // media-direct (below), leaving the device with no HEVC signaling -> tracks count=0 / -12848
        // before any media fetch (macOS / the Simulator build the track from the init hvcC and never
        // reproduce it). Forcing the master where it is routing-safe (SDR on any panel, HDR on a ready
        // one) closes that gap; the caller scopes the flag to tvOS + HEVC.
        if (hasNativeSubs || videoCodecNeedsMasterSignaling || hasAudioRendition || hasIFrameRendition)
            && routingSafeForMaster { return true }
        return sourceIsHDR && panelReadyForHDR
    }

    /// `true` when `start()` chose the master playlist (HDR/DV signaling). Read after `start()`.
    public private(set) var servingMasterPlaylist: Bool = false

    /// AE#849: serve the media playlist whatever the routing would choose. Set by the engine before
    /// `start()` / `serve(panelIsInHDRMode:)` on an audio switch whose session the display already
    /// refused the HDR master for (`MasterFallbackDecision.audioSwitchKeepsMediaRoute`).
    var keepsMediaPlaylistRoute = false

    /// `true` when the served variant advertises HDR (`VIDEO-RANGE` other than SDR), i.e. the master an
    /// external receiver rejects (#227). Read after `start()`.
    ///
    /// Deliberately NOT `sourceIsHDR` (`videoRange != .sdr || effectiveDvMode`): `effectiveDvMode` is a
    /// DEVICE capability, so that expression reads true for SDR content on any DV-capable iPhone or iPad and
    /// sent every such source down the HDR branch (device log 2026-07-27: `sourceIsHDR=true videoRange=sdr
    /// dvVariant=none`), which made the 5.23.8 AirPlay fix a no-op on exactly the devices it was written for.
    /// `resolveUseMasterPlaylist` carries the same warning for the same reason (#15).
    /// Internal on purpose: it feeds the engine's own AirPlay routing, and hosts read the consequence
    /// (`AetherEngine.nativeSubtitleRenditionsServed`) rather than the input.
    private(set) var servedSourceIsHDR: Bool = false

    /// The Dolby Vision rewrite the producer applies to every served video packet, nil when it serves the
    /// source's own profile. Read after `start()`; published as `AetherEngine.dolbyVisionConversion`.
    private(set) var servedDolbyVisionConversion: DolbyVisionConversion?

    /// The loopback server's media (single-variant) playlist URL, for the reactive master->media
    /// fallback (#98). Nil before the server starts.
    public var mediaPlaylistURL: URL? { server?.mediaPlaylistURL }

    /// The loopback server's master playlist URL, for the #35 cold-DV-master readiness gate that
    /// reloads the same master with a fresh asset while the DV/HDCP link warms. Nil before start.
    public var masterPlaylistURL: URL? { server?.playlistURL }

    /// HDR-preserving reduced master URL (#98), subtitle-preserving fallback for the #35 cold-DV gate.
    public var reducedHDRMasterPlaylistURL: URL? { server?.reducedHDRMasterPlaylistURL }

    /// True once the loopback server has handed out an init or media segment this session (#227). The
    /// AirPlay watchdog reads it: a receiver that refuses the manifest asks for playlists and never for a
    /// segment, which separates a refusal from a clock that is merely paused.
    public var hasServedMediaSegment: Bool { server?.hasServedMediaSegment ?? false }

    /// Flip the serving flag after the engine has reloaded the media playlist on a display rejection.
    func markServingMediaAfterFallback() {
        servingMasterPlaylist = false
        // AE#682: the rendition lives only in the master this session just stopped serving.
        tearDownIFrameRendition()
    }

    // MARK: - Diagnostics

    /// Point-in-time pipeline counters for the memory probe. Fields are uncoordinated snapshots
    /// (acceptable for a 30 s probe interval).
    public struct DiagnosticStats {
        public let segmentCacheCount: Int
        public let segmentCacheBytes: Int
        public let producerPacketsWritten: Int
        public let avioBytesFetched: Int64
        public let audioFifoSamples: Int
        /// Bytes in AudioBridge FIFO + swr delay; zero for stream-copy/video-only. Linear growth = bridge leak.
        public let audioBridgeFifoBytes: Int
        public let audioBridgeSwrBytes: Int
        public var audioBridgeTotalBytes: Int { audioBridgeFifoBytes + audioBridgeSwrBytes }
        /// Cumulative bytes emitted by the MP4SegmentMuxer; muxer-leak attribution baseline. Spans muxer
        /// rotations and producer replacements (AE#443), or a session with a recovery in it would read
        /// as a drop to near zero exactly where the leak question is interesting.
        public let muxerLifetimeFragmentBytes: Int
        public let muxerFragmentCuts: Int
        /// Active server connections; steady 1-3 = normal AVPlayer keep-alive; rising = CFNetwork leak.
        public let serverConnectionCount: Int
        /// Lifetime bytes sent (Data writeAll + sendfile). Should track `muxerLifetimeFragmentBytes`
        /// modulo init.mp4 + playlist; divergence = drop or duplicate.
        public let serverLifetimeBytesSent: Int
        /// Of `serverLifetimeBytesSent`, bytes via sendfile(2) fast path. Used to verify fast path is taken.
        public let serverSendfileBytesSent: Int
        /// av_packet_alloc minus av_packet_free (PacketBalanceTracker). Steady low = balanced; growth = leak.
        public let packetsAlive: Int
        public let packetsTotalAllocs: Int
        /// Producer restarts in the session (0 for non-restart sessions), across every producer the
        /// session has had. Live sessions read 0 by construction: they replace the producer instead.
        public let producerRestartCount: Int
        /// Most recent audio-gate vs video-gate gap in source-clock ms; 0 until first audio gate.
        public let lastAVGapMs: Double
        /// Lifetime HTTP requests served (playlist + init + segment fetches).
        public let serverRequestCount: Int
    }

    // MARK: - Session-lifetime counters

    /// Totals folded off the subsystems a recovery REPLACES.
    ///
    /// AE#443: every counter below used to be read straight off the live instance, so a live reopen
    /// (fresh demuxer, fresh producer) restarted all of them from zero at exactly the moment a session
    /// became worth measuring, and a telemetry line carried no sign that it had. The scope of a
    /// session-lifetime number is the SESSION, which is this object; it cannot live on the parts the
    /// session rebuilds under itself.
    ///
    /// Folded once a swap is FINAL (the live reopen puts its old demuxer back when the producer build
    /// fails, and folding at the swap would then count one reader twice) and always after the successor
    /// is installed, so the ordering can undercount for the microseconds in between but never double
    /// count. The producer fold also stays off `restartLock`: its byte total is read through the
    /// producer's own `stateLock`, while the demuxer's counter is a leaf.
    private let retiredCounterLock = NSLock()
    private var retiredDemuxerBytes: Int64 = 0
    private var retiredMuxedBytes: Int = 0
    private var retiredProducerRestarts: Int = 0

    /// Fold a replaced producer's totals into the session's. Call once per outgoing instance, before
    /// stopping it (`stop()` releases the muxer its byte total is read from).
    func retireProducer(_ old: HLSSegmentProducer?) {
        guard let old else { return }
        let bytes = old.muxerLifetimeFragmentBytes
        let restarts = old.restartCount
        retiredCounterLock.lock()
        retiredMuxedBytes &+= bytes
        retiredProducerRestarts &+= restarts
        retiredCounterLock.unlock()
    }

    /// Fold a replaced demuxer's fetched bytes into the session's. Call before closing it.
    func retireDemuxer(_ old: Demuxer?) {
        guard let old else { return }
        let bytes = old.avioBytesFetched
        retiredCounterLock.lock()
        retiredDemuxerBytes &+= bytes
        retiredCounterLock.unlock()
    }

    private func retiredTotals() -> (demuxerBytes: Int64, muxedBytes: Int, producerRestarts: Int) {
        retiredCounterLock.lock()
        defer { retiredCounterLock.unlock() }
        return (retiredDemuxerBytes, retiredMuxedBytes, retiredProducerRestarts)
    }

    // MARK: - Live telemetry forwarders

    // All forwarders snapshot the subsystem ref under `restartLock` first (stop()/restart
    // nil these under that lock; lock-free reads were an ARC data race). Counter reads
    // happen after unlock so telemetry never blocks a restart.

    /// Snapshot subsystem refs under `restartLock`.
    private func subsystemSnapshot() -> (
        producer: HLSSegmentProducer?, cache: SegmentCache?,
        server: HLSLocalServer?, demuxer: Demuxer?, audioBridge: (any AudioTranscodingBridge)?
    ) {
        restartLock.lock()
        defer { restartLock.unlock() }
        return (producer, cache, server, demuxer, audioBridge)
    }

    /// AE#514: bytes of the played streams by presentation time, fed by every producer of the session
    /// (initial, seek restart, live reopen, revive), read by the telemetry sampler at the playhead.
    let playedMediaLedger = PlayedMediaLedger()

    /// Bytes this session pulled from the SOURCE, across every demuxer it has had (see
    /// `retiredDemuxerBytes`). Not the same link as `LiveTelemetry.networkTransferredBytes`, which on
    /// the native path counts what AVPlayer pulled from the loopback server.
    var demuxerBytesFetched: Int64 {
        (subsystemSnapshot().demuxer?.avioBytesFetched ?? 0) + retiredTotals().demuxerBytes
    }
    var segmentCacheTotalBytes: Int { subsystemSnapshot().cache?.totalBytes ?? 0 }
    /// On-disk segment bytes (freshly stat-ed). Used by `aetherctl live --report-cache-bytes`.
    var segmentCacheDiskBytes: Int64 { subsystemSnapshot().cache?.diskBytes() ?? 0 }

    /// Spans currently backed by the VOD segment cache, on the **playlist axis** the plan is cut on,
    /// which is the axis `segmentIndexForPlaylistTime` reads and NOT the 0-based display axis the
    /// engine publishes. `AetherEngine` folds them onto that axis the same way it folds a scrub
    /// target (#38); naming the axis here is what keeps the fold from being forgotten. Live returns
    /// no claim: its DVR history is a different contract, expressed by `seekableLiveRange` at the
    /// engine layer.
    ///
    /// The cache read stays OUTSIDE `restartLock` like every other forwarder above: the plan is a
    /// COW array, so snapshotting it is a retain, and nesting the cache's condition under the
    /// restart lock would add a lock order this file does not otherwise have.
    func residentPlaylistRanges() -> [ClosedRange<Double>] {
        restartLock.lock()
        let live = isLiveSession
        let cacheRef = cache
        let plan = segmentPlan
        restartLock.unlock()
        guard !live, let cacheRef, !plan.isEmpty else { return [] }
        return cacheRef.residentIndexRanges().compactMap { indexes in
            guard indexes.lowerBound >= 0, indexes.upperBound < plan.count else { return nil }
            let lower = plan[indexes.lowerBound].startSeconds
            let upperIndex = indexes.upperBound + 1
            let upper = upperIndex < plan.count
                ? plan[upperIndex].startSeconds
                : plan[indexes.upperBound].startSeconds + plan[indexes.upperBound].durationSeconds
            return lower...upper
        }
    }

    /// Seconds of contiguous *safe* content ahead of the playhead on the media-playlist axis: what the
    /// consumer already holds, plus what sits contiguously above it in the disk SegmentCache (which is
    /// what the Network Buffer setting controls). Returns 0 when nothing is cached ahead or the plan is
    /// empty.
    ///
    /// The frontier walk is anchored at `max(playhead, consumer fetch target)`, see
    /// `SegmentCache.contiguousForwardFrontier(fromPlayhead:)`: the cache retains from
    /// `fetchTarget - backwardWindow` upward, so under an opt-in whole-source prefetch the playhead's own
    /// segment is evicted and a playhead-anchored walk collapsed to 0 while the whole band was resident
    /// (#207 follow-up). A frontier below the playhead still reports 0, which keeps the #54 contract that
    /// the frontier never trails the rendered frame.
    ///
    /// The target anchor holds only inside the consumer's current fetch sequence; a seek ends it, since
    /// `declareTarget` lands at the destination while `currentTime()` still reports the position the seek
    /// left, and the target would otherwise measure the band at the destination against that stale
    /// playhead. What remains is bounded rather than seek-sized: a scrub shorter than the backward window
    /// stays inside the sequence, so a tick or two around it can still anchor on the old target, and the
    /// error is at most that window.
    ///
    /// segmentIndexForPlaylistTime and the plan read each take restartLock briefly and sequentially
    /// (no nesting); a plan rebuilt between them at worst yields one transiently wrong tick, acceptable
    /// for a visual bar.
    func contiguousForwardReadAheadSeconds(playlistSeconds: Double) -> Double {
        guard let cache = subsystemSnapshot().cache else { return 0 }
        let playheadIdx = segmentIndexForPlaylistTime(playlistSeconds)
        let frontier = cache.contiguousForwardFrontier(fromPlayhead: playheadIdx)
        guard frontier >= playheadIdx else { return 0 }
        restartLock.lock()
        defer { restartLock.unlock() }
        guard frontier >= 0, frontier < segmentPlan.count else { return 0 }
        let seg = segmentPlan[frontier]
        return max(0, (seg.startSeconds + seg.durationSeconds) - playlistSeconds)
    }
    /// Producer restarts in this SESSION, across every producer it has had. A single producer restarts
    /// at most once (it is built for one aim and replaced for the next), so before AE#443 this read as
    /// a 0/1 flag on the current instance, and on live it read 0 always: the live paths replace the
    /// producer rather than restarting one, and `performRestart` bails on the empty live segment plan.
    var producerRestartCount: Int {
        (subsystemSnapshot().producer?.restartCount ?? 0) + retiredTotals().producerRestarts
    }
    /// Muxed fragment bytes for the SESSION: across muxer rotations (folded inside the producer) and
    /// across producer replacements (folded here). A leak baseline has to outlive both, or it reads as
    /// a drop to zero on the one session that had a recovery in it.
    var muxedBytesLifetime: Int {
        (subsystemSnapshot().producer?.muxerLifetimeFragmentBytes ?? 0) + retiredTotals().muxedBytes
    }
    var serverLifetimeBytesSent: Int { subsystemSnapshot().server?.lifetimeBytesSent ?? 0 }
    var serverRequestCount: Int { subsystemSnapshot().server?.requestCount ?? 0 }

    /// Live segment count. >= 2 = startup cushion released, AVPlayer has real content.
    var liveSegmentCount: Int {
        guard isLiveSession else { return 0 }
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.segmentCount ?? 0
    }

    var audioBridgeLiveBytes: Int { subsystemSnapshot().audioBridge?.liveBytes.totalBytes ?? 0 }
    var audioBridgeOutputBytesLifetime: Int64 { subsystemSnapshot().audioBridge?.outputBytesLifetime ?? 0 }
    var objectAudioActivity: ObjectAudioActivity? { subsystemSnapshot().audioBridge?.objectAudioActivity }
    var lastAVGapMs: Double { subsystemSnapshot().producer?.lastAVGapMs ?? 0 }

    /// Current route-aware cache contract. Byte fields come from the cache ledger, not segment-count
    /// estimates. The close-completion snapshot is also delivered through
    /// `onSessionCacheStatusChanged` because the cache object is intentionally detached at stop.
    public func sessionCacheStatus() -> SessionCacheStatus {
        restartLock.lock()
        let cache = self.cache
        let budget = sessionCacheBaseEffectiveBytes
        let safetyLimit = sessionCacheVolumeSafetyLimitBytes
        restartLock.unlock()
        if let cache {
            return cache.status(
                route: .loopbackFMP4,
                requestedBudgetBytes: requestedSessionCacheBudgetBytes.map { max(0, $0) },
                baseEffectiveBudgetBytes: budget,
                volumeSafetyLimitBytes: safetyLimit,
                capability: isLiveSession ? .unsupported : .active
            )
        }
        return SessionCacheStatus(
            route: .loopbackFMP4, capability: .inactive,
            requestedBudgetBytes: requestedSessionCacheBudgetBytes.map { max(0, $0) },
            volumeSafetyLimitBytes: safetyLimit,
            baseEffectiveBudgetBytes: budget, playbackSafeFloorBytes: 0,
            effectiveBudgetBytes: budget, currentResidentBytes: 0,
            currentForwardBytes: 0, forwardWindowSegments: forwardWindowSegments,
            backwardWindowSegments: SegmentCache.defaultBackwardWindow,
            producerParked: false, evictionCount: 0,
            hardWindowFloorExceeded: false, cleanupReason: nil, cleanupResult: .notRun,
            lastFailure: nil
        )
    }

    public func diagnosticStats() -> DiagnosticStats {
        let subs = subsystemSnapshot()
        let abLive = subs.audioBridge?.liveBytes
        return DiagnosticStats(
            segmentCacheCount: subs.cache?.count ?? 0,
            segmentCacheBytes: subs.cache?.totalBytes ?? 0,
            producerPacketsWritten: subs.producer?.packetsWrittenCount ?? 0,
            avioBytesFetched: subs.demuxer?.avioBytesFetched ?? 0,
            audioFifoSamples: subs.audioBridge?.fifoSampleCount ?? 0,
            audioBridgeFifoBytes: abLive?.fifoBytes ?? 0,
            audioBridgeSwrBytes: abLive?.swrDelayBytes ?? 0,
            muxerLifetimeFragmentBytes: subs.producer?.muxerLifetimeFragmentBytes ?? 0,
            muxerFragmentCuts: subs.producer?.muxerFragmentCuts ?? 0,
            serverConnectionCount: subs.server?.activeConnectionCount ?? 0,
            serverLifetimeBytesSent: subs.server?.lifetimeBytesSent ?? 0,
            serverSendfileBytesSent: subs.server?.lifetimeSendfileBytes ?? 0,
            packetsAlive: PacketBalanceTracker.alive,
            packetsTotalAllocs: PacketBalanceTracker.totalAllocs,
            producerRestartCount: subs.producer?.restartCount ?? 0,
            lastAVGapMs: subs.producer?.lastAVGapMs ?? 0,
            serverRequestCount: subs.server?.requestCount ?? 0
        )
    }

    /// init.mp4 + segment bytes for a scrub thumbnail (synchronous local I/O; call off-main).
    /// Live and VOD: reads already-produced SegmentCache bytes over the single playback
    /// connection, never opening a second one (#106). Returns nil if there is no provider
    /// or the file was evicted between lookup and read. `segmentIndex` enables extractor reuse.
    /// AE#441: the oldest resident, contiguously-playable position in output seconds, or nil when the
    /// session has no provider yet. The engine intersects this with the DVR window so the advertised
    /// rewind range is what the cache actually holds.
    func residentFloorOutputSeconds() -> Double? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.residentFloorOutputSeconds()
    }

    /// AE#446 round 4: the newest resident position in output seconds, the other end of the floor above.
    func residentCeilingOutputSeconds() -> Double? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.residentCeilingOutputSeconds()
    }

    /// AE#442: the sealed live TARGETDURATION, or nil before the first playlist build.
    func sealedLiveTargetDurationSeconds() -> Int? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        return prov?.sealedLiveTargetDurationSeconds
    }

    /// A resident segment a scrub still can decode from. Resolving it reads nothing, so an extractor
    /// LRU hit costs no I/O; `makeReader()` maps the segment file rather than reading it into the heap
    /// (audit SEG-2). SegmentCache only ever replaces or unlinks a segment file, never rewrites it in
    /// place, so a mapping stays valid for as long as the reader holds it.
    struct ScrubThumbnailSource: Sendable {
        let segmentIndex: Int
        let startSeconds: Double
        let durationSeconds: Double
        let carriedOffset: Double?
        let identity: String
        let initData: Data
        let segmentURL: URL

        func makeReader() -> DataIOReader? {
            guard let segment = try? Data(contentsOf: segmentURL, options: .alwaysMapped) else { return nil }
            return DataIOReader(parts: [initData, segment])
        }
    }

    func scrubThumbnailSource(atSeconds seconds: Double) -> ScrubThumbnailSource? {
        restartLock.lock()
        let prov = provider
        restartLock.unlock()
        guard let prov else { return nil }
        guard let seg = prov.thumbnailSegment(atSeconds: seconds),
              let initData = prov.peekInitSegment() else { return nil }
        anchorShiftLock.lock()
        let carried = isLiveSession ? 0 : carriedSecondsByIndex[seg.index]
        anchorShiftLock.unlock()
        // The cache replaces/unlinks immutable files. An index alone cannot
        // identify bytes after a same-session re-cut/restart rewrites that index.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: seg.fileURL.path),
              let volume = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        let identity = "\(volume.uint64Value):\(inode.uint64Value):\(size.uint64Value):\(modified.timeIntervalSince1970):" + initData.base64EncodedString()
        return ScrubThumbnailSource(segmentIndex: seg.index, startSeconds: seg.startSeconds, durationSeconds: seg.durationSeconds,
                                    carriedOffset: carried, identity: identity,
                                    initData: initData, segmentURL: seg.fileURL)
    }

    struct CompositorPreviewFile: Sendable {
        let url: URL
        /// Output-axis seconds of the keyframe the file shows.
        let startSeconds: Double
        let durationSeconds: Double
    }

    /// A single-keyframe fMP4 for the resident segment holding `seconds` (playlist/output axis), built
    /// once per segment identity and kept for the last `compositorPreviewFileLimit` segments. Nil
    /// for sources a still covers and live sessions. A segment that is not resident falls through to
    /// `sourceKeyframePreviewFile`.
    func compositorPreviewFile(atSeconds seconds: Double) -> CompositorPreviewFile? {
        guard previewNeedsCompositor, !isLiveSession else { return nil }
        compositorPreviewLock.lock()
        compositorPreviewRequest &+= 1
        let request = compositorPreviewRequest
        compositorPreviewLock.unlock()
        guard let source = scrubThumbnailSource(atSeconds: seconds) else {
            return sourceKeyframePreviewFile(atSeconds: seconds, request: request)
        }
        compositorPreviewLock.lock()
        if let hit = compositorPreviewFiles.firstIndex(where: { $0.identity == source.identity }) {
            let entry = compositorPreviewFiles.remove(at: hit)
            compositorPreviewFiles.append(entry)
            compositorPreviewLock.unlock()
            return entry.file
        }
        compositorPreviewSerial += 1
        let serial = compositorPreviewSerial
        compositorPreviewLock.unlock()

        restartLock.lock()
        let directory = cache?.sessionDir.appendingPathComponent("preview", isDirectory: true)
        let tag = savedVideoConfig?.codecTagOverride
        let color = savedVideoConfig?.colorOverride
        restartLock.unlock()
        guard let directory else { return nil }
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil,
              let built = CompositorPreviewBuilder.build(
                initData: source.initData, segmentURL: source.segmentURL,
                durationSeconds: source.durationSeconds, codecTagOverride: tag, colorOverride: color,
                stagingDir: staging) else { return nil }
        let url = directory.appendingPathComponent("seg\(source.segmentIndex)-\(serial).mp4")
        guard (try? built.file.write(to: url)) != nil else { return nil }
        let file = CompositorPreviewFile(url: url, startSeconds: source.startSeconds,
                                         durationSeconds: source.durationSeconds)
        compositorPreviewLock.lock()
        compositorPreviewFiles.append((source.identity, file))
        var evicted: [URL] = []
        while compositorPreviewFiles.count > Self.compositorPreviewFileLimit {
            evicted.append(compositorPreviewFiles.removeFirst().file.url)
        }
        compositorPreviewLock.unlock()
        for old in evicted { try? FileManager.default.removeItem(at: old) }
        return file
    }

    /// The plan entry holding `seconds`: the last one starting at or before it. Seconds before the
    /// first entry belong to it, a gap past the last one's end to nothing.
    nonisolated static func planIndex(containing seconds: Double, in plan: [Segment]) -> Int? {
        guard seconds.isFinite, let first = plan.first else { return nil }
        if seconds < first.startSeconds { return 0 }
        var low = 0, high = plan.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if plan[mid].startSeconds <= seconds { low = mid } else { high = mid - 1 }
        }
        let entry = plan[low]
        return seconds < entry.startSeconds + max(entry.durationSeconds, 0) || low < plan.count - 1 ? low : nil
    }

    /// The preview for a position outside the resident window: the keyframe that opens its plan
    /// segment, read off the source as the I-frame rendition reads it (`IFrameKeyframeReader`), wrapped
    /// with the session's own sample entry, `dvcC` and `colr`. Nothing is decoded; the compositor
    /// colours it like the resident preview. Skipped when a newer request arrived meanwhile.
    private func sourceKeyframePreviewFile(atSeconds seconds: Double, request: Int) -> CompositorPreviewFile? {
        restartLock.lock()
        let plan = segmentPlan
        let directory = cache?.sessionDir.appendingPathComponent("preview", isDirectory: true)
        let allowed = previewReadsSource
        restartLock.unlock()
        guard allowed, let directory, let index = Self.planIndex(containing: seconds, in: plan) else { return nil }
        let identity = "plan:\(index)"
        compositorPreviewLock.lock()
        if let hit = compositorPreviewFiles.firstIndex(where: { $0.identity == identity }) {
            let entry = compositorPreviewFiles.remove(at: hit)
            compositorPreviewFiles.append(entry)
            compositorPreviewLock.unlock()
            return entry.file
        }
        compositorPreviewLock.unlock()

        guard let (keyframes, builder) = previewKeyframeSource(plan: plan, directory: directory) else { return nil }
        let isStale: () -> Bool = { [weak self] in
            guard let self else { return true }
            self.compositorPreviewLock.lock()
            defer { self.compositorPreviewLock.unlock() }
            return self.compositorPreviewRequest != request
        }
        guard let payload = keyframes.keyframePayload(at: index, isStale: isStale) else { return nil }
        let segment = plan[index]
        guard let built = builder.build(payload: payload, durationSeconds: segment.durationSeconds) else {
            return nil
        }

        compositorPreviewLock.lock()
        compositorPreviewSerial += 1
        let serial = compositorPreviewSerial
        compositorPreviewLock.unlock()
        let url = directory.appendingPathComponent("plan\(index)-\(serial).mp4")
        guard (try? (built.initSegment + built.fragment).write(to: url)) != nil else { return nil }
        let file = CompositorPreviewFile(url: url, startSeconds: segment.startSeconds,
                                         durationSeconds: segment.durationSeconds)
        compositorPreviewLock.lock()
        compositorPreviewFiles.append((identity, file))
        var evicted: [URL] = []
        while compositorPreviewFiles.count > Self.compositorPreviewFileLimit {
            evicted.append(compositorPreviewFiles.removeFirst().file.url)
        }
        compositorPreviewLock.unlock()
        for old in evicted { try? FileManager.default.removeItem(at: old) }
        return file
    }

    /// The keyframe reader and builder behind `sourceKeyframePreviewFile`, made on the first request
    /// that needs them and torn down by `stop()`, which drains a read in flight before it frees the
    /// codec parameters the builder reads.
    private func previewKeyframeSource(plan: [Segment], directory: URL)
        -> (IFrameRendition, PreviewKeyframeBuilder)? {
        restartLock.lock()
        defer { restartLock.unlock() }
        if let previewKeyframes, let previewKeyframeBuilder { return (previewKeyframes, previewKeyframeBuilder) }
        guard previewReadsSource, let cfg = savedVideoConfig, !plan.isEmpty else { return nil }
        let staging = directory.appendingPathComponent("source-staging", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil
        else { return nil }
        let builder = PreviewKeyframeBuilder(IFrameFragmentBuilder(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: cfg.codecpar, timeBase: cfg.timeBase,
                codecTagOverride: cfg.codecTagOverride, doviConfig: cfg.doviConfig,
                colorOverride: cfg.colorOverride, extradataOverride: cfg.extradataOverride,
                convertsAnnexBSamples: cfg.convertsAnnexBSamples,
                nalFramingLatch: cfg.nalFramingLatch),
            stagingDir: staging))
        let entries = plan.map {
            IFrameRendition.Entry(startPts: $0.startPts, startSeconds: $0.startSeconds,
                                  durationSeconds: $0.durationSeconds)
        }
        guard let keyframes = makeKeyframeRendition(
            entries: entries, cache: IFramePayloadCache(),
            format: .keyframes, buildFragment: { _, _, _ in nil }) else { return nil }
        previewKeyframes = keyframes
        previewKeyframeBuilder = builder
        EngineLog.emit("[HLSVideoEngine] compositor preview: source keyframe reader ready "
                       + "(segments=\(plan.count))", category: .session)
        return (keyframes, builder)
    }

    /// The whole resident segment holding `seconds` as a video-only fMP4, and how far past the
    /// segment's first frame `seconds` lies: what the held picture of an audio switch shows for a
    /// source only the compositor colours. One file at a time; building the next removes the previous.
    func compositorHoldFile(atSeconds seconds: Double) -> (url: URL, offsetSeconds: Double)? {
        guard previewNeedsCompositor, !isLiveSession, seconds.isFinite,
              let source = scrubThumbnailSource(atSeconds: seconds) else { return nil }
        restartLock.lock()
        let directory = cache?.sessionDir.appendingPathComponent("preview", isDirectory: true)
        let tag = savedVideoConfig?.codecTagOverride
        let color = savedVideoConfig?.colorOverride
        restartLock.unlock()
        guard let directory else { return nil }
        let staging = directory.appendingPathComponent("hold-staging", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil,
              let built = CompositorPreviewBuilder.build(
                initData: source.initData, segmentURL: source.segmentURL,
                durationSeconds: source.durationSeconds, codecTagOverride: tag, colorOverride: color,
                stagingDir: staging, content: .wholeSegment) else { return nil }
        compositorPreviewLock.lock()
        compositorPreviewSerial += 1
        let serial = compositorPreviewSerial
        let previous = compositorHoldURL
        compositorPreviewLock.unlock()
        let url = directory.appendingPathComponent("hold\(source.segmentIndex)-\(serial).mp4")
        guard (try? built.file.write(to: url)) != nil else { return nil }
        compositorPreviewLock.lock()
        compositorHoldURL = url
        compositorPreviewLock.unlock()
        if let previous { try? FileManager.default.removeItem(at: previous) }
        let offset = min(max(0, seconds - source.startSeconds + built.compositionDelaySeconds), source.durationSeconds)
        return (url, offset)
    }

    /// Preserve the original zero-argument function type for hosts storing a stop callback.
    public func stop() { stop(reason: .sessionStopped) }

    public func stop(reason: SessionCacheCleanupReason) {
        preparedServe = nil
        #if DualLayerDolbyVision
        felTap?.close()
        #endif
        cancelResidentRangesPublish()
        // Sodalite#32: drop the tap routes first so a pump still draining its last packets no-ops
        // instead of decoding into stores being torn down.
        subtitleTapLock.lock()
        subtitleTapRoutes.removeAll()
        subtitleTapExcludedStreams.removeAll()
        subtitleTapLock.unlock()
        // Snapshot resources under the lock, then clear instance state and hand them to a
        // detached cleanup task (#10: SwiftUI releases @State on main; detach avoids a 3 s freeze
        // while the pump exits a parked HTTP byte-range read).
        restartLock.lock()
        sessionEpoch &+= 1
        retentionClaim?.release()
        retentionClaim = nil
        let p = producer
        producer = nil
        liveRecoveryProducer = nil
        let s = server
        server = nil
        let c = cache
        cache = nil
        let audioRendition = audioRenditionCache
        audioRenditionCache = nil
        let cacheStatusCallback = onSessionCacheStatusChanged
        let cacheRequestedBudget = requestedSessionCacheBudgetBytes.map { max(0, $0) }
        let cacheEffectiveBudget = sessionCacheBaseEffectiveBytes
        let cacheVolumeSafetyLimit = sessionCacheVolumeSafetyLimitBytes
        let cacheCapability: SessionCacheCapability = isLiveSession ? .unsupported : .active
        compositorPreviewLock.lock()
        compositorPreviewFiles.removeAll()
        compositorHoldURL = nil
        compositorPreviewLock.unlock()
        let ab = audioBridge
        audioBridge = nil
        let d = demuxer
        demuxer = nil
        let sd = sideAudioDemuxer
        sideAudioDemuxer = nil
        // Preopened demuxer: nil if start() consumed it; close is idempotent.
        let preopened = preopenedDemuxer
        preopenedDemuxer = nil
        let prov = provider
        provider = nil
        let iFrames = iFrameRendition
        iFrameRendition = nil
        let previewFrames = previewKeyframes
        previewKeyframes = nil
        let previewBuilder = previewKeyframeBuilder
        previewKeyframeBuilder = nil
        closeUnusedCustomKeyframeReader()
        keyframeReaderLock.lock()
        let keyframes = keyframeReader
        keyframeReader = nil
        keyframeReaderLock.unlock()
        // Ends a read in flight, so the shutdowns below do not wait it out.
        keyframes?.interrupt()
        sourceStillLock.lock()
        let stillDecoder = sourceStillDecoder
        sourceStillDecoder = nil
        sourceStillTimeline = nil
        sourceStillLock.unlock()
        savedVideoConfig = nil
        sourceVideoConfig = nil
        overlayPlaceholder = nil
        overlayDecodeTap?.close()
        overlayDecodeTap = nil
        savedAudioConfig = nil
        let ownedParams = ownedCodecParams
        ownedCodecParams = []
        let reopening = reopenDemuxer
        reopenDemuxer = nil
        let restartReopening = restartReopenDemuxer
        restartReopenDemuxer = nil
        // #199: factory-vended ingest reader feeding the current demuxer; session-owned, closed here.
        let reopenReader = reopenCustomReader
        reopenCustomReader = nil
        segmentPlan = []
        planKeyframePts = []
        restartLock.unlock()
        reopening?.markClosed()
        // The restart that opened it closes it once it sees the epoch moved.
        restartReopening?.markClosed()
        // Close before waitForFinish: cancels the reader's FIFO so a pump parked in a blocking
        // custom-IO read unblocks (mirrors markClosed for URL demuxers).
        reopenReader?.close()

        p?.stop()

        // Wake LL-HLS blocking-reload waiters; without this they sleep out their full 18-30 s timeout.
        prov?.cancelWaiters()
        prov?.setIFrameSource(nil)

        // markClosed unblocks a live pump parked in the AVIO reconnect loop (exits on closed flag,
        // not the producer cancel flag). Without this, waitForFinish blocks ~3 s while reconnects
        // storm against a superseded transcode, polluting the next session.
        d?.markClosed()
        sd?.markClosed()
        preopened?.markClosed()

        // Detached cleanup: producer waitForFinish must precede demuxer/cache/server close
        // (pump accesses them during unwind). ownedParams released last (pump read them).
        BlockingWork.detached {
            iFrames?.shutdown()
            previewFrames?.shutdown()
            keyframes?.close()
            stillDecoder?.close()
            previewBuilder?.close()
            _ = p?.waitForFinish(timeout: 3.0)
            s?.stop()
            _ = audioRendition?.close(reason: reason)
            if let c {
                _ = c.close(reason: reason)
                cacheStatusCallback?(c.status(
                    route: .loopbackFMP4,
                    requestedBudgetBytes: cacheRequestedBudget,
                    baseEffectiveBudgetBytes: cacheEffectiveBudget,
                    volumeSafetyLimitBytes: cacheVolumeSafetyLimit,
                    capability: cacheCapability
                ))
            }
            ab?.close()
            d?.close()
            sd?.close()
            preopened?.close()
            _ = ownedParams
        }
    }

    deinit {
        stop(reason: .sessionStopped)
    }

    // MARK: - I-frame rendition (AE#682)

    /// The keyframes are always served with their own range, so the main player scans on them in HDR. An HDR
    /// source adds the SDR HEVC stills tvOS requires (`IFrameStillBuilder`): AVKit's scrub thumbnail player is
    /// capped at SDR and takes the lowest video range on offer. A source with no keyframe list
    /// (`Timeline.stills`) serves those SDR stills alone, one a second, each the picture at its time. A software
    /// overlay session serves placeholder pictures, so its keyframes are stills too, in the variant's range
    /// (`servedRange`): the main player of an HDR session drops an SDR tier, and scans on nothing then.
    private func makeIFrameRendition(plan: [Segment], timeline: IFrameRenditionEligibility.Timeline,
                                     cache segmentCache: SegmentCache, sourceIsHDR: Bool,
                                     servedRange: HLSVideoRange) -> IFrameRendition? {
        guard let cfg = savedVideoConfig, let source = sourceVideoConfig, !plan.isEmpty else { return nil }
        let par = source.codecpar.pointee
        // The decoder reads the samples as the session serves them: Annex B ones with the source's own
        // extradata, length-prefixed ones with the record the muxer writes.
        func makeStillBuilder(maxWidth: Int = IFrameStillBuilder.defaultWidth,
                              destination: ColorAttachments.Tags = StillRenderer.sdr) -> IFrameStillBuilder? {
            guard let size = IFrameStillBuilder.size(
                codedWidth: Int(par.width), codedHeight: Int(par.height),
                sarNum: par.sample_aspect_ratio.num, sarDen: par.sample_aspect_ratio.den, maxWidth: maxWidth) else { return nil }
            return IFrameStillBuilder(
                decoder: FrameDecodeContext(streamParameters: source.codecpar, timeBase: source.timeBase,
                                            extradata: source.convertsAnnexBSamples ? nil : source.extradataOverride),
                width: size.width, height: size.height, destination: destination)
        }
        func stillsFormat(_ still: IFrameStillBuilder, entries: [IFrameRendition.Entry],
                          range: HLSVideoRange = .sdr) -> IFrameRenditionFormat {
            let durations = entries.map(\.durationSeconds).filter { $0 > 0 }
            let shortest = durations.min() ?? 1
            let mean = durations.isEmpty ? 1 : durations.reduce(0, +) / Double(durations.count)
            return .stills(width: still.width, height: still.height, codecs: still.codecs,
                           bandwidth: IFrameStillBuilder.bandwidth(shortestSegmentSeconds: shortest),
                           averageBandwidth: IFrameStillBuilder.averageBandwidth(meanSegmentSeconds: mean),
                           videoRange: range)
        }
        func stillBuild(_ still: IFrameStillBuilder) -> (Data, Int, IFrameRendition.Entry) -> IFrameFragmentBuilder.Output? {
            { payload, index, entry in
                still.build(payload: payload, index: index, startSeconds: entry.startSeconds,
                            durationSeconds: entry.durationSeconds)
                    .map { IFrameFragmentBuilder.Output(initSegment: $0.initSegment, fragment: $0.fragment) }
            }
        }
        if timeline == .stills {
            guard let still = makeStillBuilder() else { return nil }
            let entries = Self.denseStillEntries(plan: plan, timeBaseSeconds: sourceVideoTbSeconds)
            // The read is the picture's run, decoded and encoded on the rendition's queue, so what the cache
            // keeps per entry is the still itself.
            return makeKeyframeRendition(
                entries: entries, cache: IFramePayloadCache(), format: stillsFormat(still, entries: entries),
                read: { reader, entry in reader.pictureRun(atPts: entry.startPts).flatMap { still.encode(run: $0) } },
                buildFragment: { sample, index, entry in
                    let built = still.output(sample: sample, index: index, startSeconds: entry.startSeconds,
                                             durationSeconds: entry.durationSeconds)
                    return IFrameFragmentBuilder.Output(initSegment: built.initSegment, fragment: built.fragment)
                })
        }

        let entries = Self.iFrameEntries(plan: plan, keyframes: planKeyframePts,
                                         timeBaseSeconds: sourceVideoTbSeconds)
        var companion: (format: IFrameRenditionFormat,
                        build: (Data, Int, IFrameRendition.Entry) -> IFrameFragmentBuilder.Output?)?
        if sourceIsHDR, let still = makeStillBuilder() {
            companion = (stillsFormat(still, entries: entries), stillBuild(still))
        }
        if let placeholder = overlayPlaceholder {
            guard let scan = makeStillBuilder(maxWidth: Self.overlayScanStillWidth, destination: placeholder.tags) else { return nil }
            return makeKeyframeRendition(
                entries: entries, cache: IFramePayloadCache(),
                format: stillsFormat(scan, entries: entries, range: servedRange), buildFragment: stillBuild(scan),
                companion: companion)
        }
        // Fragments are muxed in memory and payloads cached in memory: nothing here is written to disk, so
        // the directory below is only the name the muxer is given, never created.
        let staging = segmentCache.sessionDir.appendingPathComponent("iframes", isDirectory: true)
        let keyframeBuilder = IFrameFragmentBuilder(
            video: MP4SegmentMuxer.VideoConfig(
                codecpar: cfg.codecpar, timeBase: cfg.timeBase,
                codecTagOverride: cfg.codecTagOverride, doviConfig: cfg.doviConfig,
                colorOverride: cfg.colorOverride, extradataOverride: cfg.extradataOverride,
                convertsAnnexBSamples: cfg.convertsAnnexBSamples,
                nalFramingLatch: cfg.nalFramingLatch, stereo: cfg.stereo),
            stagingDir: staging)
        let buildKeyframe: (Data, Int, IFrameRendition.Entry) -> IFrameFragmentBuilder.Output? = { payload, index, entry in
            keyframeBuilder.build(payload: payload, index: index,
                                  startSeconds: entry.startSeconds, durationSeconds: entry.durationSeconds)
        }
        return makeKeyframeRendition(
            entries: entries, cache: IFramePayloadCache(),
            format: .keyframes, buildFragment: buildKeyframe, companion: companion)
    }

    /// An overlay session's scan tier: the panel shows it full screen while AVPlayer scans, and 1080p is sharp
    /// there at any scan rate, where the source's own size would cost the encoder four times as much a still.
    static let overlayScanStillWidth = 1920

    /// The session's one reader of single pictures off the source (`IFrameKeyframeReader`): the I-frame
    /// rendition's, the compositor preview's and the scrub stills' past the resident window. The keyframe
    /// from the source's index, or from a demuxer of its own where only libavformat can read the container,
    /// with the P7 conversion the playing samples get. Made on the first request that needs it, over the
    /// custom source's clone when there is one; `stop()` interrupts and closes it. Under `keyframeReaderLock`.
    private var keyframeReader: IFrameKeyframeReader?
    private let keyframeReaderLock = NSLock()

    private func sessionKeyframeReader() -> IFrameKeyframeReader? {
        keyframeReaderLock.lock()
        defer { keyframeReaderLock.unlock() }
        if let keyframeReader { return keyframeReader }
        guard let cfg = sourceVideoConfig, let session = demuxer else { return nil }
        let framing = cfg.nalFramingOverride ?? A53SEIParser.nalFraming(
            codec: cfg.codecpar.pointee.codec_id == AV_CODEC_ID_HEVC ? .hevc : .h264,
            extradata: cfg.codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(cfg.codecpar.pointee.extradata_size))
        let url = sourceURL, headerStore = requestHeaders
        let positions: [Int64: Int64] = Dictionary(
            session.indexedKeyframeEntries(streamIndex: session.videoStreamIndex).map { ($0.pts, $0.pos) },
            uniquingKeysWith: { first, _ in first })
        // The reader owns the clone from here; `stop()` must not close it a second time.
        let custom = customKeyframeReader
        customKeyframeReader = nil
        isCustomKeyframeSource = custom != nil
        let reader = IFrameKeyframeReader(
            resolveIndex: { [weak session] in
                guard let session else { return .failed("the session's demuxer is gone") }
                return await Self.iFrameKeyframeIndex(url: url, headers: headerStore.current, demuxer: session,
                                                      custom: custom?.reader)
            },
            position: { positions[$0] },
            // Over exact range reads of the source, through the source cache: a seek reads what it lands
            // on and nothing streams ahead of it. A disc title is opened as the session's.
            open: { [weak session] dem in
                let title = session?.selectedDiscTitleID
                if let custom {
                    try dem.open(reader: custom.reader, formatHint: custom.formatHint, profile: .iFrameSideDemuxer,
                                 selectTitleID: title, discCacheKey: url.absoluteString)
                    return {}
                }
                guard let reader = AetherEngine.indexReader(url: url, headers: headerStore.current, label: "iframe",
                                                            requestTimeout: 8, maxRetries: 1) else {
                    throw DemuxerError.openFailed(code: -1)
                }
                do {
                    try dem.open(reader: reader, profile: .iFrameSideDemuxer, selectTitleID: title,
                                 discCacheKey: url.absoluteString)
                } catch {
                    reader.close()
                    throw error
                }
                return { reader.close() }
            },
            knownKeyframes: { [weak session] in
                guard let session else { return [] }
                return session.recordedKeyframes(streamIndex: session.videoStreamIndex)
            },
            cleanup: { custom?.reader.close() },
            convertP7ToProfile81: cfg.convertP7ToProfile81,
            nalFraming: framing)
        keyframeReader = reader
        return reader
    }

    /// What a scrub still past the resident window reads off the source (`sourceStill`): the plan's keyframes,
    /// or the picture at a time on a source with no keyframe list; nil while this session may not read one.
    /// Decided in `serve()` by the I-frame rendition's own rule.
    private(set) var sourceStillTimeline: IFrameRenditionEligibility.Timeline?
    /// The decoder `sourceStill` turns a keyframe or a picture run into an image with, made on first use.
    /// Under `sourceStillLock`, which also keeps one still at a time on it.
    private var sourceStillDecoder: FrameDecodeContext?
    private let sourceStillLock = NSLock()

    /// A still of the picture at `seconds` (playlist axis), read off the source through the session's keyframe
    /// reader, for a scrub preview past the resident window: the keyframe at or before it where the plan lists
    /// keyframes, the picture at it where the source seeks to a time. nil while no picture can be read off this
    /// source, when the origin has no room for a read, or when the read fails. Blocks; any thread but main.
    func sourceStill(atSeconds seconds: Double, maxWidth: Int) -> CGImage? {
        guard let timeline = sourceStillTimeline, seconds.isFinite, keyframeReadsAllowed() else { return nil }
        restartLock.lock()
        let plan = segmentPlan
        let keyframes = planKeyframePts.sorted()
        let cfg = sourceVideoConfig
        restartLock.unlock()
        let tb = sourceVideoTbSeconds
        guard let cfg, tb > 0, !plan.isEmpty else { return nil }
        // The plan's segment holding `seconds`, and the target on the source axis inside it.
        var first = 0, past = plan.count
        while first < past {
            let mid = (first + past) / 2
            if plan[mid].startSeconds <= seconds { first = mid + 1 } else { past = mid }
        }
        let segment = plan[max(0, first - 1)]
        let target = segment.startPts + Int64((max(0, seconds - segment.startSeconds) / tb).rounded())
        guard let reader = sessionKeyframeReader() else { return nil }
        waitForKeyframeLink { false }
        sourceStillLock.lock()
        defer { sourceStillLock.unlock() }
        if sourceStillDecoder == nil {
            // The decoder reads the samples as the session serves them: Annex B ones with the source's own
            // extradata, length-prefixed ones with the record the muxer writes.
            sourceStillDecoder = FrameDecodeContext(
                streamParameters: cfg.codecpar, timeBase: cfg.timeBase,
                extradata: cfg.convertsAnnexBSamples ? nil : cfg.extradataOverride)
        }
        guard let decoder = sourceStillDecoder, (try? decoder.ensureOpen()) != nil else { return nil }
        let decodeStart = CACurrentMediaTime()
        defer { StageTimes.alongsidePlayback.record("source still decode", ms: (CACurrentMediaTime() - decodeStart) * 1000) }
        switch timeline {
        case .keyframes:
            // The keyframe at or before the target: what playing from there would show first.
            var low = 0, high = keyframes.count
            while low < high {
                let mid = (low + high) / 2
                if keyframes[mid] <= target { low = mid + 1 } else { high = mid }
            }
            let keyframe = low > 0 ? keyframes[low - 1] : segment.startPts
            return reader.payload(startPts: keyframe).flatMap { decoder.decodeStill(keyframe: $0, targetWidth: maxWidth) }
        case .stills:
            return reader.pictureRun(atPts: target).flatMap { decoder.decodeStill(run: $0, targetWidth: maxWidth) }
        }
    }

    /// Whether a read off the source may go out now. The budget learns its limits mid-session (a 429 halves
    /// them and arms a pacer), so the check `start()` made is repeated before every read. A custom reader has
    /// no origin.
    private func keyframeReadsAllowed() -> Bool {
        isCustomKeyframeSource || !(OriginRequestBudget.shared.requiresSerialRequests(sourceURL)
                                    || OriginRequestBudget.shared.isPaced(sourceURL))
    }

    /// A seek or a producer restart owns the link for a moment; a picture can wait that out, but not
    /// ordinary fetching, or it would stall whenever the pump is busy.
    private func waitForKeyframeLink(_ shouldStop: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !shouldStop(), restartInFlight || (seekInFlight?.isSeeking ?? false) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// A rendition over the session's keyframe reader: what each entry reads (`read`), and how a read
    /// becomes a fragment. nil when the reader cannot be made (the session has no demuxer).
    private func makeKeyframeRendition(
        entries: [IFrameRendition.Entry],
        cache: IFramePayloadCache,
        format: IFrameRenditionFormat,
        read: @escaping (IFrameKeyframeReader, IFrameRendition.Entry) -> Data? = { reader, entry in
            reader.payload(startPts: entry.startPts)
        },
        buildFragment: @escaping (Data, Int, IFrameRendition.Entry) -> IFrameFragmentBuilder.Output?,
        companion: (format: IFrameRenditionFormat,
                    build: (Data, Int, IFrameRendition.Entry) -> IFrameFragmentBuilder.Output?)? = nil
    ) -> IFrameRendition? {
        guard let reader = sessionKeyframeReader() else { return nil }
        return IFrameRendition(
            entries: entries,
            cache: cache,
            format: format,
            readPayload: { read(reader, $0) },
            buildFragment: buildFragment,
            companion: companion,
            waitForLink: { [weak self] shouldStop in self?.waitForKeyframeLink(shouldStop) },
            sourceReadsAllowed: { [weak self] in self?.keyframeReadsAllowed() ?? false })
    }

    /// Stop answering I-frame requests. The shutdown waits for a read in flight, so it runs off the
    /// caller's thread; the provider is cleared first, so no new request reaches the rendition. The
    /// reference stays, because `stop()` has to drain the same shutdown before it frees the codec
    /// parameters the builder reads.
    private func tearDownIFrameRendition() {
        provider?.setIFrameSource(nil)
        guard let rendition = iFrameRendition else { return }
        DispatchQueue.global(qos: .utility).async { rendition.shutdown() }
    }

    private func closeUnusedCustomKeyframeReader() {
        keyframeReaderLock.lock()
        let custom = customKeyframeReader
        customKeyframeReader = nil
        keyframeReaderLock.unlock()
        custom?.reader.close()
    }

    // MARK: - Producer construction + restart

    /// Allocate a new `HLSSegmentProducer` at the given segment index (initial bring-up and scrub restarts).
    func makeProducer(
        baseIndex: Int,
        liveReopenOutputEndSeconds: Double? = nil
    ) throws -> HLSSegmentProducer {
        guard let dem = demuxer, let cache = cache, let cfg = savedVideoConfig else {
            throw HLSVideoEngineError.notStarted
        }

        // Scan-forward + dynamic-shift: producer scans for the first AV_PKT_FLAG_KEY packet whose
        // presentation time reaches videoTarget (a plan-boundary PTS; judging by DTS dropped the
        // anchor IRAP under B-frame reorder, AE#169 round 3), then computes
        // shift = actualFirstDts - desiredFirstTfdt and applies it to all subsequent packets.
        // Audio target set dynamically after video lands.
        let videoTarget: Int64
        let desiredVideoTfdt: Int64
        if let endSeconds = liveReopenOutputEndSeconds {
            // Live reopen: no scan target (join head), but tfdt must continue where the
            // failed producer's last segment ended (seam carries #EXT-X-DISCONTINUITY).
            videoTarget = Int64.min
            desiredVideoTfdt = sourceVideoTbSeconds > 0
                ? Int64(endSeconds / sourceVideoTbSeconds)
                : 0
        } else if baseIndex > 0, baseIndex < segmentPlan.count {
            videoTarget = segmentPlan[baseIndex].startPts
            // The produced timeline continues at the segment's ADVERTISED item-axis start, never at
            // its (possibly backed-off) source boundary: `startPts` is a gate/seek target chosen to sit
            // at-or-below the segment's IRAP (AE#268), while `startSeconds` is what the playlist told
            // AVPlayer this segment starts at. Identical for the keyframe and uniform plans, where the
            // boundary is the item-axis start plus the anchor.
            desiredVideoTfdt = sourceVideoTbSeconds > 0
                ? Int64((segmentPlan[baseIndex].startSeconds / sourceVideoTbSeconds).rounded())
                : segmentPlan[baseIndex].startPts - firstKeyframePts
        } else {
            videoTarget = Int64.min
            desiredVideoTfdt = 0
        }

        // Segment boundary slice: startPts per segment + endPts of final (producer upper bound).
        // Lower bound clamped: live reopen passes baseIndex > segmentPlan.count (empty plan).
        let plannedSegs = segmentPlan[min(baseIndex, segmentPlan.count)..<segmentPlan.count]
        var segmentBoundaries: [Int64] = plannedSegs.map { $0.startPts }
        if let last = plannedSegs.last {
            segmentBoundaries.append(last.endPts)
        }

        let producerEpoch = nextProducerEpoch()
        let prod = try HLSSegmentProducer(
            demuxer: dem,
            videoStreamIndex: videoStreamIndex,
            video: cfg,
            audio: savedAudioConfig,
            sideAudioDemuxer: sideAudioDemuxer,
            cache: cache,
            audioRendition: audioRenditionCache,
            baseIndex: baseIndex,
            targetSegmentDurationSeconds: liveCutTargetSeconds,
            videoFallbackDurationPts: videoFallbackDurationPts,
            restartTargetVideoPts: videoTarget,
            boundaryClaimsRandomAccess: planBoundariesClaimRandomAccess,
            planBoundaryAxis: planBoundaryAxis,
            closedCaptionStreamIndex: closedCaptionStreamIndexForSession,
            subtitleTapStreamIndices: Set(nativeSubtitleSourceStreamIndicesForSession.compactMap { $0 }),
            subtitlePacketStreamIndices: allEmbeddedSubtitleStreamIndices,   // #112 rework
            desiredFirstVideoTfdtPts: desiredVideoTfdt,
            segmentBoundaries: segmentBoundaries,
            planAnchorVideoPts: firstKeyframePts,
            isLive: isLiveSession,
            // #368: a forward-only chunked archive folds its chunk-seam PTS resets (incl. the
            // libavformat 33-bit wrap correction) the way live folds program boundaries; without
            // it the leap walks the cutter to the plan tail and the session deadlocks.
            foldsSequentialTimeline: sequentialOriginPinsProducerToZero,
            packedSideAudioStartPts: packedSideAudioStartPts,
            packedSideAudioFallbackDurationPts: packedSideAudioFallbackDurationPts,
            bufferAheadSegments: forwardWindowSegments,
            prefetchDiskBudgetBytes: retentionBudgetBytes,
            // AE#222: nil until a pump proved this source cuts its first segment before any audio packet
            // arrives; from then on every producer of the session muxes moov from this frame.
            audioMoovPrimeFrame: sessionAudioMoovPrimeFrame,
            // AE#366: once one producer has searched the whole source for an audio frame and come
            // back empty, later ones must not repeat the search per revive attempt.
            audioMoovPrimeKnownUnobtainable: sessionAudioMoovPrimeUnobtainable,
            // AE#464: read here rather than pushed, so every producer this session builds (seek
            // restart, live reopen, #99 revive) cuts with the offset currently in force.
            audioDelaySeconds: audioDelaySeconds,
            epoch: producerEpoch
        )
        // Layer 3 step 5: every producer (initial + restart) reads on for the subtitle consumers, and
        // states how far it has read.
        prod.subtitleReadAheadReach = { [weak self] in self?.subtitleReadAheadSegmentIndex() }
        prod.onSourceReadThrough = { [weak self] seconds in
            guard let self, self.isInstalledProducer(producerEpoch) else { return }
            self.noteSourceRead(through: seconds, producerEpoch: producerEpoch)
        }
        #if DualLayerDolbyVision
        prod.felTap = felTap
        #endif
        prod.overlayPlaceholder = overlayPlaceholder
        prod.overlayDecodeTap = overlayDecodeTap
        prod.playedMediaLedger = playedMediaLedger
        prod.onFirstHDR10PlusDetected = { [weak self] in
            self?.notifyHDR10PlusOnce()
        }
        prod.onSegmentWritten = { [weak self] index, carriedSeconds in
            self?.recordCarried(carriedSeconds, at: index)
        }
        prod.onVideoShiftKnown = { [weak self] shiftPts, firstItemTfdtPts, normalizationShiftPts in
            self?.handleVideoShiftKnown(
                shiftPts, firstItemTfdtPts: firstItemTfdtPts,
                normalizationShiftPts: normalizationShiftPts, producerEpoch: producerEpoch)
        }
        prod.onLiveTimelineRebase = { [weak self] shiftPts, seamOutputSeconds in
            self?.handleLiveTimelineRebase(shiftPts, seamOutputSeconds: seamOutputSeconds,
                                           producerEpoch: producerEpoch)
        }
        prod.onLiveVideoColour = { [weak self] startSeconds, colour in self?.onLiveVideoColour?(startSeconds, colour) }
        prod.onPumpFinished = { [weak self, weak prod] reason in
            guard let self, let prod else { return }
            self.handlePumpFinished(prod, reason: reason)
        }
        // #65: let the pump suspend its backpressure wedge detector while AVPlayer is paused (a paused
        // consumer issues no forward fetch; its frozen fetch target is not a wedge). Threaded onto every
        // producer (initial + restart) so the guard survives scrub/audio-switch rebuilds.
        prod.wantsToPlayProvider = playIntentProvider
        // #93 retest: the rendered clock feeds the wedge detector's fast path (park + both signals
        // frozen -> single-digit detection). Threaded onto every producer like the play-intent guard.
        prod.playbackPositionProvider = currentPlaybackPositionProvider
        // #35/#93 cold-startup: suspend the wedge detector until the first frame lands (pre-roll of a
        // slow high-bitrate DV master must not be misread as a wedge). Threaded onto every producer.
        prod.hasStartedRenderingProvider = hasStartedRenderingProvider
        // AE#446 round 3: the no-cut watchdog's starvation exit tears down the read a closed window
        // is waiting on. Threaded onto every producer like the guards above, so a reopen does not
        // leave the exit unguarded while the consumer is still walking the runway.
        prod.outageRunwayProvider = { [weak self] in
            self?.provider?.outageRunwayAheadOfConsumer ?? false
        }
        prod.closedCaptionObserver = closedCaptionObserverForSession   // #77
        prod.a53CaptionObserver = a53CaptionObserverForSession   // #131
        // #260: resolved per frame, so installing an observer mid-session reaches this producer too.
        prod.nativeVideoFrameTimeObserverProvider = { [weak self] in
            self?.nativeVideoFrameTimeObserverSnapshot()
        }
        // Sodalite#32: build the tap routes lazily on the first producer that has stores + stream
        // indices (the host sets both before start()), then wire the tap onto every producer.
        subtitleTapLock.lock()
        let routesEmpty = subtitleTapRoutes.isEmpty
        subtitleTapLock.unlock()
        if routesEmpty, !nativeSubtitleSourceStreamIndicesForSession.isEmpty,
           !nativeSubtitleCueStoresForSession.isEmpty {
            rebuildSubtitleTapRoutes()
        }
        armSubtitleTap(on: prod)
        // Audit HLS-101: the first producer is built before the provider exists and `start()` wires
        // it; every later one (live reopen, in-place rebuild, AE#222 rebuild) is wired here.
        if let prov = provider {
            wireProviderCallbacks(prod, to: prov)
        }
        return prod
    }

    /// The producer-to-provider reports the playlist is built from. A live producer without them
    /// cuts segments the playlist never lists (audit HLS-101).
    func wireProviderCallbacks(_ prod: HLSSegmentProducer, to prov: VideoSegmentProvider) {
        if isLiveSession {
            prov.onLivePlaylistRenewal = { [weak self] in self?.onLivePlaylistRenewal?() }
            prod.onLiveSegmentFinalized = { [weak prov] index, durationSeconds, startPtsSeconds, discontinuous in
                prov?.appendLiveSegment(index: index,
                                        startSeconds: startPtsSeconds,
                                        durationSeconds: durationSeconds,
                                        discontinuous: discontinuous)
            }
            prod.onLiveSegmentSound = { [weak prov] index, first, last in
                prov?.noteLiveSegmentSound(index: index, firstSeconds: first, lastSeconds: last)
            }
            // AE#443: the runaway park has to sit above the window this session actually serves, or it
            // bounds the window instead of backstopping it, and its enforcement (a sleeping read
            // thread) stops the origin from being drained.
            prod.liveResidentCapProvider = { [weak prov] in prov?.liveResidentParkCap() ?? 0 }
        } else if sequentialOrigin {
            prod.onSequentialSegmentFinalized = { [weak prov] index, durationSeconds in
                prov?.appendSequentialSegmentDuration(index: index, durationSeconds: durationSeconds)
            }
        }
    }

    // MARK: - Live source-loss recovery

    /// Max reopen attempts per lost-source event (AVIO absorbs transient drops internally;
    /// pump exits only on exhausted sources: dead transcode, dropped tuner, blown budget).
    static let liveReopenMaxAttempts = 6

    /// Barren-cycle backstop: an open-then-starve source would cycle forever without this.
    /// After `maxBarrenReopenCycles` consecutive cycles producing no new segment, stop reviving.
    var barrenReopenCycles = 0
    var liveRecoveryHasVerifiedReplay = false
    var liveSourceRequiresNegotiation = false
    var liveRecoveryProducer: HLSSegmentProducer?
    var lastReopenSegmentCount = -1
    static let maxBarrenReopenCycles = 3
    /// Live muxerFailed in-place rebuilds, bounded by progress like the reopen cycles above: new segments
    /// since the last death reset the budget (an hours-long channel legitimately crosses several encoder
    /// restarts, so a session-lifetime gate like the VOD #99 one would be wrong here); consecutive barren
    /// deaths exhaust it and the session halts + delegates to host retune.
    var liveMuxerRebuildCycles = 0
    var lastMuxerRebuildSegmentCount = -1
    static let maxLiveMuxerRebuildCycles = 3

    private func handleVideoShiftKnown(_ shiftPts: Int64, firstItemTfdtPts: Int64,
                                      normalizationShiftPts: Int64, producerEpoch: UInt64) {
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        let seamItemSeconds = Double(firstItemTfdtPts) * sourceVideoTbSeconds
        // Live rebases the whole timeline at a program boundary and nothing older comes back on
        // screen, so its axis is the epoch's own and it publishes here as it always has.
        guard !isLiveSession else {
            guard isInstalledProducer(producerEpoch) else { return }
            // Live has no placement model: the epoch's shift IS the axis, so the displacement this
            // session tracks for VOD stays where it is (nothing below reads it on a live session).
            publishPlaylistShift(seconds, seamItemSeconds: seamItemSeconds)
            return
        }
        // On VOD the axis is what AVPlayer reports in band (`noteInBandClock`); a gate open only answers
        // an AE#412 re-cut waiting on it, with how far below its boundary it opened.
        let index = segmentIndexForPlaylistTime(seamItemSeconds)
        // Audit SEG-104: a restart that was replaced while its first read was in flight can still
        // open its gate, for bytes nobody will store.
        guard isInstalledProducer(producerEpoch) else {
            EngineLog.emit(
                "[HLSVideoEngine] gate open at seg\(index) from a superseded producer, ignored",
                category: .session)
            return
        }
        let carried = normalizationShiftPts == Int64.min ? 0 : Double(normalizationShiftPts) * sourceVideoTbSeconds
        gateOpenCondition.lock()
        lastGateOpen = (index: index, backoffSeconds: seconds - carried)
        gateOpenCondition.broadcast()
        gateOpenCondition.unlock()
    }

    /// docs/segment-axis.md: AVPlayer played the segment that states `stamp` at item time
    /// `itemSeconds` (`InBandClock`, read back through `AVPlayerItemMetadataOutput`), so from there on
    /// `source = item + (stamp.sourceSeconds - itemSeconds)`, measured, whatever AVPlayer did with the
    /// segment: a run it opened, one it appended to, a timeline it rebuilt.
    ///
    /// Readings arrive about four seconds ahead in item order, and again for the segment a seek or the
    /// mount lands in. The axis is published when a reading differs from the last one (a new run's
    /// offset), and whenever a reading is at or before the last one's position, which is a seek: its
    /// seam then also clears whatever the old position's readings had put ahead of it.
    func noteInBandClock(itemSeconds: Double, stamp: InBandClock.Stamp) {
        guard !isLiveSession, itemSeconds.isFinite else { return }
        let axis = stamp.sourceSeconds - itemSeconds
        anchorShiftLock.lock()
        let last = lastClockReading
        lastClockReading = (itemSeconds, axis)
        anchorShiftLock.unlock()
        if let last, itemSeconds > last.itemSeconds, abs(axis - last.axis) < Self.axisReadingEpsilonSeconds { return }
        EngineLog.emit(
            "[HLSVideoEngine] seg\(stamp.segmentIndex) plays from item \(String(format: "%.3f", itemSeconds))s at "
            + "source \(String(format: "%.3f", stamp.sourceSeconds))s: axis \(String(format: "%.3f", axis))s",
            category: .session)
        publishPlaylistShift(axis, seamItemSeconds: itemSeconds)
    }

    /// Below this two readings state one axis: a stamp's time is printed to the microsecond and a frame
    /// is tens of milliseconds, so anything finer is rounding.
    static let axisReadingEpsilonSeconds = 0.0005

    /// AE#412: how long to give a re-cut its gate open before the seek goes out without it. A restart
    /// is a demuxer seek plus a scan to the covering random-access point; past this the seek is worth
    /// more than the correction, and the landing degrades to what it does today.
    static let recutGateWaitSeconds: TimeInterval = 2.0

    /// AE#412: how far below a cold seek target AVPlayer is assumed to reach for a random-access
    /// point. It reaches back a fixed span and does NOT search for one: measured with
    /// `play --picture-probe` on a 4 s grid, the first fetch of a cold seek was the segment holding
    /// `target - 8 s` in one run shape and `target - 6 s` in another, on the case fixture and on a
    /// control whose every segment is independent alike. 4 s is deliberately below both, so a landing
    /// AVPlayer would have managed on its own is never re-cut; the cost of the margin is a re-cut
    /// that was not strictly needed, not a landing that is wrong.
    static let coldSeekLookbackSeconds: Double = 4.0

    /// AE#412: the item position to seek AVPlayer to, having first made sure the segment it lands in
    /// can start a decode run there.
    ///
    /// Audio routes packets by plan boundary while video routes them keyframe-gated, so inside a
    /// keyframe drought audio opens boundaries the cutter folded and those segments carry no
    /// random-access point at all. Because AVPlayer's reach back is fixed rather than a search, a
    /// drought wider than that reach leaves the picture starting at the next sync sample ABOVE the
    /// target, and the seek silently skips content. Measured on a 12 s drought, seeking back from
    /// 88 s: a seek to 50.0 s landed at 55.0 s and one to 54.0 s at 54.96 s, while the same source cut
    /// on its real sync samples landed exactly on every target tested.
    ///
    /// The repair is the producer's own gate: a restart anchored at that index opens on the covering
    /// random-access point, so the segment begins at or below its advertised start and covers the
    /// target. The seek target is NOT moved to compensate: measured 3 of 3, AVPlayer puts the re-cut
    /// segment at its own tfdt inside the timeline it is already building (`axisErr` 0.000), so item
    /// time is source time and a correction would land exactly that far past the target instead.
    ///
    /// Runs off the main actor (it parks on the pump). Returns `itemSeconds` unchanged whenever there
    /// is nothing to act on: live, no recorded reach for the landing segment, a random-access point
    /// already within reach below the target, or a re-cut whose gate did not open in time.
    func preparedSeekLanding(itemSeconds: Double) -> Double {
        guard !isLiveSession, let provider else { return itemSeconds }
        let index = segmentIndexForPlaylistTime(itemSeconds)
        guard let reach = provider.videoReach(at: index) else { return itemSeconds }
        guard let advertised = advertisedStartSeconds(index) else { return itemSeconds }
        let covering = coveringSyncItemSeconds(atOrBelow: itemSeconds, from: index, provider: provider)
        guard Self.needsRecut(landingReach: reach,
                              offsetIntoSegment: itemSeconds - advertised,
                              coveringSyncDistance: covering.map { itemSeconds - $0 }) else {
            return itemSeconds
        }
        EngineLog.emit(
            "[HLSVideoEngine] #412 seek to item \(String(format: "%.3f", itemSeconds))s lands in seg\(index) "
            + "(advertised \(String(format: "%.3f", advertised))s), which cannot start a decode run there "
            + "and no random-access point is within reach below it; re-cutting from the covering one",
            category: .session
        )
        markRecut(at: index)
        // Audit HLS-4: off this task, so the gate wait below bounds the whole re-cut. Inline, an idle
        // coalescer ran the restart here (a 5 s stop wait, a #79 reopen, the demuxer seek) before the
        // wait began, all outside the seek's 8 s landing bound.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.requestRestart(at: index, authoritative: true)
        }
        // Audit HLS-105: a timeout leaves the mark with the restart, whose gate may open later.
        guard let opened = awaitGateOpen(forIndex: index, timeout: Self.recutGateWaitSeconds) else {
            EngineLog.emit(
                "[HLSVideoEngine] #412 seg\(index) re-cut did not open a gate within "
                + "\(String(format: "%.1f", Self.recutGateWaitSeconds))s; seeking on the uncorrected position",
                category: .session
            )
            return itemSeconds
        }
        EngineLog.emit(
            "[HLSVideoEngine] #412 seg\(index) re-cut opened "
            + "\(String(format: "%.3f", -opened))s below its "
            + "boundary and now covers item \(String(format: "%.3f", itemSeconds))s",
            category: .session
        )
        return itemSeconds
    }

    /// A re-cut waits for the gate of the restart it asks for, not an earlier one.
    func markRecut(at index: Int) {
        gateOpenCondition.lock()
        lastGateOpen = nil
        gateOpenCondition.unlock()
    }

    func recordCarried(_ seconds: Double, at index: Int) {
        anchorShiftLock.lock()
        carriedSecondsByIndex[index] = seconds
        anchorShiftLock.unlock()
    }

    private func isInstalledProducer(_ epoch: UInt64) -> Bool {
        anchorShiftLock.lock()
        defer { anchorShiftLock.unlock() }
        return installedProducerEpoch == epoch
    }

    /// AE#412 pure decision: whether the segment a cold seek lands in has to be re-cut before the
    /// seek goes out.
    ///
    /// Three ways it does not. The segment carries a random-access point at or below the target, so
    /// it opens a run there itself. Or one sits close enough below the target that AVPlayer's fixed
    /// reach back picks it up out of an earlier segment, which is the case that lands exactly today.
    /// Anything else leaves the picture starting above the target, which is the defect.
    ///
    /// `coveringSyncDistance` is how far BELOW the target the nearest known random-access point sits;
    /// nil when none is known down there.
    static func needsRecut(
        landingReach: SegmentCache.VideoReach,
        offsetIntoSegment: Double,
        coveringSyncDistance: Double?
    ) -> Bool {
        if landingReach.serves(offsetSeconds: offsetIntoSegment) { return false }
        guard let coveringSyncDistance else { return true }
        return coveringSyncDistance > coldSeekLookbackSeconds
    }

    /// `segmentPlan[index].startSeconds` on the AVPlayer/playlist axis, taking `restartLock` itself.
    private func advertisedStartSeconds(_ index: Int) -> Double? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard index >= 0, index < segmentPlan.count else { return nil }
        return segmentPlan[index].startSeconds
    }

    /// AE#412: the highest recorded random-access point at or below `itemSeconds`, walking down from
    /// `index` until one segment starts below AVPlayer's reach. nil when nothing down there carries
    /// one, and also when a walked segment made no claim: an unrecorded segment might well carry a
    /// sync sample, and re-cutting on a guess would cost a restart on a landing that works today.
    private func coveringSyncItemSeconds(
        atOrBelow itemSeconds: Double, from index: Int, provider: VideoSegmentProvider
    ) -> Double? {
        var best: Double?
        var j = index
        while j >= 0 {
            guard let advertised = advertisedStartSeconds(j) else { return best }
            guard let reach = provider.videoReach(at: j) else { return itemSeconds }
            if case .syncAt(let offset) = reach {
                let sync = advertised + offset
                if sync <= itemSeconds { best = max(best ?? sync, sync) }
            }
            if advertised <= itemSeconds - Self.coldSeekLookbackSeconds { return best }
            j -= 1
        }
        return best
    }

    /// Blocks until the epoch anchored at `index` has opened its video gate, and answers how far below
    /// its boundary it opened (seconds, negative below). nil on timeout.
    private func awaitGateOpen(forIndex index: Int, timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            gateOpenCondition.lock()
            if let open = lastGateOpen, open.index == index {
                gateOpenCondition.unlock()
                return open.backoffSeconds
            }
            let signalled = gateOpenCondition.wait(until: deadline)
            gateOpenCondition.unlock()
            if !signalled, Date() >= deadline { return nil }
        }
    }

    private func publishPlaylistShift(_ seconds: Double, seamItemSeconds: Double) {
        setPlaylistShiftSeconds(seconds)
        // Refresh every native subtitle store's shift so cuesInWindow stays on the correct AVPlayer
        // axis after a restart (matroska seek can land past the planned keyframe, #55). Snapshot under
        // restartLock: this runs on the pump thread and the array is reassigned by attach* on another
        // thread, so iterating the live array would race a CoW reassignment.
        restartLock.lock()
        let stores = nativeSubtitleCueStoresForSession
        restartLock.unlock()
        stores.forEach { $0.setShiftSeconds(seconds) }
        onPlaylistShiftChanged?(seconds, seamItemSeconds)
    }

    /// Live program-boundary rebase. Unlike `handleVideoShiftKnown`, does NOT fire `onPlaylistShiftChanged`:
    /// AVPlayer renders at ~buffer+holdback behind the producer edge, so the host must keep the OLD shift
    /// until playback crosses `seamOutputSeconds`. Internal `playlistShiftSeconds` tracks the edge immediately.
    /// #368: sequential chunk-seam rebases arrive here too, deliberately; same deferred-shift contract.
    func handleLiveTimelineRebase(_ shiftPts: Int64, seamOutputSeconds: Double, producerEpoch: UInt64) {
        guard isInstalledProducer(producerEpoch) else { return }
        let seconds = shiftPts == Int64.min ? 0 : Double(shiftPts) * sourceVideoTbSeconds
        setPlaylistShiftSeconds(seconds)
        onPlaylistShiftRebased?(seconds, seamOutputSeconds)
    }

    /// Session-level debounce: prevents re-firing after a scrub restart builds a fresh producer.
    private func notifyHDR10PlusOnce() {
        hdr10PlusLock.lock()
        let alreadyFired = hasReportedHDR10Plus
        hasReportedHDR10Plus = true
        hdr10PlusLock.unlock()
        if !alreadyFired {
            onFirstHDR10PlusDetected?()
        }
    }

    /// Entry point from `VideoSegmentProvider` when AVPlayer requests a segment outside the LRU window.
    /// Coalesces burst seeks so only the in-flight restart + one final settled-target restart run (#35).
    /// init.mp4 is byte-deterministic for a fixed `StreamConfig` so AVPlayer's cached copy stays valid.
    /// True while a coalesced restart run is executing (#93 residual: the provider's waiting
    /// segment fetches ride this instead of burning fixed retry budgets, and skip re-firing
    /// restarts at stale indices against the coalescer's newer target).
    var restartInFlight: Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return restartCoalescer.isInFlight
    }

    /// Base index of the currently-installed producer, nil when none (#93 residual: a fetch for
    /// an index the active producer covers must WAIT for its march, not tear it down; device saw
    /// a 75%-complete capture killed by a backstop re-fire and a fresh forward march restarted).
    var currentProducerBaseIndex: Int? {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer?.anchoredBaseIndex
    }

    /// AE#169 round 2: whether the installed producer's pump has exited. nil producer (mid-restart)
    /// reads as false; the coalescer's restartActivity covers that window.
    var currentProducerFinished: Bool {
        restartLock.lock()
        defer { restartLock.unlock() }
        return producer?.didFinish ?? false
    }

    /// Total media-segment requests seen this session (#93 residual): the stall-triggered
    /// re-engage watchdog compares snapshots to detect a consumer that stopped requesting.
    var mediaFetchCountSnapshot: UInt64 {
        restartLock.lock()
        defer { restartLock.unlock() }
        return provider?.mediaFetchCount ?? 0
    }

    /// #405: segments the producer has finalized this session, the counterpart to
    /// `mediaFetchCountSnapshot`. One counts the consumer asking, this one counts the producer
    /// delivering, and the stall ladder needs both to tell a dead consumer from a starved origin.
    /// nil when there is no local producer at all (a remote HLS session AVPlayer fetches directly),
    /// which is a different situation from a producer that stopped: callers must not read the
    /// absence as zero progress. Monotonic: the live window slides by moving `firstVisible` and
    /// evicting cache, never by dropping entries from the segment list.
    var liveSegmentCountSnapshot: Int? {
        restartLock.lock()
        defer { restartLock.unlock() }
        return provider.map { $0.liveContinuationPoint().nextIndex }
    }

    /// AE#443: is the live pump held in its runaway headroom park?
    ///
    /// nil when there is no local producer, for the same reason as the count above: absence is not a
    /// "no". A parked pump finalizes nothing and drains no origin, so a ladder that reads only the
    /// finalized count sees a starved source and says so, which is what sent the reporter of #443 to
    /// his server logs three times.
    var liveProducerParkedSnapshot: Bool? {
        subsystemSnapshot().producer?.isLiveHeadroomParked
    }

    /// AE#446 round 2: this session's window is being served as a finished asset because its source
    /// stopped delivering while a viewer still had resident segments ahead. See
    /// `VideoSegmentProvider.liveOutageEndlist`.
    var liveOutageEndlistActive: Bool { provider?.liveOutageEndlistLatched ?? false }

    /// AE#446 round 2: the source has cut again since that happened.
    var liveOutageProductionResumed: Bool { provider?.liveOutageProductionResumed ?? false }

    /// AE#446 round 2: re-open the window as live for the next item. Call it immediately before the
    /// item swap that will fetch the playlist again, never while the current item could still poll.
    func clearLiveOutageEndlist() { provider?.clearLiveOutageEndlist() }

    /// AE#454: tell the item the next swap loads where to start, in its own playlist. Call immediately
    /// before the swap, so the first manifest that item fetches already carries the placement.
    /// See `VideoSegmentProvider.armLiveRejoinStart`.
    @discardableResult
    func armLiveRejoinStart(atOutputSeconds seconds: Double) -> (segmentIndex: Int, secondsIntoSegment: Double)? {
        provider?.armLiveRejoinStart(atOutputSeconds: seconds)
    }

    /// AE#454: the placement is spent once the item that asked for it is running.
    func clearLiveRejoinStart() { provider?.clearLiveRejoinStart() }

    /// See `VideoSegmentProvider.liveSegmentHeads(atOutputSeconds:)`.
    func liveSegmentHeads(atOutputSeconds seconds: Double)
        -> (index: Int, secondsIntoSegment: Double, pictureStart: Double, sound: (first: Double, last: Double)?)? {
        provider?.liveSegmentHeads(atOutputSeconds: seconds)
    }

    /// See `VideoSegmentProvider.servedLiveRejoinPlacement`.
    var servedLiveRejoinPlacement: (timeOffset: Double, playlistStartOutputSeconds: Double)? {
        provider?.servedLiveRejoinPlacement
    }

    /// AE#446 round 5: a fresh item is attaching, so the axis the last one came up on is spent.
    /// See `VideoSegmentProvider.armLiveItemAxisStatement`.
    func armLiveItemAxisStatement() { provider?.armLiveItemAxisStatement() }

    /// See `VideoSegmentProvider.servedLiveItemAxisOutputSeconds`.
    var servedLiveItemAxisOutputSeconds: Double? { provider?.servedLiveItemAxisOutputSeconds }

    /// #178: called by the engine when a NEW user seek is dispatched. A recovery re-anchor still
    /// holding the coalescer's authoritative slot belongs to the superseded seek; left in place it
    /// would drop the new seek's segment-driven restart and land the producer on the stale
    /// recovery position. Runs before the host seek so AVPlayer's new segment GETs never race a
    /// locked slot.
    func releaseSupersededAuthoritativeRestart() {
        restartLock.lock()
        restartCoalescer.clearSupersededAuthoritativePending()
        restartLock.unlock()
    }

    func requestRestart(at idx: Int, authoritative: Bool = false) {
        // A sequential origin has no restart. performRestart's demuxer seek has nowhere to land
        // on a non-seekable pb, and it ignores that failure: the new producer would keep reading
        // wherever the stream stands (or from byte 0 after a fresh reopen) and label those bytes
        // segment `idx`. That is the same fabricated-position content the declaration exists to
        // keep out, only silent instead of audible. Surface the loss; the host's re-request with
        // a shifted start timestamp is the recovery path.
        if sequentialOriginPinsProducerToZero {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) refused: a sequential origin can only be "
                + "read from byte 0, so the reposition would mislabel content; surfacing source failure",
                category: .session
            )
            surfaceVODSourceFailure(FFmpegErr.eio, "Source cannot be repositioned")
            return
        }
        restartLock.lock()
        let shouldRun = restartCoalescer.begin(idx, authoritative: authoritative)
        let seekTime = segmentStartSecondsLocked(idx) // under lock; segmentPlan guarded by restartLock (#38)
        restartLock.unlock()
        guard shouldRun else {
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) coalesced behind in-flight restart",
                category: .session
            )
            return
        }
        onSeekStateChanged?(true, seekTime) // publish seek in-flight until coalesced run drains (#38)
        var target = idx
        while true {
            performRestart(at: target)
            restartLock.lock()
            let nextTarget = restartCoalescer.next(justRan: target)
            let nextSeekTime = nextTarget.flatMap { segmentStartSecondsLocked($0) }
            restartLock.unlock()
            guard let nextTarget else { break }
            EngineLog.emit(
                "[HLSVideoEngine] coalesced restart advancing to settled target idx=\(nextTarget)",
                category: .session
            )
            onSeekStateChanged?(true, nextSeekTime)
            target = nextTarget
        }
        onSeekStateChanged?(false, nil) // run settled; hand the falling edge to the landing watch (#38)
    }

    /// `segmentPlan[idx].startSeconds` on the AVPlayer/playlist axis, or nil
    /// if out of range. Caller must hold `restartLock` (segmentPlan is
    /// guarded by it).
    private func segmentStartSecondsLocked(_ idx: Int) -> Double? {
        guard idx >= 0, idx < segmentPlan.count else { return nil }
        return segmentPlan[idx].startSeconds
    }

    /// Segment index whose plan span covers `seconds` on the AVPlayer/playlist axis (the same axis
    /// `segmentStartSecondsLocked` uses). Last segment whose `startSeconds <= seconds`, clamped. Used to
    /// re-anchor the producer on AVPlayer's real position after a backpressure wedge (#65). Thread-safe.
    func segmentIndexForPlaylistTime(_ seconds: Double) -> Int {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard !segmentPlan.isEmpty else { return 0 }
        var lo = 0
        var hi = segmentPlan.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if segmentPlan[mid].startSeconds <= seconds { lo = mid + 1 } else { hi = mid }
        }
        return min(max(lo - 1, 0), segmentPlan.count - 1)
    }

    /// AE#141: whether the active producer's march can plausibly deliver the segment covering
    /// playlist time `seconds` without a re-anchor. The seek-deadline path asks this before
    /// preserving a "progressing" producer: progress toward a region the pending target is not
    /// in is not worth preserving (640 s target, march at ~316 s: 3x30 s serve timeouts ride to
    /// item death long before the march arrives). `true` with no provider (nothing to judge).
    func producerCoversPlaylistTime(_ seconds: Double) -> Bool {
        guard let prov = provider else { return true }
        return prov.activeMarchCovers(segmentIndexForPlaylistTime(seconds))
    }

    /// #93 restart latency: phase split for the "restart took" line, so a slow restart names the
    /// phase that ate the time (old-pump stop wait, wedged-reopen, demuxer seek, producer build).
    nonisolated static func restartPhaseSummary(
        stopWaitMs: Double, reopenMs: Double?, seekMs: Double, buildMs: Double
    ) -> String {
        var parts = ["stopWait=\(Int(stopWaitMs))ms"]
        if let reopenMs { parts.append("reopen=\(Int(reopenMs))ms") }
        parts.append("seek=\(Int(seekMs))ms")
        parts.append("build=\(Int(buildMs))ms")
        return parts.joined(separator: " ")
    }

    /// A new demuxer for the #79 / #169 reopen, registered for `stop()` before its blocking open, or
    /// nil when a stop already superseded the restart at `epoch`.
    func registerRestartReopenDemuxer(epoch: UInt64) -> Demuxer? {
        restartLock.lock()
        defer { restartLock.unlock() }
        guard sessionEpoch == epoch else { return nil }
        let fresh = Demuxer()
        restartReopenDemuxer = fresh
        return fresh
    }

    private func unregisterRestartReopenDemuxer(_ dem: Demuxer) {
        restartLock.lock()
        if restartReopenDemuxer === dem { restartReopenDemuxer = nil }
        restartLock.unlock()
    }

    // Driven exclusively through requestRestart(at:) so bursts coalesce (#35).
    private func performRestart(at idx: Int) {
        restartGate.lock()
        defer { restartGate.unlock() }

        restartLock.lock()
        guard idx >= 0, idx < segmentPlan.count, let dem = demuxer else {
            restartLock.unlock()
            return
        }
        let epoch = sessionEpoch
        let old = producer
        producer = nil
        let ab = audioBridge
        let targetStartPts = segmentPlan[idx].startPts
        let videoTb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        // AE#169 round 2: consume the suspect-dead mark (the demuxer's last read threw); this
        // restart replaces it via the #79 fresh-demuxer path instead of seeking the failed
        // connection.
        let demuxerSuspectDead = mainDemuxerSuspectDead
        mainDemuxerSuspectDead = false
        restartLock.unlock()

        // AE#443: off `restartLock`, and before `old.stop()` releases the muxer its byte total is read
        // from.
        retireProducer(old)

        let restartStart = DispatchTime.now()
        func msSince(_ t: DispatchTime) -> Double {
            Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
        }
        var stopWaitMs: Double = 0
        var reopenMs: Double? = nil
        var seekMs: Double = 0

        // The new producer reuses this demuxer unless we have to replace a wedged (#79) or
        // suspect-dead (#169) one, below.
        var activeDem = dem
        var freshDemuxer: Demuxer?
        var oldPumpExited = true
        if let old {
            old.stop()
            oldPumpExited = old.waitForFinish(timeout: 5.0)
            stopWaitMs = msSince(restartStart)
        }
        if !oldPumpExited || demuxerSuspectDead {
            // #79: the old pump is wedged in a blocking network read on the SHARED demuxer; stop() can't
            // unblock a socket read, so waitForFinish timed out. Reusing this demuxer makes the new
            // producer's first post-seek read queue behind that stuck read for the full ~20s
            // connStallTimeout (the reporter's ~25s restart), after which the abandoned reader also steals
            // the first packet. markClosed() aborts the stuck read immediately (the existing thread-safe
            // unblock) but dooms the demuxer, so open a FRESH one and hand it to the new producer. Open
            // FIRST, abort only on success, so a reopen failure falls back to the prior abandon behaviour
            // (no regression) rather than poisoning the only demuxer. Scoped to the VOD single-demuxer
            // scrub case; the side-source / live-reopen paths keep their existing behaviour.
            // AE#169 round 2 takes the same path when the pump exited BECAUSE the demuxer's read
            // threw: the connection is known-bad, so the revive gets one fresh connection instead
            // of seeking the demuxer that just failed.
            if !isLiveSession, sideAudioDemuxer == nil, let fresh = registerRestartReopenDemuxer(epoch: epoch) {
                let reopenStart = DispatchTime.now()
                do {
                    // .restartReopen: bounded find_stream_info budget; the FULL playback budget was
                    // the bulk of a 44 s wedge-reopen over WAN (#93 residual). The pass itself must
                    // run so video_delay resolves, else B-frame dts arrive broken (#93 judder).
                    // A sequential origin keeps its declaration on the fresh open too: a ranged
                    // reopen would splice fabricated-position bytes into the new pump.
                    try fresh.open(
                        url: sourceURL, extraHeaders: sourceHTTPHeaders,
                        profile: restartReopenProfile,
                        isLive: false)
                    dem.markClosed() // abort any wedged read now that the replacement is ready
                    freshDemuxer = fresh
                    activeDem = fresh
                    EngineLog.emit(
                        "[HLSVideoEngine] restart at idx=\(idx): "
                        + (oldPumpExited
                            ? "#169 demuxer suspect-dead after read error; "
                            : "old producer wedged in a read past 5s; aborted it and ")
                        + "reopened a fresh demuxer",
                        category: .session
                    )
                } catch {
                    unregisterRestartReopenDemuxer(fresh)
                    fresh.close()
                    EngineLog.emit(
                        "[HLSVideoEngine] restart at idx=\(idx): "
                        + (oldPumpExited ? "#169 suspect-dead demuxer" : "old producer wedged")
                        + "; reopen failed (\(error)), reusing the demuxer",
                        category: .session
                    )
                }
                reopenMs = msSince(reopenStart)
            } else if !oldPumpExited {
                EngineLog.emit(
                    "[HLSVideoEngine] restart at idx=\(idx): old producer didn't exit within 5s, abandoning it "
                    + "(its in-flight read shares the demuxer and may consume the first post-seek packet; "
                    + "if the new session starts a GOP late, this is why)",
                    category: .session
                )
            }
        }

        // Seek outside restartLock (network-bound). Concurrent stop() calls markClosed() so the
        // seek fails fast instead of racing teardown.
        let seekStart = DispatchTime.now()
        seekToProducerStart(activeDem, targetPts: targetStartPts, readStart: producerReadStart(activeDem))
        // AE#782: after the seek, so a container whose seek reads (a TS bisection) spends none of it.
        activeDem.notePlaybackRepositioned()
        // Re-arm bridge PTS rebase so the encoder timeline starts from the new demuxer cursor.
        ab?.startSegment()
        seekMs = msSince(seekStart)

        // Re-validate: a stop() landing during waits bumped sessionEpoch; don't resurrect into a torn-down session.
        restartLock.lock()
        if let freshDemuxer, restartReopenDemuxer === freshDemuxer { restartReopenDemuxer = nil }
        guard sessionEpoch == epoch else {
            restartLock.unlock()
            // #79: a reopened demuxer (replacing a wedged one) must not leak when stop() superseded us.
            freshDemuxer?.close()
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx): superseded by stop(), unwinding",
                category: .session
            )
            return
        }
        // #79: install the reopened demuxer only inside the validated section so makeProducer reads it and a
        // concurrent teardown can't race a resurrected demuxer into a torn-down session.
        if let freshDemuxer {
            demuxer = freshDemuxer
            retireDemuxer(dem)   // AE#443: nothing puts this one back, so the swap is already final
            // #433: the network axis belongs to the reader that is SERVING. The aborted one owned the
            // `.reconnecting` the host is still reading, and its pump can outlive this swap, so it is
            // unwired here rather than left able to speak for a session it no longer feeds. The incoming
            // reader takes the sink, and (new-listener rule in `NetworkPhaseGate`) announces its own first
            // delivery even though it already served this session's `find_stream_info` into a nil sink.
            dem.onNetworkPhaseChanged = nil
            freshDemuxer.onNetworkPhaseChanged = onNetworkPhaseChanged   // re-wire stall signal onto the reopened demuxer (#85)
            freshDemuxer.playIntentProvider = playIntentProvider   // and the pause bound its held connection is judged on (#377)
        }
        do {
            let newProd = try makeProducer(baseIndex: idx)
            producer = newProd
            restartLock.unlock()
            newProd.start()
        } catch {
            restartLock.unlock()
            EngineLog.emit(
                "[HLSVideoEngine] restart at idx=\(idx) failed: \(error)",
                category: .session
            )
            return
        }

        let elapsedMs = msSince(restartStart)
        let absoluteTargetSeconds = Double(targetStartPts) * Double(videoTb.num) / Double(videoTb.den)
        // #416: the outgoing pump's run ends where it got to and the new one begins here. Whatever
        // lies between the two was skipped, and a subtitle set stranded on the near side of that
        // gap can no longer be read as the line still on screen at the landing.
        subtitlePacketStore.noteHarvestAnchor(at: absoluteTargetSeconds)
        // build = everything after the seek (re-validation, muxer/producer construction, start).
        let buildMs = max(0, elapsedMs - stopWaitMs - (reopenMs ?? 0) - seekMs)
        EngineLog.emit(
            "[HLSVideoEngine] producer restarted at idx=\(idx) (seek=\(String(format: "%.2f", absoluteTargetSeconds))s [absolute source-PTS], restart took \(String(format: "%.0f", elapsedMs))ms; "
            + Self.restartPhaseSummary(stopWaitMs: stopWaitMs, reopenMs: reopenMs, seekMs: seekMs, buildMs: buildMs) + ")",
            category: .session
        )
    }

}

extension HLSVideoEngine {
    /// Puts the demuxer where the first producer starts: no-op at segment 0. Seeks on the video
    /// stream's exact plan timestamp and forbids an earlier landing. A global time seek can choose
    /// the previous sync point in a multi-stream MP4, leaving the producer to scan a whole GOP over
    /// the origin before writing anything (#191).
    func seekToInitialProducerStart(_ dem: Demuxer) {
        let plan = segmentPlan
        guard initialProducerBaseIndex > 0, initialProducerBaseIndex < plan.count else { return }
        seekToProducerStart(dem, targetPts: plan[initialProducerBaseIndex].startPts,
                            readStart: producerReadStart(dem))
    }

    /// How far before its first segment a producer reads: as far back as the stage that remembers
    /// furthest, so every stage reaches the boundary in the state continuous playback left it in and the
    /// producer cuts the segment continuous playback cut.
    /// - The audio bridge's runs (`AudioTranscodingBridge.preRollSeconds`), and a positive audio delay
    ///   on top: the sound that plays at the boundary was read that much earlier.
    /// - Copied audio: the packet playing across the boundary opens the segment (`AudioRunPlan`). A
    ///   container that seeks each stream to its own sample reads it with an at-or-before seek to the
    ///   boundary itself; any other reads it only from before the boundary.
    /// - Where the container stores no decode times (`Demuxer.storesDecodeTimes`), libavformat's
    ///   rebuilding of them from the `video_delay` pictures before each packet.
    /// What must be read from before the boundary is before its keyframe, and a read starts there only
    /// at the keyframe before, so those stages ask for a tick before it.
    func producerReadStart(_ dem: Demuxer) -> (preRollSeconds: Double, atOrBefore: Bool) {
        var seconds = (audioBridge?.preRollSeconds ?? 0) + max(0, audioDelaySeconds)
        var atOrBefore = false
        let tick = dem.stream(at: videoStreamIndex).flatMap { stream -> Double? in
            let tb = stream.pointee.time_base
            return tb.den > 0 ? Double(tb.num) / Double(tb.den) : nil
        } ?? 0
        if savedAudioConfig != nil, audioBridge == nil {
            if dem.seeksEachStream { atOrBefore = true } else { seconds = max(seconds, tick) }
        }
        if !dem.storesDecodeTimes, let stream = dem.stream(at: videoStreamIndex),
           stream.pointee.codecpar.pointee.video_delay > 0 {
            seconds = max(seconds, tick)
        }
        return (seconds, atOrBefore || seconds > 0)
    }

    /// Where a producer starting at the plan's `targetPts` reads from. Without pre-roll: the exact
    /// video-stream plan timestamp as the lower bound, since a global time seek can choose a much
    /// earlier sync point in a multi-stream MP4 and leave the producer scanning a whole GOP over the
    /// origin (#191). With it, or where a stage reads at or before the boundary (`producerReadStart`):
    /// the sync point at or before, the producer dropping the video up to the target's keyframe.
    func seekToProducerStart(_ dem: Demuxer, targetPts: Int64,
                             readStart: (preRollSeconds: Double, atOrBefore: Bool)) {
        let tb = savedVideoConfig?.timeBase ?? AVRational(num: 1, den: 1000)
        let preRollTicks = tb.num > 0 ? Int64((readStart.preRollSeconds * Double(tb.den) / Double(tb.num)).rounded(.up)) : 0
        let readFrom = targetPts - preRollTicks
        // Disc plans use folded multi-clip timestamps that are not valid raw seek targets; their
        // tables seek to the sync point at or before.
        if dem.isDiscSource || !dem.seek(to: readFrom, streamIndex: videoStreamIndex, atOrBefore: readStart.atOrBefore) {
            dem.seek(to: Double(readFrom) * Double(tb.num) / Double(tb.den))
        }
    }
}

/// The fragment builder of the source-keyframe preview, behind a lock: its muxer stages each build
/// under a name taken from the index and every preview builds index 0, and it reads the session's
/// codec parameters, which `stop()` frees once `close()` has returned.
final class PreviewKeyframeBuilder: @unchecked Sendable {
    private let builder: IFrameFragmentBuilder
    private let lock = NSLock()
    private var closed = false

    init(_ builder: IFrameFragmentBuilder) {
        self.builder = builder
    }

    /// One keyframe at file time 0, as a standalone fMP4's init and fragment.
    func build(payload: Data, durationSeconds: Double) -> IFrameFragmentBuilder.Output? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return builder.build(payload: payload, index: 0, startSeconds: 0,
                             durationSeconds: max(durationSeconds, 0.04))
    }

    /// Waits for a build in flight; every later call answers nil.
    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
