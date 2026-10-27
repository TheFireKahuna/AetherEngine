#include <metal_stdlib>
using namespace metal;

typedef uint dovi_u32;
typedef int  dovi_i32;
/* DOVI_SHARED_STRUCTS_BEGIN */
/* ---- Target output modes (unread: no kernel switches on them; the output's range is the RPU's own,
   carried by the output buffer's format) ---- */
#define DOVI_TARGET_MODE_PROFILE_8_1  0 /* Rec.2020 YCbCr PQ 10-bit limited range */
#define DOVI_TARGET_MODE_PROFILE_5    1 /* Dolby IPTPQc2 10-bit full range */

/* ---- Dither modes ---- */
#define DOVI_DITHER_NONE              0 /* round to nearest */
#define DOVI_DITHER_BAYER_8X8         1 /* ordered dither, inverted on odd frames */
#define DOVI_DITHER_FULL_PRECISION    3 /* keep the VDR bits below the 10-bit code in P010's low 6 bits */
#define DOVI_DEBUG_RAW_VDR            2 /* test only: write the un-quantised VDR code << 4 (12-bit in 16) */
#define DOVI_DITHER_BLUE_NOISE        4 /* static 64x64 blue-noise threshold map, no per-frame change */

/* ---- nlq_method_idc. Anything other than LINEAR yields no
   residual rather than a wrong inverse, degrading to base-layer output. ---- */
#define DOVI_NLQ_METHOD_LINEAR        0
#define DOVI_NLQ_METHOD_NONE          0xFFFFFFFFu

/* ---- mapping_idc, per reshaping piece ---- */
#define DOVI_MAPPING_POLYNOMIAL       0
#define DOVI_MAPPING_MMR              1

/* ---- per-frame MMR table (buffer 3): [Y, Cb, Cr][piece 0..8][24 coefficients] as int. Coefficient (power - 1) * 8
        + subset is the one against the product of `subset`'s inputs (bit 0 s0, bit 1 s1, bit 2 s2) raised to power
        1, 2 or 3; the empty subset's product is 1.0, so slot 0 is the constant and slots 8 and 16 are zero. Piece 8 of
        each component is all zeros, and a piece's coefficients above its order are zero: every sample sums all 24
        against some piece. ---- */
#define DOVI_MMR_TABLE_PIECE_STRIDE      24
#define DOVI_MMR_TABLE_PIECES            9
#define DOVI_MMR_ZERO_PIECE              8
#define DOVI_MMR_TABLE_COMPONENT_STRIDE  (DOVI_MMR_TABLE_PIECES * DOVI_MMR_TABLE_PIECE_STRIDE)

/* ---- flags ---- */
#define DOVI_FLAG_DISABLE_RESIDUAL    0x1u /* disable_residual_flag, or el_type == MEL */
#define DOVI_FLAG_CHROMA_422          0x4u /* sv22: dovi_compose_chroma writes its 16-bit sums for dovi_chroma_420_to_422 */

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
 * fixed-point convention of Dolby's reference. */
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
       unspecified). Read only by dovi_chroma_420_to_422, for the vertical phase of each 4:2:2 row. */
    dovi_u32 bl_chroma_loc;

    /* FEL / MEL split view: the luma column from which the residual is no longer added, so the left of the
       picture is the full FEL result and the right what a MEL stream decodes to. 0 = no split. */
    dovi_u32 residual_split_x;
};
/* DOVI_SHARED_STRUCTS_END */


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

// Function constant 1: the MMR sums kept as two exact words throughout (`dovi_acc_add`), for a frame with a piece the
// float estimate cannot pin; false, the default, takes the estimate path for every piece. Chosen per frame by the
// composer (`populateMmrTable`), so neither pipeline carries the other's path.
constant bool dovi_fc_mmr_exact [[function_constant(1)]];

// Function constant 2: the luma kernel's MMR path, for a frame whose luma curve has an MMR piece (no profile 7
// stream seen has one). The default luma pipeline is the lookup table alone, so it carries none of the MMR's
// registers.
constant bool dovi_fc_luma_mmr [[function_constant(2)]];

// Function constant 3: the base layer alone, for a picture with no enhancement layer (Dolby Vision profile 5, AV1
// profile 10.0). The reconstruction is the prediction (h = v, CCM 001 5.4.3.3 with no residual), so these pipelines
// take neither the enhancement layer nor its inverse-NLQ table, and carry none of their reads or registers.
constant bool dovi_fc_base_only [[function_constant(3)]];
constant bool dovi_fc_with_el = !dovi_fc_base_only;

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

// The composition arithmetic is Dolby's integer fixed point:
// - a base-layer value s enters as t = s << (20 - BL_bit_depth), Q20 of s / 2^BL_bit_depth, and a product of two
//   terms is taken back to Q20 with >> 20. For integer s that is the reference's own term (s0 * s1 <<
//   (20 - 2 * BL_bit_depth) is (t0 * t1) >> 20 exactly);
// - a prediction v is the 16-bit `vv >> (4 + coefficient_log2_denom)`, negative sums 0, capped at 0xffff;
// - the residual r is the 16-bit inverse NLQ (`DoviFelComposer.inverseNlq`, tabulated per EL code);
// - v + r is kept whole until the output is written (dovi_reconstruct and the writers below).

// Q20 shift for a base-layer code: 20 - BL_bit_depth.
static inline uint dovi_q20_shift(uint bl_max) {
    return 20u - (32u - clz(bl_max));
}

// The arithmetic is 64-bit integers, carried in 32-bit words, which Apple GPUs multiply natively where
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

