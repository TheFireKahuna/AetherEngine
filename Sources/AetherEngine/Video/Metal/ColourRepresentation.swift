import Foundation
import CoreVideo
import AetherLibavutil

/// What the finisher does with a picture's MatrixCoefficients (docs/colour-representation.md section 4): keep the
/// samples and tag them, convert them to a representation the display layer reads, or refuse.
enum ColourRepresentation: Hashable {
    /// Samples kept: a Y'CbCr matrix CoreVideo tags (1, 5, 6, 7, 9, 14, unspecified), or an RGB / palette format.
    case tagged
    /// MC 0 on planes labelled Y'CbCr: they hold G, B, R (H.273 (48)-(50)) and are encoded as RGB.
    case identity
    /// MC 4 or 12: non-constant luminance with the source's own K_R, K_B, decoded and encoded again.
    case nonConstantLuminance(kr: Double, kb: Double)
    /// MC 8 with equal luma and chroma depths: (54)-(57).
    case ycgco
    /// MC 8 with unequal depths, 16, 17: (62)-(65) at BitDepthRGB.
    case ycgcoR(bitDepthRGB: Int)
    /// MC 10 or 13: constant luminance (66)-(75) through the stream's transfer characteristics.
    case constantLuminance(kr: Double, kb: Double, transfer: TransferCharacteristics)
    case refused(String)

    var converts: Bool {
        switch self {
        case .nonConstantLuminance, .ycgco, .ycgcoR, .identity, .constantLuminance: true
        case .tagged, .refused: false
        }
    }

