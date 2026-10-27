import CoreMedia
import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Drives one playback session's read-to-mux pipeline via a per-segment
/// `MP4SegmentMuxer` writing into `SegmentCache`. Forward-only; backward
/// scrubs restart with a new instance at a non-zero `baseIndex`.
final class HLSSegmentProducer: @unchecked Sendable {

    // MARK: - Errors

    enum ProducerError: Error, CustomStringConvertible, LocalizedError {
        case muxerAllocFailed(code: Int32)
        case streamCreationFailed
        case copyParametersFailed(code: Int32)
        case writeHeaderFailed(code: Int32)

        var description: String {
            switch self {
            case .muxerAllocFailed(let c):     return "HLSSegmentProducer: avformat_alloc_output_context2 for hls failed (\(c))"
            case .streamCreationFailed:        return "HLSSegmentProducer: avformat_new_stream failed"
            case .copyParametersFailed(let c): return "HLSSegmentProducer: avcodec_parameters_copy failed (\(c))"
            case .writeHeaderFailed(let c):    return "HLSSegmentProducer: avformat_write_header failed (\(c))"
            }
        }

        var errorDescription: String? { description }
    }

    /// Per-stream codec config carried from `HLSVideoEngine` into the muxer setup.
    struct StreamConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let timeBase: AVRational
        /// Override the codec_tag emitted by the mp4 sub-muxer. Used to
        /// force `dvh1` / `hvc1` / `avc1` instead of FFmpeg's defaults
        /// of `hev1` / `h264`, which AVPlayer rejects.
        let codecTagOverride: String?
        /// What the muxer does with the source dvcC record. See `MP4SegmentMuxer.DoviConfigPolicy`.
        let doviConfig: MP4SegmentMuxer.DoviConfigPolicy
        /// Per-packet RPU conversion P7 -> 8.1 (HEVC P7 on DV panel). The container dvcC is a separate
        /// decision (`doviConfig`); this one rewrites the bitstream.
        let convertP7ToProfile81: Bool
        /// Optional color-signaling override forwarded to `MP4SegmentMuxer.ColorOverride`.
        let colorOverride: MP4SegmentMuxer.ColorOverride?
        /// Optional replacement for `codecpar.extradata` before write_header.
        let extradataOverride: [UInt8]?
        /// Framing measured on real packets (#365). Nil falls back to deriving it from the extradata,
        /// which is only correct while the two agree; on a source where they do not, every walker
        /// downstream (A53 captions, the DV P7 RPU rewrite) reads the packet at the wrong offsets.
        let nalFramingOverride: VideoNALFraming?
        /// Forwarded to `MP4SegmentMuxer.VideoConfig.convertsAnnexBSamples`. The packets stay Annex B
        /// up to the muxer, so `nalFramingOverride` keeps describing them.
        let convertsAnnexBSamples: Bool
        /// The session's BIT-1 framing verdict, handed to every muxer this producer builds for the
        /// program's own track (audit BIT-104).
        let nalFramingLatch: NALFramingLatch?
        /// Forwarded to `MP4SegmentMuxer.VideoConfig.stereo`.
        let stereo: StereoVideoSignal?
        /// AE#886: the exact frame grid of a constant-rate track on a coarse time base. Non-nil gives
        /// the muxer the grid's time base and puts every on-grid frame onto its slot.
        let frameGrid: CFRFrameGrid?

