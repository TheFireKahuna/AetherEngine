// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import Dovi
import AetherLibavutil

/// The colour conversion of a Dolby Vision picture whose signal is IPT-PQ-c2 (profile 5, AV1 profile 10.0), as its
/// RPU's display-management data states it, in the layout `dovi_ipt_to_bt2020` takes (`DoviIptConversion` in
/// DolbyVisionFEL.metal):
/// - `ycc_to_rgb`: the opponent signal (I, Ct, Cp) to the non-linear trichromatic one (L'M'S'), after `ycc_to_rgb_offset`
///   is subtracted. Coefficients over 2^13, offsets over 2^28, as the RPU carries them;
/// - the ST 2084 EOTF on each component;
/// - `rgb_to_lms` (over 2^14), the linear trichromatic signal to LMS (for IPT-PQ-c2, the inverse of its crosstalk),
///   then ``lmsToBT2020`` to linear BT.2020 RGB, as one matrix.
struct DoviIptConversion {
    /// 21 words: `ycc_to_lms` (9, row major), `ycc_offset` (3), `lms_to_rgb` (9, row major).
    let words: [Float]

    /// The XYZ to LMS matrix IPT-PQ-c2 is defined with: the Hunt-Pointer-Estevez matrix normalised to D65, after which
    /// ``crosstalk`` is mixed in.
    static let xyzToCrosstalkLms: [[Double]] = [
        [0.379702729270854, 0.702595741823277, -0.058294843714358],
        [-0.209241415246258, 1.132854830780842, 0.060621130953413],
        [0.003478802327033, 0.037458174951104, 0.880793856972993],
    ]

    /// The crosstalk c of IPT-PQ-c2: each of L, M and S keeps 1 - 2c of itself and takes c of each of the others.
    static let crosstalk = 0.02

    /// LMS (the crosstalk taken out, as the RPU's `rgb_to_lms` does) to linear BT.2020 RGB: the Hunt-Pointer-Estevez
    /// matrix inverted, then XYZ to BT.2020 RGB. Both are normalised to the same D65, so LMS (1, 1, 1), every
    /// neutral of the IPT signal, is RGB (1, 1, 1). The RPU does not carry this step.
    static let lmsToBT2020: [Double] = {
        let c = crosstalk
        let mix = ColourAffine(m: [[1 - 2 * c, c, c], [c, 1 - 2 * c, c], [c, c, 1 - 2 * c]], b: [0, 0, 0])
        let lmsToXYZ = ColourAffine(m: xyzToCrosstalkLms, b: [0, 0, 0]).inverse!.after(mix)
        let xyzToRGB = ColourRepresentation.rgbToXYZ(primaries: Int32(AVCOL_PRI_BT2020.rawValue))!.inverse!
        return xyzToRGB.after(lmsToXYZ).m.flatMap { $0 }
    }()

    /// The signal colour space of an IPT picture (`signal_color_space` 2, ICtCp in the display-management syntax).
    static let iptColorSpace: UInt8 = 2

    /// `a` x `b`, 3 x 3, row major.
    static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        (0..<9).map { i in
            let row = i / 3, column = i % 3
            return (0..<3).reduce(0) { $0 + a[row * 3 + $1] * b[$1 * 3 + column] }
        }
    }
}

extension DoviIptConversion {
    /// The conversion `rpu` carries; nil when it carries none for an IPT signal (no display-management data, a
    /// compressed payload that leaves the matrices out, or another colour space).
    init?(rpu: OpaquePointer) {
        guard let dm = dovi_rpu_get_vdr_dm_data(rpu) else { return nil }
        defer { dovi_rpu_free_vdr_dm_data(dm) }
        let d = dm.pointee
        guard !d.compressed, d.signal_color_space == Self.iptColorSpace else { return nil }
        let ycc = [d.ycc_to_rgb_coef0, d.ycc_to_rgb_coef1, d.ycc_to_rgb_coef2, d.ycc_to_rgb_coef3, d.ycc_to_rgb_coef4,
                   d.ycc_to_rgb_coef5, d.ycc_to_rgb_coef6, d.ycc_to_rgb_coef7, d.ycc_to_rgb_coef8]
            .map { Double($0) / 8192 }
        let offsets = [d.ycc_to_rgb_offset0, d.ycc_to_rgb_offset1, d.ycc_to_rgb_offset2].map { Double($0) / 268_435_456 }
        let rgbToLms = [d.rgb_to_lms_coef0, d.rgb_to_lms_coef1, d.rgb_to_lms_coef2, d.rgb_to_lms_coef3, d.rgb_to_lms_coef4,
                        d.rgb_to_lms_coef5, d.rgb_to_lms_coef6, d.rgb_to_lms_coef7, d.rgb_to_lms_coef8]
            .map { Double($0) / 16384 }
        self.init(words: (ycc + offsets + Self.multiply(Self.lmsToBT2020, rgbToLms)).map(Float.init))
    }
}
#endif
