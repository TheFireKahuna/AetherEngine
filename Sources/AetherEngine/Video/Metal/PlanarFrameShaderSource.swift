/// Metal source for ``PlanarFrameFinisher``: a decoded picture, read in any in-memory layout FFmpeg describes,
/// written into a bi-planar display buffer.
enum PlanarFrameShaderSource {
    static let source = """
#include <metal_stdlib>
using namespace metal;

// AVComponentDescriptor, as av_read_image_line2 reads it.
struct PFComponent {
    uint plane;
    uint step;
    uint offset;
    uint shift;
    uint depth;
};

// Mirrors PlanarFrameFinisher.Params (Swift); every field is 32 bits, the float4s 16-byte aligned.
struct PFParams {
    uint width;
    uint height;
    uint out_chroma_width;
    uint out_chroma_height;
    uint src_log2_w;
    uint src_log2_h;
    uint out_log2_w;
    uint out_log2_h;
    uint flags;
    // Bits of every value before it is placed in its container: 8, 10 or 16.
    uint precision;
    // Left shift that MSB-aligns a value in its container: 16 - precision for 16-bit containers, else 0.
    uint container_shift;
    // AVChromaLocation with UNSPECIFIED already resolved.
    uint chroma_location;
    PFComponent comp[4];
    uint plane_offset[4];
    uint linesize[4];
    // RGB to Y'CbCr at `precision` bits, video range: value = dot(row.xyz, rgb) + row.w, rgb in [0, 1].
    float4 rgb_y;
    float4 rgb_cb;
    float4 rgb_cr;
};

constant uint PF_RGB = 1u;
constant uint PF_BIG_ENDIAN = 2u;
constant uint PF_BITSTREAM = 4u;
constant uint PF_PALETTE = 8u;
constant uint PF_GRAY = 16u;
constant uint PF_DITHER = 32u;

// Integer Bayer 8x8 thresholds (0...63), one sixty-fourth of a 10-bit step, by row then word.
constant ushort pf_bayer[64] = {
     0, 32,  8, 40,  2, 34, 10, 42,  48, 16, 56, 24, 50, 18, 58, 26,
    12, 44,  4, 36, 14, 46,  6, 38,  60, 28, 52, 20, 62, 30, 54, 22,
     3, 35, 11, 43,  1, 33,  9, 41,  51, 19, 59, 27, 49, 17, 57, 25,
    15, 47,  7, 39, 13, 45,  5, 37,  63, 31, 55, 23, 61, 29, 53, 21,
};

// Component `c` of the sample at (x, y) of that component's own grid, exactly as av_read_image_line2 reads it.
static inline uint pf_read(device const uchar* src, constant PFParams& p, uint c, uint x, uint y) {
    PFComponent k = p.comp[c];
    device const uchar* row = src + p.plane_offset[k.plane] + y * p.linesize[k.plane];
    uint mask = k.depth >= 32u ? 0xFFFFFFFFu : ((1u << k.depth) - 1u);
    if ((p.flags & PF_BITSTREAM) != 0u) {
        if (k.step > 8u) {
            device const uchar* q = row + x * 4u;
            uint v = (uint(q[0]) << 24) | (uint(q[1]) << 16) | (uint(q[2]) << 8) | uint(q[3]);
            return (v >> k.offset) & mask;
        }
        uint skip = x * k.step + k.offset;
        int shift = 8 - int(k.depth) - int(skip & 7u);
        return (uint(row[skip >> 3]) >> uint(shift)) & mask;
    }
    device const uchar* q = row + x * k.step + k.offset;
    bool big = (p.flags & PF_BIG_ENDIAN) != 0u;
    uint bits = k.shift + k.depth;
    uint v;
    if (bits <= 8u) {
        v = uint(q[big ? 1 : 0]);
    } else if (bits <= 16u) {
        v = big ? (uint(q[0]) << 8 | uint(q[1])) : (uint(q[1]) << 8 | uint(q[0]));
    } else {
        v = big ? (uint(q[0]) << 24 | uint(q[1]) << 16 | uint(q[2]) << 8 | uint(q[3]))
                : (uint(q[3]) << 24 | uint(q[2]) << 16 | uint(q[1]) << 8 | uint(q[0]));
    }
    return (v >> k.shift) & mask;
}

// R, G, B in [0, 1] at (x, y): an RGB format's three components, or a palette entry (native-endian ARGB).
static inline float3 pf_rgb(device const uchar* src, constant PFParams& p, uint x, uint y) {
    if ((p.flags & PF_PALETTE) != 0u) {
        uint index = pf_read(src, p, 0u, x, y);
        device const uchar* e = src + p.plane_offset[1] + index * 4u;
        return float3(float(e[2]), float(e[1]), float(e[0])) / 255.0f;
    }
    return float3(float(pf_read(src, p, 0u, x, y)) / float((1u << p.comp[0].depth) - 1u),
                  float(pf_read(src, p, 1u, x, y)) / float((1u << p.comp[1].depth) - 1u),
                  float(pf_read(src, p, 2u, x, y)) / float((1u << p.comp[2].depth) - 1u));
}

// A value at `precision` bits into its container word, ordered down to 10 bits when PF_DITHER: the threshold is
// added to the 16-bit word before its low six bits are cleared, saturating at the top code.
static inline uint pf_word(uint value, constant PFParams& p, uint word_x, uint y) {
    uint w = value << p.container_shift;
    if ((p.flags & PF_DITHER) != 0u) {
        uint sum = w + uint(pf_bayer[(y & 7u) * 8u + (word_x & 7u)]);
        w = sum > 0xFFFFu ? 0xFFC0u : (sum & 0xFFC0u);
    }
    return w;
}

// A component sample, `depth` bits, raised to `precision`.
static inline uint pf_raise(uint v, uint depth, constant PFParams& p) {
    return v << (p.precision - depth);
}

static inline uint pf_quantise(float v, constant PFParams& p) {
    return uint(clamp(floor(v + 0.5f), 0.0f, float((1u << p.precision) - 1u)));
}

// Where chroma sample i sits on one axis, in luma samples, for a plane subsampled by 2^log2 there. Horizontal:
// co-sited with the left luma sample (LEFT / TOPLEFT / BOTTOMLEFT) or centred between the samples it covers.
// Vertical: on the top row (TOP / TOPLEFT), centred (LEFT / CENTER), or on the bottom row (BOTTOM / BOTTOMLEFT).
static inline float pf_site(uint i, uint log2, bool vertical, uint location) {
    float r = float(1u << log2);
    float span = r - 1.0f;
    float offset;
    if (!vertical) {
        offset = (location == 1u || location == 3u || location == 5u) ? 0.0f : span * 0.5f;
    } else {
        offset = (location == 3u || location == 4u) ? 0.0f : ((location == 5u || location == 6u) ? span : span * 0.5f);
    }
    return float(i) * r + offset;
}

// Catmull-Rom (cubic B = 0, C = 0.5) weights at fraction t over samples -1, 0, 1, 2. t = 0 is the sample itself;
// t = 1/4 gives (-9, 111, 29, -3) / 128, the taps DoviFelComposer's 4:2:2 kernel uses.
static inline float4 pf_cubic(float t) {
    float t2 = t * t, t3 = t2 * t;
    return float4((-t3 + 2.0f * t2 - t) * 0.5f,
                  (3.0f * t3 - 5.0f * t2 + 2.0f) * 0.5f,
                  (-3.0f * t3 + 4.0f * t2 + t) * 0.5f,
                  (t3 - t2) * 0.5f);
}

// Source chroma (components 1 and 2) at output chroma sample (x, y), in source units, resampled where the output
// keeps more chroma than the source.
static inline float2 pf_chroma(device const uchar* src, constant PFParams& p, uint x, uint y) {
    uint src_w = (p.width + (1u << p.src_log2_w) - 1u) >> p.src_log2_w;
    uint src_h = (p.height + (1u << p.src_log2_h) - 1u) >> p.src_log2_h;
    float ux = (pf_site(x, p.out_log2_w, false, p.chroma_location) - pf_site(0u, p.src_log2_w, false, p.chroma_location))
             / float(1u << p.src_log2_w);
    float uy = (pf_site(y, p.out_log2_h, true, p.chroma_location) - pf_site(0u, p.src_log2_h, true, p.chroma_location))
             / float(1u << p.src_log2_h);
    float fx = floor(ux), fy = floor(uy);
    float tx = ux - fx, ty = uy - fy;
    int x0 = int(fx), y0 = int(fy);
    if (tx == 0.0f && ty == 0.0f) {
        uint sx = uint(clamp(x0, 0, int(src_w) - 1)), sy = uint(clamp(y0, 0, int(src_h) - 1));
        return float2(float(pf_read(src, p, 1u, sx, sy)), float(pf_read(src, p, 2u, sx, sy)));
    }
    float4 wx = tx == 0.0f ? float4(0, 1, 0, 0) : pf_cubic(tx);
    float4 wy = ty == 0.0f ? float4(0, 1, 0, 0) : pf_cubic(ty);
    float2 sum = float2(0.0f);
    for (int j = 0; j < 4; ++j) {
        if (wy[j] == 0.0f) { continue; }
        uint sy = uint(clamp(y0 - 1 + j, 0, int(src_h) - 1));
        float2 rowsum = float2(0.0f);
        for (int i = 0; i < 4; ++i) {
            if (wx[i] == 0.0f) { continue; }
            uint sx = uint(clamp(x0 - 1 + i, 0, int(src_w) - 1));
            rowsum += wx[i] * float2(float(pf_read(src, p, 1u, sx, sy)), float(pf_read(src, p, 2u, sx, sy)));
        }
        sum += wy[j] * rowsum;
    }
    return sum;
}

kernel void pf_luma(device const uchar*              src     [[buffer(0)]],
                    constant PFParams&                p       [[buffer(1)]],
                    texture2d<uint, access::write>    out_y   [[texture(0)]],
                    uint2                             gid     [[thread_position_in_grid]]) {
    if (gid.x >= p.width || gid.y >= p.height) { return; }
    uint value;
    if ((p.flags & (PF_RGB | PF_PALETTE)) != 0u) {
        float3 rgb = pf_rgb(src, p, gid.x, gid.y);
        value = pf_quantise(dot(p.rgb_y.xyz, rgb) + p.rgb_y.w, p);
    } else {
        value = pf_raise(pf_read(src, p, 0u, gid.x, gid.y), p.comp[0].depth, p);
    }
    out_y.write(uint4(pf_word(value, p, gid.x, gid.y), 0, 0, 0), gid);
}

kernel void pf_chroma_kernel(device const uchar*           src     [[buffer(0)]],
                             constant PFParams&             p       [[buffer(1)]],
                             texture2d<uint, access::write> out_uv  [[texture(0)]],
                             uint2                          gid     [[thread_position_in_grid]]) {
    if (gid.x >= p.out_chroma_width || gid.y >= p.out_chroma_height) { return; }
    uint cb, cr;
    if ((p.flags & PF_GRAY) != 0u) {
        cb = cr = 1u << (p.precision - 1u);
    } else if ((p.flags & (PF_RGB | PF_PALETTE)) != 0u) {
        // RGB goes out 4:4:4, so the chroma grid is the pixel grid.
        float3 rgb = pf_rgb(src, p, gid.x, gid.y);
        cb = pf_quantise(dot(p.rgb_cb.xyz, rgb) + p.rgb_cb.w, p);
        cr = pf_quantise(dot(p.rgb_cr.xyz, rgb) + p.rgb_cr.w, p);
    } else if (p.src_log2_w == p.out_log2_w && p.src_log2_h == p.out_log2_h) {
        cb = pf_raise(pf_read(src, p, 1u, gid.x, gid.y), p.comp[1].depth, p);
        cr = pf_raise(pf_read(src, p, 2u, gid.x, gid.y), p.comp[2].depth, p);
    } else {
        // Resampled in source units, then raised: the extra bits of a wider container keep the filter's fraction.
        float2 c = pf_chroma(src, p, gid.x, gid.y);
        float2 top = float2(float((1u << p.comp[1].depth) - 1u), float((1u << p.comp[2].depth) - 1u));
        c = clamp(c, float2(0.0f), top);
        cb = pf_quantise(c.x * float(1u << (p.precision - p.comp[1].depth)), p);
        cr = pf_quantise(c.y * float(1u << (p.precision - p.comp[2].depth)), p);
    }
    out_uv.write(uint4(pf_word(cb, p, 2u * gid.x, gid.y), pf_word(cr, p, 2u * gid.x + 1u, gid.y), 0, 0), gid);
}
"""
}