        init(
            codecpar: UnsafePointer<AVCodecParameters>,
            timeBase: AVRational,
            codecTagOverride: String?,
            doviConfig: MP4SegmentMuxer.DoviConfigPolicy = .keep,
            convertP7ToProfile81: Bool = false,
            colorOverride: MP4SegmentMuxer.ColorOverride? = nil,
            extradataOverride: [UInt8]? = nil,
            nalFramingOverride: VideoNALFraming? = nil,
            convertsAnnexBSamples: Bool = false,
            nalFramingLatch: NALFramingLatch? = nil,
            stereo: StereoVideoSignal? = nil,
            frameGrid: CFRFrameGrid? = nil
        ) {
            self.stereo = stereo
            self.frameGrid = frameGrid
            self.codecpar = codecpar
            self.timeBase = timeBase
            self.codecTagOverride = codecTagOverride
            self.doviConfig = doviConfig
            self.convertP7ToProfile81 = convertP7ToProfile81
            self.colorOverride = colorOverride
            self.extradataOverride = extradataOverride
            self.nalFramingOverride = nalFramingOverride
            self.convertsAnnexBSamples = convertsAnnexBSamples
            self.nalFramingLatch = nalFramingLatch
        }
    }

    /// How a stream-copied audio track's packets are framed in the source, and so what comes off
    /// them before they are muxed.
    enum AudioFraming: Equatable {
        /// As the muxer takes them (MP4 and Matroska access units, linear PCM).
        case raw
        /// ADTS AAC (MPEG-TS, a raw .aac): a 7 or 9 byte header per frame.
        case adts
        /// LOAS/LATM AAC (`LATM`): the frame inside each AudioMuxElement. `config` is the
        /// AudioSpecificConfig the init segment declares, which the stream's elements must keep.
        case latm(config: [UInt8])
        /// Blu-ray LPCM (`BluRayLPCM`): the samples behind each packet's header, which must keep
        /// declaring this format.
        case bluRayLPCM(BluRayLPCM)
    }

    /// Audio wiring for stream-copy (e.g. EAC3-JOC Atmos) or the bridge (TrueHD/DTS, ...).
    ///
    /// The producer reads its source in one layer and times it in another, and each has its own time
    /// base. `demuxTimeBase` is what the demuxer hands packets over in, and only reading the source
    /// uses it: merging two demuxers into decode order, the live replay guard (which knows a re-read
    /// packet by its timestamps), the recording, the played-media ledger. `timeBase` is what every
    /// audio packet is in from where the pump takes it on, and everything that times audio uses it: a
    /// stream-copied packet is placed into samples there (`CopiedAudioTiming`), a bridged one is fed
    /// on as demuxed. `inputTimeBase` is what the muxer is handed: the samples for a copy, the
    /// encoder's for a bridge.
    struct AudioConfig {
        let codecpar: UnsafePointer<AVCodecParameters>
        let sourceStreamIndex: Int32
        let demuxTimeBase: AVRational
        let timeBase: AVRational
        let inputTimeBase: AVRational
        /// Non-nil routes each packet through bridge.feed and muxes the packets it returns.
        var bridge: (any AudioTranscodingBridge)?
        /// The framing a stream-copied track's packets arrive in.
        let framing: AudioFraming
        /// AE#458: the source track's language as ISO 639-2/T, carried into every muxer this config builds
        /// (a producer restart rebuilds one, so it has to live on the config, not on the first muxer).
        let language: String?
        /// A bridged track's first timestamp (`AVStream.start_time`, `timeBase`), nil when the container
        /// states none: where its first frame sits, the origin of the bridge's `SourceGrid`.
        let sourceStart: Int64?
        /// A stream-copied track's placement into `timeBase`; nil for a bridge.
        let copiedTiming: CopiedAudioTiming?
        /// One coded frame in `timeBase`: how far a packet that states no duration, or no timestamp at
        /// all, is taken to reach.
        let frameDuration: Int64

        /// A stream-copied track. `codecpar` is what the muxer is given, which can differ from the
        /// stream's own (an LATM stream's AAC, a Blu-ray LPCM stream's PCM).
        init(copying stream: UnsafePointer<AVStream>,
             codecpar: UnsafePointer<AVCodecParameters>,
             sourceStreamIndex: Int32,
             framing: AudioFraming = .raw,
             language: String? = nil) {
            let timing = CopiedAudioTiming(stream: stream, codecpar: codecpar)
            self.codecpar = codecpar
            self.sourceStreamIndex = sourceStreamIndex
            self.demuxTimeBase = timing.demuxTimeBase
            self.timeBase = timing.timeBase
            self.inputTimeBase = timing.timeBase
            self.bridge = nil
            self.framing = framing
            self.language = language
            self.sourceStart = nil
            self.copiedTiming = timing
            self.frameDuration = Self.codedFrameSamples(codecpar)
        }

        /// A bridged track: `bridge` is fed the stream's packets as demuxed, and `codecpar` describes
        /// what it hands on.
        init(bridging stream: UnsafePointer<AVStream>,
             codecpar: UnsafePointer<AVCodecParameters>,
             sourceStreamIndex: Int32,
             bridge: any AudioTranscodingBridge,
             language: String? = nil) {
            let tb = stream.pointee.time_base
            self.codecpar = codecpar
            self.sourceStreamIndex = sourceStreamIndex
            self.demuxTimeBase = tb
            self.timeBase = tb
            self.inputTimeBase = bridge.encoderTimeBase
            self.bridge = bridge
            self.framing = .raw
            self.language = language
            self.sourceStart = stream.pointee.start_time == Int64.min ? nil : stream.pointee.start_time
            self.copiedTiming = nil
            let rate = stream.pointee.codecpar.pointee.sample_rate
            self.frameDuration = rate > 0
                ? max(1, av_rescale_q(Self.codedFrameSamples(stream.pointee.codecpar), AVRational(num: 1, den: rate), tb))
                : 1
        }

        /// Samples in one coded frame: the codec's stated frame size, a fixed-block FLAC stream's
        /// block, or the frame length of the codec family.
        static func codedFrameSamples(_ codecpar: UnsafePointer<AVCodecParameters>) -> Int64 {
            let par = codecpar.pointee
            if par.frame_size > 0 { return Int64(par.frame_size) }
            if let declared = FLACStreamInfo.fixedBlockSize(codecpar) { return declared }
            switch par.codec_id {
            case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3: return 1536
            case AV_CODEC_ID_AAC: return 1024
            case AV_CODEC_ID_MP3: return 1152
            case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC: return 4096
            default: return 1024
            }
        }
    }

    // MARK: - State

    private let demuxer: Demuxer

    /// Non-nil for demuxed-audio HLS ingest (ARD-style: video-only variant + separate audio rendition).
    /// Pump pull-merges by DTS; audio classified by origin not stream index (numbering is independent,
    /// side index can alias main video index). Owned by HLSVideoEngine.
    private let sideAudioDemuxer: Demuxer?

    /// AE#560: the live recording sink, read on the pump thread for every source packet. It gets
    /// its own lock rather than sharing `restartLock`: the tap is on the hot path and must never
    /// contend with a restart.
    fileprivate let recordingSinkLock = NSLock()
    fileprivate var recordingSink: LiveRecordingSink?

    /// One-packet lookahead per source for the dual-demuxer pull-merge (yields lower-DTS first).
    private var mergeMainLookahead: UnsafeMutablePointer<AVPacket>?
    private var mergeSideLookahead: UnsafeMutablePointer<AVPacket>?

    /// Synthesized program-clock timestamps for packed-audio HLS (raw ADTS AAC rendition).
    /// FFmpeg's "aac" demuxer ignores Apple's ID3 PRIV anchor; synthesizing from the PRIV
    /// value puts side-audio on the same 90 kHz clock as the video.
    struct PackedAudioSynthClock {
        private(set) var nextPts: Int64
        /// Fallback advance (1024 samples in stream TB) when demuxer duration is zero.
        let fallbackDurationPts: Int64

        init(startPts: Int64, fallbackDurationPts: Int64) {
            self.nextPts = startPts
            self.fallbackDurationPts = max(1, fallbackDurationPts)
        }

        mutating func stamp(packetDuration: Int64) -> Int64 {
            let pts = nextPts
            nextPts += packetDuration > 0 ? packetDuration : fallbackDurationPts
            return pts
        }
    }

    private var packedSideAudioClock: PackedAudioSynthClock?
    /// First EOF on either merge source ends the stream; draining the survivor produces silent/frozen tail.
    private var mergeMainEOF = false
    private var mergeSideEOF = false
    /// The video stream chosen at open. An SSAI ad on a new PID arrives under it too (`Demuxer` follows
    /// the program, `noteProgramChange`).
    private let videoStreamIndex: Int32
    private let cache: SegmentCache
    /// Segment index offset; 0 for initial-start, non-zero for restart sessions.
    private let baseIndex: Int
    /// The segment index this producer is anchored at (#93 residual: the provider skips firing
    /// restarts at indices the active producer demonstrably covers).
    var anchoredBaseIndex: Int { baseIndex }

    /// Source video TB, carried to rescale timestamps (avformat_write_header rewrites the muxer's TB).
    private let sourceVideoTimeBase: AVRational
    /// AE#886: `videoConfig.frameGrid` on VOD, nil on live. Pump-thread counters for the finish line.
    private let frameGrid: CFRFrameGrid?
    private var griddedVideoPackets = 0
    private var offGridVideoPackets = 0

    /// The time base AVPlayer is served this session's video in: the frame grid's where the session has one, the
    /// source's otherwise, the same for every producer of the session.
    private var servedVideoTimeBase: AVRational { frameGrid?.outputTimeBase ?? sourceVideoTimeBase }

    /// The time AVPlayer is served the video packet `packet` (item axis, source time base) at, as the write serves it:
    /// its slot on the frame grid where it lies on one, its own time in ``servedVideoTimeBase`` otherwise. The overlay's
    /// taps name its unit by it. Nil for a packet with no presentation time.
    private func servedVideoTime(_ packet: UnsafePointer<AVPacket>) -> ServedVideoTime? {
        let pts = packet.pointee.pts, dts = packet.pointee.dts
        guard pts != Int64.min else { return nil }
        let timeBase = servedVideoTimeBase
        if let gridded = frameGrid?.place(pts: pts, dts: dts, duration: packet.pointee.duration, shift: videoShiftPts) {
            return ServedVideoTime(pts: gridded.pts, dts: gridded.dts, timeBase: timeBase)
        }
        return ServedVideoTime(pts: av_rescale_q(pts, sourceVideoTimeBase, timeBase),
                               dts: dts == Int64.min ? Int64.min : av_rescale_q(dts, sourceVideoTimeBase, timeBase),
                               timeBase: timeBase)
    }
    private let videoConfig: StreamConfig
    private let audioConfig: AudioConfig?

    /// Start PTS (source video TB) for each segment at baseIndex+i; used to detect segment crossings.
    private let segmentBoundaries: [Int64]

    /// Source PTS of plan time 0 (the plan's `firstKeyframePts`). The item axis every consumer sees is
    /// `sourcePts - planAnchorVideoPts`, so this is what maps an item-axis timestamp back onto a plan
    /// boundary. Deliberately NOT `videoShiftPts`: the shift additionally carries whatever this
    /// producer's gate overshot its restart target by (AE#268).
    private let planAnchorVideoPts: Int64

    /// Live mode: cuts at keyframes past targetSegmentDurationSeconds; ignores segmentBoundaries.
    private let isLive: Bool

    /// #368: a sequential-origin VOD session folds timeline discontinuities the way live does.
    /// IPTV timeshift archives are chunked recordings; each chunk restarts near PTS 0, and
    /// libavformat's 33-bit wrap correction turns the backward seam into +2^33 (device: dts delta
    /// 8226410192 ticks, 363524400 + 8226410192 = 2^33 exactly). Without a rebase that leap reaches
    /// the cutter as item-axis time and walks its index to the plan tail, after which the session is
    /// structurally dead (frozen playlist, permanent park, refused re-anchor). This folds them
    /// for forward-only VOD on the producer path. `isSourceReplay` stays in the shared path untouched: it requires a
    /// recent unplanned reconnect, which a sequential origin (single connection, no reconnect)
    /// can never have.
    private let foldsSequentialTimeline: Bool

    /// The timeline-rebase gate for both stream rebases: live program boundaries and sequential
    /// chunk seams share one definition of "discontinuity" (the thresholds below).
    private var rebasesTimelineOnDiscontinuity: Bool { isLive || foldsSequentialTimeline }

    private var liveCurrentSegmentIndex: Int
    private var liveSegmentStartPtsSeconds: Double = 0
    private var liveFirstSegmentOpened = false

    /// Start-PTS (seconds) per live segment index; removed once reported to keep map bounded.
    private var liveSegmentStartByIndex: [Int: Double] = [:]

    /// Fires synchronously on the pump thread per finalized live segment (index, duration, startSeconds, discontinuous).
    var onLiveSegmentFinalized: (@Sendable (Int, Double, Double, Bool) -> Void)?
    /// A live versioned init's colour (a programme or ad switch, a parameter-set change), reported with the start of
    /// its first segment on the output axis (the item clock) when that segment is finalized, ahead of playback.
    var onLiveVideoColour: (@Sendable (_ startSeconds: Double, _ colour: ColorDescription) -> Void)?
    /// The colour of each versioned init by the segment it opens on, until that segment is finalized. Pump thread.
    private var liveColourBySegment: [Int: ColorDescription] = [:]
    /// AE#684: the sound a finalized live segment carries (index, first and last audio packet on the
    /// output axis, seconds). Fired just before `onLiveSegmentFinalized` for the same index.
    var onLiveSegmentSound: (@Sendable (Int, Double, Double) -> Void)?
    /// Keyed by segment index; a nil value is a segment cut with no audio packet in it.
    private var liveSegmentSoundByIndex: [Int: (first: Double, last: Double)?] = [:]
    /// AE#684: set for the length of one merged read, so a second reader thread trips the assertion there.
    private var mergedReadInFlight = false

    /// AE#443: the resident segment count the live runaway park may use, from the session that owns the
    /// window (`VideoSegmentProvider.liveResidentParkCap`). Unset leaves the static floor, which is the
    /// pre-#443 behaviour.
    var liveResidentCapProvider: (@Sendable () -> Int)?

    /// Sequential-VOD twin of `onLiveSegmentFinalized` (index, real duration in seconds): feeds
    /// the append playlist whose EXTINF must match the media actually muxed. Set only for
    /// sequential-origin sessions; nil keeps the historical VOD behavior byte-identical.
    var onSequentialSegmentFinalized: (@Sendable (Int, Double) -> Void)?
    /// Fired once when the pump reaches true source EOF (not a stop/teardown): the append
    /// playlist completes with ENDLIST.
    var onSequentialSourceEnded: (@Sendable () -> Void)?
    /// Item-axis start (seconds) per VOD segment, recorded at the #65 ledger site as each
    /// segment opens. Pump-thread only.
    private var vodSegmentStartByIndex: [Int: Double] = [:]
    /// Capture and duration arrive in either order: the muxer rotation can fire off an AUDIO
    /// packet crossing the boundary before the first video packet of the new segment has
    /// recorded its start (the duration source). The report fires once BOTH are in. Pump-thread only.
    private var seqCapturedAwaitingDuration: Set<Int> = []
    private var seqDurationAwaitingCapture: [Int: Double] = [:]
    /// The most recent segment index the ledger recorded a start for: a long GOP can SKIP plan
    /// indices entirely (a 5.76 s cut spans two 4 s boundaries), so duration pairing runs against
    /// the last RECORDED index, and the skipped holes report duration 0 (the playlist renderer
    /// omits zero-duration entries). Pump-thread only.
    private var lastSeqLedgerSeg = Int.min
    /// The provider's append API is strictly contiguous; captures, holes and the EOF tail can
    /// resolve out of order, so reports funnel through this small reorder buffer. Pump-thread only.
    private var seqNextReportIndex: Int? = nil
    private var seqReadyReports: [Int: Double] = [:]

    /// #369: highest sequential index the append playlist can currently advertise (only entries
    /// with a real duration get a URI). Pump-thread only; read by the advance park to detect a
    /// release target beyond the advertisable frontier.
    private var seqHighestAdvertisedIndex = Int.min

    /// #369: one-shot latches for the containment logs. Pump-thread only.
    private var loggedVideoWriteFailure = false
    private var loggedSequentialParkSkip = false

    /// Order-preserving funnel for sequential finalize reports.
    private func emitSequentialReport(index: Int, duration: Double) {
        // Anchored on the pump's first segment, not on the first report: a hole a long first GOP
        // skipped is known before that segment's capture lands, and anchoring on the hole would
        // leave every later report waiting for an index below it.
        let base = seqNextReportIndex ?? min(index, baseIndex)
        seqNextReportIndex = base
        seqReadyReports[index] = duration
        var next = base
        while let d = seqReadyReports.removeValue(forKey: next) {
            onSequentialSegmentFinalized?(next, d)
            if d > 0 { seqHighestAdvertisedIndex = next }   // #369: zero-duration holes get no URI
            next += 1
        }
        seqNextReportIndex = next
    }

    /// #369: the advance park releases on a consumer fetch of `target`, but a sequential append
    /// playlist can only advertise up to the frontier this pump's OWN finalize reports have fed
    /// it, so parking on an index beyond that is waiting for oneself (field case: a fold-to-tail
    /// parked at target=364 while the playlist ended at seg61). A negative target releases
    /// instantly, so it is no deadlock. Pure for the unit test.
    static func sequentialParkWouldSelfDeadlock(target: Int, highestAdvertised: Int) -> Bool {
        target >= 0 && target > highestAdvertised
    }

    /// Forward discontinuity threshold. Distinct from NOPTS-dts repair (+1 tick scale); only fires on genuine multi-second leaps.
    static let discontinuityThresholdSeconds: Double = 10.0

    /// Tighter backward threshold (1.5 s) because any backward leap past the 0.5 s monotonic-glitch ceiling is a program boundary.
    /// 10 s symmetric threshold left a dead zone for short SSAI bumpers (~5 s reset); audio stutter resulted.
    static let discontinuityBackwardThresholdSeconds: Double = 1.5

    /// #368: rebase math of the video-stream timeline rebase; pure so the 2^33 chunk-seam wrap can be
    /// pinned in a unit test against the device trace. Output dts continues one fallback frame past
    /// the last output, whatever the source leaped to.
    static func rebasedVideoShift(
        srcDts: Int64,
        lastSrcDts: Int64,
        oldShift: Int64,
        fallbackDurationPts: Int64
    ) -> (newShift: Int64, continuationDts: Int64) {
        let lastOutputDts = SourceTimestampBounds.difference(lastSrcDts, oldShift)
        let continuationDts = SourceTimestampBounds.sum(lastOutputDts, max(fallbackDurationPts, 1))
        return (SourceTimestampBounds.difference(srcDts, continuationDts), continuationDts)
    }

    /// Derive audio shift so boundary packet lands exactly on the video seam regardless of source base.
    /// Fixes amux ad creatives (Pluto: video clock starts at 0, audio near 2^33); copying video shift directly hangs audio.
    static func seamDerivedAudioShift(
        audioBoundarySrcDts: Int64,
        seamOutAudioTb: Int64
    ) -> Int64 {
        SourceTimestampBounds.difference(audioBoundarySrcDts, seamOutAudioTb)
    }

    /// Raw source PTS of the previous video packet (before shift); used for live discontinuity detection.
    private var lastRawVideoPts: Int64 = Int64.min

    /// Pending #EXT-X-DISCONTINUITY for the next segment; latched on detection, cleared on segment open.
    private var pendingDiscontinuityFlag: Bool = false

    /// Forces a cut at the next keyframe regardless of the 4 s minimum; prevents #EXT-X-DISCONTINUITY arriving one segment late.
    private var pendingForceCutFlag: Bool = false

    /// Set when SSAI program switch moves videoStreamIndex to a new video PID; triggers a fresh muxer (versioned-init EXT-X-MAP).
    private var pendingVideoProgramSwitch: Bool = false

    /// #133 follow-up: whether the pending versioned-init rotation is an SSAI ad creative (new PID, carries its
    /// own DV/color signaling so the program's overrides are dropped) or a same-PID in-band parameter-set change
    /// (encoder restart / regional splice on the same program, whose overrides must be kept). Read by rotateMuxer.
    private var pendingReinitIsAdCreative: Bool = false

    /// Ad creative's video config from in-band SPS/PPS (mid-stream demuxer codecpar has width/height == 0).
    private var pendingAdVideoConfig: InBandVideoConfig?

    /// The pending rotation goes back to the stream chosen at open: its init is built from the open's own
    /// configuration, not from in-band parameter sets (`pendingAdVideoConfig` is nil then).
    private var pendingReinitUsesOpenedConfig = false

    /// The streams the video and audio this pump muxes come from now: the ones chosen at open until a
    /// program change hands a role to another PID (`Demuxer.sourceStream(of:)`).
    private lazy var videoSourceStream: Int32 = videoStreamIndex
    private lazy var audioSourceStream: Int32 = audioConfig?.sourceStreamIndex ?? -1

    /// A program change moved the video role (`Demuxer` hands the new PID over under the index chosen
    /// at open). Until the keyframe the switch can open on, the new stream's
    /// packets are held out of the running init: an ad creative opens on in-band SPS/PPS (#133's shape),
    /// the stream chosen at open on any keyframe, its configuration being the open's.
    private var awaitingProgramSwitch: ProgramSuccession.Change?

    /// The audio role is on a stream whose codec differs from the open's (live only; VOD rebuilds on the
    /// software path instead): its packets cannot go into this init, so they are left out until the role
    /// is back on a codec the init describes.
    private var audioRoleUnmuxable = false

    /// #133 follow-up: Annex-B SPS+PPS backing the CURRENT muxer's avcC box. The fMP4 avcC is frozen at
    /// avformat_write_header, so an in-band parameter-set change on the SAME video PID (encoder restart / regional
    /// opt-out splice, common on UK DVB via Xtream) leaves the panel decoding new slices against a stale avcC ->
    /// green frames + libav "non-existing PPS/SPS" bursts, recurring mid-stream long after the join. Comparing each
    /// keyframe's in-band sets against this triggers a versioned-init muxer rotation (the same EXT-X-MAP path SSAI
    /// uses), independent of whether the demuxer emits AV_PKT_DATA_NEW_EXTRADATA. Set at gate-open and each rotation.
    private var activeMuxerVideoExtradata: [UInt8]?
    private var vodH264Configuration: H264ConfigurationTracker?
    private var vodHEVCConfiguration: HEVCConfigurationTracker?

    /// #133 follow-up diag: count of same-PID in-band parameter-set changes rotated in place, surfaced in the log.
    private var samePIDReinitCount = 0

    /// #133: initial live-join video config reconstructed from the gating IDR's in-band SPS/PPS. Set when a
    /// mid-stream MPEG-TS join left the probed codecpar at 0x0 (probe joined before any SPS); consumed by the
    /// FIRST allocateMuxer so avformat_write_header gets real dimensions instead of failing -22 (dead channel).
    private var pendingJoinVideoConfig: InBandVideoConfig?

    /// Cross-stream rebase pairing. Video rebase is master; audio derives its shift from its OWN boundary
    /// srcDts and the shared seam OUTPUT position (not the video shift) so differing audio source bases
    /// (amux ads: video dts 0, audio near 2^33) are absorbed. Delta-based handoff accumulated per-pod A/V
    /// drift; absolute re-anchoring zeroes that. `pendingAudioInheritSeamOut` waits for audio's boundary
    /// packet (video usually crosses first). `lastIndependentAudioRebase` handles audio-first interleave.
    /// All pairing state expires after `rebasePairingWindowSeconds`.
    private var pendingAudioInheritSeamOut: (seamOutAudioTb: Int64, at: Date)? = nil
    private var lastIndependentAudioRebase: (boundarySrcDts: Int64, at: Date)? = nil
    private var pendingAudioShiftOverride: (seamOutAudioTb: Int64, boundarySrcDts: Int64, at: Date)? = nil
    private static let rebasePairingWindowSeconds: TimeInterval = 5.0

    /// Deduplicates AV_PKT_DATA_NEW_EXTRADATA detection (some demuxers re-emit identical side data periodically).
    private var lastSeenVideoExtradata: Data? = nil
    private var codecParamChangeCount = 0

    /// Discontinuity flag per live segment index; mirrors liveSegmentStartByIndex lifetime.
    private var liveSegmentDiscontinuousByIndex: [Int: Bool] = [:]
    private var loggedFirstDiscontinuity: Bool = false

    private let targetSegmentDurationSeconds: Double
    /// Real audio frame handed to every muxer this producer builds, so moov (with its packet-derived
    /// dec3/dac3/dmlp) is written at init instead of at the first cut. Two origins, one field:
    /// - AE#222 seeds it from the host, and only on a session that already proved its first segment
    ///   carries no audio (nil on a normal session).
    /// - Every audio frame a muxer accepts then replaces it, so a LATER allocation (same-PID
    ///   parameter-set rotation, SSAI program switch) starts primed too. Video leads audio across a seam,
    ///   so a rotated muxer's first cut can arrive before any post-seam audio packet exists; unprimed,
    ///   that cut defers for a sample entry the bridge's encoder latency will never deliver in time and
    ///   the pump dies with `muxerFailed`.
    ///
    /// Pump-thread confined: written only from the two audio write sites, read only from `allocateMuxer`,
    /// and every muxer allocation goes through `ensureMuxer` on the pump thread.
    private var audioMoovPrimeFrame: [UInt8]?
    /// True when the session's audio codec derives its mp4 sample entry from a parsed packet
    /// (AC-3/E-AC-3/TrueHD); only then is a per-frame prime copy worth the memcpy. AAC never copies.
    private let capturesAudioPrimeFrames: Bool
    /// Latched when a cut deferred for want of an audio sample entry; the pump then scans forward for one
    /// real audio frame and exits with `.needsAudioSampleEntryPrime` so the host can rebuild primed.
    private var cutDeferredAwaitingAudioSampleEntry: Bool = false
    private var _capturedAudioMoovPrimeFrame: [UInt8]?
    /// Frame captured by the pump's prime scan; read by the host after the pump exits.
    var capturedAudioMoovPrimeFrame: [UInt8]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _capturedAudioMoovPrimeFrame
    }
    private var _audioMoovPrimeUnobtainable = false
    /// AE#366: the search finished everywhere it can look and this track yielded nothing, as opposed
    /// to a read that failed on the way. Structural, so the session records it and later producers
    /// skip the search instead of paying it again per revive attempt (~256 MiB of reads each).
    var audioMoovPrimeUnobtainable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _audioMoovPrimeUnobtainable
    }
    /// Set by the host from a previous producer's verdict; skips the search entirely.
    private let audioMoovPrimeKnownUnobtainable: Bool

    /// AE#396: the bridge's own account of what it did with the source, for the pump-finished handler.
    /// Nil for a stream-copy session, which has no bridge and whose analogous verdict is
    /// `audioMoovPrimeUnobtainable`.
    var audioBridgeFeedStats: AudioBridge.FeedStats? { audioConfig?.bridge?.feedStats }
    /// One file the producer writes per segment, with the cache it is adopted into (`HLSOutputShape`).
    /// Pump thread only; `muxer` changes only through `installMuxer`, under `stateLock`, which the
    /// telemetry getters read it under.
    private final class Rendition {
        enum Track { case video, audio }
        let track: Track
        let cache: SegmentCache
        var muxer: MP4SegmentMuxer?
        /// The index `muxer` is writing.
        var segmentIndex: Int = .min
        /// Latched once this producer's first muxer of the file emits ftyp+moov; later inits are versions.
        var initCaptured = false
        /// The highest index this producer has served into `cache`, cut or without samples.
        var head: Int = .min
        /// The audio track's time base in its muxer, latched when one is built (`serveEmptyAudio`).
        var audioTimeBase: AVRational?
        init(track: Track, cache: SegmentCache) {
            self.track = track
            self.cache = cache
        }
        var name: String { track == .video ? "seg" : "audio" }
    }
    /// The file each segment's video goes into; in the muxed shape its audio too.
    private let videoFile: Rendition
    /// The demuxed shape's audio rendition (`HLSOutputShape.demuxed`); nil when muxed.
    private let audioFile: Rendition?
    /// AE#443: totals folded off muxers this producer has ROTATED away. A rotation (program switch, ad
    /// pod, a rebuilt muxer after a failure) hands the session a fresh `ByteCounter`, so a read of the
    /// current muxer alone drops everything the previous ones emitted, and the "lifetime" it is read as
    /// silently means "since the last rotation". Guarded by `stateLock` with `videoFile.muxer` itself.
    private var retiredMuxerBytes: Int = 0
    private var retiredMuxerFragmentCuts: Int = 0


    /// Last valid dts per stream (source TB); used to repair NOPTS dts via lastValidDts+1.
    private var lastVideoSourceDts: Int64 = Int64.min
    private var lastAudioSourceDts: Int64 = Int64.min

    /// Pump-thread-only packet history for exact overlap after a live source reconnect.
    private var liveReplayGuard = LivePacketReplayGuard()
    private var interruptedReplayHistory: LivePacketReplayGuard?

    /// Called only after the predecessor pump finished and before this pump starts.
    /// Cache continuation owns the admitted frontier, including media not rendered yet;
    /// that media remains in the retained cache, so it must not be appended a second time.
    func continueLiveReplayHistory(from predecessor: HLSSegmentProducer) {
        guard isLive, predecessor.isLive,
              sourceVideoTimeBase.num == predecessor.sourceVideoTimeBase.num,
              sourceVideoTimeBase.den == predecessor.sourceVideoTimeBase.den,
              videoStreamIndex == predecessor.videoStreamIndex,
              audioConfig?.sourceStreamIndex == predecessor.audioConfig?.sourceStreamIndex,
              audioConfig?.demuxTimeBase.num == predecessor.audioConfig?.demuxTimeBase.num,
              audioConfig?.demuxTimeBase.den == predecessor.audioConfig?.demuxTimeBase.den,
              audioConfig?.timeBase.num == predecessor.audioConfig?.timeBase.num,
              audioConfig?.timeBase.den == predecessor.audioConfig?.timeBase.den else { return }
        liveReplayGuard = (predecessor.interruptedReplayHistory ?? predecessor.liveReplayGuard).sourceContinuation()
        lastVideoSourceDts = predecessor.lastVideoSourceDts
        lastAudioSourceDts = predecessor.lastAudioSourceDts
        EngineLog.emit("[HLSSegmentProducer] live source replay history continued: entries=\(liveReplayGuard.historyEntryCount)",
                       category: .session)
    }
    private var replayPending: [ReplayBufferedPacket] = []
    private var replayReady: [ReplayBufferedPacket] = []
    private var replayReadyIndex = 0
    private var replayPendingBytes = 0
    private var replayDeferredError: Error?
    private var damagedPacketLogCounts: [String: Int] = [:]
    private static let maximumReplayPendingBytes = LivePacketReplayGuard.maximumPendingBytes
    private static let maximumReplayPendingPackets = LivePacketReplayGuard.maximumPendingPackets

    /// AE#432: last GENUINE source dts per stream and the frame stride learned from it. A repaired
    /// timestamp says nothing about the source's cadence, so it is deliberately not fed back here.
    private var lastGenuineVideoSourceDts: Int64 = Int64.min
    private var lastGenuineAudioSourceDts: Int64 = Int64.min
    private var videoSourceStrideTicks: Int64 = 0
    private var audioSourceStrideTicks: Int64 = 0
    private var loggedFirstSynthesizedTimestamp = false

    /// First dts ever seen per stream; replay detection: backward rebase landing near this + recent reconnect = server replay.
    private var firstSeenVideoSourceDts: Int64 = Int64.min
    private var firstSeenAudioSourceDts: Int64 = Int64.min

    private static let sourceReplayReconnectWindowSeconds: TimeInterval = 30
    private static let sourceReplayStartWindowSeconds: Double = 10

    /// 2^33, the MPEG-TS 33-bit PTS/DTS clock. FFmpeg's wrap correction adds exactly this when the
    /// raw timestamp jumps backward across the wrap, so a source that renumbers its clock from zero
    /// reaches us as a dts of `2^33 + (small raw value)` rather than as a backward jump (#405).
    static let mpegTSWrapTicks: Int64 = 8_589_934_592

    /// Fallback duration (source video TB) for the last fragment packet when matroska omits BlockDuration.
    /// mp4 muxer uses pkt->duration only for the last trun sample; duration=0 writes trun.last.sample_duration=0.
    private let videoFallbackDurationPts: Int64

    /// Same for stream-copy audio (AC3/EAC3: frame_size/sample_rate; AAC: 1024/sample_rate).

    /// One-packet look-behind; next packet's dts fills pending.duration when per-block duration is missing.
    private var pendingVideoPkt: UnsafeMutablePointer<AVPacket>?
    /// What the LATM elements of a stream-copied AAC track are read with (`AudioFraming.latm`).
    private var latmReader = LATM.Reader()
    /// Packets of a stream-copied track dropped because their framing could not be taken off.
    private var unframeableAudioPackets = 0
    private var pendingAudioPkt: UnsafeMutablePointer<AVPacket>?

    /// Live segment index captured when pending packet was examined; the live cutter advances at keyframes.
    private var pendingVideoSegIndex: Int = 0
    /// AE#412: item-axis timestamp of the FIRST random-access point routed into each segment this
    /// epoch has open, consumed at adopt. Keyed by the muxer's index, not the cutter's: audio can
    /// have advanced the muxer past a boundary the keyframe-gated cutter folded, and a fetch asks
    /// for the segment the bytes ended up in. Pump thread only, like every other routing field.
    private var firstSyncItemPtsBySegment: [Int: Int64] = [:]
    private var pendingAudioSegIndex: Int = 0

    /// A packet routed to its segment, muxed once the cut gate lets it through: `write` muxes it into
    /// that segment's muxer and frees it, `free` frees it unwritten.
    private struct GatedWrite {
        let write: (MP4SegmentMuxer) -> Void
        let free: () -> Void

        static func freeing(_ packet: UnsafeMutablePointer<AVPacket>) -> () -> Void {
            { var p: UnsafeMutablePointer<AVPacket>? = packet; trackedPacketFree(&p) }
        }
    }
    /// VOD routed by time: the muxer moves on to a segment once every track has reached it
    /// (`SegmentCutGate`), so a segment holds the same packets whichever run cut it. Nil where audio
    /// follows the video cutter (live, sequential origins). Set at the pump's start, pump thread only.
    private var cutGate: SegmentCutGate<GatedWrite>?

    /// A sequential origin's playlist advertises a segment from the VIDEO cut ledger (its EXTINF is
    /// the distance between two keyframe-gated opens, and a plan index no keyframe opened is a hole
    /// with no URI). Audio routed by time against the plan would open that hole on its own wherever
    /// the source's GOP is longer than the stride, and the video after it would land in a file the
    /// playlist never lists: a remote MKV with an 11 s first GOP lost 4 to 11 s that way and stalled
    /// AVPlayer at the end of seg0. So there, as on live, audio follows the video cutter.
    private var audioFollowsVideoCut: Bool { !isLive && onSequentialSegmentFinalized != nil }

    /// VOD keyframe-gated cutter: opens each segment at the IRAP that reaches its plan boundary (#92).
    private var vodCutter: VODSegmentCutter

    private var loggedFirstVideoPktInfo = false
    /// #133 follow-up diag: one-shot confirmation that the demuxer surfaces avcC changes as AV_PKT_DATA_NEW_EXTRADATA.
    private var loggedFirstVideoNewExtradata = false
    private var loggedP7ConversionFailure = false
    private var loggedEnhancementLayerType = false
    /// Latched false at SSAI program switch (ad creatives are H.264; mirrors muxer's isReinit ? false : videoConfig.convertP7ToProfile81).
    private var convertP7Active: Bool = false
    #if DualLayerDolbyVision
    /// `LoadOptions.felOverlay`: the P7 -> 8.1 rewrite keeps the enhancement layer and parameters for the
    /// overlay instead of dropping them. Set before the pump starts, on every producer of the session.
    var felTap: FelEnhancementTap?
    #endif
    /// A software overlay session (`HLSVideoEngine.overlayDecodesVideo`): every video packet is served as this
    /// placeholder's sample for its picture. Set before the pump starts, on every producer of the session.
    var overlayPlaceholder: OverlayPlaceholder?
    /// The overlay session's decode, handed every source video packet before the placeholder takes its place. Set
    /// with `overlayPlaceholder`.
    var overlayDecodeTap: OverlayDecodeTap?
    /// Whether this run's first segment has been released to AVPlayer (`releaseOverlayRunStart`). Pump thread only.
    private var overlayRunStartReleased = false
    /// Whether this producer has handed an overlay its first video unit, the one that opens its run. Pump thread only.
    private var overlayRunOpened = false
    /// Whether this producer feeds an overlay whose decode AVPlayer's start waits for: the software overlay's, or the
    /// FEL overlay's enhancement layer.
    private var holdsOverlayRunStart: Bool {
        #if DualLayerDolbyVision
        if felTap != nil { return true }
        #endif
        return overlayDecodeTap != nil
    }
    /// Bounds the wait for a run's first picture: a decoder that cannot produce it in this long would not keep up
    /// with the clock either, and AVPlayer is better told by a stall than by a wedged segment.
    static let overlayRunStartTimeout: TimeInterval = 5
    private var loggedFirstDtsBump = false
    private var loggedFirstDtsDrop = false

    /// Gate uses AV_PKT_FLAG_KEY (not libavformat's keyframe index) because MKV SimpleBlock keyframe bit can be off.
    /// Audio gate waits for video: without this, a non-IDR-keyframe miss puts video 10+ s past audio ("asynchron").
    private let restartTargetVideoPts: Int64

    /// AE#408: whether the plan promised that `restartTargetVideoPts` is a random-access point.
    /// True only for the keyframe-aligned plan, whose boundaries ARE container index entries. The
    /// uniform grid never claimed it, and a source-declared plan deliberately aims BELOW the segment's
    /// IRAP (AE#268), so neither may be re-anchored for opening past its target.
    private let boundaryClaimsRandomAccess: Bool

    /// AE#561: the axis `segmentBoundaries` are stamped on, so the cutter gate compares like with
    /// like. Decode for a mov/mp4 index, presentation for Matroska Cues; see `PlanBoundaryAxis`.
    private let planBoundaryAxis: PlanBoundaryAxis

    /// AE#408: the gate target actually in force. Starts at `restartTargetVideoPts` and moves BACK when
    /// the boundary turns out not to be openable, so the segment covers its own advertised start
    /// instead of carrying content from the far side of a keyframe drought.
    private var effectiveGateTargetPts: Int64
    private var gateBackoffAttempts = 0

    /// AE#408: the lowest timestamp already proven to carry no sync sample up to the boundary. Starts
    /// at the boundary itself and descends with each re-aim, so a deeper attempt escalates as soon as
    /// it reaches known-empty ground instead of re-reading it to the boundary every time.
    private var gateProvenEmptyFromPts: Int64
    private var restartTargetAudioDts: Int64
    private var audioWaitForVideo: Bool
    private var firstActualVideoDts: Int64 = Int64.min
    private var firstActualAudioDts: Int64 = Int64.min

    /// Layer 3 step 5: the highest segment index the session's subtitle consumers need this pump to have
    /// read through, past its forward window: a stream only the pump reads (a transport stream's, a
    /// disc's, a Matroska file's without subtitle Cues) reaches the packet store only as the pump reads
    /// it. Asked at every advance park; nil when nobody asks. The disk budget still bounds the run.
    var subtitleReadAheadReach: (@Sendable () -> Int?)?

    /// Layer 3 step 5: how far this pump has read the source, on the source axis (the video's decode
    /// time, every `sourceReadNoteStepSeconds`), and `.infinity` once it has read to the end. Everything
    /// the subtitle streams carry below it has been handed to the sinks below.
    var onSourceReadThrough: (@Sendable (Double) -> Void)?
    private var lastSourceReadNoted = -Double.infinity
    /// Small against every authored subtitle dwell, large against a packet.
    static let sourceReadNoteStepSeconds: Double = 0.5

    /// AE#514: the session's ledger of played-stream packet bytes, which the bitrate fields read at the
    /// playhead. Set once before `start()`, like the gate above; nil for hosts that drive the engine
    /// without a session (`aetherctl` probes, tests).
    var playedMediaLedger: PlayedMediaLedger?

    /// Forward-only producer restart counter; surfaced in live telemetry. Written on pump thread, read under packetCounterLock.
    var restartCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _restartCount
    }
    private var _restartCount: Int = 0
    func bumpRestartCount() {
        packetCounterLock.lock()
        _restartCount &+= 1
        packetCounterLock.unlock()
    }

    /// Audio-gate vs. video-gate gap in source-clock ms; read under packetCounterLock by telemetry sampler.
    var lastAVGapMs: Double {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _lastAVGapMs
    }
    private var _lastAVGapMs: Double = 0
    private func setLastAVGapMs(_ value: Double) {
        packetCounterLock.lock()
        _lastAVGapMs = value
        packetCounterLock.unlock()
    }

    /// PTS of first kept video packet (AV_PKT_FLAG_KEY); used to drop HEVC RASL leading B-frames (open-GOP CRA).
    private var firstActualVideoPts: Int64 = Int64.min
    private var loggedFirstLeadingDrop: Bool = false

    /// Pre-gate drop counters; surface the "lädt unendlich" failure mode when the gate never opens.
    private var pregateVideoDropCount: Int = 0
    /// AE#627: dropped packets that did carry the key flag. The wait line describes only the packet it
    /// is printed on, so without this a join gate refusing every keyframe read as a feed with none.
    private var pregateKeyDropCount: Int = 0
    private var pregateWaitStart: Date?
    private static let liveKeyframeGateTimeoutSeconds: TimeInterval = 15

    private var audioGateWaitStart: Date?
    /// 5 s is generous; a backward source-clock reset between video gate-open and first audio packet strands the target.
    private static let liveAudioGateTimeoutSeconds: TimeInterval = 5
    private var pregateAudioDropCount: Int = 0

    /// #74: head-of-stream audio that arrives before the first video packet, buffered (in read order)
    /// while the video gate is still waiting, then replayed in DTS order once it opens. Each entry owns
    /// its AVPacket. Without this the gate dropped the entire leading second of a wide-interleave source
    /// (audio muxed ahead of video), leaving a constant ~1 s A/V desync. Bounded by a byte cap; above it
    /// the original drop resumes.
    private var pregateAudioBuffer: [(UnsafeMutablePointer<AVPacket>, PacketOrigin)] = []
    private var pregateAudioBufferBytes: Int = 0
    private var pregateAudioReplaySorted = false
    /// Audit SEG-6: replay cursor into `pregateAudioBuffer`. Entries before it were handed to the pump
    /// (which owns and frees them); draining with removeFirst() was quadratic at TrueHD packet rates.
    private var pregateAudioReplayIndex = 0

    private var hasPregateAudioToReplay: Bool { pregateAudioReplayIndex < pregateAudioBuffer.count }

    private func freeUnreplayedPregateAudio() {
        for entry in pregateAudioBuffer[pregateAudioReplayIndex...] {
            var pkt: UnsafeMutablePointer<AVPacket>? = entry.0
            trackedPacketFree(&pkt)
        }
        pregateAudioBuffer.removeAll()
        pregateAudioReplayIndex = 0
        pregateAudioBufferBytes = 0
    }
    private var pregateAudioOverflowLogged = false
    private static let maxPregateAudioBufferBytes = 8 * 1024 * 1024

    /// Wall-clock of last finalized live segment; drives no-cut stall watchdog.
    private var lastLiveSegmentFinalizeAt: Date?
    /// AE#406: the no-cut window, and the timer that judges it. Live pumps only. Pump-thread-owned
    /// properties; the watchdog object itself is the only thing the timer touches.
    private var noCutWatchdog: NoCutStallWatchdog?
    private var noCutWatchdogTimer: DispatchSourceTimer?

    /// AE#443: is the live pump inside the runaway headroom park right now?
    ///
    /// The park looks exactly like a dead source from every consumer-side vantage point, and two
    /// separate diagnostics said so for three rounds of #443 ("the producer is starved, not the
    /// consumer", "source stopped delivering"). A held pump is not a starved one, and the difference
    /// is only knowable here. Its own lock: written on the pump thread, read from the stall ladder.
    private let parkStateLock = NSLock()
    private var _liveHeadroomParked = false
    var isLiveHeadroomParked: Bool {
        parkStateLock.lock()
        defer { parkStateLock.unlock() }
        return _liveHeadroomParked
    }
    private func setLiveHeadroomParked(_ parked: Bool) {
        parkStateLock.lock()
        _liveHeadroomParked = parked
        parkStateLock.unlock()
    }

    /// Whether the pump is held at its forward window right now (`awaitBackpressureRelease`): it cuts
    /// nothing more until a consumer fetch or a subtitle reach releases it. What a test waits for, rather
    /// than inferring the hold from a segment index that stopped moving for a while.
    private var _advanceParked = false
    var isAdvanceParked: Bool {
        parkStateLock.lock()
        defer { parkStateLock.unlock() }
        return _advanceParked
    }
    private func setAdvanceParked(_ parked: Bool) {
        parkStateLock.lock()
        _advanceParked = parked
        parkStateLock.unlock()
    }
    private let noCutWatchdogQueue = DispatchQueue(label: "aether.nocut.watchdog", qos: .userInitiated)
    /// Tick of the lifted watchdog: fine against both windows (10 s wedge, 35 s starvation) and
    /// cheap, one lock and a subtraction unless it has something to say. A private queue rather
    /// than the global pool, for the same reason `SlowServeSignal` uses one: a starving source is
    /// exactly when the pool is busiest, and a late watchdog is the defect being fixed.
    private static let noCutWatchdogTickSeconds: TimeInterval = 1
    /// Cutter-wedge timeout: pump reads at full rate but finalizes no segment (hostile SSAI ad pod).
    private static let liveSegmentStallTimeoutSeconds: TimeInterval = 10
    /// Source-starvation timeout: feed trickles (slow/flaky CDN). Ingest retries ~31 s then terminates;
    /// escalating at the tight wedge timeout turns one slow segment into a full host retune (device repro: hung on -1001).
    static let liveSourceStarvationTimeoutSeconds: TimeInterval = 35
    /// Read rate (pkt/s) threshold classifying a no-cut stall as cutter-wedge vs. source-starvation.
    /// Healthy 1080p25: ~60 pkt/s. Rate-based to avoid misreading a trickle that accumulated a high count (Alex Berlin: 137 pkts/13 s = 10.5 pkt/s).
    static let liveWedgeProgressRateThreshold: Double = 40
    /// #177: minimum video PTS advance (seconds) within a no-cut window for the stall to be
    /// reclassified as slow-but-healthy delivery (hold + re-arm) instead of a cutter wedge (retune).
    private static let liveSlowDeliveryPtsAdvanceSeconds: Double = 2
    /// #177: consecutive holds before a slow-delivery stall escalates to the host retune anyway.
    static let liveSlowDeliveryMaxHolds = 6

    /// #177 outcome of one no-cut watchdog evaluation.
    enum NoCutStallAction: Equatable {
        case keepReading
        case holdForSlowDelivery
        case exitForRetune
    }

    /// #177 pure decision: a wedge-classified no-cut stall whose video PTS is still advancing is a
    /// source delivering just below real-time (a 6 s segment simply has not fully arrived inside the
    /// 10 s timeout), not a stuck cutter. Retuning it re-joins behind the live edge, drains the buffer,
    /// and loops. Hold and re-arm instead, bounded by `liveSlowDeliveryMaxHolds`. A genuine SSAI wedge
    /// reads at full rate with frozen video PTS and still exits immediately; the source-starvation
    /// classification is untouched (its 35 s window with barely-advancing PTS is a dead source).
    ///
    /// AE#446 round 3: `servingOutageRunway` is the one case where a dead source must not be given up
    /// on. The session has already diagnosed the outage, closed its window with ENDLIST, and is
    /// feeding the consumer segments it holds; the exit tears down the read that is the only thing
    /// able to notice the source coming back, and takes a playing session with it. Measured on the
    /// harness with a 76 s outage: the read was aborted 35 s in while 46 s of runway were still
    /// playing, so the source delivering again at +76 s was never seen and the session held its last
    /// frame for the rest of the run. Bounded by the same hold budget, so a consumer that stops
    /// fetching with runway still listed cannot keep a dead source open for the whole session.
    /// AE#446 round 8: `hasEverProduced` is false while the producer has not cut anything at all,
    /// which is the window a JOIN is judged on rather than an outage. It decides one thing: a join
    /// is never classified as a wedge. The wedge reading is "the cutter is being fed and cannot
    /// cut", and before the first cut there is no evidence for it, because a cutter that has not
    /// reached its first keyframe reads exactly like one that cannot cut what it is given. Its
    /// deadline is 10 s, measured on a mid-session SSAI pod, and applying it to a join would retune
    /// a healthy channel with a long GOP. So a join waits out the 35 s starvation deadline, at any
    /// read rate, and neither hold applies to it: the #177 hold defers to video PTS that is still
    /// advancing, and the round-3 hold to a closed window still feeding its consumer, and a join
    /// that has cut nothing is delivering to nobody either way.
    static func noCutStallAction(
        stalledFor: TimeInterval,
        readRate: Double,
        videoPtsAdvanceSeconds: Double,
        consecutiveHolds: Int,
        servingOutageRunway: Bool = false,
        hasEverProduced: Bool = true
    ) -> NoCutStallAction {
        let isWedge = hasEverProduced && readRate >= liveWedgeProgressRateThreshold
        guard hasEverProduced else {
            return stalledFor > liveSourceStarvationTimeoutSeconds ? .exitForRetune : .keepReading
        }
        let timeout = isWedge ? liveSegmentStallTimeoutSeconds : liveSourceStarvationTimeoutSeconds
        guard stalledFor > timeout else { return .keepReading }
        if isWedge,
           videoPtsAdvanceSeconds >= liveSlowDeliveryPtsAdvanceSeconds,
           consecutiveHolds < liveSlowDeliveryMaxHolds {
            return .holdForSlowDelivery
        }
        // A wedge is a cutter that cannot cut what it is being given, which waiting does not fix; the
        // runway deferral is for a source that is not giving it anything.
        if !isWedge, servingOutageRunway, consecutiveHolds < liveSlowDeliveryMaxHolds {
            return .holdForSlowDelivery
        }
        return .exitForRetune
    }

    // MARK: - AE#432: a source that stops carrying timestamps

    /// Widest inter-packet delta still read as a frame interval. Anything past a second is a
    /// program boundary or a renumbered clock, not a cadence.
    static let maxSynthesizedStrideSeconds: Double = 1.0

    /// How far a repaired timestamp advances when the source carried neither dts nor pts.
    ///
    /// It used to advance one tick, which satisfies the muxer's monotonic invariant and nothing
    /// else: on the 90 kHz MPEG-TS axis that is 11 microseconds for a whole 20 ms frame. The live
    /// cutter's clock IS this timestamp (`liveShouldCut` below reads the pts a keyframe carries),
    /// so a run of timestamp-less packets froze the clock and the cutter could not cut again for as
    /// long as the run lasted: 1792 packets and 30 keyframes went into one 85 MB segment advertised
    /// as 0.5 s (AE#432).
    ///
    /// Cascade, most specific first: the demuxer's own claim for this packet, then the last genuine
    /// delta this stream showed, then the frame duration the producer already carries for the last
    /// trun sample, then the historical single tick for a stream that has never carried a usable
    /// timestamp at all. Each arm is capped at `maxStrideTicks` (audit SEG-101: a crafted
    /// BlockDuration near the source bound walked nine packets to Int64.max), the same second
    /// `updatedStrideTicks` already applies to a learned stride.
    static func repairStrideTicks(packetDuration: Int64, observedStride: Int64,
                                  fallbackDuration: Int64, maxStrideTicks: Int64 = .max) -> Int64 {
        let cap = Swift.max(maxStrideTicks, 1)
        if packetDuration > 0 { return Swift.min(packetDuration, cap) }
        if observedStride > 0 { return Swift.min(observedStride, cap) }
        if fallbackDuration > 0 { return Swift.min(fallbackDuration, cap) }
        return 1
    }

    /// Audit SEG-101: the dts a packet with neither timestamp gets, or nil when the walk would leave
    /// the plausible source range. The packet is then dropped, and the next genuine timestamp
    /// re-anchors the stream.
    static func synthesizedDts(anchor: Int64, stride: Int64) -> Int64? {
        let (dts, overflow) = anchor.addingReportingOverflow(stride)
        guard !overflow, SourceTimestampBounds.plausible(dts) == dts else { return nil }
        return dts
    }

    /// Adopts `dts - previousDts` as the stream's stride when it is forward and inside
    /// `maxStrideTicks`. A backward, standing or multi-second delta is a boundary or a replay, so
    /// the stride learned before it survives.
    static func updatedStrideTicks(current: Int64, previousDts: Int64, dts: Int64,
                                   maxStrideTicks: Int64) -> Int64 {
        guard previousDts != Int64.min, dts != Int64.min, maxStrideTicks > 0 else { return current }
        let delta = dts &- previousDts
        guard delta > 0, delta <= maxStrideTicks else { return current }
        return delta
    }

    /// The live cut rule, pure: a keyframe opens a new segment once its presentation time has moved
    /// `targetSeconds` past the open segment's start, or immediately when a program boundary forced
    /// a cut. Extracted so AE#432's wedge is testable against the rule the pump actually runs.
    static func liveShouldCut(ptsSeconds: Double, segmentStartSeconds: Double,
                              targetSeconds: Double, isKeyframe: Bool, forceCut: Bool) -> Bool {
        guard isKeyframe else { return false }
        return forceCut || ptsSeconds - segmentStartSeconds >= targetSeconds
    }

    // MARK: -

    private var lastPregateVideoLog: Int = 0
    private var lastPregateAudioLog: Int = 0
    private static let pregateLogInterval = 200
    /// AE#222 prime-scan bounds. 128 MiB is ~17 s of 60 Mbit/s UHD video, well past any real interleave gap
    /// (the reported source's audio starts ~4 s in), and the timeout covers a slow source rather than a
    /// far-away audio track.
    private static let moovPrimeScanByteCap = 128 * 1024 * 1024
    private static let moovPrimeScanTimeoutSeconds: TimeInterval = 30
    /// AE#366 seek-based hunt, used only after the forward scan came back empty. Per-probe budget is
    /// smaller than the forward scan's because a probe that lands inside the track's range finds a
    /// packet within one cluster; it is the POSITION that decides, not the depth.
    private static let moovPrimeHuntProbeByteCap = 32 * 1024 * 1024
    private static let moovPrimeHuntTimeoutSeconds: TimeInterval = 20
    private static let moovPrimeHuntFractions: [Double] = [0.5, 0.9, 0.25, 0.75]

    /// Desired video tfdt: 0 for baseIndex==0; plan[baseIndex].startSeconds for restarts. Audio inherits
    /// the video's shift.
    private let desiredFirstVideoTfdtPts: Int64

    /// Dynamic PTS shift = firstActualDts - desiredFirstTfdt; Int64.min = not yet computed.
    private var videoShiftPts: Int64 = Int64.min
    private var audioShiftPts: Int64 = Int64.min

    /// Max segments ahead of AVPlayer's highest fetched segment. Historically a constant (cut from 20 to
    /// 10; 4K HEVC ~10 MB/seg = 200 MB old buffer); now per session from `LoadOptions.forwardBufferSegments`
    /// via `HLSVideoEngine.forwardWindowSegments`. MUST equal the SegmentCache's forwardWindow so the muxer
    /// never writes past the cache's forward edge (a drift is exactly what stalls AVPlayer).
    private let bufferAheadSegments: Int

    /// #207: byte bound for an opt-in whole-source window. The segment ceiling is only a sanity bound,
    /// so the race-ahead parks once it has filled the session retention budget (`PrefetchDiskBudget`).
    /// 0 disables the park (live, and any host that never opted in stays far below its budget anyway).
    private let prefetchDiskBudgetBytes: Int

    /// AE#464: the host's audio offset. Fixed for the producer's life; a new value arrives as a new
    /// producer (see `MP4SegmentMuxer.audioDelaySeconds`). A bridge builds it into what it encodes,
    /// so a negative one cuts at the exact sample (`setOutputOffset`); stream-copied packets cannot be
    /// cut, so the muxer moves them and drops the ones it puts before zero.
    private let audioDelaySeconds: Double
    /// The fragment cadence inside a progressively delivered segment. Measured with `aetherctl play`
    /// on a Mac over a 6 Mbit/s origin (1080p HEVC at 2.7 Mbit/s, 3-9 s GOPs): playing after 1.9 s at
    /// 1 s fragments and 1.7 s at 0.5 s, against 2.3 s without progressive delivery. Each fragment
    /// costs a moof of a few hundred bytes.
    static let progressiveFragmentSeconds: Double = 0.5

    /// #65 stall diag: only log a park once it exceeds ~2 segment durations of zero playback progress, so normal
    /// backpressure (releases within one segment) stays silent and a real wedge surfaces its frozen tuple.
    private static let backpressureWedgeLogThresholdSeconds = 12

    /// #65 watchdog: break a VOD backpressure park once the consumer fetch target has been frozen this long.
    /// Set above the log threshold so the diag tuple surfaces first. The host then re-anchors the producer on
    /// AVPlayer's real position; a slow-but-advancing consumer never trips the detector, and seconds in which
    /// the rendered clock advanced do not count toward it (AE#649; see BackpressureWedgeDetector).
    private static let backpressureWedgeBreakThresholdSeconds = 24

    /// #207: a disk park is normal steady state for an opt-in prefetch, so it stays quiet until it has
    /// held long enough to be worth a line, then repeats every 30 s.
    private static let prefetchDiskParkLogThresholdSeconds = 10

    /// #93 retest fast path: break the park once the consumer fetch target AND the rendered clock have
    /// both been frozen this long while the consumer wants to play (rrgomes: the clock is provably flat
    /// within ~3 s of the park; the 24 s counter alone put recovery latency at 30-70 s). Only effective
    /// when `playbackPositionProvider` is wired; the dual-freeze guard is what keeps the short window
    /// safe (see BackpressureWedgeDetector.fastBreakThresholdSeconds).
    private static let backpressureWedgeFastBreakThresholdSeconds = 5

    /// Live disk runaway FLOOR for awaitLiveWindowHeadroom, for a session that cannot state its own
    /// window (`liveResidentCapProvider` unset). The live cap is `max(this, provider())`, and the
    /// provider's value is the sliding window plus slack, so the park always sits ABOVE the window.
    ///
    /// AE#443: this used to be the cap itself, and the claim above it was that a session could only
    /// approach it with a dead consumer. That was false for any window deeper than 180 segments: the
    /// playlist does not start sliding until `windowSegmentCount` segments exist, so the cache fills to
    /// the cap first and the pump parks there for the rest of the session. Measured on the loopback
    /// fixture at an 1800 s window and a 1 s cadence, an edge session with no seek at all: park at
    /// resident=180 after 179 s, never released, the edge frozen from that second on. The reporter of
    /// #443 measured the same shape against Jellyfin at a 3.9 s cadence, and 180 x 3.9 s is where his
    /// session froze, three campaigns running.
    private static let liveResidentSegmentCap = 180

    /// AE#286: how much produced-but-unfetched content has to sit ahead of the consumer before the
    /// pump's work stops being latency-critical. `HLSLocalServer` answers segment requests from a
    /// `.userInitiated` work queue, and a cache miss parks that thread in `cache.fetch` until this pump
    /// produces the segment, so a permanently demoted pump is a priority inversion dispatch cannot see.
    /// Held well below the `forwardWindow` the pump parks at, so the two states cannot flap.
    private static let pumpRelaxedLeadSeconds = 16.0

    /// `pumpRelaxedLeadSeconds` in this session's segments, floor 2.
    private var pumpRelaxedLeadSegments: Int {
        Self.relaxedLeadSegments(targetSegmentDurationSeconds: targetSegmentDurationSeconds)
    }

    static func relaxedLeadSegments(targetSegmentDurationSeconds: Double) -> Int {
        max(2, Int((pumpRelaxedLeadSeconds / max(1.0, targetSegmentDurationSeconds)).rounded(.up)))
    }

    /// Whether the pump may run at the relaxed (efficiency) QoS. Pure so the guards are testable
    /// without a session: `targetIndex < 0` is a consumer that has not fetched at all,
    /// `hasStartedRendering == false` is one still filling its startup buffer, and a short lead is a
    /// consumer sitting on the production head, which is a rebuffer in progress.
    ///
    /// `epochHighestStored` is what THIS pump has written since it started, not `cache.highestStoredIndex`.
    /// The cache's high-water is monotonic across producer epochs, so a pump restarted for a seek reads
    /// the previous epoch's head, computes a comfortable lead over content it has not produced, and
    /// demotes itself in the one window where the consumer is provably blocked on it. Measured: a
    /// restart at idx=127 with the old epoch at 135 demoted 5 ms into the seek landing.
    static func pumpMayRelax(hasStartedRendering: Bool, targetIndex: Int,
                             epochHighestStored: Int, relaxedLeadSegments: Int) -> Bool {
        guard hasStartedRendering, targetIndex >= 0, epochHighestStored >= 0 else { return false }
        return epochHighestStored - targetIndex >= relaxedLeadSegments
    }

    /// Pump-thread-only: the QoS class the pump last requested for itself, the segment index the last
    /// decision was taken at, the highest segment index THIS pump has written to the cache, and
    /// whether the pump has left its read loop. No lock; only `runPumpLoop` and its callees touch these.
    private var pumpQoSCurrent: qos_class_t = QOS_CLASS_USER_INITIATED
    private var pumpQoSLastSeg = Int.min
    private var pumpEpochHighestStored = Int.min
    private var pumpUnwinding = false
    /// AE#850: a segment boundary is not often enough to decide on. At 0.1x a single segment took
    /// 19 s of wall time on `.utility`, longer than the whole relaxed lead, so the promotion landed
    /// at lead -1 with AVPlayer already waiting. The pump also decides once a second in between.
    private var pumpQoSNextCheckNanos: UInt64 = 0
    private var pumpRelaxationRate = PumpRelaxationRateProbe()
    /// AE#850: set once the relaxed class has measured below real time. It outlives pump restarts:
    /// a seek does not make the decode, the bridge or the device any cheaper.
    private var pumpRelaxationRefused = false

    private let stateLock = NSLock()
    private var pumpStarted = false
    private var shouldStop = false
    /// #65: set when awaitBackpressureRelease breaks a frozen VOD park. runPumpLoop maps the resulting
    /// muxer-nil exit to .backpressureWedge so the host re-anchors rather than treating it as a failure.
    private var _backpressureWedgeBroken = false

    /// Video packet write counter; excludes bridge packets (different path). Read under packetCounterLock.
    private let packetCounterLock = NSLock()
    private var _packetsWrittenCount: Int = 0
    var packetsWrittenCount: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _packetsWrittenCount
    }
    private func bumpPacketsWritten() {
        packetCounterLock.lock()
        _packetsWrittenCount &+= 1
        packetCounterLock.unlock()
    }

    /// AE#169 round 3: pregate observability for the engine's starved-EOF re-anchor arm. A pump
    /// whose scan-forward gate never opened wrote nothing; the last keyframe it dropped BELOW the
    /// target is the true final random-access point the engine can re-anchor production on.
    private var _videoGateOpened = false
    private var _lastPregateDroppedKeyframePts: Int64 = Int64.min
    var videoGateOpened: Bool {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _videoGateOpened
    }
    var lastPregateDroppedKeyframePts: Int64 {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _lastPregateDroppedKeyframePts
    }
    /// AE#627: video packets the gate dropped before a keyframe starvation ended the pump. Non-zero
    /// means the source delivered video for the whole wait and none of it could open a segment.
    private var _starvedVideoDrops = 0
    var starvedVideoDrops: Int {
        packetCounterLock.lock()
        defer { packetCounterLock.unlock() }
        return _starvedVideoDrops
    }
    var hasRestartTarget: Bool { restartTargetVideoPts != Int64.min }
    private func markVideoGateOpened() {
        packetCounterLock.lock()
        _videoGateOpened = true
        packetCounterLock.unlock()
    }
    private func notePregateDroppedKeyframe(pts: Int64) {
        packetCounterLock.lock()
        if pts > _lastPregateDroppedKeyframePts { _lastPregateDroppedKeyframePts = pts }
        packetCounterLock.unlock()
    }

    /// AE#169 round 3 pure decision: whether a video packet opens the restart scan-forward gate.
    /// The gate target is a plan boundary (`segmentPlan[baseIndex].startPts`), and the packet is
    /// judged by presentation time. Comparing DTS dropped the exact IRAP the restart seeked for (a
    /// keyframe's DTS sits a reorder delay below its own PTS; same defect class as the #92 cutter
    /// fix): mid-file the next IRAP rescued the miss one GOP late, but at the file tail no later
    /// IRAP exists, so the unbounded VOD gate starved to EOF with zero packets written.
    ///
    /// AE#561 deliberately did NOT make this axis-matched the way the cutter gate is, and the
    /// reason is that the two answer different questions. The cutter decides which segment a packet
    /// belongs to, where being wrong by a composition offset costs a segment its IRAP, and it can
    /// afford exactness because it sees every packet. This gate decides where production STARTS
    /// after a seek, and being wrong in the strict direction costs the whole restart: the reported
    /// geometry (target 2878501, the anchor IRAP at dts 2878495 and pts 2878620) has the boundary
    /// falling BETWEEN that keyframe's two timestamps, so it matches neither axis and only the
    /// lenient comparison admits it. Since `pts >= dts` holds for any conforming stream, judging
    /// presentation time is the most permissive reading and cannot starve on a skew in either
    /// direction. What the axis buys here is knowing how much of the resulting overshoot is real,
    /// which is what `boundaryOpenToleranceTicks` spends it on.
    static func videoGateTargetSatisfied(pts: Int64, dts: Int64, targetPts: Int64) -> Bool {
        if targetPts == Int64.min { return true }
        let ts = pts != Int64.min ? pts : dts
        return ts != Int64.min && ts >= targetPts
    }

    // MARK: - AE#408: a boundary that is not a random-access point

    /// How far below the boundary each successive re-aim attempt targets, in seconds.
    ///
    /// The first step is deliberately short: the point at-or-before the boundary is what the segment
    /// needs, and aiming one segment back finds it whenever the source has any random access there at
    /// all. Wider steps exist for a real drought, and the list is the whole budget.
    ///
    /// AE#423: the steps are EVEN, not doubling. Each attempt opens on the first sync sample at or
    /// above where it aimed, so the distance between two steps is the worst case by which the gate can
    /// overshoot the last sample that would have covered the boundary, and a doubling step spends that
    /// error where it is largest. On the AE#408 fixture the 8 -> 16 jump aimed at 36.0, took 38.417,
    /// and never saw the 43.0 sitting between it and the boundary at 52.0: 4.6 s of landing accuracy
    /// given away for nothing. Even steps cost no more to walk, because `gateProvenEmptyFromPts` stops
    /// each scan at the previous aim rather than at the boundary, so an attempt reads its own window
    /// and not the whole drought. Same 32 s of reach as the doubling list.
    static let gateBackoffStepsSeconds: [Double] = [4, 8, 12, 16, 20, 24, 28, 32]

    /// Floor for the tolerance below; the reorder depth of the stream widens it (see
    /// `boundaryOpenToleranceTicks`).
    static let boundaryOpenToleranceSeconds: Double = 0.5

    /// AE#408: how far past the boundary a sync sample may present before it is worth going back for.
    ///
    /// The gate judges presentation time (AE#169 round 3), so where the plan's boundaries are DECODE
    /// timestamps even a perfectly formed index puts the keyframe's PTS a reorder delay above the
    /// boundary it was indexed at. Charging that skew a second seek would re-aim on every restart of
    /// a B-pyramid encode, so the tolerance covers the stream's own declared depth plus a frame, and
    /// never falls below the floor.
    ///
    /// AE#561: that reorder term pays for an AXIS MISMATCH, not for anything the stream does. A plan
    /// whose boundaries are PRESENTATION timestamps (Matroska Cues) has no such skew, a correctly
    /// indexed keyframe presents exactly at its boundary, and the term would only widen the window in
    /// which a genuinely late open escapes its re-aim. On that axis the tolerance is the floor, which
    /// sharpens the decision on the very container AE#408 was reported against. The floor still
    /// absorbs an index that is approximate rather than skewed, which Matroska Cues frequently are.
    static func boundaryOpenToleranceTicks(
        reorderFrames: Int32, frameDurationPts: Int64, floorTicks: Int64,
        planAxis: PlanBoundaryAxis = .decode
    ) -> Int64 {
        let frame = Swift.max(0, frameDurationPts)
        let reorder = planAxis == .decode ? Int64(Swift.max(0, reorderFrames)) &* frame : 0
        return Swift.max(floorTicks, reorder &+ frame)
    }

    /// How far past the target the scan reads before calling the boundary unopenable. A seek can land
    /// a reorder window early, and those frames present past the target while their own keyframe is
    /// still to come, so a single non-key packet is not evidence on its own.
    static let boundaryProbeGraceSeconds: Double = 1.0

    /// AE#408: proof that a boundary the plan called a random-access point is not one.
    ///
    /// Matroska Cues are seek points, not sync points, and libavformat enters every one of them into
    /// the index as `AVINDEX_KEYFRAME` regardless of the block's own keyframe flag
    /// (`matroska_add_index_entries`). A plan built from that index therefore advertises boundaries
    /// the producer cannot open on, and the reporting asset in AE#408 carried 11 s of them.
    ///
    /// `sawKeyframeBeforeTarget` is the veto: when the seek landed on a keyframe of its own BELOW the
    /// target, the packets presenting past it are that keyframe's reorder window and say nothing about
    /// the boundary.
    static func boundaryProvenNotRandomAccess(
        droppedPts: Int64, targetPts: Int64,
        sawKeyframeBeforeTarget: Bool, graceTicks: Int64
    ) -> Bool {
        guard targetPts != Int64.min, droppedPts != Int64.min else { return false }
        guard !sawKeyframeBeforeTarget else { return false }
        // The packet the plan named IS the answer when it lands exactly: no random access here.
        if droppedPts == targetPts { return true }
        return droppedPts >= targetPts &+ graceTicks
    }

    /// AE#408: whether the gate must re-aim below the boundary instead of opening on this keyframe.
    ///
    /// Opening past the boundary does not just start late, it makes the segment carry content from the
    /// far side of the gap while the playlist keeps claiming the boundary's own time. Every seek into
    /// that segment then lands that far off, which is the 3 to 14 s the reporter measured.
    static func shouldReanchorBeforeOpening(
        keyframePts: Int64, boundaryPts: Int64, toleranceTicks: Int64,
        attemptsUsed: Int, maxAttempts: Int
    ) -> Bool {
        guard boundaryPts != Int64.min, keyframePts != Int64.min else { return false }
        guard attemptsUsed < maxAttempts else { return false }
        return keyframePts > boundaryPts &+ toleranceTicks
    }

    /// Which item-axis timestamp the epoch's first frame is published at.
    ///
    /// On VOD it is the frame's own: item time is source time minus the plan anchor in every run, so
    /// a segment carries the same timestamps (and is cut at the same frames) whichever run made it.
    /// Measured with `play --picture-probe` on a fixture whose Cues sit 0.2 s below each sync sample:
    /// AVPlayer presents a segment that opens past its advertised start at the PLAYLIST position
    /// either way (AE#418), with no wait on the gap, so publishing the frame at its own time moves
    /// nothing on screen. Pinning it to the advertised start instead shifted the whole run by the
    /// overshoot, which moved every later cut in that run and made the segment cache hold different
    /// bytes for one index depending on where playback had started.
    ///
    /// Live keeps the pin for a late open: its target is the end of the previous epoch's output on
    /// a timeline nothing else describes, and the pin is what keeps that timeline free of a hole.
    ///
    /// Both operands must be on the ITEM axis. `actualFirstDts` is a source timestamp, and the two
    /// differ by the plan anchor on every source whose content does not start at PTS 0 (a Blu-ray
    /// beginning at 11.6 s, the restart-witness fixture at 0.083 s).
    ///
    /// AE#509: and never below zero. `tfdt` carries `unsigned int(64)` (ISO/IEC 14496-12), so a
    /// negative item axis is not expressible at all: movenc writes the value as-is and AVPlayer reads
    /// `baseMediaDecodeTime = 2^64 - |dts|`, about six million years, against a playlist that starts
    /// at 0. The item then fetches the whole window and places none of it, with no error and no
    /// stall of its own. libavformat produces those negative timestamps by design, not by accident:
    /// an MPEG-TS whose first DTS sits within 60 s of the 33-bit PTS wrap is classified
    /// `AV_PTS_WRAP_SUB_OFFSET` and every timestamp comes out 2^33 ticks low (demux.c, "correct first
    /// time stamps to negative values"). That is an ordinary live join, not an early-opening gate,
    /// and the clamp is what keeps the two apart.
    static func firstItemTfdtPts(
        actualFirstDts: Int64, desiredTfdtPts: Int64, planAnchorPts: Int64, isLive: Bool
    ) -> Int64 {
        guard actualFirstDts != Int64.min else { return desiredTfdtPts }
        let actualItemPts = actualFirstDts &- planAnchorPts
        guard isLive else { return max(0, actualItemPts) }
        return max(0, actualItemPts < desiredTfdtPts ? actualItemPts : desiredTfdtPts)
    }

    /// AE#418: the offset the HOST folds, which is not the offset the MUXER applies.
    ///
    /// Measured with `aetherctl play --picture-probe` against a fixture whose picture states its own
    /// source time: AVPlayer presents a segment at the position the PLAYLIST gives it, not at the
    /// tfdt the segment carries. So the axis a consumer reads is the distance between the first
    /// frame's source time and the segment's ADVERTISED start, whatever the muxer wrote. On a pinned
    /// (late) gate the pin makes the two identical, which is why publishing the mux shift held until
    /// the early-opening gate of AE#408 landed; on a re-aimed gate they differ by the whole re-aim,
    /// and the clock then ran that far ahead of the picture (captions early by the same amount).
    ///
    /// AE#418 round 4: taken on the first PTS, not the first DTS. A segment opens on a random-access
    /// point in DECODE order, and with B-frames that sample is presented `video_delay` frames later
    /// than it is decoded, so the two differ by exactly the composition offset the segment carries for
    /// it. This is an offset about what AVPlayer SHOWS, so it is measured where the picture is: the
    /// gate's own line already carried both numbers (`actual=42917 anchorPts=43000` on a 24 fps h264
    /// fixture with `has_b_frames=2`), and the axis was published from the decode one. Measured with
    /// `play --picture-probe`, that put the published axis 0.083 s under the truth on every epoch of
    /// a B-frame source and 0.000 s under it on the same fixture encoded without them.
    static func presentedShiftPts(actualFirstPts: Int64, desiredTfdtPts: Int64) -> Int64 {
        guard actualFirstPts != Int64.min, desiredTfdtPts != Int64.min else { return 0 }
        return actualFirstPts &- desiredTfdtPts
    }

    /// AE#418 round 5: how far after its own decode time the gating sample is PRESENTED, named on the
    /// gate-open line so a log says what reorder depth the gate opened at.
    ///
    /// Rounds 5 to 7 also composed with it, on the premise that a placement sits below its axis by
    /// some multiple of this. Round 8 measured a clip with no frame reordering at all, whose every
    /// gate opens with a lead of zero, sitting a frame below its axis on its third placement, which
    /// no multiple of zero describes. The composition measures that distance directly now; this stays
    /// a source fact worth printing.
    static func presentationLeadPts(actualFirstPts: Int64, actualFirstDts: Int64) -> Int64 {
        guard actualFirstPts != Int64.min, actualFirstDts != Int64.min else { return 0 }
        return Swift.max(0, actualFirstPts &- actualFirstDts)
    }

    /// AE#408: aim the gate below a boundary that cannot be opened on, so the segment covers its own
    /// advertised start. Returns false when there is nothing left to try, in which case the caller
    /// keeps the old behaviour (open at the next random-access point and carry the shift).
    ///
    /// Only for a plan whose boundaries CLAIM random access. The uniform grid never made that claim,
    /// and a source-declared plan aims below its IRAP on purpose (AE#268); re-aiming either would move
    /// the producer a segment back for no reason. Live is excluded because its target is a join point,
    /// not a plan boundary, and there is nothing behind it to seek to.
    private func reanchorGateBelowBoundary(reason: String) -> Bool {
        guard boundaryClaimsRandomAccess, !isLive,
              restartTargetVideoPts > Int64.min,
              sourceVideoTbSeconds > 0,
              gateBackoffAttempts < Self.gateBackoffStepsSeconds.count else { return false }
        // A side audio demuxer is a second source the engine positions itself; seeking only the main
        // one here would leave the merge reading from two different places.
        guard sideAudioDemuxer == nil else { return false }

        let step = Self.gateBackoffStepsSeconds[gateBackoffAttempts]
        let aim = Swift.max(planAnchorVideoPts, restartTargetVideoPts &- Int64(step / sourceVideoTbSeconds))
        guard aim < effectiveGateTargetPts else { return false }
        gateBackoffAttempts += 1
        // Everything from the abandoned aim up to the boundary has now been read without a sync
        // sample, so the next attempt escalates when it reaches here rather than reading it again.
        gateProvenEmptyFromPts = effectiveGateTargetPts

        guard demuxer.seek(to: aim, streamIndex: videoStreamIndex) else {
            EngineLog.emit(
                "[HLSSegmentProducer] boundary re-aim to \(aim) failed to seek; "
                + "opening at the next random-access point instead",
                category: .session
            )
            return false
        }
        discardPregateScanState()
        effectiveGateTargetPts = aim
        EngineLog.emit(
            "[HLSSegmentProducer] boundary \(restartTargetVideoPts) is not a random-access point "
            + "(\(reason)); re-aimed the gate \(String(format: "%.0f", step))s below it at \(aim) "
            + "so the segment covers its own start "
            + "(attempt \(gateBackoffAttempts)/\(Self.gateBackoffStepsSeconds.count))",
            category: .session
        )
        return true
    }

    /// Drop everything the closed gate accumulated, so a re-aimed scan starts clean. The pre-gate
    /// audio belongs to the abandoned position, and the source-dts anchors would read the backward
    /// seek as a timeline discontinuity.
    private func discardPregateScanState() {
        freeUnreplayedPregateAudio()
        pregateAudioReplaySorted = false
        pregateAudioOverflowLogged = false
        pregateVideoDropCount = 0
        pregateKeyDropCount = 0
        pregateAudioDropCount = 0
        lastPregateVideoLog = 0
        lastPregateAudioLog = 0
        pregateWaitStart = nil
        firstSeenVideoSourceDts = Int64.min
        firstSeenAudioSourceDts = Int64.min
        lastVideoSourceDts = Int64.min
        lastAudioSourceDts = Int64.min
        liveReplayGuard.reset()
        freeMergeLookaheads()
        packetCounterLock.lock()
        _lastPregateDroppedKeyframePts = Int64.min
        packetCounterLock.unlock()
    }

    var muxerLifetimeFragmentBytes: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retiredMuxerBytes + (videoFile.muxer?.lifetimeFragmentBytesEmitted ?? 0)
            + (audioFile?.muxer?.lifetimeFragmentBytesEmitted ?? 0)
    }

    var muxerFragmentCuts: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return retiredMuxerFragmentCuts + (videoFile.muxer?.fragmentCutCount ?? 0)
            + (audioFile?.muxer?.fragmentCutCount ?? 0)
    }

    /// The only way a file's muxer changes. Folds the outgoing muxer's totals in first, so every
    /// rotation site inherits the accounting instead of having to remember it (AE#443).
    private func installMuxer(_ new: MP4SegmentMuxer?, into file: Rendition) {
        stateLock.lock()
        if let outgoing = file.muxer {
            retiredMuxerBytes &+= outgoing.lifetimeFragmentBytesEmitted
            retiredMuxerFragmentCuts &+= outgoing.fragmentCutCount
        }
        file.muxer = new
        if let new, new.audioOutputStreamIndex >= 0 { file.audioTimeBase = new.muxerAudioTimeBase }
        stateLock.unlock()
    }

    private let finishCondition = NSCondition()
    private var didFinishFlag = false
    var didFinish: Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        return didFinishFlag
    }

    /// Fires once per producer when HDR10+ T.35 SEI prefix (B5 00 3C 00 01 04) first appears in a video packet.
    var onFirstHDR10PlusDetected: (@Sendable () -> Void)?

    /// #260: resolves the host's per-frame time observer at emission rather than holding it, so a host that
    /// installs one mid-session reaches the running producer without a data race on a stored closure. Set
    /// before `start()`; nil leaves the emission out entirely.
    var nativeVideoFrameTimeObserverProvider: (@Sendable () -> NativeVideoFrameTimeObserver?)?

    /// Monotonic producer generation, reported with every frame time so a consumer can drop entries from an
    /// epoch whose segments a restart has since rewritten (#260).
    let epoch: UInt64

    /// Fires at video gate-open with videoShiftPts (source video TB); re-fires on restart (matroska seek imprecision can shift).
    /// `firstItemTfdtPts` is this producer's planned first tfdt, i.e. the item-axis position (same TB) from which
    /// its shift applies. Everything below it on the item axis was muxed by an earlier producer under an earlier
    /// shift and may still be in AVPlayer's buffer, so a consumer needs the pair, not the shift alone (#260).
    /// VOD: the source-to-item normalization a finalized segment's bytes carry, seconds
    /// (`recordSegmentOpening`).
    var onSegmentWritten: (@Sendable (_ index: Int, _ carriedSeconds: Double) -> Void)?
    var onVideoShiftKnown: (@Sendable (_ shiftPts: Int64, _ firstItemTfdtPts: Int64, _ normalizationShiftPts: Int64) -> Void)?

    /// Fires at live program boundary with updated videoShiftPts and seamOutputSeconds (AVPlayer clock position of the seam).
    /// Distinct from onVideoShiftKnown: the new shift is at the producer edge, AVPlayer renders it buffer+holdback later.
    /// #368: also fires at a sequential chunk-seam rebase too; the source-PTS consumers (A53 caption tap,
    /// subtitle mapping) need the playlist axis moved the same way there.
    var onLiveTimelineRebase: (@Sendable (_ shiftPts: Int64, _ seamOutputSeconds: Double) -> Void)?

    enum PumpExitReason: Sendable, CustomStringConvertible {
        case eof
        case stopRequested
        case readError(code: Int32)
        case muxerFailed
        case videoConfigurationChanged(summary: String)
        /// AE#222: the first cut could not write moov because the audio sample entry is packet-derived
        /// (E-AC-3/AC-3/TrueHD) and the source's first segment carries no audio packet. The pump captured a
        /// real audio frame on its way out (`capturedAudioMoovPrimeFrame`); the host rebuilds with it as the
        /// muxer's moov prime, which keeps the stream-copy (and any Atmos) instead of falling back.
        case needsAudioSampleEntryPrime
        /// No AV_PKT_FLAG_KEY video packet within timeout; live only (VOD waits unbounded).
        case keyframeStarvation
        /// Source replay cannot safely continue in place; the host must negotiate a fresh session.
        case sourceReplay
        /// Pump read packets but finalized no segment for stall window (hostile SSAI ad pod wedge).
        case segmentStall
        /// VOD backpressure park frozen past the break threshold (consumer fetch target stuck, AVPlayer
        /// wedged and issuing no forward request). Host re-anchors the producer on AVPlayer's real
        /// position (#65). Live keeps its own watchdogs; this only fires on VOD.
        case backpressureWedge

        var description: String {
            switch self {
            case .eof: return "eof"
            case .stopRequested: return "stopRequested"
            case .readError(let code): return "readError(\(code))"
            case .muxerFailed: return "muxerFailed"
            case .videoConfigurationChanged: return "videoConfigurationChanged"
            case .needsAudioSampleEntryPrime: return "needsAudioSampleEntryPrime"
            case .keyframeStarvation: return "keyframeStarvation"
            case .sourceReplay: return "sourceReplay"
            case .segmentStall: return "segmentStall"
            case .backpressureWedge: return "backpressureWedge"
            }
        }
    }

    /// Whether the pump-exit in-flight segment may be adopted into the cache. A teardown mid-VOD
    /// (restart, wedge break, read error) leaves it PARTIAL: shorter content than the playlist's
    /// EXTINF under a full segment's index, with video and audio ending at different interleave
    /// drain points. Byte-budgeted retention keeps such a segment replayable (device: seeking back
    /// to 0 played a teardown-partial with ~2 s of A/V split), so VOD adopts only the natural EOF
    /// tail (a legitimately short final segment). Live always adopts: its playlist advertises the
    /// ACTUAL duration via reportLiveSegmentFinalized, so a short live tail is not a lie.
    static func shouldAdoptTeardownSegment(exitReason: PumpExitReason, isLive: Bool) -> Bool {
        if isLive { return true }
        if case .eof = exitReason { return true }
        return false
    }

    var onPumpFinished: (@Sendable (PumpExitReason) -> Void)?

    /// #65: reads whether AVPlayer currently wants to play (`timeControlStatus != .paused`), off the main
    /// actor. nil = assume wanting to play (preserves prior behaviour for tests + the live path). A paused
    /// consumer issues no forward fetch, so the VOD backpressure wedge detector must suspend while this is
    /// false instead of misreading the frozen fetch target as a wedge (issue #65 pause false-positive).
    var wantsToPlayProvider: (@Sendable () -> Bool)?

    /// #93 retest: reads AVPlayer's rendered (playlist-axis) position off the main actor. Feeds the
    /// backpressure wedge detector's fast path (park + flat clock + frozen fetch target -> single-digit
    /// detection instead of the 24 s counter). nil (tests, live) keeps the fast path inert.
    var playbackPositionProvider: (@Sendable () -> Double?)?

    /// AE#446 round 3: reads whether the session is serving a window it closed with ENDLIST because
    /// the source stopped delivering, with segments the consumer has not reached yet. While that is
    /// true the no-cut watchdog's starvation exit would tear down a session that is still handing out
    /// pictures, and with it the only read able to notice the source coming back. nil = false, which
    /// is the historical behaviour for tests and every non-live path.
    var outageRunwayProvider: (@Sendable () -> Bool)?

    /// #35/#93 startup guard: reads whether AVPlayer has ever presented a frame this item (its
    /// `timeControlStatus` reached `.playing` at least once), off the main actor. nil = assume started
    /// (preserves prior behaviour for tests + live). While false, the VOD backpressure wedge detector
    /// suspends: a flat rendered clock during cold pre-roll is not a wedge, and re-anchoring there flushes
    /// AVPlayer's forward buffer and livelocks a slow high-bitrate DV-master start ("loads forever").
    var hasStartedRenderingProvider: (@Sendable () -> Bool)?

    /// #77: in-band CC tap. When `closedCaptionStreamIndex >= 0` that source stream is kept (not
    /// discarded) and each of its packets is handed to `closedCaptionObserver` (read-only) then dropped,
    /// never muxed (output byte-identical). Set via init so it's in the keep-set; observer attached after.
    var closedCaptionStreamIndex: Int32 = -1
    var closedCaptionObserver: (@Sendable (UnsafePointer<AVPacket>, AVRational) -> Void)?

    /// #131: A53/SEI caption extraction. When set (the session has no demuxable CC stream) and the
    /// video codec is H.264/HEVC, every muxed video packet is scanned (GA94 prefilter, see
    /// `A53SEIParser`) and extracted cc_data triplets are handed over with the packet's
    /// source-timebase pts/dts, in decode order. Same lifecycle as `closedCaptionObserver`:
    /// attached after init, re-threaded onto every restart producer.
    var a53CaptionObserver: (@Sendable ([CCDataParser.CCTriplet], Int64, Int64, AVRational) -> Void)?
    private let a53CodecKind: A53SEIParser.CodecKind?
    private let a53NALFraming: A53SEIParser.NALFraming

    /// #133: latched at init. When true, the video gate withholds until a decodable access unit
    /// (in-band SPS+PPS and an IDR or immediate intra recovery point, AE#627) arrives, rather than
    /// opening on any AV_PKT_FLAG_KEY packet.
    private let liveH264AnnexBJoin: Bool
    /// Live H.264 or HEVC on Annex B (MPEG-TS, HLS ingest): a keyframe's in-band parameter sets that differ from the
    /// running init's get a versioned init (#133 follow-up for H.264; HEVC the same).
    private let liveAnnexBReinit: Bool

    /// Sodalite#32: text-subtitle tap, generalizing the #77 CC tap. Streams in this set are kept by the
    /// pump (not discarded) and each of their packets is handed to `subtitleTapObserver` (with the
    /// stream's time_base), then dropped below as a foreign packet, never muxed. The pump already reads
    /// the source's full interleave, so harvesting subtitle packets here costs no extra bandwidth: the
    /// session's cue stores fill for exactly the region the producer has produced, across restarts.
    /// Set at init (BEFORE the discard block: a post-init assignment came too late, the demuxer had
    /// already discarded the subtitle streams and only open-time queued packets ever reached the tap;
    /// device repro: readMax frozen at 5.2s on a resumed remote MKV).
    var subtitleTapStreamIndices: Set<Int32>
    var subtitleTapObserver: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational) -> Void)?
    private var subtitleTapTimeBases: [Int32: AVRational] = [:]

    /// #112 rework: ALL embedded subtitle streams stay in the keep-set; their packets feed the
    /// session's SubtitlePacketStore via this sink. Same tapped-then-dropped contract as
    /// `subtitleTapObserver`, set at init BEFORE the discard block for the same reason.
    var subtitlePacketStreamIndices: Set<Int32>
    var subtitlePacketSink: (@Sendable (Int32, UnsafeMutablePointer<AVPacket>, AVRational) -> Void)?
    private var closedCaptionStreamTimeBase = AVRational(num: 1, den: 1)

    /// Set by engine live-reopen path so the fresh producer marks its first segment with #EXT-X-DISCONTINUITY.
    var firstSegmentDiscontinuous = false

    private var hdr10PlusDetected = false

    /// The two shapes a source restart reaches the producer in. Both mean the same thing (the
    /// origin restarted its stream and is re-sending content this session has already played) and
    /// both end the pump for a host retune; they differ only in how the timestamps arrive.
    enum SourceRestartShape: Equatable {
        /// Raw dts jumped BACKWARD to near where this session first joined: the server replayed
        /// from its beginning on a connection we had just rebuilt.
        case rewind
        /// The source renumbered its 33-bit clock from zero mid-connection. FFmpeg reads that as a
        /// wrap and adds 2^33, so it arrives as a large FORWARD jump whose wrap-corrected raw value
        /// sits at the start of the axis (#405).
        case axisReset
    }

    /// Pure classifier for both shapes, testable without a demuxer.
    ///
    /// #405: the old check opened with `jumpTicks < 0` and so could only ever see the rewind. The
    /// field trace was the other shape: `srcDts=8589934592` (2^33 exactly, i.e. a raw dts of 0),
    /// `jumpTicks=+8487014192`, eleven seconds of already-played content re-sent behind an
    /// EXT-X-DISCONTINUITY while the viewer watched them twice.
    ///
    /// The anchor differs per shape and that matters: the rewind lands near `firstSeenDts` because
    /// the server restarted the PROGRAM, but an axis reset lands near ZERO regardless of where this
    /// session joined the ring. In the field trace those are 1121 s apart (`oldShift=100915200`),
    /// so testing an axis reset against `firstSeenDts` would have missed it.
    ///
    /// The axis reset is live-only. A sequential origin's archive chunks legitimately open their
    /// own axis at zero (#368), and reading that as a replay would end a healthy pump.
    static func sourceRestartShape(newDts: Int64,
                                   jumpTicks: Int64,
                                   firstSeenDts: Int64,
                                   tbSeconds: Double,
                                   isLive: Bool) -> SourceRestartShape? {
        guard firstSeenDts != Int64.min, tbSeconds > 0 else { return nil }
        let windowTicks = Int64(Self.sourceReplayStartWindowSeconds / tbSeconds)
        if jumpTicks < 0 {
            return newDts <= SourceTimestampBounds.sum(firstSeenDts, windowTicks) ? .rewind : nil
        }
        guard isLive, newDts >= Self.mpegTSWrapTicks else { return nil }
        return newDts % Self.mpegTSWrapTicks <= windowTicks ? .axisReset : nil
    }

    /// Replay-from-start check. The rewind additionally requires a recent unplanned reconnect: on
    /// that shape the discriminator against an ordinary programme boundary is that we had just
    /// rebuilt the connection. The axis reset carries its own discriminator and must NOT require
    /// one, because the origin renumbers on the connection it already holds (field trace: `gen=1->1`,
    /// `reconnects=0`); a programme boundary inside one transport stream keeps its PCR axis running,
    /// and a genuine 33-bit wrap after ~26.5 h is a continuous correction, not a jump over the
    /// discontinuity threshold.
    private func isSourceReplay(newDts: Int64,
                                jumpTicks: Int64,
                                firstSeenDts: Int64,
                                tbSeconds: Double,
                                stream: String) -> Bool {
        guard let shape = Self.sourceRestartShape(newDts: newDts,
                                                  jumpTicks: jumpTicks,
                                                  firstSeenDts: firstSeenDts,
                                                  tbSeconds: tbSeconds,
                                                  isLive: isLive)
        else { return false }
        switch shape {
        case .rewind:
            guard let reconnectAt = demuxer.lastUnplannedSourceReconnectAt,
                  Date().timeIntervalSince(reconnectAt) < Self.sourceReplayReconnectWindowSeconds
            else { return false }
            EngineLog.emit(
                "[HLSSegmentProducer] live source REPLAY detected on \(stream): "
                + "srcDts=\(newDts) firstSeenDts=\(firstSeenDts) jumpTicks=\(jumpTicks) "
                + "reconnect \(String(format: "%.1f", Date().timeIntervalSince(reconnectAt)))s ago; "
                + "server restarted the stream from its beginning, exiting pump for host retune",
                category: .session
            )
        case .axisReset:
            EngineLog.emit(
                "[HLSSegmentProducer] live source AXIS RESET detected on \(stream): "
                + "srcDts=\(newDts) (wrap-corrected raw=\(newDts % Self.mpegTSWrapTicks)) "
                + "firstSeenDts=\(firstSeenDts) jumpTicks=+\(jumpTicks); "
                + "source renumbered its 33-bit clock from zero and is re-sending content already "
                + "played, exiting pump for host retune",
                category: .session
            )
        }
        return true
    }

    // MARK: - Init

    init(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        video: StreamConfig,
        audio: AudioConfig? = nil,
        sideAudioDemuxer: Demuxer? = nil,
        cache: SegmentCache,
        audioRendition: SegmentCache? = nil,
        baseIndex: Int = 0,
        targetSegmentDurationSeconds: Double = 6.0,
        videoFallbackDurationPts: Int64,
        restartTargetVideoPts: Int64 = Int64.min,
        boundaryClaimsRandomAccess: Bool = false,
        planBoundaryAxis: PlanBoundaryAxis = .decode,
        closedCaptionStreamIndex: Int32 = -1,
        subtitleTapStreamIndices: Set<Int32> = [],
        subtitlePacketStreamIndices: Set<Int32> = [],
        desiredFirstVideoTfdtPts: Int64,
        segmentBoundaries: [Int64],
        planAnchorVideoPts: Int64 = 0,
        isLive: Bool = false,
        foldsSequentialTimeline: Bool = false,
        packedSideAudioStartPts: Int64? = nil,
        packedSideAudioFallbackDurationPts: Int64 = 0,
        bufferAheadSegments: Int = 10,
        prefetchDiskBudgetBytes: Int = 0,
        audioMoovPrimeFrame: [UInt8]? = nil,
        audioMoovPrimeKnownUnobtainable: Bool = false,
        audioDelaySeconds: Double = 0,
        epoch: UInt64 = 0
    ) throws {
        // What this producer feeds: the engine's bridge, or a session of its own made from it
        // (`AudioSegmentRuns`), which the pump ends.
        var audio = audio
        let fed = audio?.bridge?.producerBridge()
        audio?.bridge = fed
        self.epoch = epoch
        self.audioDelaySeconds = audioDelaySeconds
        audio?.bridge?.setOutputOffset(seconds: audioDelaySeconds)
        self.audioMoovPrimeFrame = audioMoovPrimeFrame
        self.audioMoovPrimeKnownUnobtainable = audioMoovPrimeKnownUnobtainable
        self.capturesAudioPrimeFrames =
            audio.map { MP4SegmentMuxer.audioNeedsParsedPacketForMoov($0.codecpar.pointee.codec_id) } ?? false
        self.bufferAheadSegments = bufferAheadSegments
        self.prefetchDiskBudgetBytes = prefetchDiskBudgetBytes
        self.demuxer = demuxer
        self.sideAudioDemuxer = sideAudioDemuxer
        // Packed side audio: synthesize timestamps from ID3 PRIV anchor; TS-side sessions use real timestamps.
        if let startPts = packedSideAudioStartPts {
            self.packedSideAudioClock = PackedAudioSynthClock(
                startPts: startPts,
                fallbackDurationPts: packedSideAudioFallbackDurationPts
            )
        }
        self.videoStreamIndex = videoStreamIndex
        self.closedCaptionStreamIndex = closedCaptionStreamIndex   // #77: before the discard block below
        self.subtitleTapStreamIndices = subtitleTapStreamIndices   // Sodalite#32: same reason
        self.subtitlePacketStreamIndices = subtitlePacketStreamIndices   // #112 rework: same reason
        self.videoConfig = video
        switch video.codecpar.pointee.codec_id {
        case AV_CODEC_ID_H264: a53CodecKind = .h264
        case AV_CODEC_ID_HEVC: a53CodecKind = .hevc
        default: a53CodecKind = nil
        }
        // #365: the measured framing wins when the session has one. Deriving it from the extradata is
        // a guess that only holds while both ends agree, and a source where they disagree is exactly
        // the one whose packets nobody can walk.
        a53NALFraming = video.nalFramingOverride ?? A53SEIParser.nalFraming(
            codec: a53CodecKind ?? .h264,
            extradata: video.codecpar.pointee.extradata.map { UnsafePointer($0) },
            size: Int(video.codecpar.pointee.extradata_size))
        self.liveH264AnnexBJoin = Self.liveH264JoinRequiresParameterSets(
            isLive: isLive,
            codecIsH264: a53CodecKind == .h264,
            framingIsAnnexB: a53NALFraming == .annexB)
        self.liveAnnexBReinit = isLive && a53CodecKind != nil && a53NALFraming == .annexB
        if !isLive, a53CodecKind == .h264, case .lengthPrefixed = a53NALFraming {
            let extra = video.extradataOverride ?? video.codecpar.pointee.extradata.map {
                Array(UnsafeBufferPointer(start: $0, count: Int(video.codecpar.pointee.extradata_size)))
            }
            if let extra { vodH264Configuration = H264ConfigurationTracker(avcC: extra) }
        }
        // HEVC VOD, on either framing: the muxer's record is length-prefixed in both (#365 converts Annex B samples).
        if !isLive, a53CodecKind == .hevc,
           let extra = video.extradataOverride ?? video.codecpar.pointee.extradata.map({
               Array(UnsafeBufferPointer(start: $0, count: Int(video.codecpar.pointee.extradata_size)))
           }) {
            vodHEVCConfiguration = HEVCConfigurationTracker(hvcC: extra, framing: a53NALFraming)
        }
        self.convertP7Active = video.convertP7ToProfile81
        self.audioConfig = audio
        if let audio, let timing = audio.copiedTiming {
            let par = audio.codecpar.pointee
            let name = avcodec_get_name(par.codec_id).map { String(cString: $0) } ?? "?"
            if let samples = timing.decoderDelay {
                if samples > 0 {
                    EngineLog.emit(
                        "[HLSSegmentProducer] stream-copied \(name) (profile \(par.profile)) moves \(samples) samples "
                        + "(\(String(format: "%.3f", Double(samples) / Double(max(par.sample_rate, 1)) * 1000)) ms) later: "
                        + "the decoder delay AVFoundation trims"
                        + (par.codec_id == AV_CODEC_ID_AAC && par.profile == -99 ? ", profile unknown, taken as AAC-LC" : ""),
                        category: .session)
                }
            } else {
                EngineLog.emit(
                    "[HLSSegmentProducer] stream-copied \(name) (profile \(par.profile)) has no measured AVFoundation "
                    + "decoder delay; its timestamps are copied as they are and its sync is unverified",
                    category: .session)
            }
        }
        self.cache = cache
        self.videoFile = Rendition(track: .video, cache: cache)
        self.audioFile = audio == nil ? nil : audioRendition.map { Rendition(track: .audio, cache: $0) }
        self.baseIndex = baseIndex
        self.sourceVideoTimeBase = video.timeBase
        self.frameGrid = isLive ? nil : video.frameGrid
        self.targetSegmentDurationSeconds = targetSegmentDurationSeconds
        self.segmentBoundaries = segmentBoundaries
        self.planAnchorVideoPts = planAnchorVideoPts
        self.vodCutter = VODSegmentCutter(
            sourceBoundaries: segmentBoundaries,
            planAnchorPts: planAnchorVideoPts,
            baseIndex: baseIndex
        )
        self.isLive = isLive
        self.foldsSequentialTimeline = foldsSequentialTimeline
        self.liveCurrentSegmentIndex = baseIndex
        self.videoFallbackDurationPts = videoFallbackDurationPts
        self.restartTargetVideoPts = restartTargetVideoPts
        self.boundaryClaimsRandomAccess = boundaryClaimsRandomAccess
        self.planBoundaryAxis = planBoundaryAxis
        self.effectiveGateTargetPts = restartTargetVideoPts
        self.gateProvenEmptyFromPts = restartTargetVideoPts
        // Audio target set dynamically once video gate opens (rescaled to audio TB).
        self.restartTargetAudioDts = Int64.min
        // Audio always waits for video: some MKV remuxes (Bluey BD) have a non-IDR first packet;
        // anchoring audio early would desync by firstVideoKeyDts - firstAudioDts even with tfdt == 0.
        self.audioWaitForVideo = true
        self.desiredFirstVideoTfdtPts = desiredFirstVideoTfdtPts

        // Discard streams we don't read (matroska queues PGS bitmaps, secondary audio -- heap churn).
        // Dual-demuxer: side audio index can alias a main-demuxer stream, so keep sets are split.
        if let side = sideAudioDemuxer {
            var keep: Set<Int32> = [videoStreamIndex]
            if closedCaptionStreamIndex >= 0 { keep.insert(closedCaptionStreamIndex) }   // #77
            keep.formUnion(subtitleTapStreamIndices)   // Sodalite#32
            keep.formUnion(subtitlePacketStreamIndices)   // #112 rework
            demuxer.discardAllStreamsExcept(keep)
            if let audio = audio {
                side.discardAllStreamsExcept([audio.sourceStreamIndex])
            }
        } else {
            var keep: Set<Int32> = [videoStreamIndex]
            if let audio = audio {
                keep.insert(audio.sourceStreamIndex)
            }
            if closedCaptionStreamIndex >= 0 { keep.insert(closedCaptionStreamIndex) }   // #77
            keep.formUnion(subtitleTapStreamIndices)   // Sodalite#32
            keep.formUnion(subtitlePacketStreamIndices)   // #112 rework
            demuxer.discardAllStreamsExcept(keep)
        }
        // #77: cache the CC stream's time_base for the observer's PTS conversion.
        if closedCaptionStreamIndex >= 0 {
            closedCaptionStreamTimeBase = demuxer.stream(at: closedCaptionStreamIndex)?.pointee.time_base
                ?? AVRational(num: 1, den: 1)
        }
        // Sodalite#32 + #112 rework: same for the tapped subtitle streams.
        for idx in subtitleTapStreamIndices.union(subtitlePacketStreamIndices) {
            subtitleTapTimeBases[idx] = demuxer.stream(at: idx)?.pointee.time_base
                ?? AVRational(num: 1, den: 1000)
        }

        let audioDesc = audio.map { a -> String in
            let mode = a.bridge != nil ? "bridge" : "stream-copy"
            let origin: String
            if packedSideAudioClock != nil {
                origin = " (side demuxer, packed synth clock start=\(packedSideAudioStartPts ?? 0))"
            } else if sideAudioDemuxer != nil {
                origin = " (side demuxer)"
            } else {
                origin = ""
            }
            return " audio=\(mode)\(origin) inTb=\(a.inputTimeBase.num)/\(a.inputTimeBase.den)"
        } ?? ""
        EngineLog.emit(
            "[HLSSegmentProducer] init OK (baseIndex=\(baseIndex), "
            + "segments=\(max(0, segmentBoundaries.count - 1)), "
            + "targetDur=\(String(format: "%.3f", targetSegmentDurationSeconds))s, "
            + "srcVideoTb=\(video.timeBase.num)/\(video.timeBase.den))"
            + audioDesc,
            category: .session
        )
    }

    /// Returns absolute segment index for a live video packet; cuts on keyframes past targetSegmentDurationSeconds.
    ///
    /// AE#446 round 6: seg-0's recorded start is a PRESENTATION time, and the shift anchors the first
    /// DECODE time at 0, so on a source with frame reordering the first segment of a live session
    /// begins one presentation lead above zero rather than at 0.000 (`lead=` on the gate-open line).
    /// That is the number the item's stated axis carries, and it is a property of the source: 0.033s
    /// on a 60 fps `-bf 3` seed here, 0.050s on the reporter's broadcast TS, 0.000s on the bundled
    /// seed, which is why a harness that only ran the bundled seed made zero look like a rule.
    private func liveVideoSegmentIndex(pts: Int64, isKeyframe: Bool) -> Int {
        let ptsSeconds = Double(pts) * sourceVideoTbSeconds
        if !liveFirstSegmentOpened {
            liveFirstSegmentOpened = true
            liveCurrentSegmentIndex = baseIndex
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = firstSegmentDiscontinuous
            // A boundary before the first segment has nothing to separate.
            pendingForceCutFlag = false
            return liveCurrentSegmentIndex
        }
        // pendingForceCutFlag cuts at the next keyframe regardless of the 4 s minimum,
        // so #EXT-X-DISCONTINUITY lands on the first IRAP of the new program (not one segment late).
        if Self.liveShouldCut(ptsSeconds: ptsSeconds,
                              segmentStartSeconds: liveSegmentStartPtsSeconds,
                              targetSeconds: targetSegmentDurationSeconds,
                              isKeyframe: isKeyframe,
                              forceCut: pendingForceCutFlag) {
            liveCurrentSegmentIndex += 1
            liveSegmentStartPtsSeconds = ptsSeconds
            liveSegmentStartByIndex[liveCurrentSegmentIndex] = ptsSeconds
            pendingForceCutFlag = false
            liveSegmentDiscontinuousByIndex[liveCurrentSegmentIndex] = pendingDiscontinuityFlag
            pendingDiscontinuityFlag = false
        }
        return liveCurrentSegmentIndex
    }

    /// One stamp for both readers of "a live segment was finalized just now": the field the pump
    /// reads on its way past, and the watchdog window a timer evaluates (AE#406).
    private func stampLiveSegmentFinalize() {
        let now = Date()
        lastLiveSegmentFinalizeAt = now
        noCutWatchdog?.noteFinalize(at: now)
    }

    private var sourceVideoTbSeconds: Double {
        guard sourceVideoTimeBase.num > 0, sourceVideoTimeBase.den > 0 else { return 0 }
        return Double(sourceVideoTimeBase.num) / Double(sourceVideoTimeBase.den)
    }

    /// The audio's time base in seconds as the pump holds it (`AudioConfig.timeBase`); 0 when there
    /// is no audio or it is degenerate.
    private var audioTbSeconds: Double {
        guard let tb = audioConfig?.timeBase, tb.num > 0, tb.den > 0 else { return 0 }
        return Double(tb.num) / Double(tb.den)
    }

    /// The same as the demuxer hands it over (`AudioConfig.demuxTimeBase`), for reading the source.
    private var audioDemuxTbSeconds: Double {
        guard let tb = audioConfig?.demuxTimeBase, tb.num > 0, tb.den > 0 else { return 0 }
        return Double(tb.num) / Double(tb.den)
    }

    /// One coded audio frame in `AudioConfig.timeBase`.
    private var audioFrameDuration: Int64 { audioConfig?.frameDuration ?? 1 }

    /// AE#432: says once per pump that the source stopped carrying timestamps and what the engine
    /// put in their place. Silent before this, which is why the field trace could only show the
    /// consequence (a frozen cut clock) and not the cause.
    private func noteSynthesizedTimestamp(strideTicks: Int64, isVideo: Bool) {
        guard !loggedFirstSynthesizedTimestamp else { return }
        loggedFirstSynthesizedTimestamp = true
        let tb = isVideo ? sourceVideoTbSeconds : audioTbSeconds
        EngineLog.emit(
            "[HLSSegmentProducer] source stopped carrying timestamps on the "
            + "\(isVideo ? "video" : "audio") stream; synthesizing at \(strideTicks) ticks/packet"
            + (tb > 0 ? " (\(String(format: "%.4f", Double(strideTicks) * tb))s)" : "")
            + ". The live cutter reads this timestamp, so its segments are paced by it from here on",
            category: .session
        )
    }

    /// Source-axis value of a timestamp the pump has already rebased onto the output axis
    /// (`pts -= videoShiftPts`). Anything the producer hands to a consumer that works in source
    /// PTS has to come back through here (#259). NOPTS and an unresolved shift pass through.
    static func foldingShiftBack(_ value: Int64, shift: Int64) -> Int64 {
        guard value != Int64.min, shift != Int64.min else { return value }
        return value &+ shift
    }

    /// 0-based segment offset for `absolute` within the sorted-ascending `boundaries`: segment i spans
    /// [boundaries[i], boundaries[i+1]), clamped to [0, count-2]. Binary search, exactly equivalent to the
    /// former linear "first i where absolute < boundaries[i+1]" scan but O(log n) instead of O(n) per packet
    /// (the scan walked ~one compare per elapsed segment, growing across a VOD title). Returns 0 if empty.
    static func segmentOffset(forAbsolutePts absolute: Int64, boundaries: [Int64]) -> Int {
        let count = boundaries.count
        guard count > 0 else { return 0 }
        // upperBound: first index whose boundary is > absolute (i.e. how many boundaries are <= absolute).
        var lo = 0
        var hi = count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if boundaries[mid] <= absolute { lo = mid + 1 } else { hi = mid }
        }
        return min(max(lo - 1, 0), max(0, count - 2))
    }

    /// Returns `file`'s muxer for targetIdx, advancing/allocating as needed. Forward-only: clamps late packets
    /// (HEVC RASL B-frames, bridge lag) upward to avoid premature finalize. Returns nil on stop/alloc failure.
    private func ensureMuxer(_ file: Rendition, forSegmentIndex targetIdx: Int) -> MP4SegmentMuxer? {
        let effectiveIdx = max(targetIdx, file.segmentIndex)

        if let m = file.muxer, m.currentSegmentIndex == effectiveIdx {
            return m
        }

        if file.muxer == nil {
            guard file.track == .video else { return allocateMuxer(file, initialSegmentIndex: effectiveIdx) }
            // #133: pendingJoinVideoConfig is non-nil only when a live H.264 join reconstructed dimensions
            // from in-band SPS/PPS because the probe left codecpar at 0x0. Consumed once, here.
            let joinConfig = pendingJoinVideoConfig
            pendingJoinVideoConfig = nil
            return allocateMuxer(file, initialSegmentIndex: effectiveIdx, reconstructedVideoConfig: joinConfig)
        }
        // SSAI program switch: new video codec params need a fresh muxer (versioned EXT-X-MAP). The audio
        // rendition keeps its init; its playlist takes the discontinuity at the same index.
        if file.track == .video, pendingVideoProgramSwitch, effectiveIdx > file.segmentIndex {
            return rotateMuxerForProgramSwitch(to: effectiveIdx)
        }
        return advanceMuxer(file, to: effectiveIdx)
    }

    private func rotateMuxerForProgramSwitch(to newIdx: Int) -> MP4SegmentMuxer? {
        if checkShouldStop() { return nil }
        let finishedIdx = videoFile.segmentIndex
        finalizeSessionMuxerAndAdopt(videoFile) // adopts finishedIdx, nils videoFile.muxer
        pendingVideoProgramSwitch = false
        let isAdCreative = pendingReinitIsAdCreative
        pendingReinitIsAdCreative = false
        if pendingReinitUsesOpenedConfig {
            pendingReinitUsesOpenedConfig = false
            EngineLog.emit(
                "[HLSSegmentProducer] muxer rotation (programme back): seg-\(finishedIdx) finalized on the ad's init, "
                + "the open's init again for seg-\(newIdx)",
                category: .session
            )
            return allocateMuxer(videoFile, initialSegmentIndex: newIdx, reconstructedVideoConfig: nil, versionedInit: true,
                                 isAdCreative: false)
        }
        guard let adConfig = pendingAdVideoConfig else {
            EngineLog.emit(
                "[HLSSegmentProducer] program switch: no parsed ad video config; "
                + "cannot re-init muxer",
                category: .session
            )
            return nil
        }
        pendingAdVideoConfig = nil
        // #133 follow-up: same trigger and versioned-init path, two origins. SSAI = new video PID (ad creative,
        // its own signaling). Same-PID = in-band SPS/PPS change on the running program (encoder restart / splice),
        // whose DV/color overrides must be kept, so only versionedInit is set, not isAdCreative.
        EngineLog.emit(
            "[HLSSegmentProducer] muxer rotation (\(isAdCreative ? "SSAI program switch" : "same-PID parameter-set change")): "
            + "seg-\(finishedIdx) finalized on old init, fresh versioned init for seg-\(newIdx) "
            + "(\(adConfig.width)x\(adConfig.height))",
            category: .session
        )
        return allocateMuxer(videoFile, initialSegmentIndex: newIdx,
                             reconstructedVideoConfig: adConfig,
                             versionedInit: true,
                             isAdCreative: isAdCreative)
    }

    /// The program change `packet` shows this pump: it comes from another stream than the one its role
    /// is set up for. Each pump compares with its own, so a pump started after a seek past a change
    /// sees the change on its first packet.
    private func sourceChange(_ packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin) -> ProgramSuccession.Change? {
        let index = packet.pointee.stream_index
        let source = Demuxer.sourceStream(of: packet)
        if origin == .main, index == videoStreamIndex, source != videoSourceStream {
            defer { videoSourceStream = source }
            return ProgramSuccession.Change(logical: index, from: videoSourceStream, to: source)
        }
        if let audio = audioConfig, index == audio.sourceStreamIndex,
           origin == (sideAudioDemuxer != nil ? .side : .main), source != audioSourceStream {
            defer { audioSourceStream = source }
            return ProgramSuccession.Change(logical: index, from: audioSourceStream, to: source)
        }
        return nil
    }

    /// What a program change does to this pump: the stream the PMT moved a
    /// role to is handed over under the role's own index, so the pump only decides whether its init still
    /// describes it. Compared with what the pump was opened with, not with the stream before: an ad's
    /// codec matters against the programme's. Returns an exit reason when the session has to be rebuilt.
    private func noteProgramChange(_ change: ProgramSuccession.Change, origin: PacketOrigin) -> PumpExitReason? {
        let source = origin == .side ? sideAudioDemuxer : demuxer
        let codec = source?.stream(at: change.to)?.pointee.codecpar.pointee.codec_id
        if origin == .main, change.logical == videoStreamIndex {
            let codecDiffers = codec != videoConfig.codecpar.pointee.codec_id
            EngineLog.emit(
                "[HLSSegmentProducer] program change: video now on stream \(change.to) (was \(change.from))"
                + (codecDiffers ? ", another codec" : ""), category: .session)
            if isLive {
                awaitingProgramSwitch = change
                return nil
            }
            // VOD: one init for the whole playlist. The same codec goes on (new H.264 parameter sets are
            // caught by `vodH264Configuration`); another codec cannot, and the session is rebuilt on the
            // software path, which decodes what it is handed.
            return codecDiffers ? .videoConfigurationChanged(
                summary: "the video changed codec at a program change (stream \(change.from) → \(change.to))") : nil
        }
        guard let audio = audioConfig, change.logical == audio.sourceStreamIndex,
              origin == (sideAudioDemuxer != nil ? .side : .main) else { return nil }
        // A bridged track decodes what it was opened with, so it can follow no codec but its own either.
        let codecDiffers = codec != audio.codecpar.pointee.codec_id
        EngineLog.emit(
            "[HLSSegmentProducer] program change: audio now on stream \(change.to) (was \(change.from))"
            + (codecDiffers ? ", another codec" : ""), category: .session)
        if !isLive, codecDiffers {
            return .videoConfigurationChanged(
                summary: "the audio changed codec at a program change (stream \(change.from) → \(change.to))")
        }
        audioRoleUnmuxable = codecDiffers
        return nil
    }

    /// The keyframe a program switch opens on, with its in-band SPS/PPS where it has them.
    private struct ProgramSwitchOpening {
        var config: InBandVideoConfig?
    }

    /// A video configuration read from a keyframe's in-band parameter sets (a live join whose probe saw no SPS, an
    /// SSAI creative, a same-PID parameter-set change): what an init built from it says. Its colour is the new SPS's
    /// VUI and, over a backward-compatible declaration, the keyframe's alternative transfer SEI (HLG, as the demuxer
    /// promotes it at open, AE#839), so the versioned init's `colr` describes the new program.
    struct InBandVideoConfig: Equatable {
        var codecID: AVCodecID
        var width: Int32
        var height: Int32
        /// The parameter sets, Annex B: what the configuration is compared by.
        var extradata: [UInt8]
        /// HEVC: the length-prefixed record the muxer is handed so it copies the samples, which the producer converts
        /// with their in-band parameter sets kept (#365). nil for H.264, whose muxer reads `extradata`.
        var lengthPrefixedRecord: [UInt8]?
        var colour: ColorDescription

        init?(annexB buf: UnsafeBufferPointer<UInt8>, codec: A53SEIParser.CodecKind, requiresRandomAccess: Bool) {
            switch codec {
            case .h264:
                guard let (sps, pps) = H264SPS.extractSPSandPPS(fromAnnexB: buf),
                      !requiresRandomAccess || H264SPS.isRandomAccessEntry(fromAnnexB: buf),
                      let dim = H264SPS.dimensions(fromNAL: sps) else { return nil }
                codecID = AV_CODEC_ID_H264
                width = Int32(dim.width)
                height = Int32(dim.height)
                extradata = H264SPS.annexBExtradata(sps: sps, pps: pps)
                colour = H264SPS.colour(fromNAL: sps) ?? .unspecified
            case .hevc:
                let sets = HEVCSPS.parameterSets(fromAnnexB: buf)
                guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps, !requiresRandomAccess || sets.irap,
                      let summary = HEVCSPS(nal: sps) else { return nil }
                codecID = AV_CODEC_ID_HEVC
                width = Int32(summary.width)
                height = Int32(summary.height)
                let startCode: [UInt8] = [0, 0, 0, 1]
                extradata = startCode + vps + startCode + sps + startCode + pps
                lengthPrefixedRecord = VideoConfigRecord.fromAnnexB(extradata, codecID: AV_CODEC_ID_HEVC,
                                                                    width: width, height: height)
                colour = HEVCInBandColour.colourDescription(vps: vps, sps: sps, pps: pps) ?? .unspecified
            }
            if AlternativeTransferSEI.declaredTransferMayHideHLG(codecID: codecID, primaries: colour.primaries,
                                                                 transfer: colour.transfer),
               let base = buf.baseAddress,
               AlternativeTransferSEI.preferredTransfer(in: base, size: buf.count, codec: codec, framing: .annexB)
                == AlternativeTransferSEI.hlgTransfer {
                colour.transfer = AVCOL_TRC_ARIB_STD_B67
            }
        }
    }

    /// The keyframe a program switch can open on, or nil to hold the packet out: on the stream chosen at
    /// open any keyframe (its configuration is the open's; an H.264 one still yields its in-band sets as
    /// the #133 baseline), on an ad creative a keyframe with in-band SPS/PPS.
    private func programSwitchOpening(_ change: ProgramSuccession.Change,
                                      _ packet: UnsafeMutablePointer<AVPacket>) -> ProgramSwitchOpening? {
        guard packet.pointee.flags & AV_PKT_FLAG_KEY != 0 else { return nil }
        // The creative's own codec: an H.264 ad can interrupt an HEVC programme.
        let codecID = demuxer.stream(at: change.to)?.pointee.codecpar.pointee.codec_id
        let inBand = extractAdVideoConfig(packet, codec: codecID == AV_CODEC_ID_HEVC ? .hevc : .h264)
        if change.to == change.logical { return ProgramSwitchOpening(config: inBand) }
        return inBand.map { ProgramSwitchOpening(config: $0) }
    }

    /// Extract H.264 ad video config from in-band Annex-B SPS/PPS. nil on mid-GOP join (no parameter sets).
    private func extractAdVideoConfig(_ packet: UnsafeMutablePointer<AVPacket>,
                                      codec: A53SEIParser.CodecKind) -> InBandVideoConfig? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        return InBandVideoConfig(annexB: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)),
                                 codec: codec, requiresRandomAccess: false)
    }

    /// #133: whether the stricter live-join gate engages (withhold the video gate until a decodable IDR
    /// access unit arrives). Only for live H.264 with Annex-B framing, i.e. MPEG-TS ingest joining
    /// mid-broadcast: fMP4 live carries valid out-of-band avcC so its keyframes are already decodable, and
    /// VOD probes the full file up front. HEVC keeps the existing AV_PKT_FLAG_KEY gate.
    static func liveH264JoinRequiresParameterSets(isLive: Bool, codecIsH264: Bool, framingIsAnnexB: Bool) -> Bool {
        isLive && codecIsH264 && framingIsAnnexB
    }

    /// #133 follow-up pure decision: a mid-stream keyframe's in-band SPS/PPS diverge from the sets backing the
    /// current muxer's avcC, so the frozen avcC no longer describes the incoming slices (stale-avcC green frames).
    /// Returns false when there is no active baseline yet (`active == nil`, first keyframe of the epoch establishes
    /// it) or the sets are byte-identical (the routine SPS/PPS repetition MPEG-TS carries before every IDR).
    static func parameterSetsDiverged(active: [UInt8]?, incoming: [UInt8]) -> Bool {
        guard let active else { return false }
        return active != incoming
    }

    /// #133 join gate: a decodable H.264 access unit at a mid-stream join needs in-band SPS + PPS and an
    /// entry point, an IDR or an immediate intra recovery point (AE#627, see `isRandomAccessEntry`). Returns
    /// the reconstructed (width, height, Annex-B extradata) so a zero-dimension probe codecpar can be
    /// backfilled into the first muxer. nil until such an AU arrives.
    private func extractJoinVideoConfig(_ packet: UnsafeMutablePointer<AVPacket>) -> InBandVideoConfig? {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return nil }
        return InBandVideoConfig(annexB: UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)),
                                 codec: .h264, requiresRandomAccess: true)
    }

    /// Pump-side backpressure wait. Returns true on release, false when stop was requested.
    /// #65 diag: an abnormally long park (no playback progress for > threshold) surfaces the producer-vs-AVPlayer
    /// index tuple once, then every 10 s, so a VOD wedge (cacheTarget frozen below target with no watchdog to break
    /// it) is distinguishable from healthy backpressure (cacheTarget climbing toward target). VOD only; live keeps
    /// its own watchdogs.
    private func awaitBackpressureRelease(target: Int, head: Int, context: String) -> Bool {
        // AE#850: a relaxed pump that parks is keeping up.
        if pumpQoSCurrent == QOS_CLASS_UTILITY { pumpRelaxationRate.reset() }
        // Already broken on this session (e.g. a teardown-flush ensureMuxer call): stay broken, don't re-park.
        if isBackpressureWedgeBroken() { return false }
        setAdvanceParked(true)
        defer { setAdvanceParked(false) }
        var parked = 0
        var nextLogAt = Self.backpressureWedgeLogThresholdSeconds
        // AE#528: the wait below returns on ANY cache broadcast (a consumer GET that moves the fetch
        // target, a stored segment), not only at its timeout, so one iteration is a wakeup and not a
        // second. Everything under it is expressed in seconds, so the seconds come from the clock.
        var parkClock = ParkClock(nowNanos: DispatchTime.now().uptimeNanoseconds)
        // #65 Piece A: a genuine VOD wedge is the consumer fetch target frozen past the break threshold.
        // The detector resets whenever the target advances, so healthy backpressure (slow CDN, cold cache)
        // keeps the target climbing and never trips. Live keeps its own pump watchdogs.
        // #93 retest: the fast path additionally watches the rendered clock; target AND clock both frozen
        // for the short window while the consumer wants to play breaks in single-digit seconds.
        var wedgeDetector = BackpressureWedgeDetector(
            breakThresholdSeconds: Self.backpressureWedgeBreakThresholdSeconds,
            fastBreakThresholdSeconds: Self.backpressureWedgeFastBreakThresholdSeconds,
            initialTarget: cache.targetIndex,
            initialRenderedPosition: playbackPositionProvider?()
        )
        while !checkShouldStop() {
            // Layer 3 step 5: a subtitle consumer of a stream only this pump reads wants it read this far.
            if let reach = subtitleReadAheadReach?(), head <= reach {
                retunePumpQoS()
                return true
            }
            if cache.awaitFetchHighWater(reaching: target, timeout: 1.0) {
                retunePumpQoS()
                if parked >= Self.backpressureWedgeLogThresholdSeconds {
                    EngineLog.emit(
                        "[HLSSegmentProducer] #65 backpressure released (\(context)) head=\(head) "
                        + "target=\(target) after=\(parked)s cacheTarget=\(cache.targetIndex) "
                        + "highStored=\(cache.highestStoredIndex) cached=\(cache.count)",
                        category: .session
                    )
                }
                return true
            }
            guard let parkedSeconds = parkClock.advance(nowNanos: DispatchTime.now().uptimeNanoseconds)
            else { continue }
            parked = parkedSeconds
            let cacheTarget = cache.targetIndex
            // #65 pause false-positive: a paused/backgrounded VOD consumer issues no forward fetch, so its
            // frozen fetch target is not a wedge. Gate the detector on play intent (nil provider = assume
            // playing, unchanged for live + tests); the legit starved-but-wants-to-play wedge keeps tripping.
            let wantsToPlay = wantsToPlayProvider?() ?? true
            // #35/#93 cold-startup: before the first frame lands a flat clock is pre-roll, not a wedge.
            let hasStarted = hasStartedRenderingProvider?() ?? true
            // AE#528: observed BEFORE the log line so `stuck=` names this poll and not the last one.
            let tripped = !isLive && wedgeDetector.observe(currentTarget: cacheTarget,
                                                           wantsToPlay: wantsToPlay,
                                                           renderedPosition: playbackPositionProvider?(),
                                                           hasStartedRendering: hasStarted)
            if !isLive, parked >= nextLogAt {
                nextLogAt += 10
                let suspendReason = !wantsToPlay ? "(consumer paused; wedge detection suspended)"
                    : !hasStarted ? "(pre-first-frame; wedge detection suspended)"
                    // AE#528: a park is not a stall. What decides is whether the consumer is still
                    // asking for segments, and stuck= is that number: 0 is a viewer scrubbing through
                    // resident content, a climbing one is a consumer that went quiet.
                    : wedgeDetector.secondsSinceTargetMoved == 0 ? "(consumer still fetching)"
                    // AE#649: quiet but rendering is a consumer playing out its forward buffer,
                    // and idle= (what the breaker counts) stays put while it does.
                    : wedgeDetector.lastPollRendered ? "(consumer quiet, still playing)"
                    : "(no playback progress)"
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure PARK (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) "
                    + "highStored=\(cache.highestStoredIndex) cached=\(cache.count) parked=\(parked)s "
                    + "stuck=\(wedgeDetector.secondsSinceTargetMoved)s "
                    + "idle=\(wedgeDetector.secondsWithoutProgress)s "
                    + suspendReason,
                    category: .session
                )
            }
            if tripped {
                markBackpressureWedgeBroken()
                EngineLog.emit(
                    "[HLSSegmentProducer] #65 backpressure WEDGE BROKEN (\(context)) head=\(head) "
                    + "target=\(target) cacheTarget=\(cacheTarget) parked=\(parked)s "
                    // AE#421: the line has to say which repair the wedge calls for, and that is
                    // decided by whether the consumer's own target is already on disk. Without it a
                    // report can show the wedge and the recovery but not whether re-anchoring the
                    // producer could have helped at all, which is exactly what had to be inferred
                    // from two field logs.
                    + "consumerTargetStored=\(cache.peekURL(index: cacheTarget) != nil ? "y" : "n") "
                    + "highStored=\(cache.highestStoredIndex) cached=\(cache.count)"
                    + (wedgeDetector.lastTripFast ? " (fast path: fetch target + rendered clock both frozen)" : "")
                    + "; exiting pump for host re-anchor on AVPlayer position",
                    category: .session
                )
                return false
            }
        }
        return false
    }

    /// Live replacement for the advance-path backpressure park (#65). Live production is source-paced,
    /// so overproduction is bounded by the origin's real-time delivery; the only unbounded case is a
    /// consumer that stopped polling entirely, which this cap catches. Logs from the first cycle (the
    /// old live park was silent below 12 s, which is why consumer-facing 6-8 s freezes never showed a
    /// producer-side line). Returns true on release, false when stop was requested.
    ///
    /// What makes this safe against a held blocking reload is the HEIGHT of the cap, not the release
    /// path. A parked pump finalizes no segment, so `segments.count` stops growing, so the playlist
    /// window stops sliding and `notePlaylistBuild -> evictBelow` evicts nothing: while the park holds,
    /// the only thing that lowers `cache.count` is `pruneOutsideWindow` off a consumer segment GET
    /// (`declareTarget`), structurally the same release the #65 park waited on. The deadlock is out of
    /// reach only because reaching `liveResidentSegmentCap` takes a consumer that is already dead, and
    /// the engine's 12 s stall watchdogs reload the item (and thus issue a fresh GET) long before then.
    /// Lowering the cap toward the steady-state window would put that deadlock back within reach.
    /// AE#443: the resident count this pump refuses to pass. The session states it (window plus
    /// slack); the static floor only covers a session that cannot.
    private func liveResidentCap() -> Int {
        max(Self.liveResidentSegmentCap, liveResidentCapProvider?() ?? 0)
    }

    private func awaitLiveWindowHeadroom(head: Int) -> Bool {
        // Compute a possibly-expired cap before reconciling its retained history. This is the
        // same expiry handler as the cache timer, so delayed timer delivery cannot wedge this park.
        if cache.reconcileExpiredNativeLiveDVRRetention(headroomCap: liveResidentCap()) { return true }
        // AE#406: nor is it reading. Inline, the watchdog could not run here at all; on a timer it
        // must not count a park as starvation, or a consumer that stopped polling would be reported
        // as a source that stopped delivering. The window re-anchors when the park releases.
        noCutWatchdog?.setReading(false, at: Date())
        defer { noCutWatchdog?.setReading(true, at: Date()) }
        // AE#443: so the stall ladder can name the pump instead of the source.
        setLiveHeadroomParked(true)
        defer { setLiveHeadroomParked(false) }
        var parked = 0
        while !checkShouldStop() {
            // AE#443: re-read per second rather than latching the entry value. The window is sized
            // from the observed cadence and segment size, so it moves while a park holds, and a park
            // that outlived its own reason would keep the origin undrained for nothing.
            let cap = liveResidentCap()
            if cache.reconcileExpiredNativeLiveDVRRetention(headroomCap: cap) {
                EngineLog.emit(
                    "[HLSSegmentProducer] live headroom released head=\(head) after=\(parked)s "
                    + "resident=\(cache.count)",
                    category: .session
                )
                return true
            }
            if parked % 10 == 0 {
                EngineLog.emit(
                    "[HLSSegmentProducer] live headroom PARK head=\(head) resident=\(cache.count) "
                    + "cap=\(cap) parked=\(parked)s (playlist polls stopped?). AE#443: this pump is "
                    + "not reading while it is parked, so the origin is not being drained either; a "
                    + "single-connection live source dies behind a long park",
                    category: .session
                )
            }
            Thread.sleep(forTimeInterval: 1.0)
            parked += 1
        }
        return false
    }

    /// #207 disk park. The segment window is a sanity bound; the real bound on an opt-in whole-source
    /// prefetch is the session retention budget, which `pruneOutsideWindow` cannot enforce because it
    /// never evicts the hard window. Parks the pump while the race-ahead has filled that budget AND the
    /// consumer still has a safe lead, so the footprint tracks the budget instead of the source length.
    /// Carries no wedge breaker of its own: the park only ever holds with `PrefetchDiskBudget
    /// .minAheadSegments` of produced content ahead of the consumer, and the extras eviction that
    /// follows the advancing playhead releases it. That rests on the advance park having caught a
    /// consumer that stopped advancing first, so `detectWedge` (#369: the advance park was skipped
    /// because its release target sat beyond the sequential playlist's frontier) arms the same #65
    /// detector here. Its cadence matches: this loop polls once a second, like the advance park.
    /// Returns true on release, false when stop was requested.
    private func awaitPrefetchDiskBudgetRelease(head: Int, context: String,
                                                detectWedge: Bool = false) -> Bool {
        guard prefetchDiskBudgetBytes > 0 || holdsOverlayRunStart else { return true }
        if pumpQoSCurrent == QOS_CLASS_UTILITY { pumpRelaxationRate.reset() }
        var parked = 0
        var nextLogAt = Self.prefetchDiskParkLogThresholdSeconds
        // AE#528: same wakeup-is-not-a-second correction as the advance park; this loop's own doc
        // above claims a one second cadence and the headroom wait returns on every cache broadcast.
        var parkClock = ParkClock(nowNanos: DispatchTime.now().uptimeNanoseconds)
        var wedgeDetector = detectWedge && !isLive
            ? BackpressureWedgeDetector(
                breakThresholdSeconds: Self.backpressureWedgeBreakThresholdSeconds,
                fastBreakThresholdSeconds: Self.backpressureWedgeFastBreakThresholdSeconds,
                initialTarget: cache.targetIndex,
                initialRenderedPosition: playbackPositionProvider?())
            : nil
        while !checkShouldStop() {
            if cache.awaitPrefetchDiskHeadroom(head: head,
                                               budgetBytes: prefetchDiskBudgetBytes,
                                               overlay: overlayTapHolding,
                                               timeout: 1.0) {
                if parked >= Self.prefetchDiskParkLogThresholdSeconds {
                    EngineLog.emit(
                        "[HLSSegmentProducer] #207 prefetch disk park released (\(context)) head=\(head) "
                        + "after=\(parked)s cacheTarget=\(cache.targetIndex) "
                        + "forward=\(cache.forwardBytes / (1 << 20)) MiB",
                        category: .session
                    )
                }
                return true
            }
            guard let parkedSeconds = parkClock.advance(nowNanos: DispatchTime.now().uptimeNanoseconds)
            else { continue }
            parked = parkedSeconds
            if parked >= nextLogAt {
                nextLogAt += 30
                EngineLog.emit(
                    "[HLSSegmentProducer] #207 prefetch disk PARK (\(context)) head=\(head) "
                    + "cacheTarget=\(cache.targetIndex) forward=\(cache.forwardBytes / (1 << 20)) MiB "
                    + "overlay=\(overlayTapHolding().bytes / (1 << 20)) MiB"
                    + (overlayTapHolding().full ? " (tap full)" : "")
                    + " budget=\(prefetchDiskBudgetBytes / (1 << 20)) MiB parked=\(parked)s "
                    + "(the session's read-ahead is full; resumes as playback advances)",
                    category: .session
                )
            }
            if wedgeDetector != nil,
               wedgeDetector!.observe(currentTarget: cache.targetIndex,
                                      wantsToPlay: wantsToPlayProvider?() ?? true,
                                      renderedPosition: playbackPositionProvider?(),
                                      hasStartedRendering: hasStartedRenderingProvider?() ?? true) {
                markBackpressureWedgeBroken()
                EngineLog.emit(
                    "[HLSSegmentProducer] #369 disk park WEDGE BROKEN (\(context)) head=\(head) "
                    + "cacheTarget=\(cache.targetIndex) parked=\(parked)s"
                    + (wedgeDetector!.lastTripFast ? " (fast path: fetch target + rendered clock both frozen)" : "")
                    + "; the advance park was skipped, so this park was the last hold. "
                    + "Exiting pump for host re-anchor on AVPlayer position",
                    category: .session
                )
                return false
            }
        }
        return false
    }

    /// What the overlay's tap keeps for the units cut (``PrefetchDiskBudget``): its bytes on disk, and whether it is
    /// full.
    private func overlayTapHolding() -> (bytes: Int, full: Bool) {
        #if DualLayerDolbyVision
        if let felTap { return (felTap.held.bytes, !felTap.hasRoomAhead) }
        #endif
        if let overlayDecodeTap { return (overlayDecodeTap.held.bytes, !overlayDecodeTap.hasRoomAhead) }
        return (0, false)
    }

    private func markBackpressureWedgeBroken() {
        stateLock.lock()
        _backpressureWedgeBroken = true
        stateLock.unlock()
    }

    private func isBackpressureWedgeBroken() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _backpressureWedgeBroken
    }

    /// Allocate the session's mp4 muxer. `reconstructedVideoConfig` overrides the probed codecpar with
    /// dimensions+extradata parsed from in-band SPS/PPS. Two orthogonal flags (#133 follow-up split the old
    /// single `isProgramSwitchReinit`):
    /// - `versionedInit`: capture the init segment as a versioned EXT-X-MAP (a mid-session avcC change: SSAI ad
    ///   creative OR a same-PID in-band SPS/PPS change). false = the primary init (session start or a #133 live
    ///   join whose probe left codecpar at 0x0).
    /// - `isAdCreative`: drop the program's DV/color overrides because the new content carries its own signaling.
    ///   True only for an SSAI ad creative on a new PID; a same-PID parameter-set change stays in the same program
    ///   and KEEPS the overrides (an HDR-live encoder restart must not lose its color signaling).
    private func allocateMuxer(_ file: Rendition,
                               initialSegmentIndex: Int,
                               reconstructedVideoConfig: InBandVideoConfig? = nil,
                               versionedInit: Bool = false,
                               isAdCreative: Bool = false) -> MP4SegmentMuxer? {
        // #93 residual: the FIRST alloc of a producer (its base segment) must not gate on the
        // consumer's fetch high water. An anchored initial producer (resume start) runs before ANY
        // segment fetch exists, because AVPlayer is still waiting on init.mp4, which is captured by
        // exactly this alloc; the park starved the map request into a fatal -12889. Producing the
        // base segment is never overproduction: the consumer requested it (fetch-triggered restart)
        // or is about to (anchored start). seg0 sessions are unaffected (their target is negative
        // and releases immediately).
        // Live never parks on the fetch high-water (see awaitLiveWindowHeadroom); an SSAI
        // versioned-init re-alloc mid-live must not re-enter the park either.
        // The video drives backpressure; an audio rendition's segment is made when the source reaches it.
        if file.track == .video, initialSegmentIndex != baseIndex, !isLive {
            let backpressureTarget = initialSegmentIndex - bufferAheadSegments
            if !awaitBackpressureRelease(target: backpressureTarget, head: initialSegmentIndex, context: "alloc") { return nil }
        }
        if checkShouldStop() { return nil }

        var adPar: UnsafeMutablePointer<AVCodecParameters>?
        defer { if adPar != nil { avcodec_parameters_free(&adPar) } }
        // The file's tracks: the video's carries the video, and the audio too unless the audio is a rendition
        // of its own (`HLSOutputShape`); the audio rendition's carries the audio alone.
        var muxerVideo: MP4SegmentMuxer.VideoConfig?
        if file.track == .video {
            let videoCodecpar: UnsafePointer<AVCodecParameters>
            if let reconstructedVideoConfig {
                guard let par = avcodec_parameters_alloc() else { return nil }
                par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
                par.pointee.codec_id = reconstructedVideoConfig.codecID
                par.pointee.width = reconstructedVideoConfig.width
                par.pointee.height = reconstructedVideoConfig.height
                // The init's `colr` (movenc writes it from these) describes the parameter sets it is built from.
                par.pointee.color_primaries = reconstructedVideoConfig.colour.primaries
                par.pointee.color_trc = reconstructedVideoConfig.colour.transfer
                par.pointee.color_space = reconstructedVideoConfig.colour.matrix
                par.pointee.color_range = reconstructedVideoConfig.colour.range
                let ed = reconstructedVideoConfig.extradata
                let pad = Int(AV_INPUT_BUFFER_PADDING_SIZE)
                if let raw = av_malloc(ed.count + pad) {
                    let bytes = raw.assumingMemoryBound(to: UInt8.self)
                    ed.withUnsafeBytes { _ = memcpy(bytes, $0.baseAddress, ed.count) }
                    memset(bytes + ed.count, 0, pad)
                    par.pointee.extradata = bytes
                    par.pointee.extradata_size = Int32(ed.count)
                }
                adPar = par
                videoCodecpar = UnsafePointer(par)
            } else {
                videoCodecpar = videoConfig.codecpar
            }

            if isLive, versionedInit {
                liveColourBySegment[initialSegmentIndex] = ColorDescription(codecpar: videoCodecpar)
            }
            muxerVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: videoCodecpar,
                timeBase: frameGrid?.outputTimeBase ?? videoConfig.timeBase,
                codecTagOverride: videoConfig.codecTagOverride,
                // Ad creative carries its own signaling; don't force the program's overrides onto it. A same-PID
                // parameter-set change is still the same program, so it keeps them (isAdCreative false).
                doviConfig: isAdCreative ? .keep : videoConfig.doviConfig,
                colorOverride: isAdCreative ? nil : videoConfig.colorOverride,
                // An init built from in-band HEVC sets gets their own record and converts its samples (#365), whatever
                // the open's were; the open's record never describes another program's sets.
                extradataOverride: reconstructedVideoConfig.map { $0.lengthPrefixedRecord }
                    ?? (isAdCreative ? nil : videoConfig.extradataOverride),
                convertsAnnexBSamples: reconstructedVideoConfig.map { $0.lengthPrefixedRecord != nil }
                    ?? (isAdCreative ? false : videoConfig.convertsAnnexBSamples),
                nalFramingLatch: isAdCreative ? nil : videoConfig.nalFramingLatch,
                stereo: isAdCreative ? nil : videoConfig.stereo
            )
        }
        let muxerAudio = file.track == .audio || audioFile == nil ? audioMuxerConfig : nil

        do {
            // #15: subtitles ship as a separate WebVTT rendition (HLSLocalServer), NOT muxed into the A/V
            // fMP4. In-band timed text is non-conformant for HLS and fails the AVPlayer open (RFC 8216 §3.1,
            // empirically -11829/-12848). The muxer carries no subtitle streams; the cue stores feed the WebVTT.
            // Only a progressive serve follows a staging file while it grows.
            let fileCache = file.cache
            var onBytesStaged: (@Sendable () -> Void)?
            if servesProgressively { onBytesStaged = { [fileCache] in fileCache.noteStagingAppended() } }
            let muxer = try MP4SegmentMuxer(
                initialSegmentIndex: initialSegmentIndex,
                sessionDir: fileCache.sessionDir,
                video: muxerVideo,
                audio: muxerAudio,
                // Cap the muxer's in-RAM interleaver at ~2 segments so a long/degenerate segment or an
                // audio stream that decodes to nothing can't buffer the whole span and fill the disk (#64).
                // Floored at 8s (the historical 2 x 4s value): a sub-second fastZap cut target (AE#195)
                // must not shrink the cap below typical TS A/V interleave skew.
                maxBufferedFragmentSeconds: servesProgressively
                    ? Self.progressiveFragmentSeconds : max(8.0, 2 * targetSegmentDurationSeconds),
                // AE#222 + mid-session rotation: the last frame a muxer accepted, or the host's
                // construction-time prime while no muxer has accepted one yet.
                audioMoovPrimeFrame: muxerAudio == nil ? nil : audioMoovPrimeFrame,
                audioDelaySeconds: audioConfig?.bridge == nil ? audioDelaySeconds : 0,
                onStorageExhausted: { [fileCache] in fileCache.noteStorageExhausted() },
                onBytesStaged: onBytesStaged,
                // docs/segment-axis.md: every VOD segment states where its first picture sits on the source
                // (`InBandClock`), the item-axis time it was written at plus the run's shift. Live rebases its
                // own timeline and states nothing. The clock rides the video.
                segmentClock: isLive || muxerVideo == nil ? nil : { [weak self] index, pts, timeBase in
                    guard let self, self.sourceVideoTbSeconds > 0 else { return nil }
                    let shift = self.videoShiftPts == Int64.min ? 0 : self.videoShiftPts
                    return InBandClock.Stamp(
                        segmentIndex: index,
                        sourceSeconds: Double(pts) * Double(timeBase.num) / Double(timeBase.den)
                            + Double(shift) * self.sourceVideoTbSeconds)
                },
                onInitCaptured: { [weak self] initBytes in
                    guard let self = self else { return }
                    if versionedInit {
                        fileCache.addInitVersion(initBytes, fromSegment: initialSegmentIndex)
                        EngineLog.emit(
                            "[HLSSegmentProducer] versioned init captured for seg-\(initialSegmentIndex) "
                            + "(\(initBytes.count) B, \(isAdCreative ? "SSAI program switch" : "same-PID parameter-set change"))",
                            category: .session
                        )
                    } else if !file.initCaptured {
                        file.initCaptured = true
                        fileCache.setInit(initBytes)
                        EngineLog.emit(
                            "[HLSSegmentProducer] \(file.track == .video ? "init.mp4" : "audio-init.mp4") captured "
                            + "(\(initBytes.count) B)",
                            category: .session
                        )
                    }
                }
            )
            // Write through installMuxer: telemetry getters read the muxer under stateLock, and the
            // outgoing muxer's totals have to be folded before the reference goes.
            self.installMuxer(muxer, into: file)
            file.segmentIndex = initialSegmentIndex
            self.noteSegmentInProgress(file, initialSegmentIndex, muxer: muxer)
            if file.track == .audio, file.head == .min {
                serveEmptyAudio(file, from: baseIndex, to: initialSegmentIndex)
            }
            return muxer
        } catch {
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name) muxer alloc for seg-\(initialSegmentIndex) failed: \(error)",
                category: .session
            )
            return nil
        }
    }

    /// The audio track as a muxer carries it.
    private var audioMuxerConfig: MP4SegmentMuxer.AudioConfig? {
        audioConfig.map { a in
            MP4SegmentMuxer.AudioConfig(codecpar: a.codecpar, timeBase: a.inputTimeBase,
                                        soundSampleEntryOverride: a.bridge?.soundSampleEntryOverride, language: a.language)
        }
    }

    /// Serves indices `[first, end)` of the audio rendition as fragments with no sample, each at its segment's
    /// start on the audio track's timeline: their time holds no audio, and the playlist lists every index the
    /// video's does.
    private func serveEmptyAudio(_ file: Rendition, from first: Int, to end: Int) {
        guard file.track == .audio, first < end, let atb = file.audioTimeBase, atb.den > 0 else { return }
        let shift = videoShiftPts == Int64.min ? 0 : videoShiftPts
        for index in first..<end {
            let local = index - baseIndex
            guard local >= 0, local < segmentBoundaries.count else { continue }
            let start = av_rescale_q(segmentBoundaries[local] &- shift, sourceVideoTimeBase, atb)
            let bytes = MP4SegmentMuxer.emptyFragment(trackID: 1, sequence: UInt32(truncatingIfNeeded: index + 1),
                                                      baseMediaDecodeTime: UInt64(max(0, start)))
            let path = file.cache.sessionDir.appendingPathComponent(
                "staging-audio-\(index)-empty-\(UUID().uuidString.prefix(8)).tmp")
            guard (try? bytes.write(to: path)) != nil else { continue }
            file.cache.adopt(index: index, stagingPath: path, byteCount: bytes.count, videoReach: nil)
            file.head = max(file.head, index)
            EngineLog.emit("[HLSSegmentProducer] audio\(index).mp4 holds no audio; served without samples",
                           category: .session, level: .verbose)
        }
    }

    /// Returns [start, end) on the AVPlayer axis for subtitle injection. VOD: from segmentBoundaries
    /// minus the plan anchor (AE#268: the anchor defines the item axis; the shift carries a restart's
    /// gate overshoot on top of it and would move the window under the cues). Live: from liveSegmentStartByIndex.
    private func segmentWindowAVPlayerSeconds(
        segIdx: Int,
        nextSegIdx: Int
    ) -> (start: Double, end: Double)? {
        if isLive {
            guard let t0 = liveSegmentStartByIndex[segIdx],
                  let t1 = liveSegmentStartByIndex[nextSegIdx]
            else { return nil }
            return (t0, t1)
        } else {
            guard videoShiftPts != Int64.min, sourceVideoTbSeconds > 0 else { return nil }
            let i = segIdx - baseIndex
            let iNext = nextSegIdx - baseIndex
            guard i >= 0, iNext < segmentBoundaries.count else { return nil }
            let t0 = Double(segmentBoundaries[i] - planAnchorVideoPts) * sourceVideoTbSeconds
            let t1 = Double(segmentBoundaries[iNext] - planAnchorVideoPts) * sourceVideoTbSeconds
            return (t0, t1)
        }
    }

    /// AE#222 prime scan: read forward from wherever the pump stopped until the muxed audio stream yields one
    /// packet, and copy its bytes. That single frame is all movenc needs to build the real `dec3` / `dac3` /
    /// `dmlp` sample entry, so the rebuilt session keeps its stream-copy (Atmos included) instead of bridging.
    ///
    /// Scoped to single-demuxer stream-copy audio: a bridged session's muxed frames come from the encoder, not
    /// the source, and feeding the bridge here would consume the very encoder state a restart depends on (#99
    /// root cause B). Bounded so a source whose audio never arrives (or arrives absurdly late) gives up and
    /// leaves the host's fallbacks in charge instead of stalling the session on an unbounded read.
    private func scanForAudioMoovPrimeFrame() -> [UInt8]? {
        guard let audio = audioConfig, audio.bridge == nil, sideAudioDemuxer == nil else { return nil }
        // AE#366: a previous producer of this session already looked everywhere it can look. Paying
        // the scan plus the hunt again on every revive attempt buys the same answer for a few hundred
        // MiB of reads, which on a remote source is minutes of black screen before the host is told.
        guard !audioMoovPrimeKnownUnobtainable else {
            EngineLog.emit(
                "[HLSSegmentProducer] AE#366 skipping the moov-prime search: this session already "
                + "searched the whole source for an audio frame and found none",
                category: .session
            )
            markAudioMoovPrimeUnobtainable()
            return nil
        }
        let result = readForwardForAudioFrame(
            streamIndex: audio.sourceStreamIndex,
            byteCap: Self.moovPrimeScanByteCap,
            deadline: Date().addingTimeInterval(Self.moovPrimeScanTimeoutSeconds),
            label: "AE#222 prime scan"
        )
        if let frame = result.frame { return frame }
        guard result.mayRetryElsewhere else { return nil }
        return huntAudioMoovPrimeFrameBySeeking(streamIndex: audio.sourceStreamIndex)
    }

    /// AE#366: the forward scan assumes the audio is a few seconds behind the video in FILE order.
    /// That holds for the #222 shape and fails completely for a track that is sparsely interleaved or
    /// muxed in bulk somewhere else: the first packet of a legacy dub can sit hundreds of MiB in, and
    /// no byte budget rescues that. Worse, the budget is a byte budget, so what it buys shrinks as the
    /// bitrate grows: 128 MiB is five minutes of a 3 Mbps encode and ten seconds of a 97 Mbps UHD one.
    ///
    /// The frame does not have to be the FIRST one. AC-3 and E-AC-3 are one complete syncframe per
    /// packet and movenc's `handle_eac3` builds the whole sample entry from whichever frame it gets
    /// (AE#340), and the prime frame's timestamp is discarded anyway (the muxer truncates the prime
    /// fragment and re-arms `frag_discont`). So instead of reading further and further forward, seek
    /// to a handful of positions and take any frame the track yields there.
    ///
    /// The order is picked for the two shapes that produce this failure: a track present throughout
    /// with wide gaps (the midpoint finds it immediately) and a track muxed in bulk near the end (the
    /// 90 % probe does). Nothing in the container says which one it is: measured on a fixture whose
    /// first audio packet sits at 211 MiB, `AVStream.start_time` for that track still reads 0.
    /// Probe positions in seconds, midpoint first. Empty for a source whose duration is unknown or
    /// too short to have anywhere else to look, which is also every live source.
    static func moovPrimeHuntPositions(durationSeconds: Double) -> [Double] {
        guard durationSeconds.isFinite, durationSeconds > 1 else { return [] }
        return moovPrimeHuntFractions.map { durationSeconds * $0 }
    }

    private func huntAudioMoovPrimeFrameBySeeking(streamIndex: Int32) -> [UInt8]? {
        // Live is forward-only: a seek would abandon the join point, and a live source that has not
        // produced an audio packet yet will produce one on its own.
        guard !isLive else { return nil }
        let positions = Self.moovPrimeHuntPositions(durationSeconds: demuxer.duration)
        guard !positions.isEmpty else { return nil }
        let deadline = Date().addingTimeInterval(Self.moovPrimeHuntTimeoutSeconds)

        for target in positions {
            if checkShouldStop() || Date() > deadline { break }
            guard demuxer.seek(to: target) else {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#366 prime hunt: seek to "
                    + "\(String(format: "%.1f", target))s failed; source is not seekable, giving up",
                    category: .session
                )
                markAudioMoovPrimeUnobtainable()
                return nil
            }
            let result = readForwardForAudioFrame(
                streamIndex: streamIndex,
                byteCap: Self.moovPrimeHuntProbeByteCap,
                deadline: deadline,
                label: "AE#366 prime hunt at \(String(format: "%.1f", target))s"
            )
            if let frame = result.frame { return frame }
            if !result.mayRetryElsewhere { return nil }
        }
        EngineLog.emit(
            "[HLSSegmentProducer] AE#366 prime hunt: no audio packet at any probe position; "
            + "the selected track cannot prime the moov in this session",
            category: .session
        )
        markAudioMoovPrimeUnobtainable()
        return nil
    }

    /// Records the structural verdict. Deliberately NOT set when a read threw or the pump was asked
    /// to stop: those say nothing about the track, and treating them as final would turn a transient
    /// I/O hiccup into a dead session.
    private func markAudioMoovPrimeUnobtainable() {
        stateLock.lock()
        _audioMoovPrimeUnobtainable = true
        stateLock.unlock()
    }

    /// One bounded forward read for a packet on `streamIndex`, copying its bytes.
    ///
    /// `mayRetryElsewhere` is false when the read itself failed or the caller was told to stop: those
    /// are reasons to abandon the hunt, unlike "this region carries no audio", which is a reason to
    /// look somewhere else.
    private func readForwardForAudioFrame(
        streamIndex: Int32, byteCap: Int, deadline: Date, label: String
    ) -> (frame: [UInt8]?, mayRetryElsewhere: Bool) {
        var bytesRead = 0
        var packetsRead = 0

        while true {
            if checkShouldStop() { return (nil, false) }
            if bytesRead >= byteCap || Date() > deadline {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) gave up after \(packetsRead) packet(s) / "
                    + "\(bytesRead / (1024 * 1024)) MiB without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            let pkt: UnsafeMutablePointer<AVPacket>?
            do {
                pkt = try demuxer.readPacket()
            } catch {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) read failed: \(error)",
                    category: .session
                )
                return (nil, false)
            }
            guard let packet = pkt else {
                EngineLog.emit(
                    "[HLSSegmentProducer] \(label) hit EOF after \(packetsRead) packet(s) "
                    + "without an audio packet",
                    category: .session
                )
                return (nil, true)
            }
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            packetsRead += 1
            bytesRead += Int(max(packet.pointee.size, 0))

            guard packet.pointee.stream_index == streamIndex,
                  packet.pointee.size > 0,
                  let data = packet.pointee.data
            else { continue }

            let frame = [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
            EngineLog.emit(
                "[HLSSegmentProducer] \(label) captured a \(frame.count) B audio frame after "
                + "\(packetsRead) packet(s) / \(bytesRead / (1024 * 1024)) MiB "
                + "(srcDts=\(packet.pointee.dts))",
                category: .session
            )
            return (frame, true)
        }
    }

    private func advanceMuxer(_ file: Rendition, to newIdx: Int) -> MP4SegmentMuxer? {
        guard let muxer = file.muxer else { return nil }
        let cutIdx = file.segmentIndex
        // Audit SEG-5: an abandoned pump whose blocked read returns after stop() gets a packet from
        // the NEW producer's position. Cutting on it would adopt this pump's partial segment under
        // its full index; the teardown rule decides what happens to the in-flight segment instead.
        if checkShouldStop() { return nil }
        if file.track == .video { releaseOverlayRunStart() }
        switch muxer.cutFragmentForNextSegment(newIdx) {
        case .completed(let path, let bytesWritten):
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name)-\(cutIdx).m4s captured (\(bytesWritten) B)",
                category: .session, level: .verbose
            )
            file.cache.adopt(index: cutIdx,
                             stagingPath: path,
                             byteCount: bytesWritten,
                             videoReach: file.track == .video ? takeVideoReach(forSegmentIndex: cutIdx) : nil)
            file.head = max(file.head, cutIdx)
            recordSegmentOpening(file, muxer, index: cutIdx)
            if file.track == .video {
                // AE#286: per-epoch head. cache.highestStoredIndex is monotonic across restarts and would
                // credit this pump with the previous epoch's production.
                pumpEpochHighestStored = max(pumpEpochHighestStored, cutIdx)
                if isLive {
                    reportLiveSegmentFinalized(index: cutIdx, nextIndex: newIdx)
                } else if onSequentialSegmentFinalized != nil {
                    reportSequentialSegmentFinalized(index: cutIdx, isFinal: false)
                }
            }
            // Cut succeeded but muxer failed to open the next staging fd: silently discards every subsequent byte.
            if muxer.isWedged {
                EngineLog.emit(
                    "[HLSSegmentProducer] muxer wedged after \(file.name)-\(cutIdx) cut "
                    + "(next staging fd open failed), ending pump",
                    category: .session
                )
                return nil
            }
        case .deferredAwaitingAudioSampleEntry:
            // AE#222: not a failure. moov cannot carry dec3/dac3/dmlp until one audio packet has been muxed,
            // and this source's first segment has none (its audio blocks sit behind seconds of video in file
            // order). Nothing was written, so the pump exits to let the host rebuild with a prime frame; the
            // scan for that frame happens on the way out.
            cutDeferredAwaitingAudioSampleEntry = true
            // AE#396: the two ways to arrive here are not the same defect and must not read the same.
            // Stream-copy audio is missing a SOURCE packet, which the prime scan goes looking for. A
            // bridged session's muxed frames come from the encoder, so there is nothing in the source
            // to scan for and `scanForAudioMoovPrimeFrame` returns without looking: announcing a scan
            // there described an action that never happened, on the one path where the interesting
            // question ("why has the bridge emitted nothing?") had no line at all.
            if let bridge = audioConfig?.bridge {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#396 \(file.name)-\(cutIdx).m4s cut deferred: the "
                    + "audio sample entry is built from a BRIDGED packet and the bridge has muxed none. "
                    + "Bridge: \(bridge.feedStats.summary)",
                    category: .session
                )
            } else {
                EngineLog.emit(
                    "[HLSSegmentProducer] AE#222 \(file.name)-\(cutIdx).m4s cut deferred: audio sample "
                    + "entry needs a parsed packet and none has been muxed; scanning forward for a prime frame",
                    category: .session
                )
            }
            return nil
        case .empty where file.track == .audio:
            // Its time holds no audio; the rendition still serves the index.
            abandonSegmentInProgress(file, cutIdx)
            serveEmptyAudio(file, from: cutIdx, to: cutIdx + 1)
        case .failed, .empty:
            // Failed cut: muxer has no open staging fd, every byte is silently discarded. Fatal. A video
            // segment with no sample is no segment either.
            abandonSegmentInProgress(file, cutIdx)
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name)-\(cutIdx).m4s cut FAILED; "
                + "muxer is wedged, ending pump",
                category: .session
            )
            return nil
        }
        // #358: the cut jumped over plan indices, so no keyframe reached their boundaries and no
        // segment will ever open there. The VOD playlist still offers them, which is what turns the
        // gap into a consumer that waits forever, so record them for the wedge handler.
        if file.track == .audio {
            // The audio passed these indices without a sample; its rendition still serves them.
            serveEmptyAudio(file, from: cutIdx + 1, to: newIdx)
        } else if !isLive, newIdx > cutIdx + 1 {
            let folded = (cutIdx + 1)..<newIdx
            cache.noteFolded(folded)
            if folded.count > SegmentCache.maxFoldRunLength {
                // #369: a leap this wide is not a long GOP, a timeline jump escaped the rebase.
                EngineLog.emit(
                    "[HLSSegmentProducer] #369 cut leap of \(folded.count) plan indices "
                    + "(discontinuity-scale; a timeline jump escaped the rebase)",
                    category: .session
                )
            }
            EngineLog.emit(
                "[HLSSegmentProducer] #358 plan indices \(folded.lowerBound)...\(folded.upperBound - 1) "
                + "folded into seg-\(newIdx) (no IRAP reached their boundary)",
                category: .session
            )
        }
        file.segmentIndex = newIdx
        noteSegmentInProgress(file, newIdx, muxer: muxer)
        // The video drives backpressure; the audio rendition's segments follow the source.
        guard file.track == .video else { return checkShouldStop() ? nil : muxer }
        if isLive {
            // Live is source-paced: the pump only runs ahead of real time while draining the join
            // backlog, and the sliding window (notePlaylistBuild -> evictBelow) bounds resident
            // segments. Parking on the consumer's fetch high-water here deadlocked against a held
            // LL-HLS blocking reload (the hold starves the segment GET that would release the park)
            // and pushed TCP backpressure onto the single-connection origin whenever the join
            // backlog exceeded bufferAheadSegments.
            if !awaitLiveWindowHeadroom(head: newIdx) { return nil }
        } else {
            let backpressureTarget = newIdx - bufferAheadSegments
            let parkSkipped = onSequentialSegmentFinalized != nil
                && Self.sequentialParkWouldSelfDeadlock(target: backpressureTarget,
                                                        highestAdvertised: seqHighestAdvertisedIndex)
            if parkSkipped {
                // #369: skip the self-deadlocking park; the disk budget below stays the resource
                // bound, and normal parking resumes as soon as the frontier catches back up.
                if !loggedSequentialParkSkip {
                    loggedSequentialParkSkip = true
                    EngineLog.emit(
                        "[HLSSegmentProducer] #369 backpressure park skipped: "
                        + "target=\(backpressureTarget) is beyond the advertisable "
                        + "frontier=\(seqHighestAdvertisedIndex); the frontier only advances "
                        + "while this pump runs",
                        category: .session
                    )
                }
            } else if !awaitBackpressureRelease(target: backpressureTarget, head: newIdx, context: "advance") {
                return nil
            }
            // #369 follow-up: a skipped advance park hands the only remaining hold to the disk park,
            // whose "no wedge breaker needed" rests on the advance park having caught a frozen
            // consumer first. Carry the detector across, or the pump races to the budget and then
            // parks there forever on a consumer that will never move again.
            if !awaitPrefetchDiskBudgetRelease(head: newIdx, context: "advance",
                                               detectWedge: parkSkipped) { return nil }
        }
        if checkShouldStop() { return nil }

        return muxer
    }

    /// Sequential-VOD duration became known (next segment's start recorded at the ledger).
    /// Reports immediately when the segment is already captured; otherwise parks until the
    /// capture side arrives.
    private func noteSequentialDurationKnown(index: Int, duration: Double) {
        if seqCapturedAwaitingDuration.remove(index) != nil {
            emitSequentialReport(index: index, duration: duration)
        } else {
            seqDurationAwaitingCapture[index] = duration
        }
    }

    /// Sequential-VOD capture side of the pairing. `isFinal` (EOF finalize) reports with the cut
    /// target when no next ledger entry will ever supply the real duration - one estimated tail
    /// EXTINF beats a playlist that never completes.
    private func reportSequentialSegmentFinalized(index: Int, isFinal: Bool) {
        if let dur = seqDurationAwaitingCapture.removeValue(forKey: index) {
            emitSequentialReport(index: index, duration: dur)
        } else if isFinal {
            let dur: Double
            if let start = vodSegmentStartByIndex[index], lastMuxedItemAxisSeconds > start {
                dur = lastMuxedItemAxisSeconds - start
            } else {
                dur = targetSegmentDurationSeconds
            }
            emitSequentialReport(index: index, duration: dur)
        } else {
            seqCapturedAwaitingDuration.insert(index)
        }
    }

    /// Newest item-axis video segment start muxed (seconds); floors the final segment's EXTINF
    /// estimate at EOF. Pump-thread only.
    private var lastMuxedItemAxisSeconds: Double = 0

    private func reportLiveSegmentFinalized(index: Int, nextIndex: Int?) {
        guard let startSeconds = liveSegmentStartByIndex[index] else {
            liveSegmentSoundByIndex.removeValue(forKey: index)
            EngineLog.emit(
                "[HLSSegmentProducer] live finalize: no recorded start for seg-\(index); skipping append",
                category: .session
            )
            return
        }
        let duration: Double
        if let nextIndex = nextIndex, let nextStart = liveSegmentStartByIndex[nextIndex] {
            let d = nextStart - startSeconds
            duration = d > 0 ? d : targetSegmentDurationSeconds
        } else {
            duration = targetSegmentDurationSeconds
        }
        let discontinuous = liveSegmentDiscontinuousByIndex[index] ?? false
        let sound = liveSegmentSoundByIndex.removeValue(forKey: index)
        liveSegmentStartByIndex.removeValue(forKey: index)
        liveSegmentDiscontinuousByIndex.removeValue(forKey: index)
        stampLiveSegmentFinalize()
        EngineLog.emit(
            "[HLSSegmentProducer] live seg-\(index) finalized: start=\(String(format: "%.3f", startSeconds))s "
            + "dur=\(String(format: "%.3f", duration))s"
            + (sound.map { $0.map { String(format: " sound=%.3f..%.3fs", $0.first, $0.last) } ?? " sound=none" } ?? "")
            + (discontinuous ? " [DISCONTINUITY]" : ""),
            category: .session
        )
        if let span = sound ?? nil { onLiveSegmentSound?(index, span.first, span.last) }
        onLiveSegmentFinalized?(index, duration, startSeconds, discontinuous)
        if let colour = liveColourBySegment.removeValue(forKey: index) { onLiveVideoColour?(startSeconds, colour) }
    }

    /// AE#412: what the segment finalized at `index` offers a cold arrival, as an offset from its
    /// ADVERTISED start, so the answer carries no axis with it. Consumes the recording.
    ///
    /// nil means "no claim", which is exactly today's behaviour: live (its playlist only ever offers
    /// what was finalized), an unresolved video time base, or an index outside this epoch's plan.
    /// `.none` is a claim, and a load-bearing one: audio opened a boundary the cutter folded, so the
    /// segment carries no random-access point at all and nothing in it can start a decode run.
    private func takeVideoReach(forSegmentIndex index: Int) -> SegmentCache.VideoReach? {
        let syncPts = firstSyncItemPtsBySegment.removeValue(forKey: index)
        firstSyncItemPtsBySegment = firstSyncItemPtsBySegment.filter { $0.key > index }
        guard !isLive, sourceVideoTbSeconds > 0 else { return nil }
        let localI = index - baseIndex
        guard localI >= 0, localI < segmentBoundaries.count else { return nil }
        guard let syncPts, syncPts != Int64.min else {
            EngineLog.emit(
                "[HLSSegmentProducer] #412 seg-\(index) carries no random-access point "
                + "(advertised \(String(format: "%.3f", Double(segmentBoundaries[localI]) * sourceVideoTbSeconds))s); "
                + "a cold arrival cannot start a decode run in it",
                category: .session
            )
            return SegmentCache.VideoReach.none
        }
        let shiftTicks = videoShiftPts == Int64.min ? 0 : videoShiftPts
        let syncSourcePts = syncPts &+ shiftTicks
        let offset = Double(syncSourcePts &- segmentBoundaries[localI]) * sourceVideoTbSeconds
        if offset > 0 {
            EngineLog.emit(
                "[HLSSegmentProducer] #412 seg-\(index) opens \(String(format: "%.3f", offset))s "
                + "below its first random-access point; a cold arrival below that lands late",
                category: .session, level: .verbose
            )
        }
        return .syncAt(offsetSeconds: offset)
    }

    /// A VOD segment is registered with the cache as it is opened and flushed in fragments every
    /// `progressiveFragmentSeconds`, so the loopback server has something to send while it is still being
    /// cut. Live keeps its own window and blocking-reload contracts.
    private var servesProgressively: Bool { !isLive }

    private func noteSegmentInProgress(_ file: Rendition, _ index: Int, muxer: MP4SegmentMuxer) {
        // An overlay run's first segment is served whole, once its picture is decoded.
        guard servesProgressively, file.track == .audio || !holdsOverlayRunStart || overlayRunStartReleased
        else { return }
        file.cache.beginInProgress(index: index, stagingPath: muxer.stagingURL)
    }

    private func abandonSegmentInProgress(_ file: Rendition, _ index: Int) {
        guard servesProgressively, index != .min else { return }
        file.cache.abandonInProgress(index: index)
    }

    /// What the segment just cut at `index` opened with. Live keeps its sound span (AE#684); VOD
    /// reports the normalization its bytes were written with, which maps a frame's time in the file
    /// back onto the source (scrub thumbnails decode the file itself).
    private func recordSegmentOpening(_ file: Rendition, _ muxer: MP4SegmentMuxer, index: Int) {
        let opening = muxer.takeSegmentOpening()
        if isLive {
            // The sound span is the file's that carries the audio: the video's when muxed, the audio
            // rendition's when not.
            guard muxer.audioOutputStreamIndex >= 0 else { return }
            let atb = muxer.muxerAudioTimeBase
            let tick = atb.den > 0 ? Double(atb.num) / Double(atb.den) : 0
            liveSegmentSoundByIndex.updateValue(
                opening.sound.map { (Double($0.first) * tick, Double($0.last) * tick) }, forKey: index)
            return
        }
        guard file.track == .video, videoShiftPts != Int64.min else { return }
        onSegmentWritten?(index, Double(videoShiftPts) * sourceVideoTbSeconds)
    }

    /// An overlay session's H.264 / HEVC A53 captions, read off the source packet as `finalizeAndWriteVideo` reads a
    /// native session's, on the same terms: the packets this producer muxes are the placeholder's.
    private func observeOverlaySourceCaptions(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let placeholder = overlayPlaceholder, let observe = a53CaptionObserver,
              let data = packet.pointee.data, packet.pointee.pts != Int64.min else { return }
        let kind: A53SEIParser.CodecKind
        switch placeholder.sourceCodecID {
        case AV_CODEC_ID_H264: kind = .h264
        case AV_CODEC_ID_HEVC: kind = .hevc
        default: return
        }
        let size = Int(packet.pointee.size)
        guard A53SEIParser.mayContainA53(data, size) else { return }
        let triplets = A53SEIParser.triplets(in: data, size: size, codec: kind, framing: placeholder.sourceFraming)
        guard !triplets.isEmpty else { return }
        observe(triplets, Self.foldingShiftBack(packet.pointee.pts, shift: videoShiftPts),
                Self.foldingShiftBack(packet.pointee.dts, shift: videoShiftPts), sourceVideoTimeBase)
    }

    /// An overlay session: the run's first segment waits for the overlay's decode to have the run's first picture
    /// (the software overlay's picture, or the FEL overlay's enhancement picture). AVPlayer prerolls its own decode
    /// and starts its clock as soon as it has the segment, so this is the one point where it has to wait for a
    /// decoder it does not own; after it the decoder only has to keep pace.
    private func releaseOverlayRunStart() {
        guard holdsOverlayRunStart, !overlayRunStartReleased else { return }
        overlayRunStartReleased = true
        let start = DispatchTime.now()
        let shouldStop: () -> Bool = { [weak self] in self?.checkShouldStop() ?? true }
        var ready = true
        if let overlayDecodeTap {
            ready = overlayDecodeTap.awaitRunStart(timeout: Self.overlayRunStartTimeout, shouldStop: shouldStop)
        }
        #if DualLayerDolbyVision
        if let felTap {
            ready = felTap.awaitRunStart(timeout: Self.overlayRunStartTimeout, shouldStop: shouldStop)
        }
        #endif
        let waitedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        EngineLog.emit("[HLSSegmentProducer] overlay run start: \(ready ? "first picture decoded" : "no picture yet, released") "
                       + "after \(String(format: "%.0f", waitedMs)) ms", category: .session)
    }

    /// Finalize `file`'s muxer and adopt its open segment. The audio rendition's adopts one with no sample
    /// as such (`serveEmptyAudio`), as a cut does.
    private func finalizeSessionMuxerAndAdopt(_ file: Rendition) {
        guard let muxer = file.muxer else { return }
        let idx = file.segmentIndex
        if file.track == .video { releaseOverlayRunStart() }
        if let result = muxer.finalize() {
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name)-\(idx).m4s captured (\(result.bytesWritten) B)",
                category: .session, level: .verbose
            )
            file.cache.adopt(index: idx, stagingPath: result.path,
                             byteCount: result.bytesWritten,
                             videoReach: file.track == .video ? takeVideoReach(forSegmentIndex: idx) : nil)
            file.head = max(file.head, idx)
            recordSegmentOpening(file, muxer, index: idx)
            if file.track == .video {
                if isLive {
                    reportLiveSegmentFinalized(index: idx, nextIndex: nil)
                } else if onSequentialSegmentFinalized != nil {
                    reportSequentialSegmentFinalized(index: idx, isFinal: true)
                }
            }
        } else if file.track == .audio {
            abandonSegmentInProgress(file, idx)
            serveEmptyAudio(file, from: idx, to: idx + 1)
        } else {
            abandonSegmentInProgress(file, idx)
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name)-\(idx).m4s final finalize failed; not adopted",
                category: .session
            )
        }
        installMuxer(nil, into: file)
        file.segmentIndex = .min
    }

    /// Finalize `file`'s muxer to release its context and staging file, but throw the partial segment
    /// away instead of adopting it into the cache (see `shouldAdoptTeardownSegment`).
    private func discardSessionMuxer(_ file: Rendition) {
        guard let muxer = file.muxer else { return }
        let idx = file.segmentIndex
        // The partial segment is not adopted; a reader draining it is told before the file goes.
        abandonSegmentInProgress(file, idx)
        if let result = muxer.finalize() {
            try? FileManager.default.removeItem(at: result.path)
            EngineLog.emit(
                "[HLSSegmentProducer] \(file.name)-\(idx).m4s partial at teardown (\(result.bytesWritten) B) "
                + "discarded, not adopted",
                category: .session
            )
        }
        installMuxer(nil, into: file)
        file.segmentIndex = .min
    }

    /// The pump's end, for every file it writes: adopted (`adopting`), the audio rendition then serving
    /// each index through the video's last, or the partial segments discarded.
    private func finishFiles(adopting: Bool) {
        let lastVideoIndex = videoFile.segmentIndex
        let files = [videoFile] + (audioFile.map { [$0] } ?? [])
        for file in files {
            if adopting { finalizeSessionMuxerAndAdopt(file) } else { discardSessionMuxer(file) }
        }
        if adopting, let audioFile, lastVideoIndex != .min {
            serveEmptyAudio(audioFile, from: max(audioFile.head + 1, baseIndex), to: lastVideoIndex + 1)
        }
    }

    deinit {
        // Backstop for a pump that never exited normally; without an exit reason, a VOD in-flight
        // segment is partial by definition, so only live may adopt here.
        if videoFile.muxer != nil || audioFile?.muxer != nil {
            finishFiles(adopting: isLive)
        }
    }

    // MARK: - Public API

    func start() {
        assert(!isLive || onLiveSegmentFinalized != nil,
               "a live producer started without its provider reports cuts segments no playlist lists (audit HLS-101)")
        stateLock.lock()
        guard !pumpStarted else { stateLock.unlock(); return }
        pumpStarted = true
        stateLock.unlock()

        // AE#286: a thread we own rather than a dispatch queue, because the pump's urgency changes
        // within one long-running block and a queue's QoS is fixed at creation.
        let thread = Thread { [weak self] in
            self?.runPumpLoop()
        }
        thread.name = "AetherEngine.HLSSegmentProducer.pump"
        thread.stackSize = 1 << 20
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// AE#286: match the pump's QoS to whether anything is waiting on it. Called at segment
    /// boundaries and after a backpressure park, both cheap and both points where the answer can
    /// have changed. VOD only: live production is source-paced and the LL-HLS blocking reload holds
    /// an AVPlayer request open on the very next segment, so live is latency-critical throughout.
    private func retunePumpQoS() {
        guard !isLive, !pumpUnwinding else { return }
        let target = cache.targetIndex
        let lead = pumpEpochHighestStored >= 0 ? String(pumpEpochHighestStored - target) : "n/a"
        // A consumer that has fetched has still not necessarily started rendering: AVPlayer keeps
        // filling its startup buffer after the first segment, and demoting there cost 80 ms of
        // time-to-first-frame under load with the forward buffer already 9 segments deep.
        let relaxed = !pumpRelaxationRefused && Self.pumpMayRelax(
            hasStartedRendering: hasStartedRenderingProvider?() ?? true,
            targetIndex: target,
            epochHighestStored: pumpEpochHighestStored,
            relaxedLeadSegments: pumpRelaxedLeadSegments
        )
        let desired: qos_class_t = relaxed ? QOS_CLASS_UTILITY : QOS_CLASS_USER_INITIATED
        guard desired != pumpQoSCurrent else { return }
        pumpQoSCurrent = desired
        pumpRelaxationRate.suspend()
        pthread_set_qos_class_self_np(desired, 0)
        // Read the class back: a thread that was opted out of the QoS system silently keeps the old
        // one, and then the whole mechanism is a no-op that still looks configured.
        EngineLog.emit(
            "[HLSSegmentProducer] pump qos -> \(QoSClass.name(desired)) "
            + "(now=\(QoSClass.name(qos_class_self())) epochHead=\(pumpEpochHighestStored) "
            + "target=\(target) lead=\(lead))",
            category: .session
        )
    }

    /// AE#850: while relaxed, compare the content this pump demuxes against wall time, and stop
    /// relaxing for the rest of the session once `.utility` has proved slower than real time. The
    /// demux position stands for production because the bridge and the muxer run on this thread (the
    /// APAC encode queue inherits its class), so a pump that demuxes slowly produces slowly.
    private func measurePumpRelaxationRate(nowNanos: UInt64, dts: Int64) {
        guard !isLive, !pumpRelaxationRefused, pumpQoSCurrent == QOS_CLASS_UTILITY,
              dts != Int64.min, sourceVideoTbSeconds > 0 else { return }
        let wall = Double(nowNanos) / 1e9
        let content = Double(dts) * sourceVideoTbSeconds
        guard let rate = pumpRelaxationRate.observe(wallSeconds: wall, contentSeconds: content) else { return }
        pumpRelaxationRefused = true
        EngineLog.emit(
            "[HLSSegmentProducer] pump qos: utility produced at \(String(format: "%.2f", rate))x real time, "
            + "below \(String(format: "%.2f", PumpRelaxationRateProbe.requiredRate))x, "
            + "staying userInitiated for this session (AE#850)",
            category: .session
        )
    }

    /// AE#286: the unwind is latency-critical whatever the pump had relaxed to. A stop is waited on
    /// (`waitForFinish`, from a seek's restart on the local server's `.userInitiated` queue and from
    /// the session stop), and every other exit hands the host a verdict it acts on. A condition
    /// donates no priority to the thread it waits for, so a relaxed pump tore down and broadcast its
    /// finish at `.utility`, the inversion Xcode's Thread Performance Checker reports at the wait in
    /// `waitForFinish`. The checker judges the class the signalling thread requested, which a QoS
    /// override from the waiter does not change, so the pump moves itself. The teardown flush can
    /// still park on backpressure, so the retune is latched off for the rest of the pump.
    private func restorePumpQoSForUnwind() {
        pumpUnwinding = true
        guard pumpQoSCurrent != QOS_CLASS_USER_INITIATED else { return }
        pumpQoSCurrent = QOS_CLASS_USER_INITIATED
        pumpRelaxationRate.suspend()
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
        EngineLog.emit(
            "[HLSSegmentProducer] pump qos -> userInitiated for unwind (now=\(QoSClass.name(qos_class_self())))",
            category: .session
        )
    }

    /// Async stop; also wakes backpressure waiter so restart doesn't wait a full poll timeout.
    func stop() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
        cache.wakeWaiters()
    }

    fileprivate func checkShouldStop() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    func waitForFinish(timeout: TimeInterval) -> Bool {
        finishCondition.lock()
        defer { finishCondition.unlock() }
        if didFinishFlag { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while !didFinishFlag {
            if !finishCondition.wait(until: deadline) { return false }
        }
        return true
    }

    // MARK: - Dual-source pull-merge

    private enum PacketOrigin { case main, side }

    /// Pump-thread-only: has the first source read of this producer been timed yet (#93 latency)?
    private var pumpFirstReadLogged = false

    private struct LiveReplaySample {
        let signature: LivePacketReplayGuard.Signature
        let seconds: Double
        let timeBaseSeconds: Double
    }

    private struct ReplayBufferedPacket {
        let packet: UnsafeMutablePointer<AVPacket>
        let origin: PacketOrigin
        let sample: LiveReplaySample?
        let isDuplicate: Bool
        var untimedBoundaryVideo = false
    }

    private struct InterruptedSourceReplay: Error {}

    /// Returns next packet in global decode order. Single-demuxer fast path; dual-demuxer yields lower-DTS first.
    /// #93 restart latency: the FIRST read of a producer is timed (one line; info when it exceeded
    /// 1 s), because rrgomes' trace shows exactly that read waiting 19-46 s client-side while a
    /// fresh side reader overtakes it in 300 ms.
    private func readNextSourcePacket() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin,
                                                   replaySample: LiveReplaySample?)? {
        guard !pumpFirstReadLogged else { return try readNextSourcePacketMergedTapped() }
        pumpFirstReadLogged = true
        let t0 = DispatchTime.now()
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
            EngineLog.emit(
                "[HLSSegmentProducer] first source read after start took \(Int(ms))ms",
                category: .session, level: ms > 1000 ? .info : .verbose
            )
        }
        return try readNextSourcePacketMergedTapped()
    }

    /// AE#560: the one place every source packet of this route passes through on its way to the
    /// pump, main demuxer and side-audio demuxer already merged into global decode order. The
    /// recording tap sits here rather than on `Demuxer.readPacket` for exactly that reason: a
    /// packed AAC audio rendition in live HLS rides a SIDE demuxer, and a tap on the main one
    /// alone would record those channels silently without audio.
    ///
    /// It is also upstream of `bridge.feed`, so the recording carries the source's own audio codec
    /// while playback listens to the bridged rendition.
    private func readNextSourcePacketMergedTapped() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin,
                                                               replaySample: LiveReplaySample?)? {
        while true {
            if !replayPending.isEmpty || !replayReady.isEmpty {
                stateLock.lock()
                let stopped = shouldStop
                stateLock.unlock()
                if stopped {
                    freeReplayPackets()
                    return nil
                }
            }
            if replayReadyIndex < replayReady.count {
                let ready = replayReady[replayReadyIndex]
                replayReadyIndex += 1
                if replayReadyIndex == replayReady.count {
                    replayReady.removeAll(keepingCapacity: true)
                    replayReadyIndex = 0
                }
                logDamagedLivePacket(ready.packet, origin: ready.origin, action: "forwarded")
                logVideoPacketProgress(ready.sample)
                tapForRecording(ready.packet)
                recordPlayedMedia(ready.packet, origin: ready.origin)
                return (ready.packet, ready.origin, ready.sample)
            }
            if let replayDeferredError {
                self.replayDeferredError = nil
                throw replayDeferredError
            }
            let read: (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)?
            do {
                read = try readNextSourcePacketMerged()
            } catch {
                if !replayPending.isEmpty {
                    replayDeferredError = error
                    try rollbackReplayCandidate(reason: "source read failed before overlap was confirmed")
                    continue
                }
                throw error
            }
            guard let read else {
                if !replayPending.isEmpty {
                    try rollbackReplayCandidate(reason: "source ended before overlap was confirmed")
                    continue
                }
                return nil
            }
            let sample = liveReplaySample(packet: read.packet, origin: read.origin)
            if let sample {
                let wasCheckingReplay = liveReplayGuard.isDroppingReplay
                let decision = liveReplayGuard.inspect(
                    sample.signature, sourceSeconds: sample.seconds,
                    timeBaseSeconds: sample.timeBaseSeconds,
                    videoFrontier: lastVideoSourceDts, audioFrontier: lastAudioSourceDts,
                    hasAudio: audioConfig != nil,
                    isCorrupt: damagedLivePacketStream(read.packet, origin: read.origin) != nil)
                if decision.drop, !liveReplayGuard.isDroppingReplay, decision.event == nil {
                    var duplicate: UnsafeMutablePointer<AVPacket>? = read.packet
                    trackedPacketFree(&duplicate)
                    continue
                }
                if case .some(.began) = decision.event {
                    // A complete overlap continues in place. An interrupted, confirmed prefix
                    // must not be remuxed as new media; ambiguous candidates still lose nothing.
                    noCutWatchdog?.setReplayChecking(true, at: Date())
                    EngineLog.emit(
                        "[HLSSegmentProducer] live source overlap candidate: exact packet match "
                        + "after timestamp rollback; checking both tracks before output",
                        category: .session)
                }
                if liveReplayGuard.isDroppingReplay || decision.holdDamagedBoundary || decision.event != nil {
                    // A held outgoing boundary can precede a damaged first returning PES.
                    // Arm at the replay transition even when pending is already nonempty.
                    if !wasCheckingReplay, liveReplayGuard.isDroppingReplay {
                        noCutWatchdog?.setReplayChecking(true, at: Date())
                    }
                    logDamagedLivePacket(read.packet, origin: read.origin, action: "held")
                    noCutWatchdog?.noteReplayPacketRead(at: Date())
                    replayPending.append(ReplayBufferedPacket(packet: read.packet, origin: read.origin,
                                                               sample: sample, isDuplicate: decision.drop))
                    replayPendingBytes += max(0, Int(read.packet.pointee.size))
                    switch decision.event {
                    case .some(.damagedBoundaryHeld):
                        EngineLog.emit("[HLSSegmentProducer] live damaged boundary held: sourceSeconds=\(String(format: "%.3f", sample.seconds)); waiting for replay evidence before publishing video", category: .session)
                    case .some(.damagedBoundaryForwarded):
                        forwardUnverifiedDamagedBoundary()
                    case .some(.quarantined):
                        EngineLog.emit("[HLSSegmentProducer] live overlap quarantined a changed packet; checking the bounded interval before output", category: .session)
                    case .some(.finished(let videoPackets, let audioPackets, let videoSeconds)):
                        commitReplayCandidate()
                        EngineLog.emit(
                            "[HLSSegmentProducer] live source overlap resolved: "
                            + "removed \(videoPackets) video + \(audioPackets) audio packets "
                            + "across \(String(format: "%.2f", videoSeconds))s; "
                            + "first new packet continues the existing timeline",
                            category: .session)
                    case .some(.mismatch(let videoPackets, let audioPackets)),
                         .some(.interrupted(let videoPackets, let audioPackets)):
                        try rollbackReplayCandidate(reason: "track diverged after \(videoPackets) video "
                            + "+ \(audioPackets) audio matches", divergentStream: sample.signature.stream)
                    default:
                        if replayPendingBytes > Self.maximumReplayPendingBytes
                            || replayPending.count > Self.maximumReplayPendingPackets {
                            try rollbackReplayCandidate(reason: "bounded overlap check reached its limit")
                        }
                    }
                    continue
                }
            }
            // A truncated outgoing PES can also release an unflagged, untimed fragment.
            // Do not synthesize a clock for it before the pending boundary is resolved.
            let untimedBoundaryVideo = liveReplayGuard.isHoldingDamagedBoundary && sample == nil
                && read.origin == .main && read.packet.pointee.stream_index == videoStreamIndex
            if !replayPending.isEmpty, !liveReplayGuard.isHoldingDamagedBoundary || untimedBoundaryVideo {
                noCutWatchdog?.noteReplayPacketRead(at: Date())
                if damagedLivePacketStream(read.packet, origin: read.origin) != nil {
                    liveReplayGuard.noteDamagedPacket()
                }
                logDamagedLivePacket(read.packet, origin: read.origin, action: "held")
                // Untimed fragments of this damaged boundary are provisional too;
                // only verified replay permits discarding them without a signature.
                replayPending.append(ReplayBufferedPacket(packet: read.packet, origin: read.origin,
                    sample: sample, isDuplicate: false, untimedBoundaryVideo: untimedBoundaryVideo))
                replayPendingBytes += max(0, Int(read.packet.pointee.size))
                if replayPendingBytes > Self.maximumReplayPendingBytes
                    || replayPending.count > Self.maximumReplayPendingPackets {
                    try rollbackReplayCandidate(reason: "bounded overlap check reached its limit")
                }
                continue
            }
            // The recording sees the same unique source packets as playback.
            logDamagedLivePacket(read.packet, origin: read.origin, action: "forwarded")
            logVideoPacketProgress(sample)
            tapForRecording(read.packet)
            recordPlayedMedia(read.packet, origin: read.origin)
            return (read.packet, read.origin, sample)
        }
    }

    private func damagedLivePacketStream(_ packet: UnsafePointer<AVPacket>, origin: PacketOrigin) -> String? {
        guard isLive, (packet.pointee.flags & AV_PKT_FLAG_CORRUPT) != 0 else { return nil }
        if origin == .main, packet.pointee.stream_index == videoStreamIndex { return "video" }
        if packet.pointee.stream_index == audioConfig?.sourceStreamIndex,
           (origin == .side) == (sideAudioDemuxer != nil) { return "audio" }
        return nil
    }

    private func logDamagedLivePacket(_ packet: UnsafePointer<AVPacket>, origin: PacketOrigin, action: String) {
        guard let stream = damagedLivePacketStream(packet, origin: origin) else { return }
        let key = stream + action
        damagedPacketLogCounts[key, default: 0] += 1
        let count = damagedPacketLogCounts[key]!
        guard count <= 3 || count.isMultiple(of: 64) else { return }
        let dts = packet.pointee.dts == Int64.min ? "missing" : String(packet.pointee.dts)
        let pts = packet.pointee.pts == Int64.min ? "missing" : String(packet.pointee.pts)
        let keyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        EngineLog.emit("[HLSSegmentProducer] live damaged packet: stream=\(stream) action=\(action) "
            + "count=\(count) dts=\(dts) pts=\(pts) keyframe=\(keyframe)", category: .session)
    }

    private var admittedVideoProgress = VideoPacketProgress()

    private func logVideoPacketProgress(_ sample: LiveReplaySample?) {
        guard let sample, sample.signature.stream == .video,
              let gap = admittedVideoProgress.observe(sample.seconds) else { return }
        EngineLog.emit("[VideoPacketProgress] event=gap route=native previous=\(String(format: "%.3f", gap.previous)) dts=\(String(format: "%.3f", sample.seconds)) gap=\(String(format: "%.3f", gap.seconds)) cadence=\(String(format: "%.3f", gap.cadence))", category: .session)
    }

    private func commitReplayCandidate() {
        let boundary = LivePacketReplayGuard.videoBoundarySummary(replayPending.map {
            (signature: $0.sample?.signature, corrupt: damagedLivePacketStream($0.packet, origin: $0.origin) != nil,
             duplicate: $0.isDuplicate, keyframe: ($0.packet.pointee.flags & AV_PKT_FLAG_KEY) != 0)
        })
        EngineLog.emit("[ReplayVideoBoundary] route=native damaged=\(boundary.damaged) replaced=\(boundary.replaced) unreplaced=\(boundary.unreplaced) retained=\(boundary.retained) keyframes=\(boundary.keyframes) superseded=\(boundary.superseded) untimed=\(replayPending.filter { $0.untimedBoundaryVideo }.count)", category: .session)
        for entry in replayPending {
            // Once both tracks prove the overlap, discard its damaged boundary packets too.
            // A truncated PES can carry valid timestamps beyond the retained audio frontier.
            let damaged = damagedLivePacketStream(entry.packet, origin: entry.origin) != nil
            if entry.isDuplicate || damaged || entry.untimedBoundaryVideo {
                if damaged { logDamagedLivePacket(entry.packet, origin: entry.origin, action: "discarded") }
                var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
                trackedPacketFree(&packet)
            } else {
                replayReady.append(entry)
            }
        }
        let order = LivePacketReplayGuard.verifiedPacketOrder(replayReady.map { $0.sample?.signature })
        let kept = Set(order)
        for index in replayReady.indices where !kept.contains(index) {
            var duplicate: UnsafeMutablePointer<AVPacket>? = replayReady[index].packet
            trackedPacketFree(&duplicate)
        }
        replayReady = order.map { replayReady[$0] }
        for entry in replayReady {
            if let signature = entry.sample?.signature { liveReplayGuard.retainForwardedReplayPacket(signature) }
        }
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        noCutWatchdog?.setReplayChecking(false, at: Date())
    }

    private func rollbackReplayCandidate(reason: String,
                                         divergentStream: LivePacketReplayGuard.Stream? = nil) throws {
        if liveReplayGuard.isHoldingDamagedBoundary {
            forwardUnverifiedDamagedBoundary()
            return
        }
        if let evidence = liveReplayGuard.confirmedPrefix {
            let code: String = switch reason {
            case let value where value.hasPrefix("track diverged"): "track_diverged"
            case "source read failed before overlap was confirmed": "read_failed"
            case "source ended before overlap was confirmed": "source_ended"
            case "bounded overlap check reached its limit": "bounded_limit"
            default: "unknown"
            }
            let stream = divergentStream.map { $0 == .video ? "video" : "audio" } ?? "none"
            EngineLog.emit(
                "[HLSSegmentProducer] verified live replay interrupted: reason=\(code) stream=\(stream) "
                + "videoMatches=\(evidence.videoPackets) audioMatches=\(evidence.audioPackets) "
                + "videoSeconds=\(String(format: "%.2f", evidence.videoSeconds)) "
                + "audioSeconds=\(String(format: "%.2f", evidence.audioSeconds)); "
                + "requesting fresh source without forwarding overlap",
                category: .session)
            freeReplayPackets()
            interruptedReplayHistory = liveReplayGuard.sourceContinuation()
            liveReplayGuard.reset()
            throw InterruptedSourceReplay()
        }
        replayReady.append(contentsOf: replayPending)
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        liveReplayGuard.reset()
        noCutWatchdog?.setReplayChecking(false, at: Date())
        EngineLog.emit(
            "[HLSSegmentProducer] live source overlap unconfirmed: \(reason); "
            + "forwarding all packets to normal discontinuity handling",
            category: .session)
    }

    private func forwardUnverifiedDamagedBoundary() {
        replayReady.append(contentsOf: replayPending)
        replayPending.removeAll(keepingCapacity: true)
        replayPendingBytes = 0
        liveReplayGuard.releaseDamagedBoundary()
        noCutWatchdog?.setReplayChecking(false, at: Date())
        EngineLog.emit("[HLSSegmentProducer] live damaged boundary unconfirmed: forwarding retained packets without resetting source history", category: .session)
    }

    private func freeReplayPackets() {
        for entry in replayPending + replayReady.dropFirst(replayReadyIndex) {
            var packet: UnsafeMutablePointer<AVPacket>? = entry.packet
            trackedPacketFree(&packet)
        }
        replayPending.removeAll()
        replayReady.removeAll()
        replayReadyIndex = 0
        replayPendingBytes = 0
        replayDeferredError = nil
        noCutWatchdog?.setReplayChecking(false, at: Date())
    }

    private func liveReplaySample(packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)
        -> LiveReplaySample? {
        // Only the single-demuxer stream-copy path has one source timeline for both tracks.
        // Side audio and bridged audio have independent clocks; the existing rebase owns them.
        guard isLive, sideAudioDemuxer == nil, audioConfig?.bridge == nil,
              packet.pointee.dts != Int64.min, packet.pointee.pts != Int64.min,
              packet.pointee.size > 0, let bytes = packet.pointee.data else { return nil }
        let stream: LivePacketReplayGuard.Stream
        let timeBaseSeconds: Double
        if origin == .main, packet.pointee.stream_index == videoStreamIndex {
            stream = .video
            timeBaseSeconds = sourceVideoTbSeconds
        } else if let audio = audioConfig,
                  packet.pointee.stream_index == audio.sourceStreamIndex,
                  origin == .main {
            stream = .audio
            timeBaseSeconds = audioDemuxTbSeconds
        } else {
            return nil
        }
        guard timeBaseSeconds > 0 else { return nil }
        let signature = LivePacketReplayGuard.Signature(
            stream: stream, dts: packet.pointee.dts, pts: packet.pointee.pts,
            payload: UnsafeRawBufferPointer(start: bytes, count: Int(packet.pointee.size)))
        return LiveReplaySample(signature: signature,
                                seconds: Double(packet.pointee.dts) * timeBaseSeconds,
                                timeBaseSeconds: timeBaseSeconds)
    }

    /// AE#514: the video stream and the audio stream this session plays, on the source axis the engine
    /// folds AVPlayer's clock back onto (`source_pts - playlistShiftSeconds`).
    private func recordPlayedMedia(_ packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin) {
        guard let ledger = playedMediaLedger, packet.pointee.size > 0 else { return }
        let index = packet.pointee.stream_index
        let track: PlayedMediaLedger.Track
        let timeBase: AVRational
        if origin == .main, index == videoStreamIndex {
            track = .video
            timeBase = sourceVideoTimeBase
        } else if let audio = audioConfig, index == audio.sourceStreamIndex,
                  (origin == .side) == (sideAudioDemuxer != nil) {
            track = .audio
            timeBase = audio.demuxTimeBase
        } else {
            return
        }
        let ticks = packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts
        guard ticks != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return }
        ledger.record(track, pts: Double(ticks) * Double(timeBase.num) / Double(timeBase.den),
                      bytes: Int(packet.pointee.size))
    }

    private func readNextSourcePacketMerged() throws -> (packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin)? {
        // AE#684: `HLSLiveIngestReader.pumpJoinIsSpent` reads "parked on EITHER reader" as "nothing
        // more is cut", which holds only while one thread reads both of them in turn.
        assert(!mergedReadInFlight, "the main and side readers are read by one thread, one at a time")
        mergedReadInFlight = true
        defer { mergedReadInFlight = false }
        guard let side = sideAudioDemuxer else {
            guard let packet = try demuxer.readPacket() else { return nil }
            boundSourceTimestamps(packet)
            return (packet, .main)
        }
        if mergeMainLookahead == nil, !mergeMainEOF {
            mergeMainLookahead = try demuxer.readPacket()
            if let pkt = mergeMainLookahead { boundSourceTimestamps(pkt) } else { mergeMainEOF = true }
        }
        if mergeSideLookahead == nil, !mergeSideEOF {
            mergeSideLookahead = try side.readPacket()
            if let pkt = mergeSideLookahead { boundSourceTimestamps(pkt) }
            if mergeSideLookahead == nil {
                mergeSideEOF = true
            } else if packedSideAudioClock != nil, let pkt = mergeSideLookahead {
                // Stamp at lookahead fill so ordering/gates/rebase/mux all see the same TS-like values.
                stampPackedSideAudio(pkt)
            }
        }
        guard !mergeMainEOF, !mergeSideEOF,
              let main = mergeMainLookahead, let sidePkt = mergeSideLookahead else {
            return nil
        }
        let sideTb = audioConfig?.demuxTimeBase ?? sourceVideoTimeBase
        let sideFirst = DualSourceMergeOrder.sideFirst(
            mainTicks: Self.mergeOrderingTicks(main),
            mainTimeBase: sourceVideoTimeBase,
            sideTicks: Self.mergeOrderingTicks(sidePkt),
            sideTimeBase: sideTb
        )
        if sideFirst {
            mergeSideLookahead = nil
            return (sidePkt, .side)
        }
        mergeMainLookahead = nil
        return (main, .main)
    }

    /// Pump-thread-only: an out-of-range source timestamp was logged once for this producer.
    private var implausibleTimestampLogged = false

    /// Whether a source packet is the audio this producer muxes. Origin-aware: a side demuxer's
    /// stream indices can alias the main one's.
    private func isAudioPacket(_ packet: UnsafeMutablePointer<AVPacket>, origin: PacketOrigin) -> Bool {
        guard let audio = audioConfig, packet.pointee.stream_index == audio.sourceStreamIndex else { return false }
        return origin == (sideAudioDemuxer != nil ? .side : .main)
    }

    private func boundSourceTimestamps(_ packet: UnsafeMutablePointer<AVPacket>) {
        let pts = packet.pointee.pts, dts = packet.pointee.dts
        guard SourceTimestampBounds.sanitize(packet), !implausibleTimestampLogged else { return }
        implausibleTimestampLogged = true
        EngineLog.emit(
            "[HLSSegmentProducer] source packet on stream \(packet.pointee.stream_index) carries an "
            + "out-of-range timestamp (pts=\(pts) dts=\(dts)), treated as unset",
            category: .session
        )
    }

    /// Ordering key: dts when valid, else pts; AV_NOPTS_VALUE (Int64.min) yields immediately (NOPTS repair handles it downstream).
    private static func mergeOrderingTicks(_ packet: UnsafeMutablePointer<AVPacket>) -> Int64 {
        if packet.pointee.dts != Int64.min { return packet.pointee.dts }
        return packet.pointee.pts
    }

    /// #74: whether a pre-video-gate audio packet should be buffered for in-DTS-order replay (instead of
    /// dropped). Buffered while the gate is still waiting, only audio, only under the byte cap, for:
    ///   - head-of-stream (any), and
    ///   - VOD restart/seek.
    /// The wide-interleave failure is the same at both: the matching audio is muxed ahead of the video in
    /// file order, so on a seek it is read during the keyframe scan-forward (gate still closed) and was
    /// dropped, leaving the post-gate restart-target filter to snap the next (~1 s-later) audio onto the
    /// keyframe. Buffering it lets that same filter pick the matching packet from the [target, …] window.
    /// Live restart still drops: its program-boundary re-anchor handles audio separately.
    static func shouldBufferPregateAudio(
        isAudioPkt: Bool,
        audioWaitForVideo: Bool,
        isHeadOfStream: Bool,
        isLive: Bool,
        bufferedBytes: Int,
        packetSize: Int,
        capBytes: Int,
        bufferedCount: Int = 0,
        maxEntries: Int = HLSSegmentProducer.maxPregateAudioBufferEntries
    ) -> Bool {
        guard isAudioPkt, audioWaitForVideo, isHeadOfStream || !isLive else { return false }
        return bufferedCount < maxEntries && bufferedBytes + max(packetSize, 0) <= capBytes
    }

    /// Audit SEG-102: the byte cap charges payload only, and each entry costs an `AVPacket`, a buffer
    /// ref and an array slot besides, so 1-byte laced packets pinned about 1.4 GB under the 8 MiB cap
    /// while the VOD gate waited unbounded. Above what the byte cap admits for AAC or AC-3, and still
    /// about 22 minutes of 20 ms Opus frames.
    static let maxPregateAudioBufferEntries = 65_536

    /// Overwrite packed side-audio timestamps with the synthesized program clock.
    /// KNOWN LIMITATION: free-running clock does NOT follow a live video rebase; A/V sync is lost from that boundary on.
    private func stampPackedSideAudio(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard audioConfig.map({ packet.pointee.stream_index == $0.sourceStreamIndex }) ?? false,
              var clock = packedSideAudioClock else { return }
        let pts = clock.stamp(packetDuration: packet.pointee.duration)
        packedSideAudioClock = clock
        packet.pointee.pts = pts
        packet.pointee.dts = pts
        if packet.pointee.duration <= 0 {
            packet.pointee.duration = clock.fallbackDurationPts
        }
    }

    private func freeMergeLookaheads() {
        trackedPacketFree(&mergeMainLookahead)
        trackedPacketFree(&mergeSideLookahead)
    }

    // MARK: - No-cut watchdog (AE#406)

    /// Arm the watchdog and the timer that reads it. Live only: a sequential source finalizes on
    /// its own plan and has no live edge to fall behind.
    private func startNoCutWatchdog() {
        let watchdog = NoCutStallWatchdog(videoTimeBaseSeconds: sourceVideoTbSeconds)
        // AE#446 round 8: the window used to begin at the first cut, which is stamped when the video
        // gate opens. A source that stops before it delivers one video packet therefore had no
        // deadline at all: nothing to time out, nothing logged, the host never told. Arm the window
        // here, so "the pump has been reading and nothing was ever cut" is judged like any other
        // starved source.
        if let already = lastLiveSegmentFinalizeAt {
            watchdog.noteFinalize(at: already)
        } else {
            watchdog.armForJoin(at: Date())
        }
        noCutWatchdog = watchdog
        let timer = DispatchSource.makeTimerSource(queue: noCutWatchdogQueue)
        timer.schedule(deadline: .now() + Self.noCutWatchdogTickSeconds,
                       repeating: Self.noCutWatchdogTickSeconds,
                       leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.tickNoCutWatchdog(watchdog) }
        noCutWatchdogTimer = timer
        timer.resume()
    }

    private func stopNoCutWatchdog() {
        noCutWatchdogTimer?.cancel()
        noCutWatchdogTimer = nil
    }

    /// One tick, off the read thread. The hold logs and re-arms; the exit logs, latches, and aborts
    /// the read the pump is parked in, because a cancel flag alone cannot reach a thread inside
    /// `av_read_frame` (which is what `HLSVideoEngine`'s own teardown already pairs `stop()` with).
    /// The abort costs nothing this exit was going to keep: `.segmentStall` delegates to a host
    /// retune, which tears the demuxer down.
    private func tickNoCutWatchdog(_ watchdog: NoCutStallWatchdog) {
        guard let decision = watchdog.evaluate(
            now: Date(), servingOutageRunway: outageRunwayProvider?() ?? false) else { return }
        switch decision {
        case .holdForOutageRunway(let w):
            EngineLog.emit(
                "[HLSSegmentProducer] #446 outage hold "
                + "\(w.consecutiveHolds)/\(Self.liveSlowDeliveryMaxHolds): nothing cut for "
                + "\(Int(w.stalledFor))s (rate=\(String(format: "%.1f", w.readRate))pkt/s), and the "
                + "closed window is still feeding the consumer; keeping the source read so the source "
                + "coming back can still be seen",
                category: .session
            )
        case .holdForSlowDelivery(let w):
            EngineLog.emit(
                "[HLSSegmentProducer] slow live delivery hold "
                + "\(w.consecutiveHolds)/\(Self.liveSlowDeliveryMaxHolds): video PTS "
                + "+\(String(format: "%.1f", w.videoPtsAdvanceSeconds))s in \(Int(w.stalledFor))s "
                + "(rate=\(String(format: "%.1f", w.readRate))pkt/s); not a wedge, "
                + "re-arming watchdog instead of retuning",
                category: .session
            )
        case .exitForRetune(let w):
            EngineLog.emit(
                (w.everProduced
                 ? "[HLSSegmentProducer] no-cut stall: no segment finalized for "
                 : "[HLSSegmentProducer] #446 the join never cut anything: nothing produced in ")
                + "\(Int(w.stalledFor))s (packetsRead=\(w.packetsRead), "
                + "sinceFinalize=\(w.progress), "
                + "rate=\(String(format: "%.1f", w.readRate))pkt/s, "
                + "\(w.everProduced ? (w.isWedge ? "cutter wedge" : "source starvation") : "the video gate never opened, so nothing was ever cut to serve")); "
                + "window video=\(w.videoPackets) key=\(w.videoKeyframes) "
                + "audio=\(w.audioPackets) foreign=\(w.foreignPackets)"
                + (w.synthesizedVideoPackets > 0
                    ? " synthesizedTs=\(w.synthesizedVideoPackets)" : "")
                + (w.lastForeignStreamIndex >= 0
                    ? " lastForeignIdx=\(w.lastForeignStreamIndex)" : "")
                + (w.videoPtsAdvanceSeconds >= 0
                    ? " videoPtsAdvance=\(String(format: "%.1f", w.videoPtsAdvanceSeconds))s" : "")
                + (w.consecutiveHolds > 0
                    ? " holdsExhausted=\(w.consecutiveHolds)" : "")
                + "; aborting the source read and exiting for host retune",
                category: .session
            )
            demuxer.markClosed()
            sideAudioDemuxer?.markClosed()
        }
    }

    // MARK: - Pump

    private func runPumpLoop() {
        // AE#286: a (re)started pump always begins latency-critical. Nothing has been produced for
        // this epoch yet, and both of its entry reasons, cold start and a seek landing, have the
        // consumer waiting on the first segment it cuts.
        pumpQoSCurrent = QOS_CLASS_USER_INITIATED
        pumpQoSLastSeg = Int.min
        pumpQoSNextCheckNanos = 0
        pumpEpochHighestStored = Int.min
        pumpUnwinding = false
        pumpRelaxationRate.suspend()
        pthread_set_qos_class_self_np(pumpQoSCurrent, 0)
        EngineLog.emit(
            "[HLSSegmentProducer] pump thread qos=\(QoSClass.name(qos_class_self()))",
            category: .session
        )
        if restartTargetVideoPts > Int64.min {
            bumpRestartCount()
        }
        let pumpStart = DispatchTime.now()
        var packetsRead = 0
        var lastError: Int32 = 0
        var exitReason: PumpExitReason = .eof
        // AE#406: the no-cut window used to live in this loop's locals, which is what tied the
        // decision to the read the loop is parked in. It lives in the watchdog now, and a timer
        // reads it; this loop only reports what it read and observes the verdict.
        if isLive { startNoCutWatchdog() }
        defer { stopNoCutWatchdog() }
        var vodLedgerLastRoutedSeg = Int.min  // #65 ledger: last VOD segment index logged at the routing site
        // The muxed shape's: one file holds both tracks. Demuxed, each track cuts a file of its own.
        cutGate = isLive || audioFollowsVideoCut || audioFile != nil ? nil
            : SegmentCutGate(tracks: audioConfig == nil ? [.video] : [.video, .audio], segment: baseIndex)

        do {
            readLoop: while true {
                stateLock.lock()
                let stopRequested = shouldStop
                stateLock.unlock()
                if stopRequested {
                    exitReason = .stopRequested
                    break readLoop
                }

                if noCutWatchdog?.hasLatchedExit == true {
                    exitReason = .segmentStall
                    break readLoop
                }

                let packet: UnsafeMutablePointer<AVPacket>
                let origin: PacketOrigin
                let replaySample: LiveReplaySample?
                if !audioWaitForVideo, hasPregateAudioToReplay {
                    // #74: once the video gate opens, drain the buffered head-of-stream audio in DTS
                    // order before reading further source packets. These were already counted in
                    // packetsRead when first read, so do not re-count them here.
                    if !pregateAudioReplaySorted {
                        pregateAudioBuffer.sort { Self.mergeOrderingTicks($0.0) < Self.mergeOrderingTicks($1.0) }
                        pregateAudioReplaySorted = true
                    }
                    let entry = pregateAudioBuffer[pregateAudioReplayIndex]
                    pregateAudioReplayIndex += 1
                    if pregateAudioReplayIndex == pregateAudioBuffer.count {
                        pregateAudioBuffer.removeAll()
                        pregateAudioReplayIndex = 0
                    }
                    packet = entry.0
                    origin = entry.1
                    replaySample = nil
                    pregateAudioBufferBytes -= Int(packet.pointee.size)
                } else {
                    guard let read = try readNextSourcePacket() else {
                        break readLoop
                    }
                    // Audit SEG-104: a stop that landed while this read was parked means the session
                    // has already replaced this pump, so what the read returned is not its to act on.
                    if checkShouldStop() {
                        var stale: UnsafeMutablePointer<AVPacket>? = read.packet
                        trackedPacketFree(&stale)
                        exitReason = .stopRequested
                        break readLoop
                    }
                    packet = read.packet
                    origin = read.origin
                    replaySample = read.replaySample
                    packetsRead += 1
                    // Where a packet passes from reading the source to timing it: a stream-copied
                    // audio packet is placed on its frame, in samples and on Apple's axis
                    // (`CopiedAudioTiming`), and from here on the pump holds audio in
                    // `AudioConfig.timeBase`. Here and only here, because the pre-gate replay above
                    // hands back packets that already passed it. Only timestamps the packet arrived
                    // with: ones repaired below are built from the last audio timestamp, already placed.
                    if let timing = audioConfig?.copiedTiming, isAudioPacket(packet, origin: origin) {
                        timing.place(packet)
                    }
                    noCutWatchdog?.notePacketRead()
                }
                var pktPtr: UnsafeMutablePointer<AVPacket>? = packet
                defer { trackedPacketFree(&pktPtr) }

                if let change = sourceChange(packet, origin: origin),
                   let stop = noteProgramChange(change, origin: origin) {
                    exitReason = stop
                    break readLoop
                }

                // Drop matroska BlockAddition side data (HDR10+/DV RPU ~6 KB/entry; metadata lives in bitstream for HEVC).
                // Exception: check AV_PKT_DATA_NEW_EXTRADATA first (live only: program boundary SPS/PPS change detection).
                if isLive, origin == .main, packet.pointee.stream_index == videoStreamIndex {
                    var sdSize: Int = 0
                    if let sd = av_packet_get_side_data(packet, AV_PKT_DATA_NEW_EXTRADATA, &sdSize),
                       sdSize > 0 {
                        // #133 follow-up diag: confirm ONCE whether the demuxer surfaces avcC changes as side data at
                        // all. On MPEG-TS it often does not (the sets are only in-band), which is why the actual
                        // rotation trigger is the keyframe SPS/PPS compare below, not this path.
                        if !loggedFirstVideoNewExtradata {
                            loggedFirstVideoNewExtradata = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] diag: demuxer emitted AV_PKT_DATA_NEW_EXTRADATA (\(sdSize) B) "
                                + "on video PID stream=\(videoStreamIndex)",
                                category: .session
                            )
                        }
                        let newExtra = Data(bytes: sd, count: sdSize)
                        if newExtra != lastSeenVideoExtradata {
                            lastSeenVideoExtradata = newExtra
                            codecParamChangeCount += 1
                            // Force an early discontinuity cut; the versioned-init muxer rotation is driven by the
                            // keyframe SPS/PPS compare below (which also covers the common case where no side data is
                            // emitted at all). This side-data hit just brings the cut forward by up to one keyframe.
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] in-band video extradata change #\(codecParamChangeCount) "
                                + "(\(sdSize) B) signaled via side data; forcing a discontinuity cut "
                                + "(rotation handled by the keyframe parameter-set compare)",
                                category: .session
                            )
                        }
                    }
                }
                // AVC VOD can carry new SPS/PPS even while its file header stays unchanged.
                // Inspect on the producer queue, before the first stale-init sample is written.
                // An active IDR reference is required; unused/repeated sets do not change routing.
                // An overlay session's init is its placeholder's, which no source change touches: its decoder takes
                // the source's parameter sets in band.
                if overlayPlaceholder == nil, packet.pointee.stream_index == videoStreamIndex,
                   case .lengthPrefixed(let size) = a53NALFraming,
                   let data = packet.pointee.data, packet.pointee.size > 0,
                   let mismatch = vodH264Configuration?.observe(
                    UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)), lengthSize: size) {
                    EngineLog.emit("[HLSSegmentProducer] \(mismatch.summary); stopping stale-init VOD epoch=\(epoch)",
                                   category: .session)
                    exitReason = .videoConfigurationChanged(summary: mismatch.summary)
                    break readLoop
                }
                if overlayPlaceholder == nil, packet.pointee.stream_index == videoStreamIndex,
                   let data = packet.pointee.data, packet.pointee.size > 0,
                   let mismatch = vodHEVCConfiguration?.observe(UnsafeBufferPointer(start: data, count: Int(packet.pointee.size))) {
                    EngineLog.emit("[HLSSegmentProducer] \(mismatch.summary); stopping stale-init VOD epoch=\(epoch)",
                                   category: .session)
                    exitReason = .videoConfigurationChanged(summary: mismatch.summary)
                    break readLoop
                }
                av_packet_free_side_data(packet)

                let pktStreamIdx = packet.pointee.stream_index

                // SSAI program switch: the video role moved to a new PID (or back to the open's), and this is
                // the first keyframe it can open on. Until then its packets stay out of the running init.
                if let change = awaitingProgramSwitch, origin == .main, pktStreamIdx == videoStreamIndex {
                    guard let opened = programSwitchOpening(change, packet) else { continue }  // held out
                    awaitingProgramSwitch = nil
                    let returning = change.to == change.logical
                    EngineLog.emit(
                        "[HLSSegmentProducer] SSAI video program switch: stream \(change.from) → \(change.to) "
                        + (returning ? "(back to the programme, its own configuration)"
                            : "(ad/program \(opened.config?.width ?? 0)x\(opened.config?.height ?? 0) on a new video PID)"),
                        category: .session
                    )
                    // Do NOT nil lastVideoSourceDts: timeline rebase (below) needs it to fire on the big backward jump.
                    lastSeenVideoExtradata = nil
                    pendingVideoProgramSwitch = true
                    // An ad creative carries its own DV/color signaling, so the program's overrides are dropped;
                    // the programme coming back keeps them.
                    pendingReinitIsAdCreative = !returning
                    pendingReinitUsesOpenedConfig = returning
                    pendingAdVideoConfig = returning ? nil : opened.config
                    // #133 follow-up: rebaseline for same-PID PS-change detection.
                    activeMuxerVideoExtradata = opened.config?.extradata
                    convertP7Active = returning ? videoConfig.convertP7ToProfile81 : false  // ad creatives are H.264
                    if lastLiveSegmentFinalizeAt != nil { stampLiveSegmentFinalize() }
                    // pendingDiscontinuityFlag / pendingForceCutFlag set by the rebase below.
                }
                if audioRoleUnmuxable, isAudioPacket(packet, origin: origin) {
                    continue
                }

                // NOPTS dts repair: matroska reconstructs dts from ReferenceBlock relations; fails on some B-frames.
                // Forwarding NOPTS causes FFmpeg muxer monotonic check failure (EINVAL, -16046). Using pts as fallback
                // is WRONG for B-frames (pts < dts in decode order). Fix: lastValidDts+1.
                // Origin-aware classification: side audio index can alias main video index in dual-demuxer sessions.
                let isVideoPkt = origin == .main && (pktStreamIdx == videoStreamIndex)
                let isAudioPkt = isAudioPacket(packet, origin: origin)
                // #77: hand the in-band caption-track packet to the observer (read-only). It's a foreign
                // packet (the eia_608/c608 caption stream) and is dropped below, never muxed.
                if pktStreamIdx == closedCaptionStreamIndex, let observe = closedCaptionObserver {
                    observe(packet, closedCaptionStreamTimeBase)
                }
                // Sodalite#32: hand tapped subtitle packets to the session's decode tap, then drop them
                // below as foreign packets. Main demuxer only; side-demuxer indices alias a different space.
                if origin == .main, subtitleTapStreamIndices.contains(pktStreamIdx),
                   let observe = subtitleTapObserver {
                    observe(pktStreamIdx, packet,
                            subtitleTapTimeBases[pktStreamIdx] ?? AVRational(num: 1, den: 1000))
                }
                // #112 rework: hand every embedded subtitle packet to the session's packet store sink,
                // then drop it below as a foreign packet. Main demuxer only, same as the decode tap.
                if origin == .main, subtitlePacketStreamIndices.contains(pktStreamIdx),
                   let sink = subtitlePacketSink {
                    sink(pktStreamIdx, packet,
                         subtitleTapTimeBases[pktStreamIdx] ?? AVRational(num: 1, den: 1000))
                }
                if isVideoPkt, let note = onSourceReadThrough, packet.pointee.dts != Int64.min,
                   sourceVideoTbSeconds > 0 {
                    let seconds = Double(packet.pointee.dts) * sourceVideoTbSeconds
                    if seconds >= lastSourceReadNoted + Self.sourceReadNoteStepSeconds {
                        lastSourceReadNoted = seconds
                        note(seconds)
                    }
                }

                // AE#432: learn each stream's frame stride from its GENUINE timestamps, so a run
                // that arrives without any can be advanced by a plausible interval instead of a
                // single tick. Recorded before the repair below, and never from a repaired value.
                if packet.pointee.dts != Int64.min, isVideoPkt || isAudioPkt {
                    let tb = isVideoPkt ? sourceVideoTbSeconds : audioTbSeconds
                    let cap = tb > 0 ? Int64(Self.maxSynthesizedStrideSeconds / tb) : 0
                    if isVideoPkt {
                        videoSourceStrideTicks = Self.updatedStrideTicks(
                            current: videoSourceStrideTicks, previousDts: lastGenuineVideoSourceDts,
                            dts: packet.pointee.dts, maxStrideTicks: cap)
                        lastGenuineVideoSourceDts = packet.pointee.dts
                    } else {
                        audioSourceStrideTicks = Self.updatedStrideTicks(
                            current: audioSourceStrideTicks, previousDts: lastGenuineAudioSourceDts,
                            dts: packet.pointee.dts, maxStrideTicks: cap)
                        lastGenuineAudioSourceDts = packet.pointee.dts
                    }
                }

                // AE#432: true when this packet reached the loop with no timestamp of its own, so
                // everything downstream that measures time is reading a value the engine invented.
                var timestampsSynthesized = false
                if packet.pointee.dts == Int64.min {
                    let anchor: Int64 = isVideoPkt ? lastVideoSourceDts
                                      : isAudioPkt ? lastAudioSourceDts
                                      : Int64.min
                    if anchor == Int64.min {
                        // No anchor yet. Keyframes (IDR/CRA): pts == dts in decode order, safe to use.
                        // Non-keyframe NOPTS first packet: drop (corrupt seg-0 is worse than a small drop).
                        // Dropping the first IDR would shift DV5's leading SEI and break DV color init (#4).
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        guard isKey, packet.pointee.pts != Int64.min else {
                            continue
                        }
                        packet.pointee.dts = packet.pointee.pts
                    } else if packet.pointee.pts != Int64.min {
                        // dts alone is missing (matroska reconstructs it from ReferenceBlock relations
                        // and fails on some B-frames). pts is the real presentation time and must not
                        // be crossed, so the bump stays minimal.
                        packet.pointee.dts = anchor &+ 1
                    } else {
                        // Neither timestamp survived. One tick per packet is not a presentation time,
                        // it is a frozen clock; advance by this stream's frame interval instead.
                        let strideTb = isVideoPkt ? sourceVideoTbSeconds : audioTbSeconds
                        let stride = Self.repairStrideTicks(
                            packetDuration: packet.pointee.duration,
                            observedStride: isVideoPkt ? videoSourceStrideTicks : audioSourceStrideTicks,
                            fallbackDuration: isVideoPkt ? videoFallbackDurationPts : audioFrameDuration,
                            maxStrideTicks: strideTb > 0 ? Int64(Self.maxSynthesizedStrideSeconds / strideTb) : .max)
                        guard let synthesized = Self.synthesizedDts(anchor: anchor, stride: stride) else {
                            continue
                        }
                        packet.pointee.dts = synthesized
                        packet.pointee.pts = packet.pointee.dts
                        timestampsSynthesized = true
                        noteSynthesizedTimestamp(strideTicks: stride, isVideo: isVideoPkt)
                    }
                }

                // #74: buffer pre-video-gate audio for in-DTS-order replay once the video gate opens
                // (drained at the loop top), instead of dropping it at the audio gate. On wide-interleave
                // sources (audio muxed ahead of video in file order) the old drop discarded the matching
                // audio, leaving a constant ~1 s A/V desync. Bounded by a byte cap; over the cap the
                // original gate drop below resumes. Applies to head-of-stream (any) and VOD restart/seek:
                // on a seek the matching audio is read during the keyframe scan-forward (gate still
                // closed), and buffering it lets the post-gate restart-target filter pick it from the
                // [target, …] window. Live restart keeps the drop (program-boundary re-anchor handles it).
                if Self.shouldBufferPregateAudio(
                    isAudioPkt: isAudioPkt,
                    audioWaitForVideo: audioWaitForVideo,
                    isHeadOfStream: restartTargetVideoPts == Int64.min,
                    isLive: isLive,
                    bufferedBytes: pregateAudioBufferBytes,
                    packetSize: Int(packet.pointee.size),
                    capBytes: Self.maxPregateAudioBufferBytes,
                    bufferedCount: pregateAudioBuffer.count
                ) {
                    pregateAudioBuffer.append((packet, origin))
                    pregateAudioBufferBytes += Int(packet.pointee.size)
                    pktPtr = nil  // ownership moves to the buffer; freed on replay or teardown
                    continue
                } else if isAudioPkt, audioWaitForVideo,
                          restartTargetVideoPts == Int64.min || !isLive,
                          !pregateAudioOverflowLogged {
                    pregateAudioOverflowLogged = true
                    EngineLog.emit(
                        "[HLSSegmentProducer] pre-gate audio buffer hit the "
                        + "\(Self.maxPregateAudioBufferBytes)-byte / \(Self.maxPregateAudioBufferEntries)-entry "
                        + "cap; dropping further leading audio "
                        + "(wide interleave beyond cap)",
                        category: .session
                    )
                }
                // Timeline rebase: a live program boundary (or, #368, a sequential-origin archive
                // chunk seam) resets source dts to a distant value. Per-frame monotonic gate would
                // bump to lastValid+1, exceed reset pts, and DROP every subsequent packet.
                // Correct repair: rebase OUTPUT dts to one frame past last output; live additionally
                // adds #EXT-X-DISCONTINUITY at the seam.
                if rebasesTimelineOnDiscontinuity, isVideoPkt, lastVideoSourceDts != Int64.min,
                   videoShiftPts != Int64.min, packet.pointee.dts != Int64.min {
                    let jumpTicks = SourceTimestampBounds.difference(packet.pointee.dts, lastVideoSourceDts)
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = sourceVideoTbSeconds > 0
                        ? Int64(thresholdSeconds / sourceVideoTbSeconds)
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenVideoSourceDts,
                                          tbSeconds: sourceVideoTbSeconds,
                                          stream: "video") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        liveReplayGuard.reset()
                        let (newShift, continuationDts) = Self.rebasedVideoShift(
                            srcDts: packet.pointee.dts,
                            lastSrcDts: lastVideoSourceDts,
                            oldShift: videoShiftPts,
                            fallbackDurationPts: videoFallbackDurationPts
                        )
                        EngineLog.emit(
                            "[HLSSegmentProducer] video timeline rebase (\(isLive ? "live" : "sequential")): "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastVideoSourceDts) oldShift=\(videoShiftPts) "
                            + "newShift=\(newShift) continuationDts=\(continuationDts)",
                            category: .session
                        )
                        if packedSideAudioClock != nil {
                            // Synth clock free-runs; audio-side inherit will not apply here (timestamps never leap).
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: live video rebase with a "
                                + "packed-audio synth clock active; synthesized side-audio "
                                + "timestamps do NOT follow the jump, A/V sync is lost from "
                                + "this boundary on",
                                category: .session
                            )
                        }
                        videoShiftPts = newShift
                        lastVideoSourceDts = packet.pointee.dts - 1  // dts-1 so monotonic gate is a no-op for this packet
                        // Re-anchor leading-B-frame gate to the new program (otherwise every reset-timeline packet drops).
                        if packet.pointee.pts != Int64.min {
                            firstActualVideoPts = packet.pointee.pts
                        }
                        lastRawVideoPts = Int64.min
                        if isLive {
                            // Live consumers get #EXT-X-DISCONTINUITY plus a forced cut. A sequential
                            // chunk seam (#368) wants neither: the archive is content-continuous, the
                            // output timeline stays continuous after the rebase, and the append
                            // playlist's EXTINF comes from real muxed durations. (Both flags feed
                            // only the live segment bookkeeping.)
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                        }
                        // Hand seam OUTPUT dts (not video shift) to audio: audio derives its own shift from its OWN srcDts,
                        // so differing audio source bases (Pluto amux: audio near 2^33) are absorbed.
                        if let audio = audioConfig {
                            let seamOutAudioTb = av_rescale_q(
                                continuationDts,
                                sourceVideoTimeBase,
                                audio.timeBase
                            )
                            if let prior = lastIndependentAudioRebase,
                               Date().timeIntervalSince(prior.at) < Self.rebasePairingWindowSeconds {
                                // Audio crossed first; re-derive shift from recorded boundary srcDts at next audio packet.
                                pendingAudioShiftOverride = (seamOutAudioTb, prior.boundarySrcDts, Date())
                                lastIndependentAudioRebase = nil
                            } else {
                                pendingAudioInheritSeamOut = (seamOutAudioTb, Date())
                            }
                        }
                        // Deferred handoff: shift is at producer edge; AVPlayer renders buffer+holdback later.
                        let seamOutputSeconds = Double(continuationDts) * sourceVideoTbSeconds
                        onLiveTimelineRebase?(newShift, seamOutputSeconds)
                    }
                }
                if rebasesTimelineOnDiscontinuity, isAudioPkt, lastAudioSourceDts != Int64.min,
                   audioShiftPts != Int64.min, packet.pointee.dts != Int64.min,
                   let audio = audioConfig {
                    let jumpTicks = SourceTimestampBounds.difference(packet.pointee.dts, lastAudioSourceDts)
                    let tb = audio.timeBase
                    let thresholdSeconds = jumpTicks < 0
                        ? Self.discontinuityBackwardThresholdSeconds
                        : Self.discontinuityThresholdSeconds
                    let thresholdTicks = tb.num > 0
                        ? Int64(thresholdSeconds * Double(tb.den) / Double(tb.num))
                        : Int64.max
                    if abs(jumpTicks) >= thresholdTicks {
                        if isSourceReplay(newDts: packet.pointee.dts,
                                          jumpTicks: jumpTicks,
                                          firstSeenDts: firstSeenAudioSourceDts,
                                          tbSeconds: tb.den > 0
                                              ? Double(tb.num) / Double(tb.den) : 0,
                                          stream: "audio") {
                            exitReason = .sourceReplay
                            break readLoop
                        }
                        liveReplayGuard.reset()
                        if pendingAudioShiftOverride != nil {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: discarding stale shift override (new boundary)",
                                category: .session
                            )
                            pendingAudioShiftOverride = nil
                        }
                        let lastOutputDts = SourceTimestampBounds.difference(lastAudioSourceDts, audioShiftPts)
                        // Independent measurement (audio-first boundary): used directly only when no video-derived shift available.
                        let measuredShift = SourceTimestampBounds.difference(
                            packet.pointee.dts, SourceTimestampBounds.sum(lastOutputDts, max(audioFrameDuration, 1)))
                        var newShift = measuredShift
                        var inherited = false
                        if let p = pendingAudioInheritSeamOut,
                           Date().timeIntervalSince(p.at) < Self.rebasePairingWindowSeconds {
                            // Snap audio onto video timeline via seam-derived shift to absorb differing source bases (amux ads).
                            let candidate = Self.seamDerivedAudioShift(
                                audioBoundarySrcDts: packet.pointee.dts,
                                seamOutAudioTb: p.seamOutAudioTb
                            )
                            if let bridge = audio.bridge {
                                // Bridge: free-running encoder restamps continuously; jump its timeline by the residual gap.
                                let driftTicks = SourceTimestampBounds.difference(measuredShift, candidate)
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                inherited = true
                            } else {
                                // Stream-copy: apply candidate verbatim (absolute, not clamped to lastOutputDts).
                                // Delta handoff accumulated A/V drift across SSAI pod creatives (device symptom: seconds late by content return).
                                // An overlap at the seam is audio the muxer already holds: it drops those packets
                                // (`OutputTimestampSanitizer`) rather than squash them, so audio lands on the video's
                                // timeline. More than 0.5 s of it says the waiting video seam is not this boundary's
                                // (audio ran on past it), so audio carries on contiguously for now and the boundary is
                                // kept as an audio-first one: a video rebase inside the pairing window still moves
                                // audio onto the video-derived shift.
                                let firstOutputDts = SourceTimestampBounds.difference(packet.pointee.dts, candidate)
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = audio.timeBase.num > 0
                                    ? Int64(0.5 * Double(audio.timeBase.den)
                                            / Double(audio.timeBase.num))
                                    : Int64.max
                                if overlapTicks > maxOverlapTicks {
                                    newShift = SourceTimestampBounds.difference(SourceTimestampBounds.difference(packet.pointee.dts, lastOutputDts), 1)
                                    lastIndependentAudioRebase = (packet.pointee.dts, Date())
                                    EngineLog.emit(
                                        "[HLSSegmentProducer] audio rebase inherit re-anchored: "
                                        + "candidate=\(candidate) overlap=\(overlapTicks) ticks "
                                        + "exceeds \(maxOverlapTicks) (implausible reset); a later video rebase can still correct it",
                                        category: .session
                                    )
                                } else {
                                    newShift = candidate
                                    inherited = true
                                }
                            }
                        } else {
                            // Audio-first boundary: record srcDts for video rebase to re-derive shift from.
                            lastIndependentAudioRebase = (packet.pointee.dts, Date())
                        }
                        pendingAudioInheritSeamOut = nil
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio timeline rebase (\(isLive ? "live" : "sequential")): "
                            + "jumpTicks=\(jumpTicks) srcDts=\(packet.pointee.dts) "
                            + "lastSrcDts=\(lastAudioSourceDts) oldShift=\(audioShiftPts) "
                            + "newShift=\(newShift) "
                            + "(\(inherited ? "video-derived" : "independent"))",
                            category: .session
                        )
                        audioShiftPts = newShift
                        lastAudioSourceDts = packet.pointee.dts - 1
                    } else if let override_ = pendingAudioShiftOverride {
                        // Video rebase arrived after audio rebased independently; correct toward video-derived value.
                        pendingAudioShiftOverride = nil
                        let derivedShift = Self.seamDerivedAudioShift(
                            audioBoundarySrcDts: override_.boundarySrcDts,
                            seamOutAudioTb: override_.seamOutAudioTb
                        )
                        if Date().timeIntervalSince(override_.at) < Self.rebasePairingWindowSeconds {
                            if let bridge = audio.bridge {
                                // Bridge: residual between applied and video-derived shift becomes an encoder-timeline jump.
                                let driftTicks = SourceTimestampBounds.difference(audioShiftPts, derivedShift)
                                let tbSec = tb.den > 0
                                    ? Double(tb.num) / Double(tb.den) : 0
                                bridge.noteTimelineJump(
                                    deltaSeconds: Double(driftTicks) * tbSec
                                )
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected via bridge jump (drift=\(driftTicks) ticks)",
                                    category: .session
                                )
                            } else {
                                // Stream-copy: apply seam-derived shift; a sub-0.5 s overlap's packets are dropped by
                                // the muxer as audio it already holds (`OutputTimestampSanitizer`). A > 0.5 s overlap
                                // says this video seam is not the audio boundary's: audio carries on contiguously, and
                                // the seam waits for an audio boundary of its own inside the pairing window, which then
                                // takes the video-derived shift.
                                let lastOutputDts = SourceTimestampBounds.difference(lastAudioSourceDts, audioShiftPts)
                                let firstOutputDts = SourceTimestampBounds.difference(override_.boundarySrcDts, derivedShift)
                                let overlapTicks = lastOutputDts - firstOutputDts
                                let maxOverlapTicks = tb.num > 0
                                    ? Int64(0.5 * Double(tb.den) / Double(tb.num))
                                    : Int64.max
                                let applied = overlapTicks > maxOverlapTicks
                                    ? SourceTimestampBounds.difference(SourceTimestampBounds.difference(packet.pointee.dts, lastOutputDts), 1)
                                    : derivedShift
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio rebase corrected to video-derived shift: "
                                    + "old=\(audioShiftPts) new=\(applied)"
                                    + (applied != derivedShift ? " (re-anchored, overlap \(overlapTicks) ticks)" : ""),
                                    category: .session
                                )
                                if applied != derivedShift {
                                    pendingAudioInheritSeamOut = (override_.seamOutAudioTb, override_.at)
                                }
                                audioShiftPts = applied
                                lastAudioSourceDts = packet.pointee.dts - 1
                            }
                        } else {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio rebase: shift override expired unapplied",
                                category: .session
                            )
                        }
                    }
                }
                // Monotonic-dts enforcement (small glitches only, <= 0.5 s): MKV B-frame dts reconstruction can
                // go backward after NOPTS repair. Bump to lastValid+1 if bump does not exceed pts (muxer invariant);
                // otherwise drop the packet (at most one leading B-frame per CRA). Large backward jumps are program
                // boundaries and are left to the timeline rebase; bumping them caused cutter-wedge reloads + A/V drift.
                let monoGlitchVideoTicks = sourceVideoTbSeconds > 0
                    ? Int64(0.5 / sourceVideoTbSeconds) : Int64.max
                if isVideoPkt, lastVideoSourceDts != Int64.min,
                   packet.pointee.dts != Int64.min,
                   packet.pointee.dts <= lastVideoSourceDts,
                   SourceTimestampBounds.difference(lastVideoSourceDts, packet.pointee.dts) <= monoGlitchVideoTicks {
                    let original = packet.pointee.dts
                    let bumped = SourceTimestampBounds.sum(lastVideoSourceDts, 1)
                    let ptsValid = packet.pointee.pts != Int64.min
                    if !ptsValid || bumped <= packet.pointee.pts {
                        packet.pointee.dts = bumped
                        if !loggedFirstDtsBump {
                            loggedFirstDtsBump = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts non-monotonic at source: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts) → bumped to \(bumped)",
                                category: .session
                            )
                        }
                    } else {
                        // Bump would violate dts<=pts. Drop the packet
                        // rather than feed the muxer a bad combo.
                        if !loggedFirstDtsDrop {
                            loggedFirstDtsDrop = true
                            EngineLog.emit(
                                "[HLSSegmentProducer] video dts unrecoverable, dropping: "
                                + "orig=\(original) lastValid=\(lastVideoSourceDts) "
                                + "pts=\(packet.pointee.pts)",
                                category: .session
                            )
                        }
                        continue
                    }
                }
                // Audio is not bumped here. A repeated audio timestamp is the source's own rounding, not a
                // glitch: Matroska stores 1 ms ticks, so TrueHD's 0.83 ms access units read 0, 1, 2, 3, 3,
                // 4 ms. Bumping the repeat to "last plus one" and carrying the bumped value forward moved
                // every later timestamp a tick per unit (1.2x real time) until the 0.5 s guard gave up,
                // and everything reading the audio's time from here on (the gate, the restart target,
                // the bridge's frame clock through FFmpeg's best-effort timestamp) read that instead.
                // The muxer keeps output timestamps strictly increasing itself (`OutputTimestampSanitizer`,
                // in its own 1/48000 ticks, where a repeat costs one sample and cannot cascade), and a
                // bridge stamps its own output.
                if isVideoPkt {
                    noCutWatchdog?.noteVideoPacket(
                        pts: packet.pointee.pts,
                        isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                        synthesizedTimestamp: timestampsSynthesized
                    )
                    if firstSeenVideoSourceDts == Int64.min {
                        firstSeenVideoSourceDts = packet.pointee.dts
                    }
                    lastVideoSourceDts = packet.pointee.dts
                } else if isAudioPkt {
                    noCutWatchdog?.noteAudioPacket()
                    if firstSeenAudioSourceDts == Int64.min {
                        firstSeenAudioSourceDts = packet.pointee.dts
                    }
                    lastAudioSourceDts = packet.pointee.dts
                }

                if !isVideoPkt && !isAudioPkt {
                    noCutWatchdog?.noteForeignPacket(streamIndex: pktStreamIdx)
                    continue
                }

                // Scan-forward gate: wait for AV_PKT_FLAG_KEY (matroska seek can land 100+ ms early and
                // SimpleBlock keyframe bit can be off for an IDR in the Cues index). Initial-start also
                // waits: first packet is not always a sync sample (Bluey MKV: dts=0 pts=33, no key flag,
                // seg-0 rejected by AVPlayer with -12860 indefinite stall). The target is a plan-boundary
                // PTS, so the packet is judged by presentation time (AE#169 round 3): comparing DTS
                // dropped the anchor IRAP itself under B-frame reorder, and at the file tail no later
                // IRAP exists to rescue the miss, starving the unbounded VOD gate to EOF.
                if isVideoPkt {
                    if firstActualVideoDts == Int64.min {
                        let isKey = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                        let targetSatisfied = Self.videoGateTargetSatisfied(
                            pts: packet.pointee.pts, dts: packet.pointee.dts,
                            targetPts: effectiveGateTargetPts)
                        // #133: on a live H.264 Annex-B mid-stream join, opening on a bare keyframe flag is not
                        // enough. A join packet must carry a decodable access unit (in-band SPS+PPS and an
                        // IDR or immediate intra recovery point, AE#627); otherwise the decoder renders references
                        // it never received (green frames) or, when the probe joined before any SPS and left codecpar at 0x0, the first muxer alloc gets 0x0
                        // dimensions and avformat_write_header fails -22, dead-ending the channel. The bounded
                        // live timeout below covers the miss (keyframeStarvation -> reopen), unlike muxerFailed.
                        let joinConfig = (liveH264AnnexBJoin && isKey && targetSatisfied)
                            ? extractJoinVideoConfig(packet) : nil
                        let joinGateSatisfied = !liveH264AnnexBJoin || joinConfig != nil
                        guard isKey, targetSatisfied, joinGateSatisfied else {
                            if isKey {
                                let ts = packet.pointee.pts != Int64.min
                                    ? packet.pointee.pts : packet.pointee.dts
                                if ts != Int64.min { notePregateDroppedKeyframe(pts: ts) }
                                pregateKeyDropCount += 1
                            }
                            // AE#408: the scan has reached ground already known to carry no sync
                            // sample (the boundary itself on the first pass, the abandoned aim after
                            // that) on a packet that cannot open a segment, so nothing between the
                            // current aim and the boundary can cover it. Re-aim now rather than read
                            // the whole drought to find that out. The comparison is never against the
                            // current aim: an aim is a probe position and claims nothing, so a non-key
                            // packet sitting on one is not evidence.
                            if !isKey, sourceVideoTbSeconds > 0,
                               Self.boundaryProvenNotRandomAccess(
                                   droppedPts: packet.pointee.pts != Int64.min
                                       ? packet.pointee.pts : packet.pointee.dts,
                                   targetPts: gateProvenEmptyFromPts,
                                   sawKeyframeBeforeTarget: lastPregateDroppedKeyframePts != Int64.min,
                                   graceTicks: Int64(Self.boundaryProbeGraceSeconds / sourceVideoTbSeconds)),
                               reanchorGateBelowBoundary(reason: "no sync sample covers it") {
                                continue
                            }
                            pregateVideoDropCount += 1
                            if pregateVideoDropCount == 1 {
                                pregateWaitStart = Date()
                            }
                            if pregateVideoDropCount - lastPregateVideoLog >= Self.pregateLogInterval {
                                lastPregateVideoLog = pregateVideoDropCount
                                let awaiting = (isKey && targetSatisfied && liveH264AnnexBJoin)
                                    ? "SPS/PPS + entry-point access unit" : "video keyframe"
                                EngineLog.emit(
                                    "[HLSSegmentProducer] still waiting for \(awaiting): "
                                    + "dropped=\(pregateVideoDropCount) (keyframes=\(pregateKeyDropCount)) "
                                    + "lastDts=\(packet.pointee.dts) lastPts=\(packet.pointee.pts) "
                                    + "isKey=\(isKey) "
                                    + "target=\(effectiveGateTargetPts)"
                                    + (effectiveGateTargetPts != restartTargetVideoPts
                                        ? " (re-aimed from boundary \(restartTargetVideoPts))" : "")
                                    + " baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            // Live bounded wait: mis-flagged TS would starve forever. VOD keeps unbounded wait.
                            if isLive, let started = pregateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveKeyframeGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live keyframe gate timed out after "
                                    + "\(Int(Self.liveKeyframeGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateVideoDropCount), keyframes=\(pregateKeyDropCount)); "
                                    + "exiting pump for reopen",
                                    category: .session
                                )
                                packetCounterLock.lock()
                                _starvedVideoDrops = pregateVideoDropCount
                                packetCounterLock.unlock()
                                exitReason = .keyframeStarvation
                                break readLoop
                            }
                            continue
                        }
                        // AE#408: this keyframe opens a segment whose playlist entry starts at the
                        // boundary. Opening it well past that makes the segment carry content from the
                        // far side of the gap under the boundary's own name, and every seek into it
                        // lands that far off. Go back for a sync sample that covers the start instead.
                        if sourceVideoTbSeconds > 0,
                           Self.shouldReanchorBeforeOpening(
                               keyframePts: packet.pointee.pts != Int64.min
                                   ? packet.pointee.pts : packet.pointee.dts,
                               boundaryPts: restartTargetVideoPts,
                               toleranceTicks: Self.boundaryOpenToleranceTicks(
                                   reorderFrames: videoConfig.codecpar.pointee.video_delay,
                                   frameDurationPts: videoFallbackDurationPts,
                                   floorTicks: Int64(Self.boundaryOpenToleranceSeconds / sourceVideoTbSeconds),
                                   planAxis: planBoundaryAxis),
                               attemptsUsed: gateBackoffAttempts,
                               maxAttempts: Self.gateBackoffStepsSeconds.count),
                           reanchorGateBelowBoundary(reason: "its first sync sample presents "
                               + "\(String(format: "%.2f", Double((packet.pointee.pts != Int64.min ? packet.pointee.pts : packet.pointee.dts) &- restartTargetVideoPts) * sourceVideoTbSeconds))s later") {
                            continue
                        }
                        // #133: probe joined before any SPS (codecpar 0x0). Backfill the first muxer's video
                        // config from the gating IDR's in-band SPS/PPS so avformat_write_header gets real
                        // dimensions instead of failing -22.
                        if let joinConfig,
                           videoConfig.codecpar.pointee.width == 0 || videoConfig.codecpar.pointee.height == 0 {
                            pendingJoinVideoConfig = joinConfig
                            EngineLog.emit(
                                "[HLSSegmentProducer] live join: reconstructed video config "
                                + "\(joinConfig.width)x\(joinConfig.height) from in-band SPS/PPS "
                                + "(probe codecpar was 0x0)",
                                category: .session
                            )
                        }
                        firstActualVideoDts = packet.pointee.dts
                        markVideoGateOpened()
                        firstActualVideoPts = packet.pointee.pts != Int64.min
                            ? packet.pointee.pts
                            : packet.pointee.dts
                        if isLive, lastLiveSegmentFinalizeAt == nil {
                            stampLiveSegmentFinalize()
                        }
                        let firstTfdtPts = Self.firstItemTfdtPts(
                            actualFirstDts: firstActualVideoDts,
                            desiredTfdtPts: desiredFirstVideoTfdtPts,
                            planAnchorPts: planAnchorVideoPts,
                            isLive: isLive)
                        videoShiftPts = SourceTimestampBounds.difference(firstActualVideoDts, firstTfdtPts)
                        if audioWaitForVideo, let audio = audioConfig {
                            // VOD audio starts at the run's first plan boundary, where routing puts the
                            // start of its first segment (`AudioRunPlan`), so
                            // that segment opens on the audio continuous playback put in it. Not the
                            // keyframe's decode time: on a presentation-axis plan that sits a composition
                            // offset before the boundary. Live has no plan and starts at the keyframe.
                            // Rescale into SOURCE audio TB (not encoder TB): a bridge exposes this mismatch;
                            // using inputTimeBase landed the target 48x too far for bridged DTS sources.
                            restartTargetAudioDts = av_rescale_q(
                                isLive ? firstActualVideoDts : (segmentBoundaries.first ?? firstActualVideoDts),
                                sourceVideoTimeBase,
                                audio.timeBase
                            )
                            audioWaitForVideo = false
                        }
                        EngineLog.emit(
                            "[HLSSegmentProducer] video gate open: "
                            + "actual=\(firstActualVideoDts) "
                            + "anchorPts=\(firstActualVideoPts) "
                            + "target=\(restartTargetVideoPts) "
                            + (effectiveGateTargetPts != restartTargetVideoPts
                                ? "reaimedTo=\(effectiveGateTargetPts) " : "")
                            + "desired=\(desiredFirstVideoTfdtPts) "
                            + (firstTfdtPts != desiredFirstVideoTfdtPts
                                ? "publishedAt=\(firstTfdtPts) " : "")
                            + "shift=\(videoShiftPts) "
                            + (Self.presentedShiftPts(actualFirstPts: firstActualVideoPts,
                                                      desiredTfdtPts: desiredFirstVideoTfdtPts) != videoShiftPts
                                ? "presentedShift=\(Self.presentedShiftPts(actualFirstPts: firstActualVideoPts, desiredTfdtPts: desiredFirstVideoTfdtPts)) " : "")
                            // AE#418 round 5: the composition needs this, so the line that publishes
                            // the shift names it too. Zero on a source without frame reordering.
                            + (Self.presentationLeadPts(actualFirstPts: firstActualVideoPts,
                                                        actualFirstDts: firstActualVideoDts) != 0
                                ? "lead=\(Self.presentationLeadPts(actualFirstPts: firstActualVideoPts, actualFirstDts: firstActualVideoDts)) " : "")
                            // #133 follow-up diag: PID + reconstruct state per epoch, so retest logs separate a
                            // same-PID mid-stream parameter-set change from a reopen storm (each reopen is a fresh
                            // gate-open here; a same-PID change is NOT, it stays in one epoch and rotates in place).
                            + "videoPID=\(videoStreamIndex) reconstructed=\(pendingJoinVideoConfig != nil)",
                            category: .session
                        )
                        // AE#418: what the HOST folds is not the muxer's shift. Measured with
                        // `play --picture-probe` against a picture that states its own source time:
                        // AVPlayer presents a segment at the position the PLAYLIST gives it, not at
                        // the tfdt the segment carries, so a gate that opened below its boundary has
                        // its content presented that far late whatever it wrote. The muxer's shift
                        // stays what it is (it is the source-to-item offset for the bytes), and the
                        // axis the clock folds with is measured against the ADVERTISED start, which
                        // is where AVPlayer will put the frame. The two coincide on a pinned (late)
                        // gate, which is why publishing the mux shift held until the early-opening
                        // gate landed in 6.40.0. Same reason the seam activates at the advertised
                        // start: the stretch below it still belongs to the previous epoch on screen.
                        onVideoShiftKnown?(
                            Self.presentedShiftPts(
                                actualFirstPts: firstActualVideoPts,
                                desiredTfdtPts: desiredFirstVideoTfdtPts),
                            desiredFirstVideoTfdtPts,
                            videoShiftPts)
                        // #133 follow-up: the gating IDR's in-band SPS/PPS back this epoch's muxer avcC. Establish
                        // the baseline so a later same-PID parameter-set change (encoder restart / regional splice)
                        // is detected against it. joinConfig is non-nil only in the liveH264AnnexBJoin scope.
                        if let joinConfig {
                            activeMuxerVideoExtradata = joinConfig.extradata
                        }
                    } else {
                        // Drop HEVC RASL leading B-frames: open-GOP CRA emits B-frames with pts before CRA.pts
                        // that reference pre-CRA frames not in our stream (AVPlayer stalls in waitingToPlay forever).
                        if firstActualVideoPts != Int64.min,
                           packet.pointee.pts != Int64.min,
                           packet.pointee.pts < firstActualVideoPts {
                            if !loggedFirstLeadingDrop {
                                loggedFirstLeadingDrop = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] drop pre-keyframe "
                                    + "leading B-frame: pts=\(packet.pointee.pts) "
                                    + "dts=\(packet.pointee.dts) "
                                    + "anchor=\(firstActualVideoPts) "
                                    + "(open-GOP RASL)",
                                    category: .session
                                )
                            }
                            continue
                        }
                        // #133 follow-up: gate is open; watch mid-stream keyframes for an in-band SPS/PPS change on
                        // the SAME video PID. The fMP4 avcC froze at write_header, so without a versioned re-init the
                        // new slices decode against a stale avcC (recurring green frames + "non-existing PPS" bursts,
                        // exactly the UK-DVB-via-Xtream report). Route it through the same EXT-X-MAP rotation SSAI uses,
                        // parsing the sets ourselves so it fires whether or not the demuxer emits NEW_EXTRADATA.
                        // HEVC has no join config: its first keyframe after the gate is the baseline.
                        if liveAnnexBReinit, activeMuxerVideoExtradata == nil,
                           (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                           let first = extractAdVideoConfig(packet, codec: a53CodecKind ?? .h264) {
                            activeMuxerVideoExtradata = first.extradata
                        } else if liveAnnexBReinit,
                           (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0,
                           !pendingVideoProgramSwitch,
                           let incoming = extractAdVideoConfig(packet, codec: a53CodecKind ?? .h264),
                           Self.parameterSetsDiverged(active: activeMuxerVideoExtradata, incoming: incoming.extradata) {
                            samePIDReinitCount += 1
                            EngineLog.emit(
                                "[HLSSegmentProducer] same-PID in-band parameter-set change #\(samePIDReinitCount) "
                                + "on video PID stream=\(videoStreamIndex) "
                                + "(\(incoming.width)x\(incoming.height), "
                                + "\(activeMuxerVideoExtradata?.count ?? 0)->\(incoming.extradata.count) B SPS/PPS); "
                                + "forcing a discontinuity cut + versioned init so the new avcC matches the slices",
                                category: .session
                            )
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            pendingVideoProgramSwitch = true
                            pendingReinitIsAdCreative = false
                            pendingAdVideoConfig = incoming
                            activeMuxerVideoExtradata = incoming.extradata
                        }
                    }
                }
                if isAudioPkt {
                    if audioWaitForVideo {
                        pregateAudioDropCount += 1
                        if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                            lastPregateAudioLog = pregateAudioDropCount
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio waiting for video gate: "
                                + "dropped=\(pregateAudioDropCount) "
                                + "lastDts=\(packet.pointee.dts) baseIndex=\(baseIndex)",
                                category: .session
                            )
                        }
                        continue
                    }
                    if restartTargetAudioDts != Int64.min && firstActualAudioDts == Int64.min {
                        // The routing rule (`playedAudioSegmentIndex`): a packet belongs once any of its
                        // audio plays at or after the target, the host's audio delay in, so the run's first
                        // segment opens on the packet that straddles its start, as continuous playback's
                        // does. For a bridge it is also what the decoder needs: dropping a leading packet
                        // (Opus's, which carries the pre-skip) made it skip the next packet's real audio. A
                        // bridge that makes each segment in a run of its own reads its pre-roll ahead of
                        // that. A packet with no stated duration is known only to start where it says.
                        let target = restartTargetAudioDts &- audioDelaySourceTicks &- audioPreRollTicks
                        let meetsTarget = packet.pointee.dts != Int64.min
                            && (packet.pointee.duration > 0
                                ? SourceTimestampBounds.sum(packet.pointee.dts, packet.pointee.duration) > target
                                : packet.pointee.dts >= target)
                        // Live escape: backward PCR wrap between video gate-open and first audio packet strands the target
                        // in the old clock domain (permanently silent). Timeout + accept; VOD keeps unbounded wait.
                        var escape = false
                        if isLive, !meetsTarget {
                            if audioGateWaitStart == nil { audioGateWaitStart = Date() }
                            if let started = audioGateWaitStart,
                               Date().timeIntervalSince(started) > Self.liveAudioGateTimeoutSeconds {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live audio gate timed out after "
                                    + "\(Int(Self.liveAudioGateTimeoutSeconds))s "
                                    + "(dropped=\(pregateAudioDropCount) dts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts)); accepting current packet",
                                    category: .session
                                )
                                escape = packet.pointee.dts != Int64.min
                            }
                        }
                        guard meetsTarget || escape else {
                            pregateAudioDropCount += 1
                            if pregateAudioDropCount - lastPregateAudioLog >= Self.pregateLogInterval {
                                lastPregateAudioLog = pregateAudioDropCount
                                EngineLog.emit(
                                    "[HLSSegmentProducer] audio waiting for target dts: "
                                    + "dropped=\(pregateAudioDropCount) "
                                    + "lastDts=\(packet.pointee.dts) "
                                    + "target=\(restartTargetAudioDts) baseIndex=\(baseIndex)",
                                    category: .session
                                )
                            }
                            continue
                        }
                    }
                    if firstActualAudioDts == Int64.min {
                        firstActualAudioDts = packet.pointee.dts
                        let audioTb = audioConfig?.timeBase ?? AVRational(num: 1, den: 1000)
                        if restartTargetVideoPts == Int64.min {
                            // Head-of-stream: inherit video's shift so the audio-minus-video offset survives (Cars: EAC3 +256 ms).
                            // Snapping to desired=0 would pull the entire audio track ahead of picture.
                            audioShiftPts = av_rescale_q(
                                videoShiftPts,
                                sourceVideoTimeBase,
                                audioTb
                            )
                            pendingAudioInheritSeamOut = nil
                        } else {
                            // Restart: inherit the session mapping exactly like head-of-stream. A snap onto the
                            // video seam (the first audio dts against a desired audio tfdt) would compensate for a
                            // fresh muxer zero-basing each restart epoch; with tfdt continuity (frag_discont) the
                            // snap itself became the divergence: it moved audio off the source frame grid by up to
                            // one frame per epoch and skewed the shift fold-back in audio routing (`AudioRunPlan`) by
                            // the same amount, so a restarted segment carried a different audio timeline (and a
                            // different boundary frame) than continuous production.
                            audioShiftPts = av_rescale_q(
                                videoShiftPts,
                                sourceVideoTimeBase,
                                audioTb
                            )
                        }
                        // The bridge's grid starts where the stream does, on the axis it is fed on.
                        audioConfig?.bridge?.setSourceStart(audioConfig?.sourceStart.map { $0 - audioShiftPts })
                        if let audio = audioConfig, !isLive, !audioFollowsVideoCut {
                            audio.bridge?.setRunPlan(audioRunPlan(audio))
                        }
                        let gapInAudioTb: Int64
                        if restartTargetVideoPts == Int64.min {
                            gapInAudioTb = 0
                        } else {
                            gapInAudioTb = restartTargetAudioDts == Int64.min
                                ? 0
                                : SourceTimestampBounds.difference(firstActualAudioDts,
                                                                  restartTargetAudioDts &- audioDelaySourceTicks &- audioPreRollTicks)
                        }
                        let gapMs = audioTb.den > 0
                            ? Double(gapInAudioTb) * Double(audioTb.num) * 1000.0 / Double(audioTb.den)
                            : 0
                        self.setLastAVGapMs(gapMs)
                        EngineLog.emit(
                            "[HLSSegmentProducer] audio gate open: "
                            + "actual=\(firstActualAudioDts) "
                            + "target=\(restartTargetAudioDts) "
                            + "shift=\(audioShiftPts) "
                            + "gapMs=\(String(format: "%.1f", gapMs))",
                            category: .session
                        )
                        if abs(gapMs) > 50 {
                            EngineLog.emit(
                                "[HLSSegmentProducer] WARNING: audio gate "
                                + "opened \(String(format: "%.1f", gapMs)) ms "
                                + "after video gate (baseIndex=\(baseIndex)). "
                                + "Audio content for seg-\(baseIndex)'s first "
                                + "video frame is offset from the video by "
                                + "this much, expect A/V drift to be audible.",
                                category: .session
                            )
                        }
                    }
                }

                // Live PTS discontinuity detection on raw (pre-shift) pts. Above NOPTS-repair (+1 tick) and frame-interval scales.
                if isVideoPkt, isLive, firstActualVideoDts != Int64.min,
                   packet.pointee.pts != Int64.min {
                    let rawPts = packet.pointee.pts
                    if lastRawVideoPts != Int64.min {
                        let deltaTicks = SourceTimestampBounds.difference(rawPts, lastRawVideoPts)
                        let deltaSeconds = Double(deltaTicks) * sourceVideoTbSeconds
                        if abs(deltaSeconds) >= Self.discontinuityThresholdSeconds {
                            pendingDiscontinuityFlag = true
                            pendingForceCutFlag = true
                            if !loggedFirstDiscontinuity {
                                loggedFirstDiscontinuity = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] live PTS discontinuity detected: "
                                    + "prevRawPts=\(lastRawVideoPts) rawPts=\(rawPts) "
                                    + "delta=\(String(format: "%.2f", deltaSeconds))s "
                                    + "(threshold=\(String(format: "%.1f", Self.discontinuityThresholdSeconds))s); "
                                    + "next segment will carry #EXT-X-DISCONTINUITY",
                                    category: .session
                                )
                            }
                        }
                    }
                    lastRawVideoPts = rawPts
                }

                let activeShift: Int64 = isVideoPkt ? videoShiftPts : audioShiftPts
                if activeShift != Int64.min && activeShift != 0 {
                    if packet.pointee.dts != Int64.min {
                        packet.pointee.dts = SourceTimestampBounds.difference(packet.pointee.dts, activeShift)
                    }
                    if packet.pointee.pts != Int64.min {
                        packet.pointee.pts = SourceTimestampBounds.difference(packet.pointee.pts, activeShift)
                    }
                }


                // Only packets that passed the live gates and output timestamp checks enter the
                // history. Their original source signature was captured before timestamp repair.
                if let sample = replaySample {
                    liveReplayGuard.record(sample.signature, sourceSeconds: sample.seconds)
                }

                if isVideoPkt {
                    if !loggedFirstVideoPktInfo {
                        loggedFirstVideoPktInfo = true
                        EngineLog.emit(
                            "[HLSSegmentProducer] first video pkt: "
                            + "dts=\(packet.pointee.dts) pts=\(packet.pointee.pts) "
                            + "duration=\(packet.pointee.duration) size=\(packet.pointee.size) "
                            + "(fallback=\(videoFallbackDurationPts) in srcVideoTb)",
                            category: .session
                        )
                    }
                    let opensOverlayRun = !overlayRunOpened
                    overlayRunOpened = true
                    let served = servedVideoTime(packet)
                    if let overlayDecodeTap {
                        if let served {
                            overlayDecodeTap.keep(packet, opensRun: opensOverlayRun, served: served,
                                                  shiftSeconds: Double(videoShiftPts == Int64.min ? 0 : videoShiftPts) * sourceVideoTbSeconds)
                        }
                        observeOverlaySourceCaptions(packet)
                    }
                    if let overlayPlaceholder, !overlayPlaceholder.substitute(packet) {
                        exitReason = .muxerFailed
                        break readLoop
                    }
                    if convertP7Active {
                        // Probe the enhancement-layer type once (latching on the first RPU seen, before
                        // conversion strips it); a FEL source loses refinement in the P8.1 conversion.
                        if !loggedEnhancementLayerType,
                           let elType = DoviRpuConverter.enhancementLayerType(
                               packet, framing: a53NALFraming) {
                            loggedEnhancementLayerType = true
                            if elType == "FEL" {
                                EngineLog.emit(
                                    "[HLSSegmentProducer] DV P7 source carries a Full Enhancement Layer (FEL); "
                                    + "it is discarded in the P8.1 conversion, so some highlight/detail refinement "
                                    + "is lost versus a native P7 player unless LoadOptions.felOverlay composes it over AVPlayer",
                                    category: .session
                                )
                            }
                        }
                        let converted: Bool
                        #if DualLayerDolbyVision
                        if let felTap {
                            converted = felTap.rewrite(packet, opensRun: opensOverlayRun, served: served,
                                                       framing: a53NALFraming,
                                                       chromaLocation: UInt32(max(0, videoConfig.codecpar.pointee.chroma_location.rawValue)))
                        } else {
                            converted = DoviRpuConverter.convertPacketToProfile81(packet, framing: a53NALFraming)
                        }
                        #else
                        converted = DoviRpuConverter.convertPacketToProfile81(packet, framing: a53NALFraming)
                        #endif
                        if !converted {
                            if !loggedP7ConversionFailure {
                                loggedP7ConversionFailure = true
                                EngineLog.emit(
                                    "[HLSSegmentProducer] DV P7->8.1 conversion failed for a packet; dropped the RPU, "
                                    + "degrading affected frames to the HDR10 base",
                                    category: .session
                                )
                            }
                        }
                    }
                    // Live: keyframe cutter uses shifted pts. VOD: unused; routing uses prev.dts at look-behind site.
                    let isVideoKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
                    // #731: a bridge that encodes on its own queue hands packets back a feed or more
                    // late. Where audio follows the video cutter (sequential origins) they are routed
                    // by the cutter and the open muxer (the `max` in `ensureMuxer`), so settle it
                    // before this packet advances the cutter or the look-behind write below cuts.
                    // Routed by time, the cut gate waits for them instead (muxed), or the audio cuts a file
                    // of its own on its own routing (demuxed).
                    if !isLive, audioFollowsVideoCut, let audio = audioConfig, let bridge = audio.bridge {
                        let advancesCutter = audioFollowsVideoCut && isVideoKeyframe
                            && vodCutter.peekIndex(
                                pts: planBoundaryAxis.timestamp(dts: packet.pointee.dts, pts: packet.pointee.pts),
                                isKeyframe: true) != vodCutter.current
                        let lookBehindCuts = pendingVideoPkt != nil && videoFile.muxer != nil
                            && pendingVideoSegIndex > videoFile.segmentIndex
                        if advancesCutter || lookBehindCuts, !writeBridgedAudio(bridge.settle(), audio: audio) {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    // VOD now cuts keyframe-gated like live (and like FFmpeg's hls muxer): a segment opens
                    // at the IRAP that reaches its plan boundary, so the IRAP is the segment's first sample
                    // and its open-GOP RASL leading pictures stay with it (#92). Routing by DTS against PTS
                    // boundaries used to drop the IRAP (dts < pts) into the previous segment.
                    // #358 / AE#561: the VOD plan's boundaries ARE the container's index entries, and
                    // what an entry's timestamp means depends on the container: decode times from a
                    // mov/mp4 sample table, presentation times from a Matroska Cue. The gate compares
                    // on the plan's own axis (`PlanBoundaryAxis`), because either mismatch costs a
                    // segment its IRAP: a presentation packet against decode boundaries let a keyframe
                    // reach boundaries beyond its own (#358), a decode packet against presentation
                    // boundaries let no keyframe reach its own at all (AE#561). Keyframe gating itself
                    // is unchanged, so #92 holds: the IRAP is the segment's first sample and its
                    // open-GOP RASL pictures still follow it in decode order.
                    let thisVideoSeg = isLive
                        ? liveVideoSegmentIndex(pts: packet.pointee.pts, isKeyframe: isVideoKeyframe)
                        : vodCutter.index(pts: planBoundaryAxis.timestamp(dts: packet.pointee.dts,
                                                                          pts: packet.pointee.pts),
                                          isKeyframe: isVideoKeyframe)
                    let nowNanos = DispatchTime.now().uptimeNanoseconds
                    if thisVideoSeg != pumpQoSLastSeg || nowNanos >= pumpQoSNextCheckNanos {
                        pumpQoSLastSeg = thisVideoSeg
                        pumpQoSNextCheckNanos = nowNanos + 1_000_000_000
                        measurePumpRelaxationRate(nowNanos: nowNanos, dts: packet.pointee.dts)
                        retunePumpQoS()
                    }
                    if let prev = pendingVideoPkt {
                        let prevSeg = pendingVideoSegIndex
                        // Newest muxed frame time, recorded per PACKET. Recording it at the ledger
                        // site below (which only fires when a segment opens) left it equal to the
                        // last segment's start, so the EOF tail EXTINF's "real span" branch could
                        // never be true and every archive's final segment was advertised at the
                        // full cut target no matter how little media it held.
                        if onSequentialSegmentFinalized != nil, prev.pointee.dts != Int64.min,
                           sourceVideoTbSeconds > 0 {
                            lastMuxedItemAxisSeconds = Double(prev.pointee.dts) * sourceVideoTbSeconds
                        }
                        // #65 ledger: at each VOD segment open, map the segment's item-axis start (what AVPlayer and
                        // currentTime see) to the TRUE source content muxed there. drift = actual source - planned
                        // source for this index; non-zero means the presented frame leads the clock (Root B positively
                        // confirmed, with the exact idx/epoch). Zero across the whole burst means there is no
                        // content-vs-clock offset and the reported 6 s is the stall/frozen-clock artifact instead.
                        if !isLive, prevSeg != vodLedgerLastRoutedSeg, prev.pointee.dts != Int64.min,
                           sourceVideoTbSeconds > 0 {
                            vodLedgerLastRoutedSeg = prevSeg
                            let shiftTicks = videoShiftPts == Int64.min ? 0 : videoShiftPts
                            let outDts = prev.pointee.dts
                            if onSequentialSegmentFinalized != nil {
                                let startSec = Double(outDts) * sourceVideoTbSeconds
                                vodSegmentStartByIndex[prevSeg] = startSec
                                // The previous segment's REAL duration is final the moment this
                                // one's start is known; the report pairs with its capture. Plan
                                // indices a long GOP skipped report as zero-duration holes.
                                if lastSeqLedgerSeg != Int.min, lastSeqLedgerSeg < prevSeg,
                                   let priorStart = vodSegmentStartByIndex[lastSeqLedgerSeg],
                                   startSec > priorStart {
                                    vodSegmentStartByIndex.removeValue(forKey: lastSeqLedgerSeg)
                                    noteSequentialDurationKnown(index: lastSeqLedgerSeg,
                                                                duration: startSec - priorStart)
                                    for hole in (lastSeqLedgerSeg + 1)..<prevSeg {
                                        emitSequentialReport(index: hole, duration: 0)
                                    }
                                }
                                lastSeqLedgerSeg = prevSeg
                            }
                            let srcDts = outDts &+ shiftTicks
                            let localI = prevSeg - baseIndex
                            let planSrc: Int64? = (localI >= 0 && localI < segmentBoundaries.count)
                                ? segmentBoundaries[localI] : nil
                            let tb = sourceVideoTbSeconds
                            EngineLog.emit(
                                "[HLSSegmentProducer] #65 ledger seg-\(prevSeg) base=\(baseIndex) "
                                + "itemAxis=\(String(format: "%.3f", Double(outDts) * tb))s "
                                + "sourceStart=\(String(format: "%.3f", Double(srcDts) * tb))s "
                                + (planSrc != nil
                                    ? "planSource=\(String(format: "%.3f", Double(planSrc!) * tb))s "
                                      + "drift=\(String(format: "%.3f", Double(srcDts &- planSrc!) * tb))s "
                                    : "planSource=n/a drift=n/a ")
                                + "shift=\(String(format: "%.3f", Double(shiftTicks) * tb))s",
                                category: .session
                            )
                        }
                        pendingVideoPkt = nil
                        if !mux(.video, segment: prevSeg, videoWrite(prev, nextDts: packet.pointee.dts)) {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingVideoPkt = packet
                    pendingVideoSegIndex = thisVideoSeg   // live: liveVideoSegmentIndex; VOD: keyframe-gated cutter
                    pktPtr = nil  // ownership transferred to pendingVideoPkt
                    continue
                }

                if let audio = audioConfig, isAudioPkt {
                    if let bridge = audio.bridge {
                        let flacPackets: [UnsafeMutablePointer<AVPacket>]
                        do {
                            flacPackets = try bridge.feed(packet: packet)
                        } catch {
                            EngineLog.emit(
                                "[HLSSegmentProducer] audio bridge.feed failed at pkt#\(packetsRead): \(error)",
                                category: .session
                            )
                            continue
                        }
                        if !writeBridgedAudio(flacPackets, audio: audio) {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                        continue
                    }
                    switch audio.framing {
                    case .raw: break
                    case .adts: Self.stripADTSHeader(packet)
                    case .latm(let config):
                        guard unwrapLATM(packet, declared: config) else { continue }
                    case .bluRayLPCM(let format):
                        guard unwrapBluRayLPCM(packet, declared: format) else { continue }
                    }
                    let thisAudioSeg: Int = isLive
                        ? liveCurrentSegmentIndex
                        : (audioFollowsVideoCut ? vodCutter.current : 0)
                    if let prev = pendingAudioPkt {
                        pendingAudioPkt = nil
                        let write = audioWrite(prev, nextDts: packet.pointee.dts, audio: audio)
                        let prevSeg = isLive || audioFollowsVideoCut
                            ? pendingAudioSegIndex : playedAudioSegmentIndex(prev, audio: audio)
                        if !mux(.audio, segment: prevSeg, write) {
                            exitReason = .muxerFailed
                            break readLoop
                        }
                    }
                    pendingAudioPkt = packet
                    if isLive || audioFollowsVideoCut { pendingAudioSegIndex = thisAudioSeg }
                    pktPtr = nil
                    continue
                }
            }
        } catch is InterruptedSourceReplay {
            exitReason = checkShouldStop() ? .stopRequested : .sourceReplay
        } catch {
            if case DemuxerError.readFailed(let code) = error {
                lastError = code
                exitReason = .readError(code: code)
            } else {
                lastError = -1
                exitReason = .readError(code: -1)
            }
            // Audit HLS-1: a stop aborts a parked read through markClosed, which surfaces here.
            stateLock.lock()
            let stopped = shouldStop
            stateLock.unlock()
            if stopped { exitReason = .stopRequested }
            EngineLog.emit(
                "[HLSSegmentProducer] demuxer.readPacket threw: \(error)",
                category: .session
            )
        }

        restorePumpQoSForUnwind()

        // AE#406: the watchdog decides off this thread, so its verdict lands while the loop is
        // parked in a read that has no upper bound of its own. The abort that lets the loop observe
        // the verdict surfaces here as a read error, and `.readError` sends a reopenable source into
        // a URL reopen of the very origin that starved. The verdict is what the exit means.
        if noCutWatchdog?.hasLatchedExit == true {
            if case .stopRequested = exitReason {} else { exitReason = .segmentStall }
        }

        // Audit SEG-104: the abort of a parked read surfaces as end of file, which is not the source's.
        if case .eof = exitReason, checkShouldStop() {
            exitReason = .stopRequested
        }
        if case .eof = exitReason { onSourceReadThrough?(.infinity) }

        // muxerFailed from a backpressure break is a wedge (host re-anchors) or a stop (teardown), not a real failure.
        if case .muxerFailed = exitReason {
            stateLock.lock()
            let stopped = shouldStop
            let wedged = _backpressureWedgeBroken
            stateLock.unlock()
            if stopped { exitReason = .stopRequested }
            else if wedged { exitReason = .backpressureWedge }
        }

        // AE#222: a cut that deferred for want of a packet-derived audio sample entry is recoverable, but only
        // with one real audio frame in hand. Scan for it here, on the way out: the bytes this reads are the
        // same ones the rebuilt producer will re-read for its own first segments, and every alternative
        // (bridging to FLAC, stretching the first segment past its plan boundary) either downgrades the audio
        // or breaks the playlist. If no frame turns up, the reason stays .muxerFailed and the host's existing
        // fallbacks own the session.
        if case .muxerFailed = exitReason, cutDeferredAwaitingAudioSampleEntry {
            if let prime = scanForAudioMoovPrimeFrame() {
                stateLock.lock()
                _capturedAudioMoovPrimeFrame = prime
                stateLock.unlock()
                exitReason = .needsAudioSampleEntryPrime
            }
        }

        freeReplayPackets()
        freeMergeLookaheads()

        // #74: free any head-of-stream audio still buffered (e.g. the video gate never opened on a
        // corrupt or aborted source); replayed entries were already drained at the loop top.
        freeUnreplayedPregateAudio()

        // Flush look-behind; fallback duration produces tail-correct trun for the final fragment.
        // #731: the last keyframe can open a final segment; what the bridge still encodes belongs
        // before that cut. Only an EOF adopts the open segment, so only an EOF needs it.
        if case .eof = exitReason, let audio = audioConfig, let bridge = audio.bridge {
            _ = writeBridgedAudio(bridge.settle(), audio: audio)
        }
        if let prev = pendingVideoPkt {
            pendingVideoPkt = nil
            // unified: live + VOD both carry the routed index
            _ = mux(.video, segment: pendingVideoSegIndex, videoWrite(prev, nextDts: nil))
        }
        if let prev = pendingAudioPkt, let audio = audioConfig {
            pendingAudioPkt = nil
            let write = audioWrite(prev, nextDts: nil, audio: audio)
            let prevSeg = isLive || audioFollowsVideoCut
                ? pendingAudioSegIndex : playedAudioSegmentIndex(prev, audio: audio)
            _ = mux(.audio, segment: prevSeg, write)
        }

        // EOF tail flush for bridge audio: drains ~100-200 ms remainder (per-feed only emits full frames).
        if case .eof = exitReason, let audio = audioConfig, let bridge = audio.bridge {
            _ = writeBridgedAudio(bridge.flush(), audio: audio)
        }
        // What the gate still holds: muxed at the source's end, where no track has more to come, and
        // freed on any other exit, whose open segment is not adopted.
        if var gate = cutGate {
            cutGate = nil
            let held = gate.drain()
            if case .eof = exitReason {
                _ = muxReleased(held)
            } else {
                held.forEach { $0.item.free() }
            }
        }

        // AE#847: after the bridge tail, so the fill starts where the delivered audio really ends.
        if case .eof = exitReason, !isLive, let audio = audioConfig {
            padAudioTailToVideoEnd(audio: audio)
        }

        finishFiles(adopting: Self.shouldAdoptTeardownSegment(exitReason: exitReason, isLive: isLive))
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - pumpStart.uptimeNanoseconds) / 1_000_000
        EngineLog.emit(
            "[HLSSegmentProducer] pump finished: reason=\(exitReason) "
            + "packetsRead=\(packetsRead) "
            + "packetsWritten=\(packetsWrittenCount) lastError=\(lastError) "
            + "elapsed=\(String(format: "%.0f", elapsedMs))ms cacheCount=\(cache.count)"
            + (frameGrid.map { " frameGrid=1/\($0.outputTimeBase.den)x\($0.frameTicks) "
                + "onGrid=\(griddedVideoPackets) offGrid=\(offGridVideoPackets)" } ?? ""),
            category: .session
        )

        audioConfig?.bridge?.producerFinished()
        finishCondition.lock()
        didFinishFlag = true
        finishCondition.broadcast()
        finishCondition.unlock()

        onPumpFinished?(exitReason)
    }

    /// Route and mux packets a bridge returned. False when the muxer is gone; every packet is freed
    /// either way.
    private func writeBridgedAudio(_ packets: [UnsafeMutablePointer<AVPacket>], audio: AudioConfig) -> Bool {
        var muxerGone = false
        for fp in packets {
            let free = GatedWrite.freeing(fp)
            if muxerGone { free(); continue }
            let write = GatedWrite(write: { [self] muxer in
                fp.pointee.stream_index = muxer.audioOutputStreamIndex
                av_packet_rescale_ts(fp, audio.inputTimeBase, muxer.muxerAudioTimeBase)
                let prime = copyAudioPrimeCandidate(fp)
                if muxer.writePacket(fp).rc >= 0, let prime {
                    audioMoovPrimeFrame = prime
                }
                free()
            }, free: free)
            if !mux(.audio, segment: bridgedAudioSegmentIndex(fp, audio: audio), write) { muxerGone = true }
        }
        return !muxerGone
    }

    // MARK: - The cut gate

    /// Muxes `item` into `segment`: through the cut gate, which may hold it for another track, or at once
    /// where there is none. False when the muxer is gone; every packet released is then freed.
    private func mux(_ track: SegmentCutGate<GatedWrite>.Track, segment: Int, _ item: GatedWrite) -> Bool {
        // Demuxed, the audio has a file of its own, cut on its own routing, and nothing waits for the video.
        if track == .audio, let audioFile {
            guard let muxer = ensureMuxer(audioFile, forSegmentIndex: segment) else { item.free(); return false }
            item.write(muxer)
            return true
        }
        guard cutGate != nil else { return muxReleased([(segment, item)]) }
        return muxReleased(cutGate!.submit(item, track: track, segment: segment))
    }

    private func muxReleased(_ entries: [(segment: Int, item: GatedWrite)]) -> Bool {
        var muxerGone = false
        for entry in entries {
            if !muxerGone, let muxer = ensureMuxer(videoFile, forSegmentIndex: entry.segment) {
                entry.item.write(muxer)
            } else {
                muxerGone = true
                entry.item.free()
            }
        }
        return !muxerGone
    }

    /// A look-behind video packet's write. AE#412: a cold arrival can only start a decode run on a
    /// random-access point, so what a segment is worth to one is where its first sync sample sits,
    /// recorded against the muxer's own index because that is the segment these bytes are in.
    private func videoWrite(_ packet: UnsafeMutablePointer<AVPacket>, nextDts: Int64?) -> GatedWrite {
        GatedWrite(write: { [self] muxer in
            if !isLive, (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0 {
                let openIdx = muxer.currentSegmentIndex
                if firstSyncItemPtsBySegment[openIdx] == nil {
                    // AE#561: measured against a plan boundary, so stamped on the plan's axis. On the
                    // wrong one the reach is off by the frame's composition offset, which is the
                    // distance this very number exists to report.
                    firstSyncItemPtsBySegment[openIdx] =
                        planBoundaryAxis.timestamp(dts: packet.pointee.dts, pts: packet.pointee.pts)
                }
            }
            finalizeAndWriteVideo(packet, nextDts: nextDts, muxer: muxer)
            bumpPacketsWritten()
        }, free: GatedWrite.freeing(packet))
    }

    /// A look-behind copied audio packet's write, its duration stated first: where the container gave
    /// none, up to the next packet (`nextDts`), so routing reads where its last sample plays.
    private func audioWrite(_ packet: UnsafeMutablePointer<AVPacket>, nextDts: Int64?, audio: AudioConfig) -> GatedWrite {
        if packet.pointee.duration <= 0 {
            let inferred = nextDts.map { SourceTimestampBounds.difference($0, packet.pointee.dts) } ?? 0
            packet.pointee.duration = inferred > 0 ? inferred : audioFrameDuration
        }
        return GatedWrite(write: { [self] muxer in
            finalizeAndWriteAudio(packet, audio: audio, muxer: muxer)
        }, free: GatedWrite.freeing(packet))
    }

    /// AE#847: give the final segment silence from where its audio stops to where its picture
    /// does, because AVPlayer ends the item at the end of the audio (see `AudioTailPadding`).
    /// The fill goes into the file that serves the video's last segment: the video's own when muxed. When
    /// demuxed, the audio rendition first moves on to that index, which serves the indices its audio never
    /// reached without samples, so the silence lands in the final audio segment and not the one where the
    /// source's audio ran out.
    private func padAudioTailToVideoEnd(audio: AudioConfig) {
        guard let videoMuxer = videoFile.muxer else { return }
        let muxer: MP4SegmentMuxer
        if let audioFile {
            guard let audioMuxer = ensureMuxer(audioFile, forSegmentIndex: videoFile.segmentIndex) else { return }
            muxer = audioMuxer
        } else {
            muxer = videoMuxer
        }
        guard videoMuxer.writtenVideoEndPts != Int64.min,
              videoMuxer.segmentVideoStartPts != Int64.min else { return }
        let videoTb = videoMuxer.muxerVideoTimeBase
        let audioTb = muxer.muxerAudioTimeBase
        guard videoTb.den > 0, audioTb.den > 0 else { return }
        let videoEnd = Double(videoMuxer.writtenVideoEndPts) * av_q2d(videoTb)
        let segmentStart = Double(videoMuxer.segmentVideoStartPts) * av_q2d(videoTb)
        let audioEnd = muxer.writtenAudioEndPts == Int64.min
            ? nil : Double(muxer.writtenAudioEndPts) * av_q2d(audioTb)
        guard let span = AudioTailPadding.span(videoEnd: videoEnd, audioEnd: audioEnd,
                                               segmentStart: segmentStart) else { return }
        let describe = "audio ends at \(audioEnd.map { String(format: "%.3f", $0) } ?? "-")s, "
            + "video at \(String(format: "%.3f", videoEnd))s, segment from \(String(format: "%.3f", segmentStart))s"
        // A stand-in sample entry (the APAC bed behind ALAC) describes a codec the fill cannot match.
        if audio.bridge?.soundSampleEntryOverride != nil {
            EngineLog.emit("[HLSSegmentProducer] AE#847 audio tail not padded (\(describe)): "
                           + "the track is a stand-in for its real codec", category: .session)
            return
        }
        let startTicks = Int64((span.start / av_q2d(audioTb)).rounded(.up))
        let endTicks = Int64((span.end / av_q2d(audioTb)).rounded(.down))
        switch AudioTailPadding.silencePackets(codecpar: audio.codecpar, startTicks: startTicks,
                                               endTicks: endTicks, timeBase: audioTb) {
        case .unavailable(let reason):
            EngineLog.emit("[HLSSegmentProducer] AE#847 audio tail not padded (\(describe)): \(reason)",
                           category: .session)
        case .packets(let packets, let encoder):
            if !muxer.placeNextFragmentAtItsTimestamp() {
                EngineLog.emit("[HLSSegmentProducer] AE#847 cannot place the fill at its own time on this build; "
                               + "it follows the written audio instead (\(describe))", category: .session)
            }
            var written = 0
            for packet in packets {
                packet.pointee.stream_index = muxer.audioOutputStreamIndex
                if muxer.writePacket(packet).rc >= 0 { written += 1 }
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&pkt)
            }
            EngineLog.emit("[HLSSegmentProducer] AE#847 audio tail padded with \(written) silent \(encoder) frame(s) "
                           + "from \(String(format: "%.3f", span.start))s (\(describe))", category: .session)
        }
    }

    /// The segment a bridged audio packet belongs to. Live and sequential audio follow the video
    /// cutter; everything else is routed by where it plays (`playedAudioSegmentIndex`). One helper for
    /// the per-feed and the end-of-file flush, because the flush missing the sequential rule opened a
    /// plan index the cutter never reached and cost the archive its final segment (audit SEG-103).
    private func bridgedAudioSegmentIndex(_ packet: UnsafeMutablePointer<AVPacket>, audio: AudioConfig) -> Int {
        if isLive { return liveCurrentSegmentIndex }
        if audioFollowsVideoCut { return vodCutter.current }
        return playedAudioSegmentIndex(packet, audio: audio)
    }

    /// VOD routed by time: the segment an audio packet's last sample plays in, copied or bridged
    /// (`AudioRunPlan`), so a packet that straddles a boundary opens the segment after it and the
    /// segment has sound from its first picture. Played time has the host's audio delay in: a bridge
    /// stamps it into its output, the muxer adds it to a copied packet, so it is added here for one.
    private func playedAudioSegmentIndex(_ packet: UnsafeMutablePointer<AVPacket>, audio: AudioConfig) -> Int {
        let plan = audioRunPlan(audio)
        let played = audio.bridge == nil ? packet.pointee.pts &+ plan.delayTicks : packet.pointee.pts
        return plan.segment(ofOutputPts: played, duration: packet.pointee.duration)
    }

    /// This producer's segments as bridged audio is routed to them: the routing above, and the runs
    /// that make each segment's audio (`AudioSegmentRuns`).
    private func audioRunPlan(_ audio: AudioConfig) -> AudioRunPlan {
        AudioRunPlan(
            baseIndex: baseIndex, boundaries: segmentBoundaries, planAnchor: planAnchorVideoPts,
            videoTimeBase: sourceVideoTimeBase, outputTimeBase: audio.inputTimeBase,
            delayTicks: Int64((audioDelaySeconds * Double(audio.inputTimeBase.den)
                               / Double(max(audio.inputTimeBase.num, 1))).rounded()))
    }

    /// The host's audio delay in `AudioConfig.timeBase`: source audio at `t` plays at `t` plus this.
    private var audioDelaySourceTicks: Int64 {
        guard let audio = audioConfig, audio.timeBase.num > 0 else { return 0 }
        return Int64((audioDelaySeconds * Double(audio.timeBase.den) / Double(audio.timeBase.num)).rounded())
    }

    /// The bridge's pre-roll (`AudioTranscodingBridge.preRollSeconds`), in `AudioConfig.timeBase`.
    private var audioPreRollTicks: Int64 {
        guard let audio = audioConfig, let seconds = audio.bridge?.preRollSeconds, seconds > 0,
              audio.timeBase.num > 0 else { return 0 }
        return Int64((seconds * Double(audio.timeBase.den) / Double(audio.timeBase.num)).rounded(.up))
    }

    // MARK: - Look-behind finalize helpers

    /// Sample duration (source video TB) written for a look-behind video packet. Always telescope to
    /// the true decode-order DTS delta when a forward `nextDts` is available, so movenc's per-track
    /// `track_duration` equals the elapsed DTS and its fragment-boundary reference (`start_dts +
    /// track_duration`) can never overshoot the next real DTS. matroska hands a CONSTANT DefaultDuration
    /// for every block while the ms-quantized block timecodes make the real DTS deltas jitter; trusting
    /// the constant drifts track_duration ~one frame ahead per segment and trips `check_pkt`
    /// (`Packet duration: -N ... out of range` -> DTS clamp + `pts has no value` -> wrong trun timing,
    /// the #92 transient blocky glitch). Falls back to the source packet's own positive duration, then
    /// `fallback`, only when no usable forward delta exists (EOF tail, NOPTS, or a non-increasing next).
    /// #369: `capTicks` bounds the inferred delta (a sample longer than a discontinuity is
    /// definitionally invalid). Across a 33-bit PTS wrap the look-behind delta IS the wrap
    /// (device: 8226410192 ticks, ~91404 s; movenc rejects it as "Application provided duration
    /// ... is invalid" and the packet is lost), so an over-cap delta falls back like a
    /// non-forward one. The cap holds for the source's DECLARED duration too: movenc rejects the
    /// sample whatever produced its number, and a container that carries a wrap-scale duration
    /// (a corrupt DefaultDuration, a duration derived from the same wrapped clock) reaches the
    /// muxer through exactly this branch whenever there is no usable forward delta, which is the
    /// EOF tail of the very stream the cap exists for.
    static func resolveVideoSampleDuration(
        existingDuration: Int64,
        dts: Int64,
        nextDts: Int64?,
        fallback: Int64,
        capTicks: Int64
    ) -> Int64 {
        if let next = nextDts, dts != Int64.min, next != Int64.min {
            let inferred = SourceTimestampBounds.difference(next, dts)
            if inferred > 0, inferred <= capTicks { return inferred }
        }
        return existingDuration > 0 && existingDuration <= capTicks ? existingDuration : fallback
    }

    /// #369: the sample-duration cap in source-video ticks (`discontinuityThresholdSeconds`, so
    /// live rebases and the duration cap share one definition of "discontinuity").
    private var videoSampleDurationCapTicks: Int64 {
        sourceVideoTbSeconds > 0
            ? Int64(Self.discontinuityThresholdSeconds / sourceVideoTbSeconds)
            : Int64.max
    }

    private func finalizeAndWriteVideo(
        _ packet: UnsafeMutablePointer<AVPacket>,
        nextDts: Int64?,
        muxer: MP4SegmentMuxer
    ) {
        packet.pointee.duration = Self.resolveVideoSampleDuration(
            existingDuration: packet.pointee.duration,
            dts: packet.pointee.dts,
            nextDts: nextDts,
            fallback: videoFallbackDurationPts,
            capTicks: videoSampleDurationCapTicks
        )

        packet.pointee.stream_index = muxer.videoOutputStreamIndex

        if !hdr10PlusDetected, HDR10PlusMetadataScan.packetCarriesHDR10Plus(
            packet, codecParameters: videoConfig.codecpar, framing: a53NALFraming
        ) {
            hdr10PlusDetected = true
            onFirstHDR10PlusDetected?()
        }

        // #131: A53 caption extraction rides the same per-packet spot as the HDR10+ scan: decode
        // order, repaired DTS, timestamps still in the source time base (the rescale below).
        // #259: the source time BASE, but no longer the source AXIS. The pump rebased this packet
        // onto the output axis long before it got here, so the shift is folded back: the tap's cues
        // are rendered against the source-PTS clock (as the c608 tap's and the SW path's are), and
        // the shift is recomputed per producer session, so leaving it in would displace every
        // caption by a different amount after each seek.
        if let kind = a53CodecKind, let observe = a53CaptionObserver,
           let data = packet.pointee.data, packet.pointee.pts != Int64.min {
            let size = Int(packet.pointee.size)
            if A53SEIParser.mayContainA53(data, size) {
                let extracted = A53SEIParser.triplets(in: data, size: size, codec: kind, framing: a53NALFraming)
                if !extracted.isEmpty {
                    observe(extracted,
                            Self.foldingShiftBack(packet.pointee.pts, shift: videoShiftPts),
                            Self.foldingShiftBack(packet.pointee.dts, shift: videoShiftPts),
                            sourceVideoTimeBase)
                }
            }
        }

        // #260: capture the source axis BEFORE the rescale (after it the packet carries muxer TB) and the
        // keyframe flag while the packet is still ours. The item axis comes back out of writePacket: the write
        // blanks the packet, so it cannot be read off it afterwards, and the sanitizer can move it.
        let frameObserver = nativeVideoFrameTimeObserverProvider?()
        let frameSourcePts = frameObserver == nil
            ? Int64.min
            : Self.foldingShiftBack(packet.pointee.pts, shift: videoShiftPts)
        let frameIsKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        let frameSegmentIndex = videoFile.segmentIndex

        // AE#886: decided on the source time base, before the rescale rounds it away.
        let gridded = muxer.muxerVideoTimeBase.den == frameGrid?.outputTimeBase.den
            ? frameGrid?.place(pts: packet.pointee.pts, dts: packet.pointee.dts,
                               duration: packet.pointee.duration, shift: videoShiftPts)
            : nil
        av_packet_rescale_ts(packet, sourceVideoTimeBase, muxer.muxerVideoTimeBase)
        if let gridded {
            packet.pointee.pts = gridded.pts
            packet.pointee.dts = gridded.dts
            packet.pointee.duration = gridded.duration
            griddedVideoPackets += 1
        } else if frameGrid != nil {
            offGridVideoPackets += 1
        }
        let write = muxer.writePacket(packet)
        if write.rc < 0, !loggedVideoWriteFailure {
            // #369: this rc used to be dropped on the floor; the field failure (movenc rejecting a
            // wrap-scale sample duration) was only findable through libav's own stderr line.
            loggedVideoWriteFailure = true
            EngineLog.emit(
                "[HLSSegmentProducer] #369 video packet write failed rc=\(write.rc) "
                + "dts=\(packet.pointee.dts) duration=\(packet.pointee.duration) (muxer TB; "
                + "first occurrence only)",
                category: .session
            )
        }
        let written = write.written

        if let frameObserver,
           let source = Self.cmTime(ticks: frameSourcePts, timeBase: sourceVideoTimeBase),
           let item = Self.cmTime(ticks: written.pts, timeBase: muxer.muxerVideoTimeBase) {
            frameObserver(
                NativeVideoFrameTime(
                    source: source,
                    item: item,
                    segmentIndex: frameSegmentIndex,
                    isKeyframe: frameIsKeyframe,
                    epoch: epoch
                )
            )
        }

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

    /// Ticks in `timeBase` as a `CMTime`. nil for NOPTS or a degenerate time base, so a consumer never
    /// receives a timestamp the engine could not actually resolve (#260).
    static func cmTime(ticks: Int64, timeBase: AVRational) -> CMTime? {
        guard ticks != Int64.min, timeBase.num > 0, timeBase.den > 0 else { return nil }
        return CMTime(value: CMTimeValue(ticks &* Int64(timeBase.num)), timescale: CMTimeScale(timeBase.den))
    }

    /// Strip 7/9-byte ADTS header in-place (advances data pointer, shrinks size; buf untouched for unref safety).
    /// Replace a LOAS/LATM packet's bytes with the AAC frame inside it (`LATM.Reader`). False drops
    /// the packet: an element outside what `LATM` reads, or one whose stream changed its
    /// AudioSpecificConfig away from the one the init segment declares, whose frames would be
    /// decoded against the wrong configuration.
    private func unwrapLATM(_ packet: UnsafeMutablePointer<AVPacket>, declared: [UInt8]) -> Bool {
        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
        let frame = latmReader.payload(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
        guard let frame, latmReader.config == declared else {
            noteUnframeable(frame == nil ? "an unreadable LATM element"
                : "a LATM element carrying AudioSpecificConfig " + Self.hex(latmReader.config ?? [])
                    + " where the init declares " + Self.hex(declared))
            return false
        }
        return Self.replacePayload(of: packet, with: frame)
    }

    /// Take a Blu-ray LPCM packet's header off (`BluRayLPCM`), in place, and on a layout stored with
    /// an unused channel copy the frames without it. False drops the packet: one whose header declares
    /// another format than the init segment does, or that is not whole frames.
    private func unwrapBluRayLPCM(_ packet: UnsafeMutablePointer<AVPacket>, declared: BluRayLPCM) -> Bool {
        guard let data = packet.pointee.data, packet.pointee.size > 0,
              let samples = declared.samples(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size))) else {
            noteUnframeable("a Blu-ray LPCM packet of another format, or not whole frames")
            return false
        }
        guard !declared.isPadded else { return Self.replacePayload(of: packet, with: declared.droppingPadding(samples)) }
        packet.pointee.data = data.advanced(by: 4)
        packet.pointee.size -= 4
        return true
    }

    private func noteUnframeable(_ what: String) {
        unframeableAudioPackets += 1
        if unframeableAudioPackets == 1 || unframeableAudioPackets % 500 == 0 {
            EngineLog.emit(
                "[HLSSegmentProducer] audio: dropped \(unframeableAudioPackets) packet(s), the last \(what)",
                category: .session)
        }
    }

    private static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// `packet` with `bytes` as its whole payload, in a buffer of its own.
    static func replacePayload(of packet: UnsafeMutablePointer<AVPacket>, with bytes: [UInt8]) -> Bool {
        guard let buffer = av_buffer_alloc(bytes.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)) else { return false }
        bytes.withUnsafeBufferPointer { buffer.pointee.data.update(from: $0.baseAddress!, count: bytes.count) }
        memset(buffer.pointee.data + bytes.count, 0, Int(AV_INPUT_BUFFER_PADDING_SIZE))
        av_buffer_unref(&packet.pointee.buf)
        packet.pointee.buf = buffer
        packet.pointee.data = buffer.pointee.data
        packet.pointee.size = Int32(bytes.count)
        return true
    }

    private static func stripADTSHeader(_ packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data, packet.pointee.size >= 7 else { return }
        guard data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else { return }  // ADTS sync word
        let headerLen: Int32 = (data[1] & 0x01) != 0 ? 7 : 9
        guard packet.pointee.size > headerLen else { return }
        packet.pointee.data = data.advanced(by: Int(headerLen))
        packet.pointee.size -= headerLen
    }

    /// Copies the payload of an audio packet about to be muxed, BEFORE the write: movenc consumes the
    /// packet's data reference, so afterwards there is nothing left to copy. The caller commits the copy
    /// into `audioMoovPrimeFrame` only when the write succeeded.
    private func copyAudioPrimeCandidate(_ packet: UnsafeMutablePointer<AVPacket>) -> [UInt8]? {
        guard capturesAudioPrimeFrames, let data = packet.pointee.data, packet.pointee.size > 0 else {
            return nil
        }
        return [UInt8](UnsafeBufferPointer(start: data, count: Int(packet.pointee.size)))
    }

    /// Stream-copy audio only; bridge audio bypasses this (FLAC encoder sets durations correctly).
    private func finalizeAndWriteAudio(
        _ packet: UnsafeMutablePointer<AVPacket>,
        audio: AudioConfig,
        muxer: MP4SegmentMuxer
    ) {
        packet.pointee.stream_index = muxer.audioOutputStreamIndex
        av_packet_rescale_ts(packet, audio.inputTimeBase, muxer.muxerAudioTimeBase)
        let prime = copyAudioPrimeCandidate(packet)
        if muxer.writePacket(packet).rc >= 0, let prime {
            audioMoovPrimeFrame = prime
        }

        var pkt: UnsafeMutablePointer<AVPacket>? = packet
        trackedPacketFree(&pkt)
    }

}

