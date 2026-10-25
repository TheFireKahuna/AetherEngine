import Foundation
import AetherLibavcodec
import AetherLibavutil

/// The luma range a stream's own parameter sets state, which is the range VideoToolbox decodes it with, for the
/// `colr` of an init the engine serves.
///
/// VideoToolbox converts by the SPS VUI alone, HEVC and H.264 alike: with no `video_signal_type` it decodes limited
/// range (what H.265 E.3.1 and H.264 E.2.1 infer), and a contradicting MP4 `colr` or Matroska `Colour/Range` changes
/// only the format description's `FullRangeVideo` label, not a code. CoreMedia's parameter-set parser reports the same
/// range the decode uses in every case measured (macOS 27; research/colour-range-dv, section 2 and
/// `probes/cm-parameter-set-range`). codecpar is the wrong source: FFmpeg keeps a container's range over the
/// bitstream's after `avformat_find_stream_info` (`demux.c`), so an init built from it could state a range its
/// picture is not decoded with.
enum BitstreamVideoRange {
    /// The range `record`'s parameter sets state (an hvcC / avcC record or Annex B extradata), limited where they
    /// signal none. nil when the record carries no parameter sets to read (in-band only) or for another codec.
    static func range(codecID: AVCodecID, record: [UInt8]) -> AVColorRange? {
        let colour: ColorDescription?
        switch codecID {
        case AV_CODEC_ID_HEVC:
            guard let sets = hevcParameterSets(record) else { return nil }
            colour = HEVCInBandColour.colourDescription(vps: sets.vps, sps: sets.sps, pps: sets.pps)
        case AV_CODEC_ID_H264:
            colour = H264SPS.spsNAL(fromExtradata: record).flatMap(H264SPS.colour(fromNAL:))
        default:
            return nil
        }
        guard let colour else { return nil }
        return colour.range == AVCOL_RANGE_JPEG ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG
    }

    /// The first base-layer VPS, SPS and PPS (2-byte headers) of an hvcC record or of Annex B extradata.
    static func hevcParameterSets(_ record: [UInt8]) -> (vps: [UInt8], sps: [UInt8], pps: [UInt8])? {
        if VideoConfigRecord.isAnnexB(record) {
            let sets = record.withUnsafeBufferPointer { HEVCSPS.parameterSets(fromAnnexB: $0) }
            guard let vps = sets.vps, let sps = sets.sps, let pps = sets.pps else { return nil }
            return (vps, sps, pps)
        }
        guard record.first == 1 else { return nil }
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        let nals = record.withUnsafeBufferPointer { parseHVCCParameterSets($0.baseAddress!, $0.count) }
        for nal in nals where nal.count > 2 && nal.withUnsafeBufferPointer({ HEVCSPS.isBaseLayer($0.baseAddress!) }) {
            switch (nal[0] >> 1) & 0x3F {
            case 32: if vps == nil { vps = nal }
            case 33: if sps == nil { sps = nal }
            case 34: if pps == nil { pps = nal }
            default: break
            }
        }
        guard let vps, let sps, let pps else { return nil }
        return (vps, sps, pps)
    }
}
