import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

/// Personal builds only, with the APACObjectOutput trait: with this environment variable set to 1,
/// TrueHD Atmos elements are sent to APAC as positioned objects (`APACObjectEncoder`) rather than
/// rendered into the layout. Without the trait it is always off and that path is not built.
enum APACObjectOutputSwitch {
    static let variable = "AETHER_APAC_OBJECTS"
    static var isOn: Bool {
        #if APACObjectOutput
        ProcessInfo.processInfo.environment[variable] == "1"
        #else
        false
        #endif
    }
}

extension HLSVideoEngine {

    /// The object-audio format a source would be rendered as, before it is confirmed.
    enum ObjectAudioSource: Equatable {
        /// TrueHD that FFmpeg marked Atmos.
        case trueHDAtmos
        /// Lossless DTS-HD Master Audio, which may carry DTS:X whatever the probe's label says, so its
        /// first decoded frame decides (see `dtsxVerdict`).
        case dtsHDMasterAudio

        /// How the log and the pipeline description name it.
        var name: String {
            switch self {
            case .trueHDAtmos: return "TrueHD Atmos"
            case .dtsHDMasterAudio: return "DTS:X"
            }
        }

        /// Whether this build carries the source's decoder (its package trait). Without it the source
        /// keeps the channel bridge whatever `objectAudioRendering` asks.
        var isBuiltIn: Bool {
            switch self {
            case .trueHDAtmos: return AetherEngine.linksTrueHDObjectDecoder
            case .dtsHDMasterAudio: return AetherEngine.linksDTSXObjectDecoder
            }
        }

        var traitName: String {
            switch self {
            case .trueHDAtmos: return "TrueHDObjectAudio"
            case .dtsHDMasterAudio: return "DTSXObjectAudio"
            }
        }
    }

    /// The bed a source should be rendered into, or nil to keep the ordinary bridge.
    ///
    /// TrueHD only when FFmpeg marked the stream Atmos (`AV_PROFILE_TRUEHD_ATMOS`, which mlpdec sets
    /// from the major sync while the probe decodes a frame): a TrueHD track without an object
    /// presentation gains nothing from rendering and would lose its lossless 7.1 for it. DTS when it
    /// is DTS-HD Master Audio, with or without FFmpeg's DTS:X label: FFmpeg names only two of DTS:X's
    /// markers, so the label misses some DTS:X, and a DTS-HD MA track that turns out not to be DTS:X
    /// is refused before the bridge is built (`buildSpatialAudioProducerIfEligible`). 48 kHz, or not
    /// yet known, since TrueHD reports its rate from the first frame and both formats are only ever
    /// authored at 48 kHz. Nil as well when the build lacks the source's decoder trait, and for DTS
    /// when the layout does not carry DTS:X's 7.1 bed and four heights one to one (see
    /// `SpatialSpeakerLayout.carriesDTSXOneToOne`).
    static func spatialRenderingLayout(
        rendering: ObjectAudioRendering,
        codecID: AVCodecID,
        profile: Int32,
        sampleRate: Int32
    ) -> SpatialSpeakerLayout? {
        // TrueHD at 96 or 192 kHz is brought to 48 kHz after decoding (`ObjectAudioDecimator`).
        let rates = codecID == AV_CODEC_ID_TRUEHD ? [0, 48_000, 96_000, 192_000] : [0, 48_000]
        guard let layout = rendering.layout, layout.isBed,
              objectAudioSource(codecID: codecID, profile: profile)?.isBuiltIn == true,
              rates.contains(Int(sampleRate))
        else { return nil }
        if objectAudioSource(codecID: codecID, profile: profile) == .dtsHDMasterAudio,
           !layout.carriesDTSXOneToOne {
            return nil
        }
        return layout
    }

