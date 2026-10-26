// AV1 film grain synthesis (AV1 7.18.3) on the GPU: fg_synthesize, which writes a frame's templates, scaling tables and
// block offsets into its grain buffer, and the per-sample functions the finisher's reader calls for every sample it
// takes, over those tables. The block sampling and overlap blending follow dav1d's
// src/filmgrain_tmpl.c (sample_lut, fgy_32x32xn_c, fguv_32x32xn_c):
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

/// The film grain functions, inserted into the finisher's library after its raw readers. The noise at a sample is a
/// pure function of the templates, its block's offset and, inside an overlap, its left and upper neighbours' offsets,
/// so any sample is grained on its own, wherever and however often the finisher reads it.
enum FilmGrainShaderSource {
    static var source: String {
        typealias S = FilmGrainSynthesis
        func word(_ h: S.Header) -> String { "\(h.rawValue)u" }
        let gauss = S.gaussianSequence.map(String.init).joined(separator: ", ")
        let jumps = S.jumpColumns.map { "{ " + $0.map { "\($0)" }.joined(separator: ", ") + " }" }.joined(separator: ",\n    ")
        return """
// MARK: - Film grain (AV1 7.18.3)

constant uint FG_TEMPLATES = \(S.templatesOffset)u;
constant uint FG_SCALING = \(S.scalingOffset)u;
constant uint FG_SCALING_STRIDE = \(S.scalingStride)u;
constant uint FG_OFFSETS = \(S.offsetsOffset)u;
constant int FG_TW = \(S.templateWidth);
constant int FG_TH = \(S.templateHeight);

static inline int fg_h(device const uchar* g, uint word) { return ((device const int*)g)[word]; }

// The per-sample functions below are kept inline: outlined, the compiler makes them calls with a stack frame of their
// own, from every sample the finisher reads.

// floor( v / 2^n ), exactly, whatever >> does with a negative int: v less its low bits is a multiple of 2^n.
static inline int fg_floor_shift(int v, uint n) { return (v - (v & int((1u << n) - 1u))) / int(1u << n); }

// Round2 (AV1 4.7).
static inline int fg_round2(int v, uint n) { return n == 0u ? v : fg_floor_shift(v + int(1u << (n - 1u)), n); }

// The template sample for block offset `rand`: (bx, by) = (1, 0) reads the left block's continuation, (0, 1) the upper
// block's, (1, 1) the upper left's.
static inline __attribute__((always_inline)) int fg_template(device const uchar* g, uint plane, int rand, uint sx, uint sy, int bx, int by, int x, int y) {
    int offx = 3 + (2 >> sx) * (3 + (rand >> 4));
    int offy = 3 + (2 >> sy) * (3 + (rand & 15));
    device const short* t = (device const short*)(g + FG_TEMPLATES) + int(plane) * FG_TW * FG_TH;
    return int(t[(offy + y + (32 >> sy) * by) * FG_TW + offx + x + (32 >> sx) * bx]);
}

// One overlap blend: 27 / 17 then 17 / 27 across two samples, 23 / 22 across one on a subsampled axis.
static inline __attribute__((always_inline)) int fg_blend(int old, int cur, uint sub, int i, int lo, int hi) {
    int w0 = sub != 0u ? 23 : (i == 0 ? 27 : 17);
    int w1 = sub != 0u ? 22 : (i == 0 ? 17 : 27);
    return clamp(fg_round2(old * w0 + cur * w1, 5u), lo, hi);
}

// The grain at (x, y) of `plane` (0 luma, 1 Cb, 2 Cr) on that plane's grid, subsampled by (sx, sy): horizontal blend
// with the left block, then vertical with the upper one, each rounded and clipped.
static inline __attribute__((always_inline)) int fg_noise(device const uchar* g, uint plane, uint sx, uint sy, uint x, uint y) {
    int dm8 = fg_h(g, \(word(.bitDepthMinus8)));
    int hi = (128 << dm8) - 1, lo = -(128 << dm8);
    uint bw = 32u >> sx, bh = 32u >> sy;
    uint col = x / bw, row = y / bh;
    int lx = int(x - col * bw), ly = int(y - row * bh);
    uint cols = uint(fg_h(g, \(word(.blockColumns))));
    device const uchar* off = g + FG_OFFSETS;
    int grain = fg_template(g, plane, int(off[row * cols + col]), sx, sy, 0, 0, lx, ly);
    bool overlap = fg_h(g, \(word(.overlap))) != 0;
    bool ox = overlap && col > 0u && lx < int(2u >> sx);
    bool oy = overlap && row > 0u && ly < int(2u >> sy);
    if (ox) {
        grain = fg_blend(fg_template(g, plane, int(off[row * cols + col - 1u]), sx, sy, 1, 0, lx, ly), grain, sx, lx, lo, hi);
    }
    if (oy) {
        int top = fg_template(g, plane, int(off[(row - 1u) * cols + col]), sx, sy, 0, 1, lx, ly);
        if (ox) {
            top = fg_blend(fg_template(g, plane, int(off[(row - 1u) * cols + col - 1u]), sx, sy, 1, 1, lx, ly), top, sx, lx, lo, hi);
        }
        grain = fg_blend(top, grain, sy, ly, lo, hi);
    }
    return grain;
}

static inline int fg_scaling(device const uchar* g, uint table, int index) {
    return int(g[FG_SCALING + table * FG_SCALING_STRIDE + uint(index)]);
}

// A luma code with its grain.
static inline __attribute__((always_inline)) uint fg_luma(device const uchar* g, uint v, uint x, uint y) {
    if (fg_h(g, \(word(.activeY))) == 0) { return v; }
    int noise = fg_round2(fg_scaling(g, 0u, int(v)) * fg_noise(g, 0u, 0u, 0u, x, y), uint(fg_h(g, \(word(.scalingShift)))));
    return uint(clamp(int(v) + noise, fg_h(g, \(word(.minValue))), fg_h(g, \(word(.maxLuma)))));
}

// A chroma code of plane 1 + uv with its grain, from `average`, the un-noised luma at its site (the top row's pair
// averaged horizontally when subsampled).
static inline __attribute__((always_inline)) uint fg_chroma(device const uchar* g, uint uv, uint v, uint average, uint sx, uint sy, uint x, uint y) {
    if (fg_h(g, \(word(.activeCb)) + uv) == 0) { return v; }
    int dm8 = fg_h(g, \(word(.bitDepthMinus8)));
    bool fromLuma = fg_h(g, \(word(.chromaScalingFromLuma))) != 0;
    int index = int(average);
    if (!fromLuma) {
        int combined = int(average) * fg_h(g, \(word(.cbLumaMult)) + uv) + int(v) * fg_h(g, \(word(.cbMult)) + uv);
        index = clamp(fg_floor_shift(combined, 6u) + fg_h(g, \(word(.cbOffset)) + uv) * (1 << dm8), 0, (256 << dm8) - 1);
    }
    int noise = fg_round2(fg_scaling(g, fromLuma ? 0u : 1u + uv, index) * fg_noise(g, 1u + uv, sx, sy, x, y),
                          uint(fg_h(g, \(word(.scalingShift)))));
    return uint(clamp(int(v) + noise, fg_h(g, \(word(.minValue))), fg_h(g, \(word(.maxChroma)))));
}
// MARK: - Synthesis (AV1 7.18.3.3 - 7.18.3.5): the templates, the scaling tables and the block offsets, on the GPU

// The Gaussian sequence `get_random_number(11)` indexes.
constant short FG_GAUSS[2048] = { \(gauss) };

// The LFSR's step to the 2^j-th power, j = 0 ... 12, as 16 columns each (FilmGrainSynthesis.jumpColumns).
constant ushort FG_JUMP[13][16] = {
    \(jumps)
};

// The LFSR's state after `n` steps from `state`: the step is linear over GF(2), so n's set bits pick the powers.
static inline uint fg_jump(uint state, uint n) {
    for (uint j = 0u; j < 13u; ++j) {
        if (((n >> j) & 1u) == 0u) { continue; }
        uint out = 0u;
        for (uint b = 0u; b < 16u; ++b) {
            if (((state >> b) & 1u) != 0u) { out ^= uint(FG_JUMP[j][b]); }
        }
        state = out;
    }
    return state;
}

// get_random_number(bits) (7.18.3.2): steps the LFSR, then its top `bits`.
static inline int fg_next(thread uint& state, uint bits) {
    uint r = state;
    uint bit = (r ^ (r >> 1) ^ (r >> 3) ^ (r >> 12)) & 1u;
    state = (r >> 1) | (bit << 15);
    return int((state >> (16u - bits)) & ((1u << bits) - 1u));
}

// Draw n (from 1) of the LFSR seeded with `seed`, `bits` wide.
static inline int fg_draw(uint seed, uint n, uint bits) {
    uint state = fg_jump(seed, n - 1u);
    return fg_next(state, bits);
}

struct FGParams {
    uint seed;
    uint bit_depth;
    uint shift;          // 4 - (BitDepth - 8) + grain_scale_shift
    uint lag;
    uint ar_shift;
    uint sx;
    uint sy;
    uint y_points;       // (value, scaling) pairs
    uint cb_points;
    uint cr_points;
    uint from_luma;      // chroma_scaling_from_luma
    uint active_y;
    uint active_cb;
    uint active_cr;
    uint block_columns;
    uint block_rows;
    uchar y_pts[28];
    uchar cb_pts[20];
    uchar cr_pts[20];
    char ar_y[24];
    char ar_cb[25];
    char ar_cr[25];
};

constant uint FG_THREADS = 256;

// The auto-regressive filter (7.18.3.3) over one template, run as a wavefront: sample (y, x) reads the rows above it up
// to x + lag and the samples to its left, so the anti-diagonal t = x + (lag + 1) y can go once every earlier one has,
// a thread a row, in the raster order's own results. Every thread calls this; `luma` gives chroma its luma term.
static inline void fg_regress(threadgroup short* buf, threadgroup const short* luma, constant char* coeffs,
                              constant FGParams& p, int w, int h, bool chroma, int lo, int hi, uint tid) {
    int lag = int(p.lag);
    int steps = (w - 4) + (lag + 1) * (h - 1);
    int y = int(tid) + 3;
    for (int t = 0; t <= steps; ++t) {
        int x = t - (lag + 1) * y;
        if (y < h && x >= 3 && x < w - 3) {
            int sum = 0, k = 0;
            for (int dy = -lag; dy <= 0; ++dy) {
                for (int dx = -lag; dx <= (dy < 0 ? lag : -1); ++dx) {
                    sum += int(coeffs[k]) * int(buf[(y + dy) * FG_TW + x + dx]);
                    k += 1;
                }
            }
            if (chroma && p.active_y != 0u) {
                // The current sample: the luma template's, averaged over the subsampling.
                int l = 0;
                int lumaX = ((x - 3) << p.sx) + 3, lumaY = ((y - 3) << p.sy) + 3;
                for (uint i = 0u; i <= p.sy; ++i) {
                    for (uint j = 0u; j <= p.sx; ++j) { l += int(luma[(lumaY + int(i)) * FG_TW + lumaX + int(j)]); }
                }
                sum += fg_round2(l, p.sx + p.sy) * int(coeffs[k]);
            }
            buf[y * FG_TW + x] = short(clamp(int(buf[y * FG_TW + x]) + fg_round2(sum, p.ar_shift), lo, hi));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
}

// The 8-bit-grid value of the piecewise-linear scaling function (7.18.3.4) at grid index i: flat before the first
// point and from the last, by + (d >> 16) between, d = 0x8000 + k delta, delta = dy (0x10000 + dx / 2) / dx.
static inline int fg_scale8(constant uchar* pts, uint count, int i) {
    if (i < int(pts[0])) { return int(pts[1]); }
    if (i >= int(pts[2u * (count - 1u)])) { return int(pts[2u * (count - 1u) + 1u]); }
    uint j = 0u;
    while (j + 2u < count && i >= int(pts[2u * (j + 1u)])) { ++j; }
    int bx = int(pts[2u * j]), by = int(pts[2u * j + 1u]);
    int dx = int(pts[2u * (j + 1u)]) - bx, dy = int(pts[2u * (j + 1u) + 1u]) - by;
    int delta = dy * ((0x10000 + (dx >> 1)) / dx);
    return (by + fg_floor_shift(0x8000 + (i - bx) * delta, 16u)) & 0xFF;
}

// Entry e of the 2^BitDepth table: the 8-bit grid's value, and between two grid entries of a segment,
// Round2((end - start) * rem, BitDepth - 8) added to the start, as scale_lut interpolates.
static inline uint fg_scale(constant uchar* pts, uint count, uint bitDepth, uint e) {
    if (count == 0u) { return 0u; }
    uint shiftX = bitDepth - 8u, pad = 1u << shiftX;
    int first = int(pts[0]) << shiftX, last = int(pts[2u * (count - 1u)]) << shiftX;
    if (int(e) < first) { return uint(pts[1]); }
    if (int(e) >= last) { return uint(pts[2u * (count - 1u) + 1u]); }
    int i = int(e >> shiftX), rem = int(e & (pad - 1u));
    int start = fg_scale8(pts, count, i);
    if (rem == 0) { return uint(start); }
    int range = fg_scale8(pts, count, i + 1) - start;
    return uint((start + fg_floor_shift(int(pad >> 1) + rem * range, shiftX)) & 0xFF);
}

// A frame's templates, scaling tables and block offsets into its grain buffer, after the header the CPU wrote. One
// threadgroup of FG_THREADS.
kernel void fg_synthesize(device uchar*       g   [[buffer(0)]],
                          constant FGParams&  p   [[buffer(1)]],
                          uint                tid [[thread_index_in_threadgroup]]) {
    threadgroup short luma[FG_TW * FG_TH];
    threadgroup short chroma[FG_TW * FG_TH];
    int lo = -(128 << (p.bit_depth - 8u)), hi = (128 << (p.bit_depth - 8u)) - 1;
    device short* templates = (device short*)(g + FG_TEMPLATES);
    uint plane = uint(FG_TW * FG_TH);

    // Luma: no points, no grain, and no luma term for chroma; the template is zero.
    for (uint i = tid; i < plane; i += FG_THREADS) {
        luma[i] = p.active_y != 0u ? short(fg_round2(int(FG_GAUSS[fg_draw(p.seed, i + 1u, 11u)]), p.shift)) : short(0);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (p.active_y != 0u) { fg_regress(luma, luma, p.ar_y, p, FG_TW, FG_TH, false, lo, hi, tid); }
    for (uint i = tid; i < plane; i += FG_THREADS) { templates[i] = luma[i]; }

    // Cb then Cr, each from its own seed, on its subsampled template (the stride stays the luma template's).
    int cw = p.sx != 0u ? \(S.subTemplateWidth) : FG_TW, ch = p.sy != 0u ? \(S.subTemplateHeight) : FG_TH;
    for (uint c = 0u; c < 2u; ++c) {
        if ((c == 0u ? p.active_cb : p.active_cr) == 0u) { continue; }
        uint seed = p.seed ^ (c == 0u ? 0xb524u : 0x49d8u);
        for (uint i = tid; i < uint(cw * ch); i += FG_THREADS) {
            uint y = i / uint(cw), x = i % uint(cw);
            chroma[y * uint(FG_TW) + x] = short(fg_round2(int(FG_GAUSS[fg_draw(seed, i + 1u, 11u)]), p.shift));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        fg_regress(chroma, luma, c == 0u ? p.ar_cb : p.ar_cr, p, cw, ch, true, lo, hi, tid);
        for (uint i = tid; i < uint(cw * ch); i += FG_THREADS) {
            uint y = i / uint(cw), x = i % uint(cw);
            templates[(1u + c) * plane + y * uint(FG_TW) + x] = chroma[y * uint(FG_TW) + x];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // The scaling tables. Chroma scaled from luma reads luma's, which is all 0 with no luma points.
    uint size = 1u << p.bit_depth;
    for (uint e = tid; e < 3u * size; e += FG_THREADS) {
        uint table = e / size, index = e % size;
        uint count = table == 0u ? p.y_points : (table == 1u ? p.cb_points : p.cr_points);
        bool written = table == 0u ? (p.active_y != 0u || p.from_luma != 0u) : count > 0u;
        if (!written) { continue; }
        constant uchar* pts = table == 0u ? p.y_pts : (table == 1u ? p.cb_pts : p.cr_pts);
        g[FG_SCALING + table * FG_SCALING_STRIDE + index] = uchar(fg_scale(pts, count, p.bit_depth, index));
    }

    // One 8-bit draw a 32 x 32 luma block, from an LFSR re-seeded every block row.
    for (uint row = tid; row < p.block_rows; row += FG_THREADS) {
        uint state = p.seed ^ (((row * 37u + 178u) & 0xFFu) << 8) ^ ((row * 173u + 105u) & 0xFFu);
        for (uint col = 0u; col < p.block_columns; ++col) {
            g[FG_OFFSETS + row * p.block_columns + col] = uchar(fg_next(state, 8u));
        }
    }
}

"""
    }
}
