// AV1 film grain synthesis (AV1 7.18.3), the per-sample half: Metal functions the finisher's reader calls for every
// sample it takes, over the tables FilmGrainSynthesis writes. The block sampling and overlap blending follow dav1d's
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
        return """
// MARK: - Film grain (AV1 7.18.3)

constant uint FG_TEMPLATES = \(S.templatesOffset)u;
constant uint FG_SCALING = \(S.scalingOffset)u;
constant uint FG_SCALING_STRIDE = \(S.scalingStride)u;
constant uint FG_OFFSETS = \(S.offsetsOffset)u;
constant int FG_TW = \(S.templateWidth);
constant int FG_TH = \(S.templateHeight);

static inline int fg_h(device const uchar* g, uint word) { return ((device const int*)g)[word]; }

// floor( v / 2^n ), exactly, whatever >> does with a negative int: v less its low bits is a multiple of 2^n.
static inline int fg_floor_shift(int v, uint n) { return (v - (v & int((1u << n) - 1u))) / int(1u << n); }

// Round2 (AV1 4.7).
static inline int fg_round2(int v, uint n) { return n == 0u ? v : fg_floor_shift(v + int(1u << (n - 1u)), n); }

// The template sample for block offset `rand`: (bx, by) = (1, 0) reads the left block's continuation, (0, 1) the upper
// block's, (1, 1) the upper left's.
static inline int fg_template(device const uchar* g, uint plane, int rand, uint sx, uint sy, int bx, int by, int x, int y) {
    int offx = 3 + (2 >> sx) * (3 + (rand >> 4));
    int offy = 3 + (2 >> sy) * (3 + (rand & 15));
    device const short* t = (device const short*)(g + FG_TEMPLATES) + int(plane) * FG_TW * FG_TH;
    return int(t[(offy + y + (32 >> sy) * by) * FG_TW + offx + x + (32 >> sx) * bx]);
}

// One overlap blend: 27 / 17 then 17 / 27 across two samples, 23 / 22 across one on a subsampled axis.
static inline int fg_blend(int old, int cur, uint sub, int i, int lo, int hi) {
    int w0 = sub != 0u ? 23 : (i == 0 ? 27 : 17);
    int w1 = sub != 0u ? 22 : (i == 0 ? 17 : 27);
    return clamp(fg_round2(old * w0 + cur * w1, 5u), lo, hi);
}

// The grain at (x, y) of `plane` (0 luma, 1 Cb, 2 Cr) on that plane's grid, subsampled by (sx, sy): horizontal blend
// with the left block, then vertical with the upper one, each rounded and clipped.
static inline int fg_noise(device const uchar* g, uint plane, uint sx, uint sy, uint x, uint y) {
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
static inline uint fg_luma(device const uchar* g, uint v, uint x, uint y) {
    if (fg_h(g, \(word(.activeY))) == 0) { return v; }
    int noise = fg_round2(fg_scaling(g, 0u, int(v)) * fg_noise(g, 0u, 0u, 0u, x, y), uint(fg_h(g, \(word(.scalingShift)))));
    return uint(clamp(int(v) + noise, fg_h(g, \(word(.minValue))), fg_h(g, \(word(.maxLuma)))));
}

// A chroma code of plane 1 + uv with its grain, from `average`, the un-noised luma at its site (the top row's pair
// averaged horizontally when subsampled).
static inline uint fg_chroma(device const uchar* g, uint uv, uint v, uint average, uint sx, uint sy, uint x, uint y) {
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
"""
    }
}
