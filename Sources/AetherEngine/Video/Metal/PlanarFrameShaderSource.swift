/// Metal source for ``PlanarFrameFinisher``. The equations are docs/colour-representation.md's (H.273); the
/// numbers in parentheses below are H.273's.
///
/// One kernel, specialised per source format with function constants: the component layout, the read width,
/// the range, the output depth and the path are all compile-time values, so each format gets a kernel with its
/// branches and address arithmetic folded away. One thread per output chroma sample writes that sample and the
/// luma block it covers (2x2 for 4:2:0, 2x1 for 4:2:2, 1x1 for 4:4:4).
enum PlanarFrameShaderSource {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// MARK: - Specialisation

// 0 pack (Y'CbCr, output keeps the source's chroma subsampling), 1 resample (Y'CbCr, output keeps more chroma),
// 2 grey (neutral chroma), 3 RGB (R'G'B' codes or a palette, to Y'CbCr through the affine rows).
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

constant bool PF_DITHER = FC_FRACTION_BITS > 0u;
constant uint PF_BLOCK_W = 1u << FC_OUT_LOG2_W;
constant uint PF_BLOCK_H = 1u << FC_OUT_LOG2_H;

// MARK: - Per-frame values

struct PFFrame {
    uint width;
    uint height;
    uint chroma_width;      // output chroma plane
    uint chroma_height;
    uint plane_offset[4];
    uint linesize[4];
    // RGB: output code (with F fraction bits) = ( row[0] R + row[1] G + row[2] B + row[3] ) / 2^30, before Round.
    // Fixed point: at 16-bit outputs float32 cannot place a value against its rounding tie, 64-bit integers
    // with 30 fraction bits err by under 2^-14 of a code.
    long rgb_rows[12];
};

// MARK: - Reading (av_read_image_line2)

// The component at (x, y) of its own plane's grid. Every argument but the frame and the position is a function
// constant, so the load width and the address arithmetic fold away.
static inline uint pf_read(device const uchar* src, constant PFFrame& f,
                           uint plane, uint step, uint offset, uint shift, uint depth, uint x, uint y) {
    device const uchar* row = src + f.plane_offset[plane] + y * f.linesize[plane];
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

static inline uint pf_c0(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C0_PLANE, FC_C0_STEP, FC_C0_OFFSET, FC_C0_SHIFT, FC_C0_DEPTH, x, y);
}
static inline uint pf_c1(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C1_PLANE, FC_C1_STEP, FC_C1_OFFSET, FC_C1_SHIFT, FC_C1_DEPTH, x, y);
}
static inline uint pf_c2(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    return pf_read(s, f, FC_C2_PLANE, FC_C2_STEP, FC_C2_OFFSET, FC_C2_SHIFT, FC_C2_DEPTH, x, y);
}

// MARK: - Codes at the output depth

constant uint PF_WORD_MAX = FC_TARGET_BITS + FC_FRACTION_BITS >= 16u ? 0xFFFFu
                          : ((1u << (FC_TARGET_BITS + FC_FRACTION_BITS)) - 1u);

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

// An RGB row applied to codes: Round( x ) = Floor( x + 0.5 ) (8) in 2^-30 fixed point, clipped.
static inline uint pf_rgb_word(constant PFFrame& f, uint row, int3 rgb) {
    long acc = f.rgb_rows[row * 4u] * long(rgb.x) + f.rgb_rows[row * 4u + 1u] * long(rgb.y)
             + f.rgb_rows[row * 4u + 2u] * long(rgb.z) + f.rgb_rows[row * 4u + 3u] + (1l << 29);
    return acc <= 0l ? 0u : min(uint(min(acc >> 30, long(PF_WORD_MAX))), PF_WORD_MAX);
}

