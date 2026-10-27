#include <metal_stdlib>
using namespace metal;

// MARK: - Specialisation

// 0 pack (Y'CbCr, output keeps the source's chroma subsampling), 1 resample (Y'CbCr, output keeps more chroma),
// 2 grey (neutral chroma), 3 RGB (R'G'B' codes or a palette, to Y'CbCr through the affine rows), 4 convert
// (Y'CbCr in a matrix CoreVideo cannot tag, re-encoded at 4:4:4; FC_MATRIX says which), 5 constant luminance
// (re-encoded at 4:4:4 through the transfer characteristics FC_TRANSFER names).
constant uint FC_MODE        [[function_constant(0)]];
constant uint FC_OUT_LOG2_W  [[function_constant(1)]];
constant uint FC_OUT_LOG2_H  [[function_constant(2)]];
constant uint FC_SRC_LOG2_W  [[function_constant(3)]];
constant uint FC_SRC_LOG2_H  [[function_constant(4)]];
// AVComponentDescriptor of components 0...3: plane, step, offset, shift, depth.
constant uint FC_C0_PLANE [[function_constant(5)]];  constant uint FC_C0_STEP [[function_constant(6)]];
constant uint FC_C0_OFFSET [[function_constant(7)]]; constant uint FC_C0_SHIFT [[function_constant(8)]];
constant uint FC_C0_DEPTH [[function_constant(9)]];
constant uint FC_C1_PLANE [[function_constant(10)]]; constant uint FC_C1_STEP [[function_constant(11)]];
constant uint FC_C1_OFFSET [[function_constant(12)]]; constant uint FC_C1_SHIFT [[function_constant(13)]];
constant uint FC_C1_DEPTH [[function_constant(14)]];
constant uint FC_C2_PLANE [[function_constant(15)]]; constant uint FC_C2_STEP [[function_constant(16)]];
constant uint FC_C2_OFFSET [[function_constant(17)]]; constant uint FC_C2_SHIFT [[function_constant(18)]];
constant uint FC_C2_DEPTH [[function_constant(19)]];
constant bool FC_BIG_ENDIAN  [[function_constant(20)]];
constant bool FC_BITSTREAM   [[function_constant(21)]];
constant bool FC_PALETTE     [[function_constant(22)]];
// The source's VideoFullRangeFlag (for RGB: the R'G'B' codes' range).
constant bool FC_FULL_RANGE  [[function_constant(23)]];
// Output: T significant bits (8, 10 or 16), F fraction bits kept for the dither (6, else 0), and the left shift
// that MSB-aligns an undithered value in its container.
constant uint FC_TARGET_BITS     [[function_constant(24)]];
constant uint FC_FRACTION_BITS   [[function_constant(25)]];
constant uint FC_CONTAINER_SHIFT [[function_constant(26)]];
// AVChromaLocation, UNSPECIFIED already resolved.
constant uint FC_CHROMA_LOCATION [[function_constant(27)]];
// Convert: 1 non-constant luminance (one affine map of Y, Cb, Cr), 2 YCgCo (54)-(57), 3 YCgCo-R (62)-(65); the
// last two then encode their R, G, B codes through the affine rows. BitDepthRGB for 2 and 3 (23)-(25).
constant uint FC_MATRIX        [[function_constant(28)]];
constant uint FC_BITDEPTH_RGB  [[function_constant(29)]];
// Constant luminance: the stream's TransferCharacteristics (1, 4, 5, 6, 7, 8, 13, 14, 15, 16 or 18).
constant uint FC_TRANSFER      [[function_constant(30)]];
constant bool FC_GRAIN         [[function_constant(31)]];
// The source is one of two pictures of one layout, chosen on the GPU (inverse telecine's window passes its weave
// through): `alt` when the word at `chosen` is nonzero.
constant bool FC_CHOSEN_SOURCE [[function_constant(32)]];

constant bool PF_DITHER = FC_FRACTION_BITS > 0u;
constant uint PF_BLOCK_W = 1u << FC_OUT_LOG2_W;
constant uint PF_BLOCK_H = 1u << FC_OUT_LOG2_H;
// The largest output word: T bits with F fraction bits.
constant uint PF_WORD_MAX = FC_TARGET_BITS + FC_FRACTION_BITS >= 16u ? 0xFFFFu
                          : ((1u << (FC_TARGET_BITS + FC_FRACTION_BITS)) - 1u);

// MARK: - Per-frame values

struct PFFrame {
    uint width;
    uint height;
    uint chroma_width;      // output chroma plane
    uint chroma_height;
    uint plane_offset[4];
    uint linesize[4];
    // Affine maps as double-float rows (hi, lo), computed in double on the host: output i = rows[4i] x0 + rows[4i+1] x1
    // + rows[4i+2] x2 + rows[4i+3]. RGB and convert use outputs 0-2 (to words, before Round). Constant luminance
    // uses 0-2 for codes to E'Y, E'PB, E'PR and 3-5 for E'R, E'G, E'B to words.
    float2 rows[24];
    // Constant luminance: K_R, K_B, K_G, N_B, P_B, N_R, P_R (72)-(75).
    float2 cl[8];
    // The transfer function's constants (pf_tf_*), as double-float.
    float2 tp[8];
    // The relative error of one float32 transfer evaluation (a few ulp of Metal's precise pow / exp / log); 0 turns
    // the exact recompute off (tests).
    float tie_bound;
    uint list_capacity;
};

// MARK: - Double-float

// A value as the unevaluated sum hi + lo of two floats (about 48 significant bits). The library is compiled with
// MTLMathMode.safe, so nothing reassociates these sums; fma is a single rounding.
struct pf_df { float hi; float lo; };

static inline pf_df pf_quick_two_sum(float a, float b) { float s = a + b; return pf_df{s, b - (s - a)}; }

static inline pf_df pf_two_sum(float a, float b) {
    float s = a + b, bb = s - a;
    return pf_df{s, (a - (s - bb)) + (b - bb)};
}

static inline pf_df pf_add(pf_df a, pf_df b) {
    pf_df s = pf_two_sum(a.hi, b.hi), t = pf_two_sum(a.lo, b.lo);
    s = pf_quick_two_sum(s.hi, s.lo + t.hi);
    return pf_quick_two_sum(s.hi, s.lo + t.lo);
}

static inline pf_df pf_mul(pf_df a, pf_df b) {
    float p = a.hi * b.hi;
    float e = fma(a.hi, b.hi, -p);
    e = fma(a.hi, b.lo, fma(a.lo, b.hi, e));
    return pf_quick_two_sum(p, e);
}

// An integer (|v| < 2^47) as a double-float, exactly; `scale` a power of two applied exactly.
static inline pf_df pf_df_long(long v, float scale) {
    float hi = float(v);
    float lo = float(v - long(hi));
    return pf_df{hi * scale, lo * scale};
}

// Round( x ) = Floor( x + 0.5 ) (8) of a double-float, clipped to a word. Words stay below 2^23, so a hi that is not
// whole is further from the next integer than lo can reach.
static inline uint pf_round_df(pf_df x, uint word_max) {
    pf_df t = pf_add(x, pf_df{0.5f, 0.0f});
    float f = floor(t.hi);
    if (t.hi == f && t.lo < 0.0f) { f -= 1.0f; }
    return uint(clamp(f, 0.0f, float(word_max)));
}