    /// The representation of a picture in `format` declaring `matrix` and `primaries`.
    static func resolve(format: AVPixelFormat, matrix: AVColorSpace, primaries: AVColorPrimaries,
                        transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED) -> ColourRepresentation {
        guard let desc = av_pix_fmt_desc_get(format)?.pointee else { return .refused("unknown pixel format") }
        let isRGBFormat = desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL) != 0
        if primaries == AVCOL_PRI_SMPTE428 {
            return .refused("SMPTE ST 428 (XYZ) primaries: showing them is a gamut conversion")
        }
        if isRGBFormat { return .tagged }
        let depths = withUnsafeBytes(of: desc.comp) { Array($0.bindMemory(to: AVComponentDescriptor.self)).map { Int($0.depth) } }
        let subsampled = desc.log2_chroma_w != 0 || desc.log2_chroma_h != 0
        switch matrix {
        case AVCOL_SPC_BT709, AVCOL_SPC_UNSPECIFIED, AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M, AVCOL_SPC_SMPTE240M,
             AVCOL_SPC_BT2020_NCL, AVCOL_SPC_ICTCP:
            return .tagged
        case AVCOL_SPC_RGB:
            guard desc.nb_components >= 3, !subsampled else { return .refused("identity (GBR) matrix on subsampled planes") }
            return .identity
        case AVCOL_SPC_FCC:
            return .nonConstantLuminance(kr: 0.30, kb: 0.11)
        case AVCOL_SPC_CHROMA_DERIVED_NCL:
            guard let k = coefficients(primaries: primaries) else {
                return .refused("chromaticity-derived matrix without known colour primaries")
            }
            return .nonConstantLuminance(kr: k.kr, kb: k.kb)
        case AVCOL_SPC_YCGCO:
            guard desc.nb_components >= 3 else { return .refused("YCgCo without chroma") }
            return depths[1] == depths[0] ? .ycgco : .ycgcoR(bitDepthRGB: depths[0])
        case AVCOL_SPC_YCGCO_RE:
            return depths[0] >= 10 ? .ycgcoR(bitDepthRGB: depths[0] - 2) : .refused("YCgCo-Re below 10-bit luma")
        case AVCOL_SPC_YCGCO_RO:
            return depths[0] >= 9 ? .ycgcoR(bitDepthRGB: depths[0] - 1) : .refused("YCgCo-Ro below 9-bit luma")
        case AVCOL_SPC_BT2020_CL, AVCOL_SPC_CHROMA_DERIVED_CL:
            guard desc.nb_components >= 3 else { return .refused("constant luminance without chroma") }
            guard let tf = TransferCharacteristics(transfer) else {
                return .refused("constant luminance with TransferCharacteristics \(transfer.rawValue), which has no inverse here")
            }
            if matrix == AVCOL_SPC_BT2020_CL { return .constantLuminance(kr: 0.2627, kb: 0.0593, transfer: tf) }
            guard let k = coefficients(primaries: primaries) else {
                return .refused("chromaticity-derived matrix without known colour primaries")
            }
            return .constantLuminance(kr: k.kr, kb: k.kb, transfer: tf)
        case AVCOL_SPC_SMPTE2085:
            return .refused("Y'D'zD'x (SMPTE ST 2085): XYZ colour")
        case AVCOL_SPC_IPT_C2:
            return .refused("IPT-C2: Dolby Vision profile 5, decodable only with its RPU")
        default:
            return .refused("reserved MatrixCoefficients \(matrix.rawValue)")
        }
    }

    /// The matrix a converted picture is encoded with and tagged as, by its colour primaries: any non-constant-
    /// luminance matrix carries R'G'B' exactly, so this only picks a tag the display decodes (CoreVideo's P3
    /// matrix tags are deprecated as no longer supported).
    static func targetMatrix(primaries: AVColorPrimaries) -> CFString {
        switch primaries {
        case AVCOL_PRI_BT2020: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case AVCOL_PRI_BT470BG, AVCOL_PRI_SMPTE170M, AVCOL_PRI_SMPTE240M: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
    }

    /// H.273 Table 2: red, green, blue and white (x, y) per ColourPrimaries code.
    static let chromaticities: [Int32: [Double]] = [
        1: [0.640, 0.330, 0.300, 0.600, 0.150, 0.060, 0.3127, 0.3290],
        4: [0.67, 0.33, 0.21, 0.71, 0.14, 0.08, 0.310, 0.316],
        5: [0.64, 0.33, 0.29, 0.60, 0.15, 0.06, 0.3127, 0.3290],
        6: [0.630, 0.340, 0.310, 0.595, 0.155, 0.070, 0.3127, 0.3290],
        7: [0.630, 0.340, 0.310, 0.595, 0.155, 0.070, 0.3127, 0.3290],
        8: [0.681, 0.319, 0.243, 0.692, 0.145, 0.049, 0.310, 0.316],
        9: [0.708, 0.292, 0.170, 0.797, 0.131, 0.046, 0.3127, 0.3290],
        11: [0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.314, 0.351],
        12: [0.680, 0.320, 0.265, 0.690, 0.150, 0.060, 0.3127, 0.3290],
        22: [0.630, 0.340, 0.295, 0.605, 0.155, 0.077, 0.3127, 0.3290],
    ]

    /// K_R, K_B from the colour primaries, H.273 (39)-(44).
    static func coefficients(primaries: AVColorPrimaries) -> (kr: Double, kb: Double)? {
        guard let c = chromaticities[Int32(primaries.rawValue)] else { return nil }
        let (xR, yR, xG, yG, xB, yB, xW, yW) = (c[0], c[1], c[2], c[3], c[4], c[5], c[6], c[7])
        let zR = 1 - (xR + yR), zG = 1 - (xG + yG), zB = 1 - (xB + yB), zW = 1 - (xW + yW)
        let denominator = yW * (xR * (yG * zB - yB * zG) + xG * (yB * zR - yR * zB) + xB * (yR * zG - yG * zR))
        let kr = yR * (xW * (yG * zB - yB * zG) + yW * (xB * zG - xG * zB) + zW * (xG * yB - xB * yG)) / denominator
        let kb = yB * (xW * (yR * zG - yG * zR) + yW * (xG * zR - xR * zG) + zW * (xR * yG - xG * yR)) / denominator
        return (kr, kb)
    }
}

/// An affine map of three values, evaluated by the finisher in double-float: `out[i] = m[i] . in + b[i]`.
struct ColourAffine: Equatable {
    var m: [[Double]]
    var b: [Double]

    static let identity = ColourAffine(m: [[1, 0, 0], [0, 1, 0], [0, 0, 1]], b: [0, 0, 0])