// constant << 20, the constant term: the coefficient against the term 1.0 in Q20 (`poly_coef[0] * (1 << 20)`).
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

// The accumulated Q(20 + coefficient_log2_denom) sum to the 16-bit prediction: negative sums 0,
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

// Index of the piece owning t: the last pivot that t reaches. The reference takes the first piece whose next pivot
// is above s, which is the same piece, a zero-width piece (two equal pivots) included: both give the later one. Past
// the last pivot the reference's index runs one beyond the pieces; the value is clamped to that pivot anyway, so the
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

// t clamped to a component's pivot range, in Q20 (the polynomial's input and each MMR input s0 / s1 / s2). A
// component with no usable curve (num_pivots < 2) has no range and is left as is.
static inline uint dovi_clamp_to_pivots(constant struct DoviPolynomialParams &curve, uint t, uint shift) {
    if (curve.num_pivots < 2u) {
        return t;
    }
    return clamp(t, curve.pivots[0] << shift, curve.pivots[curve.num_pivots - 1u] << shift);
}

// Polynomial piece: the sum of poly_coef[i] * s^i at Q20, i <= 2.
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

// One component's MMR sum. The sum vv is a 64-bit integer. On the estimate path (`dovi_fc_mmr_exact` false) its low
// word is exact from wrapping 32-bit multiply-adds, one multiply per coefficient, and its high word is pinned by a
// float estimate E of the same sum, the coefficients' float values against the exact terms (every term is below
// 2^24, so its float value is exact; each coefficient's float value is converted where it is used, the same rounding
// the CPU's bound assumes): with A = sum of |c * t|, E is within (n + 2) * 2^-24 * A of vv in whatever order the
// terms are added, and for A <= 2^49 that is under 2^31, so hi = rint((E - lo) / 2^32) is vv's high word exactly. The
// CPU bounds A for every piece the frame can reach with the term ceiling 2^20; a frame with a piece it cannot bound
// gets the exact pipelines, which carry both words through two-word products for any coefficient. Either way the
// sum does not depend on the order its terms arrive in, and a zero coefficient or a zero term adds exactly nothing.
struct DoviMmrSum {
    DoviAcc acc;
    float e;
};

// Coefficient c against the term t (Q20; the constant is coefficient 0 against 1 << 20, 1.0).
static inline void dovi_mmr_add(thread DoviMmrSum &s, int c, uint t) {
    if (dovi_fc_mmr_exact) {
        dovi_acc_add(s.acc, c, t);
    } else {
        s.acc.lo += uint(c) * t;
        s.e = fma(float(c), float(t), s.e);
    }
}

// The sum's 16-bit prediction.
static inline int dovi_mmr_end(thread const DoviMmrSum &s, uint coef_shift) {
    if (dovi_fc_mmr_exact) {
        return dovi_prediction(s.acc, coef_shift);
    }
    int hi = int(rint((s.e - float(s.acc.lo)) * 0x1p-32f));
    return dovi_prediction(DoviAcc{ hi, s.acc.lo }, coef_shift);
}

// One term of a step of `dovi_mmr_shared`, its square and its cube (term * square), each product truncated back to
// Q20, against the coefficients the step's rotation has brought to lanes `first`, first + 8 and first + 16, of
// `a`'s piece and, with `Both`, `b`'s. Every lane takes part in the shuffles.
template <bool Both>
static inline void dovi_mmr_feed(thread DoviMmrSum &a, int ka, thread DoviMmrSum &b, int kb, ushort first,
                                 uint term) {
    uint square = dovi_mul_q20(term, term);
    uint cube = dovi_mul_q20(term, square);
    dovi_mmr_add(a, simd_shuffle(ka, first), term);
    dovi_mmr_add(a, simd_shuffle(ka, ushort(first + 8)), square);
    dovi_mmr_add(a, simd_shuffle(ka, ushort(first + 16)), cube);
    if (Both) {
        dovi_mmr_add(b, simd_shuffle(kb, first), term);
        dovi_mmr_add(b, simd_shuffle(kb, ushort(first + 8)), square);
        dovi_mmr_add(b, simd_shuffle(kb, ushort(first + 16)), cube);
    }
}

