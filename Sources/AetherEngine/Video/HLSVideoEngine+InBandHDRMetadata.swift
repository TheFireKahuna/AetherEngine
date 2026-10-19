import Foundation
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

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
/// A container statement wins: only a type the codecpar lacks is added.
struct InBandHDRStaticMetadata: Equatable {
    /// mastering_display_colour_volume payload (24 bytes: G, B, R, white point, max / min luminance).
    var masteringDisplay: [UInt8]?
    /// content_light_level_info payload (4 bytes: max_content_light_level, max_pic_average_light_level).
    var contentLightLevel: [UInt8]?

    var isEmpty: Bool { masteringDisplay == nil && contentLightLevel == nil }

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
        if let md = masteringDisplay, !has(AV_PKT_DATA_MASTERING_DISPLAY_METADATA),
           let sd = av_packet_side_data_new(
               &codecpar.pointee.coded_side_data, &codecpar.pointee.nb_coded_side_data,
               AV_PKT_DATA_MASTERING_DISPLAY_METADATA, MemoryLayout<AVMasteringDisplayMetadata>.size, 0) {
            memset(sd.pointee.data, 0, MemoryLayout<AVMasteringDisplayMetadata>.size)
            sd.pointee.data.withMemoryRebound(to: AVMasteringDisplayMetadata.self, capacity: 1) { m in
                // The SEI orders the primaries G, B, R; AVMasteringDisplayMetadata R, G, B
                // (libavcodec's `mapping[3] = { 2, 0, 1 }`).
                let rgb = [2, 0, 1].map { c in
                    (AVRational(num: u16(md, c * 4), den: 50000), AVRational(num: u16(md, c * 4 + 2), den: 50000))
                }
                m.pointee.display_primaries = ((rgb[0].0, rgb[0].1), (rgb[1].0, rgb[1].1), (rgb[2].0, rgb[2].1))
                m.pointee.white_point = (AVRational(num: u16(md, 12), den: 50000),
                                         AVRational(num: u16(md, 14), den: 50000))
                m.pointee.max_luminance = AVRational(num: u32(md, 16), den: 10000)
                m.pointee.min_luminance = AVRational(num: u32(md, 20), den: 10000)
                m.pointee.has_primaries = 1
                m.pointee.has_luminance = 1
            }
            added.append("mdcv")
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
        return added
    }
}

extension HLSVideoEngine {

    /// Look for the in-band HDR10 static metadata in the first video access units of a source whose
    /// codecpar states none (`InBandHDRStaticMetadata`). The messages ride the first IRAP, so a short
    /// budget covers every encoder measured. A VOD source is scanned like the parameter-set scan
    /// (rewound, consumed, `start()` seeks back to 0); a live one is only peeked, so its packets stay
    /// queued for the producer.
    func scanInBandHDRStaticMetadata(
        demuxer: Demuxer,
        videoStreamIndex: Int32,
        codecpar: UnsafePointer<AVCodecParameters>,
        framing measuredFraming: VideoNALFraming?,
        isLive: Bool
    ) -> InBandHDRStaticMetadata {
        var metadata = InBandHDRStaticMetadata()
        let par = codecpar.pointee
        guard par.codec_id == AV_CODEC_ID_HEVC || par.codec_id == AV_CODEC_ID_H264 else { return metadata }
        let hasMastering = av_packet_side_data_get(
            par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA) != nil
        let hasLightLevel = av_packet_side_data_get(
            par.coded_side_data, par.nb_coded_side_data, AV_PKT_DATA_CONTENT_LIGHT_LEVEL) != nil
        guard !hasMastering || !hasLightLevel else { return metadata }
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
            }
            return (metadata.masteringDisplay != nil || hasMastering)
                && (metadata.contentLightLevel != nil || hasLightLevel)
                || videoPackets >= packetBudget
        }
        if isLive {
            try? demuxer.peekPackets(maxPackets: 512, inspect)
        } else {
            scanSourceHead(demuxer: demuxer, rewind: true, readBudget: 512, inspect)
        }
        return metadata
    }
}
