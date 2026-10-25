// Only with the TrueHDObjectAudio or DTSXObjectAudio trait (both off by default).
#if TrueHDObjectAudio || DTSXObjectAudio
import Foundation
import AetherLibavcodec
import AetherLibavutil

/// TrueHD Atmos or DTS:X in, APAC out: decodes the object presentation, renders its beds and objects
/// into a `SpatialSpeakerLayout` bed and encodes that as Apple Positional Audio, which tvOS delivers
/// to an Atmos receiver as Dolby MAT with the heights intact.
///
/// The PCM bridge keeps TrueHD and DTS-HD lossless but can only carry the 7.1 presentation, so every
/// height and every object position is gone before the audio leaves the engine. This bridge trades the
/// lossless bed for the Atmos mix: APAC is lossy, at a few Mbit/s, several times the rate streaming
/// services deliver Atmos at.
///
/// libavformat can neither encode nor mux APAC, so the muxer is handed an ALAC stand-in stream
/// (`encoderCodecpar`) whose sample entry the init segment rewrite replaces with the real one
/// (`soundSampleEntryOverride`). Packets pass through movenc untouched.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class SpatialAudioBridge: AudioTranscodingBridge, @unchecked Sendable {

    static let sampleRate = ObjectAudioRendering.sampleRate

    /// Default encode rate per bed channel. 3.84 Mbit/s for 7.1.4, 5.12 for 9.1.6.
    static let bitRatePerChannel = 320_000

    enum BridgeError: Error, CustomStringConvertible {
        case codecparAllocFailed
        case unsupportedSampleRate(Int)

        var description: String {
            switch self {
            case .codecparAllocFailed: return "SpatialAudioBridge: avcodec_parameters_alloc failed"
            case .unsupportedSampleRate(let r): return "SpatialAudioBridge: object audio at \(r) Hz (48 kHz only)"
            }
        }
    }

    let layout: SpatialSpeakerLayout
    private(set) var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>?
    let encoderTimeBase = AVRational(num: 1, den: Int32(SpatialAudioBridge.sampleRate))
    let soundSampleEntryOverride: Data?
    /// HLS `CODECS` value for the track.
    let hlsCodecs: String
    var servedChannelCount: Int? {
#if APACObjectOutput
        // CHANNELS agrees with CODECS: both name the tier the object stream is announced as.
        if objectOutput { return Self.objectAnnouncedLayout.channelCount }
#endif
        return layout.channelCount
    }
    let peakOutputBitRate: Int64
    /// The encoder's priming: the first frames of every encoder run's decoded audio, before its content.
    var leadingFrames: Int { pipeline.leadingFrames }

    /// What the bed handed to the encoder at a position takes input from, decoder to limiter
    /// (`AudioStageSpan`). Two stages are not in it. The renderer's memory is the metadata's, and it
    /// says itself when it has settled (`ObjectAudioRenderer.isSettled`). The encoder's never ends,
    /// so a segment that must not depend on its run gets a run of its own
    /// (`APACEncoder.segmentRunLeadFrames`).
    var span: AudioStageSpan {
        var stages = [decoder.span]
#if TrueHDObjectAudio
        if decoder.playsBedOnly { stages.append(BedSplitter.span) }
#endif
#if APACObjectOutput
        if objectOutput { return .series(stages) }
#endif
        stages.append(PeakLimiter.span(sampleRate: Self.sampleRate))
        return .series(stages)
    }

    /// A segment's run (`AudioSegmentRuns`): `span`, then the encoder, whose rate control never
    /// forgets where a run began, so a run leaves it `APACEncoder.segmentRunLeadFrames` before the
    /// segment.
    var runSpan: AudioStageSpan? { span.then(AudioStageSpan(latency: 0, memory: APACEncoder.segmentRunLeadFrames)) }
    var runEncoderMemory: Int { APACEncoder.segmentRunLeadFrames }
    var runPacketFrames: Int { APACEncoder.framesPerPacket }
    var presentationDelay: Int64 { Int64(leadingFrames) }

    private let srcTimeBase: AVRational
    private let decoder: ObjectAudioDecoding
    private let pipeline: APACEncodePipeline
    private var renderer: ObjectAudioRenderer?
    private var rendererGeneration = -1
    /// The renderer started over (built, or reset by a restart) and its next block marks where.
    private var rendererRunPending = true
    /// Where the renderer's run began, until it settles (`ObjectAudioRenderer.isSettled`): how long
    /// that takes on real programmes is what a restart's pre-roll has to cover, so it is logged.
    private var rendererSettlingFrom: Int64?
    /// What the encoder is fed, per bed channel, for the session log (see `BedLevelMeter`): this
    /// bridge's, or the session's when it makes one segment (`measuring`).
    let levels: SessionLevelMeter
    /// A segment's run measures into the session's meter, and only its own segment: frames on the
    /// output timeline (`startRun`). Nil: everything this bridge makes is its own to measure.
    private var measuring: Range<Int64>?
    private let ownsLevels: Bool
    /// Set-up lines go to the log once a session: a segment's run is made as the session's own was.
    private let announces: Bool
    /// Keeps the bed under full scale, since the encoder carries anything over it on (see `PeakLimiter`).
    private var limiter: PeakLimiter

    /// Rendered bed awaiting the encoder. TrueHD decodes one 40-frame access unit per block, 1200
    /// a second; feeding the converter that often costs more in call overhead than the encode, so
    /// blocks are rendered straight into this buffer and it is handed to the encoder's queue
    /// `encodeChunkFrames` at a time (see `APACEncodePipeline`).
    private var output: APACEncodePipeline.PlaneBuffer
    private var pendingFrames = 0
