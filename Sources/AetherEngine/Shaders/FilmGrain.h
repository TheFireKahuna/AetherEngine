// AV1 film grain (AV1 7.18.3) on the GPU, included by Finisher.metal: the synthesis kernels, which write a frame's
// templates, scaling tables and block offsets into its grain buffer, and the per-sample functions the finisher's reader
// calls for every sample it takes, over those tables. The block sampling and overlap blending follow dav1d's
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

// The noise at a sample is a pure function of the templates, its block's offset and, inside an overlap, its left and
// upper neighbours' offsets, so any sample is grained on its own, wherever and however often the finisher reads it.

#pragma once

// MARK: - Film grain (AV1 7.18.3)

constant uint FG_TEMPLATES = 128u;
constant uint FG_SCALING = 36048u;
constant uint FG_SCALING_STRIDE = 4096u;
constant uint FG_OFFSETS = 48336u;
constant int FG_TW = 82;
constant int FG_TH = 73;
constant int FG_SUB_TW = 44;
constant int FG_SUB_TH = 38;

// The header the CPU writes (FilmGrainSynthesis.Header), by word.
constant uint FG_H_SCALING_SHIFT = 0u;
constant uint FG_H_MIN_VALUE = 1u;
constant uint FG_H_MAX_LUMA = 2u;
constant uint FG_H_MAX_CHROMA = 3u;
constant uint FG_H_OVERLAP = 4u;
constant uint FG_H_CHROMA_SCALING_FROM_LUMA = 5u;
constant uint FG_H_ACTIVE_Y = 6u;
constant uint FG_H_ACTIVE_CB = 7u;
constant uint FG_H_ACTIVE_CR = 8u;
constant uint FG_H_CB_MULT = 9u;
constant uint FG_H_CR_MULT = 10u;
constant uint FG_H_CB_LUMA_MULT = 11u;
constant uint FG_H_CR_LUMA_MULT = 12u;
constant uint FG_H_CB_OFFSET = 13u;
constant uint FG_H_CR_OFFSET = 14u;
constant uint FG_H_BLOCK_COLUMNS = 15u;
constant uint FG_H_BIT_DEPTH_MINUS_8 = 16u;

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
    int dm8 = fg_h(g, FG_H_BIT_DEPTH_MINUS_8);
    int hi = (128 << dm8) - 1, lo = -(128 << dm8);
    uint bw = 32u >> sx, bh = 32u >> sy;
    uint col = x / bw, row = y / bh;
    int lx = int(x - col * bw), ly = int(y - row * bh);
    uint cols = uint(fg_h(g, FG_H_BLOCK_COLUMNS));
    device const uchar* off = g + FG_OFFSETS;
    int grain = fg_template(g, plane, int(off[row * cols + col]), sx, sy, 0, 0, lx, ly);
    bool overlap = fg_h(g, FG_H_OVERLAP) != 0;
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
    if (fg_h(g, FG_H_ACTIVE_Y) == 0) { return v; }
    int noise = fg_round2(fg_scaling(g, 0u, int(v)) * fg_noise(g, 0u, 0u, 0u, x, y), uint(fg_h(g, FG_H_SCALING_SHIFT)));
    return uint(clamp(int(v) + noise, fg_h(g, FG_H_MIN_VALUE), fg_h(g, FG_H_MAX_LUMA)));
}

// A chroma code of plane 1 + uv with its grain, from `average`, the un-noised luma at its site (the top row's pair
// averaged horizontally when subsampled).
static inline __attribute__((always_inline)) uint fg_chroma(device const uchar* g, uint uv, uint v, uint average, uint sx, uint sy, uint x, uint y) {
    if (fg_h(g, FG_H_ACTIVE_CB + uv) == 0) { return v; }
    int dm8 = fg_h(g, FG_H_BIT_DEPTH_MINUS_8);
    bool fromLuma = fg_h(g, FG_H_CHROMA_SCALING_FROM_LUMA) != 0;
    int index = int(average);
    if (!fromLuma) {
        int combined = int(average) * fg_h(g, FG_H_CB_LUMA_MULT + uv) + int(v) * fg_h(g, FG_H_CB_MULT + uv);
        index = clamp(fg_floor_shift(combined, 6u) + fg_h(g, FG_H_CB_OFFSET + uv) * (1 << dm8), 0, (256 << dm8) - 1);
    }
    int noise = fg_round2(fg_scaling(g, fromLuma ? 0u : 1u + uv, index) * fg_noise(g, 1u + uv, sx, sy, x, y),
                          uint(fg_h(g, FG_H_SCALING_SHIFT)));
    return uint(clamp(int(v) + noise, fg_h(g, FG_H_MIN_VALUE), fg_h(g, FG_H_MAX_CHROMA)));
}
// MARK: - Synthesis (AV1 7.18.3.3 - 7.18.3.5): the templates, the scaling tables and the block offsets, on the GPU