    /// Whether the probe alone says the track will play as APAC, so the Atmos activator can be on the HDMI link
    /// before the display switch: TrueHD Atmos, and DTS-HD MA whose profile names DTS:X. A DTS-HD MA track the
    /// probe does not label X may still be DTS:X; its first decoded frame decides that at routing, after the
    /// criteria are written.
    static func probeAnticipatesAPAC(rendering: ObjectAudioRendering, codecID: AVCodecID,
                                     profile: Int32, sampleRate: Int32) -> Bool {
        guard spatialRenderingLayout(rendering: rendering, codecID: codecID, profile: profile,
                                     sampleRate: sampleRate) != nil else { return false }
        switch objectAudioSource(codecID: codecID, profile: profile) {
        case .trueHDAtmos: return true
        case .dtsHDMasterAudio: return profile == AV_PROFILE_DTS_HD_MA_X || profile == AV_PROFILE_DTS_HD_MA_X_IMAX
        case nil: return false
        }
    }

    static func objectAudioSource(codecID: AVCodecID, profile: Int32) -> ObjectAudioSource? {
        switch (codecID, profile) {
        case (AV_CODEC_ID_TRUEHD, AV_PROFILE_TRUEHD_ATMOS):
            return .trueHDAtmos
        case (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA),
             (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA_X),
             (AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA_X_IMAX):
            return .dtsHDMasterAudio
        default:
            return nil
        }
    }

    #if DTSXObjectAudio
    /// Packets of the source's head `dtsxVerdict` may look at. A DTS:X track renders on its first
    /// frame, which the decoder's parser hands over once the second starts, and is refused after
    /// eight frames without heights; a muxed file interleaves those within the first few dozen
    /// packets. The same budget as the planner's head scans bounds a file whose audio starts late.
    static let dtsxVerdictPacketBudget = 512
    /// Bytes the peek may hold. Unlike the planner's scans, peeked packets stay resident until the
    /// producer reads them, video included, so a late-starting track in a 4K remux must not pin
    /// hundreds of megabytes; the frames a verdict needs normally sit within the first few of them.
    static let dtsxVerdictByteBudget = 24 << 20