// Output i of the affine rows applied to (x0, x1, x2).
static inline pf_df pf_affine_df(constant PFFrame& f, uint i, pf_df x0, pf_df x1, pf_df x2) {
    pf_df acc = pf_df{f.rows[4u * i + 3u].x, f.rows[4u * i + 3u].y};
    acc = pf_add(acc, pf_mul(pf_df{f.rows[4u * i].x, f.rows[4u * i].y}, x0));
    acc = pf_add(acc, pf_mul(pf_df{f.rows[4u * i + 1u].x, f.rows[4u * i + 1u].y}, x1));
    return pf_add(acc, pf_mul(pf_df{f.rows[4u * i + 2u].x, f.rows[4u * i + 2u].y}, x2));
}

static inline uint pf_affine(constant PFFrame& f, uint i, pf_df x0, pf_df x1, pf_df x2, uint word_max) {
    return pf_round_df(pf_affine_df(f, i, x0, x1, x2), word_max);
}

// Output i of the affine rows in float32 on float inputs carrying absolute errors e0...e2: the value and its absolute
// error bound (the roundings and the rows' dropped low parts, at most 2^-21 of the terms' magnitudes, plus the
// inputs' errors through their coefficients).
static inline float2 pf_affine_f(constant PFFrame& f, uint i, float x0, float x1, float x2, float e0, float e1, float e2) {
    float a0 = f.rows[4u * i].x, a1 = f.rows[4u * i + 1u].x, a2 = f.rows[4u * i + 2u].x, b = f.rows[4u * i + 3u].x;
    float v = fma(a0, x0, fma(a1, x1, fma(a2, x2, b)));
    float magnitude = fabs(a0 * x0) + fabs(a1 * x1) + fabs(a2 * x2) + fabs(b);
    return float2(v, magnitude * 0x1p-21f + fabs(a0) * e0 + fabs(a1) * e1 + fabs(a2) * e2);
}

// Whether a float word, within `error` of its true value, might round differently from it.
static inline bool pf_near_tie_f(float w, float error) {
    float fraction = w - floor(w);
    return !(fabs(fraction - 0.5f) >= error);
}

static inline uint pf_round_f(float w, uint max_value) { return uint(clamp(floor(w + 0.5f), 0.0f, float(max_value))); }

// Output word i, exactly: float32 with its error bound (twice, for margin), and double-float only for a value that
// close to a rounding tie (about one word in 10^4 at 10 bits).
static inline uint pf_affine_word(constant PFFrame& f, uint i, pf_df x0, pf_df x1, pf_df x2, uint max_value) {
    float2 w = pf_affine_f(f, i, x0.hi, x1.hi, x2.hi, fabs(x0.lo), fabs(x1.lo), fabs(x2.lo));
    if (!pf_near_tie_f(w.x, 2.0f * w.y)) { return pf_round_f(w.x, max_value); }
    return pf_affine(f, i, x0, x1, x2, max_value);
}

// MARK: - Double-float functions

static inline pf_df pf_df_f(float v) { return pf_df{v, 0.0f}; }
static inline pf_df pf_neg(pf_df a) { return pf_df{-a.hi, -a.lo}; }
static inline pf_df pf_sub(pf_df a, pf_df b) { return pf_add(a, pf_neg(b)); }
static inline pf_df pf_ldexp(pf_df a, int e) { return pf_df{ldexp(a.hi, e), ldexp(a.lo, e)}; }
static inline pf_df pf_c(constant float2& v) { return pf_df{v.x, v.y}; }

static inline pf_df pf_div(pf_df a, pf_df b) {
    float q1 = a.hi / b.hi;
    pf_df r = pf_sub(a, pf_mul(pf_df_f(q1), b));
    float q2 = r.hi / b.hi;
    r = pf_sub(r, pf_mul(pf_df_f(q2), b));
    float q3 = r.hi / b.hi;
    pf_df q = pf_quick_two_sum(q1, q2);
    return pf_add(q, pf_df_f(q3));
}

static inline pf_df pf_sqrt(pf_df a) {
    if (a.hi <= 0.0f) { return pf_df_f(0.0f); }
    float s = sqrt(a.hi);
    // One Newton step on s^2 = a: s + ( a - s^2 ) / ( 2 s ).
    pf_df e = pf_sub(a, pf_mul(pf_df_f(s), pf_df_f(s)));
    return pf_add(pf_df_f(s), pf_df_f(e.hi / (2.0f * s)));
}


// 2^a: a = n + j / 64 + r, 2^(j/64) from PF_EXP2_T, and e^t - 1 for t = r ln 2 (|t| <= ln 2 / 128). Only t + t^2 / 2
// needs double-float: the rest of the series, t^3 ( 1/6 + t / 24 + t^2 / 120 ), is under 2.7e-8, where float32's
// rounding is under 2^-50 (the next term is under 2^-54).
static inline pf_df pf_exp2(pf_df a) {
    if (a.hi < -126.0f) { return pf_df_f(0.0f); }
    float n = rint(a.hi);
    pf_df fraction = pf_sub(a, pf_df_f(n));
    float j = rint(fraction.hi * 64.0f);
    pf_df t = pf_mul(pf_sub(fraction, pf_df_f(j * 0.015625f)), pf_c(PF_LN2));
    float th = t.hi;
    float tail = th * th * th * fma(th, fma(th, 1.0f / 120.0f, 1.0f / 24.0f), PF_INV6.x);
    pf_df em1 = pf_add(t, pf_add(pf_ldexp(pf_mul(t, t), -1), pf_df_f(tail)));
    return pf_ldexp(pf_mul(pf_c(PF_EXP2_T[int(j) + 32]), pf_add(pf_df_f(1.0f), em1)), int(n));
}

// log2 a for a > 0: a = 2^e x, x in [1, 2); with c = PF_LOG_C[i] for x's top seven mantissa bits, x c = 1 + r with
// |r| <= 2^-8, log2 x = log2(1 / c) (PF_LOG_L) + ln(1 + r) / ln 2. Only r - r^2 / 2 needs double-float: the rest,
// r^3 ( 1/3 - r / 4 + r^2 / 5 - r^3 / 6 ), is under 2.1e-8, where float32's rounding is under 2^-50.
static inline pf_df pf_log2(pf_df a) {
    int e;
    frexp(a.hi, e);
    pf_df x = pf_ldexp(a, 1 - e);
    uint i = (as_type<uint>(x.hi) >> 16) & 0x7Fu;
    pf_df r = pf_sub(pf_mul(x, pf_df_f(PF_LOG_C[i])), pf_df_f(1.0f));
    float rh = r.hi;
    float tail = rh * rh * rh * fma(rh, fma(rh, fma(rh, -1.0f / 6.0f, 0.2f), -0.25f), PF_INV3.x);
    pf_df ln1p = pf_add(r, pf_add(pf_neg(pf_ldexp(pf_mul(r, r), -1)), pf_df_f(tail)));
    return pf_add(pf_add(pf_df_f(float(e - 1)), pf_c(PF_LOG_L[i])), pf_mul(ln1p, pf_c(PF_LOG2E)));
}

static inline pf_df pf_pow(pf_df x, pf_df p) {
    if (x.hi <= 0.0f) { return pf_df_f(0.0f); }
    return pf_exp2(pf_mul(p, pf_log2(x)));
}

// MARK: - Reading (av_read_image_line2)

