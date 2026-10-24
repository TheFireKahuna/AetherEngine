import AetherLibavcodec


/// The stretch of the timeline one stage of an audio path takes its output from: output at timeline
/// position `p` is a function of the input in `p - memory ..< p + latency`, and of nothing else.
/// Frames, at the rate of the path's output.
///
/// The two numbers answer different questions. `latency` is how far ahead of `p` the stage has to
/// have read before it can hand `p` on: what it holds back, and what the timeline compensates, the
/// way an Audio Unit states it in `kAudioUnitProperty_Latency`. `memory` is how far behind `p` its
/// output still reaches: a run that starts at least that far back gives the output continuous
/// playback gives, whatever came before, so a seek reads that much earlier (the restart's pre-roll)
/// and the segment it produces is the one continuous playback produced.
///
/// For a decoder, `memory` counts from where a read begins: it covers the wait for the first point the
/// bitstream can be decoded from (a TrueHD major sync) as well as the history the decode is coded
/// against.
struct AudioStageSpan: Equatable, Sendable {
    var latency: Int
    var memory: Int

    /// A stage that touches each frame on its own.
    static let instant = AudioStageSpan(latency: 0, memory: 0)

    /// This stage followed by `next`. Its input reaches back and ahead by both.
    func then(_ next: AudioStageSpan) -> AudioStageSpan {
        AudioStageSpan(latency: latency + next.latency, memory: memory + next.memory)
    }

    /// Stages in series, first to last.
    static func series(_ stages: [AudioStageSpan]) -> AudioStageSpan {
        stages.reduce(.instant) { $0.then($1) }
    }
}

// MARK: - Decoders

extension AudioStageSpan {

    /// A TrueHD / MLP decode starts at the next major sync, which the format puts at most 128 access
    /// units (128/1200 s) apart, and is bit-identical with continuous playback from it: it restarts
    /// every filter and predictor. Measured over 60 starts each in a 48 kHz 5.1, a 96 kHz stereo and
    /// a real Atmos 7.1 stream: the wait is the only difference (at most 5040 frames at 48 kHz, 0 after
    /// the sync). Frames at `outputRate`.
    static func trueHDDecoderMemory(outputRate: Int32) -> Int {
        (Int(outputRate) * 128 + 1199) / 1200
    }

    /// Every DTS frame is a sync point, so a decode starts on the next one; what it needs is the
    /// core's subband ADPCM history, which a band's prediction mode resets only when the encoder
    /// switches it off. Measured through FFmpeg's dca decoder (core + XLL) from 60 starts each, against
    /// a continuous decode: bit-identical within 43 frames of 512 in `DTSX Emulator.mkv` (median
    /// 98 ms), 22 in `DTSX Gravity.mkv`, 1 (480 frames) in an FFmpeg-encoded core. Frames at the
    /// source rate.
    static let dtsDecoderMemory = 44 * 512

