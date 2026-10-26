// AV1 film grain synthesis (AV1 7.18.3), the CPU's part: the grain buffer's layout, the header and the synthesis
// arguments of a frame's parameters, and the LFSR's jump matrices; the GPU synthesises the templates, the scaling
// tables and the block offsets into the buffer (FilmGrainShaderSource's fg_synthesize). The structure follows dav1d's
// src/filmgrain_tmpl.c and src/fg_apply_tmpl.c:
//
// Copyright © 2018, Niklas Haas
// Copyright © 2018, VideoLAN and dav1d authors
// Copyright © 2018, Two Orioles, LLC
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
// ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
// ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import AetherLibavutil

/// One shown frame's film grain, as libdav1d resolved it (`AV_FRAME_DATA_FILM_GRAIN_PARAMS`: `update_grain`,
/// `load_grain_params` and `show_existing_frame` already applied) and as AV1 6.8.20 defines its values, with the
/// syntax elements' offsets removed. Equal values give equal grain.
struct FilmGrainParameters: Hashable, Sendable {
    var seed: UInt16
    var bitDepth: Int
    var subsamplingX: Int
    var subsamplingY: Int
    var monochrome: Bool
    /// MatrixCoefficients is MC_IDENTITY: chroma's restricted range ends at 235, as luma's.
    var identityMatrix: Bool
    /// (value, scaling) pairs: luma up to 14, each chroma plane up to 10.
    var yPoints: [UInt8]
    var cbPoints: [UInt8]
    var crPoints: [UInt8]
    var chromaScalingFromLuma: Bool
    /// `grain_scaling_minus_8 + 8`.
    var scalingShift: Int
    var arCoeffLag: Int
    /// `ar_coeffs_*_plus_128 - 128`: 2 lag (lag + 1) for luma, one more for chroma (the luma correlation).
    var arCoeffsY: [Int8]
    var arCoeffsCb: [Int8]
    var arCoeffsCr: [Int8]
    /// `ar_coeff_shift_minus_6 + 6`.
    var arCoeffShift: Int
    var grainScaleShift: Int
    /// `cb_mult - 128`, `cb_luma_mult - 128`, `cb_offset - 256`; Cr likewise.
    var cbMult: Int
    var cbLumaMult: Int
    var cbOffset: Int
    var crMult: Int
    var crLumaMult: Int
    var crOffset: Int
    var overlap: Bool
    var clipToRestrictedRange: Bool

    /// The frame's AV1 grain, or nil when it carries none (no side data, another kind, or `apply_grain` off: libdav1d
    /// attaches nothing then).
    init?(frame: UnsafePointer<AVFrame>) {
        guard let side = av_frame_get_side_data(frame, AV_FRAME_DATA_FILM_GRAIN_PARAMS), let data = side.pointee.data,
              Int(side.pointee.size) >= MemoryLayout<AVFilmGrainParams>.size,
              let desc = av_pix_fmt_desc_get(AVPixelFormat(rawValue: frame.pointee.format))?.pointee else { return nil }
        let p = UnsafeRawPointer(data).loadUnaligned(as: AVFilmGrainParams.self)
        guard p.type == AV_FILM_GRAIN_PARAMS_AV1 else { return nil }
        let a = p.codec.aom
        seed = UInt16(truncatingIfNeeded: p.seed)
        bitDepth = Int(desc.comp.0.depth)
        subsamplingX = Int(desc.log2_chroma_w)
        subsamplingY = Int(desc.log2_chroma_h)
        monochrome = desc.nb_components < 3
        identityMatrix = frame.pointee.colorspace == AVCOL_SPC_RGB
        func bytes<T>(_ tuple: T, count: Int) -> [UInt8] {
            withUnsafeBytes(of: tuple) { Array($0.prefix(count)) }
        }
        func coefficients<T>(_ tuple: T, count: Int) -> [Int8] {
            withUnsafeBytes(of: tuple) { $0.prefix(count).map { Int8(bitPattern: $0) } }
        }
        let lag = Int(a.ar_coeff_lag)
        let positions = 2 * lag * (lag + 1)
        yPoints = bytes(a.y_points, count: 2 * Int(a.num_y_points))
        cbPoints = monochrome ? [] : bytes(a.uv_points.0, count: 2 * Int(a.num_uv_points.0))
        crPoints = monochrome ? [] : bytes(a.uv_points.1, count: 2 * Int(a.num_uv_points.1))
        chromaScalingFromLuma = !monochrome && a.chroma_scaling_from_luma != 0
        scalingShift = Int(a.scaling_shift)
        arCoeffLag = lag
        arCoeffsY = coefficients(a.ar_coeffs_y, count: positions)
        arCoeffsCb = coefficients(a.ar_coeffs_uv.0, count: positions + 1)
        arCoeffsCr = coefficients(a.ar_coeffs_uv.1, count: positions + 1)
        arCoeffShift = Int(a.ar_coeff_shift)
        grainScaleShift = Int(a.grain_scale_shift)
        cbMult = Int(a.uv_mult.0)
        crMult = Int(a.uv_mult.1)
        cbLumaMult = Int(a.uv_mult_luma.0)
        crLumaMult = Int(a.uv_mult_luma.1)
        cbOffset = Int(a.uv_offset.0)
        crOffset = Int(a.uv_offset.1)
        overlap = a.overlap_flag != 0
        clipToRestrictedRange = a.limit_output_range != 0
    }