// The component at column x of a plane row. Every argument but the row and x is a function constant, so the
// load width and the address arithmetic fold away.
static inline uint pf_read_row(device const uchar* row, uint step, uint offset, uint shift, uint depth, uint x) {
    uint mask = depth >= 32u ? 0xFFFFFFFFu : ((1u << depth) - 1u);
    if (FC_BITSTREAM) {
        if (step > 8u) {
            uint v = as_type<uint>(*(device const packed_uchar4*)(row + x * 4u));
            return (((v & 0xFFu) << 24) | ((v & 0xFF00u) << 8) | ((v >> 8) & 0xFF00u) | (v >> 24)) >> offset & mask;
        }
        uint skip = x * step + offset;
        return (uint(row[skip >> 3]) >> (8u - depth - (skip & 7u))) & mask;
    }
    device const uchar* q = row + x * step + offset;
    uint bits = shift + depth;
    uint v;
    if (bits <= 8u) {
        v = uint(q[FC_BIG_ENDIAN ? 1 : 0]);
    } else if (bits <= 16u) {
        // A typed load when the component sits on its own alignment (plane offsets and linesizes are checked by
        // PlanarFrameFinisher); bytes otherwise, as for x2rgb10's green at byte 1 of its word.
        if (step % 2u == 0u && offset % 2u == 0u) {
            ushort w = *(device const ushort*)q;
            v = FC_BIG_ENDIAN ? uint((w >> 8) | (w << 8)) & 0xFFFFu : uint(w);
        } else {
            v = FC_BIG_ENDIAN ? (uint(q[0]) << 8 | uint(q[1])) : (uint(q[1]) << 8 | uint(q[0]));
        }
    } else {
        uint w;
        if (step % 4u == 0u && offset % 4u == 0u) {
            w = *(device const uint*)q;
        } else {
            w = uint(q[0]) | uint(q[1]) << 8 | uint(q[2]) << 16 | uint(q[3]) << 24;
        }
        v = FC_BIG_ENDIAN ? (((w & 0xFFu) << 24) | ((w & 0xFF00u) << 8) | ((w >> 8) & 0xFF00u) | (w >> 24)) : w;
    }
    return (v >> shift) & mask;
}

// The component at (x, y) of its own plane's grid.
static inline uint pf_read(device const uchar* src, constant PFFrame& f,
                           uint plane, uint step, uint offset, uint shift, uint depth, uint x, uint y) {
    return pf_read_row(src + f.plane_offset[plane] + y * f.linesize[plane], step, offset, shift, depth, x);
}

// Components 0...2 as decoded.
static inline uint pf_r0(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C0_PLANE, FC_C0_STEP, FC_C0_OFFSET, FC_C0_SHIFT, FC_C0_DEPTH, x, y);
}
static inline uint pf_r1(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C1_PLANE, FC_C1_STEP, FC_C1_OFFSET, FC_C1_SHIFT, FC_C1_DEPTH, x, y);
}
static inline uint pf_r2(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C2_PLANE, FC_C2_STEP, FC_C2_OFFSET, FC_C2_SHIFT, FC_C2_DEPTH, x, y);
}

// The picture and the film grain tables (bound to a placeholder when FC_GRAIN is off).
static inline device const uchar* pf_source(device const uchar* src, device const uchar* alt, device const uint* chosen) {
    return FC_CHOSEN_SOURCE && chosen[0] != 0u ? alt : src;
}

struct pf_src {
    device const uchar* p;
    device const uchar* g;
};

// The sample of plane `plane` at (x, y), as decoded: the component that lives there (for GBR, plane 0 is G).
static inline uint pf_plane_sample(pf_src s, constant PFFrame& f, uint plane, uint x, uint y) {
    if (FC_C0_PLANE == plane) { return pf_r0(s.p, f, x, y); }
    if (FC_C1_PLANE == plane) { return pf_r1(s.p, f, x, y); }
    return pf_r2(s.p, f, x, y);
}


// A sample of plane `plane` with its film grain. Grain is a property of the plane (AV1's planes 0, 1, 2), not of the
// component the finisher reads it as. Chroma takes the un-noised luma at its site. Kept inline: outlined, it is a call
// with a stack frame from every sample read.
static inline __attribute__((always_inline)) uint pf_grained(pf_src s, constant PFFrame& f, uint plane, uint v, uint x, uint y) {
    if (plane == 0u) { return fg_luma(s.g, v, x, y); }
    uint lx = x << FC_SRC_LOG2_W, ly = y << FC_SRC_LOG2_H;
    uint average = pf_plane_sample(s, f, 0u, lx, ly);
    if (FC_SRC_LOG2_W != 0u) { average = (average + pf_plane_sample(s, f, 0u, min(lx + 1u, f.width - 1u), ly) + 1u) >> 1; }
    return fg_chroma(s.g, plane - 1u, v, average, FC_SRC_LOG2_W, FC_SRC_LOG2_H, x, y);
}

// Components 0...2 as shown: with their grain under FC_GRAIN.
static inline uint pf_c0(pf_src s, constant PFFrame& f, uint x, uint y) {
    uint v = pf_r0(s.p, f, x, y);
    return FC_GRAIN ? pf_grained(s, f, FC_C0_PLANE, v, x, y) : v;
}
static inline uint pf_c1(pf_src s, constant PFFrame& f, uint x, uint y) {
    uint v = pf_r1(s.p, f, x, y);
    return FC_GRAIN ? pf_grained(s, f, FC_C1_PLANE, v, x, y) : v;
}
static inline uint pf_c2(pf_src s, constant PFFrame& f, uint x, uint y) {
    uint v = pf_r2(s.p, f, x, y);
    return FC_GRAIN ? pf_grained(s, f, FC_C2_PLANE, v, x, y) : v;
}

// MARK: - Codes at the output depth


// A d-bit luma (or grey) code at T bits with F fraction bits. Video range: a left shift, exact. Full range:
// Round( Y * ( 2^T - 1 ) / ( 2^d - 1 ) ) (36), in 64-bit integers: the quotient has an odd denominator, so it
// never ties, but float32 cannot resolve it at 16-bit words.
static inline uint pf_luma_word(uint v, uint d) {
    if (!FC_FULL_RANGE) { return v << (FC_TARGET_BITS + FC_FRACTION_BITS - d); }
    ulong num = ulong(v) * ulong((1u << FC_TARGET_BITS) - 1u) << (FC_FRACTION_BITS + 1u);
    ulong den = ulong((1u << d) - 1u);
    return min(uint((num + den) / (2ul * den)), PF_WORD_MAX);
}

// A d-bit chroma code at T bits with F fraction bits: video range a shift; full range
// Round( ( C - 2^(d-1) ) * ( 2^T - 1 ) / ( 2^d - 1 ) + 2^(T-1) ) (37), clipped at 0 (Clip1C).
static inline uint pf_chroma_word(uint v, uint d) {
    if (!FC_FULL_RANGE) { return v << (FC_TARGET_BITS + FC_FRACTION_BITS - d); }
    long den = long((1u << d) - 1u);
    long num = (long(v) - long(1u << (d - 1u))) * long((1u << FC_TARGET_BITS) - 1u) * long(1u << (FC_FRACTION_BITS + 1u))
             + den * (long(1u << (FC_TARGET_BITS - 1u + FC_FRACTION_BITS + 1u)) + 1l);
    if (num <= 0l) { return 0u; }
    return min(uint(num / (2l * den)), PF_WORD_MAX);
}

// Integer Bayer 8x8 thresholds (0...63), by row then word.
constant ushort pf_bayer[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,  48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,  60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,  51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,  63, 31, 55, 23, 61, 29, 53, 21,
};

// A word into its container: ordered down to 10 bits when dithering (the threshold added to the 16-bit word
// before the six fraction bits are cleared, saturating at the top code), else MSB-aligned.
static inline uint pf_container(uint w, uint word_x, uint y) {
    if (PF_DITHER) {
        uint sum = w + uint(pf_bayer[(y & 7u) * 8u + (word_x & 7u)]);
        return sum > 0xFFFFu ? 0xFFC0u : (sum & 0xFFC0u);
    }
    return w << FC_CONTAINER_SHIFT;
}