// The Gaussian sequence `get_random_number(11)` indexes.
constant short FG_GAUSS[2048] = {
    56, 568, -180, 172, 124, -84, 172, -64, -900, 24, 820, 224, 1248, 996, 272, -8,
    -916, -388, -732, -104, -188, 800, 112, -652, -320, -376, 140, -252, 492, -168, 44, -788,
    588, -584, 500, -228, 12, 680, 272, -476, 972, -100, 652, 368, 432, -196, -720, -192,
    1000, -332, 652, -136, -552, -604, -4, 192, -220, -136, 1000, -52, 372, -96, -624, 124,
    -24, 396, 540, -12, -104, 640, 464, 244, -208, -84, 368, -528, -740, 248, -968, -848,
    608, 376, -60, -292, -40, -156, 252, -292, 248, 224, -280, 400, -244, 244, -60, 76,
    -80, 212, 532, 340, 128, -36, 824, -352, -60, -264, -96, -612, 416, -704, 220, -204,
    640, -160, 1220, -408, 900, 336, 20, -336, -96, -792, 304, 48, -28, -1232, -1172, -448,
    104, -292, -520, 244, 60, -948, 0, -708, 268, 108, 356, -548, 488, -344, -136, 488,
    -196, -224, 656, -236, -1128, 60, 4, 140, 276, -676, -376, 168, -108, 464, 8, 564,
    64, 240, 308, -300, -400, -456, -136, 56, 120, -408, -116, 436, 504, -232, 328, 844,
    -164, -84, 784, -168, 232, -224, 348, -376, 128, 568, 96, -1244, -288, 276, 848, 832,
    -360, 656, 464, -384, -332, -356, 728, -388, 160, -192, 468, 296, 224, 140, -776, -100,
    280, 4, 196, 44, -36, -648, 932, 16, 1428, 28, 528, 808, 772, 20, 268, 88,
    -332, -284, 124, -384, -448, 208, -228, -1044, -328, 660, 380, -148, -300, 588, 240, 540,
    28, 136, -88, -436, 256, 296, -1000, 1400, 0, -48, 1056, -136, 264, -528, -1108, 632,
    -484, -592, -344, 796, 124, -668, -768, 388, 1296, -232, -188, -200, -288, -4, 308, 100,
    -168, 256, -500, 204, -508, 648, -136, 372, -272, -120, -1004, -552, -548, -384, 548, -296,
    428, -108, -8, -912, -324, -224, -88, -112, -220, -100, 996, -796, 548, 360, -216, 180,
    428, -200, -212, 148, 96, 148, 284, 216, -412, -320, 120, -300, -384, -604, -572, -332,
    -8, -180, -176, 696, 116, -88, 628, 76, 44, -516, 240, -208, -40, 100, -592, 344,
    -308, -452, -228, 20, 916, -1752, -136, -340, -804, 140, 40, 512, 340, 248, 184, -492,
    896, -156, 932, -628, 328, -688, -448, -616, -752, -100, 560, -1020, 180, -800, -64, 76,
    576, 1068, 396, 660, 552, -108, -28, 320, -628, 312, -92, -92, -472, 268, 16, 560,
    516, -672, -52, 492, -100, 260, 384, 284, 292, 304, -148, 88, -152, 1012, 1064, -228,
    164, -376, -684, 592, -392, 156, 196, -524, -64, -884, 160, -176, 636, 648, 404, -396,
    -436, 864, 424, -728, 988, -604, 904, -592, 296, -224, 536, -176, -920, 436, -48, 1176,
    -884, 416, -776, -824, -884, 524, -548, -564, -68, -164, -96, 692, 364, -692, -1012, -68,
    260, -480, 876, -1116, 452, -332, -352, 892, -1088, 1220, -676, 12, -292, 244, 496, 372,
    -32, 280, 200, 112, -440, -96, 24, -644, -184, 56, -432, 224, -980, 272, -260, 144,
    -436, 420, 356, 364, -528, 76, 172, -744, -368, 404, -752, -416, 684, -688, 72, 540,
    416, 92, 444, 480, -72, -1416, 164, -1172, -68, 24, 424, 264, 1040, 128, -912, -524,
    -356, 64, 876, -12, 4, -88, 532, 272, -524, 320, 276, -508, 940, 24, -400, -120,
    756, 60, 236, -412, 100, 376, -484, 400, -100, -740, -108, -260, 328, -268, 224, -200,
    -416, 184, -604, -564, -20, 296, 60, 892, -888, 60, 164, 68, -760, 216, -296, 904,
    -336, -28, 404, -356, -568, -208, -1480, -512, 296, 328, -360, -164, -1560, -776, 1156, -428,
    164, -504, -112, 120, -216, -148, -264, 308, 32, 64, -72, 72, 116, 176, -64, -272,
    460, -536, -784, -280, 348, 108, -752, -132, 524, -540, -776, 116, -296, -1196, -288, -560,
    1040, -472, 116, -848, -1116, 116, 636, 696, 284, -176, 1016, 204, -864, -648, -248, 356,
    972, -584, -204, 264, 880, 528, -24, -184, 116, 448, -144, 828, 524, 212, -212, 52,
    12, 200, 268, -488, -404, -880, 824, -672, -40, 908, -248, 500, 716, -576, 492, -576,
    16, 720, -108, 384, 124, 344, 280, 576, -500, 252, 104, -308, 196, -188, -8, 1268,
    296, 1032, -1196, 436, 316, 372, -432, -200, -660, 704, -224, 596, -132, 268, 32, -452,
    884, 104, -1008, 424, -1348, -280, 4, -1168, 368, 476, 696, 300, -8, 24, 180, -592,
    -196, 388, 304, 500, 724, -160, 244, -84, 272, -256, -420, 320, 208, -144, -156, 156,
    364, 452, 28, 540, 316, 220, -644, -248, 464, 72, 360, 32, -388, 496, -680, -48,
    208, -116, -408, 60, -604, -392, 548, -840, 784, -460, 656, -544, -388, -264, 908, -800,
    -628, -612, -568, 572, -220, 164, 288, -16, -308, 308, -112, -636, -760, 280, -668, 432,
    364, 240, -196, 604, 340, 384, 196, 592, -44, -500, 432, -580, -132, 636, -76, 392,
    4, -412, 540, 508, 328, -356, -36, 16, -220, -64, -248, -60, 24, -192, 368, 1040,
    92, -24, -1044, -32, 40, 104, 148, 192, -136, -520, 56, -816, -224, 732, 392, 356,
    212, -80, -424, -1008, -324, 588, -1496, 576, 460, -816, -848, 56, -580, -92, -1372, -112,
    -496, 200, 364, 52, -140, 48, -48, -60, 84, 72, 40, 132, -356, -268, -104, -284,
    -404, 732, -520, 164, -304, -540, 120, 328, -76, -460, 756, 388, 588, 236, -436, -72,
    -176, -404, -316, -148, 716, -604, 404, -72, -88, -888, -68, 944, 88, -220, -344, 960,
    472, 460, -232, 704, 120, 832, -228, 692, -508, 132, -476, 844, -748, -364, -44, 1116,
    -1104, -1056, 76, 428, 552, -692, 60, 356, 96, -384, -188, -612, -576, 736, 508, 892,
    352, -1132, 504, -24, -352, 324, 332, -600, -312, 292, 508, -144, -8, 484, 48, 284,
    -260, -240, 256, -100, -292, -204, -44, 472, -204, 908, -188, -1000, -256, 92, 1164, -392,
    564, 356, 652, -28, -884, 256, 484, -192, 760, -176, 376, -524, -452, -436, 860, -736,
    212, 124, 504, -476, 468, 76, -472, 552, -692, -944, -620, 740, -240, 400, 132, 20,
    192, -196, 264, -668, -1012, -60, 296, -316, -828, 76, -156, 284, -768, -448, -832, 148,
    248, 652, 616, 1236, 288, -328, -400, -124, 588, 220, 520, -696, 1032, 768, -740, -92,
    -272, 296, 448, -464, 412, -200, 392, 440, -200, 264, -152, -260, 320, 1032, 216, 320,
    -8, -64, 156, -1016, 1084, 1172, 536, 484, -432, 132, 372, -52, -256, 84, 116, -352,
    48, 116, 304, -384, 412, 924, -300, 528, 628, 180, 648, 44, -980, -220, 1320, 48,
    332, 748, 524, -268, -720, 540, -276, 564, -344, -208, -196, 436, 896, 88, -392, 132,
    80, -964, -288, 568, 56, -48, -456, 888, 8, 552, -156, -292, 948, 288, 128, -716,
    -292, 1192, -152, 876, 352, -600, -260, -812, -468, -28, -120, -32, -44, 1284, 496, 192,
    464, 312, -76, -516, -380, -456, -1012, -48, 308, -156, 36, 492, -156, -808, 188, 1652,
    68, -120, -116, 316, 160, -140, 352, 808, -416, 592, 316, -480, 56, 528, -204, -568,
    372, -232, 752, -344, 744, -4, 324, -416, -600, 768, 268, -248, -88, -132, -420, -432,
    80, -288, 404, -316, -1216, -588, 520, -108, 92, -320, 368, -480, -216, -92, 1688, -300,
    180, 1020, -176, 820, -68, -228, -260, 436, -904, 20, 40, -508, 440, -736, 312, 332,
    204, 760, -372, 728, 96, -20, -632, -520, -560, 336, 1076, -64, -532, 776, 584, 192,
    396, -728, -520, 276, -188, 80, -52, -612, -252, -48, 648, 212, -688, 228, -52, -260,
    428, -412, -272, -404, 180, 816, -796, 48, 152, 484, -88, -216, 988, 696, 188, -528,
    648, -116, -180, 316, 476, 12, -564, 96, 476, -252, -364, -376, -392, 556, -256, -576,
    260, -352, 120, -16, -136, -260, -492, 72, 556, 660, 580, 616, 772, 436, 424, -32,
    -324, -1268, 416, -324, -80, 920, 160, 228, 724, 32, -516, 64, 384, 68, -128, 136,
    240, 248, -204, -68, 252, -932, -120, -480, -628, -84, 192, 852, -404, -288, -132, 204,
    100, 168, -68, -196, -868, 460, 1080, 380, -80, 244, 0, 484, -888, 64, 184, 352,
    600, 460, 164, 604, -196, 320, -64, 588, -184, 228, 12, 372, 48, -848, -344, 224,
    208, -200, 484, 128, -20, 272, -468, -840, 384, 256, -720, -520, -464, -580, 112, -120,
    644, -356, -208, -608, -528, 704, 560, -424, 392, 828, 40, 84, 200, -152, 0, -144,
    584, 280, -120, 80, -556, -972, -196, -472, 724, 80, 168, -32, 88, 160, -688, 0,
    160, 356, 372, -776, 740, -128, 676, -248, -480, 4, -364, 96, 544, 232, -1032, 956,
    236, 356, 20, -40, 300, 24, -676, -596, 132, 1120, -104, 532, -1096, 568, 648, 444,
    508, 380, 188, -376, -604, 1488, 424, 24, 756, -220, -192, 716, 120, 920, 688, 168,
    44, -460, 568, 284, 1144, 1160, 600, 424, 888, 656, -356, -320, 220, 316, -176, -724,
    -188, -816, -628, -348, -228, -380, 1012, -452, -660, 736, 928, 404, -696, -72, -268, -892,
    128, 184, -344, -780, 360, 336, 400, 344, 428, 548, -112, 136, -228, -216, -820, -516,
    340, 92, -136, 116, -300, 376, -244, 100, -316, -520, -284, -12, 824, 164, -548, -180,
    -128, 116, -924, -828, 268, -368, -580, 620, 192, 160, 0, -1676, 1068, 424, -56, -360,
    468, -156, 720, 288, -528, 556, -364, 548, -148, 504, 316, 152, -648, -620, -684, -24,
    -376, -384, -108, -920, -1032, 768, 180, -264, -508, -1268, -260, -60, 300, -240, 988, 724,
    -376, -576, -212, -736, 556, 192, 1092, -620, -880, 376, -56, -4, -216, -32, 836, 268,
    396, 1332, 864, -600, 100, 56, -412, -92, 356, 180, 884, -468, -436, 292, -388, -804,
    -704, -840, 368, -348, 140, -724, 1536, 940, 372, 112, -372, 436, -480, 1136, 296, -32,
    -228, 132, -48, -220, 868, -1016, -60, -1044, -464, 328, 916, 244, 12, -736, -296, 360,
    468, -376, -108, -92, 788, 368, -56, 544, 400, -672, -420, 728, 16, 320, 44, -284,
    -380, -796, 488, 132, 204, -596, -372, 88, -152, -908, -636, -572, -624, -116, -692, -200,
    -56, 276, -88, 484, -324, 948, 864, 1000, -456, -184, -276, 292, -296, 156, 676, 320,
    160, 908, -84, -1236, -288, -116, 260, -372, -644, 732, -756, -96, 84, 344, -520, 348,
    -688, 240, -84, 216, -1044, -136, -676, -396, -1500, 960, -40, 176, 168, 1516, 420, -504,
    -344, -364, -360, 1216, -940, -380, -212, 252, -660, -708, 484, -444, -152, 928, -120, 1112,
    476, -260, 560, -148, -344, 108, -196, 228, -288, 504, 560, -328, -88, 288, -1008, 460,
    -228, 468, -836, -196, 76, 388, 232, 412, -1168, -716, -644, 756, -172, -356, -504, 116,
    432, 528, 48, 476, -168, -608, 448, 160, -532, -272, 28, -676, -12, 828, 980, 456,
    520, 104, -104, 256, -344, -4, -28, -368, -52, -524, -572, -556, -200, 768, 1124, -208,
    -512, 176, 232, 248, -148, -888, 604, -600, -304, 804, -156, -212, 488, -192, -804, -256,
    368, -360, -916, -328, 228, -240, -448, -472, 856, -556, -364, 572, -12, -156, -368, -340,
    432, 252, -752, -152, 288, 268, -580, -848, -592, 108, -76, 244, 312, -716, 592, -80,
    436, 360, 4, -248, 160, 516, 584, 732, 44, -468, -280, -292, -156, -588, 28, 308,
    912, 24, 124, 156, 180, -252, 944, -924, -772, -520, -428, -624, 300, -212, -1144, 32,
    -724, 800, -1128, -212, -1288, -848, 180, -416, 440, 192, -576, -792, -76, -1080, 80, -532,
    -352, -132, 380, -820, 148, 1112, 128, 164, 456, 700, -924, 144, -668, -384, 648, -832,
    508, 552, -52, -100, -656, 208, -568, 748, -88, 680, 232, 300, 192, -408, -1012, -152,
    -252, -268, 272, -876, -664, -648, -332, -136, 16, 12, 1152, -28, 332, -536, 320, -672,
    -460, -316, 532, -260, 228, -40, 1052, -816, 180, 88, -496, -556, -672, -368, 428, 92,
    356, 404, -408, 252, 196, -176, -556, 792, 268, 32, 372, 40, 96, -332, 328, 120,
    372, -900, -40, 472, -264, -592, 952, 128, 656, 112, 664, -232, 420, 4, -344, -464,
    556, 244, -416, -32, 252, 0, -412, 188, -696, 508, -476, 324, -1096, 656, -312, 560,
    264, -136, 304, 160, -64, -580, 248, 336, -720, 560, -348, -288, -276, -196, -500, 852,
    -544, -236, -1128, -992, -776, 116, 56, 52, 860, 884, 212, -12, 168, 1020, 512, -552,
    924, -148, 716, 188, 164, -340, -520, -184, 880, -152, -680, -208, -1156, -300, -528, -472,
    364, 100, -744, -1056, -32, 540, 280, 144, -676, -32, -232, -280, -224, 96, 568, -76,
    172, 148, 148, 104, 32, -296, -32, 788, -80, 32, -16, 280, 288, 944, 428, -484
};

