import Foundation

/// Pump-local evidence that an HEVC access unit no longer matches the sample description, `H264ConfigurationTracker`'s
/// counterpart: an IRAP picture whose SPS has a decoder signature (`HEVCSPS.decoderSignature`: dimensions, chroma format,
/// bit depths) that the init's `hvcC` does not carry. A new PPS, VUI or level is not one: the samples keep their in-band
/// parameter sets (#365) and the native decoder takes them. Base layer only: a second layer's sets and pictures (MV-HEVC,
/// a scalable layer) are its own. No frames are decoded; only parameter sets and the first bytes of IRAP slice headers
/// are read.
struct HEVCConfigurationTracker {
    struct Mismatch: Sendable, Equatable {
        let width: Int
        let height: Int
        let spsID: Int
        var summary: String { "HEVC active SPS differs from native init: \(width)x\(height), SPS=\(spsID)" }
    }

    private let baselineSignatures: Set<[Int]>
    private var sps: [Int: HEVCSPS] = [:]
    /// pps_pic_parameter_set_id to pps_seq_parameter_set_id.
    private var pps: [Int: Int] = [:]
    private let framing: A53SEIParser.NALFraming

    /// `hvcC`: the init's HEVCDecoderConfigurationRecord (ISO/IEC 14496-15 8.3.3.1). nil when it carries no usable SPS.
    init?(hvcC: [UInt8], framing: A53SEIParser.NALFraming) {
        guard hvcC.count >= 23, hvcC[0] == 1 else { return nil }
        self.framing = framing
        var cursor = 23
        var signatures = Set<[Int]>()
        for _ in 0..<Int(hvcC[22]) {
            guard cursor + 3 <= hvcC.count else { return nil }
            let type = hvcC[cursor] & 0x3F
            let count = Int(hvcC[cursor + 1]) << 8 | Int(hvcC[cursor + 2])
            cursor += 3
            for _ in 0..<count {
                guard cursor + 2 <= hvcC.count else { return nil }
                let size = Int(hvcC[cursor]) << 8 | Int(hvcC[cursor + 1])
                cursor += 2
                guard size > 0, cursor + size <= hvcC.count else { return nil }
                let nal = Array(hvcC[cursor..<(cursor + size)])
                cursor += size
                if type == 33, let parsed = HEVCSPS(nal: nal) {
                    sps[parsed.id] = parsed
                    signatures.insert(parsed.decoderSignature)
                } else if type == 34, let ids = Self.pictureIDs(nal) {
                    pps[ids.pps] = ids.sps
                }
            }
        }
        guard !signatures.isEmpty else { return nil }
        baselineSignatures = signatures
    }

    /// Reads one access unit in NAL order (sets announced after a slice do not describe that slice).
    mutating func observe(_ bytes: UnsafeBufferPointer<UInt8>) -> Mismatch? {
        guard let base = bytes.baseAddress else { return nil }
        var mismatch: Mismatch?
        A53SEIParser.forEachNAL(base, bytes.count, framing) { nal, length in
            guard mismatch == nil, length > 2, HEVCSPS.isBaseLayer(nal) else { return }
            let type = (nal[0] >> 1) & 0x3F
            switch type {
            case 33:
                if let parsed = HEVCSPS(nal: nal, length: length) { sps[parsed.id] = parsed }
            case 34:
                if let ids = Self.pictureIDs(Array(UnsafeBufferPointer(start: nal, count: min(length, 32)))) {
                    pps[ids.pps] = ids.sps
                }
            case 16...23:
                var r = H264SPS.BitReader(A53SEIParser.unescapeRBSP(nal + 2, min(length, 16) - 2))
                // first_slice_segment_in_pic_flag, no_output_of_prior_pics_flag, slice_pic_parameter_set_id
                guard r.flag() == true, r.flag() != nil, let ppsID = r.ue(), let spsID = pps[ppsID],
                      let active = sps[spsID], !baselineSignatures.contains(active.decoderSignature) else { return }
                mismatch = Mismatch(width: active.width, height: active.height, spsID: spsID)
            default:
                break
            }
        }
        return mismatch
    }

    /// pps_pic_parameter_set_id and pps_seq_parameter_set_id of a PPS NAL (2-byte header included).
    static func pictureIDs(_ nal: [UInt8]) -> (pps: Int, sps: Int)? {
        guard nal.count > 2 else { return nil }
        var r = H264SPS.BitReader(A53SEIParser.unescapeRBSP(nal.withUnsafeBufferPointer { $0.baseAddress! } + 2, min(nal.count, 32) - 2))
        guard let ppsID = r.ue(), ppsID <= 63, let spsID = r.ue(), spsID <= 15 else { return nil }
        return (ppsID, spsID)
    }
}