    /// The planes that take grain: luma with scaling points, chroma with its own or luma's.
    var activeY: Bool { !yPoints.isEmpty }
    var activeCb: Bool { !monochrome && (chromaScalingFromLuma || !cbPoints.isEmpty) }
    var activeCr: Bool { !monochrome && (chromaScalingFromLuma || !crPoints.isEmpty) }

    /// Whether the shader takes these planes: planar, one plane per component, at 8, 10 or 12 bits, as libdav1d writes
    /// every AV1 picture.
    static func supports(_ format: AVPixelFormat) -> Bool {
        guard let desc = av_pix_fmt_desc_get(format)?.pointee else { return false }
        let refused = UInt64(AV_PIX_FMT_FLAG_BE) | UInt64(AV_PIX_FMT_FLAG_PAL) | UInt64(AV_PIX_FMT_FLAG_BITSTREAM)
            | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_FLOAT) | UInt64(AV_PIX_FMT_FLAG_ALPHA)
        guard desc.flags & refused == 0, desc.nb_components == 1 || desc.nb_components == 3 else { return false }
        let comps = [desc.comp.0, desc.comp.1, desc.comp.2].prefix(Int(desc.nb_components))
        return comps.allSatisfy { c in
            [8, 10, 12].contains(c.depth) && c.depth == desc.comp.0.depth && c.offset == 0 && c.shift == 0
                && c.step == (c.depth > 8 ? 2 : 1)
        } && Set(comps.map(\.plane)).count == comps.count
    }
}

/// The per-frame tables, laid out as `FilmGrainShaderSource` reads them: a header the CPU writes, and the templates,
/// scaling tables and block offsets the GPU synthesises in the frame's own batch (`fg_synthesize`). AV1's generator is
/// serial (one LFSR stream, a causal auto-regressive filter), and the GPU takes it exactly: each draw's LFSR state
/// jumped to directly (``jumpColumns``), the filter run as a wavefront, the tables in closed form.
enum FilmGrainSynthesis {
    static let templateWidth = 82
    static let templateHeight = 73
    static let subTemplateWidth = 44
    static let subTemplateHeight = 38
    static let blockSize = 32

    // The buffer: a header of 32 Int32s, three Int16 templates (82 wide whatever the plane's size), three scaling
    // tables of 4096 bytes, then one offset byte per block, row by row.
    static let headerWords = 32
    static let templateBytes = templateWidth * templateHeight * 2
    static let templatesOffset = headerWords * 4
    static let scalingStride = 4096
    static let scalingOffset = (templatesOffset + 3 * templateBytes + 15) & ~15
    static let offsetsOffset = scalingOffset + 3 * scalingStride

    /// Header words.
    enum Header: Int {
        case scalingShift, minValue, maxLuma, maxChroma, overlap, chromaScalingFromLuma
        case activeY, activeCb, activeCr
        case cbMult, crMult, cbLumaMult, crLumaMult, cbOffset, crOffset
        case blockColumns, bitDepthMinus8
    }

    static func blocks(_ length: Int) -> Int { (length + blockSize - 1) / blockSize }

    static func bufferLength(width: Int, height: Int) -> Int {
        offsetsOffset + max(1, blocks(width) * blocks(height))
    }