/// Unit-testable DTS ordering for the dual-source pull-merge.
enum DualSourceMergeOrder {

    /// Compares in a 1/1000000 common clock. Ties yield MAIN first (segment cut keys off video keyframes).
    static func sideFirst(
        mainTicks: Int64,
        mainTimeBase: AVRational,
        sideTicks: Int64,
        sideTimeBase: AVRational
    ) -> Bool {
        if sideTicks == Int64.min { return true }   // AV_NOPTS_VALUE: yield immediately
        if mainTicks == Int64.min { return false }
        let micro = AVRational(num: 1, den: 1_000_000)
        let mainUs = av_rescale_q(mainTicks, mainTimeBase, micro)
        let sideUs = av_rescale_q(sideTicks, sideTimeBase, micro)
        return sideUs < mainUs
    }
}

// MARK: - Live recording (AE#560)

extension HLSSegmentProducer: LiveRecordingHost {

    func recordingStreamDescriptors() -> [RecordingStreamDescriptor] {
        var out: [RecordingStreamDescriptor] = []

        let videoIndex = demuxer.videoStreamIndex
        if videoIndex >= 0, let stream = demuxer.stream(at: videoIndex) {
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: videoIndex,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: true))
        }

        // The audio source is the SIDE demuxer when one is open (a packed audio rendition), and the
        // main demuxer otherwise. Reading the wrong one is how this feature would ship silent.
        let audioSource = sideAudioDemuxer ?? demuxer
        let audioIndex = audioSource.audioStreamIndex
        if audioIndex >= 0, let stream = audioSource.stream(at: audioIndex) {
            // A side demuxer numbers its streams independently, so it can hand back the same index
            // the main demuxer already used for video. The writer maps packets by source index, so
            // a collision would route audio into the video stream. Refuse instead.
            if audioIndex == videoIndex, sideAudioDemuxer != nil {
                EngineLog.emit(
                    "[HLSSegmentProducer] recording refused: the side audio demuxer reuses source "
                    + "stream index \(audioIndex), which the video stream already holds",
                    category: .session
                )
                return []
            }
            out.append(RecordingStreamDescriptor(
                sourceStreamIndex: audioIndex,
                timeBaseNum: stream.pointee.time_base.num,
                timeBaseDen: stream.pointee.time_base.den,
                codecParameters: stream.pointee.codecpar,
                isVideo: false))
        }
        return out
    }

    func setRecordingSink(_ sink: LiveRecordingSink?) {
        recordingSinkLock.lock()
        recordingSink = sink
        recordingSinkLock.unlock()
    }

    /// Pump thread. Non-blocking by the sink's contract.
    func tapForRecording(_ packet: UnsafeMutablePointer<AVPacket>) {
        recordingSinkLock.lock()
        let sink = recordingSink
        recordingSinkLock.unlock()
        guard let sink, let data = packet.pointee.data, packet.pointee.size > 0 else { return }
        sink.accept(
            packetBytes: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)),
            sourceStreamIndex: packet.pointee.stream_index,
            pts: packet.pointee.pts,
            dts: packet.pointee.dts,
            duration: packet.pointee.duration,
            isKeyframe: (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
        )
    }
}
