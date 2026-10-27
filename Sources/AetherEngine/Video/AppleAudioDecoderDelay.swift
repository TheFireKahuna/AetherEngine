import AetherLibavcodec

/// The decoder delay AVFoundation trims from the start of an audio track in fragmented MP4 that
/// states none (no edit list), per codec, and how far a stream-copied track has to be moved for its
/// audio to play where its source puts it.
///
/// The two sides disagree on what a packet's timestamp means. A source demuxed by FFmpeg (Matroska,
/// MP4, MPEG-TS) says the packet's decoded audio plays at its timestamp; priming, where a stream has
/// it, is stated beside that (Matroska CodecDelay, an MP4 edit list) and already taken out of the
/// timestamps. Apple's HLS packaging says the timestamp sits a fixed decoder delay ahead of the audio:
/// `AVAssetWriter` (`mpeg4AppleHLS`) writes AAC with no edit list and its first, priming packet at 0,
/// and AVFoundation trims the delay on decode. Copied across unchanged, a source's audio therefore
/// played that delay early: 44.0 ms for AAC-LC, 5.3 ms for AC-3 and E-AC-3 (measured through the
/// engine's HLS output against FFmpeg's decode of the same fixtures). Moving each packet by the delay
/// writes what Apple's own packager writes, which is the convention AVPlayer is built for.
///
/// Values measured on macOS 27 by decoding Apple's own HLS output, and E-AC-3 / AC-3 / AAC files without
/// an edit list, with AVFoundation against FFmpeg (which trims nothing it is not told to): research
/// notes, A/V sync audit. `AppleAudioDecoderDelayTests` holds each one against AVFoundation, so a
/// system that changes one fails a test instead of moving the sound.
enum AppleAudioDecoderDelay {

    /// The delay in samples at the decoder's output rate (`codecpar.sample_rate`), or nil where it has
    /// not been measured (the caller logs that and moves nothing).
    static func samples(codecID: AVCodecID, profile: Int32) -> Int? {
        switch codecID {
        case AV_CODEC_ID_AAC:
            switch profile {
            // HE-AAC and HE-AAC v2 (SBR halves the core rate; the delay is at the output rate).
            case 4, 28: return 5186
            // AAC-LC. FFmpeg's "unknown" (-99) is taken as LC, the profile nearly every AAC track in a
            // video file is; it is logged as an assumption where it is applied.
            case 1, -99: return 2112
            default: return nil
            }
        case AV_CODEC_ID_AC3, AV_CODEC_ID_EAC3:
            return 256
        case AV_CODEC_ID_FLAC, AV_CODEC_ID_ALAC:
            return 0
        default:
            if let name = avcodec_get_name(codecID), String(cString: name).hasPrefix("pcm_") { return 0 }
            return nil
        }
    }
}
