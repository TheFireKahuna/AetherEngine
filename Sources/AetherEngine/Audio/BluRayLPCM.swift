import AetherLibavcodec
import AetherLibavutil

/// Blu-ray LPCM (HDMV LPCM, the PCM tracks of an M2TS disc) as the linear PCM it is. Each packet is
/// a 4-byte header (channel assignment, sampling frequency, bits per sample) and big-endian samples:
/// 16-bit in two bytes, 20- and 24-bit in three. ISO/IEC 23003-5 `ipcm` carries big-endian samples
/// and states the speaker of every channel in `chnl`, so the samples copy as they are: the header
/// comes off, and the speaker order is declared as the disc stores it rather than reordered.
/// Measured on macOS 27: CoreAudio places every channel of a 5.1 and a 7.1 `ipcm` stream by the
/// order its `chnl` declares, the Blu-ray one (LFE last, sides before backs) included.
///
/// A layout with an odd channel count is stored with one more, unused, channel, which `chnl` has no
/// way to declare, so those frames are copied without it.
struct BluRayLPCM: Equatable {
    let sampleRate: Int32
    /// 16, 20 or 24.
    let bitsPerSample: Int
    /// The speakers of the channels the samples carry, in the order the disc stores them.
    let speakers: [AVChannel]
    /// Channels per stored frame: `speakers`, plus the unused one on an odd layout.
    let storedChannels: Int
    /// Bytes 2 and 3 of the header as far as they describe the stream, for telling a packet of
    /// another format apart.
    private let signature: UInt16

    var bytesPerSample: Int { bitsPerSample == 16 ? 2 : 3 }