// The LFSR's step to the 2^j-th power, j = 0 ... 12, as 16 columns each (derived in ShaderTablesTests).
constant ushort FG_JUMP[13][16] = {
    { 32768, 32769, 2, 32772, 8, 16, 32, 64, 128, 256, 512, 1024, 34816, 4096, 8192, 16384 },
    { 16384, 49152, 32769, 16386, 32772, 8, 16, 32, 64, 128, 256, 512, 17408, 34816, 4096, 8192 },
    { 4096, 12288, 24576, 53248, 40961, 16386, 32772, 8, 16, 32, 64, 128, 4352, 8704, 17408, 34816 },
    { 4352, 13056, 26112, 56576, 47616, 29696, 59392, 53248, 40961, 16386, 32772, 8, 4368, 8736, 17472, 34944 },
    { 45329, 54067, 42598, 64989, 64442, 63348, 61160, 56784, 48032, 30528, 61056, 56576, 2833, 5666, 11332, 22664 },
    { 46256, 56785, 48035, 50167, 34799, 4063, 8127, 16255, 32511, 65023, 64510, 63485, 23371, 46742, 27948, 55896 },
    { 31540, 36188, 6841, 20038, 40076, 14617, 29234, 58468, 51400, 37264, 8993, 17987, 63411, 61286, 57037, 48538 },
    { 26159, 43633, 21731, 53224, 40912, 16288, 32577, 65154, 64772, 64009, 62483, 59430, 46690, 27845, 55691, 45847 },
    { 54177, 29923, 59847, 47, 94, 189, 378, 756, 1513, 3027, 6054, 12109, 36154, 6772, 13544, 27088 },
    { 4048, 4209, 8419, 19991, 39983, 14430, 28860, 57721, 49906, 34277, 3019, 6038, 8445, 16890, 33780, 2024 },
    { 22176, 64480, 63424, 47393, 29251, 58503, 51471, 37406, 9276, 18553, 37106, 8677, 5482, 10964, 21928, 43856 },
    { 61136, 13168, 26336, 8976, 17952, 35904, 6272, 12545, 25091, 50183, 34831, 4126, 52973, 40410, 15284, 30568 },
    { 58033, 10195, 20391, 32254, 64508, 63481, 61426, 57316, 49097, 32659, 65318, 65101, 7723, 15446, 30892, 61784 }
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

// The synthesis of a frame's templates, scaling tables and block offsets into its grain buffer (after the header the CPU
// wrote), split by role so independent parts run at once: fg_luma, fg_chroma_draws, fg_scaling and fg_offsets together,
// then, once the luma template is done, fg_chroma_regress for both chroma planes. Each template's draws are a run per
// thread: one jump to the run's start, then a step per draw.

// Thread `tid`'s run of `n` draws, [x, y).
static inline uint2 fg_run(uint n, uint tid) {
    uint per = (n + FG_THREADS - 1u) / FG_THREADS;
    uint start = min(n, tid * per);
    return uint2(start, min(n, start + per));
}

// The luma template: its draws, then its auto-regressive filter. Zero when luma has no points. One threadgroup of
// FG_THREADS.
kernel void fg_luma(device uchar*       g   [[buffer(0)]],
                    constant FGParams&  p   [[buffer(1)]],
                    uint                tid [[thread_index_in_threadgroup]]) {
    threadgroup short luma[FG_TW * FG_TH];
    device short* templates = (device short*)(g + FG_TEMPLATES);
    uint plane = uint(FG_TW * FG_TH);
    if (p.active_y == 0u) {
        for (uint i = tid; i < plane; i += FG_THREADS) { templates[i] = 0; }
        return;
    }
    int lo = -(128 << (p.bit_depth - 8u)), hi = (128 << (p.bit_depth - 8u)) - 1;
    uint2 run = fg_run(plane, tid);
    uint state = fg_jump(p.seed, run.x);
    for (uint i = run.x; i < run.y; ++i) { luma[i] = short(fg_round2(int(FG_GAUSS[fg_next(state, 11u)]), p.shift)); }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    fg_regress(luma, luma, p.ar_y, p, FG_TW, FG_TH, false, lo, hi, tid);
    for (uint i = tid; i < plane; i += FG_THREADS) { templates[i] = luma[i]; }
}

// A chroma template's draws, before its filter: Cb in threadgroup 0, Cr in 1, each from its own seed, on its subsampled
// template (the stride stays the luma template's).
kernel void fg_chroma_draws(device uchar*       g   [[buffer(0)]],
                            constant FGParams&  p   [[buffer(1)]],
                            uint                c   [[threadgroup_position_in_grid]],
                            uint                tid [[thread_index_in_threadgroup]]) {
    if ((c == 0u ? p.active_cb : p.active_cr) == 0u) { return; }
    device short* t = (device short*)(g + FG_TEMPLATES) + (1u + c) * uint(FG_TW * FG_TH);
    uint cw = p.sx != 0u ? uint(FG_SUB_TW) : uint(FG_TW), ch = p.sy != 0u ? uint(FG_SUB_TH) : uint(FG_TH);
    uint2 run = fg_run(cw * ch, tid);
    uint state = fg_jump(p.seed ^ (c == 0u ? 0xb524u : 0x49d8u), run.x);
    for (uint i = run.x; i < run.y; ++i) {
        t[(i / cw) * uint(FG_TW) + i % cw] = short(fg_round2(int(FG_GAUSS[fg_next(state, 11u)]), p.shift));
    }
}

// A chroma template's auto-regressive filter, with its luma term from the finished luma template: Cb in threadgroup 0,
// Cr in 1. After fg_luma and fg_chroma_draws.
kernel void fg_chroma_regress(device uchar*       g   [[buffer(0)]],
                              constant FGParams&  p   [[buffer(1)]],
                              uint                c   [[threadgroup_position_in_grid]],
                              uint                tid [[thread_index_in_threadgroup]]) {
    if ((c == 0u ? p.active_cb : p.active_cr) == 0u) { return; }
    threadgroup short luma[FG_TW * FG_TH];
    threadgroup short chroma[FG_TW * FG_TH];
    device short* templates = (device short*)(g + FG_TEMPLATES);
    uint plane = uint(FG_TW * FG_TH);
    int lo = -(128 << (p.bit_depth - 8u)), hi = (128 << (p.bit_depth - 8u)) - 1;
    int cw = p.sx != 0u ? FG_SUB_TW : FG_TW, ch = p.sy != 0u ? FG_SUB_TH : FG_TH;
    if (p.active_y != 0u) {
        for (uint i = tid; i < plane; i += FG_THREADS) { luma[i] = templates[i]; }
    }
    device short* t = templates + (1u + c) * plane;
    for (uint i = tid; i < uint(cw * ch); i += FG_THREADS) {
        uint y = i / uint(cw), x = i % uint(cw);
        chroma[y * uint(FG_TW) + x] = t[y * uint(FG_TW) + x];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    fg_regress(chroma, luma, c == 0u ? p.ar_cb : p.ar_cr, p, cw, ch, true, lo, hi, tid);
    for (uint i = tid; i < uint(cw * ch); i += FG_THREADS) {
        uint y = i / uint(cw), x = i % uint(cw);
        t[y * uint(FG_TW) + x] = chroma[y * uint(FG_TW) + x];
    }
}

// The scaling tables, a thread an entry over 3 x 2^BitDepth. Chroma scaled from luma reads luma's, which is all 0 with no
// luma points.
kernel void fg_scaling(device uchar*       g   [[buffer(0)]],
                       constant FGParams&  p   [[buffer(1)]],
                       uint                e   [[thread_position_in_grid]]) {
    uint size = 1u << p.bit_depth;
    if (e >= 3u * size) { return; }
    uint table = e / size, index = e % size;
    uint count = table == 0u ? p.y_points : (table == 1u ? p.cb_points : p.cr_points);
    bool written = table == 0u ? (p.active_y != 0u || p.from_luma != 0u) : count > 0u;
    if (!written) { return; }
    constant uchar* pts = table == 0u ? p.y_pts : (table == 1u ? p.cb_pts : p.cr_pts);
    g[FG_SCALING + table * FG_SCALING_STRIDE + index] = uchar(fg_scale(pts, count, p.bit_depth, index));
}

// One 8-bit draw a 32 x 32 luma block, from an LFSR re-seeded every block row: a thread a row.
kernel void fg_offsets(device uchar*       g   [[buffer(0)]],
                       constant FGParams&  p   [[buffer(1)]],
                       uint                row [[thread_position_in_grid]]) {
    if (row >= p.block_rows) { return; }
    uint state = p.seed ^ (((row * 37u + 178u) & 0xFFu) << 8) ^ ((row * 173u + 105u) & 0xFFu);
    for (uint col = 0u; col < p.block_columns; ++col) {
        g[FG_OFFSETS + row * p.block_columns + col] = uchar(fg_next(state, 8u));
    }
}