// MARK: - Chroma resampling

// Where sample i sits on one axis, in half luma samples, for a plane subsampled by 2^log2 there. Horizontal:
// co-sited with the left luma sample (LEFT / TOPLEFT / BOTTOMLEFT) or centred on the samples it covers.
// Vertical: on the top row (TOPLEFT / TOP), centred (LEFT / CENTER) or on the bottom row (BOTTOMLEFT / BOTTOM).
static inline int pf_site2(int i, uint log2, bool vertical) {
    int r = 1 << log2, span = r - 1;
    uint l = FC_CHROMA_LOCATION;
    int offset2 = !vertical ? ((l == 1u || l == 3u || l == 5u) ? 0 : span)
                            : ((l == 3u || l == 4u) ? 0 : ((l == 5u || l == 6u) ? 2 * span : span));
    return 2 * i * r + offset2;
}

// Catmull-Rom (B = 0, C = 0.5) weights times 1024 at phase k / 8, over samples -1, 0, 1, 2. Every phase the
// sitings produce is a multiple of 1/8 (sites are half samples apart, ratios are at most 4), so the weights are
// exact integers: k = 2 gives (-72, 888, 232, -24), i.e. (-9, 111, 29, -3) / 128.
static inline int4 pf_cubic8(int k) {
    int k2 = k * k, k3 = k2 * k;
    return int4(-k3 + 16 * k2 - 64 * k, 3 * k3 - 40 * k2 + 1024, -3 * k3 + 32 * k2 + 64 * k, k3 - 8 * k2);
}

// Source chroma (components 1, 2) at output chroma sample `o`, as exact numerators over 2^20 (2^10 per axis).
static inline long2 pf_resample(pf_src s, constant PFFrame& f, uint2 o) {
    if (FC_SRC_LOG2_W == FC_OUT_LOG2_W && FC_SRC_LOG2_H == FC_OUT_LOG2_H) {
        return long2(long(pf_c1(s, f, o.x, o.y)), long(pf_c2(s, f, o.x, o.y))) << 20;
    }
    int src_w = int((f.width + (1u << FC_SRC_LOG2_W) - 1u) >> FC_SRC_LOG2_W);
    int src_h = int((f.height + (1u << FC_SRC_LOG2_H) - 1u) >> FC_SRC_LOG2_H);
    // Source coordinate in eighths: 8 * ( site_out - site_src(0) ) / 2^src_log2, sites in half samples.
    // Both divisions are exact (4 / 2^src_log2 is whole); the floor of a negative coordinate is taken by removing
    // its phase first, so nothing depends on how a signed shift rounds.
    int ux8 = 4 * (pf_site2(int(o.x), FC_OUT_LOG2_W, false) - pf_site2(0, FC_SRC_LOG2_W, false)) / (1 << FC_SRC_LOG2_W);
    int uy8 = 4 * (pf_site2(int(o.y), FC_OUT_LOG2_H, true) - pf_site2(0, FC_SRC_LOG2_H, true)) / (1 << FC_SRC_LOG2_H);
    int x0 = (ux8 - (ux8 & 7)) / 8, y0 = (uy8 - (uy8 & 7)) / 8;
    int4 wx = FC_SRC_LOG2_W == FC_OUT_LOG2_W ? int4(0, 1024, 0, 0) : pf_cubic8(ux8 & 7);
    int4 wy = FC_SRC_LOG2_H == FC_OUT_LOG2_H ? int4(0, 1024, 0, 0) : pf_cubic8(uy8 & 7);
    long2 sum = 0;
    for (int j = 0; j < 4; ++j) {
        if (wy[j] == 0) { continue; }
        uint sy = uint(clamp(y0 - 1 + j, 0, src_h - 1));
        // Four taps of at most 1024 times a 16-bit code stay inside 32 bits.
        int2 row = 0;
        for (int i = 0; i < 4; ++i) {
            if (wx[i] == 0) { continue; }
            uint sx = uint(clamp(x0 - 1 + i, 0, src_w - 1));
            row += wx[i] * int2(int(pf_c1(s, f, sx, sy)), int(pf_c2(s, f, sx, sy)));
        }
        sum += long(wy[j]) * long2(row);
    }
    return sum;
}

// A resampled chroma value (numerator over 2^20, clamped to the source's codes) as an output word, exactly:
// video range Round( c * 2^(T - d) ) with the fraction bits, full range (37) with the real value.
static inline uint pf_resampled_word(long c, uint d) {
    c = clamp(c, 0l, long((1u << d) - 1u) << 20);
    if (!FC_FULL_RANGE) {
        return min(uint(((c << (FC_TARGET_BITS + FC_FRACTION_BITS - d)) + (1l << 19)) >> 20), PF_WORD_MAX);
    }
    long den = long((1u << d) - 1u) << 20;
    long num = (c - (long(1u << (d - 1u)) << 20)) * long((1u << FC_TARGET_BITS) - 1u) * long(1u << (FC_FRACTION_BITS + 1u))
             + den * (long(1u << (FC_TARGET_BITS + FC_FRACTION_BITS)) + 1l);
    return num <= 0l ? 0u : min(uint(num / (2l * den)), PF_WORD_MAX);
}

// MARK: - RGB

static inline int3 pf_rgb_codes(pf_src s, constant PFFrame& f, uint x, uint y) {
    if (FC_PALETTE) {
        // AV_PIX_FMT_PAL8: an index into 256 native-endian ARGB words in plane 1.
        uint e = *(device const uint*)(s.p + f.plane_offset[1] + pf_r0(s.p, f, x, y) * 4u);
        return int3(int((e >> 16) & 0xFFu), int((e >> 8) & 0xFFu), int(e & 0xFFu));
    }
    return int3(int(pf_c0(s, f, x, y)), int(pf_c1(s, f, x, y)), int(pf_c2(s, f, x, y)));
}

// MARK: - Transfer characteristics (H.273 Table 3), for constant luminance

// f.tp by FC_TRANSFER (double-float):
//   1, 6, 14, 15, 7: alpha, beta, slope (4.5; 4.0 for 7), 0.45, 1 / 0.45, 1 / alpha, 1 / slope, alpha - 1
//   13:              alpha, beta, 12.92, 1 / 2.4, 2.4, 1 / alpha, 1 / 12.92, alpha - 1
//   4, 5:            -, -, -, 1 / gamma, gamma
//   16:              c1, c2, c3, m, n, 1 / m, 1 / n, c2 - c1 c3
//   18:              a, b, c, 1 / a
// A value outside the function's domain is clamped to it ([0, 1]; TC 13 is odd-symmetric and unclamped).
constant bool PF_TF_POWER = FC_TRANSFER == 1u || FC_TRANSFER == 6u || FC_TRANSFER == 14u || FC_TRANSFER == 15u
                         || FC_TRANSFER == 7u;
constant bool PF_TF_SRGB = FC_TRANSFER == 13u;
constant bool PF_TF_GAMMA = FC_TRANSFER == 4u || FC_TRANSFER == 5u;
constant bool PF_TF_PQ = FC_TRANSFER == 16u;
constant bool PF_TF_HLG = FC_TRANSFER == 18u;
// A converted picture is encoded at its own depth (convert and constant luminance write d-bit codes, which the depth
// stage takes to the output like any code of that depth). Above 12 bits float32 cannot round them: constant
// luminance goes straight to double-float there.
constant bool PF_EXACT_ONLY = FC_C0_DEPTH > 12u;