#if TrueHDObjectAudio
    /// Built from the first block that carries a bed: every output comes from that bed instead of
    /// the renderer's mix (see `BedSplitter`). Its latency is the frames it holds, `backlog`.
    private var splitter: BedSplitter?
    /// The splitter starts fresh at the next block, its hops put on the stream's grid there
    /// (`BedSplitter.reset(phase:)`): after it is built, a restart, or a drain.
    private var splitterStartsFresh = true
    private var gainSnapshot = ObjectAudioGainSnapshot()
#endif
    /// Frames taken from the decoder that have not reached the encoder yet, outside `output`: the
    /// splitter's and the limiter's look-ahead.
    private var heldBack: Int {
#if TrueHDObjectAudio
        (splitter?.backlog ?? 0) + limiter.backlog
#else
        limiter.backlog
#endif
    }
    private static let encodeChunkFrames = 2048
#if APACObjectOutput
    /// Elements go out as APAC objects (`APACObjectEncoder`): no renderer mix, no split, no limiter
    /// (the system renderer mixes after the encode). The presentation the chunk being filled holds.
    private let objectOutput: Bool
    private var objectRoles: [ObjectAudioRole] = []
    /// The channel bed an object stream is announced as in the playlist (see `init`): the one tvOS
    /// renders it to for an HDMI Atmos route.
    static let objectAnnouncedLayout = SpatialSpeakerLayout.l714