// A real-valued code (with F fraction bits) rounded: Round( x ) = Floor( x + 0.5 ) for x >= 0 (8), clipped.
static inline uint pf_round_word(float x) {
    return uint(clamp(floor(x + 0.5f), 0.0f, float(PF_WORD_MAX)));
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

// Where sample i sits on one axis, in luma samples, for a plane subsampled by 2^log2 there. Horizontal:
// co-sited with the left luma sample (LEFT / TOPLEFT / BOTTOMLEFT) or centred on the samples it covers.
// Vertical: on the top row (TOPLEFT / TOP), centred (LEFT / CENTER) or on the bottom row (BOTTOMLEFT / BOTTOM).
static inline float pf_site(float i, uint log2, bool vertical) {
    float span = float(1u << log2) - 1.0f;
    uint l = FC_CHROMA_LOCATION;
    float offset = !vertical ? ((l == 1u || l == 3u || l == 5u) ? 0.0f : 0.5f * span)
                             : ((l == 3u || l == 4u) ? 0.0f : ((l == 5u || l == 6u) ? span : 0.5f * span));
    return i * float(1u << log2) + offset;
}

// Catmull-Rom (B = 0, C = 0.5) weights at fraction t over samples -1, 0, 1, 2.
static inline float4 pf_cubic(float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5f * float4(-t3 + 2.0f * t2 - t, 3.0f * t3 - 5.0f * t2 + 2.0f, -3.0f * t3 + 4.0f * t2 + t, t3 - t2);
}

// Source chroma (components 1, 2) in source code units at output chroma sample `o`.
static inline float2 pf_resample(device const uchar* s, constant PFFrame& f, uint2 o) {
    int src_w = int((f.width + (1u << FC_SRC_LOG2_W) - 1u) >> FC_SRC_LOG2_W);
    int src_h = int((f.height + (1u << FC_SRC_LOG2_H) - 1u) >> FC_SRC_LOG2_H);
    float ux = (pf_site(float(o.x), FC_OUT_LOG2_W, false) - pf_site(0.0f, FC_SRC_LOG2_W, false)) / float(1u << FC_SRC_LOG2_W);
    float uy = (pf_site(float(o.y), FC_OUT_LOG2_H, true) - pf_site(0.0f, FC_SRC_LOG2_H, true)) / float(1u << FC_SRC_LOG2_H);
    float fx = floor(ux), fy = floor(uy);
    int x0 = int(fx), y0 = int(fy);
    float4 wx = FC_SRC_LOG2_W == FC_OUT_LOG2_W ? float4(0, 1, 0, 0) : pf_cubic(ux - fx);
    float4 wy = FC_SRC_LOG2_H == FC_OUT_LOG2_H ? float4(0, 1, 0, 0) : pf_cubic(uy - fy);
    float2 sum = 0.0f;
    for (int j = 0; j < 4; ++j) {
        if (FC_SRC_LOG2_H == FC_OUT_LOG2_H && j != 1) { continue; }
        uint sy = uint(clamp(y0 - 1 + j, 0, src_h - 1));
        float2 row = 0.0f;
        for (int i = 0; i < 4; ++i) {
            if (FC_SRC_LOG2_W == FC_OUT_LOG2_W && i != 1) { continue; }
            uint sx = uint(clamp(x0 - 1 + i, 0, src_w - 1));
            row += wx[i] * float2(float(pf_c1(s, f, sx, sy)), float(pf_c2(s, f, sx, sy)));
        }
        sum += wy[j] * row;
    }
    return sum;
}

// A resampled chroma value (source units, real) as an output word: (31) / (37) with the real value.
static inline uint pf_resampled_word(float c, uint d) {
    float top = float((1u << d) - 1u);
    c = clamp(c, 0.0f, top);
    float scale = float(1u << FC_FRACTION_BITS);
    float x = FC_FULL_RANGE
        ? ((c - float(1u << (d - 1u))) * float((1u << FC_TARGET_BITS) - 1u) / top + float(1u << (FC_TARGET_BITS - 1u))) * scale
        : c * float(1u << (FC_TARGET_BITS - d)) * scale;
    return pf_round_word(x);
}

// MARK: - RGB

static inline int3 pf_rgb_codes(device const uchar* s, constant PFFrame& f, uint x, uint y) {
    if (FC_PALETTE) {
        // AV_PIX_FMT_PAL8: an index into 256 native-endian ARGB words in plane 1.
        uint e = *(device const uint*)(s + f.plane_offset[1] + pf_c0(s, f, x, y) * 4u);
        return int3(int((e >> 16) & 0xFFu), int((e >> 8) & 0xFFu), int(e & 0xFFu));
    }
    return int3(int(pf_c0(s, f, x, y)), int(pf_c1(s, f, x, y)), int(pf_c2(s, f, x, y)));
}

// MARK: - Kernel

kernel void pf_finish(device const uchar*            src     [[buffer(0)]],
                      constant PFFrame&               f       [[buffer(1)]],
                      texture2d<uint, access::write>  out_y   [[texture(0)]],
                      texture2d<uint, access::write>  out_c   [[texture(1)]],
                      uint2                           gid     [[thread_position_in_grid]]) {
    if (gid.x >= f.chroma_width || gid.y >= f.chroma_height) { return; }
    uint cb, cr;
    if (FC_MODE == 3u) {
        // RGB goes out 4:4:4: one pixel, all three outputs from one read.
        int3 rgb = pf_rgb_codes(src, f, gid.x, gid.y);
        out_y.write(uint4(pf_container(pf_rgb_word(f, 0u, rgb), gid.x, gid.y)), gid);
        cb = pf_rgb_word(f, 1u, rgb);
        cr = pf_rgb_word(f, 2u, rgb);
    } else {
        uint2 base = gid * uint2(PF_BLOCK_W, PF_BLOCK_H);
        for (uint j = 0u; j < PF_BLOCK_H; ++j) {
            for (uint i = 0u; i < PF_BLOCK_W; ++i) {
                uint2 p = base + uint2(i, j);
                if (p.x < f.width && p.y < f.height) {
                    out_y.write(uint4(pf_container(pf_luma_word(pf_c0(src, f, p.x, p.y), FC_C0_DEPTH), p.x, p.y)), p);
                }
            }
        }
        if (FC_MODE == 2u) {
            cb = cr = 1u << (FC_TARGET_BITS - 1u + FC_FRACTION_BITS);
        } else if (FC_MODE == 1u) {
            float2 c = pf_resample(src, f, gid);
            cb = pf_resampled_word(c.x, FC_C1_DEPTH);
            cr = pf_resampled_word(c.y, FC_C2_DEPTH);
        } else {
            cb = pf_chroma_word(pf_c1(src, f, gid.x, gid.y), FC_C1_DEPTH);
            cr = pf_chroma_word(pf_c2(src, f, gid.x, gid.y), FC_C2_DEPTH);
        }
    }
    out_c.write(uint4(pf_container(cb, 2u * gid.x, gid.y), pf_container(cr, 2u * gid.x + 1u, gid.y), 0u, 0u), gid);
}
"""
}