// The MMR sums of this sample's pieces, `piece_a` of `table_a` (and with `Both`, `piece_b` of `table_b`: Cb and Cr
// read the same three inputs), with the coefficients shared across the SIMD-group instead of every lane loading its
// own: in each pass the first lane still pending names a piece (pair), lane L loads coefficient L of it, and every
// term takes its coefficient from the lane holding it by shuffle. A lane whose pieces are the pass's sums its
// terms; any other sums zero terms, exactly nothing, and waits for a later pass. A group on one piece, as nearly
// every one is, takes one pass. `need` false (no MMR piece, or outside the picture) never counts as pending. Every
// lane of the SIMD-group must be here: the shuffles read every lane.
//
// A pass runs four steps, step i the subsets i and i + 4 (base and base * s2, the bases 1.0, s0, s1, s0s1): each
// reads its coefficients at lanes 0, 4, 8, 12, 16, 20 and then rotates them down a lane for the next. The steps are
// a loop the compiler keeps rolled, so a sample holds its inputs, the bases still to come, two sums a component and
// one step's six products, never the 21 terms (unrolled, the compiler forms them all up front and keeps them for
// the second component and the estimate).
template <bool Both>
static inline void dovi_mmr_shared(device const int* table_a, int piece_a, device const int* table_b, int piece_b,
                                   bool need, uint t0, uint t1, uint t2, uint lane,
                                   thread DoviMmrSum &a, thread DoviMmrSum &b) {
    a = DoviMmrSum{ DoviAcc{ 0, 0u }, 0.0f };
    b = DoviMmrSum{ DoviAcc{ 0, 0u }, 0.0f };
    bool pending = need;
    while (true) {
        uint waiting = uint(uint64_t(simd_ballot(pending)));
        if (waiting == 0u) {
            break;
        }
        ushort leader = ushort(ctz(waiting));
        int pass_a = simd_broadcast(piece_a, leader);
        int pass_b = Both ? simd_broadcast(piece_b, leader) : 0;
        bool mine = pending && piece_a == pass_a && (!Both || piece_b == pass_b);
        uint k = min(lane, uint(DOVI_MMR_TABLE_PIECE_STRIDE - 1));
        int ka = table_a[pass_a * DOVI_MMR_TABLE_PIECE_STRIDE + k];
        int kb = Both ? table_b[pass_b * DOVI_MMR_TABLE_PIECE_STRIDE + k] : 0;
        uint s0 = mine ? t0 : 0u, s1 = mine ? t1 : 0u, s2 = mine ? t2 : 0u;
        uint base = mine ? (1u << 20) : 0u, next = s0, after = s1, last = dovi_mul_q20(s0, s1);
        #pragma clang loop unroll(disable)
        for (ushort step = 0; step < 4; ++step) {
            dovi_mmr_feed<Both>(a, ka, b, kb, ushort(0), base);
            dovi_mmr_feed<Both>(a, ka, b, kb, ushort(4), dovi_mul_q20(base, s2));
            ka = simd_shuffle_rotate_down(ka, ushort(1));
            if (Both) {
                kb = simd_shuffle_rotate_down(kb, ushort(1));
            }
            base = next;
            next = after;
            after = last;
        }
        pending = pending && !mine;
    }
}

// The MMR inputs of a sample: luma (downsampled to the chroma site) and the two chroma values, each
// clamped to its own component's pivots.
static inline void dovi_mmr_inputs(constant struct DoviMetalParams &params, uint t0, uint t1, uint t2, uint shift,
                                   thread uint &c0, thread uint &c1, thread uint &c2) {
    c0 = dovi_clamp_to_pivots(params.poly_y, t0, shift);
    c1 = dovi_clamp_to_pivots(params.poly_cb, t1, shift);
    c2 = dovi_clamp_to_pivots(params.poly_cr, t2, shift);
}

// Whether `curve`'s `piece` is MMR (piece -1, identity, is not).
static inline bool dovi_is_mmr(constant struct DoviPolynomialParams &curve, int piece) {
    return piece >= 0 && curve.method[piece] == DOVI_MAPPING_MMR;
}

// One component's 16-bit prediction from its own value t (Q20), in a `piece` (`dovi_curve_piece`) that is not MMR (an
// MMR piece's is `dovi_mmr_end`). Piece -1, num_pivots < 2, is the parser's fail-safe for a curve it could not
// trust, and means identity: the base layer passes through untouched (v = s << (16 - BL_bit_depth), the identity
// polynomial's exact value).
static inline int dovi_eval_curve(constant struct DoviPolynomialParams &curve, int piece, uint t, uint shift) {
    return dovi_eval_poly(curve, piece, t, shift);
}

/* ============================================================================
   Inverse NLQ
   ========================================================================= */

// The inverse linear-deadzone quantiser depends on the EL code alone, so the composer evaluates it once per frame
// for every code of each component (`DoviFelComposer.inverseNlq`) and the kernels index that table:
// nlq_lut[component * DOVI_NLQ_LUT_CODES + code], the 16-bit signed r, Y then Cb then Cr. It runs past the 10-bit
// range because the EL upsampling filters overshoot (0 ... about 1400 from 10-bit input) and the inverse NLQ takes
// the upsampled code as it is.
#define DOVI_NLQ_LUT_CODES 2048
static inline int dovi_inv_nlq(device const int* nlq_lut, uint component, int el_code) {
    return nlq_lut[component * uint(DOVI_NLQ_LUT_CODES) + uint(clamp(el_code, 0, DOVI_NLQ_LUT_CODES - 1))];
}

/* ============================================================================
   Reconstruction and output
   ========================================================================= */

// h = v + r, still at 16 bits: the reconstruction rounds it once to hdr_bit_depth, and each writer below takes it
// from here, so no output is rounded twice.
//
// The reconstructed sample, hdr_bit_depth bits: (h + 2^(15 - hdr_bit_depth)) >> (16 - hdr_bit_depth), clipped to
// [0, 2^hdr_bit_depth - 1].
static inline int dovi_reconstruct(int h, uint vdr_max) {
    uint bits = 32u - clz(vdr_max);
    return clamp((h + (1 << (15u - bits))) >> (16u - bits), 0, int(vdr_max));
}

// The largest 16-bit sum the reconstruction does not clip: the one whose rounding to hdr_bit_depth bits is
// 2^hdr_bit_depth - 1 (65527 at 12 bits). A sum clipped to [0, dovi_sum_max] rounds to exactly the reconstruction's
// clipped sample, so the clip is the code space's, whatever range the picture is in. A depth the parser never
// accepts (outside 1...15 bits) still gives a bound within 16 bits.
static inline int dovi_sum_max(uint vdr_max) {
    uint bits = clamp(32u - clz(vdr_max), 1u, 15u);
    return min((int(vdr_max) << (16u - bits)) + (1 << (15u - bits)) - 1, 0xFFFF);
}