    /// Shows the DTS:X decoder the audio stream's first packets, without consuming them (the producer reads the
    /// same packets afterwards), until it says whether the track is DTS:X it renders. Nil when a
    /// budget ran out or the source could not be read first.
    func dtsxVerdict(
        decoder: DTSXObjectAudioDecoder,
        demuxer: Demuxer,
        streamIndex: Int32
    ) -> DTSXObjectAudioDecoder.Verdict? {
        var verdict: DTSXObjectAudioDecoder.Verdict?
        var heldBytes = 0
        try? demuxer.peekPackets(maxPackets: Self.dtsxVerdictPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > Self.dtsxVerdictByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
            verdict = decoder.verdict(feeding: UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
            return verdict != nil
        }
        return verdict
    }
    #endif

    /// Packets `resolveUnlabelledTrueHDAtmos` may look at. Sized for a track that starts well after the
    /// probe window: 22 s of a 4K remux interleaved with a second audio track is about 3,000 packets.
    static let trueHDVerdictPacketBudget = 8192
    /// Bytes it may hold. Peeked packets stay resident until the producer reads them, so this is the
    /// worst-case extra memory of a session start; it is paid only by a TrueHD track whose profile the
    /// probe could not read, and the measured case (TrueHD from 22 s, 45.8 MB in) fits.
    static let trueHDVerdictByteBudget = 64 << 20

    /// A TrueHD track the probe never decoded a frame of keeps `AV_PROFILE_UNKNOWN`, which reads as
    /// "not Atmos" everywhere below. When object rendering is wanted, look at the track's own major
    /// sync where the first producer starts, and mark the stream Atmos if it is. Peeks without
    /// consuming (the producer reads the same packets) and leaves the demuxer at the producer start.
    func resolveUnlabelledTrueHDAtmos(
        audioStream: UnsafeMutablePointer<AVStream>,
        audioDemuxer: Demuxer,
        streamIndex: Int32
    ) {
        let par = audioStream.pointee.codecpar.pointee
        guard par.codec_id == AV_CODEC_ID_TRUEHD, par.profile == AV_PROFILE_UNKNOWN,
              objectAudioRendering.layout != nil, ObjectAudioSource.trueHDAtmos.isBuiltIn,
              !isLiveSession
        else { return }
        if audioDemuxer === demuxer {
            seekToInitialProducerStart(audioDemuxer)
            demuxerAtInitialProducerStart = true
        }
        let started = DispatchTime.now()
        var verdict: Bool?
        var heldBytes = 0
        var packets = 0
        try? audioDemuxer.peekPackets(maxPackets: Self.trueHDVerdictPacketBudget) { packet in
            packets += 1
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > Self.trueHDVerdictByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex,
                  let data = packet.pointee.data, packet.pointee.size > 0 else { return false }
            verdict = TrueHDMajorSync.isAtmos(UnsafeRawBufferPointer(start: data, count: Int(packet.pointee.size)))
            return verdict != nil
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        let span = "\(packets) packets, \(heldBytes >> 10) KiB, \(String(format: "%.0f", ms)) ms"
        switch verdict {
        case true?:
            audioStream.pointee.codecpar.pointee.profile = AV_PROFILE_TRUEHD_ATMOS
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD profile was not probed; major sync says Atmos (\(span))",
                category: .session
            )
        case false?:
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD profile was not probed; major sync says no Atmos (\(span))",
                category: .session
            )
        case nil:
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD profile was not probed and no major sync within the budget (\(span)); "
                + "treating it as without Atmos",
                category: .session
            )
        }
    }


    /// Build the producer on a `SpatialAudioBridge` when the host asked for object rendering and the
    /// source qualifies. Nil means "not this route": ineligible, unsupported OS, not DTS:X, or a
    /// bridge/header failure, each logged, and the caller carries on with the ordinary bridge
    /// cascade, so asking for Atmos never costs a session its audio.
    func buildSpatialAudioProducerIfEligible(
        audioStream: UnsafeMutablePointer<AVStream>,
        audioDemuxer: Demuxer,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?
    ) -> HLSSegmentProducer? {
        let par = audioStream.pointee.codecpar.pointee
        guard let layout = Self.spatialRenderingLayout(
            rendering: objectAudioRendering, codecID: par.codec_id,
            profile: par.profile, sampleRate: par.sample_rate),
              let source = Self.objectAudioSource(codecID: par.codec_id, profile: par.profile)
        else {
            if objectAudioRendering != .off,
               let source = Self.objectAudioSource(codecID: par.codec_id, profile: par.profile),
               !source.isBuiltIn {
                EngineLog.emit(
                    "[HLSVideoEngine] \(source.name) rendering requested but not built in (\(source.traitName) "
                    + "trait off); keeping the channel bridge",
                    category: .session
                )
            } else if par.codec_id == AV_CODEC_ID_TRUEHD {
                if objectAudioRendering != .off {
                    EngineLog.emit(
                        "[HLSVideoEngine] object rendering requested but TrueHD is not Atmos at 48, 96 or 192 kHz "
                        + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                        category: .session
                    )
                } else if par.profile == AV_PROFILE_TRUEHD_ATMOS {
                    // The host's choice, not a failure, but the one a missing-heights report turns on:
                    // the channel bridge plays the 7.1 presentation, where the objects are mixed into
                    // the floor channels.
                    EngineLog.emit(
                        "[HLSVideoEngine] TrueHD Atmos with objectAudioRendering off; the channel bridge "
                        + "carries the 7.1 presentation, with the objects mixed into the floor channels",
                        category: .session
                    )
                }
            } else if par.codec_id == AV_CODEC_ID_DTS, let layout = objectAudioRendering.layout,
                      !layout.carriesDTSXOneToOne {
                EngineLog.emit(
                    "[HLSVideoEngine] DTS:X is rendered into 7.1.4 or 9.1.6 only, not \(layout.rawValue); "
                    + "keeping the channel bridge",
                    category: .session
                )
            } else if par.codec_id == AV_CODEC_ID_DTS, objectAudioRendering != .off {
                // Lossy DTS has no DTS:X to render; only the lossless profiles reach the DTS:X decoder.
                EngineLog.emit(
                    "[HLSVideoEngine] object rendering requested but DTS is not 48 kHz DTS-HD Master Audio "
                    + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                    category: .session
                )
            }
            return nil
        }
        // VOD only: the live reopen and splice paths re-time the bridge in ways this one's encoder
        // latency and fixed packet stamping do not follow.
        guard !isLiveSession else {
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name) rendering is VOD only; keeping the channel bridge on this live session",
                category: .session
            )
            return nil
        }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name) rendering needs OS 26 (APAC encoder API); keeping the channel bridge",
                category: .session
            )
            return nil
        }
        #if TrueHDObjectAudio || DTSXObjectAudio
        return buildSpatialAudioProducer(
            audioStream: audioStream, audioDemuxer: audioDemuxer, sourceAudioStreamIndex: sourceAudioStreamIndex,
            sourceCodecLabel: sourceCodecLabel, audioHLSCodecs: &audioHLSCodecs, audioLanguage: audioLanguage,
            layout: layout, source: source)
        #else
        return nil
        #endif
    }

    #if TrueHDObjectAudio || DTSXObjectAudio
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func buildSpatialAudioProducer(
        audioStream: UnsafeMutablePointer<AVStream>,
        audioDemuxer: Demuxer,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?,
        layout: SpatialSpeakerLayout,
        source: ObjectAudioSource
    ) -> HLSSegmentProducer? {
        let bridge: SpatialAudioBridge
        /// A decoder for each segment's run, made as the session's own.
        let makeDecoder: () throws -> ObjectAudioDecoding
        /// The stream's clock against its start, for a source whose bitstream carries one (TrueHD): one store of
        /// anchors for the session's bridge and every run.
        var clockAnchors: StreamClockAnchors?
        do {
            let decoder: ObjectAudioDecoding
            switch source {
            case .trueHDAtmos:
                #if TrueHDObjectAudio
                let dialogueGain = objectDialogueGain
                makeDecoder = {
                    APACObjectOutputSwitch.isOn
                        ? try TrueHDObjectAudioDecoder(objectOutput: true, dialogueGain: dialogueGain)
                        : try TrueHDObjectAudioDecoder(dialogueGain: dialogueGain)
                }
                decoder = try makeDecoder()
                clockAnchors = trueHDClockHeadOffset(audioStream: audioStream, audioDemuxer: audioDemuxer,
                                                     streamIndex: sourceAudioStreamIndex).map(StreamClockAnchors.init(headOffset:))
                #else
                return nil
                #endif
            case .dtsHDMasterAudio:
                #if DTSXObjectAudio
                let dtsx = try DTSXObjectAudioDecoder()
                // On a resume the verdict reads where the first producer starts, not the file head
                // that step 8's seek would then drop; the decoder decides mid-stream as well.
                if audioDemuxer === demuxer {
                    seekToInitialProducerStart(audioDemuxer)
                    demuxerAtInitialProducerStart = true
                }
                let started = DispatchTime.now()
                let verdict = dtsxVerdict(decoder: dtsx, demuxer: audioDemuxer, streamIndex: sourceAudioStreamIndex)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                switch verdict {
                case .renders(let presentation):
                    EngineLog.emit(
                        "[HLSVideoEngine] DTS-HD MA track is DTS:X \(presentation) (first frame, "
                        + "\(String(format: "%.0f", ms)) ms)",
                        category: .session
                    )
                    // The verdict decoded the first packets; the bridge starts from the same ones again.
                    dtsx.reset()
                    decoder = dtsx
                    makeDecoder = { try DTSXObjectAudioDecoder() }
                    audioIsConfirmedDTSX = true
                case .refused(let reason):
                    EngineLog.emit(
                        "[HLSVideoEngine] DTS-HD MA track is not DTS:X this engine renders (\(reason)); "
                        + "keeping the channel bridge",
                        category: .session
                    )
                    return nil
                case nil:
                    EngineLog.emit(
                        "[HLSVideoEngine] no DTS:X verdict within \(Self.dtsxVerdictPacketBudget) packets or "
                        + "\(Self.dtsxVerdictByteBudget >> 20) MiB; keeping the channel bridge",
                        category: .session
                    )
                    return nil
                }
                #else
                return nil
                #endif
            }
            bridge = try SpatialAudioBridge(
                srcTimeBase: audioStream.pointee.time_base, layout: layout, decoder: decoder,
                objectOutput: source == .trueHDAtmos && APACObjectOutputSwitch.isOn)
            bridge.setStreamClock(anchors: clockAnchors)
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] ERROR: \(source.name) rendering unavailable (\(error)); keeping the channel bridge",
                category: .session
            )
            return nil
        }
        guard let cp = bridge.encoderCodecpar else {
            bridge.close()
            return nil
        }
        // Same surfacing as the channel bridge: a decoder that never answers is a failure, not silence.
        let watchesDecoder = sideAudioDemuxer == nil
        let streamIndex = sourceAudioStreamIndex
        let objectOutput = source == .trueHDAtmos && APACObjectOutputSwitch.isOn
        let levels = bridge.levels
        let delivered = segmentRuns(template: bridge, sourceStream: audioStream) { [weak self] in
            let run = try SpatialAudioBridge(srcTimeBase: audioStream.pointee.time_base, layout: layout,
                                             decoder: try makeDecoder(), objectOutput: objectOutput,
                                             sessionLevels: levels)
            run.setStreamClock(anchors: clockAnchors)
            if watchesDecoder {
                run.onDecoderProducedNothing = { [weak self] stats in
                    self?.handleBridgeDecodedNothing(streamIndex: streamIndex, summary: stats.summary)
                }
            }
            return run
        } ?? bridge
        let cfg = HLSSegmentProducer.AudioConfig(
            bridging: audioStream,
            codecpar: cp,
            sourceStreamIndex: sourceAudioStreamIndex,
            bridge: delivered,
            language: audioLanguage
        )
        savedAudioConfig = cfg
        audioBridge = delivered
        if watchesDecoder {
            bridge.onDecoderProducedNothing = { [weak self] stats in
                self?.handleBridgeDecodedNothing(streamIndex: streamIndex, summary: stats.summary)
            }
        }
        do {
            let producer = try makeProducer(baseIndex: initialProducerBaseIndex)
            audioHLSCodecs = bridge.hlsCodecs
            // Short on purpose: hosts append it to a track title in one-line stats rows.
            audioPipelineDescription = source == .trueHDAtmos
                ? "\(sourceCodecLabel) Atmos → APAC \(APACObjectOutputSwitch.isOn ? "objects" : layout.rawValue)"
                : "DTS:X → APAC \(layout.rawValue)"
            audioDelivery = .bridged
            audioIsAPAC = true
            let rendering: String
            switch source {
            case .trueHDAtmos where APACObjectOutputSwitch.isOn:
                rendering = "elements sent as APAC objects (\(APACObjectOutputSwitch.variable), personal build)"
            case .trueHDAtmos:
                rendering = "decoded exactly, objects rendered into \(layout.rawValue)"
            case .dtsHDMasterAudio:
                rendering = "bed and heights routed one to one into \(layout.rawValue)"
            }
            EngineLog.emit(
                "[HLSVideoEngine] \(source.name): \(rendering), delivered as \(bridge.hlsCodecs) (lossy)",
                category: .session
            )
            return producer
        } catch {
            EngineLog.emit(
                "[HLSVideoEngine] APAC producer header write failed (\(error)); keeping the channel bridge",
                category: .session
            )
            savedAudioConfig = nil
            audioBridge = nil
            delivered.close()
            return nil
        }
    }
    #endif
}
