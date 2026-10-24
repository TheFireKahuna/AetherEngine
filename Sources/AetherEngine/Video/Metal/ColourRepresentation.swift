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
    case refused(String)

    var converts: Bool {
        switch self {
        case .nonConstantLuminance, .ycgco, .ycgcoR, .identity: true
        case .tagged, .refused: false
        }
    }

    /// The representation of a picture in `format` declaring `matrix` and `primaries`.
    static func resolve(format: AVPixelFormat, matrix: AVColorSpace, primaries: AVColorPrimaries) -> ColourRepresentation {
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
            return .refused("constant-luminance matrix")
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
