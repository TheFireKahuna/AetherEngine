import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The init's `colr` range is the one its picture is decoded with: the parameter sets', whatever the container said.
/// The software decoders take the same range for their pictures (`ColorDescription(decoding:)`).
///
/// The records are real: libx265 / libx264 encodes of a black-and-white test card, stream-copied into MP4 with a
/// `colr` that contradicts the SPS, the clips `research/colour-range-dv/tools/make_range_clips.sh` builds. On every one
/// VideoToolbox decoded by the SPS (`probes/cm-parameter-set-range`): the SPS-limited ones gave black 65 / white 940
/// under a full-range `colr`, the SPS-full one needed conversion into video range, and an SPS with no
/// `video_signal_type` decoded as limited.
@Suite("Range follows the parameter sets: the init's colr and the software decoders")
struct BitstreamVideoRangeTests {

    static func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            let i = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[i..<hex.index(i, offsetBy: 2)], radix: 16)!
        }
    }

    /// HEVC Main10, SPS `video_full_range_flag` 0 (clip A; clip B is the same stream under a full-range `colr`).
    static let hevcLimited = bytes(
        "0102200000009000000000003cf000fcfdfafa00000f03a00001001840010c01ffff02200000030090000003000003003c959809a1"
        + "0001002d42010102200000030090000003000003003ca00808081365959a4932bc05a80808082000000300200000030301a2000100"
        + "074401c172b46240")
    /// The same SPS with `video_full_range_flag` 1 (clip D, under a limited `colr`): one bit apart.
    static let hevcFull = bytes(
        "0102200000009000000000003cf000fcfdfafa00000f03a00001001840010c01ffff02200000030090000003000003003c959809a1"
        + "0001002d42010102200000030090000003000003003ca00808081365959a4932bc05b80808082000000300200000030301a2000100"
        + "074401c172b46240")
    /// An x265 CLI encode whose VUI has no `video_signal_type` (clip J).
    static let hevcNoSignalType = bytes(
        "0102200000009000000000003cf000fcfdfafa00000f03a00001001840010c01ffff02200000030090000003000003003c959809a1"
        + "0001002742010102200000030090000003000003003ca00808081365959a4932b80400000fa00001770020a2000100074401c172b4"
        + "6240")
    /// H.264 High, SPS limited under a full-range `colr` (clip K), SPS full under a limited one (L), no signal type (M).
    static let h264Limited = bytes(
        "0164000cffe1001b6764000cacd941011b016a020202800000030080000018078a14cb01000668ebe3cb22c0fdf8f800")
    static let h264Full = bytes(
        "0164000cffe1001b6764000cacd941011b016e020202800000030080000018078a14cb01000668ebe3cb22c0fdf8f800")
    static let h264NoSignalType = bytes(
        "0164000cffe100196764000cacd941011b011000000300100000030300f142996001000668ebe3cb22c0fdf8f800")

    @Test("HEVC: the SPS's range, limited where it signals none",
          arguments: [(hevcLimited, AVCOL_RANGE_MPEG), (hevcFull, AVCOL_RANGE_JPEG), (hevcNoSignalType, AVCOL_RANGE_MPEG)])
    func hevc(record: [UInt8], expected: AVColorRange) {
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_HEVC, record: record) == expected)
    }

    @Test("H.264: the SPS's range, limited where it signals none",
          arguments: [(h264Limited, AVCOL_RANGE_MPEG), (h264Full, AVCOL_RANGE_JPEG), (h264NoSignalType, AVCOL_RANGE_MPEG)])
    func h264(record: [UInt8], expected: AVColorRange) {
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_H264, record: record) == expected)
    }

    @Test("the same parameter sets as Annex B extradata read the same")
    func annexB() throws {
        let sets = try #require(BitstreamVideoRange.hevcParameterSets(Self.hevcFull))
        let startCode: [UInt8] = [0, 0, 0, 1]
        let annexB = startCode + sets.vps + startCode + sets.sps + startCode + sets.pps
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_HEVC, record: annexB) == AVCOL_RANGE_JPEG)
    }

    @Test("nothing to read gives no answer, so the container's range stands")
    func nothingToRead() {
        // An hvcC with numOfArrays 0: the parameter sets are in-band only.
        var empty = Array(Self.hevcLimited[0..<23])
        empty[22] = 0
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_HEVC, record: empty) == nil)
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_HEVC, record: []) == nil)
        #expect(BitstreamVideoRange.range(codecID: AV_CODEC_ID_AV1, record: Self.hevcFull) == nil)
    }

    @Test("the in-band init's colour reads the same range through the shared reader")
    func sharedReader() throws {
        let sets = try #require(BitstreamVideoRange.hevcParameterSets(Self.hevcFull))
        let colour = try #require(HEVCInBandColour.colourDescription(vps: sets.vps, sps: sets.sps, pps: sets.pps))
        #expect(colour.range == AVCOL_RANGE_JPEG)
        #expect(colour.primaries == AVCOL_PRI_BT709)
    }
    /// codecpar as a demuxer leaves it: `container` is the container's range, `record` the extradata.
    private static func decodingRange(codec: AVCodecID, record: [UInt8], container: AVColorRange) throws -> AVColorRange {
        let par = try #require(avcodec_parameters_alloc())
        defer { var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = codec
        par.pointee.color_range = container
        if !record.isEmpty {
            let bytes = try #require(av_mallocz(record.count + Int(AV_INPUT_BUFFER_PADDING_SIZE)))
                .assumingMemoryBound(to: UInt8.self)
            record.withUnsafeBufferPointer { bytes.update(from: $0.baseAddress!, count: record.count) }
            par.pointee.extradata = bytes
            par.pointee.extradata_size = Int32(record.count)
        }
        return ColorDescription(decoding: par).range
    }

    @Test("a decoder takes the SPS's range over the container's, limited where the SPS signals none",
          arguments: [(AV_CODEC_ID_H264, h264NoSignalType, AVCOL_RANGE_JPEG, AVCOL_RANGE_MPEG),
                      (AV_CODEC_ID_H264, h264Limited, AVCOL_RANGE_JPEG, AVCOL_RANGE_MPEG),
                      (AV_CODEC_ID_H264, h264Full, AVCOL_RANGE_MPEG, AVCOL_RANGE_JPEG),
                      (AV_CODEC_ID_HEVC, hevcNoSignalType, AVCOL_RANGE_JPEG, AVCOL_RANGE_MPEG),
                      (AV_CODEC_ID_HEVC, hevcFull, AVCOL_RANGE_MPEG, AVCOL_RANGE_JPEG)])
    func decoderRange(codec: AVCodecID, record: [UInt8], container: AVColorRange, expected: AVColorRange) throws {
        #expect(try Self.decodingRange(codec: codec, record: record, container: container) == expected)
    }

    @Test("a stream with no parameter sets to read keeps the container's range")
    func decoderRangeWithoutSets() throws {
        #expect(try Self.decodingRange(codec: AV_CODEC_ID_MPEG2VIDEO, record: [], container: AVCOL_RANGE_JPEG) == AVCOL_RANGE_JPEG)
        #expect(try Self.decodingRange(codec: AV_CODEC_ID_H264, record: [], container: AVCOL_RANGE_JPEG) == AVCOL_RANGE_JPEG)
        #expect(try Self.decodingRange(codec: AV_CODEC_ID_AV1, record: Self.hevcFull, container: AVCOL_RANGE_MPEG) == AVCOL_RANGE_MPEG)
    }
}