// 16-bit sample: h itself, clipped as the reconstruction is clipped (dovi_sum_max). A 10-bit code shifted left 6
// and a 12-bit code shifted left 4 are both h's scale (black 64 << 6 = 256 << 4 = 4096), so sv22 carries the sum
// before the reconstruction's rounding, from which its 12-bit sample is (h + 8) >> 4 exactly; P010's
// full-precision mode puts the same word in P010, whose low 6 bits CoreVideo calls padding.
static inline int dovi_full_precision(int h, uint vdr_max) {
    return clamp(h, 0, dovi_sum_max(vdr_max));
}

// h down to the 10-bit output plane, dithered or rounded, in one step from the 16-bit sum, clipped to the 10-bit code
// space as the reconstruction is clipped to its own.
static inline int dovi_quantize(
    int h,
    uint dither_mode,
    float dither)
{
    float v = float(h) * (1.0f / 64.0f);
    // Both branches have mean 0.5, so enabling dither redistributes the rounding
    // error without moving the average level.
    float bias = (dither_mode == DOVI_DITHER_NONE) ? 0.5f : dither;
    return clamp(int(floor(v + bias)), 0, 1023);
}

// A 4:2:0 chroma plane's size along an axis of `n` luma samples: half, rounded up, as CoreVideo allocates it, so an
// odd picture's last chroma column and row are read and written.
static inline uint dovi_chroma_size(uint n) {
    return (n + 1u) >> 1;
}

/* ============================================================================
   Enhancement layer upsampling
   ========================================================================= */

// The EL is brought to the base layer's grid by Dolby's reference resampling: the RPU carries no filter, so the
// reference is the only defined choice. Every 2:1 step takes the same grid: columns co-sited, rows centred.

// Vertical first, then horizontal, each pass rounded and clipped to [0, 0xFFFF], edges replicated:
// - vertical, luma (cmp 0): r[2n] = (-3 y[n-2] + 29 y[n-1] + 111 y[n] - 9 y[n+1] + 64) >> 7, r[2n+1] mirrored
//   (Catmull-Rom at the quarter phases, rows centred);
// - vertical, chroma (cmp 1, 2): r[2n] = (64 y[n-1] + 192 y[n] + 128) >> 8, r[2n+1] = (192 y[n] + 64 y[n+1] + 128) >> 8;
// - horizontal, every component (SPATIAL_RESAMPLING_FILTER_H): r[2n] = y[n], r[2n+1] = (22 y[n-3] + 94 y[n-2]
//   - 524 y[n-1] + 2456 y[n] + 2456 y[n+1] - 524 y[n+2] + 94 y[n+3] + 22 y[n+4] + 2048) >> 12 (columns co-sited).
//
// One SIMD-group composes the 32 consecutive output columns x0 ... x0 + 31, which read 23 EL columns (16, and 3 + 4
// neighbours for the 8 taps). Lane L runs the vertical pass for EL column x0 / 2 - 3 + L, and each output lane takes
// its horizontal taps from the lanes that hold them: registers and shuffles, no threadgroup memory, no barrier.
// Lanes 0 - 15 compose the even columns and lanes 16 - 31 the odd ones (`dovi_lane_column`), so that every tap is a
// fixed number of lanes away: a shuffle by a constant offset is one instruction, where one whose source lane varies
// inside a quad of lanes (lane L reading lane L / 2 + k) is four shuffles and three selects on the A15. That holds
// when lane L is grid column x0 + L: threadgroups 32 wide, dispatched in whole threadgroups, so every lane runs (the
// composer's `elUpsamplingThreadgroup`). Lanes past the picture still compute, on replicated edge columns, and only
// leave after the shuffles.

// The output column lane `lane` composes, in the SIMD-group whose first grid column is x0: x0 + 2L for lanes 0 - 15,
// x0 + 2(L - 16) + 1 for lanes 16 - 31.
static inline uint dovi_lane_column(uint x0, uint lane) {
    return x0 + ((lane & 15u) << 1) + (lane >> 4);
}

// The EL column lane `lane` runs the vertical pass for, edge replicated.
static inline int dovi_el_column(uint x0, uint lane, uint el_width) {
    return clamp(int(x0 >> 1) - 3 + int(lane), 0, int(el_width) - 1);
}

// Vertical pass, luma, for output row `row` at EL column `col`: the four EL rows it reads, from two gathers of the
// 2 x 2 block at (col, first) and (col, first + 2), this lane keeping column `col`; clamp-to-edge is the reference's
// replication.
static inline int dovi_el_v_luma(texture2d<ushort, access::sample> tex, int col, uint row) {
    constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);
    int n = int(row >> 1);
    bool odd = (row & 1u) != 0u;
    float first = float(odd ? n - 1 : n - 2);
    // Gather order: (x0, y1), (x1, y1), (x1, y0), (x0, y0).
    ushort4 a = tex.gather(s, float2(float(col) + 1.0f, first + 1.0f));
    ushort4 b = tex.gather(s, float2(float(col) + 1.0f, first + 3.0f));
    int y0 = int(a.w >> 6), y1 = int(a.x >> 6), y2 = int(b.w >> 6), y3 = int(b.x >> 6);
    int sum = odd ? (-9 * y0 + 111 * y1 + 29 * y2 - 3 * y3) : (-3 * y0 + 29 * y1 + 111 * y2 - 9 * y3);
    return clamp((sum + 64) >> 7, 0, 0xFFFF);
}

