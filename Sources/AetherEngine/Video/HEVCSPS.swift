import Foundation

/// The leading fields of an H.265 SPS (ITU-T H.265 §7.3.2.2.1), through the bit depths: what a decoder session is
/// built from (dimensions, chroma format, bit depths) and what slice headers need (POC LSB bits). The rest of the SPS,
/// its VUI included, is not read here; CoreMedia reads the colour (`HEVCInBandColour`).
struct HEVCSPS: Equatable {
    let id: Int
    let chromaFormat: Int
    let separateColourPlane: Bool
    /// Cropped to the conformance window, in luma samples.
    let width: Int
    let height: Int
    let bitDepthLuma: Int
    let bitDepthChroma: Int
    let pocLsbBits: Int

    /// What a decoder session is built from: a change here needs a new sample description, a change elsewhere (VUI,
    /// level, the rest of the SPS) plays with the in-band set.
    var decoderSignature: [Int] {
        [chromaFormat, separateColourPlane ? 1 : 0, width, height, bitDepthLuma, bitDepthChroma]
    }

    /// One SPS NAL (2-byte header included, emulation prevention bytes intact). nil when malformed or out of range.
    init?(nal: UnsafePointer<UInt8>, length: Int) {
        guard length > 2, (nal[0] >> 1) & 0x3F == 33 else { return nil }
        // The fields read here sit well inside the first bytes; cap the unescape.
        var r = H264SPS.BitReader(A53SEIParser.unescapeRBSP(nal + 2, min(length, 256) - 2))
        guard r.u(4) != nil, let subLayers = r.u(3), r.u(1) != nil,
              r.skip(88), r.skip(8) else { return nil }             // general profile_tier_level, level_idc
        var present: [(profile: Bool, level: Bool)] = []
        for _ in 0..<subLayers {
            guard let p = r.flag(), let l = r.flag() else { return nil }
            present.append((p, l))
        }
        if subLayers > 0 { guard r.skip(2 * (8 - subLayers)) else { return nil } }
        for p in present {
            guard r.skip(p.profile ? 88 : 0), r.skip(p.level ? 8 : 0) else { return nil }
        }
        // sps_seq_parameter_set_id is at most 15 (7.4.3.2.1).
        guard let id = r.ue(), id <= 15, let chroma = r.ue(), chroma <= 3 else { return nil }
        var separate = false
        if chroma == 3 { guard let f = r.flag() else { return nil }; separate = f }
        guard let codedWidth = r.ue(), let codedHeight = r.ue(), let window = r.flag() else { return nil }
        var crop = [0, 0, 0, 0]   // left, right, top, bottom, in chroma units
        if window {
            for i in 0..<4 { guard let v = r.ue() else { return nil }; crop[i] = v }
        }
        guard let lumaMinus8 = r.ue(), lumaMinus8 <= 8, let chromaMinus8 = r.ue(), chromaMinus8 <= 8,
              let lsb = r.ue(), lsb <= 12 else { return nil }
        // Table 6-1: SubWidthC, SubHeightC (4:4:4 and separate planes are 1, 1).
        let subWidth = (chroma == 1 || chroma == 2) && !separate ? 2 : 1
        let subHeight = chroma == 1 && !separate ? 2 : 1
        let width = codedWidth - subWidth * (crop[0] + crop[1])
        let height = codedHeight - subHeight * (crop[2] + crop[3])
        guard width > 0, height > 0 else { return nil }
        self.id = id
        chromaFormat = chroma
        separateColourPlane = separate
        self.width = width
        self.height = height
        bitDepthLuma = lumaMinus8 + 8
        bitDepthChroma = chromaMinus8 + 8
        pocLsbBits = lsb + 4
    }

    init?(nal: [UInt8]) {
        guard let parsed = nal.withUnsafeBufferPointer({ b in b.baseAddress.flatMap { HEVCSPS(nal: $0, length: b.count) } })
        else { return nil }
        self = parsed
    }

    /// Whether a NAL (2-byte header) belongs to the base layer, nuh_layer_id 0. A second layer (MV-HEVC's other view,
    /// a scalable layer) brings parameter sets and pictures of its own, which say nothing about the base layer's
    /// sample description or colour.
    static func isBaseLayer(_ nal: UnsafePointer<UInt8>) -> Bool {
        (Int(nal[0] & 1) << 5 | Int(nal[1] >> 3)) == 0
    }

    /// The first base-layer VPS, SPS and PPS NALs (2-byte header included) of an Annex B access unit, and whether it
    /// holds a base-layer IRAP picture (NAL types 16-23).
    static func parameterSets(fromAnnexB buf: UnsafeBufferPointer<UInt8>)
        -> (vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?, irap: Bool) {
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?, irap = false
        guard let base = buf.baseAddress else { return (nil, nil, nil, false) }
        A53SEIParser.forEachNAL(base, buf.count, .annexB) { nal, length in
            guard length > 2, isBaseLayer(nal) else { return }
            switch (nal[0] >> 1) & 0x3F {
            case 32: if vps == nil { vps = Array(UnsafeBufferPointer(start: nal, count: length)) }
            case 33: if sps == nil { sps = Array(UnsafeBufferPointer(start: nal, count: length)) }
            case 34: if pps == nil { pps = Array(UnsafeBufferPointer(start: nal, count: length)) }
            case 16...23: irap = true
            default: break
            }
        }
        return (vps, sps, pps, irap)
    }
}
