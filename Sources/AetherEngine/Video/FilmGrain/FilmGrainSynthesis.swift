// AV1 film grain synthesis (AV1 7.18.3), the per-frame half: the grain templates, the scaling tables and the block
// offsets, written into the buffer the finisher's shader reads (FilmGrainShaderSource). The structure follows dav1d's
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

/// The per-frame tables, laid out as `FilmGrainShaderSource` reads them. Everything here is serial by nature (one LFSR
/// stream, a causal auto-regressive filter) and small: about 6,000 template samples a plane, a 2^BitDepth-entry table
/// per plane, one byte per 32 x 32 block.
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

    /// Writes the tables for one `width` x `height` frame of `p` at `buffer`, which holds `bufferLength(width:height:)`
    /// bytes.
    static func write(_ p: FilmGrainParameters, width: Int, height: Int, into buffer: UnsafeMutableRawPointer) {
        let header = buffer.bindMemory(to: Int32.self, capacity: headerWords)
        header.update(repeating: 0, count: headerWords)
        let depthMinus8 = p.bitDepth - 8
        let activeY = !p.yPoints.isEmpty
        let activeCb = !p.monochrome && (p.chromaScalingFromLuma || !p.cbPoints.isEmpty)
        let activeCr = !p.monochrome && (p.chromaScalingFromLuma || !p.crPoints.isEmpty)
        func set(_ word: Header, _ value: Int) { header[word.rawValue] = Int32(value) }
        set(.scalingShift, p.scalingShift)
        set(.minValue, p.clipToRestrictedRange ? 16 << depthMinus8 : 0)
        set(.maxLuma, p.clipToRestrictedRange ? 235 << depthMinus8 : (256 << depthMinus8) - 1)
        set(.maxChroma, p.clipToRestrictedRange ? (p.identityMatrix ? 235 : 240) << depthMinus8 : (256 << depthMinus8) - 1)
        set(.overlap, p.overlap ? 1 : 0)
        set(.chromaScalingFromLuma, p.chromaScalingFromLuma ? 1 : 0)
        set(.activeY, activeY ? 1 : 0)
        set(.activeCb, activeCb ? 1 : 0)
        set(.activeCr, activeCr ? 1 : 0)
        set(.cbMult, p.cbMult)
        set(.crMult, p.crMult)
        set(.cbLumaMult, p.cbLumaMult)
        set(.crLumaMult, p.crLumaMult)
        set(.cbOffset, p.cbOffset)
        set(.crOffset, p.crOffset)
        set(.blockColumns, blocks(width))
        set(.bitDepthMinus8, depthMinus8)

        let templates = UnsafeMutableBufferPointer(
            start: (buffer + templatesOffset).bindMemory(to: Int16.self, capacity: 3 * templateWidth * templateHeight),
            count: 3 * templateWidth * templateHeight)
        let plane = templateWidth * templateHeight
        let luma = UnsafeMutableBufferPointer(rebasing: templates[0..<plane])
        generateLuma(p, into: luma)
        if activeCb { generateChroma(p, cr: false, luma: UnsafeBufferPointer(luma), into: UnsafeMutableBufferPointer(rebasing: templates[plane..<2 * plane])) }
        if activeCr { generateChroma(p, cr: true, luma: UnsafeBufferPointer(luma), into: UnsafeMutableBufferPointer(rebasing: templates[2 * plane..<3 * plane])) }

        let scaling = (buffer + scalingOffset).bindMemory(to: UInt8.self, capacity: 3 * scalingStride)
        // Chroma scaled from luma reads luma's table, which is all 0 with no luma points: chroma is still clipped.
        if activeY || p.chromaScalingFromLuma { generateScaling(p.yPoints, bitDepth: p.bitDepth, into: scaling) }
        if !p.cbPoints.isEmpty { generateScaling(p.cbPoints, bitDepth: p.bitDepth, into: scaling + scalingStride) }
        if !p.crPoints.isEmpty { generateScaling(p.crPoints, bitDepth: p.bitDepth, into: scaling + 2 * scalingStride) }

        writeOffsets(seed: p.seed, width: width, height: height,
                     into: (buffer + offsetsOffset).bindMemory(to: UInt8.self, capacity: blocks(width) * blocks(height)))
    }

    // MARK: - Random numbers (7.18.3.2)

    /// The 16-bit LFSR.
    struct Random {
        var state: UInt32

        init(_ seed: UInt32) { state = seed }

        @inline(__always)
        mutating func next(_ bits: Int) -> Int {
            let r = state
            let bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1
            state = (r >> 1) | (bit << 15)
            return Int((state >> UInt32(16 - bits)) & ((1 << UInt32(bits)) - 1))
        }
    }

    @inline(__always)
    static func round2(_ x: Int, _ shift: Int) -> Int { (x + ((1 << shift) >> 1)) >> shift }

    // MARK: - Grain templates (7.18.3.3)

    static func generateLuma(_ p: FilmGrainParameters, into buf: UnsafeMutableBufferPointer<Int16>) {
        let w = templateWidth, h = templateHeight
        // No luma points: luma takes no grain and chroma's auto-regression no luma term, so the template is never read.
        guard !p.yPoints.isEmpty else { buf.update(repeating: 0); return }
        var random = Random(UInt32(p.seed))
        let shift = 4 - (p.bitDepth - 8) + p.grainScaleShift
        for i in 0..<(w * h) { buf[i] = Int16(round2(Int(gaussianSequence[random.next(11)]), shift)) }
        let (grainMin, grainMax) = grainRange(p.bitDepth)
        let lag = p.arCoeffLag
        let coefficients = p.arCoeffsY.map(Int.init)
        for y in 3..<h {
            for x in 3..<(w - 3) {
                var sum = 0, k = 0
                rows: for dy in -lag...0 {
                    for dx in -lag...lag {
                        if dy == 0 && dx == 0 { break rows }
                        sum += coefficients[k] * Int(buf[(y + dy) * w + x + dx])
                        k += 1
                    }
                }
                buf[y * w + x] = Int16(clamp(Int(buf[y * w + x]) + round2(sum, p.arCoeffShift), grainMin, grainMax))
            }
        }
    }

    static func generateChroma(_ p: FilmGrainParameters, cr: Bool, luma: UnsafeBufferPointer<Int16>,
                               into buf: UnsafeMutableBufferPointer<Int16>) {
        let stride = templateWidth
        let w = p.subsamplingX != 0 ? subTemplateWidth : templateWidth
        let h = p.subsamplingY != 0 ? subTemplateHeight : templateHeight
        var random = Random(UInt32(p.seed) ^ (cr ? 0x49d8 : 0xb524))
        let shift = 4 - (p.bitDepth - 8) + p.grainScaleShift
        for y in 0..<h {
            for x in 0..<w { buf[y * stride + x] = Int16(round2(Int(gaussianSequence[random.next(11)]), shift)) }
        }
        let (grainMin, grainMax) = grainRange(p.bitDepth)
        let lag = p.arCoeffLag
        let coefficients = (cr ? p.arCoeffsCr : p.arCoeffsCb).map(Int.init)
        let sx = p.subsamplingX, sy = p.subsamplingY
        for y in 3..<h {
            for x in 3..<(w - 3) {
                var sum = 0, k = 0
                rows: for dy in -lag...0 {
                    for dx in -lag...lag {
                        if dy == 0 && dx == 0 {
                            // The current sample: the luma template's, averaged over the subsampling.
                            guard !p.yPoints.isEmpty else { break rows }
                            var l = 0
                            let lumaX = ((x - 3) << sx) + 3, lumaY = ((y - 3) << sy) + 3
                            for i in 0...sy { for j in 0...sx { l += Int(luma[(lumaY + i) * templateWidth + lumaX + j]) } }
                            sum += round2(l, sx + sy) * coefficients[k]
                            break rows
                        }
                        sum += coefficients[k] * Int(buf[(y + dy) * stride + x + dx])
                        k += 1
                    }
                }
                buf[y * stride + x] = Int16(clamp(Int(buf[y * stride + x]) + round2(sum, p.arCoeffShift), grainMin, grainMax))
            }
        }
    }

    static func grainRange(_ bitDepth: Int) -> (Int, Int) {
        let centre = 128 << (bitDepth - 8)
        return (-centre, centre - 1)
    }

    @inline(__always)
    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }

    // MARK: - Scaling (7.18.3.4, and scale_lut of 7.18.3.5 expanded to every code)

    /// The 2^bitDepth-entry table of the piecewise-linear scaling function through `points` ((value, scaling) pairs).
    static func generateScaling(_ points: [UInt8], bitDepth: Int, into scaling: UnsafeMutablePointer<UInt8>) {
        let shiftX = bitDepth - 8
        let size = 1 << bitDepth
        let count = points.count / 2
        guard count > 0 else { scaling.update(repeating: 0, count: size); return }
        func x(_ i: Int) -> Int { Int(points[2 * i]) }
        func y(_ i: Int) -> Int { Int(points[2 * i + 1]) }
        scaling.update(repeating: UInt8(y(0)), count: x(0) << shiftX)
        for i in 0..<(count - 1) {
            let bx = x(i), by = y(i), dx = x(i + 1) - bx, dy = y(i + 1) - by
            // Divide first, then multiply (AV1 7.18.3.4).
            let delta = dy * ((0x10000 + (dx >> 1)) / dx)
            var d = 0x8000
            for k in 0..<dx {
                scaling[(bx + k) << shiftX] = UInt8(truncatingIfNeeded: by + (d >> 16))
                d += delta
            }
        }
        let last = x(count - 1) << shiftX
        (scaling + last).update(repeating: UInt8(y(count - 1)), count: size - last)
        guard shiftX > 0 else { return }
        // Between two 8-bit entries, Round2( (end - start) * rem, BitDepth - 8 ) as scale_lut interpolates.
        let pad = 1 << shiftX, rnd = pad >> 1
        for i in 0..<(count - 1) {
            let bx = x(i) << shiftX, dx = (x(i + 1) << shiftX) - bx
            var k = 0
            while k < dx {
                let start = Int(scaling[bx + k]), range = Int(scaling[bx + k + pad]) - start
                var r = rnd
                for n in 1..<pad {
                    r += range
                    scaling[bx + k + n] = UInt8(truncatingIfNeeded: start + (r >> shiftX))
                }
                k += pad
            }
        }
    }

    // MARK: - Block offsets (7.18.3.5)

    /// One 8-bit draw per 32 x 32 luma block, from an LFSR re-seeded every block row; all planes share it.
    static func writeOffsets(seed: UInt16, width: Int, height: Int, into offsets: UnsafeMutablePointer<UInt8>) {
        let columns = blocks(width)
        for row in 0..<blocks(height) {
            var random = Random(UInt32(seed) ^ (UInt32((row * 37 + 178) & 0xFF) << 8) ^ UInt32((row * 173 + 105) & 0xFF))
            for column in 0..<columns { offsets[row * columns + column] = UInt8(random.next(8)) }
        }
    }
}
