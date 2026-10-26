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

    /// Packets and bytes the TrueHD clock measurement may peek. Peeked packets stay resident until the
    /// producer reads them, as for the TrueHD verdict (`trueHDVerdictByteBudget`); restart headers come every
    /// sixteen access units, so the readings it takes arrive within about a second of the stream.
    static let trueHDClockPacketBudget = 16_384
    static let trueHDClockByteBudget = 64 << 20
    /// Restart headers the TrueHD clock measurement reads up to: about a second of the stream.
    static let trueHDClockRestarts = 64

    /// Where a TrueHD stream's own clock reads zero, counted from the stream's start, in frames at its rate
    /// (`StreamClockPlacement.headOffset`), for the bridges that place by it: the one number the container alone
    /// knows, how the stream's clock sits against the timeline the picture shares (``trueHDClockOffset(audioStream:
    /// demuxer:streamIndex:)``), read from the stream's head. Nil where it cannot be read (live, a side audio demuxer
    /// the producer positions itself, a stream that states no start, too few readings within the budget), and the
    /// grid then places as before.
    func trueHDClockHeadOffset(audioStream: UnsafeMutablePointer<AVStream>, audioDemuxer: Demuxer,
                               streamIndex: Int32) -> Int64? {
        guard audioStream.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD,
              !isLiveSession, audioDemuxer === demuxer, audioStream.pointee.start_time != Int64.min else { return nil }
        let started = DispatchTime.now()
        var read = Self.trueHDClockOffset(audioStream: audioStream, demuxer: audioDemuxer, streamIndex: streamIndex)
        var seeked = false
        if !read.atHead {
            seeked = audioDemuxer.seek(to: audioStream.pointee.start_time, streamIndex: streamIndex, atOrBefore: true)
            if seeked { read = Self.trueHDClockOffset(audioStream: audioStream, demuxer: audioDemuxer, streamIndex: streamIndex) }
        }
        if seeked || initialProducerBaseIndex > 0 {
            seekToInitialProducerStart(audioDemuxer)
            demuxerAtInitialProducerStart = true
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
        EngineLog.emit(
            "[HLSVideoEngine] TrueHD clock "
            + (read.offset.map { "reads zero \($0) frames from the stream's start, "
                                 + (read.counted ? "counted from its head, within what its timestamps allow"
                                                 : "the middle of what its timestamps allow (its first packet is stamped apart)")
                                 + "; \(read.apart) of \(read.readings) access units stamped apart" }
               ?? "not read: \(read.readings) access units within the budget; placing on the grid")
            + " (\(String(format: "%.0f", ms)) ms)",
            category: .session)
        return read.offset
    }

    /// The offset ``trueHDClockHeadOffset(audioStream:audioDemuxer:streamIndex:)`` reads, on `demuxer` from where it
    /// stands: the offset, how many access units it read and how many of those were stamped apart from it, whether it
    /// is the count from the head, and whether the demuxer stood at the stream's first packet.
    ///
    /// FFmpeg's decoder states each restart header's output_timing on its frame (`mlp_output_timing`), every sixteen
    /// access units, and every access unit is the same number of samples, so the clock is known at every access unit:
    /// the last restart's, plus the units since. Two reads of the offset from that:
    /// - The timestamps bound it. A packet's timestamp is its access unit's place rounded to the container's tick, so
    ///   each one allows the offsets within half a tick of its own reading (its timestamp less its clock,
    ///   ``mostAllowed(_:halfWidth:)``); the offset lies where the most packets allow it. With a millisecond's tick
    ///   and 40-sample access units that is a window eight frames wide, whatever the number of packets. A packet that
    ///   does not allow it is stamped apart.
    /// - The count from the head pins it. The stream's first packet is its start, unrounded, so the access units
    ///   before the first restart header, times the unit's samples, less its clock, is the offset to the frame.
    /// The count stands where the timestamps allow it. Where they do not, the first packet is the one stamped apart (a
    /// library title's sat at zero, 5.3 ms ahead of a gap its clock runs straight through), and the offset is the
    /// middle of what they allow, within four frames. A survey of seven TrueHD titles found every other stamp within
    /// a millisecond of its access unit, spread both ways. The clock wraps at 2^16, so the readings are taken in the
    /// wrap's window around the first.
    static func trueHDClockOffset(audioStream: UnsafeMutablePointer<AVStream>, demuxer: Demuxer, streamIndex: Int32)
        -> (offset: Int64?, readings: Int, apart: Int, counted: Bool, atHead: Bool) {
        let start = audioStream.pointee.start_time
        let tb = audioStream.pointee.time_base
        guard start != Int64.min, tb.den > 0, let codec = avcodec_find_decoder(AV_CODEC_ID_TRUEHD)
        else { return (nil, 0, 0, false, false) }
        var readings: [Int64] = []
        var restarts = 0
        var lastRestart: (timing: Int64, unitsSince: Int64)?
        var atHead: Bool?
        var unitsFromStart: Int64 = 0
        var counted: Int64?
        var halfTick: Int64 = 0
        var context = avcodec_alloc_context3(codec)
        var frame = av_frame_alloc()
        defer { avcodec_free_context(&context); av_frame_free(&frame) }
        guard let context, let frame, avcodec_parameters_to_context(context, audioStream.pointee.codecpar) >= 0
        else { return (nil, 0, 0, false, false) }
        context.pointee.pkt_timebase = tb
        guard avcodec_open2(context, codec, nil) >= 0 else { return (nil, 0, 0, false, false) }
        var heldBytes = 0
        try? demuxer.peekPackets(maxPackets: trueHDClockPacketBudget) { packet in
            heldBytes += Int(max(packet.pointee.size, 0))
            if heldBytes > trueHDClockByteBudget { return true }
            guard packet.pointee.stream_index == streamIndex, packet.pointee.size > 0 else { return false }
            if atHead == nil { atHead = packet.pointee.pts == start }
            var units: Int64 = 0
            if avcodec_send_packet(context, packet) >= 0 {
                while avcodec_receive_frame(context, frame) >= 0 {
                    defer { av_frame_unref(frame); units += 1 }
                    let rate = AVRational(num: 1, den: frame.pointee.sample_rate)
                    let unit = AudioBridge.trueHDAccessUnitFrames(rate: frame.pointee.sample_rate)
                    if let entry = av_dict_get(frame.pointee.metadata, "mlp_output_timing", nil, 0),
                       let timing = Int64(String(cString: entry.pointee.value)) {
                        lastRestart = (timing, 0)
                        restarts += 1
                        if atHead == true, counted == nil { counted = (unitsFromStart + units) * unit - timing }
                    } else if let last = lastRestart {
                        lastRestart = (last.timing, last.unitsSince + 1)
                    }
                    // Only a packet's first access unit carries its timestamp.
                    guard units == 0, packet.pointee.pts != Int64.min, let last = lastRestart else { continue }
                    halfTick = max(1, av_rescale_q(1, tb, rate) / 2)
                    readings.append(av_rescale_q(packet.pointee.pts &- start, tb, rate) - (last.timing + last.unitsSince * unit))
                }
            }
            unitsFromStart += max(units, 1)
            return restarts >= trueHDClockRestarts
        }
        let head = atHead ?? false
        guard restarts >= trueHDClockRestarts / 2, let first = readings.first else {
            return (nil, readings.count, 0, false, head)
        }
        let window = readings.map { first + StreamClockPlacement.nearest($0 - first, modulus: 1 << 16) }
        let allowed = mostAllowed(window, halfWidth: halfTick)
        // A reading is stamped apart when it allows none of the window.
        let allowsWindow: (Int64) -> Bool = { $0 + halfTick > allowed.lowerBound && $0 - halfTick <= allowed.upperBound }
        let apart = window.filter { !allowsWindow($0) }.count
        if let counted {
            let near = first + StreamClockPlacement.nearest(counted - first, modulus: 1 << 16)
            if allowed.contains(near) { return (counted, readings.count, apart, true, head) }
        }
        return ((allowed.lowerBound + allowed.upperBound) / 2, readings.count, apart, false, head)
    }

    /// The values the most readings allow: a closed range. A reading is a timestamp rounded to the nearest tick, a
    /// tie upward, less its exact place, so it lies in (x - halfWidth, x + halfWidth] of the true value x, and allows
    /// x in [r - halfWidth, r + halfWidth). A reading off by a whole tick then allows none of the true window, where a
    /// closed allowance would let late ones pull it a lattice step.
    static func mostAllowed(_ readings: [Int64], halfWidth: Int64) -> ClosedRange<Int64> {
        // Each reading's allowance opens at r - halfWidth and closes at r + halfWidth. Every change at a value is
        // applied before the stretch from it to the next change is counted; the best stretch is where most are open.
        var changes: [Int64: Int] = [:]
        for r in readings {
            changes[r - halfWidth, default: 0] += 1
            changes[r + halfWidth, default: 0] -= 1
        }
        let at = changes.keys.sorted()
        var open = 0, best = 0
        var range = (readings.first ?? 0)...(readings.first ?? 0)
        for (i, value) in at.enumerated() where i + 1 < at.count {
            open += changes[value]!
            if open > best {
                best = open
                range = value...(at[i + 1] - 1)
            }
        }
        return range
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
                let clockHeadOffset = trueHDClockHeadOffset(audioStream: audioStream, audioDemuxer: audioDemuxer,
                                                            streamIndex: sourceAudioStreamIndex)
                bridge.setStreamClock(headOffset: clockHeadOffset)
                let delivered = segmentRuns(template: bridge, sourceStream: audioStream) { [weak self, audioBridgeMode, isLiveSession] in
                    let run = try AudioBridge(srcCodecpar: audioStream.pointee.codecpar,
                                              srcTimeBase: audioStream.pointee.time_base,
                                              mode: audioBridgeMode, followsSourceContinuity: !isLiveSession,
                                              announces: false)
                    run.setStreamClock(headOffset: clockHeadOffset)
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