// Vertical pass, both chroma components, for BL chroma row `row` at EL chroma column `col`.
static inline int2 dovi_el_v_chroma(texture2d<ushort, access::read> tex, int col, uint row, uint el_height) {
    int n = int(row >> 1), last = int(el_height) - 1;
    bool odd = (row & 1u) != 0u;
    int2 a = int2(tex.read(uint2(col, clamp(odd ? n : n - 1, 0, last))).rg >> 6);
    int2 b = int2(tex.read(uint2(col, clamp(odd ? n + 1 : n, 0, last))).rg >> 6);
    int2 s = odd ? (192 * a + 64 * b) : (64 * a + 192 * b);
    return clamp((s + 128) >> 8, int2(0), int2(0xFFFF));
}

// Horizontal pass across the SIMD-group: `v` is this lane's vertical result. An even lane L (0 - 15, output column
// x0 + 2L) takes y[x0 / 2 + L], the co-sited value, from lane L + 3; an odd lane (16 - 31, output column
// x0 + 2(L - 16) + 1) takes its eight taps from lanes L - 16 ... L - 9. Every lane shuffles, whichever phase it keeps.
// The eight taps arrive as four pairs: every lane first takes its right neighbour's value beside its own (one
// shuffle down; each value is 16 bits, so the two fit a 32-bit word, Cb and Cr a word each), then an odd lane takes
// the pairs 16, 14, 12 and 10 lanes up. Six shuffles (ten for chroma's two components), each by a constant offset.
static inline int dovi_el_h(int v, uint lane) {
    uint even = simd_shuffle_down(own, ushort(3));
    uint p0 = simd_shuffle_up(pair, ushort(16)), p1 = simd_shuffle_up(pair, ushort(14));
    uint p2 = simd_shuffle_up(pair, ushort(12)), p3 = simd_shuffle_up(pair, ushort(10));
    if (lane < 16u) {
        return int(even);
    }
}
static inline int2 dovi_el_h(int2 v, uint lane) {
    uint even = simd_shuffle_down(own, ushort(3));
    uint2 p0 = simd_shuffle_up(pair, ushort(16)), p1 = simd_shuffle_up(pair, ushort(14));
    uint2 p2 = simd_shuffle_up(pair, ushort(12)), p3 = simd_shuffle_up(pair, ushort(10));
    if (lane < 16u) {
        return int2(int(even & 0xFFFFu), int(even >> 16));
    }
}

// The upsampled EL luma code at this lane's BL pixel in row `row` (`dovi_lane_column`).
static inline int dovi_el_luma(texture2d<ushort, access::sample> tex, uint x0, uint row, uint lane, uint2 el_size) {
    return dovi_el_h(dovi_el_v_luma(tex, dovi_el_column(x0, lane, el_size.x), row), lane);
}

// The upsampled EL chroma codes (Cb, Cr) at this lane's BL chroma sample in row `row`.
static inline int2 dovi_el_chroma(texture2d<ushort, access::read> tex, uint x0, uint row, uint lane, uint2 el_size) {
    return dovi_el_h(dovi_el_v_chroma(tex, dovi_el_column(x0, lane, el_size.x), row, el_size.y), lane);
}

/* ============================================================================
   Composition kernels
   ========================================================================= */

// Whether the residual is added at luma column `x`: everywhere without a split, left of it with one.
static inline bool dovi_residual_at(constant struct DoviMetalParams &params, uint x) {
    return params.residual_split_x == 0u || x < params.residual_split_x;
}

// Luma: BL luma + reshaping curve + inverse-NLQ residual -> 10-bit P010 plane.
//
// bl_uv_tex is bound only because a luma curve may carry MMR pieces, which need
// all three components. No observed profile 7 stream has an MMR luma curve (libdovi
// would report it as mapping_idc = 1 for component 0), so only the `dovi_fc_luma_mmr`
// pipeline fetches it. There the chroma pair is taken
// nearest-neighbour from the 4:2:0 plane: the reshaping model is defined on 4:4:4
// input, and reconstructing chroma to full resolution here would cost a separate
// pass for a case that does not occur in practice.