// x^p for x >= 0 in float32, through the hardware's exp2 / log2.
static inline float pf_powf(float x, float p) { return x > 0.0f ? precise::exp2(p * precise::log2(x)) : 0.0f; }

// L from V in float32: (L, L's relative error in units of one evaluation's, dL / dV). The relative error is the
// base's rounding raised by the exponent, and for PQ the cancellation in V^(1/m) - c1; dL / dV comes from the same
// intermediates.
static inline float3 pf_tf_inv_f(float v, constant PFFrame& f) {
    if (PF_TF_POWER || PF_TF_SRGB) {
        float a = PF_TF_SRGB ? fabs(v) : clamp(v, 0.0f, 1.0f);
        if (a < f.tp[2].x * f.tp[1].x) { return float3(copysign(a * f.tp[6].x, PF_TF_SRGB ? v : 1.0f), 1.0f, f.tp[6].x); }
        float base = a + f.tp[7].x;
        float l = pf_powf(base * f.tp[5].x, f.tp[4].x);
        return float3(PF_TF_SRGB ? copysign(l, v) : l, 3.0f + f.tp[4].x, f.tp[4].x * l / base);
    } else if (PF_TF_GAMMA) {
        float a = clamp(v, 0.0f, 1.0f);
        float l = pf_powf(a, f.tp[4].x);
        return float3(l, 2.0f + f.tp[4].x, a > 0.0f ? f.tp[4].x * l / a : 0.0f);
    } else if (PF_TF_PQ) {
        float a = clamp(v, 0.0f, 1.0f);
        float p = pf_powf(a, f.tp[5].x);
        float num = p - f.tp[0].x;
        if (num <= 0.0f) { return float3(0.0f, 0.0f, 0.0f); }
        float den = f.tp[1].x - f.tp[2].x * p;
        float l = pf_powf(num / den, f.tp[6].x);
        // d ln L / dV = ( 1 / n ) ( dp / dV ) ( 1 / num + c3 / den ), dp / dV = p / ( m V ).
        float slope = f.tp[6].x * l * f.tp[5].x * (p / a) * (1.0f / num + f.tp[2].x / den);
        return float3(l, 3.0f + f.tp[6].x * (3.0f + p / num), slope);
    } else if (PF_TF_HLG) {
        float a = clamp(v, 0.0f, 1.0f);
        if (a <= 0.5f) { return float3(a * a * (1.0f / 3.0f), 3.0f, a * (2.0f / 3.0f)); }
        float e = precise::exp2((a - f.tp[2].x) * f.tp[3].x * M_LOG2E_F);
        return float3((e + f.tp[1].x) * (1.0f / 12.0f), 4.0f + (a + f.tp[2].x) * f.tp[3].x, e * f.tp[3].x * (1.0f / 12.0f));
    }
    return float3(clamp(v, 0.0f, 1.0f), 0.0f, 1.0f);
}

// V = ( L )' in float32, with dV / dL from the same intermediates (infinite where the curve's slope is).
static inline float2 pf_tf_fwd_f(float l, constant PFFrame& f) {
    if (PF_TF_POWER || PF_TF_SRGB) {
        float a = PF_TF_SRGB ? fabs(l) : clamp(l, 0.0f, 1.0f);
        float v, s;
        if (a < f.tp[1].x) {
            v = f.tp[2].x * a;
            s = f.tp[2].x;
        } else {
            v = f.tp[0].x * pf_powf(a, f.tp[3].x) - f.tp[7].x;
            s = f.tp[3].x * (v + f.tp[7].x) / a;
        }
        return float2(PF_TF_SRGB ? copysign(v, l) : v, s);
    } else if (PF_TF_GAMMA) {
        float a = clamp(l, 0.0f, 1.0f);
        float v = pf_powf(a, f.tp[3].x);
        return float2(v, f.tp[3].x * v / a);
    } else if (PF_TF_PQ) {
        // ( ( c1 + c2 Ln ) / ( 1 + c3 Ln ) )^m as exp( m log1p( u ) ), u = ( 21 / 128 ) ( Ln - 1 ) / ( 1 + c3 Ln ) exactly
        // (c2 - c3 = 21 / 128, c1 - 1 = -21 / 128): the base's rounding is not raised to the 79th power.
        float a = clamp(l, 0.0f, 1.0f);
        float ln = pf_powf(a, f.tp[4].x);
        float d = 1.0f + f.tp[2].x * ln;
        float u = (21.0f / 128.0f) * (ln - 1.0f) / d;
        float w = 1.0f + u;
        float log1p_u = w == 1.0f ? u : precise::log2(w) * M_LN2_F * u / (w - 1.0f);
        float v = precise::exp2(f.tp[3].x * log1p_u * M_LOG2E_F);
        return float2(v, v * f.tp[3].x * f.tp[7].x * f.tp[4].x * ln / ((f.tp[0].x + f.tp[1].x * ln) * d * a));
    } else if (PF_TF_HLG) {
        float a = clamp(l, 0.0f, 1.0f);
        if (a <= 1.0f / 12.0f) {
            float v = precise::sqrt(3.0f * a);
            return float2(v, 1.5f / v);
        }
        float x = 12.0f * a - f.tp[1].x;
        return float2(f.tp[0].x * precise::log2(x) * M_LN2_F + f.tp[2].x, 12.0f * f.tp[0].x / x);
    }
    return float2(clamp(l, 0.0f, 1.0f), 1.0f);
}

static inline pf_df pf_clamp01(pf_df x) {
    if (x.hi < 0.0f) { return pf_df_f(0.0f); }
    if (x.hi > 1.0f || (x.hi == 1.0f && x.lo > 0.0f)) { return pf_df_f(1.0f); }
    return x;
}

// L from V in double-float.
static inline pf_df pf_tf_inv_d(pf_df v, constant PFFrame& f) {
    if (PF_TF_POWER || PF_TF_SRGB) {
        bool negative = PF_TF_SRGB && v.hi < 0.0f;
        pf_df a = PF_TF_SRGB ? (negative ? pf_neg(v) : v) : pf_clamp01(v);
        pf_df l = pf_sub(a, pf_mul(pf_c(f.tp[2]), pf_c(f.tp[1]))).hi < 0.0f
            ? pf_mul(a, pf_c(f.tp[6]))
            : pf_pow(pf_mul(pf_add(a, pf_c(f.tp[7])), pf_c(f.tp[5])), pf_c(f.tp[4]));
        return negative ? pf_neg(l) : l;
    } else if (PF_TF_GAMMA) {
        return pf_pow(pf_clamp01(v), pf_c(f.tp[4]));
    } else if (PF_TF_PQ) {
        pf_df p = pf_pow(pf_clamp01(v), pf_c(f.tp[5]));
        pf_df num = pf_sub(p, pf_c(f.tp[0]));
        if (num.hi <= 0.0f) { return pf_df_f(0.0f); }
        return pf_pow(pf_div(num, pf_sub(pf_c(f.tp[1]), pf_mul(pf_c(f.tp[2]), p))), pf_c(f.tp[6]));
    } else if (PF_TF_HLG) {
        pf_df a = pf_clamp01(v);
        if (pf_sub(a, pf_df_f(0.5f)).hi <= 0.0f) { return pf_mul(pf_mul(a, a), pf_c(PF_INV3)); }
        pf_df e = pf_exp2(pf_mul(pf_mul(pf_sub(a, pf_c(f.tp[2])), pf_c(f.tp[3])), pf_c(PF_LOG2E)));
        return pf_mul(pf_add(e, pf_c(f.tp[1])), pf_c(PF_INV12));
    }
    return pf_clamp01(v);
}

