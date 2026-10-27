import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import Dovi

/// HDR10 static metadata a source states only in its bitstream, lifted into the stream side data movenc
/// writes the init's `mdcv` / `clli` from.
///
/// movenc (n8.1, `mov_write_mdcv_tag` / `mov_write_clli_tag`) reads nothing but the output codecpar's
/// `coded_side_data`, and the demuxers only fill that from a container statement: Matroska's
/// `MasteringMetadata`, MP4's own boxes. MPEG-TS has no such statement, and neither does a Matroska
/// remuxed from one, so the mastering display and content light level SEI messages (H.264 / HEVC
/// payload types 137 and 144) never reached the init and AVPlayer saw HDR10 with no static metadata.
/// Measured on an x265 `--master-display ... --max-cll 1000,400` encode in MPEG-TS and in a Matroska
/// remux of it: `ffprobe` lists no stream side data for either, and the served `init.mp4` carried
/// `colr` 9 / 16 / 9 and neither box. `avformat_find_stream_info` does not help: the decoder attaches
/// these messages to frames, not to the stream.
///
/// The ambient viewing environment message (148) is read in the same pass and lands in `amve`, which
/// movenc n8.1 writes from its side data the same way (`mov_write_amve_tag`). It does not gate or
/// extend the scan: it is rare, and a source's own `amve` box already reaches the init, since the MP4
/// demuxer lifts it into stream side data (`mov_read_amve`) and the stream copy carries that over.
///
/// The alternative transfer characteristics message (147) is read too, for backward-compatible HLG:
/// the VUI states BT.2020-10 so an SDR decoder shows something, and the SEI names ARIB STD-B67 (18) as
/// the transfer to prefer. libavcodec applies it, but only to a decoded frame, and a source whose
/// config record holds the SPS is never decoded by `avformat_find_stream_info`: the decoder exports the
/// VUI at init from the record. Measured on one x265 `atc-sei=18:transfer=bt2020-10` stream: from
/// MPEG-TS the probe decodes, codecpar reads 18 and the master states `VIDEO-RANGE=HLG` with `colr`
/// 9 / 18 / 9; the same bytes in an MP4 (MP4Box import, `colr` 9 / 14 / 9, or no `colr` at all) read 14
/// and were served as SDR. The SEI's word is taken on the MP4 path as on the TS path, so one stream is
/// one delivery whatever it arrives in.
///
/// A container statement wins for what it states: a type the codecpar lacks is added, and a mastering display
/// entry the container left incomplete (a Matroska `MasteringMetadata` with no luminance, which movenc will not
/// write as `mdcv`) has its missing half filled from the SEI. The mastering display message belongs beside Dolby
/// Vision metadata, and dropping it leaves the panel the mastering black it guessed.
///
/// The SEI is also looked for in the config record: x265 and other encoders can put prefix SEI arrays in the hvcC,
/// which `canonicalizeHEVCConfigRecord` strips before the init is written (AE#187), so they are read first.
///
/// For a Dolby Vision `dvh1` sample entry, or a session that composes the FEL, the same scan reads the first RPU: its
/// `bl_video_full_range_flag`, where a Profile 5 base layer's range is stated (libdovi requires it set for Profile 5,
/// and the SPS of such a stream often has no VUI to say it, #19), and its L6, the master's mastering display and
/// light level (`DolbyVisionLevel6`).
struct InBandHDRStaticMetadata: Equatable {
    /// mastering_display_colour_volume payload (24 bytes: G, B, R, white point, max / min luminance).
    var masteringDisplay: [UInt8]?
    /// content_light_level_info payload (4 bytes: max_content_light_level, max_pic_average_light_level).
    var contentLightLevel: [UInt8]?
    /// ambient_viewing_environment payload (8 bytes: ambient_illuminance, ambient_light_x / _y).
    var ambientViewing: [UInt8]?
    /// alternative_transfer_characteristics: preferred_transfer_characteristics.
    var alternativeTransfer: UInt8?
    /// The first parseable RPU's `bl_video_full_range_flag` and L6, when the scan was asked to read the RPU.
    var dolbyVisionBaseLayerFullRange: Bool?
    var dolbyVisionLevel6: DolbyVisionLevel6?

    var isEmpty: Bool { masteringDisplay == nil && contentLightLevel == nil && ambientViewing == nil }

    /// The SEI asks for ARIB STD-B67.
    var prefersHLG: Bool { alternativeTransfer == UInt8(AVCOL_TRC_ARIB_STD_B67.rawValue) }