kernel void dovi_compose_luma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::sample>      el_y_tex      [[texture(2), function_constant(dovi_fc_with_el)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant int*                          luma_lut      [[buffer(1)]],
    device const int*                      nlq_lut       [[buffer(2), function_constant(dovi_fc_with_el)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    // This lane's pixel (`dovi_lane_column`); x0 is the first column of its SIMD-group's 32.
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    bool residual = dovi_fc_with_el && (params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u &&
                    params.nlq_y.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_y.nlq_scale != 0;
    // The EL's horizontal pass reads its neighbours' vertical results, so every lane runs it before any leaves.
    int el_code = 0;
    if (residual) {
        el_code = dovi_el_luma(el_y_tex, x0, gid.y, lane, uint2(params.el_width, params.el_height));
    }
    // A lane past the picture reads the edge and stays until the MMR's shuffles are done (they read every lane).
    bool inside = gid.x < params.bl_width && gid.y < params.bl_height;
    uint2 at = min(gid, uint2(params.bl_width - 1u, params.bl_height - 1u));

    int bl_y = int(bl_y_tex.read(at).r >> 6);

    int h;
    if (!dovi_fc_luma_mmr) {
        h = luma_lut[bl_y];
    } else {
        uint shift = dovi_q20_shift(params.bl_max);
        ushort4 bl_uv = bl_uv_tex.read(uint2(at.x >> 1, at.y >> 1));
        uint t = uint(bl_y) << shift;
        bool mmr = dovi_is_mmr(params.poly_y, piece);
        uint c0, c1, c2;
        dovi_mmr_inputs(params, t, uint(bl_uv.r >> 6) << shift, uint(bl_uv.g >> 6) << shift, shift, c0, c1, c2);
        // As in the chroma kernel: a polynomial piece first, on the clamped input.
        h = mmr ? 0 : dovi_eval_curve(params.poly_y, piece, c0, shift);
        DoviMmrSum sum, unused;
        dovi_mmr_shared<false>(mmr_table, piece, mmr_table, 0, inside && mmr, c0, c1, c2, lane, sum, unused);
        if (mmr) {
            h = dovi_mmr_end(sum, params.mmr_y.coef_shift);
        }
    }
    if (!inside) {
        return;
    }

    if (residual && dovi_residual_at(params, gid.x)) {
        h += dovi_inv_nlq(nlq_lut, 0u, el_code);
    }

    if (params.residual_split_x != 0u && uint(abs(int(gid.x) - int(params.residual_split_x))) < 2u) {
        h = 0x8000;   // the split's divider, mid-grey in PQ
    }

    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        out_y_tex.write(ushort4(ushort(dovi_reconstruct(h, params.vdr_max) << (16u - (32u - clz(params.vdr_max)))), 0, 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_y_tex.write(ushort4(ushort(dovi_full_precision(h, params.vdr_max)), 0, 0, 0), gid);
        return;
    }
    int out_y = dovi_quantize(h, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(0u, 0u)));
    out_y_tex.write(ushort4(ushort(out_y << 6), 0, 0, 0), gid);
}

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
// reads the same three base-layer components. Composed at the 4:2:0 sites, where the reconstruction is defined;
// for sv22 (DOVI_FLAG_CHROMA_422) the result goes to the intermediate dovi_chroma_420_to_422 reads, not the output.
kernel void dovi_compose_chroma(
    texture2d<ushort, access::read>        bl_y_tex      [[texture(0)]],
    texture2d<ushort, access::read>        bl_uv_tex     [[texture(1)]],
    texture2d<ushort, access::read>        el_uv_tex     [[texture(2), function_constant(dovi_fc_with_el)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    device const int*                      nlq_lut       [[buffer(2), function_constant(dovi_fc_with_el)]],
    device const int*                      mmr_table     [[buffer(3)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    // This lane's chroma sample (`dovi_lane_column`); x0 is the first column of its SIMD-group's 32.
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    uint uv_width = dovi_chroma_size(params.bl_width);
    uint uv_height = dovi_chroma_size(params.bl_height);
    bool cb_active = params.nlq_cb.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cb.nlq_scale != 0;
    bool cr_active = params.nlq_cr.nlq_method == DOVI_NLQ_METHOD_LINEAR && params.nlq_cr.nlq_scale != 0;
    bool residual = dovi_fc_with_el && (params.flags & DOVI_FLAG_DISABLE_RESIDUAL) == 0u && (cb_active || cr_active);
    // As in the luma kernel: every lane runs the EL upsampling before any leaves.
    int2 el_code = int2(0);
    if (residual) {
        el_code = dovi_el_chroma(el_uv_tex, x0, gid.y, lane,
                                 uint2(dovi_chroma_size(params.el_width), dovi_chroma_size(params.el_height)));
    }

    // A lane past the picture reads the edge and stays until the MMR's shuffles are done (they read every lane).
    bool inside = gid.x < uv_width && gid.y < uv_height;
    uint2 at = min(gid, uint2(uv_width - 1u, uv_height - 1u));

    // Base-layer luma at the chroma site, for the cross-component terms: [1 2 1]
    // around the even column in each of the cell's two rows, then the rows
    // averaged, in integers, edges clamped. This is DoViBaker's reading, and
    // Dolby-encoded streams agree with it: on one with order-3 MMR chroma the
    // coded residual matches it at about half the error of the plain vertical
    // 2-tap this kernel used before.
    uint lx = min(at.x * 2u, params.bl_width - 1u);
    uint lxl = lx > 0u ? lx - 1u : 0u;
    uint lxr = min(lx + 1u, params.bl_width - 1u);
    int bl_y = 0;
    for (uint r = 0u; r < 2u; ++r) {
        uint ly = min(at.y * 2u + r, params.bl_height - 1u);
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
        bl_y += (row + 2) >> 2;
    }
    bl_y = (bl_y + 1) >> 1;

    ushort4 bl_uv = bl_uv_tex.read(at);
    int bl_cb = int(bl_uv.r >> 6);
    int bl_cr = int(bl_uv.g >> 6);

    uint shift = dovi_q20_shift(params.bl_max);
    uint t0 = uint(bl_y) << shift, t1 = uint(bl_cb) << shift, t2 = uint(bl_cr) << shift;
    bool mmr_cb = dovi_is_mmr(params.poly_cb, piece_cb), mmr_cr = dovi_is_mmr(params.poly_cr, piece_cr);
    uint c0, c1, c2;
    dovi_mmr_inputs(params, t0, t1, t2, shift, c0, c1, c2);
    // A polynomial piece is evaluated before the MMR pass (on the clamped input, which it clamps to the same range), so
    // the pass carries one value a component rather than its piece and input.
    int h_cb = mmr_cb ? 0 : dovi_eval_curve(params.poly_cb, piece_cb, c1, shift);
    int h_cr = mmr_cr ? 0 : dovi_eval_curve(params.poly_cr, piece_cr, c2, shift);
    // One pass over the terms feeds both sums; a component whose piece is not MMR sums against the zero piece.
    DoviMmrSum sum_cb, sum_cr;
    dovi_mmr_shared<true>(mmr_table + DOVI_MMR_TABLE_COMPONENT_STRIDE, mmr_cb ? piece_cb : DOVI_MMR_ZERO_PIECE,
                          mmr_table + 2 * DOVI_MMR_TABLE_COMPONENT_STRIDE, mmr_cr ? piece_cr : DOVI_MMR_ZERO_PIECE,
                          inside && (mmr_cb || mmr_cr), c0, c1, c2, lane, sum_cb, sum_cr);
    if (mmr_cb) {
        h_cb = dovi_mmr_end(sum_cb, params.mmr_cb.coef_shift);
    }
    if (mmr_cr) {
        h_cr = dovi_mmr_end(sum_cr, params.mmr_cr.coef_shift);
    }
    if (!inside) {
        return;
    }

    if (residual && dovi_residual_at(params, gid.x * 2u)) {
        if (cb_active) {
            h_cb += dovi_inv_nlq(nlq_lut, 1u, el_code.x);
        }
        if (cr_active) {
            h_cr += dovi_inv_nlq(nlq_lut, 2u, el_code.y);
        }
    }

    // sv22: the 16-bit sums, clipped as the reconstruction is clipped, for the 4:2:2 step.
    if ((params.flags & DOVI_FLAG_CHROMA_422) != 0u) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(h_cb, params.vdr_max)),
                                 ushort(dovi_full_precision(h_cr, params.vdr_max)), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DEBUG_RAW_VDR) {
        uint up = 16u - (32u - clz(params.vdr_max));
        out_uv_tex.write(ushort4(ushort(dovi_reconstruct(h_cb, params.vdr_max) << up),
                                 ushort(dovi_reconstruct(h_cr, params.vdr_max) << up), 0, 0), gid);
        return;
    }
    if (params.dither_mode == DOVI_DITHER_FULL_PRECISION) {
        out_uv_tex.write(ushort4(ushort(dovi_full_precision(h_cb, params.vdr_max)),
                                 ushort(dovi_full_precision(h_cr, params.vdr_max)), 0, 0), gid);
        return;
    }
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)));
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)));
    out_uv_tex.write(ushort4(ushort(out_cb << 6), ushort(out_cr << 6), 0, 0), gid);
}