    /// `self` after `first`: x -> self(first(x)).
    func after(_ first: ColourAffine) -> ColourAffine {
        let m3 = (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + m[i][$1] * first.m[$1][j] } } }
        let b3 = (0..<3).map { i in (0..<3).reduce(b[i]) { $0 + m[i][$1] * first.b[$1] } }
        return ColourAffine(m: m3, b: b3)
    }

    /// Y'CbCr codes (d bits each) to E'Y, E'PB, E'PR: the inverse of (30)-(32) or (36)-(38).
    static func decodeYCbCr(depths: [Int], fullRange: Bool) -> ColourAffine {
        func scale(_ d: Int, chroma: Bool) -> (Double, Double) {
            if fullRange {
                let span = pow(2, Double(d)) - 1
                return (1 / span, chroma ? -pow(2, Double(d - 1)) / span : 0)
            }
            let k = pow(2, Double(d - 8))
            return chroma ? (1 / (224 * k), -128.0 / 224) : (1 / (219 * k), -16.0 / 219)
        }
        let s = [scale(depths[0], chroma: false), scale(depths[1], chroma: true), scale(depths[2], chroma: true)]
        return ColourAffine(m: [[s[0].0, 0, 0], [0, s[1].0, 0], [0, 0, s[2].0]], b: [s[0].1, s[1].1, s[2].1])
    }

    /// R'G'B' codes (d bits each) to E'R, E'G, E'B: the inverse of (27)-(29) or (33)-(35).
    static func decodeRGB(depths: [Int], fullRange: Bool) -> ColourAffine {
        let s = depths.map { d -> (Double, Double) in
            fullRange ? (1 / (pow(2, Double(d)) - 1), 0) : (1 / (219 * pow(2, Double(d - 8))), -16.0 / 219)
        }
        return ColourAffine(m: [[s[0].0, 0, 0], [0, s[1].0, 0], [0, 0, s[2].0]], b: [s[0].1, s[1].1, s[2].1])
    }

    /// E'R, E'G, E'B to E'Y, E'PB, E'PR: (45)-(47).
    static func encodeNCL(kr: Double, kb: Double) -> ColourAffine {
        let kg = 1 - kr - kb
        return ColourAffine(m: [[kr, kg, kb],
                                [-0.5 * kr / (1 - kb), -0.5 * kg / (1 - kb), 0.5],
                                [0.5, -0.5 * kg / (1 - kr), -0.5 * kb / (1 - kr)]], b: [0, 0, 0])
    }

    /// E'Y, E'PB, E'PR to E'R, E'G, E'B: the exact inverse of (45)-(47).
    static func decodeNCL(kr: Double, kb: Double) -> ColourAffine {
        let kg = 1 - kr - kb
        // E'R = E'Y + 2 (1 - K_R) E'PR;  E'B = E'Y + 2 (1 - K_B) E'PB;  E'G = ( E'Y - K_R E'R - K_B E'B ) / K_G.
        let r = [1.0, 0, 2 * (1 - kr)], bRow = [1.0, 2 * (1 - kb), 0]
        let g = (0..<3).map { j in ([1.0, 0, 0][j] - kr * r[j] - kb * bRow[j]) / kg }
        return ColourAffine(m: [r, g, bRow], b: [0, 0, 0])
    }

    /// E'Y, E'PB, E'PR to output words: (30)-(32) or (36)-(38) at T bits, times 2^F, before Round.
    static func encodeCodes(targetBits n: Int, fractionBits f: Int, fullRange: Bool) -> ColourAffine {
        let scale = pow(2, Double(f)), t = Double(n)
        if fullRange {
            let span = (pow(2, t) - 1) * scale, mid = pow(2, t - 1) * scale
            return ColourAffine(m: [[span, 0, 0], [0, span, 0], [0, 0, span]], b: [0, mid, mid])
        }
        let k = pow(2, t - 8) * scale
        return ColourAffine(m: [[219 * k, 0, 0], [0, 224 * k, 0], [0, 0, 224 * k]], b: [16 * k, 128 * k, 128 * k])
    }

    /// The finisher's rows: (coefficient hi, lo) for the three inputs, then the offset, per output; 24 floats.
    var doubleFloatRows: [Float] {
        func split(_ v: Double) -> [Float] { let hi = Float(v); return [hi, Float(v - Double(hi))] }
        return (0..<3).flatMap { i in m[i].flatMap(split) + split(b[i]) }
    }
}