// V = ( L )' in double-float.
static inline pf_df pf_tf_fwd_d(pf_df l, constant PFFrame& f) {
    if (PF_TF_POWER || PF_TF_SRGB) {
        bool negative = PF_TF_SRGB && l.hi < 0.0f;
        pf_df a = PF_TF_SRGB ? (negative ? pf_neg(l) : l) : pf_clamp01(l);
        pf_df v = a.hi < f.tp[1].x ? pf_mul(pf_c(f.tp[2]), a)
                                   : pf_sub(pf_mul(pf_c(f.tp[0]), pf_pow(a, pf_c(f.tp[3]))), pf_c(f.tp[7]));
        return negative ? pf_neg(v) : v;
    } else if (PF_TF_GAMMA) {
        return pf_pow(pf_clamp01(l), pf_c(f.tp[3]));
    } else if (PF_TF_PQ) {
        pf_df ln = pf_pow(pf_clamp01(l), pf_c(f.tp[4]));
        pf_df base = pf_div(pf_add(pf_c(f.tp[0]), pf_mul(pf_c(f.tp[1]), ln)), pf_add(pf_df_f(1.0f), pf_mul(pf_c(f.tp[2]), ln)));
        return pf_pow(base, pf_c(f.tp[3]));
    } else if (PF_TF_HLG) {
        pf_df a = pf_clamp01(l);
        pf_df x = pf_mul(pf_df_f(12.0f), a);
        if (pf_sub(x, pf_df_f(1.0f)).hi <= 0.0f) { return pf_sqrt(pf_mul(pf_df_f(3.0f), a)); }
        return pf_add(pf_mul(pf_mul(pf_c(f.tp[0]), pf_log2(pf_sub(x, pf_c(f.tp[1])))), pf_c(PF_LN2)), pf_c(f.tp[2]));
    }
    return pf_clamp01(l);
}

// MARK: - Constant luminance

// f.cl: K_R, K_B, 1 / K_G, N_B, P_B, N_R, P_R (72)-(75).

// The luma table (PlanarFrameFinisher): per luma code, E'Y and E_Y = its inverse transfer value, as double-float
// pairs computed in double on the host.
struct pf_luma_entry { float2 ey; float2 ly; };

// E'Y from the table, E'PB and E'PR from the chroma numerators (over 2^20) through rows 1 and 2, in double-float.
static inline void pf_cl_signals(constant PFFrame& f, pf_luma_entry e, long2 c, thread pf_df& ey, thread pf_df& epb,
                                 thread pf_df& epr) {
    pf_df zero = pf_df_f(0.0f), cb = pf_df_long(c.x, 0x1p-20f), cr = pf_df_long(c.y, 0x1p-20f);
    ey = pf_df{e.ey.x, e.ey.y};
    epb = pf_affine_df(f, 1u, zero, cb, cr);
    epr = pf_affine_df(f, 2u, zero, cb, cr);
}

// E'B - E'Y and E'R - E'Y from E'PB, E'PR: (68)-(71) inverted, the branch by the sign.
static inline pf_df pf_cl_difference(pf_df e, constant float2& negative, constant float2& positive) {
    return pf_mul(pf_ldexp(e.hi <= 0.0f ? pf_c(negative) : pf_c(positive), 1), e);
}

// Fast path, all float32, each value carrying a first-order absolute error bound: the codes' decode, E'B and E'R,
// the three inverse curves (their own error plus the input's through their slope), E_G's cancelling sum, the forward
// curve (through its slope, plus its own error) and the encode. Writes each output word and its error.
static inline void pf_cl_fast(constant PFFrame& f, pf_luma_entry e, long2 c, thread float* words, thread float* errors) {
    float cb = float(c.x) * 0x1p-20f, cr = float(c.y) * 0x1p-20f;
    // E'Y and E_Y come from the luma table: each within half an ulp, with no transfer evaluation.
    float2 ey = float2(e.ey.x, fabs(e.ey.x) * 0x1p-24f);
    float2 epb = pf_affine_f(f, 1u, 0.0f, cb, cr, 0.0f, fabs(cb) * 0x1p-24f, fabs(cr) * 0x1p-24f);
    float2 epr = pf_affine_f(f, 2u, 0.0f, cb, cr, 0.0f, fabs(cb) * 0x1p-24f, fabs(cr) * 0x1p-24f);
    // E'B = E'Y + 2 N_B E'PB or 2 P_B E'PB by the sign; a value within its error of 0 may take either branch.
    float nb = epb.x <= 0.0f ? f.cl[3].x : f.cl[4].x, nr = epr.x <= 0.0f ? f.cl[5].x : f.cl[6].x;
    float eb = fma(2.0f * nb, epb.x, ey.x), er = fma(2.0f * nr, epr.x, ey.x);
    float e_eb = ey.y + 2.0f * max(f.cl[3].x, f.cl[4].x) * epb.y + fabs(eb) * 0x1p-23f
               + (fabs(epb.x) <= epb.y ? 2.0f * fabs(f.cl[3].x - f.cl[4].x) * fabs(epb.x) : 0.0f);
    float e_er = ey.y + 2.0f * max(f.cl[5].x, f.cl[6].x) * epr.y + fabs(er) * 0x1p-23f
               + (fabs(epr.x) <= epr.y ? 2.0f * fabs(f.cl[5].x - f.cl[6].x) * fabs(epr.x) : 0.0f);
    float eps = f.tie_bound;
    float3 lb = pf_tf_inv_f(eb, f), lr = pf_tf_inv_f(er, f);
    float3 ly = float3(e.ly.x, 0.0f, 0.0f);
    float e_lb = eps * lb.y * fabs(lb.x) + lb.z * e_eb;
    float e_lr = eps * lr.y * fabs(lr.x) + lr.z * e_er;
    float e_ly = fabs(e.ly.x) * 0x1p-24f;
    // E_G = ( E_Y - K_R E_R - K_B E_B ) / K_G.
    float kr = f.cl[0].x, kb = f.cl[1].x, inv_kg = f.cl[2].x;
    float lg = (ly.x - kr * lr.x - kb * lb.x) * inv_kg;
    float e_lg = (e_ly + kr * e_lr + kb * e_lb + (fabs(ly.x) + kr * fabs(lr.x) + kb * fabs(lb.x)) * 0x1p-22f) * inv_kg;
    float2 g = pf_tf_fwd_f(lg, f);
    float e_eg = g.y * e_lg + 4.0f * eps * fabs(g.x);
    for (uint i = 0u; i < 3u; ++i) {
        float2 w = pf_affine_f(f, 3u + i, er, g.x, eb, e_er, e_eg, e_eb);
        words[i] = w.x;
        errors[i] = w.y;
    }
}

// Exact path: all of it in double-float.
static inline void pf_cl_exact(pf_df ey, pf_df epb, pf_df epr, pf_df ly, constant PFFrame& f, thread pf_df* words) {
    pf_df eb = pf_add(ey, pf_cl_difference(epb, f.cl[3], f.cl[4]));
    pf_df er = pf_add(ey, pf_cl_difference(epr, f.cl[5], f.cl[6]));
    pf_df lb = pf_tf_inv_d(eb, f), lr = pf_tf_inv_d(er, f);
    pf_df lg = pf_mul(pf_sub(pf_sub(ly, pf_mul(pf_c(f.cl[0]), lr)), pf_mul(pf_c(f.cl[1]), lb)), pf_c(f.cl[2]));
    pf_df eg = pf_tf_fwd_d(lg, f);
    for (uint i = 0u; i < 3u; ++i) { words[i] = pf_affine_df(f, 3u + i, er, eg, eb); }
}

