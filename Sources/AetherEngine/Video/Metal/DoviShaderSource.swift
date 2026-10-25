// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation

/// Canonical Metal source for the Dolby Vision FEL composer.
///
/// `DoviFelComposer` compiles ``source`` at runtime with
/// `MTLDevice.makeLibrary(source:)` on demand.
enum DoviShaderSource {

    /// Metal-side spelling of the fixed-width typedefs the shared block uses.
    static let preamble = """
#include <metal_stdlib>
using namespace metal;

typedef uint dovi_u32;
typedef int  dovi_i32;
"""

    /// Definitions of the parameters and structs consumed by the Metal kernels.
    static let sharedStructs = """
/* DOVI_SHARED_STRUCTS_BEGIN */
/* ---- Target output modes (informational; the composer always emits
   video-range 10-bit P010, so this does not currently switch clamping) ---- */
#define DOVI_TARGET_MODE_PROFILE_8_1  0 /* Rec.2020 YCbCr PQ 10-bit limited range */
#define DOVI_TARGET_MODE_PROFILE_5    1 /* Dolby IPTPQc2 10-bit full range */

/* ---- Dither modes ---- */
#define DOVI_DITHER_NONE              0 /* round to nearest */
#define DOVI_DITHER_BAYER_8X8         1 /* ordered dither, inverted on odd frames */
#define DOVI_DITHER_FULL_PRECISION    3 /* keep the VDR bits below the 10-bit code in P010's low 6 bits */
#define DOVI_DEBUG_RAW_VDR            2 /* test only: write the un-quantised VDR code << 4 (12-bit in 16) */
#define DOVI_DITHER_BLUE_NOISE        4 /* static 64x64 blue-noise threshold map, no per-frame change */

/* ---- nlq_method_idc (ETSI GS CCM 001). Anything other than LINEAR yields no
   residual rather than a wrong inverse, degrading to base-layer output. ---- */
#define DOVI_NLQ_METHOD_LINEAR        0
#define DOVI_NLQ_METHOD_NONE          0xFFFFFFFFu

/* ---- mapping_idc, per reshaping piece ---- */
#define DOVI_MAPPING_POLYNOMIAL       0
#define DOVI_MAPPING_MMR              1

/* ---- per-frame MMR table (buffer 3): [Y, Cb, Cr][piece 0..7][constant, 21 coefficients, estimate flag] as int,
        then the same layout again as float (the coefficients' float values; the flag slot unused) ---- */
#define DOVI_MMR_TABLE_PIECE_STRIDE      23
#define DOVI_MMR_TABLE_COMPONENT_STRIDE  (8 * DOVI_MMR_TABLE_PIECE_STRIDE)
#define DOVI_MMR_TABLE_FLOAT_OFFSET      (3 * DOVI_MMR_TABLE_COMPONENT_STRIDE)

/* ---- flags ---- */
#define DOVI_FLAG_DISABLE_RESIDUAL    0x1u /* disable_residual_flag, or el_type == MEL */
#define DOVI_FLAG_LUMA_MMR            0x2u /* luma curve has at least one MMR piece */
#define DOVI_FLAG_CHROMA_422          0x4u /* output chroma plane is 4:2:2 (sv22): each sample covers two rows */

/* Piecewise reshaping curve for one component.
 *
 * num_pivots < 2 means "identity passthrough"; the parser installs that as the
 * fail-safe whenever a curve cannot be trusted, so a malformed RPU degrades to
 * the base layer instead of to black.
 *
 * pivots are absolute (prefix-summed) BL code values, ascending, and pivots[0]
 * / pivots[num_pivots - 1] bound the evaluation domain. method[i] selects how
 * piece i is evaluated. The syntax lets a component mix polynomial and MMR
 * pieces, but libdovi keeps one mapping_idc per component (the last piece's) and
 * one coefficient list per method, so a mixed curve cannot be read back
 * through its C API, and DoviRpuGuard refuses it before it gets here: in
 * practice every piece of a component has the same method. order[i] is
 * the polynomial order for a polynomial piece and the MMR order for an MMR
 * piece. coef[i][j] is Q(coef_shift[i]) and is evaluated against inputs
 * normalised by dividing the BL code value by 2^bl_bit_depth (bl_max + 1), the
 * fixed-point convention of the spec's pseudo-code. */
struct DoviPolynomialParams {
    dovi_u32 num_pivots;
    dovi_u32 pivots[9];
    dovi_u32 method[8];
    dovi_u32 order[8];
    dovi_i32 coef[8][3];
    dovi_u32 coef_shift[8];
};

/* Multiple-model regression coefficients, one set per reshaping piece.
 *
 * The piece count, the per-piece MMR order and the piece selection all live in
 * the matching DoviPolynomialParams; this block only carries the coefficients,
 * laid out as coef[piece][order * 7 + term] over the seven cross terms
 * [y, u, v, yu, yv, uv, yuv]. Order o contributes those terms raised to the
 * power o + 1. Every coefficient is Q(coef_shift) against normalised inputs. */
struct DoviMmrParams {
    dovi_i32 mmr_constant[8];
    dovi_i32 coef[8][21];
    dovi_u32 coef_shift;
};

/* Inverse non-linear quantisation for one component.
 *
 * nlq_scale and nlq_threshold are Q(coefficient_log2_denom) in the normalised
 * residual domain; nlq_shift = coefficient_log2_denom - vdr_bit_depth converts
 * that product into VDR code units. vdr_in_max is the ceiling already reduced
 * to VDR code units by the parser. */
struct DoviNlqParams {
    dovi_u32 nlq_method;
    dovi_i32 nlq_offset;
    dovi_i32 nlq_scale;
    dovi_i32 nlq_threshold;
    dovi_i32 vdr_in_max;
    dovi_u32 nlq_shift;
    dovi_u32 nlq_pivots[2];
};

struct DoviMetalParams {
    dovi_u32 bl_width;
    dovi_u32 bl_height;
    dovi_u32 el_width;
    dovi_u32 el_height;

    dovi_u32 target_mode;
    dovi_u32 dither_mode;
    dovi_u32 frame_index;
    dovi_u32 flags;

    struct DoviPolynomialParams poly_y;
    struct DoviMmrParams        mmr_y;
    struct DoviNlqParams        nlq_y;

    struct DoviPolynomialParams poly_cb;
    struct DoviMmrParams        mmr_cb;
    struct DoviNlqParams        nlq_cb;

    struct DoviPolynomialParams poly_cr;
    struct DoviMmrParams        mmr_cr;
    struct DoviNlqParams        nlq_cr;

    dovi_u32 min_pq;
    dovi_u32 max_pq;
    dovi_u32 avg_pq;

    /* Bit-depth derived constants, so the kernels carry no literal 1023/4095.
       bl_max   = (1 << bl_bit_depth) - 1
       vdr_max  = (1 << vdr_bit_depth) - 1
       vdr_scale = 1 << (vdr_bit_depth - bl_bit_depth)
       Curve inputs are normalised by 2^bl_bit_depth (bl_max + 1) and a normalised
       prediction is denormalised by (bl_max + 1) * vdr_scale = 2^vdr_bit_depth, the
       same scale both ways, so an identity curve is bit-exact and a neutral chroma
       (code 512) maps to exactly 2048 (DoViBaker agrees; scaling by bl_max instead
       puts it at 2049, and up to 2041 through an MMR constant). */
    dovi_u32 bl_max;
    dovi_u32 vdr_max;
    dovi_u32 vdr_scale;

    /* The base layer's chroma siting as FFmpeg's AVChromaLocation (chroma_sample_loc_type + 1; 0 =
       unspecified). Read only by dovi_compose_chroma_422, for the vertical phase of each 4:2:2 row. */
    dovi_u32 bl_chroma_loc;

    /* FEL / MEL split view: the luma column from which the residual is no longer added, so the left of the
       picture is the full FEL result and the right what a MEL stream decodes to. 0 = no split. */
    dovi_u32 residual_split_x;
};
/* DOVI_SHARED_STRUCTS_END */
"""

