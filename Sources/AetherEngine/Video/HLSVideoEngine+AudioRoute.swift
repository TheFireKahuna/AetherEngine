import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// Audio codec routing: stream-copy (fMP4-legal, preserves Atmos/DTS-HD) vs AudioBridge (decode to PCM, then FLAC or EAC3, for non-fMP4-legal codecs; TrueHD-MAT Atmos object metadata lost in the PCM intermediate unless `objectAudioRendering`, in a build with the object-audio traits, sends it to `SpatialAudioBridge`).
    enum AudioCodecCompat {
        case aac, ac3, eac3, flac, alac, mp3, opus
        case truehd, dts
        case vorbis, mp2
        /// Linear PCM, integer or float, which the mp4 muxer writes as ISO/IEC 23003-5 `ipcm` / `fpcm`
        /// with its speaker positions in `chnl`, and AVPlayer plays from HLS fMP4 (measured on macOS 27:
        /// 16-, 24- and 32-bit float, stereo, 5.1 and 7.1, CODECS `ipcm` / `fpcm`; `lpcm` it refuses,
        /// -11848). Copied as it is.
        case pcm
        /// PCM with no `ipcm` form: unsigned 8-bit, G.711 A-law / mu-law (libavcodec spells them
        /// pcm_alaw / pcm_mulaw, and they decode to the same S16 the raw shapes do), and DVD LPCM, whose
        /// packets carry headers. These go through the bridge.
        case otherPCM
        /// Blu-ray LPCM: big-endian PCM behind a header per packet (`BluRayLPCM`). Copied as `ipcm`
        /// with the header taken off and the speakers declared in the disc's own order.
        case bluRayLPCM
        /// LATM/LOAS-framed AAC (DVB-T2/IPTV, typically HE-AAC): the AAC inside it copies (`LATM`).
        case aacLatm
        /// Every Windows Media audio flavour (Standard, Pro, Lossless, Voice), which arrives with the
        /// native .wmv / .asf support of FFmpegBuild 3.1.0. None is fMP4-legal, so all bridge. One case
        /// rather than five: nothing downstream distinguishes them.
        case wma
        /// The Flash era's own audio, which arrives with the native `.flv` decoders of FFmpegBuild
        /// 3.2.0. Three cases rather than one family, unlike `wma` above: these are unrelated codecs
        /// that only share a container, and the routing log prints this name, so an operator reading
        /// `codec=nellymoser` learns what the file carries. None is fMP4-legal, so all three bridge.
        case nellymoser, adpcmSwf, speex
        /// Every RealAudio an `.rm` / `.rmvb` carries (Cook, ATRAC3, Sipro, RealAudio Lossless and the
        /// 14.4 / 28.8 speech codecs), which arrive with the RealMedia support of FFmpegBuild 3.8.0. One
        /// family like `wma`: they share a container and nothing downstream tells them apart.
        case realAudio
        /// AMR narrowband and wideband, the speech audio of a feature phone's 3GP (FFmpegBuild 3.8.0).
        case amr
        /// What this case costs is the STREAM-COPY decision, not the audio. Since the bridge cascade
        /// was rewired (2026-05-13) it asks libavcodec for a decoder by id and never consults this
        /// table, so a codec that lands here still plays if the build carries its decoder; measured
        /// 2026-09-10 on Nellymoser-in-FLV before its entry existed. Silence has one cause and it is
        /// the FFmpeg build: no decoder, `AudioBridge` init fails, and the cascade ends in
        /// `droppedNoPipeline`. That is why a format chain ships whole, decoders and all.
        case unsupported

        static func from(_ codecID: AVCodecID) -> AudioCodecCompat {
            switch codecID {
            case AV_CODEC_ID_AAC:    return .aac
            case AV_CODEC_ID_AAC_LATM: return .aacLatm
            case AV_CODEC_ID_AC3:    return .ac3
            case AV_CODEC_ID_EAC3:   return .eac3
            case AV_CODEC_ID_FLAC:   return .flac
            case AV_CODEC_ID_ALAC:   return .alac
            case AV_CODEC_ID_MP3:    return .mp3
            case AV_CODEC_ID_OPUS:   return .opus
            case AV_CODEC_ID_TRUEHD: return .truehd
            case AV_CODEC_ID_DTS:    return .dts
            case AV_CODEC_ID_VORBIS: return .vorbis
            case AV_CODEC_ID_MP2:    return .mp2
            case AV_CODEC_ID_WMAV1,
                 AV_CODEC_ID_WMAV2,
                 AV_CODEC_ID_WMAPRO,
                 AV_CODEC_ID_WMALOSSLESS,
                 AV_CODEC_ID_WMAVOICE:
                return .wma
            case AV_CODEC_ID_NELLYMOSER: return .nellymoser
            case AV_CODEC_ID_ADPCM_SWF:  return .adpcmSwf
            case AV_CODEC_ID_SPEEX:      return .speex
            case AV_CODEC_ID_COOK,
                 AV_CODEC_ID_ATRAC3,
                 AV_CODEC_ID_SIPR,
                 AV_CODEC_ID_RALF,
                 AV_CODEC_ID_RA_144,
                 AV_CODEC_ID_RA_288:
                return .realAudio
            case AV_CODEC_ID_AMR_NB, AV_CODEC_ID_AMR_WB: return .amr
            case AV_CODEC_ID_PCM_S16LE,
                 AV_CODEC_ID_PCM_S24LE,
                 AV_CODEC_ID_PCM_F32LE,
                 AV_CODEC_ID_PCM_S16BE,
                 AV_CODEC_ID_PCM_S32LE:
                return .pcm
            case AV_CODEC_ID_PCM_U8,
                 AV_CODEC_ID_PCM_ALAW,
                 AV_CODEC_ID_PCM_MULAW,
                 AV_CODEC_ID_PCM_DVD:
                return .otherPCM
            case AV_CODEC_ID_PCM_BLURAY: return .bluRayLPCM
            default: return .unsupported
            }
        }

        /// CODECS attribute for the master playlist. Empty for bridged codecs (engine computes `fLaC` from the encoded stream).
        var hlsCodecsString: String {
            switch self {
            case .aac, .aacLatm: return "mp4a.40.2"
            case .pcm, .bluRayLPCM: return "ipcm"
            case .ac3:    return "ac-3"
            case .eac3:   return "ec-3"
            case .flac:   return "fLaC"
            case .alac:   return "alac"
            case .mp3, .opus, .truehd, .dts, .vorbis, .otherPCM, .mp2, .wma,
                 .nellymoser, .adpcmSwf, .speex, .realAudio, .amr, .unsupported:
                // mp3: theoretically mp4a.40.34, but AVPlayer treats any mp4a as AAC and fails; bridge to FLAC.
                return ""
            }
        }

        /// Codecs that must go through AudioBridge. Opus is fMP4-spec-legal but AVPlayer rejects it in HLS-fMP4 in practice (only CAF/WebM paths work). MP3 writes `mp4a.40.34` but AVPlayer treats any mp4a as AAC, failing with -11829/-12848.
        var requiresBridge: Bool {
            switch self {
            case .opus, .mp3, .truehd, .dts, .vorbis, .otherPCM, .mp2, .wma,
                 .nellymoser, .adpcmSwf, .speex, .realAudio, .amr: return true
            default: return false
            }
        }
    }

    /// libavcodec's own name for a codec id ("eac3", "flac"), for log lines that used to print a bridge
    /// MODE and would now name the wrong thing.
    static func encoderLabel(_ id: AVCodecID) -> String {
        avcodec_get_name(id).map { String(cString: $0) } ?? "id \(id.rawValue)"
    }

    /// AE#462: the cascade's video-only tail is reached by two different sources of silence, and a
    /// host's ladder acts on exactly one of them. A source with no audio track has nothing to demote
    /// to; a source whose audio was dropped plays silently over a server-side transcode that would
    /// have carried it. `audioPipelineDescription` is nil for both.
    static func videoOnlyAudioDelivery(hadSourceAudioStream: Bool) -> AudioDelivery {
        hadSourceAudioStream ? .droppedNoPipeline : .noAudioInSource
    }

    /// AE#641: the bridge decoded not one frame of the selected stream. A FLAC sample entry is built from
    /// the encoder's extradata, so no muxer death follows on that route: a live session serves an
    /// audio track that is never filled and AVPlayer waits on it, a VOD session plays silently while
    /// reporting `.bridged`. Live hands it to the engine, which rebuilds video-only; VOD surfaces
    /// the same verdict the E-AC-3 route reaches through its failed cut, so a host can hand the
    /// position to a player that decodes the track itself.
    /// Seekable VOD makes each segment's bridged audio in a run of its own (`AudioSegmentRuns`), so
    /// a segment comes out the same however playback reached it; `makeRun` builds a run like
    /// `template`. Nil keeps `template` as the one run of the session: live and sequential sources,
    /// which are never re-read, and a decoder whose memory is not known (`AudioStageSpan.decoder`).
    func segmentRuns(template: any AudioTranscodingBridge, sourceStream: UnsafeMutablePointer<AVStream>,
                     makeRun: @escaping () throws -> any AudioTranscodingBridge) -> (any AudioTranscodingBridge)? {
        guard !isLiveSession, !sequentialOrigin else { return nil }
        let codec = avcodec_get_name(sourceStream.pointee.codecpar.pointee.codec_id).map { String(cString: $0) } ?? "?"
        guard let runs = AudioSegmentRuns(template: template, sourceCodecpar: sourceStream.pointee.codecpar,
                                          sourceTimeBase: sourceStream.pointee.time_base, makeRun: makeRun) else {
            EngineLog.emit(
                "[HLSVideoEngine] audio: \(codec)'s decoder memory is not known, so one run makes every segment "
                + "and a seek's segments can differ from continuous playback's",
                category: .session)
            return nil
        }
        EngineLog.emit(
            "[HLSVideoEngine] audio: each segment from a run of its own (\(codec)), the source read "
            + "\(String(format: "%.2f", runs.preRollSeconds)) s ahead of it",
            category: .session)
        return runs
    }

    func handleBridgeDecodedNothing(streamIndex: Int32, summary: String) {
        if isLiveSession {
            onLiveAudioDecodesNothing?(streamIndex, summary)
            return
        }
        EngineLog.emit(
            "[HLSVideoEngine] AE#641 the VOD audio bridge decoded nothing from stream \(streamIndex) "
            + "(\(summary)); surfacing it instead of playing silently",
            category: .session
        )
        surfaceVODSourceFailure(FFmpegErr.einval, "Audio track could not be decoded",
                                kind: .audioBridgeProducedNoOutput)
    }

    /// Guards `audioSourceStreamIndexOverride` against stale picker selections from a previous title.
    static func isAudioStream(demuxer: Demuxer, index: Int32) -> Bool {
        guard index >= 0, let stream = demuxer.stream(at: index) else {
            return false
        }
        return stream.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO
    }

    /// Audio routing cascade: stream-copy -> bridge -> video-only. Covers EAC3-from-MKV where codecpar
    /// lacks the `dec3` extradata the mp4 muxer needs to write the audio sample-entry.
    func buildProducerWithAudioCascade(
        preferBridge: Bool,
        streamCopyAudio: HLSSegmentProducer.AudioConfig?,
        sourceAudioStreamIndex: Int32,
        sourceAudioStream: UnsafeMutablePointer<AVStream>?,
        audioDemuxer: Demuxer,
        sourceCarriesAudio: Bool,
        audioHLSCodecs: inout String?,
        audioLanguage: String? = nil
    ) throws -> HLSSegmentProducer {
        // EAC3 profile=30 is the JOC marker; any stream-copy->FLAC fallback silently loses Atmos object metadata.
        let sourceIsAtmos: Bool = {
            guard let stream = sourceAudioStream else { return false }
            return stream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_EAC3
                && stream.pointee.codecpar.pointee.profile == 30
        }()

        // AE#462 harness (TEST-ONLY): both attempts are skipped so the video-only tail is reachable
        // without a source this build has no decoder for. Loud, because a run that read as a real
        // classification would be worse than no harness at all.
        let forcedForTesting = AetherEngine.forceAudioPipelineFailureForTesting
        if forcedForTesting {
            EngineLog.emit(
                "[HLSVideoEngine] TEST-ONLY: audio pipeline forced to fail, skipping stream-copy and bridge",
                category: .session
            )
        }
        // AE#641: this session's bridge already decoded nothing from this stream, and a second
        // bridge would be handed the same bytes.
        let knownUndecodable = Self.isKnownUndecodable(
            undecodableAudioStreamIndices, sourceAudioStreamIndex: sourceAudioStreamIndex)
        if knownUndecodable {
            EngineLog.emit(
                "[HLSVideoEngine] AE#641 audio stream \(sourceAudioStreamIndex) decoded nothing earlier "
                + "in this session; skipping stream-copy and bridge",
                category: .session
            )
        }
        let forcedDrop = forcedForTesting || knownUndecodable

        let sourceCodecLabel: String = {  // falls back to "audio" for codecs with no libavcodec name entry
            if let stream = sourceAudioStream,
               let cstr = avcodec_get_name(stream.pointee.codecpar.pointee.codec_id) {
                return String(cString: cstr).uppercased()
            }
            return "audio"
        }()

        if !forcedDrop, !preferBridge, let cfg = streamCopyAudio, let vcfg = savedVideoConfig {
            // Pre-flight avformat_write_header: makeProducer is lazy (muxer alloc on first keep-packet), so a
            // failure there (EAC3-from-MKV, missing dec3 extradata, -22 "Cannot write moov atom before EAC3
            // packets parsed") would leave the producer stuck with the bridge fallback unreachable.
            let probeVideo = MP4SegmentMuxer.VideoConfig(
                codecpar: vcfg.codecpar,
                timeBase: vcfg.timeBase,
                codecTagOverride: vcfg.codecTagOverride,
                doviConfig: vcfg.doviConfig,
                colorOverride: vcfg.colorOverride,
                extradataOverride: vcfg.extradataOverride,
                convertsAnnexBSamples: vcfg.convertsAnnexBSamples
            )
            let probeAudio = MP4SegmentMuxer.AudioConfig(
                codecpar: cfg.codecpar,
                timeBase: cfg.inputTimeBase
            )
            let probeRet = MP4SegmentMuxer.probeWriteHeader(
                video: probeVideo,
                audio: probeAudio
            )
            if probeRet < 0 {
                if sourceIsAtmos {
                    EngineLog.emit(
                        "[HLSVideoEngine] WARNING: Atmos downgrade, EAC3+JOC stream-copy probe rejected by mp4 muxer (ret=\(probeRet)). "
                        + "Falling back to the bridge: bed channels stay lossless, but object metadata is lost. "
                        + "Source: \(sourceAudioStream?.pointee.codecpar.pointee.profile.description ?? "?") profile, "
                        + "channels=\(sourceAudioStream?.pointee.codecpar.pointee.ch_layout.nb_channels ?? -1), "
                        + "codec_tag=\(MP4SegmentMuxer.fourCCDescription(sourceAudioStream?.pointee.codecpar.pointee.codec_tag ?? 0)). "
                        + "The source container's codec_tag is already sanitised for the mp4 muxer (AE#382), so the cause "
                        + "is elsewhere; the muxer's own error line above this one names it.",
                        category: .session
                    )
                } else {
                    EngineLog.emit(
                        "[HLSVideoEngine] audio stream-copy probe failed (ret=\(probeRet)), retrying with the bridge",
                        category: .session
                    )
                }
            } else {
                self.savedAudioConfig = cfg
                do {
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    if sourceIsAtmos {
                        EngineLog.emit(
                            "[HLSVideoEngine] EAC3+JOC Atmos: stream-copy engaged; DD+/JOC bitstream "
                            + "preserved for the downstream renderer (HDMI passthrough / AirPods spatial; "
                            + "plain Bluetooth A2DP / LE downmixes natively)",
                            category: .session
                        )
                    }
                    self.audioPipelineDescription = sourceIsAtmos
                        ? "Stream-copy (EAC3+JOC Atmos)"
                        : "Stream-copy (\(sourceCodecLabel))"
                    self.audioDelivery = .streamCopy
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] makeProducer failed after stream-copy probe succeeded (\(error)), retrying with the bridge",
                        category: .session
                    )
                }
            }
        } else if preferBridge && sourceIsAtmos {
            // EAC3+JOC always stream-copies; a pre-bridge decision is a codec-table bug.
            EngineLog.emit(
                "[HLSVideoEngine] WARNING: Atmos source pre-routed to the bridge without stream-copy attempt, Atmos lost. Investigate the codec compatibility table.",
                category: .session
            )
        }

        // #731: TrueHD Atmos or DTS:X with object rendering requested. Tried before the channel bridges,
        // which it falls back to on any failure (see buildSpatialAudioProducerIfEligible).
        if !forcedDrop, let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0,
           let prod = buildSpatialAudioProducerIfEligible(
               audioStream: audioStream,
               audioDemuxer: audioDemuxer,
               sourceAudioStreamIndex: sourceAudioStreamIndex,
               sourceCodecLabel: sourceCodecLabel,
               audioHLSCodecs: &audioHLSCodecs,
               audioLanguage: audioLanguage) {
            return prod
        }

        if !forcedDrop, let audioStream = sourceAudioStream, sourceAudioStreamIndex >= 0 {
            bridged: do {
                let bridge: AudioBridge
                do {
                    bridge = try AudioBridge(
                        srcCodecpar: audioStream.pointee.codecpar,
                        srcTimeBase: audioStream.pointee.time_base,
                        mode: audioBridgeMode,
                        // Live splices are re-timed by the producer (`noteTimelineJump`); VOD places each
                        // decoded frame on the stream's grid (`SourceGrid`).
                        followsSourceContinuity: !isLiveSession
                    )
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] ERROR: AudioBridge init failed (\(error)), falling back to SILENT video-only",
                        category: .session
                    )
                    break bridged
                }

                guard let cp = bridge.encoderCodecpar else {
                    bridge.close()
                    break bridged
                }
                let watchesDecoder = sideAudioDemuxer == nil
                let streamIndex = sourceAudioStreamIndex
                let delivered = segmentRuns(template: bridge, sourceStream: audioStream) { [weak self, audioBridgeMode, isLiveSession] in
                    let run = try AudioBridge(srcCodecpar: audioStream.pointee.codecpar,
                                              srcTimeBase: audioStream.pointee.time_base,
                                              mode: audioBridgeMode, followsSourceContinuity: !isLiveSession,
                                              announces: false)
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
                self.savedAudioConfig = cfg
                self.audioBridge = delivered
                if watchesDecoder {
                    bridge.onDecoderProducedNothing = { [weak self] stats in
                        self?.handleBridgeDecodedNothing(streamIndex: streamIndex, summary: stats.summary)
                    }
                }
                do {
                    let prod = try makeProducer(baseIndex: initialProducerBaseIndex)
                    // The label and the CODECS attribute come from what the bridge ACTUALLY hands on, not
                    // from the mode: `.surroundCompat` on a stereo source hands on PCM, and a master playlist
                    // that advertises ec-3 for a PCM track is a load failure, not a cosmetic slip.
                    audioHLSCodecs = bridge.output == .eac3 ? "ec-3" : "ipcm"
                    self.audioPipelineDescription = "\(sourceCodecLabel) → \(bridge.output == .eac3 ? "EAC3" : "PCM") bridge"
                    self.audioDelivery = .bridged
                    return prod
                } catch {
                    EngineLog.emit(
                        "[HLSVideoEngine] \(Self.encoderLabel(bridge.outputCodecID)) bridge header write failed "
                        + "(\(error)), falling back to video-only",
                        category: .session
                    )
                    self.savedAudioConfig = nil
                    self.audioBridge = nil
                    delivered.close()
                }
            }
        }

        // Video-only fallback: illegal for demuxed-audio sessions (silent playback); fail and let the host fall back to server-muxed.
        if sideAudioDemuxer != nil {
            throw HLSVideoEngineError.openFailed(
                reason: "demuxed-audio companion present but no audio pipeline could be built")
        }
        self.savedAudioConfig = nil
        self.audioBridge = nil
        audioHLSCodecs = nil
        self.audioPipelineDescription = nil
        // AE#462: the drop becomes a fact the host can read, and a line that says which of the two
        // silences this is. The ERROR lines above name a failure; this one names the outcome, which
        // is what a reader of the log is actually looking for.
        // AE#641: whether the SOURCE has audio, not whether a stream was picked. `av_find_best_stream`
        // passes over an audio stream whose parameters the probe left empty, and on VOD nothing falls
        // back to it, so a source with an undecodable track used to read as one without audio.
        self.audioDelivery = Self.videoOnlyAudioDelivery(
            hadSourceAudioStream: sourceCarriesAudio
                || (sourceAudioStream != nil && sourceAudioStreamIndex >= 0))
        EngineLog.emit(
            "[HLSVideoEngine] audio delivery = \(audioDelivery.rawValue)"
            + (audioDelivery == .droppedNoPipeline
               ? ": the source has audio and none of it could be delivered, the session plays "
                 + "video-only (a host with a fallback ladder demotes here)"
               : ": the source carries no audio to deliver"),
            category: .session
        )
        return try makeProducer(baseIndex: initialProducerBaseIndex)
    }
}