// Converted d-bit codes (Y, Cb, Cr) to the output at (x, y): through the depth stage, as any code of that depth.
static inline void pf_write_codes(texture2d<uint, access::write> out_y, texture2d<uint, access::write> out_c, uint2 p,
                                  uint3 codes) {
    out_y.write(uint4(pf_container(pf_luma_word(codes.x, FC_C0_DEPTH), p.x, p.y)), p);
    out_c.write(uint4(pf_container(pf_chroma_word(codes.y, FC_C1_DEPTH), 2u * p.x, p.y),
                      pf_container(pf_chroma_word(codes.z, FC_C2_DEPTH), 2u * p.x + 1u, p.y), 0u, 0u), p);
}

constant uint PF_Y_MAX = (1u << FC_C0_DEPTH) - 1u;
constant uint PF_C_MAX = (1u << FC_C1_DEPTH) - 1u;

static inline uint3 pf_round_codes_df(thread pf_df* words) {
    return uint3(pf_round_df(words[0], PF_Y_MAX), pf_round_df(words[1], PF_C_MAX), pf_round_df(words[2], PF_C_MAX));
}

// MARK: - Block threads (convert, constant luminance)

// Convert and constant luminance write 4:4:4 from a source subsampled by 2^src_log2: one thread per source chroma
// sample writes the block of pixels it covers. Every pixel's Catmull-Rom taps fall in the 5 x 5 window of source
// chroma around the thread's sample (its centre column or row only, on an axis that is not subsampled), read once.
constant uint PF_SRC_BW = 1u << FC_SRC_LOG2_W;
constant uint PF_SRC_BH = 1u << FC_SRC_LOG2_H;

static inline void pf_load_window(pf_src s, constant PFFrame& f, uint2 g, thread int2 (&w)[5][5]) {
    int src_w = int((f.width + PF_SRC_BW - 1u) >> FC_SRC_LOG2_W);
    int src_h = int((f.height + PF_SRC_BH - 1u) >> FC_SRC_LOG2_H);
    for (int j = 0; j < 5; ++j) {
        if (PF_SRC_BH == 1u && j != 2) { continue; }
        uint sy = uint(clamp(int(g.y) - 2 + j, 0, src_h - 1));
        for (int i = 0; i < 5; ++i) {
            if (PF_SRC_BW == 1u && i != 2) { continue; }
            uint sx = uint(clamp(int(g.x) - 2 + i, 0, src_w - 1));
            w[j][i] = int2(int(pf_c1(s, f, sx, sy)), int(pf_c2(s, f, sx, sy)));
        }
    }
}

// Chroma at pixel p from the window around source sample g: pf_resample's exact numerators over 2^20.
static inline long2 pf_window_sample(thread int2 (&w)[5][5], uint2 g, uint2 p) {
    if (PF_SRC_BW == 1u && PF_SRC_BH == 1u) { return long2(w[2][2]) << 20; }
    int ux8 = 4 * (pf_site2(int(p.x), 0u, false) - pf_site2(0, FC_SRC_LOG2_W, false)) / int(PF_SRC_BW);
    int uy8 = 4 * (pf_site2(int(p.y), 0u, true) - pf_site2(0, FC_SRC_LOG2_H, true)) / int(PF_SRC_BH);
    int x0 = (ux8 - (ux8 & 7)) / 8, y0 = (uy8 - (uy8 & 7)) / 8;
    int4 wx = PF_SRC_BW == 1u ? int4(0, 1024, 0, 0) : pf_cubic8(ux8 & 7);
    int4 wy = PF_SRC_BH == 1u ? int4(0, 1024, 0, 0) : pf_cubic8(uy8 & 7);
    // Tap k of the pixel sits at source sample x0 - 1 + k, which is window column x0 - 1 + k - ( g.x - 2 ).
    int cx = x0 + 1 - int(g.x), cy = y0 + 1 - int(g.y);
    long2 sum = 0;
    for (int j = 0; j < 4; ++j) {
        if (wy[j] == 0) { continue; }
        int2 row = 0;
        for (int i = 0; i < 4; ++i) {
            if (wx[i] == 0) { continue; }
            row += wx[i] * w[cy + j][cx + i];
        }
        sum += long(wy[j]) * long2(row);
    }
    return sum;
}

// Convert: one pixel's d-bit codes from its luma code and chroma numerators.
static inline uint3 pf_convert_codes(constant PFFrame& f, long y, long2 c) {
    if (FC_MATRIX == 1u) {
        pf_df x0 = pf_df{float(y), 0.0f}, x1 = pf_df_long(c.x, 0x1p-20f), x2 = pf_df_long(c.y, 0x1p-20f);
        return uint3(pf_affine_word(f, 0u, x0, x1, x2, PF_Y_MAX), pf_affine_word(f, 1u, x0, x1, x2, PF_C_MAX),
                     pf_affine_word(f, 2u, x0, x1, x2, PF_C_MAX));
    }
    long h = long(1u << (FC_C1_DEPTH - 1u));
    long rgb_max = long((1u << FC_BITDEPTH_RGB) - 1u);
    long3 rgb;  // numerators over 2^20
    if (FC_MATRIX == 2u) {
        // (54)-(57) on real values: chroma resampled to this pixel is a numerator over 2^20.
        long luma_max = long((1u << FC_C0_DEPTH) - 1u) << 20;
        long cg = c.x - (h << 20), co = c.y - (h << 20);
        long t = (y << 20) - cg;
        rgb = long3(clamp(t + co, 0l, luma_max), clamp((y << 20) + cg, 0l, luma_max), clamp(t - co, 0l, luma_max));
    } else {
        // (62)-(65) are integer lifting: chroma resampled to this pixel is rounded to a code first.
        long cg = ((clamp(c.x, 0l, long((1u << FC_C1_DEPTH) - 1u) << 20) + (1l << 19)) >> 20) - h;
        long co = ((clamp(c.y, 0l, long((1u << FC_C2_DEPTH) - 1u) << 20) + (1l << 19)) >> 20) - h;
        // >> of a negative value is floor division here, as H.273's arithmetic shift: (v - (v & 1)) / 2.
        long t = y - (cg - (cg & 1l)) / 2l;
        long g = clamp(t + cg, 0l, rgb_max);
        long b = clamp(t - (co - (co & 1l)) / 2l, 0l, rgb_max);
        long r = clamp(b + co, 0l, rgb_max);
        rgb = long3(r, g, b) << 20;
    }
    pf_df r = pf_df_long(rgb.x, 0x1p-20f), g = pf_df_long(rgb.y, 0x1p-20f), b = pf_df_long(rgb.z, 0x1p-20f);
    return uint3(pf_affine_word(f, 0u, r, g, b, PF_Y_MAX), pf_affine_word(f, 1u, r, g, b, PF_C_MAX),
                 pf_affine_word(f, 2u, r, g, b, PF_C_MAX));
}

// MARK: - Kernel