    /// Kernel bodies and their helpers: the only place the composition math is
    /// written down, shared by both consumers unchanged.
    static let kernels = """

/* ============================================================================
   Ordered dither
   ========================================================================= */

constant float dovi_bayer_8x8[64] = {
     0.0f/64.0f, 32.0f/64.0f,  8.0f/64.0f, 40.0f/64.0f,  2.0f/64.0f, 34.0f/64.0f, 10.0f/64.0f, 42.0f/64.0f,
    48.0f/64.0f, 16.0f/64.0f, 56.0f/64.0f, 24.0f/64.0f, 50.0f/64.0f, 18.0f/64.0f, 58.0f/64.0f, 26.0f/64.0f,
    12.0f/64.0f, 44.0f/64.0f,  4.0f/64.0f, 36.0f/64.0f, 14.0f/64.0f, 46.0f/64.0f,  6.0f/64.0f, 38.0f/64.0f,
    60.0f/64.0f, 28.0f/64.0f, 52.0f/64.0f, 20.0f/64.0f, 62.0f/64.0f, 30.0f/64.0f, 54.0f/64.0f, 22.0f/64.0f,
     3.0f/64.0f, 35.0f/64.0f, 11.0f/64.0f, 43.0f/64.0f,  1.0f/64.0f, 33.0f/64.0f,  9.0f/64.0f, 41.0f/64.0f,
    51.0f/64.0f, 19.0f/64.0f, 59.0f/64.0f, 27.0f/64.0f, 49.0f/64.0f, 17.0f/64.0f, 57.0f/64.0f, 25.0f/64.0f,
    15.0f/64.0f, 47.0f/64.0f,  7.0f/64.0f, 39.0f/64.0f, 13.0f/64.0f, 45.0f/64.0f,  5.0f/64.0f, 37.0f/64.0f,
    63.0f/64.0f, 31.0f/64.0f, 55.0f/64.0f, 23.0f/64.0f, 61.0f/64.0f, 29.0f/64.0f, 53.0f/64.0f, 21.0f/64.0f
};

// Function constant 0: the blue-noise dither (DOVI_DITHER_BLUE_NOISE) compiled in. The default pipelines are
// specialised with it false, so the ordered-dither path carries no mode test: testing dither_mode there at run
// time measured +2.5% UHD GPU time on an M4 Pro (0.743 -> 0.762 ms), with no blue-noise frame in sight.
constant bool dovi_fc_blue_noise [[function_constant(0)]];

// Blue-noise threshold in [0.5/4096, 4095.5/4096]: rank k of the 4096 cells maps to (k + 0.5) / 4096, so the
// mean over the tile is exactly 0.5, the rounding bias of the undithered branch. A 10-bit code plus the
// threshold needs 10 + 13 bits, inside float's 24, so floor(v + d) is exact. Each component reads the tile at
// its own toroidal offset (Bayer phases (0,0) / (1,0) / (1,1) become (0,0) / (32,0) / (48,32)),
// each pair at least half a tile apart along one axis, where a blue-noise map is uncorrelated with itself.
static inline float dovi_blue_noise(uint2 gid, uint2 phase) {
    uint2 o = uint2(phase.x * 32u + phase.y * 16u, phase.y * 32u);
    uint x = (gid.x + o.x) & 63u;
    uint y = (gid.y + o.y) & 63u;
    return (float(dovi_blue_noise_64[y * 64u + x]) + 0.5f) * (1.0f / 4096.0f);
}

// Ordered dither offset in [0.5/64, 63.5/64], whose mean over the cell is
// exactly 0.5 -- the same rounding bias the undithered branch applies.
//
// The raw Bayer table holds k/64 for k in 0..63 and averages 31.5/64 = 0.4921875,
// 1/128 of a code low. That bias is invisible at any bit depth a Dolby Vision
// stream can ask for: the value reaching the rounding step has a fraction of
// j/vdr_scale, and for vdr_scale <= 64 the raw and centred tables select exactly
// the same cells at every j, so 10-bit BL into 12-bit VDR (vdr_scale = 4) is
// bit-identical either way. It becomes visible only at the vdr_scale >= 128 that
// setBitDepths still accepts, where the raw table's worst per-level error is
// 0.0117 codes against the centred table's 0.0078. Centring costs one add, makes
// the mean exactly 0.5 as claimed, and removes the case where it would matter.
//
// phase translates the cell so that two components written from the same value do
// not receive the same pattern. Not every translation does that: this matrix
// satisfies M[(y + 4) % 8][(x + 4) % 8] == M[y][x] +/- 1, so the (4, 4) diagonal
// is its own near-symmetry (a Cr phase there leaves Cb and Cr disagreeing on
// an average of 1 pixel in 64 -- at the 50% level, where the selected set is a
// checkerboard in (x + y) parity and a (4, 4) shift preserves parity, on zero
// pixels). Translations of odd parity are the ones that decorrelate, averaging 32
// pixels in 64. Parity is additive, so three mutually odd offsets do not exist;
// (0, 0) / (1, 0) / (1, 1) makes the two chroma components and the luma-Cb pair
// odd and leaves luma-Cr, which is also the pair that differs in plane and in
// resolution, at 16 in 64.
//
// The blue-noise pipelines (function constant `dovi_fc_blue_noise`) take the threshold from the 64x64
// blue-noise rank map instead (`dovi_blue_noise`): the same mean, its error pushed to high spatial
// frequencies rather than onto the Bayer grid's fixed periods, and static from frame to frame.
static inline float dovi_dither(uint2 gid, uint frame_index, uint2 phase) {
    if (dovi_fc_blue_noise) {
        return dovi_blue_noise(gid, phase);
    }
    uint dx = (gid.x + phase.x) % 8u;
    uint dy = (gid.y + phase.y) % 8u;
    float d = dovi_bayer_8x8[dy * 8u + dx];
    if (frame_index & 1u) {
        // Inversion is over the raw table, so the frame pair still covers every
        // cell exactly once; the half-step is added to both frames afterwards.
        d = (63.0f / 64.0f) - d;
    }
    return d + (0.5f / 64.0f);
}

/* ============================================================================
   Reshaping curve evaluation
   ========================================================================= */

// The composition arithmetic is ETSI GS CCM 001's fixed point, clause by clause:
// - a base-layer value s enters as t = s << (20 - BL_bit_depth), Q20 of s / 2^BL_bit_depth (5.4.2.3.2's
//   `ss << shift`, 5.4.2.3.3's tt[1..3]), and a product of two terms is taken back to Q20 with >> 20. For integer
//   s that is the spec's own term (s0 * s1 << (20 - 2 * BL_bit_depth) is (t0 * t1) >> 20 exactly);
// - a prediction v is the 16-bit `vv >> (4 + coefficient_log2_denom)`, negative sums 0, capped at 0xffff;
// - the residual r is 5.4.3.2's 16-bit value (`DoviFelComposer.inverseNlq`, tabulated per EL code);
// - v + r is kept whole until the output is written (dovi_reconstruct and the writers below).
// The 4:2:2 kernel's interpolated base chroma is a multiple of 1/128 of a code, which Q20 holds exactly, so it
// runs the same arithmetic on its fractional values.

// Q20 shift for a base-layer code: 20 - BL_bit_depth.
static inline uint dovi_q20_shift(uint bl_max) {
    return 20u - (32u - clz(bl_max));
}

// The arithmetic is the spec's 64-bit integers, carried in 32-bit words, which Apple GPUs multiply natively where
// 64-bit integers are emulated:
// - every term is non-negative and below 2^20 (a clamped base-layer value in Q20, or a product of two), so a product
//   of two is below 2^40 and (a * b) >> 20 is its high word shifted up by 12 and its low word down by 20, exactly;
// - a sum of coefficient * term (a signed 32-bit coefficient times a term below 2^20) is a two-word accumulator,
//   each product's words from mul and the signed mulhi, the carry added by hand: int64 arithmetic, wrapping
//   included.

// (a * b) >> 20 for a * b below 2^52.
static inline uint dovi_mul_q20(uint a, uint b) {
    return (mulhi(a, b) << 12) | ((a * b) >> 20);
}

// A 64-bit sum as its high (signed) and low words.
struct DoviAcc {
    int hi;
    uint lo;
};

// constant << 20, the spec's `coef * tt[0]` (`poly_coef[0] * (1 << 20)`).
static inline DoviAcc dovi_acc_constant(int c) {
    return DoviAcc{ c >> 12, uint(c) << 20 };
}

// acc += c * t, for 0 <= t < 2^31.
static inline void dovi_acc_add(thread DoviAcc &acc, int c, uint t) {
    uint lo = uint(c) * t;
    int hi = mulhi(c, int(t));
    uint sum = acc.lo + lo;
    acc.hi += hi + (sum < lo ? 1 : 0);
    acc.lo = sum;
}

// 5.4.2.3: the accumulated Q(20 + coefficient_log2_denom) sum to the 16-bit prediction: negative sums 0,
// `>> (4 + coefficient_log2_denom)`, capped at 0xffff. The shift is held below 64, where a hostile coef_shift would
// otherwise leave it undefined.
static inline int dovi_prediction(DoviAcc acc, uint coef_shift) {
    if (acc.hi < 0) {
        return 0;
    }
    uint k = min(4u + coef_shift, 63u);
    uint hi = uint(acc.hi);
    if (k >= 32u) {
        return int(min(hi >> (k - 32u), 0xffffu));
    }
    if ((hi >> k) != 0u) {
        return 0xffff;   // at least 2^32 after the shift
    }
    return int(min((hi << (32u - k)) | (acc.lo >> k), 0xffffu));
}

// Index of the piece owning t: the last pivot that t reaches. 5.4.2.2 takes the first piece whose next pivot is
// above s, which is the same piece, a zero-width piece (two equal pivots) included: both give the later one. Past
// the last pivot the spec's index runs one beyond the pieces; the value is clamped to that pivot anyway, so the
// last piece is the one that applies.
static inline int dovi_select_piece(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    int last_piece = int(curve.num_pivots) - 2;
    int piece = 0;
    for (int i = 0; i <= last_piece; ++i) {
        if (t >= (curve.pivots[i] << shift)) {
            piece = i;
        }
    }
    return clamp(piece, 0, max(last_piece, 0));
}

// t clamped to a component's pivot range, in Q20 (5.4.2.3.2 and the s0 / s1 / s2 clamps of 5.4.2.3.3). A
// component with no usable curve (num_pivots < 2) has no range and is left as is.
static inline uint dovi_clamp_to_pivots(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    if (curve.num_pivots < 2u) {
        return t;
    }
    return clamp(t, curve.pivots[0] << shift, curve.pivots[curve.num_pivots - 1u] << shift);
}

// 5.4.2.3.2, polynomial piece: the sum of poly_coef[i] * s^i at Q20, i <= 2.
static inline int dovi_eval_poly(constant struct DoviPolynomialParams &curve, int piece, uint t, uint shift) {
    t = dovi_clamp_to_pivots(curve, t, shift);
    DoviAcc acc = dovi_acc_constant(curve.coef[piece][0]);
    uint order = curve.order[piece];
    if (order >= 1u) {
        dovi_acc_add(acc, curve.coef[piece][1], t);
    }
    if (order >= 2u) {
        dovi_acc_add(acc, curve.coef[piece][2], dovi_mul_q20(t, t));
    }
    return dovi_prediction(acc, curve.coef_shift[piece]);
}

// 5.4.2.3.3's tt[1...21] for MMR inputs already clamped to their pivots, up to `order`: the seven terms [s0, s1, s2,
// s0s1, s0s2, s1s2, s0s1s2], then their squares, then their cubes (term * square), each product truncated back to
// Q20 as the spec's are. Cb and Cr read the same three inputs, so a chroma sample forms these once for both.
static inline void dovi_mmr_terms(uint t0, uint t1, uint t2, uint order, thread uint* tt, thread float* ttf) {
    tt[0] = t0;
    tt[1] = t1;
    tt[2] = t2;
    tt[3] = dovi_mul_q20(t0, t1);
    tt[4] = dovi_mul_q20(t0, t2);
    tt[5] = dovi_mul_q20(t1, t2);
    tt[6] = dovi_mul_q20(tt[3], t2);
    if (order >= 2u) {
        for (int j = 0; j < 7; ++j) {
            tt[7 + j] = dovi_mul_q20(tt[j], tt[j]);
        }
    }
    if (order >= 3u) {
        for (int j = 0; j < 7; ++j) {
            tt[14 + j] = dovi_mul_q20(tt[j], tt[7 + j]);
        }
    }
    // The float values the estimate reads (exact: every term is below 2^24), formed once for Cb and Cr.
    for (int j = 0; j < 21; ++j) {
        ttf[j] = float(tt[j]);
    }
}

// 5.4.2.3.3, MMR piece: the constant and the order's terms against their coefficients. `k` is this component's slice
// of the per-frame MMR table (`populateMmrTable`): per piece the constant, the 21 coefficients, Q(coef_shift), and
// whether the estimate below is safe for the piece.
//
// The sum vv is the spec's 64-bit integer. Its low word is exact from wrapping 32-bit multiply-adds, one multiply per
// coefficient. Its high word is pinned by a float estimate E of the same sum, the coefficients' float values against
// the exact terms: with A = sum of |c * t|, E is within (n + 2) * 2^-24 * A of vv, and for A <= 2^49 that is under
// 2^31, so hi = rint((E - lo) / 2^32) is vv's high word exactly. The CPU bounds A per piece with the term ceiling
// 2^20 and sets the flag; a piece it cannot bound takes the two-word product path, exact for any coefficient.
static inline int dovi_eval_mmr(device const int* k, int piece, uint order, uint coef_shift, thread const uint* tt,
                                thread const float* ttf) {
    device const int* c = k + piece * DOVI_MMR_TABLE_PIECE_STRIDE;
    // Loops of fixed length, the order tested per block of seven: a loop bound known only at run time would keep
    // tt[] in addressable memory instead of registers.
    if (c[22] != 0) {
        device const float* f = (device const float*)(c + DOVI_MMR_TABLE_FLOAT_OFFSET);
        uint lo = uint(c[0]) << 20;
        float e = f[0] * 1048576.0f;
        for (uint o = 0u; o < 3u; ++o) {
            if (o < order) {
                for (uint j = 0u; j < 7u; ++j) {
                    uint i = o * 7u + j;
                    lo += uint(c[1u + i]) * tt[i];
                    e = fma(f[1u + i], ttf[i], e);
                }
            }
        }
        int hi = int(rint((e - float(lo)) * 0x1p-32f));
        return dovi_prediction(DoviAcc{ hi, lo }, coef_shift);
    }
    DoviAcc acc = dovi_acc_constant(c[0]);
    for (uint o = 0u; o < 3u; ++o) {
        if (o < order) {
            for (uint j = 0u; j < 7u; ++j) {
                dovi_acc_add(acc, c[1u + o * 7u + j], tt[o * 7u + j]);
            }
        }
    }
    return dovi_prediction(acc, coef_shift);
}

// The MMR inputs of a sample: luma (downsampled to the chroma site, 5.4.2.3.3) and the two chroma values, each
// clamped to its own component's pivots.
static inline void dovi_mmr_inputs(constant struct DoviMetalParams &params, uint t0, uint t1, uint t2, uint shift,
                                   thread uint &c0, thread uint &c1, thread uint &c2) {
    c0 = dovi_clamp_to_pivots(params.poly_y, t0, shift);
    c1 = dovi_clamp_to_pivots(params.poly_cb, t1, shift);
    c2 = dovi_clamp_to_pivots(params.poly_cr, t2, shift);
}

// Whether `curve`'s piece for t is MMR, and that piece's order (0 when it is not).
static inline uint dovi_mmr_order(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    if (curve.num_pivots < 2u) {
        return 0u;
    }
    int piece = dovi_select_piece(curve, t, shift);
    return curve.method[piece] == DOVI_MAPPING_MMR ? curve.order[piece] : 0u;
}

// One component's 16-bit prediction from its own value t (Q20). An MMR piece reads `tt`, the sample's MMR terms
// (dovi_mmr_terms), formed up to at least its order. num_pivots < 2 is the parser's fail-safe for a curve it could
// not trust, and means identity: the base layer passes through untouched (v = s << (16 - BL_bit_depth), the identity
// polynomial's exact value).
static inline int dovi_eval_curve(
    constant struct DoviPolynomialParams &curve,
    device const int* mmr,
    uint mmr_coef_shift,
    uint t,
    thread const uint* tt,
    thread const float* ttf,
    uint shift)
{
    if (curve.num_pivots < 2u) {
        return int(min(t >> 4, 0xffffu));
    }
    int piece = dovi_select_piece(curve, t, shift);
    if (curve.method[piece] == DOVI_MAPPING_MMR) {
        return dovi_eval_mmr(mmr, piece, curve.order[piece], mmr_coef_shift, tt, ttf);
    }
    return dovi_eval_poly(curve, piece, t, shift);
}

/* ============================================================================
   Inverse NLQ
   ========================================================================= */

// The inverse linear-deadzone quantiser depends on the 10-bit EL code alone, so the composer evaluates it
// once per frame for all 1024 codes of each component (`DoviFelComposer.inverseNlq`, 5.4.3.2 line for line) and
// the kernels index that table: nlq_lut[component * 1024 + code], the spec's 16-bit signed r, Y then Cb then Cr.
static inline int dovi_inv_nlq(device const int* nlq_lut, uint component, int el_code) {
    return nlq_lut[component * 1024u + uint(clamp(el_code, 0, 1023))];
}

/* ============================================================================
   Reconstruction and output
   ========================================================================= */

// h = v + r (5.4.3.3), still at 16 bits: the spec rounds it once to hdr_bit_depth, and each writer below takes it
// from here, so no output is rounded twice.
//
// The spec's reconstructed sample, hdr_bit_depth bits: (h + 2^(15 - hdr_bit_depth)) >> (16 - hdr_bit_depth),
// clipped to [0, 2^hdr_bit_depth - 1].
static inline int dovi_reconstruct(int h, uint vdr_max) {
    uint bits = 32u - clz(vdr_max);
    return clamp((h + (1 << (15u - bits))) >> (16u - bits), 0, int(vdr_max));
}

// 16-bit sample: h itself, clamped to the video range (10-bit limits shifted left 6). A 10-bit code shifted
// left 6 and a 12-bit code shifted left 4 are both h's scale (black 64 << 6 = 256 << 4 = 4096), so sv22 carries
// the sum before the spec's rounding, from which its 12-bit sample is (h + 8) >> 4 exactly; P010's full-precision
// mode puts the same word in P010, whose low 6 bits CoreVideo calls padding.
static inline int dovi_full_precision(int h, int lo, int hi) {
    return clamp(h, lo << 6, hi << 6);
}

// h down to the 10-bit output plane, dithered or rounded, in one step from the 16-bit sum.
static inline int dovi_quantize(
    int h,
    uint dither_mode,
    float dither,
    int lo,
    int hi)
{
    float v = float(h) * (1.0f / 64.0f);
    // Both branches have mean 0.5, so enabling dither redistributes the rounding
    // error without moving the average level.
    float bias = (dither_mode == DOVI_DITHER_NONE) ? 0.5f : dither;
    return clamp(int(floor(v + bias)), lo, hi);
}

/* ============================================================================
   Enhancement layer upsampling
   ========================================================================= */

// EL upsampling: bilinear, from four explicit texel reads with exact weights.
//
// el_spatial_resampling_filter_flag advertises that the encoder used its own
// separable filter, whose taps the RPU does not carry, so no bit-exact inverse
// is available from the stream. Against the DoViBaker oracle on a fine-detail set (gratings, zone plate,
// band-limited noise) a 4-fetch Catmull-Rom bought about 0.7% of per-pixel error sd over bilinear, with chroma
// unchanged, for four times the EL reads.
//
// Not the hardware sampler: its bilinear weights are fixed point, so the interpolated code could land one
// off the exact value (the CPU model saw it), and rounding that with rint() sent every exact half to the
// even neighbour. A 2:1 EL interpolates at quarter weights, where halves are common (two texels 2 apart
// mod 4), so ties-to-even was a parity-dependent bias. Here the weights for a 2:1 or 1:1 EL are exact quarters,
// halves or zero, every product and sum of 10-bit codes at those weights is exact in float, and the caller
// rounds half up.

// One axis: the lower EL texel index and the fraction towards the next texel for base-layer sample n.
// `centre` 0.5 puts both grids' samples at their pixel centres (luma: n_el = (n + 1/2) * el / bl - 1/2);
// 0 co-sites the first samples (chroma: n_el = n * el / bl). For the 2:1 and 1:1 grids streams use,
// el / bl is 0.5 or 1, so every term is exact in float.
static inline int dovi_el_axis(uint n, float ratio, float centre, thread float &frac) {
    float u = (float(n) + centre) * ratio - centre;
    float i = floor(u);
    frac = u - i;
    return int(i);
}

// Bilinear EL luma code at base-layer pixel `site` of a `bl_size` plane, edges clamped. One gather fetches the
// 2x2 footprint: the point between the four texel centres selects it and sits half a texel from any footprint
// boundary. A gather measured cheaper here than four reads (UHD luma 0.41 ms against 0.45 ms on an M4 Pro).
static inline float dovi_upsample_el(texture2d<ushort, access::sample> tex, uint2 site,
                                     uint2 bl_size, uint2 el_size) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    float fx, fy;
    int x0 = dovi_el_axis(site.x, float(el_size.x) / float(bl_size.x), 0.5f, fx);
    int y0 = dovi_el_axis(site.y, float(el_size.y) / float(bl_size.y), 0.5f, fy);
    // Gather order: (x0, y1), (x1, y1), (x1, y0), (x0, y0).
    float4 c = float4(tex.gather(s, float2(float(x0 + 1), float(y0 + 1))) >> 6);
    float top = c.w * (1.0f - fx) + c.z * fx;
    float bot = c.x * (1.0f - fx) + c.y * fx;
    return top * (1.0f - fy) + bot * fy;
}

// Bilinear EL chroma codes (Cb, Cr) at base chroma sample `site`, co-sited, edges clamped. Four reads of the
// interleaved plane return both components each, which measured cheaper than a gather per component.
static inline float2 dovi_upsample_el_uv(texture2d<ushort, access::read> tex, uint2 site,
                                         uint2 bl_size, uint2 el_size) {
    float fx, fy;
    int x0 = dovi_el_axis(site.x, float(el_size.x) / float(bl_size.x), 0.0f, fx);
    int y0 = dovi_el_axis(site.y, float(el_size.y) / float(bl_size.y), 0.0f, fy);
    int xm = int(el_size.x) - 1, ym = int(el_size.y) - 1;
    uint xa = uint(clamp(x0, 0, xm)), xb = uint(clamp(x0 + 1, 0, xm));
    uint ya = uint(clamp(y0, 0, ym)), yb = uint(clamp(y0 + 1, 0, ym));
    float2 c00 = float2(tex.read(uint2(xa, ya)).rg >> 6);
    float2 c10 = float2(tex.read(uint2(xb, ya)).rg >> 6);
    float2 c01 = float2(tex.read(uint2(xa, yb)).rg >> 6);
    float2 c11 = float2(tex.read(uint2(xb, yb)).rg >> 6);
    float2 top = c00 * (1.0f - fx) + c10 * fx;
    float2 bot = c01 * (1.0f - fx) + c11 * fx;
    return top * (1.0f - fy) + bot * fy;
}

// Bilinear EL chroma codes (Cb, Cr) for row `site.y` of a 4:2:2 chroma plane (one chroma row per luma row),
// column `site.x`. The row sits at 4:2:0 chroma-row coordinate `row_coord` (site.y / 2 plus the siting offset,
// dovi_compose_chroma_422), and the EL is read at that coordinate through the same grid relation as
// dovi_upsample_el_uv (n_el = n * el / bl), so at a 4:2:0 site this is that function. For a 2:1 EL the vertical
// weights are eighths, still exact in float with the horizontal halves, and the caller rounds half up as before.
static inline float2 dovi_upsample_el_uv_422(texture2d<ushort, access::read> tex, uint2 site, float row_coord,
                                             uint2 bl_size, uint2 el_size) {
    float fx;
    int x0 = dovi_el_axis(site.x, float(el_size.x) / float(bl_size.x), 0.0f, fx);
    float v = row_coord * (float(el_size.y) / float(bl_size.y));
    float y0f = floor(v);
    float fy = v - y0f;
    int y0 = int(y0f);
    int xm = int(el_size.x) - 1, ym = int(el_size.y) - 1;
    uint xa = uint(clamp(x0, 0, xm)), xb = uint(clamp(x0 + 1, 0, xm));
    uint ya = uint(clamp(y0, 0, ym)), yb = uint(clamp(y0 + 1, 0, ym));
    float2 c00 = float2(tex.read(uint2(xa, ya)).rg >> 6);
    float2 c10 = float2(tex.read(uint2(xb, ya)).rg >> 6);
    float2 c01 = float2(tex.read(uint2(xa, yb)).rg >> 6);
    float2 c11 = float2(tex.read(uint2(xb, yb)).rg >> 6);
    float2 top = c00 * (1.0f - fx) + c10 * fx;
    float2 bot = c01 * (1.0f - fx) + c11 * fx;
    return top * (1.0f - fy) + bot * fy;
}

// Round half up: the interpolated EL code back to an integer code for the inverse NLQ.
static inline int dovi_el_code(float v) {
    return int(floor(v + 0.5f));
}

/* ============================================================================
   Composition kernels
   ========================================================================= */

// Luma: BL luma + reshaping curve + inverse-NLQ residual -> 10-bit P010 plane.
//
// bl_uv_tex is bound only because a luma curve may carry MMR pieces, which need
// all three components. No observed profile 7 stream has an MMR luma curve (libdovi
// would report it as mapping_idc = 1 for component 0), so the DOVI_FLAG_LUMA_MMR gate
// normally skips the fetch entirely. When it does fire, the chroma pair is taken
// nearest-neighbour from the 4:2:0 plane: the reshaping model is defined on 4:4:4
// input, and reconstructing chroma to full resolution here would cost a separate
// pass for a case that does not occur in practice.
// Whether the residual is added at luma column `x`: everywhere without a split, left of it with one.
static inline bool dovi_residual_at(constant struct DoviMetalParams &params, uint x) {
    return params.residual_split_x == 0u || x < params.residual_split_x;
}

kernel void dovi_compose_luma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::sample>      el_y_tex      [[texture(2)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant int*                          luma_lut      [[buffer(1)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
        return;
    }

    int bl_y = int(bl_y_tex.read(gid).r >> 6);

    int h;
    if ((params.flags & DOVI_FLAG_LUMA_MMR) == 0u) {
        h = luma_lut[bl_y];
    } else {
        uint shift = dovi_q20_shift(params.bl_max);
        ushort4 bl_uv = bl_uv_tex.read(uint2(gid.x >> 1, gid.y >> 1));
        uint t = uint(bl_y) << shift;
        uint tt[21];
        float ttf[21];
        uint order = dovi_mmr_order(params.poly_y, t, shift);
        if (order > 0u) {
            uint c0, c1, c2;
            dovi_mmr_inputs(params, t, uint(bl_uv.r >> 6) << shift, uint(bl_uv.g >> 6) << shift, shift, c0, c1, c2);
            dovi_mmr_terms(c0, c1, c2, order, tt, ttf);
        }
        h = dovi_eval_curve(params.poly_y, mmr_table, params.mmr_y.coef_shift, t, tt, ttf, shift);
    }

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u &&
        dovi_residual_at(params, gid.x) &&
        params.nlq_y.nlq_method == DOVI_NLQ_METHOD_LINEAR &&
        params.nlq_y.nlq_scale != 0) {
        // Centre-aligned: luma samples sit at pixel centres on both grids.
        float el = dovi_upsample_el(el_y_tex, gid, uint2(params.bl_width, params.bl_height),
                                    uint2(params.el_width, params.el_height));
        h += dovi_inv_nlq(nlq_lut, 0u, dovi_el_code(el));
    }

    if (params.residual_split_x != 0u && uint(abs(int(gid.x) - int(params.residual_split_x))) < 2u) {
        h = 0x8000;   // the split's divider, mid-grey in PQ
    }

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        out_y_tex.write(ushort4(ushort(dovi_reconstruct(h, params.vdr_max) << (16u - (32u - clz(params.vdr_max)))), 0, 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_y_tex.write(ushort4(ushort(dovi_full_precision(h, 64, 940)), 0, 0, 0), gid);
        return;
    }
    int out_y = dovi_quantize(h, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(0u, 0u)), 64, 940);
    out_y_tex.write(ushort4(ushort(out_y << 6), 0, 0, 0), gid);
}

// One composed chroma sample, at its 4:2:0 site. A 4:2:2 output plane has twice the rows,
// so the sample is written to both (vertical nearest-neighbour; the BL chroma is 4:2:0). The composer
// fills a 4:2:2 plane with dovi_compose_chroma_422 instead; this duplication is what that kernel replaced,
// kept so the tests can still produce it and compare.
static inline void dovi_write_chroma(texture2d<ushort, access::write> out_uv_tex, ushort4 uv,
                                     uint2 gid, uint flags) {
    if ((flags & DOVI_FLAG_CHROMA_422) != 0u) {
        out_uv_tex.write(uv, uint2(gid.x, 2u * gid.y));
        out_uv_tex.write(uv, uint2(gid.x, 2u * gid.y + 1u));
    } else {
        out_uv_tex.write(uv, gid);
    }
}

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
// reads the same three base-layer components.
kernel void dovi_compose_chroma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = params.bl_width / 2u;
    uint uv_height = params.bl_height / 2u;

    if (gid.x >= uv_width || gid.y >= uv_height) {
        return;
    }

    // Base-layer luma at the chroma site, for the cross-component terms: [1 2 1]
    // around the even column in each of the cell's two rows, then the rows
    // averaged, in integers, edges clamped. This is DoViBaker's reading, and
    // Dolby-encoded streams agree with it: on one with order-3 MMR chroma the
    // coded residual matches it at about half the error of the plain vertical
    // 2-tap this kernel used before.
    uint lx = min(gid.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = 0;
    for (uint r = 0u; r < 2u; ++r) {
        uint ly = min(gid.y * 2u + r, params.bl_height - 1u);
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
        bl_y += (row + 2) >> 2;
    }
    bl_y = (bl_y + 1) >> 1;

    ushort4 bl_uv = bl_uv_tex.read(gid);
    int bl_cb = int(bl_uv.r >> 6);
    int bl_cr = int(bl_uv.g >> 6);

    uint shift = dovi_q20_shift(params.bl_max);
    uint t0 = uint(bl_y) << shift, t1 = uint(bl_cb) << shift, t2 = uint(bl_cr) << shift;
    uint order = max(dovi_mmr_order(params.poly_cb, t1, shift), dovi_mmr_order(params.poly_cr, t2, shift));
    uint tt[21];
    float ttf[21];
    if (order > 0u) {
        uint c0, c1, c2;
        dovi_mmr_inputs(params, t0, t1, t2, shift, c0, c1, c2);
        dovi_mmr_terms(c0, c1, c2, order, tt, ttf);
    }
    int h_cb = dovi_eval_curve(params.poly_cb, mmr_table + DOVI_MMR_TABLE_COMPONENT_STRIDE, params.mmr_cb.coef_shift,
                               t1, tt, ttf, shift);
    int h_cr = dovi_eval_curve(params.poly_cr, mmr_table + 2 * DOVI_MMR_TABLE_COMPONENT_STRIDE, params.mmr_cr.coef_shift,
                               t2, tt, ttf, shift);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u && dovi_residual_at(params, gid.x * 2u)) {
        bool cb_active = (params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0);
        bool cr_active = (params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0);
        if (cb_active || cr_active) {
            // The enhancement chroma grid and the base chroma grid share their first sample rather than
            // their outer edge: base chroma sample n sits at EL chroma texel n * el / bl, and a
            // quarter-resolution EL gives the even samples exactly and the odd ones half way between two
            // texels. This is DoViBaker's phase (`upsampleChromaEven` copies, `upsampleChromaOdd`
            // interpolates at 0.5); a centre-aligned fetch puts every sample a quarter of an EL chroma
            // texel up and to the left. Same-resolution EL is unchanged. It is a relation between the two
            // chroma grids taken from DoViBaker, not a reading of the stream's chroma_sample_loc_type,
            // which this kernel never consults: it is what decimating top-left co-sited (type 2) chroma
            // from sample 0 gives, hence the "type 2" this comment used to claim, while the luma at the
            // chroma site above assumes chroma vertically between rows 2k and 2k + 1 (type 0).
            float2 el = dovi_upsample_el_uv(el_uv_tex, gid, uint2(uv_width, uv_height),
                                            uint2(params.el_width / 2u, params.el_height / 2u));
            if (cb_active) {
                h_cb += dovi_inv_nlq(nlq_lut, 1u, dovi_el_code(el.x));
            }
            if (cr_active) {
                h_cr += dovi_inv_nlq(nlq_lut, 2u, dovi_el_code(el.y));
            }
        }
    }

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        uint up = 16u - (32u - clz(params.vdr_max));
        dovi_write_chroma(out_uv_tex, ushort4(ushort(dovi_reconstruct(h_cb, params.vdr_max) << up),
                                              ushort(dovi_reconstruct(h_cr, params.vdr_max) << up), 0, 0), gid, params.flags);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        dovi_write_chroma(out_uv_tex, ushort4(ushort(dovi_full_precision(h_cb, 64, 960)),
                                              ushort(dovi_full_precision(h_cr, 64, 960)), 0, 0),
                          gid, params.flags);
        return;
    }
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);
    dovi_write_chroma(out_uv_tex, ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid, params.flags);
}

// Catmull-Rom (cubic B = 0, C = 0.5) taps for the base-layer chroma at a 4:2:2 row, over chroma rows i - 1 ... i + 2
// for a row at chroma-row coordinate i + t, by phase t in quarters. t = 0 is the chroma row itself, copied; 1/2 is
// (-1, 9, 9, -1) / 16. Every tap is n / 128, so a 10-bit code times a tap and the four-tap sum are exact in float.
constant float dovi_chroma_422_taps[4][4] = {
    {  0.0f,            1.0f,            0.0f,            0.0f           },
    { -9.0f / 128.0f, 111.0f / 128.0f,  29.0f / 128.0f,  -3.0f / 128.0f },
    { -8.0f / 128.0f,  72.0f / 128.0f,  72.0f / 128.0f,  -8.0f / 128.0f },
    { -3.0f / 128.0f,  29.0f / 128.0f, 111.0f / 128.0f,  -9.0f / 128.0f },
};

// The vertical offset, in quarter chroma rows, of 4:2:2 row 2k from chroma row k, by the base layer's siting
// (AVChromaLocation in params.bl_chroma_loc):
// - LEFT / CENTER (chroma_sample_loc_type 0 / 1): chroma between luma rows 2k and 2k + 1, so row 2k is 1/4 above
//   chroma row k and row 2k + 1 1/4 below: -1.
// - TOPLEFT / TOP (types 2 / 3, what UHD Blu-ray and BT.2020 HEVC commonly signal): chroma on row 2k, so row 2k
//   is chroma row k and row 2k + 1 half way to k + 1: 0.
// - BOTTOMLEFT / BOTTOM (types 4 / 5): chroma on row 2k + 1, so row 2k is half way between k - 1 and k: -2.
// - UNSPECIFIED: HEVC infers type 0 when the VUI carries no chroma_loc_info, so LEFT. FFmpeg's HEVC decoder
//   already writes LEFT into the codec parameters in that case, so UNSPECIFIED reaches here only from a stream
//   FFmpeg did not probe.
static inline int dovi_chroma_422_offset_q(uint loc) {
    switch (loc) {
        case 3u: case 4u: return 0;
        case 5u: case 6u: return -2;
        default: return -1;
    }
}

// Chroma for a 4:2:2 output plane (sv22), one thread per output sample: every row is composed at its own site
// instead of the 4:2:0 result being repeated on both rows. With sv22 the composer, not tvOS, does the 4:2:0 ->
// 4:2:2 conversion, and the reshaping is not linear in luma: under order-3 MMR chroma two rows with different
// luma predict different chroma, which a repeated 4:2:0 sample cannot show. So the base layer is brought to the
// row first and reshaped there (libplacebo's order: chroma upsampled, then reshaped), a deliberate quality choice
// that is not bit-exact with Dolby's 4:2:0 reference.
//
// Chroma is horizontally co-sited with the even luma column (types 0 / 2 / 4; neither chroma kernel models the
// half-column shift of 1 / 3 / 5); vertically it is sited from the stream (dovi_chroma_422_offset_q).
// - luma: [1 2 1] around the even column on this row only, in integers, edges clamped;
// - BL chroma: 4-tap Catmull-Rom over the chroma rows at the row's phase (dovi_chroma_422_taps), edge rows
//   clamped, clamped to [0, bl_max] and kept fractional for the curve (exact in its Q20 fixed point);
// - EL chroma: bilinear at the same row coordinate (dovi_upsample_el_uv_422), rounded half up, inverse NLQ.
//   The EL phase convention itself (base chroma row n at EL chroma row n * el / bl) is kept; the siting only
//   moves where between the base chroma rows the output row sits, and the residual is read where the base
//   chroma it corrects is, so at a 4:2:0 site every siting reads what dovi_compose_chroma reads;
// then prediction, residual and output exactly as in dovi_compose_chroma.
// A separate kernel rather than a branch in dovi_compose_chroma, so the 4:2:0 kernel the P010 modes run is
// untouched. It is built without the blue-noise specialisation, which sv22 (full precision) never uses.
kernel void dovi_compose_chroma_422(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = params.bl_width / 2u;
    uint uv_height = params.bl_height / 2u;

    if (gid.x >= uv_width || gid.y >= params.bl_height) {
        return;
    }

    uint lx = min(gid.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = (int(bl_y_tex.read(uint2(lxl, gid.y)).r >> 6)
              + 2 * int(bl_y_tex.read(uint2(lx, gid.y)).r >> 6)
              + int(bl_y_tex.read(uint2(lxr, gid.y)).r >> 6) + 2) >> 2;

    // The row's chroma-row coordinate in quarters, q = 2 * row + offset (>= -2): whole part q / 4, phase q % 4.
    int q = 2 * int(gid.y) + dovi_chroma_422_offset_q(params.bl_chroma_loc) + 8;
    int first = q / 4 - 2 - 1;
    int phase = q & 3;
    int last_row = int(uv_height) - 1;
    float2 bl_uv = float2(0.0f);
    for (int i = 0; i < 4; ++i) {
        uint row = uint(clamp(first + i, 0, last_row));
        bl_uv = fma(float2(bl_uv_tex.read(uint2(gid.x, row)).rg >> 6), dovi_chroma_422_taps[phase][i], bl_uv);
    }
    bl_uv = clamp(bl_uv, 0.0f, float(params.bl_max));

    // The interpolated chroma is a multiple of 1/128 of a code, so its Q20 value is exact.
    uint shift = dovi_q20_shift(params.bl_max);
    float q20 = float(1u << shift);
    uint t0 = uint(bl_y) << shift, t1 = uint(rint(bl_uv.x * q20)), t2 = uint(rint(bl_uv.y * q20));
    uint order = max(dovi_mmr_order(params.poly_cb, t1, shift), dovi_mmr_order(params.poly_cr, t2, shift));
    uint tt[21];
    float ttf[21];
    if (order > 0u) {
        uint c0, c1, c2;
        dovi_mmr_inputs(params, t0, t1, t2, shift, c0, c1, c2);
        dovi_mmr_terms(c0, c1, c2, order, tt, ttf);
    }
    int h_cb = dovi_eval_curve(params.poly_cb, mmr_table + DOVI_MMR_TABLE_COMPONENT_STRIDE, params.mmr_cb.coef_shift,
                               t1, tt, ttf, shift);
    int h_cr = dovi_eval_curve(params.poly_cr, mmr_table + 2 * DOVI_MMR_TABLE_COMPONENT_STRIDE, params.mmr_cr.coef_shift,
                               t2, tt, ttf, shift);

    if ((params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u && dovi_residual_at(params, gid.x * 2u)) {
        bool cb_active = (params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0);
        bool cr_active = (params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0);
        if (cb_active || cr_active) {
            float2 el = dovi_upsample_el_uv_422(el_uv_tex, gid, float(q - 8) * 0.25f, uint2(uv_width, uv_height),
                                                uint2(params.el_width / 2u, params.el_height / 2u));
            if (cb_active) {
                h_cb += dovi_inv_nlq(nlq_lut, 1u, dovi_el_code(el.x));
            }
            if (cr_active) {
                h_cr += dovi_inv_nlq(nlq_lut, 2u, dovi_el_code(el.y));
            }
        }
    }

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        uint up = 16u - (32u - clz(params.vdr_max));
        out_uv_tex.write(ushort4(ushort(dovi_reconstruct(h_cb, params.vdr_max) << up),
                                 ushort(dovi_reconstruct(h_cr, params.vdr_max) << up), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(h_cb, 64, 960)),
                                 ushort(dovi_full_precision(h_cr, 64, 960)), 0, 0), gid);
        return;
    }
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);
    out_uv_tex.write(ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid);
}

/* ============================================================================
   Layout probe
   ========================================================================= */

// Reads sentinels back out of the parameter block the host actually uploaded,
// so the Swift serialiser and this shader's struct definitions are checked
// against each other on the GPU rather than by hand. Metal has no static_assert
// and the offline metal compiler is not always installed, so slot 0 carries
// sizeof(DoviMetalParams), slots 1-35 the scalars and the last element of each
// sub-block, slots 36-95, per component, the first element of every array and every
// NLQ scalar, and slot 96 bl_chroma_loc: any offset drift or swapped neighbours
// moves a sentinel and the test fails.
kernel void dovi_layout_probe(
    constant struct DoviMetalParams& params [[buffer(0)]],
    device uint*                     out    [[buffer(1)]],
    uint                             tid    [[thread_position_in_grid]])
{
    if (tid != 0u) {
        return;
    }

    out[0] = uint(sizeof(struct DoviMetalParams));

    out[1] = params.bl_width;
    out[2] = params.bl_height;
    out[3] = params.el_width;
    out[4] = params.el_height;
    out[5] = params.target_mode;
    out[6] = params.dither_mode;
    out[7] = params.frame_index;
    out[8] = params.flags;

    out[9]  = params.poly_y.num_pivots;
    out[10] = params.poly_y.pivots[8];
    out[11] = params.poly_y.method[7];
    out[12] = params.poly_y.order[7];
    out[13] = uint(params.poly_y.coef[7][2]);
    out[14] = params.poly_y.coef_shift[7];
    out[15] = uint(params.mmr_y.mmr_constant[7]);
    out[16] = uint(params.mmr_y.coef[7][20]);
    out[17] = params.mmr_y.coef_shift;
    out[18] = uint(params.nlq_y.vdr_in_max);
    out[19] = params.nlq_y.nlq_pivots[1];

    out[20] = params.poly_cb.num_pivots;
    out[21] = params.poly_cb.coef_shift[7];
    out[22] = uint(params.mmr_cb.coef[7][20]);
    out[23] = params.mmr_cb.coef_shift;
    out[24] = params.nlq_cb.nlq_pivots[1];

    out[25] = params.poly_cr.num_pivots;
    out[26] = params.poly_cr.coef_shift[7];
    out[27] = uint(params.mmr_cr.coef[7][20]);
    out[28] = params.mmr_cr.coef_shift;
    out[29] = params.nlq_cr.nlq_pivots[1];

    out[30] = params.min_pq;
    out[31] = params.max_pq;
    out[32] = params.avg_pq;
    out[33] = params.bl_max;
    out[34] = params.vdr_max;
    out[35] = params.vdr_scale;

    // --- y: first element of every array and every NLQ scalar ---
    out[36] = params.poly_y.pivots[0];
    out[37] = params.poly_y.pivots[1];
    out[38] = params.poly_y.method[0];
    out[39] = params.poly_y.order[0];
    out[40] = uint(params.poly_y.coef[0][0]);
    out[41] = uint(params.poly_y.coef[0][1]);
    out[42] = uint(params.poly_y.coef[1][0]);
    out[43] = params.poly_y.coef_shift[0];
    out[44] = uint(params.mmr_y.mmr_constant[0]);
    out[45] = uint(params.mmr_y.coef[0][0]);
    out[46] = uint(params.mmr_y.coef[0][1]);
    out[47] = uint(params.mmr_y.coef[1][0]);
    out[48] = params.nlq_y.nlq_method;
    out[49] = uint(params.nlq_y.nlq_offset);
    out[50] = uint(params.nlq_y.nlq_scale);
    out[51] = uint(params.nlq_y.nlq_threshold);
    out[52] = params.nlq_y.nlq_shift;
    out[53] = uint(params.nlq_y.vdr_in_max);
    out[54] = params.nlq_y.nlq_pivots[0];
    out[55] = params.nlq_y.nlq_pivots[1];
    // --- cb: first element of every array and every NLQ scalar ---
    out[56] = params.poly_cb.pivots[0];
    out[57] = params.poly_cb.pivots[1];
    out[58] = params.poly_cb.method[0];
    out[59] = params.poly_cb.order[0];
    out[60] = uint(params.poly_cb.coef[0][0]);
    out[61] = uint(params.poly_cb.coef[0][1]);
    out[62] = uint(params.poly_cb.coef[1][0]);
    out[63] = params.poly_cb.coef_shift[0];
    out[64] = uint(params.mmr_cb.mmr_constant[0]);
    out[65] = uint(params.mmr_cb.coef[0][0]);
    out[66] = uint(params.mmr_cb.coef[0][1]);
    out[67] = uint(params.mmr_cb.coef[1][0]);
    out[68] = params.nlq_cb.nlq_method;
    out[69] = uint(params.nlq_cb.nlq_offset);
    out[70] = uint(params.nlq_cb.nlq_scale);
    out[71] = uint(params.nlq_cb.nlq_threshold);
    out[72] = params.nlq_cb.nlq_shift;
    out[73] = uint(params.nlq_cb.vdr_in_max);
    out[74] = params.nlq_cb.nlq_pivots[0];
    out[75] = params.nlq_cb.nlq_pivots[1];
    // --- cr: first element of every array and every NLQ scalar ---
    out[76] = params.poly_cr.pivots[0];
    out[77] = params.poly_cr.pivots[1];
    out[78] = params.poly_cr.method[0];
    out[79] = params.poly_cr.order[0];
    out[80] = uint(params.poly_cr.coef[0][0]);
    out[81] = uint(params.poly_cr.coef[0][1]);
    out[82] = uint(params.poly_cr.coef[1][0]);
    out[83] = params.poly_cr.coef_shift[0];
    out[84] = uint(params.mmr_cr.mmr_constant[0]);
    out[85] = uint(params.mmr_cr.coef[0][0]);
    out[86] = uint(params.mmr_cr.coef[0][1]);
    out[87] = uint(params.mmr_cr.coef[1][0]);
    out[88] = params.nlq_cr.nlq_method;
    out[89] = uint(params.nlq_cr.nlq_offset);
    out[90] = uint(params.nlq_cr.nlq_scale);
    out[91] = uint(params.nlq_cr.nlq_threshold);
    out[92] = params.nlq_cr.nlq_shift;
    out[93] = uint(params.nlq_cr.vdr_in_max);
    out[94] = params.nlq_cr.nlq_pivots[0];
    out[95] = params.nlq_cr.nlq_pivots[1];

    out[96] = params.bl_chroma_loc;
    out[97] = params.residual_split_x;
}
"""