#endif

    /// Timeline, in 48 kHz frames on the output time base. Where a block plays comes from `grid`
    /// (`SourceGrid`): the stream's frames from its start, on the decoder's own clock where the
    /// bitstream has one (TrueHD), else its count of what it was given since its reset, placed by
    /// every source timestamp the decoder attributes to the run's blocks (`sourcePts`).
    /// `encoderStartFrame`: where the first frame handed to the encoder since the reset sits.
    /// `encoderFramesIn`: frames handed to the encoder since the reset, so the next chunk sits at
    /// `encoderStartFrame + encoderFramesIn`. The pipeline stamps the packets; see `wrap`.
    private var grid: SourceGrid?
    /// The stream's first timestamp (source time base, the producer's axis), where continuous
    /// playback puts its first frame: the grid's origin (`setSourceStart`).
    private var sourceStart: Int64?
    /// The decoder started over after a failure. One with a clock is still on it; one that counts its
    /// input counts from zero again, so its run starts over and the next timestamp places it.
    private var runBreakPending = false
    /// No stream start was given, so nothing can be placed; logged once.
    private var reportedNoSourceStart = false
    private var encoderStartFrame: Int64?
    private var encoderFramesIn: Int64 = 0
    /// Where a VOD segment's run puts the encoder's first frame (`startRun(atFrame:segment:)`), until the
    /// run's first placed block anchors it.
    private var runStartFrame: Int64?
    /// Rendered frames still to drop before the encoder: audio an output offset puts before the
    /// timeline's start, cut at the exact frame (`encodePending`).
    private var pendingTrimFrames: Int64 = 0
    /// `setOutputOffset`, in seconds, and in frames once a reset's first push has taken it.
    private var outputOffsetSeconds: Double = 0
    private var outputOffsetFrames: Int64 = 0
    private var drainedAtEOF = false
    /// The decoder reset itself after an internal failure: its offsets count from zero again.
    private var decoderSelfResetsSeen = 0
    /// Feeds in a row that threw, for a rate-limited log and the AE#641 report of a bridge that
    /// keeps failing (a decoder that panics on every unit, a rate the renderer refuses).
    private var consecutiveFeedFailures = 0

    private let opLock = NSLock()
    private var stats = AudioBridge.FeedStats()
    private(set) var outputBytesLifetime: Int64 = 0

    /// `LiveTelemetry.objectAudio`: written on the pump thread for every rendered block, read at 1 Hz
    /// by the telemetry sampler. Behind a lock of its own, so that read never waits for a decode or
    /// an encode holding `opLock`.
    private let activityLock = NSLock()
    private var latestActivity: ObjectAudioActivity?
    var objectAudioActivity: ObjectAudioActivity? { activityLock.withLock { latestActivity } }

    /// AE#641: called once, on the pump thread, when the object decoder has been fed
    /// `silentFeedPacketThreshold` packets in a row without returning a block. The APAC
    /// sample entry is written up front, like FLAC's, so nothing downstream fails on its own and the
    /// session would otherwise play the picture over silence. Set before the producer starts feeding.
    var onDecoderProducedNothing: (@Sendable (AudioBridge.FeedStats) -> Void)?
    private var decodedNothingReported = false

    private static let avNoPTS: Int64 = -0x7FFFFFFFFFFFFFFF - 1

    /// Packets the object decoder may take without a block before it counts as producing nothing.
    /// Not the channel bridge's default 64 (it takes this bound for TrueHD too, AE#786): a TrueHD
    /// packet is one 40-frame access unit, and after a start or resume mid-stream the decoder waits
    /// for the next major sync before its first block. Measured
    /// on Dolby's Unfold demo, that wait was up to 102 access units; at 64 every resume past the
    /// opening seconds was reported as a dead decoder and the session went to `.error` while it
    /// played, ignoring every seek after it. 1200 is a second of TrueHD, still a fraction of a second
    /// of the producer's time. A DTS-HD packet is a 512-frame frame, so for DTS:X it is 12.8 s; the
    /// track was confirmed as DTS:X before the bridge was built, and its decoder outputs from the
    /// third packet after every reset.
    static let silentFeedPacketThreshold = AudioBridge.trueHDSilentFeedPacketThreshold

    /// `objectOutput` (personal builds with `APACObjectOutput`): send the decoder's elements as APAC
    /// objects instead of rendering them into `layout`.
    init(
        srcTimeBase: AVRational,
        layout: SpatialSpeakerLayout,
        decoder: ObjectAudioDecoding,
        bitRate: Int? = nil,
        objectOutput: Bool = false,
        sessionLevels: SessionLevelMeter? = nil
    ) throws {
        self.srcTimeBase = srcTimeBase
        self.layout = layout
        self.decoder = decoder
        levels = sessionLevels ?? SessionLevelMeter(layout: layout, sampleRate: Self.sampleRate)
        ownsLevels = sessionLevels == nil
        announces = sessionLevels == nil
        limiter = PeakLimiter(sampleRate: Self.sampleRate, channels: layout.channelCount)
        let encoder: any APACChunkEncoding
        let channels: Int
        let rate: Int
#if APACObjectOutput
        self.objectOutput = objectOutput
        if objectOutput {
            // Coded to quality per object (`APACObjectEncoder.objectBitRate`), the stream's rate follows
            // the content; this is what the playlist declares as its peak (Unfold peaks at 10.3 Mbit/s).
            rate = bitRate ?? (APACObjectEncoder.objectSlots + 1) * APACObjectEncoder.objectBitRate
            let objects = try APACObjectEncoder(bitRate: rate, sampleRate: Double(Self.sampleRate))
            objects.followRoute()
            if sessionLevels == nil {
                EngineLog.emit("[SpatialAudioBridge] objects rendered for a \(objects.output.rawValue) output", category: .session)
            }
            encoder = objects
            channels = APACObjectEncoder.elementCapacity
            // Advertised as the 7.1.4 channel tier the HDMI route renders it to, not the stream's own
            // profile and level (`objects.hlsCodecs`, apac.05.00). On a tvOS 27.2 Apple TV the object
            // stream announced as apac.05.00 reached the receiver as multichannel PCM, where the 7.1.4
            // bed (apac.31.03) and the same objects played from a file (no playlist) reached it as Dolby
            // MAT: APAC levels are channel-count tiers, level 0 the stereo one, and the player decides on
            // MAT for HLS from the playlist (MediaToolbox's HLS Atmos selection, HasAtmosAlternates /
            // AtmosIsSupported) before it reads the stream. The decoder takes the scene from the dapa box.
            hlsCodecs = APACSampleEntry.codecsString(channelCount: Self.objectAnnouncedLayout.channelCount)
        } else {
            rate = bitRate ?? layout.channelCount * Self.bitRatePerChannel
            encoder = try APACEncoder(layout: layout, sampleRate: Double(Self.sampleRate), bitRate: rate)
            channels = layout.channelCount
            hlsCodecs = APACSampleEntry.codecsString(channelCount: layout.channelCount)
        }
#else
        precondition(!objectOutput, "object output is only built with the APACObjectOutput trait")
        rate = bitRate ?? layout.channelCount * Self.bitRatePerChannel
        encoder = try APACEncoder(layout: layout, sampleRate: Double(Self.sampleRate), bitRate: rate)
        channels = layout.channelCount
        hlsCodecs = APACSampleEntry.codecsString(channelCount: layout.channelCount)
#endif
        // Constant mode holds the target; the sync packets each add about a packet (`APACEncoder.peakBitRate`).
        peakOutputBitRate = Int64(APACEncoder.peakBitRate(target: rate))
        let pipeline = APACEncodePipeline(
            encoder: encoder, channels: channels, bufferFrames: Self.encodeChunkFrames * 4)
        self.pipeline = pipeline
        output = pipeline.takeInitialBuffer()
        soundSampleEntryOverride = APACSampleEntry.sampleEntry(
            magicCookie: encoder.magicCookie, sampleRate: Self.sampleRate)
        guard let cp = Self.makeStandInCodecpar() else { throw BridgeError.codecparAllocFailed }
        encoderCodecpar = cp
        guard announces else { return }
        EngineLog.emit(
            "[SpatialAudioBridge] init: \(objectOutput ? "objects (\(channels - 1) slots + LFE, stream \(APACSampleEntry.codecsString(magicCookie: encoder.magicCookie) ?? "?"))" : "layout=\(layout.rawValue)") "
            + "bitRate=\(rate / 1000) kbps codecs=\(hlsCodecs) priming=\(encoder.leadingFrames) frames",
            category: .session
        )
    }

    deinit { cleanup() }

    /// ALAC, 2 channels, 48 kHz, 1024-frame packets: a stream movenc writes from parameters alone and
    /// never inspects the packets of. Its sample entry is replaced wholesale, so only the timing
    /// fields matter to anything downstream.
    private static func makeStandInCodecpar() -> UnsafeMutablePointer<AVCodecParameters>? {
        guard let cp = avcodec_parameters_alloc() else { return nil }
        cp.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        cp.pointee.codec_id = AV_CODEC_ID_ALAC
        cp.pointee.sample_rate = Int32(sampleRate)
        cp.pointee.frame_size = Int32(APACEncoder.framesPerPacket)
        cp.pointee.bits_per_raw_sample = 16
        cp.pointee.bits_per_coded_sample = 16
        av_channel_layout_default(&cp.pointee.ch_layout, 2)
        // A well-formed 36-byte ALAC `alac` atom (ALACSpecificConfig), so movenc writes a sane box.
        var cookie: [UInt8] = [0, 0, 0, 36] + Array("alac".utf8) + [0, 0, 0, 0]
        cookie += [0, 0, 4, 0]                  // frameLength 1024
        cookie += [0, 16, 40, 10, 14, 2]        // compatibleVersion, bitDepth, pb, mb, kb, numChannels
        cookie += [0, 255]                      // maxRun
        cookie += [0, 0, 0, 0, 0, 0, 0, 0]      // maxFrameBytes, avgBitRate
        cookie += [0, 0, 0xBB, 0x80]            // sampleRate 48000
        if let extradata = av_mallocz(cookie.count + Int(AV_INPUT_BUFFER_PADDING_SIZE))?
            .assumingMemoryBound(to: UInt8.self) {
            extradata.update(from: cookie, count: cookie.count)
            cp.pointee.extradata = extradata
            cp.pointee.extradata_size = Int32(cookie.count)
        }
        return cp
    }

    // MARK: - AudioTranscodingBridge

    var feedStats: AudioBridge.FeedStats { stats }
    var fifoSampleCount: Int { 0 }
    var liveBytes: AudioBridge.LiveBytes {
        AudioBridge.LiveBytes(fifoSamples: 0, fifoBytes: 0, swrDelaySamples: 0, swrDelayBytes: 0)
    }

    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        var results: [UnsafeMutablePointer<AVPacket>] = []
        wrap(feedLocked(packet: packet), into: &results)
        return results
    }

    /// `feed` without the muxer's packets: the encoder's own, each with its place in its encoder run, for a
    /// consumer that states the priming itself (`APACSampleBufferDecoder`).
    func feedStamped(packet: UnsafePointer<AVPacket>) -> [APACEncodePipeline.StampedPacket] {
        opLock.lock()
        defer { opLock.unlock() }
        let stamped = feedLocked(packet: packet)
        noteEmitted(stamped)
        return stamped
    }

    /// Caller holds `opLock`.
    private func feedLocked(packet: UnsafePointer<AVPacket>) -> [APACEncodePipeline.StampedPacket] {
        stats.packetsFed += 1
        stats.packetsFedSinceLastEnqueue += 1
        // Every exit: a decoder that rejects each packet has decoded nothing too.
        defer { noteDecodedNothingIfNeeded() }

        guard let data = packet.pointee.data, packet.pointee.size > 0 else { return [] }
        let ts = packet.pointee.pts != Self.avNoPTS ? packet.pointee.pts : packet.pointee.dts
        do {
            try decoder.push(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)), pts: ts)
        } catch {
            stats.packetsRejected += 1
            noteDecoderSelfReset()
            noteFeedFailure(error)
            var results: [APACEncodePipeline.StampedPacket] = []
            // This feed has already counted as failed.
            collectEncoded(into: &results, noteFailure: false)
            return results
        }
        // Packets already stamped stay in the result when a later block of the same packet fails:
        // their timestamps are right, and dropping them would leave a hole the source never had.
        var results: [APACEncodePipeline.StampedPacket] = []
        do {
            while let block = try decoder.nextBlock() {
                stats.framesDecoded += 1
                try renderAndEncode(block, into: &results)
            }
            consecutiveFeedFailures = 0
        } catch {
            stats.decodeErrors += 1
            noteDecoderSelfReset()
            noteFeedFailure(error)
        }
        collectEncoded(into: &results)
        return results
    }

    /// Caller holds `opLock`. After the decoder reset itself, the bytes of the failing packet are gone
    /// and its offsets restart at zero: anchor again on the next packet it takes.
    private func noteDecoderSelfReset() {
        guard decoder.selfResetCount != decoderSelfResetsSeen else { return }
        decoderSelfResetsSeen = decoder.selfResetCount
        runBreakPending = true
    }

    /// Caller holds `opLock`. The first failure and every `silentFeedPacketThreshold`th after it are
    /// logged; a run that long is reported once as a bridge that produces nothing.
    private func noteFeedFailure(_ error: Error) {
        consecutiveFeedFailures += 1
        if consecutiveFeedFailures == 1 || consecutiveFeedFailures % Self.silentFeedPacketThreshold == 0 {
            EngineLog.emit(
                "[SpatialAudioBridge] feed failed (\(consecutiveFeedFailures) in a row): \(error)",
                category: .session)
        }
        guard !decodedNothingReported,
              consecutiveFeedFailures >= Self.silentFeedPacketThreshold else { return }
        // One latch with the decoded-nothing report: a decoder that refuses every packet is both.
        decodedNothingReported = true
        EngineLog.emit(
            "[SpatialAudioBridge] ERROR: AE#641 every feed has failed for \(consecutiveFeedFailures) packets: "
            + "\(stats.summary)", category: .session)
        onDecoderProducedNothing?(stats)
    }

    /// Caller holds `opLock`.
    private func noteDecodedNothingIfNeeded() {
        guard !decodedNothingReported, stats.decodedNothing,
              stats.packetsFedSinceLastEnqueue >= Self.silentFeedPacketThreshold else { return }
        decodedNothingReported = true
        EngineLog.emit(
            "[SpatialAudioBridge] ERROR: AE#641 the object decoder has produced nothing: "
            + "\(stats.summary)", category: .session)
        onDecoderProducedNothing?(stats)
    }

    func settle() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        var stamped: [APACEncodePipeline.StampedPacket] = []
        // Audio the decoder holds for metadata sits before the cut; released here, the cut sees what
        // it saw before the hold existed, rather than up to 100 ms of it landing in the next segment.
        renderHeldBlocks(into: &stamped)
        let settled = pipeline.settle()
        stamped += settled.packets
        noteEncodeErrors(settled.errors)
        var results: [UnsafeMutablePointer<AVPacket>] = []
        wrap(stamped, into: &results)
        return results
    }

    func flush() -> [UnsafeMutablePointer<AVPacket>] {
        opLock.lock()
        defer { opLock.unlock() }
        guard !drainedAtEOF else { return [] }
        drainedAtEOF = true
        var stamped: [APACEncodePipeline.StampedPacket] = []
        // Audio the decoder held back for metadata that never came plays as it is.
        renderHeldBlocks(into: &stamped)
        drainSplitter()
        encodePending()
        drainLimiter()
        restartLevels()
        let finished = pipeline.finish()
        stamped += finished.packets
        noteEncodeErrors(finished.errors)
        var results: [UnsafeMutablePointer<AVPacket>] = []
        wrap(stamped, into: &results)
        if !results.isEmpty {
            EngineLog.emit("[SpatialAudioBridge] EOF flush emitted \(results.count) tail packet(s)", category: .session)
        }
        return results
    }

    func startSegment() {
        opLock.lock()
        defer { opLock.unlock() }
        decoder.reset()
        renderer?.reset()
        rendererRunPending = true
#if TrueHDObjectAudio
        splitter?.reset()
        splitterStartsFresh = true
#endif
        pipeline.reset()
        limiter.reset()
        restartLevels()
        pendingFrames = 0
#if APACObjectOutput
        output.objectUpdates.removeAll(keepingCapacity: true)
        output.objectDiscontinuities.removeAll(keepingCapacity: true)
#endif
        grid?.restart()
        runBreakPending = false
        encoderStartFrame = nil
        encoderFramesIn = 0
        pendingTrimFrames = 0
        drainedAtEOF = false
        decoderSelfResetsSeen = decoder.selfResetCount
        consecutiveFeedFailures = 0
    }

    func startRun(atFrame frame: Int64, segment: Range<Int64>) {
        opLock.lock()
        defer { opLock.unlock() }
        runStartFrame = frame
        measuring = segment
    }

    func setOutputOffset(seconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        outputOffsetSeconds = seconds
    }

    func setSourceStart(_ pts: Int64?) {
        opLock.lock()
        defer { opLock.unlock() }
        guard pts != sourceStart else { return }
        sourceStart = pts
        grid = nil
    }

    func noteTimelineJump(deltaSeconds: Double) {
        opLock.lock()
        defer { opLock.unlock() }
        guard deltaSeconds > 0, let start = encoderStartFrame else { return }
        let frames = Int64((deltaSeconds * Double(Self.sampleRate)).rounded())
        encoderStartFrame = start + frames
        pipeline.shift(by: frames)
    }

    func close() {
        opLock.lock()
        defer { opLock.unlock() }
        // A viewer who hears no heights stops playback: the window they stopped in is the one to log.
        restartLevels()
        pipeline.close()
        cleanup()
    }

    private func cleanup() {
        if encoderCodecpar != nil { avcodec_parameters_free(&encoderCodecpar) }
    }

    // MARK: - Pipeline

    /// Caller holds `opLock`.
    private func renderHeldBlocks(into results: inout [APACEncodePipeline.StampedPacket]) {
        decoder.releaseHeldBlocks()
        do {
            while let block = try decoder.nextBlock() {
                stats.framesDecoded += 1
                try renderAndEncode(block, into: &results)
            }
        } catch {
            EngineLog.emit("[SpatialAudioBridge] drain of held blocks failed: \(error)", category: .session)
        }
    }

    private func renderAndEncode(_ block: ObjectAudioDecodedBlock, into results: inout [APACEncodePipeline.StampedPacket]) throws {
        guard block.sampleRate == Self.sampleRate else { throw BridgeError.unsupportedSampleRate(block.sampleRate) }
        guard block.frameCount > 0 else { return }

        let rebuilt = renderer == nil || block.configurationGeneration != rendererGeneration
        if rebuilt, announces || renderer != nil {
            // Whether the presentation has an LFE element at all is the first question a missing-LFE
            // report asks.
            EngineLog.emit(
                "[SpatialAudioBridge] object configuration\(renderer == nil ? "" : " changed, renderer rebuilt"): "
                    + BedLevelMeter.configurationSummary(block.roles),
                category: .session
            )
        }
        if rebuilt {
            renderer = ObjectAudioRenderer(layout: layout, roles: block.roles)
            rendererGeneration = block.configurationGeneration
            rendererRunPending = true
        } else if block.isDiscontinuity {
            renderer?.markDiscontinuity()
        }
        // Every block plays where the grid puts it: the encoder is anchored on the first, and a gap
        // the decoder skipped (corrupt access units) is filled with silence so everything after it
        // stays on its frame. Nothing says where a block plays before the run's first timestamp, so
        // until then it is dropped rather than placed at a guess.
        let placed = position(of: block)
        let offset = Int64((outputOffsetSeconds * Double(Self.sampleRate)).rounded())
        if measuring.map({ range in placed.map { range.contains($0 + offset) } ?? false }) ?? true {
            let activity = levels.with { meter in
                meter.observe(roles: block.roles, updates: block.updates, configurationChanged: rebuilt)
                meter.measureInput(roles: block.roles, planes: block.planes, frameCount: block.frameCount)
                return meter.activity
            }
            activityLock.withLock { latestActivity = activity }
        }
        guard let position = placed else {
            stats.blocksDroppedUnplaced += 1
            return
        }
        if encoderStartFrame == nil {
            outputOffsetFrames = Int64((outputOffsetSeconds * Double(Self.sampleRate)).rounded())
            if let runStart = runStartFrame {
                runStartFrame = nil
                anchorRun(at: runStart, firstBlockAt: position + outputOffsetFrames)
            } else {
                anchor(at: position + outputOffsetFrames)
            }
        } else {
            place(at: position + outputOffsetFrames)
        }

#if APACObjectOutput
        if objectOutput {
            stageObjects(block, discontinuity: block.isDiscontinuity && !rebuilt)
            stats.samplesEnqueued += Int64(block.frameCount)
            stats.packetsFedSinceLastEnqueue = 0
            if pendingFrames >= Self.encodeChunkFrames { encodePending() }
            return
        }
#endif
        output.ensureCapacity(pendingFrames + block.frameCount, keeping: pendingFrames)
#if TrueHDObjectAudio
        if let bed = block.bed {
            if splitter?.bedRoles != bed.roles {
                drainSplitter()
                output.ensureCapacity(pendingFrames + block.frameCount, keeping: pendingFrames)
                if announces || splitter != nil {
                    EngineLog.emit(
                        "[SpatialAudioBridge] every output from the stream's \(bed.roles.count)-channel presentation, "
                        + "split by the objects' energy (latency \(BedSplitter.latency) frames)",
                        category: .session)
                }
                splitter = BedSplitter(layout: layout, bedRoles: bed.roles)
                splitterStartsFresh = true
            }
            if splitterStartsFresh, let grid {
                splitterStartsFresh = false
                splitter!.reset(phase: Int((position - grid.origin) % Int64(BedSplitter.hop)))
            }
            // Up to each hop boundary in turn, so the splitter reads the gains as they are on the
            // hop's last frame, mid-ramp included, not as they are at the end of the block.
            var start = 0
            while start < block.frameCount {
                let count = min(block.frameCount - start, splitter!.framesUntilHop)
                let last = start + count == block.frameCount
                let updates = block.updates.filter { $0.frameOffset >= start && ($0.frameOffset < start + count || last) }
                    .map { u -> ObjectAudioMetadataUpdate in var u = u; u.frameOffset -= start; return u }
                renderer!.advance(frameCount: count, updates: updates)
                renderer!.snapshot(into: &gainSnapshot)
                splitter!.setGains(gainSnapshot)
                pendingFrames += splitter!.process(
                    elements: block.planes.map { $0 + start }, bed: bed.planes.map { $0 + start }, frameCount: count,
                    output: output.planes.map { $0 + pendingFrames })
                start += count
            }
        } else if let splitter {
            // A block without its bed in a stream that has one: silence on the bed's timeline.
            renderer!.advance(frameCount: block.frameCount, updates: block.updates)
            pendingFrames += splitter.process(
                elements: nil, bed: nil, frameCount: block.frameCount,
                output: output.planes.map { $0 + pendingFrames })
        } else if decoder.playsBedOnly {
            // No bed yet: silence, never a mix of the object signals.
            renderer!.advance(frameCount: block.frameCount, updates: block.updates)
            for plane in output.planes { (plane + pendingFrames).update(repeating: 0, count: block.frameCount) }
            pendingFrames += block.frameCount
        } else {
            renderer!.render(
                inputs: block.planes, frameCount: block.frameCount, updates: block.updates,
                outputs: output.planes.map { $0 + pendingFrames })
            pendingFrames += block.frameCount
        }
#else
        renderer!.render(
            inputs: block.planes, frameCount: block.frameCount, updates: block.updates,
            outputs: output.planes.map { $0 + pendingFrames })
        pendingFrames += block.frameCount
#endif
        noteRendererSettling(blockAt: position, frames: block.frameCount)
        stats.samplesEnqueued += Int64(block.frameCount)
        stats.packetsFedSinceLastEnqueue = 0
        if pendingFrames >= Self.encodeChunkFrames { encodePending() }
    }

    /// Log where the renderer settles, once per run.
    private func noteRendererSettling(blockAt position: Int64, frames: Int) {
        if rendererRunPending {
            rendererRunPending = false
            rendererSettlingFrom = position
        }
        guard let from = rendererSettlingFrom, renderer?.isSettled == true else { return }
        rendererSettlingFrom = nil
        let end = position + Int64(frames)
        EngineLog.emit(
            String(format: "[SpatialAudioBridge] render settled by %.3f s, %.3f s after its run began",
                   Double(end) / Double(Self.sampleRate), Double(end - from) / Double(Self.sampleRate)),
            category: .session)
    }