    /// The format a packet's header declares; nil for a reserved channel assignment, sampling
    /// frequency or sample depth.
    init?(header bytes: UnsafeRawBufferPointer) {
        guard bytes.count >= 4 else { return nil }
        let speakers: [AVChannel]
        switch bytes[2] >> 4 {
        case 1: speakers = [AV_CHAN_FRONT_CENTER]
        case 3: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT]
        case 4: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER]
        case 5: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_BACK_CENTER]
        case 6: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_BACK_CENTER]
        case 7: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        case 8: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER,
                            AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT]
        case 9: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER,
                            AV_CHAN_SIDE_LEFT, AV_CHAN_SIDE_RIGHT, AV_CHAN_LOW_FREQUENCY]
        case 10: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_SIDE_LEFT,
                             AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_RIGHT]
        case 11: speakers = [AV_CHAN_FRONT_LEFT, AV_CHAN_FRONT_RIGHT, AV_CHAN_FRONT_CENTER, AV_CHAN_SIDE_LEFT,
                             AV_CHAN_BACK_LEFT, AV_CHAN_BACK_RIGHT, AV_CHAN_SIDE_RIGHT, AV_CHAN_LOW_FREQUENCY]
        default: return nil
        }
        switch bytes[2] & 0x0F {
        case 1: sampleRate = 48_000
        case 4: sampleRate = 96_000
        case 5: sampleRate = 192_000
        default: return nil
        }
        switch bytes[3] >> 6 {
        case 1: bitsPerSample = 16
        case 2: bitsPerSample = 20
        case 3: bitsPerSample = 24
        default: return nil
        }
        self.speakers = speakers
        storedChannels = (speakers.count + 1) & ~1
        signature = UInt16(bytes[2]) << 8 | UInt16(bytes[3] & 0xC0)
    }

    /// The format a probed stream has, as libavcodec's decoder read it off the first header into
    /// `codecpar` (layout, rate, depth); nil when probing read none. 20-bit needs FFmpegBuild's
    /// `patch_ffmpeg_bluray_20bit`: stock libavcodec refuses it, and reads no parameters at all.
    init?(codecpar: UnsafePointer<AVCodecParameters>) {
        let par = codecpar.pointee
        guard par.codec_id == AV_CODEC_ID_PCM_BLURAY, par.ch_layout.nb_channels > 0 else { return nil }
        var layout = par.ch_layout
        let speakers = Set((0..<UInt32(par.ch_layout.nb_channels)).map { av_channel_layout_channel_from_index(&layout, $0).rawValue })
        let rates: [Int32: UInt8] = [48_000: 1, 96_000: 4, 192_000: 5]
        let depths: [Int32: UInt8] = [16: 1, 20: 2, 24: 3]
        guard let rate = rates[par.sample_rate], let depth = depths[par.bits_per_coded_sample] else { return nil }
        // The channel assignment whose speakers these are: the header table is the only one.
        for assignment: UInt8 in 1...15 {
            let header: [UInt8] = [0, 0, assignment << 4 | rate, depth << 6]
            if let format = header.withUnsafeBytes({ BluRayLPCM(header: $0) }),
               Set(format.speakers.map(\.rawValue)) == speakers {
                self = format
                return
            }
        }
        return nil
    }

    /// The codec parameters the muxer writes `ipcm` from: big-endian 16- or 24-bit samples (20-bit
    /// ones in their 24-bit words) and the speakers in their stored order.
    func describe(_ codecpar: UnsafeMutablePointer<AVCodecParameters>) -> Bool {
        var layout = AVChannelLayout()
        guard av_channel_layout_custom_init(&layout, Int32(speakers.count)) >= 0 else { return false }
        defer { av_channel_layout_uninit(&layout) }
        for (i, speaker) in speakers.enumerated() { layout.u.map[i].id = speaker }
        av_channel_layout_uninit(&codecpar.pointee.ch_layout)
        guard av_channel_layout_copy(&codecpar.pointee.ch_layout, &layout) >= 0 else { return false }
        codecpar.pointee.codec_id = bitsPerSample == 16 ? AV_CODEC_ID_PCM_S16BE : AV_CODEC_ID_PCM_S24BE
        codecpar.pointee.codec_tag = 0
        codecpar.pointee.sample_rate = sampleRate
        codecpar.pointee.bits_per_coded_sample = Int32(bytesPerSample * 8)
        // The word size, 20-bit samples included: the muxer writes this into `pcmC`, whose sample size
        // is 16, 24 or 32 and says how the data is laid out. Stated as 20, CoreMedia refused the track
        // ("Cannot Open"); the 20 bits are the top of each word either way.
        codecpar.pointee.bits_per_raw_sample = Int32(bytesPerSample * 8)
        codecpar.pointee.block_align = Int32(speakers.count * bytesPerSample)
        codecpar.pointee.bit_rate = Int64(speakers.count * bytesPerSample * 8) * Int64(sampleRate)
        codecpar.pointee.frame_size = 0
        return true
    }

    /// The samples `packet` carries, as `describe` declares them. Nil for a packet of another format
    /// (the stream changed) or one that is not whole frames.
    func samples(_ packet: UnsafeRawBufferPointer) -> UnsafeRawBufferPointer? {
        guard packet.count > 4, BluRayLPCM(header: packet) == self else { return nil }
        let payload = UnsafeRawBufferPointer(rebasing: packet[4...])
        guard payload.count % (storedChannels * bytesPerSample) == 0 else { return nil }
        return payload
    }

    /// Whether the stored frames carry the unused channel `samples` has to leave out.
    var isPadded: Bool { storedChannels != speakers.count }

    /// `payload`'s frames without their unused channel.
    func droppingPadding(_ payload: UnsafeRawBufferPointer) -> [UInt8] {
        let stored = storedChannels * bytesPerSample, kept = speakers.count * bytesPerSample
        let frames = payload.count / stored
        var out = [UInt8](repeating: 0, count: frames * kept)
        out.withUnsafeMutableBytes { dst in
            for f in 0..<frames {
                dst.baseAddress!.advanced(by: f * kept).copyMemory(from: payload.baseAddress!.advanced(by: f * stored), byteCount: kept)
            }
        }
        return out
    }

    static func == (a: BluRayLPCM, b: BluRayLPCM) -> Bool { a.signature == b.signature }
}