    /// The 64 x 64 blue-noise rank map behind ``DoviDither/blueNoise``, one row per string, three hex digits
    /// per cell: every rank 0...4095 exactly once. Void-and-cluster (Ulichney 1993) on a torus, Gaussian
    /// sigma 1.5, initial pattern 10% of the cells from a seeded generator (20261019), so it is fixed and
    /// tiles seamlessly. Its spectrum below 1/8 cycle per pixel holds 1.4e-5 of the energy, where white noise
    /// would hold 0.047. `DoviDitherTests` checks the permutation and the flatness of local means.
    static let blueNoiseRows: [String] = [
        "36ecf6103fa277d0114cdf3e9cae8aacdd5dfd6a7670407e9bf2ebb2a7924f1b8d6a2e24ad7773cad4b5fa15f4d4194fedebee2b25db46abb8535da9c5e0f7cee755e7cb686b4c578b0cde7e2fe9120778332c367e4cc14ff9b32948981797c0",
        "e6c5abb7546fa53df8b537030db5712c98a21933fae9350abaa6641b1a25ff723bce056030f07f93f180a803e40a47f1352a42724913e3132e73719d8836a9fa8905002363db2205f2e06d9a328fbbad856459dd0eaaa51c5f66d5962bb3c4ec",
        "05782edd22ec6711cf8fc330d29ba2796c8d5e7957d18295810cbcdfe5cd36a99b0d0862f70688b89e4d742dbdb4b215542de80ecce11fda19f8eafa3a6b8a28447560fa167c8505ac16093f7e5752c9301e0fa0459df15eb80b0943fcee8c3e",
        "689aa915a96aefac5558ffc282d481157f22344b6777011df8148606087dc796dbea6a9c4c4d6a37d57028a8d761cf86c2488d457ae567481f06f605eaa5519b8e0bc4df64133bc72dbddfa5770609db4539bbda7178fe362bf6ac67302b090a",
        "f463cdd515138063f906aa3a232e5ca726ed01bdea57dad996b32faa1eef17e456bc22b7135a158adf1d010ccc4339e6147650f2a368e7d4cbd358e51eed7009872f217874431ecd7388921c8bf2f418005e5e49043cf5248ecf532dcda4f1bc",
        "591791bcd25cb1bea3748cfa65f95a383bfe88b45c1dfeae61ec4173554697bdb17de5e4cd47281febe67d7a99ea52d8790d540968ddc06198b78430a737d5c0938fb065bbd109af03d534d3831d49f9ed2658824eea346c897119286a4a7c88",
        "984086ff869c10593b325b9c5040abd7e593fb19a1cfd2c78d10ebd8422cb4d39003991bfcd45fdf264f35a5211a792fba64c2a942715a8744f4d2fb6a0fde4e0958ea20e733b678b6de7591e686cb40ccee0d2eb221b0fdf3e8d0801aeb22dd",
        "e3285138d9f3cac5d1dce1d7f6c771ac027c11a6a6b3279e4ccfc940784bf4c6c5e58c30312a950b199ef91c926fede037ffe06cfcb3e19a41049949cab121274d806eb8b7fbbc6d26a435106fa67bda9f43e72334b63cc187d25a2b74716a96",
        "201d0f541e052af7f546ba7e8c03cfea9845c31349e7f055ca4a1bb816070ffab35241c68605b3ba129f815108ada5da0418271d59553514a37e6e82540aec652ba3451207a824f780d9c8b3158e2b4c341dc966e810a1db92a99d5f6b3b463e",
        "47ab2c753156ad2f3a02067dca70f55eed1f47fa4356c94366b19f313ce594d2cad749e970aef8d0b50ddc73f88ccbffe9ea35576eea110b2bd9321137a899edf0239dede975d087ccaebc191d468d9646f5850ebd1863a4a4c61cd8b60fbc6b",
        "94109bef58df501c2b962e5b2bcb489381bd72af76239d4d3dcf047fa4fce89754448bf905d3ce1eb9446a3f351e24f32ced4b404b9789b7025b4c05a29712cd22f85ddc0b3ccf2c5ea70c3454cee16013a187ad14b3db602e51bbbd48779e80",
        "2c35f1be93156dc1f23d778552afda42dddcbc60a3837b947109f8d88008bb7159f905e6df4a8579fb60097a5dc9e79d970126632ce72b1fad3fb0bcf1817349780cf8c8ef183aef23e976aca7ddb883f6c972f5d67fb6ae404a6b335e50fa7b",
        "846def455a14fa3cd0b04db6195a0a7f82df618999498e710d929a5928c83eb9cb7cb2a68cd4d8ffd2d9d8d5c835de596adf8fa5f7b400d9ccd1d8ed637d76998b580b9528dbc78f3fde5f0e2ff92526d6e9959999270026b891ed09a2224fd1",
        "6e218fd090567f35690d28ba658c10042ef6acfd9b33d5e8addfe7bf06ddee4b1819acf8b9d0e5633c3548a84d9e1058b5c3a5216e0d4babbf6c3204b1e3aa235e1f6b73469aacf1b9e4e9c945b8920a6f0aa884197c6448cced597b030c4c40",
        "395b5a8ce697e7b2ad9bdf11369d8259d45089f12ac217c29163b01a5d442fa56de08694381a07e2b906160f60269da74b08e3c8a5cb879300e9051f830fec5aa7cdc33ebf1f75f902f8d472b151daf47ec29f6f378a3eef313e3c3763d6f537",
        "a4df4e24a4a5ae8c493fe7471ccade7a0cd12706e9f3818addd4cfa748250c5978463872f2122977b3cbaea726bc55f67dbead0f1a9df7317ba3bd55050c61a0b14d43aabe83af97324a5ee963c1b352927b0547b546577c791abcff6e2ae817",
        "10f5bad7d95d161608e39a4951af8d10a946e94a7d561306c836b2e925ccc56fabac2089c235b2d50016e5d4fecfc171a2a2cb698418c5977a39291048f705320d8793c08c509d72681bed1c482bf1766ad3d1e5e210702d4e645f3015994e3f",
        "466793bbc34efe881901cd5b870314bbd61d3be08eba999780e03e2899213d1743259dcb7dc441b6c9db666308927426fd9ba7d96980074581b62f3913ae45bc1543f63734b4a21f95e452cc65de9bb0bfa5b85344d9add054e5ac438468fc7a",
        "908e8306c6f3ce94efb5124567fe65485a1adf0783fb745ed37ab8f61b9f109ce359e36b98313cfb58881f5f02ad50636e651c2087efeddd1526367baa38031c38af296c8f3d4ed87ce0a0fb32624c9e02339c07f3f74fb991508a3ddeb551d2",
        "2f3ae040fa471e3996380c739180a6cba1d18bf2aa6721375df35971f530e3b85fa8bf45bc06e832654cc16767d2c84aded937377b0e62c44f8c9dbe4f0360b0be856a7a231015efd58a696ecb218e6c6c6de56f102301624fe52577c950bf5f",
        "5f2d4e84ef08623dc57ac59bfb4ab96f254dd3faadc20eca909dc017c9d942a1f86ae0404dcd03a45e9b0dd4992b659a1a2c7bf3c1299d71e1c150459cff5a604136454dcf832bae2be526e2e3ac004f6920c8b8ad3dac91446ea7fcbd08d761",
        "c140e35152abbf1088ec018843d2c4826f523c90127df42b226b7381af0cb3ad4a92beac2a88491b2627d9f9d0bd9f84a6847472cbe2e527ccfd46d429d7b3d3cba097d25bfe64929d4128896bd47a84659f2eb5403c7403be4a6c2396ebb9da",
        "279f9593274ea7747c897b5b9aee07bea177963e345829f9c7c6403ba05b60e2f2517c2e760e2db5f8f93897a708568e32d88a02d5af40c2d3565b1ac9941d0a25597e0cf203071bcb6f326252ead7b5becc312d76a5a38049e71c1b508bd443",
        "70bb701b7e8dcc42ef5f8d5a71d06e63b4e8b7e7222c1ffa0d4e98982cff782fc40e69c33d21274b7ff0218b12ec191dcd5e6eadbd9a8f2a71df5162924e46a65f1e36f635af190c3bc1f3a24eba0f6af2835367ba5220f79328d3353b10ddd5",
        "5c2a0e3c557c118987f141db3b7c6787fece1f9d60af689d50c75727f4a1a9a8bbb92db5670a87cb272d55dd364011425292826731e7c6e0a78314ae63425485c1b4c02e222e453ddb0808c5050895b249fd5690d6b8dc4bdc0a656f447e5c4a",
        "005e1e889d2a6f7bb3807503abcf9e302a3841c66f13d3eada2a1fbfcdf915839157e255834f423220b6a1e84f64ac13a4b7ebfc03e7751f34348cceee6b396e449e94576c144f7bb630816ab35f75ae204b2a13068ec8a8f13892d253acc355",
        "ffb4ea241a8ef7436c036e538f45c00dad047d89b2f00c8c1f167607b852f1b6fbc89eb40065c6961c32ef717de14309ed50cebd09914f8b5669d95000b3b9c66f9d077a6acae60099f473f48aaeceb0b3b912fd5dc7b23ad70fe40477cf069e",
        "9b07d4c650d6488677a3cca126777fbd74c5e47059594828ba4f943475e0ae91da9ec4abb25d5f3f27ba2754d6aed7099425962d6deb111d451f4ab25a7e019e426e522e953e31cb7cf2a0d8918184461f8f6de1c3f16dd26b3605aa2e85e1a3",
        "b7c3105cae03926d73196707410d9593621eb573a1ab129b71e4de9accdd445dab7ca31a8e01bfe72628b9a89cd9d0243f4d1486c621a1c7be30cff286d1727c1654d9088f6e5c1aed6b1f8e954a334f932004279dc833fc34c861bf313bfd8b",
        "0b4f07a5478e286bdf52dfb8b0a104f13603741fce8e7dfc0a9b16ebe2648f1064fdc5adc7271ca3307cfc13945c1a09f80b241ddf29421e4e554b82446cf7350bfdaf51552f4a014a60186f6c9d9ffb61769e9158c1d3317923bd324374c54e",
        "9526be424167f538503409a97e757b373a30d1917f51ec5d3ec865154752c3a65cb96114df62c0518cdc94e1b9ca87d11394d0756bac0478c4c820cd67c903f590af46297afaeccf651ddb3d0f1c10b4dad24034b02c7d6d9e1712c88ce6fc51",
        "222e25b30cb958bab4071db422de84c4b00c8733046d19c1f565f5d4f4fde7738e9b4460aa4869eb83ff6c7b102b8e69675977cb8366a756d828b9f0ea8223a595fbe447a355a0e187a233ac77b62d290b66738b8b1f0943fa64d0a4e7aa737b",
        "5d98a802575c3b3e766c6484b8c6929044c1eabb87dd90df277be79792f0ad11af7f2f475ce16cb8f0e0823dfb4ada863a7eed25edaa584f8ad204b676edb83f0857c9c1d8b3b39ae86c089595aee09bcaf75a4426f5f009a7c42d767908bf20",
        "c2a4b4d8e98b23fbbe8a1a2613bd642acaaa6433e2818abd4797a2026fa78a66bbcbf27bd94736973f6d568c62051877c0e0b56268f01313d683f176c0c5a602eb9b2c8683ef19e36fa49b0adcf91e844e0c7725d53b26dca9b5f5db93925774",
        "ae12daed1622d06100fd35c73d5ee98010d5f6a1adcaf5acea4d7867ab59419e1506ba513e1c26203382a4c28069afe3555a0d781e60c3d9c2b4cf0633caa0911fd04f9d668db145d1e30aff173aafb893e704f682916f40959f1ea3b2d3e19b",
        "411824164a7c4257fc2ffcb576db05572c1199a74a2e98fb15da2f29855e16abce5fa90152be7465ad2b79be5a95f1a6d3031eb854442346fd09262e7f4d7f18d6ffa370c343c5d6ad082c5279f62e2620b83212c84fca93dbe0e4271a545fe4",
        "ca665e90ef6754fb27e0c03298d1d9370d424a4e06b64ff6400838c45f0d9817d9f822f7afe0bb8a7b6510e3e6b377f9493efd0fa81bfbcd574ede4c24d495c25398e547f0c19f621aae12c7004df25d253a99bc5d732a6d50f2880a9b03f97e",
        "23ddfd082c2726c6bd9024e6bc3f966d78d2281038695536d2308f74034dd074941b8d657afef42724aaf98606d832a7c6a685a7856492e2e7adf8789eef4b65b8d5221b0f35473d91c29c6654288de14e766eec007aafd5c4a9c78316e8c7a1",
        "5759d13b8784d97175f0f333601d910baa81f0381ead620f933edab076100dea8c6d2c124345d8964c8b762a0200a58398e16be2acd70376c0c4c3de14cb4409ed1657ff05014cc24a8a06bdd7bcdf3a794a0bf78d6e4b7a624cf7264143bbb5",
        "0fef27b3f4aca3d81cc77a6b20e7ee438c5356ad793c7c856ef4b8244dbf8c7e6b2939d6044dd3aba17830ddee855ec7b7973c2fe415a20f241cad40720507e3c9ab788458a6c60ce8e125fac1fa586cd32d06681893b556eb6b965152a3fd4c",
        "8856b12c6e1d5d006642e682ed3b6e99330374b11ca00e3d0f3bde9b141b7a4b8e531fd287c37c6b9f3b53fb193ae202471f4f8aebd67a54bc61996cffe8473361a1ca528d8f7d7c31c70dad839f98f08af8583dc9fa36efe0ac820dda74927e",
        "4f2cb19511a0c43fef9c9d020ef519df7184fc88e861a28c866faa5c900ff2835616e691cd920dc1c8e2093d1271190dcbe5c50f4dad242e35b2e2fc052c1d5edaf9f926aabd50dc821506c9388ee796eaafc510dd7206631c60323512b52fbd",
        "a0504bed77b93718c61ff76f3ab8d06b0ce4490b76ea7502af333acc7a706fcc4f8fab09469e737c54129e8616feb0c9a602b5ae365d98611985deaf48e9ebde33ee876187538e26b14f190a562f22ec2d3dd10c96d75e41a9fbea16ce185387",
        "bfb615453b0866cbc4544e63a28f68266a7a7d635c04ec5868b7d3148e2f237574da3075a045e9107b7de561e6be34e1dc67edf89487cec3755a5c696d321b7970bda61eb7365972213417a0cda64e29c67ffef032bb7fff384c02bcf3929e0e",
        "25d864d31278f2b09fd8a2b9b470195c4c3c1539c0d758b31d4ec948d8599ea3f3edc7f6318f26d1c2c252387b3359746b83d8029bec721f109ce182da8b4ef154c3cd8701c5c5d27b7d326e1337fb903cd17590c8616853c283b2f3e0595764",
        "af0eb1124a564f58409956f849c809d6842ff3064c4b1f993b699dbf45f7d11112718bab4db8da6a8ac5777cc5ee512bb95e619fa2858a00b2b0040b81d3119565fc23a900065a9ef78115c008aab3375828ea846ca8b5d27e2378799cf870c0",
        "43257994b727dc4358ccb186bcbec69542f1794bb1260ab7714dba06130bfe1a90297ccd1c7a48163f9b03a3c0a3953e25a8225b9d924d1e1063afb255801dd56b98fd7468d992f94d59a5273552194dd445aeb90d8a1244c64b11bc1f2bdd1b",
        "805c5f2edf771bbb205b0fcc3bd6620eda62e6a079836cdb14155cb239356cd47b8c1f3d661e04437c48931649d6274dfbac7e166b4631b9751f0c3b8eca9767e3b111f765b1d86be1a696ce2efba31653842be13a0f83214ac3ee34d26c49f4",
        "f1a009699bb9423802073a118a424bcd66f44ebd6e5a99f7374f557e31d6c4edd6021533aff2e07e8550e7e27ab170d39a740869ff377dad0e6f135bebd190e0a8419d2e9a5b71a4bad0034227ab357c9b0699885ff7a9c9a90f338858dbb1e4",
        "393a50d815399e2ed26e0decbf854be9fb401c28ca2e6e2c6a1c01449e4f5e23619f178cc870f9985b7a18b881491de42e58c2a9805e548a550c1b7b4a278a2b3c5a51b276cbb3c6733ec3948b3e146fdb4e3e682ccda50fc58abdb084b2960a",
        "e3a7992318bc13fce82d547013278d34396945bff5ace11e8eb256a220c6894b4f219e9d38afb06bad6c3e5f656dfbe858de7acb7288e283bbf8b856d345e3b43f7104fa888d3fa5a0f56621ade5613a0889a1abb69a66416eb3732faf46d8f5",
        "adc4b9fe2c753c464eb2d8f3d39a4ef50027c4262977ec904faea073bc76f9a4cacfe60b8b94bba2c07a617c549e001e82f1a94807aabef8ff655225a2d0e996040e6eeda46120be30ed6d890496c1e321731c7f55b6f58c51dea272a5d0012e",
        "2e8687091afd812f2f048e555d4227684868dc91fb38cf0a067b0d3c863d2cf7b1080ad4174c222bbe368a520b34aed9ab5693fee9d85bf165dc3440f12329e29816230bb647680ac2ca91113789f510a8d9e3caf7d099e48c3964787e553be4",
        "ee7967d9c5622999b64d37c3379c91b0c3f5556bb2a178485d3940d8c1709fde27928d696e7f017aeb1347dd4375f500d863a8b800cb341c98ab0795c1b69b525cea9e5ee21b6e136d0405ecb2c593ab285eca4024f96e4fb307da1033e1b745",
        "18eaa2413772ba8dfa1d0ac9fcb0f88e4ee10b06c9dff2decb021d7d0efcbd23af5632684069905891aefc7968b7712f91524686fd63746f5751400e9391ecb1c0833975b1af494c236d0164dbcc5201ce839e8f75bcfbb157bf447a8391f3da",
        "cf483b22bf7f0fd68dc5291258773e27dd139c47ea14a4b3fc5b5e44b5a00ca713feab6add802ac8e37e6da0905b6f54c2f639e8b40aa322288be3a4d5ee8770ef7c8ee78b0e4ff455789e0549a8dc1353c9602840d60d123fffc0f1c9f33630",
        "07de305e1c818b44892e1dae420e66bc94dd34cf40c37a636af0019bad1a8b2a931b585b611a587ece11ac8d0c3f17b819ea8a4f405fc5b68ceb0bd85bd9fe4822a4ca0dd1442beb33fabff1641f719fc656bb909a6ed426d9476c153a2f6b6f",
        "9b74e4aeb364a10f0e7fe0b8a6e1b383e663af720a5788d832ce9773922ae18327c684be134f432dc51686e25f9d3e5e319d2882afa957a9a01167c62ee0ae854aa86482099c76e3d981c079cc380eea2b8a92cddb37e1ae63a2e3e895cc07bb",
        "fbe19c708e88035598b49cda62a97ff88031d8f780e38117d3baee3e9bf351d680eee9efd216f9b710c8edb66db414c78fd6ac14fb5d2e3de7472af8fd8c63e4115fbaf549ecc09587159ce372a263fd491ed6f04c00d15b5d3a062a6715c467",
        "331c04934290d0d77c2383dfe4329e478c9592239ca1d46c6388750e8fa495c0767fd41e1e992c39ec7197c1bed52017c03eff3ed92a72ebfa21c66093e52f7503eff5e8cf372b72caa464a6d8c3b4249deb6bdca03f9fc447594d9f4a642d2f",
        "775e005feb8b45d9dffed8cbbb476baac5d51ba6bcf9cbe5250ec54d4776b66dc82a3c0de6d567fcf7b54615bcf7e768291585ae2da00cff5b861d4717a342a5acdf6a5122a4673f24ef3601f3c2f7a14380f38618c86733e1fc9a4bc82408e1",
        "04c511149814ec41996bf09c52e15ef2331fe50b340c279898ccc9abb2103885c3a5c6cc887046a52251ce6acb3858aba21e1c1ef66e37655fa89402b84de20729192badcc49ad2d5fd953786bf55cf9cd6b6ca2e0f614b3dec28113d9e33aab",
        "c6ff0bb01399d77588aa6cc8dd0907c287f79b94d7db736d5801306b5917c80f49140d61483bb062dde60d7715e78169ca344a8139becef79a02cef26367fbf2d5a1c177e9fbf0b7b11e671acd222d1dc2078ab643994a000d7a5a40f06cb48b",
        "2588ac65998a287c4785a3a322f68a42c053644261c46886f5cd71429e620228433d396f1f6ef934f83c9c52a1b864df6a405cffcb3815be9c8f82bf9f54af247a924141a8989573305436669a8d4bf8eaeeb57723cf1f72939dae7ca9fdd9fc",
    ]

    /// ``blueNoiseRows`` as the Metal table the kernels index.
    static let blueNoiseTable: String = {
        var values: [String] = []
        values.reserveCapacity(4096)
        for row in blueNoiseRows {
            var i = row.startIndex
            while i < row.endIndex {
                let j = row.index(i, offsetBy: 3)
                values.append(String(UInt16(row[i..<j], radix: 16)!))
                i = j
            }
        }
        return "constant ushort dovi_blue_noise_64[4096] = {\n" + values.joined(separator: ",") + "\n};\n"
    }()

    /// Runtime-compiled form: typedefs, struct block, the blue-noise table and kernels in one string.
    static var source: String {
        preamble + "\n" + sharedStructs + "\n" + blueNoiseTable + "\n" + kernels + "\n"
    }
}
#endif