#if APACObjectOutput
    /// The block's elements into `output` as they are, and its metadata beside them for the encoder.
    /// A chunk holds one presentation, so a new one starts a new chunk.
    private func stageObjects(_ block: ObjectAudioDecodedBlock, discontinuity: Bool) {
        if block.roles != objectRoles {
            if pendingFrames > 0 { encodePending() }
            objectRoles = block.roles
            output.objectRoles = block.roles
        }
        let n = block.frameCount
        output.ensureCapacity(pendingFrames + n, keeping: pendingFrames)
        for (i, plane) in output.planes.enumerated() {
            if i < block.planes.count {
                (plane + pendingFrames).update(from: block.planes[i], count: n)
            } else {
                (plane + pendingFrames).update(repeating: 0, count: n)
            }
        }
        if discontinuity { output.objectDiscontinuities.append(pendingFrames) }
        for update in block.updates {
            var shifted = update
            shifted.frameOffset += pendingFrames
            output.objectUpdates.append(shifted)
        }
        pendingFrames += n
    }
#endif

    /// Caller holds `opLock`. Where `block` plays on the source timeline (48 kHz frames), or nil
    /// while its run has had no timestamp.
    private func position(of block: ObjectAudioDecodedBlock) -> Int64? {
        if grid == nil {
            guard let sourceStart else {
                if !reportedNoSourceStart {
                    reportedNoSourceStart = true
                    EngineLog.emit("[SpatialAudioBridge] ERROR: no stream start, so no block can be placed",
                                   category: .session)
                }
                return nil
            }
            grid = SourceGrid(origin: av_rescale_q(sourceStart, srcTimeBase, encoderTimeBase),
                              step: Int64(block.gridFrames),
                              tolerance: AudioContinuity.tolerance(sourceTimeBase: srcTimeBase, sampleRate: Int32(Self.sampleRate)))
        }
        if runBreakPending {
            runBreakPending = false
            if block.clockFrame == nil { grid?.restart() }
        }
        let estimate = block.sourcePts.map {
            av_rescale_q($0, srcTimeBase, encoderTimeBase) + block.inputFrameOffset - block.sourcePtsInputFrame
        }
        let (placement, restarted) = grid!.place(relative: block.clockFrame ?? block.inputFrameOffset, estimate: estimate)
        if restarted {
            // A timestamp no grid point of the run allows: the stream was cut here.
            stats.timestampMismatches += 1
            if stats.timestampMismatches == 1 || stats.timestampMismatches % 1000 == 0 {
                EngineLog.emit(
                    "[SpatialAudioBridge] a source timestamp left the run's grid (a splice); placed anew "
                    + "(\(stats.timestampMismatches) so far)", category: .session)
            }
        }
        guard case .position(let at) = placement else { return nil }
        return at
    }

    /// Continue the encoder's input at `target` (a source position in 48 kHz frames): a short gap
    /// ahead is filled with silence, anything longer or behind restarts the encoder there, so every
    /// later packet keeps its source position.
    private func place(at target: Int64) {
        guard let start = encoderStartFrame else { return }
        let end = runningEnd(from: start)
        let gap = target - end
        if gap == 0 { return }
        if gap > 0, gap <= Int64(Self.maxSilenceFillFrames) {
            encodeSilence(frames: Int(gap))
            return
        }
        drainSplitter()
        encodePending()
        drainLimiter()
        pipeline.restart()
        limiter.reset()
        anchor(at: target)
        EngineLog.emit(
            "[SpatialAudioBridge] encoder re-anchored \(String(format: "%+.3f", Double(gap) / Double(Self.sampleRate))) s "
            + "off its running position", category: .session)
    }

    /// Where the next frame taken from the decoder plays.
    private func runningEnd(from start: Int64) -> Int64 {
        start + encoderFramesIn + Int64(pendingFrames + heldBack) - pendingTrimFrames
    }

    /// Start an encoder run at `position`. Never below zero: `baseMediaDecodeTime` is unsigned
    /// (AE#561), and an APAC packet cut from the front would take its priming with it, so audio
    /// before the timeline's start comes off the rendered frames instead.
    private func anchor(at position: Int64) {
        encoderStartFrame = max(position, 0)
        encoderFramesIn = 0
        pendingTrimFrames = max(-position, 0)
    }

    /// Start a segment's run with the encoder at `start` whatever the first block is: audio rendered
    /// before it only settles the renderer, splitter and limiter and comes off; a stream that begins
    /// after it is preceded by silence.
    private func anchorRun(at start: Int64, firstBlockAt position: Int64) {
        encoderStartFrame = start
        encoderFramesIn = 0
        pendingTrimFrames = max(start - position, 0)
        if position > start { encodeSilence(frames: Int(position - start)) }
    }

    /// The longest gap filled with silence rather than by restarting the encoder.
    private static let maxSilenceFillFrames = sampleRate * 5

    /// In chunks, like rendered audio: a 5 s fill handed over in one piece would hold the encoder
    /// for its whole length and grow every pooled buffer to it.
    private func encodeSilence(frames: Int) {
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, max(Self.encodeChunkFrames - pendingFrames, 0))
            if n == 0 { encodePending(); continue }
            output.ensureCapacity(pendingFrames + n, keeping: pendingFrames)