    /// Writes the header of one `width` x `height` frame of `p` at `buffer`, which holds `bufferLength(width:height:)`
    /// bytes; the templates, the scaling tables and the block offsets are the GPU's (`fg_synthesize`, from
    /// ``synthesisArguments(_:width:height:)``).
    static func writeHeader(_ p: FilmGrainParameters, width: Int, height: Int, into buffer: UnsafeMutableRawPointer) {
        let header = buffer.bindMemory(to: Int32.self, capacity: headerWords)
        header.update(repeating: 0, count: headerWords)
        let depthMinus8 = p.bitDepth - 8
        func set(_ word: Header, _ value: Int) { header[word.rawValue] = Int32(value) }
        set(.scalingShift, p.scalingShift)
        set(.minValue, p.clipToRestrictedRange ? 16 << depthMinus8 : 0)
        set(.maxLuma, p.clipToRestrictedRange ? 235 << depthMinus8 : (256 << depthMinus8) - 1)
        set(.maxChroma, p.clipToRestrictedRange ? (p.identityMatrix ? 235 : 240) << depthMinus8 : (256 << depthMinus8) - 1)
        set(.overlap, p.overlap ? 1 : 0)
        set(.chromaScalingFromLuma, p.chromaScalingFromLuma ? 1 : 0)
        set(.activeY, p.activeY ? 1 : 0)
        set(.activeCb, p.activeCb ? 1 : 0)
        set(.activeCr, p.activeCr ? 1 : 0)
        set(.cbMult, p.cbMult)
        set(.crMult, p.crMult)
        set(.cbLumaMult, p.cbLumaMult)
        set(.crLumaMult, p.crLumaMult)
        set(.cbOffset, p.cbOffset)
        set(.crOffset, p.crOffset)
        set(.blockColumns, blocks(width))
        set(.bitDepthMinus8, depthMinus8)
    }

    /// `fg_synthesize`'s argument (FGParams in the shader) for one `width` x `height` frame of `p`.
    static func synthesisArguments(_ p: FilmGrainParameters, width: Int, height: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        func words(_ values: [Int]) { for v in values { withUnsafeBytes(of: UInt32(truncatingIfNeeded: v)) { bytes += $0 } } }
        func padded(_ values: [UInt8], _ count: Int) { bytes += values + Array(repeating: 0, count: count - values.count) }
        words([Int(p.seed), p.bitDepth, 4 - (p.bitDepth - 8) + p.grainScaleShift, p.arCoeffLag, p.arCoeffShift,
               p.subsamplingX, p.subsamplingY, p.yPoints.count / 2, p.cbPoints.count / 2, p.crPoints.count / 2,
               p.chromaScalingFromLuma ? 1 : 0, p.activeY ? 1 : 0, p.activeCb ? 1 : 0, p.activeCr ? 1 : 0,
               blocks(width), blocks(height)])
        padded(p.yPoints, 28)
        padded(p.cbPoints, 20)
        padded(p.crPoints, 20)
        padded(p.arCoeffsY.map { UInt8(bitPattern: $0) }, 24)
        padded(p.arCoeffsCb.map { UInt8(bitPattern: $0) }, 25)
        padded(p.arCoeffsCr.map { UInt8(bitPattern: $0) }, 25)
        while bytes.count % 4 != 0 { bytes.append(0) }
        return bytes
    }

    // MARK: - Random numbers (7.18.3.2)

    /// The 16-bit LFSR's step, a linear map over GF(2): draw n's state is its n-th power applied to the seed. Columns of
    /// the step's 2^j-th powers, j = 0 ... 12 (a template's 5,986 draws), for the shader's jumps (`fg_jump`): column b
    /// is the state bit b alone becomes.
    static let jumpColumns: [[UInt16]] = {
        func step(_ r: UInt32) -> UInt32 {
            let bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
            return (r >> 1) | (bit << 15)
        }
        func apply(_ columns: [UInt16], _ v: UInt16) -> UInt16 {
            var out: UInt16 = 0
            for b in 0..<16 where v & (1 << b) != 0 { out ^= columns[b] }
            return out
        }
        var powers: [[UInt16]] = [(0..<16).map { UInt16(step(UInt32(1) << $0)) }]
        for _ in 1..<13 {
            let m = powers.last!
            powers.append(m.map { apply(m, $0) })
        }
        return powers
    }()
}