    /// The manifest range once the SEI is heard: SDR becomes HLG, nothing else moves.
    func videoRange(upgrading range: HLSVideoRange) -> HLSVideoRange {
        range == .sdr && prefersHLG ? .hlg : range
    }

    /// HDR10 static metadata only means something on a PQ / HLG source, and is only worth reading
    /// for a type the container did not state. Without the transfer gate every SDR MPEG-TS source paid
    /// a head scan (a rewind on VOD, a peek of the live feed) for messages it cannot carry.
    static func wantsStaticMetadata(
        transfer: AVColorTransferCharacteristic, hasMastering: Bool, hasLightLevel: Bool
    ) -> Bool {
        (transfer == AVCOL_TRC_SMPTE2084 || transfer == AVCOL_TRC_ARIB_STD_B67)
            && (!hasMastering || !hasLightLevel)
    }

    /// Only a BT.2020 source whose transfer is not already PQ / HLG can be backward-compatible HLG.
    static func wantsAlternativeTransfer(
        primaries: AVColorPrimaries, transfer: AVColorTransferCharacteristic
    ) -> Bool {
        primaries == AVCOL_PRI_BT2020 && transfer != AVCOL_TRC_SMPTE2084 && transfer != AVCOL_TRC_ARIB_STD_B67
    }

    /// Whether the codecpar's mastering display entry states both halves movenc needs for `mdcv`.
    static func masteringIsComplete(_ codecpar: UnsafePointer<AVCodecParameters>) -> Bool {
    }

    /// Read the messages carried in an HEVC config record: the SEI NAL arrays of an hvcC, or the NAL units of Annex B
    /// extradata. H.264's avcC has no place for SEI.
    mutating func collect(fromConfigRecord record: [UInt8], codecID: AVCodecID) {
    }

    /// Read `bl_video_full_range_flag` and L6 from the first RPU (unspec62 NAL) in one HEVC access unit that libdovi
    /// parses. Both come from that one RPU, so a later one never mixes in.
    mutating func collectDolbyVisionRPU(from data: UnsafePointer<UInt8>, size: Int, framing: VideoNALFraming) {
        if let found {
            dolbyVisionBaseLayerFullRange = found.fullRange
            dolbyVisionLevel6 = found.level6
        }
    }

    /// Read the messages out of one H.264 / HEVC access unit, keeping the first of each.
    mutating func collect(
        from data: UnsafePointer<UInt8>, size: Int, codecID: AVCodecID, framing: VideoNALFraming
    ) {
        guard codecID == AV_CODEC_ID_HEVC || codecID == AV_CODEC_ID_H264, size > 0 else { return }
        let bytes = UnsafeBufferPointer(start: data, count: size)
        func first(_ type: Int, size expected: Int) -> [UInt8]? {
            var found: [UInt8]?
            _ = HDR10PlusMetadataScan.scanNALs(bytes, codecID: codecID, framing: framing, payloadType: type) {
                guard $1 == expected else { return false }
                found = Array(UnsafeBufferPointer(start: $0, count: $1))
                return true
            }
            return found
        }
        if masteringDisplay == nil { masteringDisplay = first(137, size: 24) }
        if contentLightLevel == nil { contentLightLevel = first(144, size: 4) }
        if ambientViewing == nil { ambientViewing = first(148, size: 8) }
        if alternativeTransfer == nil { alternativeTransfer = first(147, size: 1)?.first }
    }