#if TrueHDObjectAudio
            if let splitter {
                pendingFrames += splitter.process(
                    elements: nil, bed: nil, frameCount: n, output: output.planes.map { $0 + pendingFrames })
                remaining -= n
                if pendingFrames >= Self.encodeChunkFrames { encodePending() }
                continue
            }
#endif
            for plane in output.planes { (plane + pendingFrames).update(repeating: 0, count: n) }
            pendingFrames += n
            remaining -= n
            if pendingFrames >= Self.encodeChunkFrames { encodePending() }
        }
    }

    /// The frames the splitter still holds, into `output`: before the encoder restarts somewhere else
    /// or the input ends, so the audio up to there plays in full.
    private func drainSplitter() {
#if TrueHDObjectAudio
        splitterStartsFresh = true
        guard let splitter, splitter.backlog > 0 else { return }
        output.ensureCapacity(pendingFrames + splitter.backlog, keeping: pendingFrames)
        pendingFrames += splitter.drain(output: output.planes.map { $0 + pendingFrames })
#endif
    }

    /// Hand the rendered frames to the encoder's queue. Its packets come back through
    /// `collectEncoded` on a later call.
    private func encodePending() {
        guard pendingFrames > 0 else { return }
        var frames = pendingFrames
        pendingFrames = 0
        guard encoderStartFrame != nil else { return }
        if pendingTrimFrames > 0 {
            let cut = Int(min(pendingTrimFrames, Int64(frames)))
            pendingTrimFrames -= Int64(cut)
            frames -= cut
            for plane in output.planes where frames > 0 {
                memmove(plane, plane + cut, frames * MemoryLayout<Float>.stride)
            }
#if APACObjectOutput
            // Metadata from the cut frames still holds where the frames kept begin.
            for i in output.objectUpdates.indices {
                output.objectUpdates[i].frameOffset = max(output.objectUpdates[i].frameOffset - cut, 0)
            }
            output.objectDiscontinuities = output.objectDiscontinuities.map { max($0 - cut, 0) }
#endif
            if frames == 0 { return }
        }
#if APACObjectOutput
        if objectOutput, let start = encoderStartFrame {
            let position = start + encoderFramesIn
            // No bed to measure, but the objects and the LFE input still get their line.
            if let measured = measured(position: position, frames: frames) {
                logLevels(levels.with { $0.addUnmeasured(frameCount: measured.count,
                                                         startSeconds: Double(measured.lowerBound) / Double(Self.sampleRate)) })
            }
            output = pipeline.submit(output, frames: frames, position: position)
            // The free buffer handed back still holds the chunk it last carried.
            output.objectRoles = objectRoles
            output.objectUpdates.removeAll(keepingCapacity: true)
            output.objectDiscontinuities.removeAll(keepingCapacity: true)
            encoderFramesIn += Int64(frames)
            return
        }
#endif
        submitLimited(limiter.process(output.planes, frameCount: frames, lfe: layout.lfeIndex))
    }

    /// The frames the limiter still holds, to the encoder: before it restarts somewhere else or the
    /// input ends, so the audio up to there plays in full. `output` is empty here.
    private func drainLimiter() {
        guard limiter.backlog > 0, encoderStartFrame != nil else { return }
        output.ensureCapacity(limiter.backlog, keeping: 0)
        submitLimited(limiter.drain(into: output.planes, lfe: layout.lfeIndex))
    }

    /// The first `frames` of `output`, which the limiter has handed on, to the encoder's queue.
    private func submitLimited(_ frames: Int) {
        guard frames > 0, let start = encoderStartFrame else { return }
        let position = start + encoderFramesIn
        // Where this chunk plays, for the level line: the anchor is a source PTS in 48 kHz frames.
        if let measured = measured(position: position, frames: frames) {
            let skip = Int(measured.lowerBound - position)
            logLevels(levels.with { $0.add(output.planes.map { UnsafePointer($0 + skip) }, frameCount: measured.count,
                                           startSeconds: Double(measured.lowerBound) / Double(Self.sampleRate)) })
        }
        output = pipeline.submit(output, frames: frames, position: position)
        encoderFramesIn += Int64(frames)
    }

    /// Caller holds `opLock`. Everything the encoder has finished since the last call.
    private func collectEncoded(into results: inout [APACEncodePipeline.StampedPacket], noteFailure: Bool = true) {
        let encoded = pipeline.collect()
        results += encoded.packets
        noteEncodeErrors(encoded.errors, noteFailure: noteFailure)
    }

    /// Caller holds `opLock`. A failed chunk is a gap the pipeline already stepped over; it counts
    /// as a failed feed for the log.
    private func noteEncodeErrors(_ errors: [Error], noteFailure: Bool = true) {
        guard let first = errors.first else { return }
        stats.encodeErrors += errors.count
        if noteFailure { noteFeedFailure(first) }
    }

    /// The frames of a chunk at `position` this bridge measures: all of them, or those of its segment.
    private func measured(position: Int64, frames: Int) -> Range<Int64>? {
        let chunk = position..<(position + Int64(frames))
        guard let measuring else { return chunk }
        let kept = chunk.clamped(to: measuring)
        return kept.isEmpty ? nil : kept
    }

    /// The session meter's open window, if this bridge owns it: on a seek, the end of input or
    /// teardown. A segment's run leaves the session's to the session.
    private func restartLevels() {
        guard ownsLevels else { return }
        logLevels(levels.with { $0.restart() })
    }

    /// The level line, with the limiter's work over the same window when it had any.
    private func logLevels(_ line: String?) {
        guard let line else { return }
        let limited = limiter.takeLimitedFrames()
        let limiterNote = limited.frames > 0
            ? String(format: "; limiter reduced %d frames, deepest %.1f dB", limited.frames, limited.deepestDB)
            : ""
        EngineLog.emit("[SpatialAudioBridge] \(line)\(limiterNote)", category: .session)
    }

    /// Wrap stamped encoder packets for the muxer. The pipeline stamps packet k of an encoder run
    /// at the run's first position plus k·1024, the encoder's priming packets included, because
    /// AVFoundation presents an APAC packet's audio `leadingFrames` (2048) before its timestamp: it
    /// counts the priming as part of the stream, the way AVAssetWriter writes it. So the priming
    /// packets take the anchor's timestamp, their output falls before it and is never heard, and the
    /// first content frame plays on the source position. Dropping them and stamping the first
    /// content packet on the anchor played every session 2048 frames (42.7 ms) ahead of the video,
    /// at load and after every seek (AVPlayer over HLS on macOS 27, with 5.1 APAC since macOS rejects
    /// 7.1.4, against an ALAC reference; AVAssetReader shows the same 2048 frames for 7.1.4).
    private func wrap(_ packets: [APACEncodePipeline.StampedPacket], into results: inout [UnsafeMutablePointer<AVPacket>]) {
        let frames = Int64(APACEncoder.framesPerPacket)
        for packet in packets {
            guard let avpkt = trackedPacketAlloc() else { continue }
            guard av_new_packet(avpkt, Int32(packet.data.count)) >= 0 else {
                var p: UnsafeMutablePointer<AVPacket>? = avpkt
                trackedPacketFree(&p)
                continue
            }
            packet.data.withUnsafeBytes { raw in
                avpkt.pointee.data.update(from: raw.bindMemory(to: UInt8.self).baseAddress!, count: packet.data.count)
            }
            avpkt.pointee.pts = packet.pts
            avpkt.pointee.dts = packet.pts
            avpkt.pointee.duration = frames
            if packet.isSync { avpkt.pointee.flags |= AV_PKT_FLAG_KEY }
            results.append(avpkt)
        }
        noteEmitted(packets)
    }

    private func noteEmitted(_ packets: [APACEncodePipeline.StampedPacket]) {
        for packet in packets { outputBytesLifetime += Int64(packet.data.count) }
        stats.packetsEmitted += packets.count
    }
}
#endif