    /// What a decoder's output at a position takes from earlier in the stream, from where a read
    /// begins (the wait for a decodable point included); nil where it is not known, so a run started
    /// anywhere is not claimed to give continuous playback's output. Frames at `outputRate`; a
    /// decoder's own timestamps place its output, so none states a latency.
    ///
    /// Bounds are the format's where it gives one, otherwise the maximum measured from 60 starts
    /// against a continuous decode through this build's decoders (opened by `openAudioDecoder`).
    static func decoder(_ codecpar: UnsafePointer<AVCodecParameters>, outputRate: Int32) -> AudioStageSpan? {
        let par = codecpar.pointee
        let rate = Int(par.sample_rate)
        func atOutputRate(_ frames: Int) -> AudioStageSpan? {
            guard rate > 0 else { return nil }
            return AudioStageSpan(latency: 0, memory: (frames * Int(outputRate) + rate - 1) / rate)
        }
        switch par.codec_id {
        case AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_S24LE, AV_CODEC_ID_PCM_S32LE,
             AV_CODEC_ID_PCM_F32LE, AV_CODEC_ID_PCM_U8, AV_CODEC_ID_PCM_ALAW, AV_CODEC_ID_PCM_MULAW,
             AV_CODEC_ID_PCM_BLURAY, AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC:
            // Every frame decodes on its own (FLAC and ALAC measured: 0 frames from every start).
            return .instant
        case AV_CODEC_ID_PCM_DVD:
            // Not known: the decoder carries a sample block that straddles two packets over to the
            // next, and the demuxer strips the header that says where the first whole block begins, so a
            // decode from a packet that starts mid-block stays misaligned (3 of 12 starts in a clip).
            return nil
        case AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP:
            return AudioStageSpan(latency: 0, memory: trueHDDecoderMemory(outputRate: outputRate))
        case AV_CODEC_ID_DTS:
            return atOutputRate(dtsDecoderMemory)
        case AV_CODEC_ID_MP2:
            // The synthesis filterbank's 512-tap window; mp2float measured 481 from every start.
            return atOutputRate(512)
        case AV_CODEC_ID_MP3:
            return atOutputRate(mp3DecoderMemory(sampleRate: rate, channels: Int(par.ch_layout.nb_channels)))
        case AV_CODEC_ID_VORBIS:
            // A block overlaps the one before by half of it, and the format's longest is 8192 (measured
            // 1024, half of the fixtures' 2048, from every start).
            return atOutputRate(4096)
        case AV_CODEC_ID_OPUS:
            // CELT predicts each band's energy from the frame before, and its post-filter and the
            // de-emphasis feed back; every path decays at a fixed rate, but only an intra or silence
            // frame resets one, and the encoder decides when (libopus coded the LFE stream of a 5.1
            // film with neither in 90 s). Measured on 90 s of film: bit-identical within 0.92 s
            // stereo and 1.04 s 5.1 (49,735 frames) from every start. 52 frames of 960.
            return atOutputRate(52 * 960)
        default:
            return nil
        }
    }

    /// Layer III: a granule's main data begins up to `main_data_begin` bytes before its own frame (511
    /// in MPEG-1, 255 in MPEG-2/2.5), its IMDCT overlaps the granule before by 576 frames, and the
    /// synthesis window reaches back 512. The reservoir spans the most frames at the format's lowest
    /// bitrate (32 kbps in MPEG-1, 8 in MPEG-2/2.5), whose frames have the least main data after the
    /// header, a CRC and the side information. Measured: at most 4512 frames over four fixtures.
    static func mp3DecoderMemory(sampleRate: Int, channels: Int) -> Int {
        let mpeg1 = sampleRate >= 32_000
        let frameBytes = (mpeg1 ? 144 * 32_000 : 72 * 8_000) / max(sampleRate, 1)
        let sideInfo = mpeg1 ? (channels == 1 ? 17 : 32) : (channels == 1 ? 9 : 17)
        let mainData = max(frameBytes - 4 - 2 - sideInfo, 1)
        let reservoirFrames = ((mpeg1 ? 511 : 255) + mainData - 1) / mainData
        return reservoirFrames * (mpeg1 ? 1152 : 576) + 576 + 512
    }

    // MARK: - Resampler and encoders

    /// libswresample as the bridge configures it (`AudioBridge.applyResamplerQuality`). At one rate it
    /// converts each frame on its own: the bridge's 16-bit output only follows a 16-bit or narrower
    /// source, which libswresample converts in S16P and never dithers, and the 24-bit output is not
    /// dithered. A rate change runs a symmetric filter of `filter_size` taps at the lower of the two
    /// rates, so output at a position reads half of it either side (measured 33 frames 96 kHz into 48,
    /// 34 from 44.1 kHz, with no lag between runs).
    static func resampler(inputRate: Int32, outputRate: Int32) -> AudioStageSpan {
        guard inputRate != outputRate, inputRate > 0 else { return .instant }
        let half = AudioBridge.resamplerFilterSize / 2
        let reach = (half * Int(max(inputRate, outputRate)) + Int(inputRate) - 1) / Int(inputRate) + 1
        return AudioStageSpan(latency: reach, memory: reach)
    }

    /// FFmpeg's E-AC-3 encoder holds back its MDCT overlap (`initial_padding`, 256) and decides each
    /// frame from that frame's input alone. Measured with the bridge's settings (5.1, 768 kbps) from 40
    /// starts on its frame grid over 90 s of film: every packet after a run's first is byte-identical
    /// with continuous encoding's.
    static func eac3Encoder(frameSize: Int, initialPadding: Int) -> AudioStageSpan {
        AudioStageSpan(latency: initialPadding, memory: frameSize)
    }
}