/// The transfer characteristics constant luminance runs through (H.273 Table 3), with their constants. alpha and
/// beta are the values H.273 defines them as, the constants that join the segments with continuous value and slope
/// (docs/colour-representation.md section 3).
struct TransferCharacteristics: Hashable {
    let code: UInt32
    /// The kernel's f.tp, in double (see PlanarFrameShaderSource).
    let constants: [Double]

    init?(_ transfer: AVColorTransferCharacteristic) {
        code = UInt32(transfer.rawValue)
        switch transfer {
        case AVCOL_TRC_BT709, AVCOL_TRC_SMPTE170M, AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
            constants = Self.segmented(alpha: 1.09929682680944294, beta: 0.01805396851080781, slope: 4.5, exponent: 0.45)
        case AVCOL_TRC_SMPTE240M:
            constants = Self.segmented(alpha: 1.11157219592173122, beta: 0.02282158552944502, slope: 4.0, exponent: 0.45)
        case AVCOL_TRC_GAMMA22:
            constants = [0, 0, 0, 1 / 2.2, 2.2]
        case AVCOL_TRC_GAMMA28:
            constants = [0, 0, 0, 1 / 2.8, 2.8]
        case AVCOL_TRC_IEC61966_2_1:
            constants = Self.segmented(alpha: 1.05501071894758660, beta: 0.00304128256012752, slope: 12.92, exponent: 1 / 2.4)
        case AVCOL_TRC_SMPTE2084:
            let c1 = 107.0 / 128, c2 = 2413.0 / 128, c3 = 2392.0 / 128, m = 2523.0 / 32, n = 1305.0 / 8192
            constants = [c1, c2, c3, m, n, 1 / m, 1 / n, c2 - c1 * c3]
        case AVCOL_TRC_ARIB_STD_B67:
            let a = 0.17883277
            constants = [a, 0.28466892, 0.55991073, 1 / a]
        case AVCOL_TRC_LINEAR:
            constants = []
        default:
            return nil
        }
    }

    /// alpha, beta, slope, exponent, 1 / exponent, 1 / alpha, 1 / slope, alpha - 1.
    private static func segmented(alpha: Double, beta: Double, slope: Double, exponent: Double) -> [Double] {
        [alpha, beta, slope, exponent, 1 / exponent, 1 / alpha, 1 / slope, alpha - 1]
    }

    /// L from V in double, for the finisher's luma table: the kernel's inverse, values outside the domain clamped to it
    /// ([0, 1]; TC 13 odd-symmetric).
    func inverse(_ v: Double) -> Double {
        let c = constants
        switch code {
        case 1, 6, 14, 15, 7:
            let a = min(max(v, 0), 1)
            return a < c[2] * c[1] ? a / c[2] : pow((a + c[0] - 1) / c[0], c[4])
        case 4, 5: return pow(min(max(v, 0), 1), c[4])
        case 13:
            let a = abs(v)
            let l = a < c[2] * c[1] ? a / c[2] : pow((a + c[0] - 1) / c[0], c[4])
            return v < 0 ? -l : l
        case 16:
            let p = pow(min(max(v, 0), 1), c[5])
            return pow(max(p - c[0], 0) / (c[1] - c[2] * p), c[6])
        case 18:
            let a = min(max(v, 0), 1)
            return a <= 0.5 ? a * a / 3 : (exp((a - c[2]) / c[0]) + c[1]) / 12
        default: return min(max(v, 0), 1)
        }
    }

    /// V = ( L )' in double, for N_B, P_B, N_R, P_R (72)-(75).
    func forward(_ l: Double) -> Double {
        let c = constants
        switch code {
        case 1, 6, 14, 15, 7: return l < c[1] ? c[2] * l : c[0] * pow(l, c[3]) - (c[0] - 1)
        case 4, 5: return pow(l, c[3])
        case 13:
            let a = abs(l)
            let v = a < c[1] ? c[2] * a : c[0] * pow(a, c[3]) - (c[0] - 1)
            return l < 0 ? -v : v
        case 16:
            let ln = pow(l, c[4])
            return pow((c[0] + c[1] * ln) / (1 + c[2] * ln), c[3])
        case 18: return l <= 1.0 / 12 ? (3 * l).squareRoot() : c[0] * log(12 * l - c[1]) + c[2]
        default: return l
        }
    }
}