// The 4:2:0 -> 4:2:2 taps, over chroma rows i - 1 ... i + 2 for a row at chroma-row coordinate i + t, by phase t in
// quarters, in 128ths:
// - t = 0, the chroma row itself: a copy, f[2n] = 64 s[n];
// - t = 1/2: (-1, 9, 9, -1) / 16, f[2n + 1] = -4 s[n - 1] + 36 s[n] + 36 s[n + 1] - 4 s[n + 2];
//   these two are Dolby's reference chroma up-sampling, for co-sited chroma;
// - t = 1/4, 3/4: Catmull-Rom at the quarter phases, the EL luma's vertical taps, for the other sitings.
constant int dovi_chroma_422_taps[4][4] = {
    {  0, 128,   0,   0 },
    { -9, 111,  29,  -3 },
    { -8,  72,  72,  -8 },
    { -3,  29, 111,  -9 },
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

// sv22's 4:2:0 -> 4:2:2 step, one thread per output sample: Dolby's reference vertical chroma up-sampling, on the
// reconstructed picture, after composition. `in_uv_tex` holds dovi_compose_chroma's 16-bit sums at the 4:2:0
// sites, clipped as the reconstruction is; each output row takes the four chroma rows around it at its phase
// (dovi_chroma_422_taps), edge rows replicated, rounded once, `+ 64 >> 7` (tvOS and the display take the 4:2:2
// picture's horizontal step), and clipped the same way.
// On a chroma row the output is that row's composed sum. The rows sit where the stream's siting puts them
// (dovi_chroma_422_offset_q); chroma is horizontally co-sited with the even luma column.
kernel void dovi_chroma_420_to_422(
    texture2d<ushort, access::read>        in_uv_tex     [[texture(0)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(1)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width = dovi_chroma_size(params.bl_width);
    if (gid.x >= uv_width || gid.y >= params.bl_height) {
        return;
    }
    // The row's chroma-row coordinate in quarters, q = 2 * row + offset (>= -2): whole part q / 4, phase q % 4.
    int q = 2 * int(gid.y) + dovi_chroma_422_offset_q(params.bl_chroma_loc) + 8;
    int first = q / 4 - 2 - 1;
    int phase = q & 3;
    int last_row = int(dovi_chroma_size(params.bl_height)) - 1;
    int2 sum = int2(0);
    for (int i = 0; i < 4; ++i) {
        uint row = uint(clamp(first + i, 0, last_row));
        sum += int2(in_uv_tex.read(uint2(gid.x, row)).rg) * dovi_chroma_422_taps[phase][i];
    }
    int2 h = (sum + 64) >> 7;
    out_uv_tex.write(ushort4(ushort(dovi_full_precision(h.x, params.vdr_max)),
                             ushort(dovi_full_precision(h.y, params.vdr_max)), 0, 0), gid);
}

/* ============================================================================
   IPT-PQ-c2 to BT.2020 Y'CbCr PQ (profile 5 and AV1 10.0 stills)
   ========================================================================= */

// The colour conversion a profile 5 picture carries in its RPU's display-management data (CCM 001 6.2.2), with the
// last step the RPU leaves implied:
// - ycc_to_lms: YCCtoRGB_coef, the opponent signal (here IPT, signal_color_space 2) to the non-linear trichromatic one,
//   applied after subtracting ycc_offset (YCCtoRGB_offset);
// - the ST 2084 EOTF on each component (signal_eotf: PQ);
// - lms_to_rgb: RGBtoLMS_coef (for IPT-PQ-c2, the inverse of its crosstalk) followed by LMS to linear BT.2020 RGB,
//   one matrix. Row major.
struct DoviIptConversion {
    float ycc_to_lms[9];
    float ycc_offset[3];
    float lms_to_rgb[9];
};

// e^x - 1 and log(1 + x), accurate for small x where the direct forms lose their digits to the subtraction (Kahan's
// formulations over precise exp and log). Reassociation off: it would fold (1 + x) - 1 back to x.
static inline float3 dovi_expm1(float3 x) {
    #pragma clang fp reassociate(off)
    float3 u = precise::exp(x);
    float3 um1 = u - 1.0f;
    float3 r = select(um1 * x / precise::log(u), x, u == 1.0f);
    return select(r, float3(-1.0f), um1 == -1.0f);
}

static inline float3 dovi_log1p(float3 x) {
    #pragma clang fp reassociate(off)
    float3 u = 1.0f + x;
    return select(precise::log(u) * x / (u - 1.0f), x, u == 1.0f);
}

// The ST 2084 curves, written so that nothing cancels: with p = 1 + d, p - c1 = (1 - c1) + d and c2 - c3 p =
// (c2 - c3) - c3 d, and the inverse's ratio (c1 + c2 p) / (1 + c3 p) is 1 + (c2 - c3) d / (1 + c3 p); 1 - c1 and
// c2 - c3 are both 0.1640625 exactly. In single precision the direct forms are off by up to 11 in 65535 at 16-bit
// video range; these, by a tenth of one.
static inline float3 dovi_pq_eotf(float3 e) {
    float3 d = dovi_expm1(precise::log(max(e, 1e-30f)) * (1.0f / 78.84375f));
    float3 ratio = max(0.1640625f + d, 0.0f) / (0.1640625f - 18.6875f * d);
    return select(precise::exp(precise::log(ratio) * (1.0f / 0.1593017578125f)), float3(0.0f), e <= 0.0f);
}

static inline float3 dovi_pq_oetf(float3 l) {
    float3 d = dovi_expm1(precise::log(max(l, 1e-30f)) * 0.1593017578125f);
    float3 encoded = precise::exp(78.84375f * dovi_log1p(0.1640625f * d / (1.0f + 18.6875f * (1.0f + d))));
    return select(encoded, float3(precise::pow(0.8359375f, 78.84375f)), l <= 0.0f);
}

static inline float3 dovi_mul3(constant float *m, float3 v) {
    return float3(m[0] * v.x + m[1] * v.y + m[2] * v.z,
                  m[3] * v.x + m[4] * v.y + m[5] * v.z,
                  m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

// One output pixel per lane (`dovi_lane_column`): the composed luma sum at the pixel, and the composed chroma, already
// brought to every row by `dovi_chroma_420_to_422`, brought to the pixel's column by the reference horizontal 2:1
// filter (`dovi_el_h`; chroma sits on the even luma columns). Each is reconstructed to hdr_bit_depth bits
// (`dovi_reconstruct`, CCM 001 5.4.3.3), taken to the signal's [0, 1] range, converted, and written as BT.2020
// non-constant-luminance Y'CbCr, PQ, 16-bit video range (luma 4096...60160), 4:4:4, so nothing is rounded between
// the reconstruction and the still's own mapping. Whole threadgroups 32 wide, as the composition kernels.
kernel void dovi_ipt_to_bt2020(
    texture2d<ushort, access::read>        sum_y_tex     [[texture(0)]],
    texture2d<ushort, access::read>        sum_uv_tex    [[texture(1)]],
    texture2d<ushort, access::write>       out_y_tex     [[texture(2)]],
    texture2d<ushort, access::write>       out_uv_tex    [[texture(3)]],
    constant struct DoviMetalParams&       params        [[buffer(0)]],
    constant struct DoviIptConversion&     conversion    [[buffer(4)]],
    uint2                                  grid          [[thread_position_in_grid]],
    uint                                   lane          [[thread_index_in_simdgroup]])
{
    uint x0 = grid.x - lane;
    uint2 gid = uint2(dovi_lane_column(x0, lane), grid.y);
    uint row = min(gid.y, params.bl_height - 1u);
    int column = dovi_el_column(x0, lane, dovi_chroma_size(params.bl_width));
    int2 chroma = dovi_el_h(int2(sum_uv_tex.read(uint2(uint(column), row)).rg), lane);
    if (gid.x >= params.bl_width || gid.y >= params.bl_height) {
        return;
    }
    float max_code = float(params.vdr_max);
    float3 signal = float3(float(dovi_reconstruct(int(sum_y_tex.read(gid).r), params.vdr_max)),
                           float(dovi_reconstruct(chroma.x, params.vdr_max)),
                           float(dovi_reconstruct(chroma.y, params.vdr_max))) / max_code;
    float3 offset = float3(conversion.ycc_offset[0], conversion.ycc_offset[1], conversion.ycc_offset[2]);
    float3 lms = dovi_pq_eotf(dovi_mul3(conversion.ycc_to_lms, signal - offset));
    float3 rgb = dovi_pq_oetf(max(dovi_mul3(conversion.lms_to_rgb, lms), 0.0f));
    float y = dot(rgb, float3(0.2627f, 0.6780f, 0.0593f));
    float cb = (rgb.b - y) / 1.8814f;
    float cr = (rgb.r - y) / 1.4746f;
    uint3 codes = uint3(clamp(rint(float3(4096.0f + 56064.0f * y, 32768.0f + 57344.0f * cb, 32768.0f + 57344.0f * cr)),
                              0.0f, 65535.0f));
    out_y_tex.write(ushort4(ushort(codes.x), 0, 0, 0), gid);
    out_uv_tex.write(ushort4(ushort(codes.y), ushort(codes.z), 0, 0), gid);
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