    /// Add what the codecpar has no side data of its own for; returns the boxes that will now be
    /// written, for the log. Units are the SEI's: chromaticity in 0.00002, luminance in 0.0001 cd/m2,
    /// which is the denominator movenc rescales back to, so the box carries the SEI's integers.
    @discardableResult
    func attach(to codecpar: UnsafeMutablePointer<AVCodecParameters>) -> [String] {
        func has(_ type: AVPacketSideDataType) -> Bool {
            av_packet_side_data_get(
                codecpar.pointee.coded_side_data, codecpar.pointee.nb_coded_side_data, type) != nil
        }
        func u16(_ b: [UInt8], _ i: Int) -> Int32 { Int32(b[i]) << 8 | Int32(b[i + 1]) }
        func u32(_ b: [UInt8], _ i: Int) -> Int32 {
            Int32(truncatingIfNeeded: UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16
                  | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
        }
        var added: [String] = []
        // The SEI orders the primaries G, B, R; AVMasteringDisplayMetadata R, G, B (libavcodec's
        // `mapping[3] = { 2, 0, 1 }`).
        func fill(_ m: UnsafeMutablePointer<AVMasteringDisplayMetadata>, from md: [UInt8], primaries: Bool, luminance: Bool) {
        }
        if let md = masteringDisplay {
        }
        if let cll = contentLightLevel, !has(AV_PKT_DATA_CONTENT_LIGHT_LEVEL),
           let sd = av_packet_side_data_new(
               &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
               AV_PKT_DATA_CONTENT_LIGHT_LEVEL, MemoryLayout<AVContentLightMetadata>.size, 0) {
            sd.pointee.data.withMemoryRebound(to: AVContentLightMetadata.self, capacity: 1) { c in
                c.pointee.MaxCLL = UInt32(u16(cll, 0))
                c.pointee.MaxFALL = UInt32(u16(cll, 2))
            }
            added.append("clli")
        }
        // Illuminance in 0.0001 lux, chromaticity in 0.00002: libavcodec's denominators again.
        if let amve = ambientViewing, !has(AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT),
           let sd = av_packet_side_data_new(
               &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
               AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT, MemoryLayout<AVAmbientViewingEnvironment>.size, 0) {
            sd.pointee.data.withMemoryRebound(to: AVAmbientViewingEnvironment.self, capacity: 1) { a in
                a.pointee.ambient_illuminance = AVRational(num: u32(amve, 0), den: 10000)
                a.pointee.ambient_light_x = AVRational(num: u16(amve, 4), den: 50000)
                a.pointee.ambient_light_y = AVRational(num: u16(amve, 6), den: 50000)
            }
            added.append("amve")
        }
        return added
    }
}

extension HLSVideoEngine {

    /// Whether this session's FEL is composed over AVPlayer (`felTap`): the picture on screen is then the master.
    var composesFEL: Bool {
        #if DualLayerDolbyVision
        felTap != nil
        #else
        false
        #endif
    }

    /// Look for the in-band HDR10 static metadata a source's codecpar does not state completely
    /// (`InBandHDRStaticMetadata`): first in the config record, then in the first video access units. The
    /// messages ride the first IRAP, so a short budget covers every encoder measured. With
    /// `readsDolbyVisionRPU` the same access units also yield the first RPU's base-layer range and L6. A VOD source
    /// is scanned like the parameter-set scan (rewound, consumed, `start()` seeks back to 0); a live one is only
    /// peeked, so its packets stay queued for the producer. No head read when the record answered everything.
    func scanInBandHDRStaticMetadata(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>,
        framing measuredFraming: VideoNALFraming?,
        isLive: Bool,
        readsDolbyVisionRPU: Bool = false
    ) -> InBandHDRStaticMetadata {
        var metadata = InBandHDRStaticMetadata()
        let par = codecpar.pointee
        guard par.codec_id == AV_CODEC_ID_HEVC || par.codec_id == AV_CODEC_ID_H264 else { return metadata }
        let hasLightLevel = av_packet_side_data_get(
            par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) != nil
        let wantsTransfer = InBandHDRStaticMetadata.wantsAlternativeTransfer(
            primaries: par.color_primaries, transfer: par.color_trc)
        let wantsStatic = InBandHDRStaticMetadata.wantsStaticMetadata(
            transfer: par.color_trc, hasMastering: hasMastering, hasLightLevel: hasLightLevel)
        let framing = measuredFraming ?? NALUnitChain.lengthPrefixSize(
            codecID: par.codec_id, extradata: par.extradata, extradataSize: Int(par.extradata_size)
        ).map { .lengthPrefixed(size: $0) } ?? .annexB

        // Counted in video packets, with a second cap on all packets (same budgets as the in-band
        // parameter-set scan, which reads the same access units).
        let packetBudget = 8
        var videoPackets = 0
        let inspect: (UnsafeMutablePointer<AVPacket>) -> Bool = { pkt in
            guard pkt.pointee.stream_index == videoStreamIndex else { return false }
            videoPackets += 1
            if let data = pkt.pointee.data {
                metadata.collect(from: data, size: Int(pkt.pointee.size), codecID: par.codec_id, framing: framing)
                if readsRange { metadata.collectDolbyVisionRPU(from: data, size: Int(pkt.pointee.size), framing: framing) }
            }
            return done() || videoPackets >= packetBudget
        }
        if isLive {
            try? demuxer.peekPackets(maxPackets: 512, inspect)
        } else {
        }
        return metadata
    }
}