kernel void pf_finish(device const uchar*            src     [[buffer(0)]],
                      constant PFFrame&               f       [[buffer(1)]],
                      device atomic_uint*             list    [[buffer(2)]],
                      device const pf_luma_entry*     lut     [[buffer(4)]],
                      device const uchar*             grain   [[buffer(5)]],
                      device const uchar*             alt     [[buffer(6)]],
                      device const uint*              chosen  [[buffer(7)]],
                      texture2d<uint, access::write>  out_y   [[texture(0)]],
                      texture2d<uint, access::write>  out_c   [[texture(1)]],
                      uint2                           gid     [[thread_position_in_grid]]) {
    pf_src s = pf_src{pf_source(src, alt, chosen), grain};
    if (FC_MODE == 4u || FC_MODE == 5u) {
        // gid is a source chroma sample; its block of pixels.
        uint2 base = gid * uint2(PF_SRC_BW, PF_SRC_BH);
        if (base.x >= f.width || base.y >= f.height) { return; }
        int2 window[5][5];
        pf_load_window(s, f, gid, window);
        uint flagged = 0u;  // bit k: the block's pixel k needs the exact recompute
        for (uint j = 0u; j < PF_SRC_BH; ++j) {
            for (uint i = 0u; i < PF_SRC_BW; ++i) {
                uint2 p = base + uint2(i, j);
                if (p.x >= f.width || p.y >= f.height) { continue; }
                uint y = pf_c0(s, f, p.x, p.y);
                long2 c = pf_window_sample(window, gid, p);
                if (FC_MODE == 4u) {
                    pf_write_codes(out_y, out_c, p, pf_convert_codes(f, long(y), c));
                } else if (PF_EXACT_ONLY) {
                    pf_luma_entry e = lut[y];
                    pf_df ey, epb, epr, words[3];
                    pf_cl_signals(f, e, c, ey, epb, epr);
                    pf_cl_exact(ey, epb, epr, pf_df{e.ly.x, e.ly.y}, f, words);
                    pf_write_codes(out_y, out_c, p, pf_round_codes_df(words));
                } else {
                    float fast[3], errors[3];
                    pf_cl_fast(f, lut[y], c, fast, errors);
                    pf_write_codes(out_y, out_c, p, uint3(pf_round_f(fast[0], PF_Y_MAX), pf_round_f(fast[1], PF_C_MAX),
                                                          pf_round_f(fast[2], PF_C_MAX)));
                    // A word within twice its error bound of a rounding tie is recomputed exactly.
                    bool flag = false;
                    for (uint k = 0u; k < 3u; ++k) { flag = flag || pf_near_tie_f(fast[k], 2.0f * errors[k]); }
                    if (flag && f.tie_bound > 0.0f) { flagged |= 1u << (j * PF_SRC_BW + i); }
                }
            }
        }
        if (FC_MODE == 5u && !PF_EXACT_ONLY) {
            // One atomic per SIMD group: the flagged pixels take consecutive slots from the group's single add.
            uint mine = popcount(flagged);
            uint before = simd_prefix_exclusive_sum(mine);
            uint total = simd_sum(mine);
            uint slot = 0u;
            if (simd_is_first() && total > 0u) { slot = atomic_fetch_add_explicit(&list[0], total, memory_order_relaxed); }
            slot = simd_broadcast_first(slot) + before;
            for (uint k = 0u; k < PF_SRC_BW * PF_SRC_BH; ++k) {
                if ((flagged & (1u << k)) == 0u) { continue; }
                if (slot < f.list_capacity) {
                    uint2 p = base + uint2(k % PF_SRC_BW, k / PF_SRC_BW);
                    atomic_store_explicit(&list[1u + slot], p.x | (p.y << 16), memory_order_relaxed);
                }
                ++slot;
            }
        }
        return;
    }
    if (gid.x >= f.chroma_width || gid.y >= f.chroma_height) { return; }
    uint cb, cr;
    if (FC_MODE == 3u) {
        // RGB goes out 4:4:4: one pixel, all three outputs from one read.
        int3 c = pf_rgb_codes(s, f, gid.x, gid.y);
        pf_df r = pf_df{float(c.x), 0.0f}, g = pf_df{float(c.y), 0.0f}, b = pf_df{float(c.z), 0.0f};
        out_y.write(uint4(pf_container(pf_affine_word(f, 0u, r, g, b, PF_WORD_MAX), gid.x, gid.y)), gid);
        cb = pf_affine_word(f, 1u, r, g, b, PF_WORD_MAX);
        cr = pf_affine_word(f, 2u, r, g, b, PF_WORD_MAX);
    } else {
        uint2 base = gid * uint2(PF_BLOCK_W, PF_BLOCK_H);
        for (uint j = 0u; j < PF_BLOCK_H; ++j) {
            for (uint i = 0u; i < PF_BLOCK_W; ++i) {
                uint2 p = base + uint2(i, j);
                if (p.x < f.width && p.y < f.height) {
                    out_y.write(uint4(pf_container(pf_luma_word(pf_c0(s, f, p.x, p.y), FC_C0_DEPTH), p.x, p.y)), p);
                }
            }
        }
        if (FC_MODE == 2u) {
            cb = cr = 1u << (FC_TARGET_BITS - 1u + FC_FRACTION_BITS);
        } else if (FC_MODE == 1u) {
            long2 c = pf_resample(s, f, gid);
            cb = pf_resampled_word(c.x, FC_C1_DEPTH);
            cr = pf_resampled_word(c.y, FC_C2_DEPTH);
        } else {
            cb = pf_chroma_word(pf_c1(s, f, gid.x, gid.y), FC_C1_DEPTH);
            cr = pf_chroma_word(pf_c2(s, f, gid.x, gid.y), FC_C2_DEPTH);
        }
    }
    out_c.write(uint4(pf_container(cb, 2u * gid.x, gid.y), pf_container(cr, 2u * gid.x + 1u, gid.y), 0u, 0u), gid);
}

// The pixels the fast path flagged, as indirect dispatch arguments for pf_cl_correct (64 threads a group).
kernel void pf_cl_prepare(device atomic_uint* list [[buffer(2)]], device uint* arguments [[buffer(3)]],
                          constant PFFrame& f [[buffer(1)]]) {
    uint count = min(atomic_load_explicit(&list[0], memory_order_relaxed), f.list_capacity);
    arguments[0] = (count + 63u) / 64u;
    arguments[1] = 1u;
    arguments[2] = 1u;
}

// Each flagged pixel recomputed in double-float, overwriting the fast path's words.
kernel void pf_cl_correct(device const uchar*            src     [[buffer(0)]],
                          constant PFFrame&               f       [[buffer(1)]],
                          device atomic_uint*             list    [[buffer(2)]],
                          device const pf_luma_entry*     lut     [[buffer(4)]],
                          device const uchar*             grain   [[buffer(5)]],
                          device const uchar*             alt     [[buffer(6)]],
                          device const uint*              chosen  [[buffer(7)]],
                          texture2d<uint, access::write>  out_y   [[texture(0)]],
                          texture2d<uint, access::write>  out_c   [[texture(1)]],
                          uint                            gid     [[thread_position_in_grid]]) {
    pf_src s = pf_src{pf_source(src, alt, chosen), grain};
    uint count = min(atomic_load_explicit(&list[0], memory_order_relaxed), f.list_capacity);
    if (gid >= count) { return; }
    uint packed = atomic_load_explicit(&list[1u + gid], memory_order_relaxed);
    uint2 p = uint2(packed & 0xFFFFu, packed >> 16);
    pf_luma_entry e = lut[pf_c0(s, f, p.x, p.y)];
    pf_df ey, epb, epr, words[3];
    pf_cl_signals(f, e, pf_resample(s, f, p), ey, epb, epr);
    pf_cl_exact(ey, epb, epr, pf_df{e.ly.x, e.ly.y}, f, words);
    pf_write_codes(out_y, out_c, p, pf_round_codes_df(words));
}
