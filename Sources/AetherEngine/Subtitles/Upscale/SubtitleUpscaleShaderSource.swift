import Foundation

/// Metal source for ``SubtitleUpscaler``: ArtCNN (``ArtCNNNetwork``) run on a subtitle bitmap's alpha and
/// premultiplied-luma planes, then recombined with bilinear chroma into a 2x premultiplied RGBA picture.
///
/// Region. The picture is a crop of a transparent canvas: the output depends on its content alone, not on where the
/// crop's edges fall. The network runs on the content bounds (the whole picture without bounds) grown by S + 6
/// pixels, which may reach past the picture; outside the region every output pixel is transparent. Coordinates
/// below are the region's unless they say picture; texture reads add `origin` and read transparency outside the
/// picture, and only picture pixels are written.
///
/// Layout. Every per-pixel buffer is a padded raster of one band of the region: row pitch `wp` pixels, eight zero
/// columns before column 0, the region's columns rounded up to the 8-pixel unit, eight more columns, and one zero row
/// above and below the band. A feature map stores its channels innermost (`[row][x][channel]`, half), so eight
/// consecutive pixels of eight consecutive channels are an 8x8 matrix with row stride `channels`, which is what
/// `simdgroup_load` reads. The pad pixels stay zero, so a 3x3 tap needs no bounds check; at the region's edge that is
/// ArtCNN's zero padding (Keras `padding="same"`), which reaches only pixels the composite discards.
///
/// Work. A unit is 8 pixels of one row. The output keeps only pixels within S (the support radius, 5 by default)
/// of a pixel with non-zero alpha; everything else is exactly transparent. The network's receptive field is 7
/// pixels, but what it adds farther than 4 or 5 pixels from content is its zero-input response (under 0.002, below
/// an 8-bit step), the haze the cut removes. The mask passes measure each unit's Chebyshev distance to content, and
/// layer L (0...6) runs only on units within S + 6 - L of it. A pixel within S + 6 - L reads only neighbours within
/// S + 7 - L, which layer L - 1 computed, so the kept pixels are exact whatever the skipped units hold. The
/// convolutions are 8x8x8 `simdgroup_matrix` products: per tap and per block of 8 input channels, an 8-pixel x
/// 8-channel slice of the input map times an 8x8 block of the kernel, accumulated in float.
enum SubtitleUpscaleShaderSource {
    static let source = """
#include <metal_stdlib>
using namespace metal;

struct UpGeom {
    uint width;          // region width
    uint height;         // region height
    uint wp;             // padded row pitch in pixels
    uint unitsX;         // ceil(width / 8)
    int row0;            // region row of band row 0
    uint rows;           // band rows
    uint outRow0;        // region rows the composite writes: [outRow0, outRow1)
    uint outRow1;
    uint featureStride;  // elements from one plane's feature map to the next
    uint pixelStride;    // pixels from one plane's 1-channel raster to the next (also the 4-channel output's)
    uint wordsX;         // ceil(width / 32)
    uint listCapacity;   // entries per layer list
    uint skip;           // 0 computes every unit (the mask still applies)
    uint straightAlpha;  // the source's colour is not premultiplied
    int originX;         // picture position of the region
    int originY;
    uint pictureWidth;
    uint pictureHeight;
    uint support;        // S: output pixels farther than S from content are transparent (1...7)
};

// BT.709 luma weights. Any weights that sum to 1 work: chroma is colour minus luma, so it is recombined exactly.
constant float3 UP_LUMA = float3(0.2126f, 0.7152f, 0.0722f);

static inline float4 up_premultiplied(float4 c, constant UpGeom& g) {
    return g.straightAlpha != 0 ? float4(c.rgb * c.a, c.a) : c;
}

// The source at region position (x, y), premultiplied; transparent outside the picture.
static inline float4 up_source(texture2d<float, access::read> src, constant UpGeom& g, int x, int y) {
    const int px = x + g.originX, py = y + g.originY;
    if (px < 0 || py < 0 || px >= int(g.pictureWidth) || py >= int(g.pictureHeight)) return float4(0.0f);
    return up_premultiplied(src.read(uint2(uint(px), uint(py))), g);
}

static inline uint up_pixel(constant UpGeom& g, int bandRow, int x) {
    return uint(bandRow + 1) * g.wp + uint(x + 8);
}

// MARK: - Content mask

// Bit i of word (w, y): pixel (32w + i, y) has non-zero alpha. One thread per pixel; a simdgroup is one word (the
// threadgroup is 32 wide), gathered with a ballot.
kernel void up_mask_bits(texture2d<float, access::read> src [[texture(0)]],
                         device uint* bits [[buffer(0)]],
                         constant UpGeom& g [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]],
                         ushort lane [[thread_index_in_simdgroup]]) {
    const bool row = gid.y < g.height;
    const bool set = row && gid.x < g.width && up_source(src, g, int(gid.x), int(gid.y)).a > 0.0f;
    const uint word = uint(uint64_t(simd_ballot(set)));
    if (lane == 0 && row && gid.x / 32 < g.wordsX) bits[gid.y * g.wordsX + gid.x / 32] = word;
}

// Row dilations by S...S + 6 pixels: rows[t - S][y][w].
kernel void up_mask_rows(device const uint* bits [[buffer(0)]],
                         device uint* rows [[buffer(1)]],
                         constant UpGeom& g [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.wordsX || gid.y >= g.height) return;
    device const uint* row = bits + gid.y * g.wordsX;
    const uint m = row[gid.x];
    const uint l = gid.x > 0 ? row[gid.x - 1] : 0u;
    const uint r = gid.x + 1 < g.wordsX ? row[gid.x + 1] : 0u;
    const ulong left = (ulong(m) << 32) | ulong(l);
    const ulong right = (ulong(r) << 32) | ulong(m);
    uint h = m;
    const uint plane = g.height * g.wordsX;
    for (uint k = 1; k <= g.support + 6; k++) {
        h |= uint(right >> k) | uint(left >> (32 - k));
        if (k >= g.support) rows[(k - g.support) * plane + gid.y * g.wordsX + gid.x] = h;
    }
}

// Column dilations, one thread per word, row and distance t = S + gid.z: square[t - S][y][w] has bit i set when
// pixel (32w + i, y) is within Chebyshev distance t of content. Plane 0 is the composite's support; layer L runs on
// the units plane 6 - L touches.
kernel void up_mask_columns(device const uint* rows [[buffer(0)]],
                            device uint* square [[buffer(1)]],
                            constant UpGeom& g [[buffer(2)]],
                            uint3 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.wordsX || gid.y >= g.height || gid.z >= 7) return;
    const uint plane = g.height * g.wordsX;
    const int t = int(g.support + gid.z);
    const int y0 = max(int(gid.y) - t, 0);
    const int y1 = min(int(gid.y) + t, int(g.height) - 1);
    device const uint* column = rows + gid.z * plane + gid.x;
    uint acc = 0;
    for (int y = y0; y <= y1; y++) acc |= column[uint(y) * g.wordsX];
    square[gid.z * plane + gid.y * g.wordsX + gid.x] = acc;
}

// MARK: - Band setup

kernel void up_band_reset(device atomic_uint* counts [[buffer(0)]], uint tid [[thread_position_in_grid]]) {
    if (tid < 8) atomic_store_explicit(&counts[tid], 0u, memory_order_relaxed);
}

// Appends each of the band's units to the lists of the layers it takes part in. Entry: row << 16 | unit column.
kernel void up_band_lists(device const uint* square [[buffer(0)]],
                          device uint* lists [[buffer(1)]],
                          device atomic_uint* counts [[buffer(2)]],
                          constant UpGeom& g [[buffer(3)]],
                          uint tid [[thread_position_in_grid]]) {
    const uint total = g.rows * g.unitsX;
    const bool valid = tid < total;
    const uint ry = valid ? tid / g.unitsX : 0u;
    const uint ux = valid ? tid - ry * g.unitsX : 0u;
    uint level = 0;
    if (valid) {
        if (g.skip == 0) {
            level = 7;
        } else {
            device const uint* word = square + uint(g.row0 + int(ry)) * g.wordsX + ux / 4;
            const uint shift = 8 * (ux % 4);
            const uint plane = g.height * g.wordsX;
            for (uint layer = 0; layer < 7; layer++) {
                if (((word[(6 - layer) * plane] >> shift) & 0xffu) != 0) level = layer + 1;
            }
        }
    }
    for (uint layer = 0; layer < 7; layer++) {
        const bool take = level > layer;
        const uint offset = simd_prefix_exclusive_sum(uint(take));
        const uint taken = simd_sum(uint(take));
        if (taken == 0) continue;
        uint start = 0;
        if (simd_is_first()) start = atomic_fetch_add_explicit(&counts[layer], taken, memory_order_relaxed);
        start = simd_broadcast_first(start);
        if (take) lists[layer * g.listCapacity + start + offset] = (ry << 16) | ux;
    }
}

// Threadgroup counts for each layer's indirect dispatch. Slot 3L + k: k 0 serves both planes with one model (y 2),
// k 1 the alpha plane alone, k 2 the luma plane alone (y 1); `unitsPerGroup` is per slot.
kernel void up_band_arguments(device const uint* counts [[buffer(0)]],
                              device uint* arguments [[buffer(1)]],
                              constant uint* unitsPerGroup [[buffer(2)]],
                              uint tid [[thread_position_in_grid]]) {
    if (tid >= 21) return;
    const uint layer = tid / 3;
    device uint* a = arguments + tid * 3;
    a[0] = (counts[layer] + unitsPerGroup[tid] - 1) / unitsPerGroup[tid];
    a[1] = tid % 3 == 0 ? 2u : 1u;
    a[2] = 1;
}

// The alpha (plane 0) and premultiplied luma (plane 1) rasters of the band, pads included, zero outside the region.
kernel void up_planes(texture2d<float, access::read> src [[texture(0)]],
                      device half* planes [[buffer(0)]],
                      constant UpGeom& g [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.wp || gid.y >= g.rows + 2) return;
    const int x = int(gid.x) - 8;
    const int y = g.row0 + int(gid.y) - 1;
    float a = 0.0f, l = 0.0f;
    // The pad rows hold the picture rows beyond the band (zero beyond the region): layer 0 and the residual read
    // them, so the band's first and last rows are as exact as the overlap needs.
    if (x >= 0 && x < int(g.width) && y >= 0 && y < int(g.height)) {
        const float4 c = up_source(src, g, x, y);
        a = c.a;
        l = dot(c.rgb, UP_LUMA);
    }
    const uint i = gid.y * g.wp + gid.x;
    planes[i] = half(a);
    planes[g.pixelStride + i] = half(l);
}

// Zeroes the feature maps' pad pixels a layer can read: the rows above and below the band, column -1 and the column
// after the last unit. gid.y = 2 * map + plane over the maps [P0, P1, Q0, Q1], `featureStride` apart; `channels`
// per plane.
kernel void up_clear_pads(device half* maps [[buffer(0)]],
                          constant UpGeom& g [[buffer(1)]],
                          constant uint2& channels [[buffer(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    const uint horizontal = 2 * g.wp;
    const uint n = horizontal + 2 * g.rows;
    if (gid.x >= n || gid.y >= 4) return;
    uint pixel;
    if (gid.x < horizontal) {
        const uint row = gid.x < g.wp ? 0u : g.rows + 1;
        pixel = row * g.wp + (gid.x % g.wp);
    } else {
        const uint k = gid.x - horizontal;
        const uint row = 1 + k / 2;
        pixel = row * g.wp + ((k & 1) == 0 ? 7u : 8u + 8u * g.unitsX);
    }
    const uint c = channels[gid.y & 1];
    device half* p = maps + gid.y * g.featureStride + pixel * c;
    for (uint i = 0; i < c; i++) p[i] = 0.0h;
}

// MARK: - Network

// Layer 0, 1 -> C channels: one thread per pixel and block of 8 output channels. `w0` is [C][10]: nine taps (row-major)
// and the bias.
template <uint C>
kernel void up_conv_first(device const half* planes [[buffer(0)]],
                          device half* out [[buffer(1)]],
                          device const float* w0 [[buffer(2)]],
                          device const uint* list [[buffer(3)]],
                          device const uint* count [[buffer(4)]],
                          constant UpGeom& g [[buffer(5)]],
                          constant uint& planeBase [[buffer(6)]],
                          uint2 tg [[threadgroup_position_in_grid]],
                          uint2 tptg [[threads_per_threadgroup]],
                          uint ti [[thread_index_in_threadgroup]]) {
    constexpr uint CB = C / 8;
    const uint t = tg.x * tptg.x + ti;
    const uint entry = t / (8 * CB);
    if (entry >= count[0]) return;
    const uint local = t - entry * 8 * CB;
    const uint px = local / CB;
    const uint cb = local - px * CB;
    const uint e = list[entry];
    const uint ry = e >> 16, ux = e & 0xffffu;
    const uint x = ux * 8 + px;
    const uint plane = planeBase + tg.y;
    device half* o = out + plane * g.featureStride + up_pixel(g, int(ry), int(x)) * C + cb * 8;
    if (x >= g.width) {
        *(device half4*)o = half4(0.0h);
        *(device half4*)(o + 4) = half4(0.0h);
        return;
    }
    device const half* p = planes + plane * g.pixelStride + up_pixel(g, int(ry), int(x));
    float v[9];
    for (uint ky = 0; ky < 3; ky++)
        for (uint kx = 0; kx < 3; kx++) v[ky * 3 + kx] = float(p[(int(ky) - 1) * int(g.wp) + int(kx) - 1]);
    float r[8];
    for (uint j = 0; j < 8; j++) {
        device const float* w = w0 + (cb * 8 + j) * 10;
        float s = w[9];
        for (uint k = 0; k < 9; k++) s = fma(w[k], v[k], s);
        r[j] = s;
    }
    *(device half4*)o = half4(r[0], r[1], r[2], r[3]);
    *(device half4*)(o + 4) = half4(r[4], r[5], r[6], r[7]);
}

// Layers 1...6, CIN -> COUT, as 8x8x8 matrix products: MB units (list entries `first`...) per simdgroup.
// MODE 0: ReLU. MODE 1: no activation, plus layer 0's output recomputed from the plane (the residual; layer 5).
// MODE 2: the last layer, COUT 4 padded to one 8-wide block, written as the 2x2 sub-pixels [row][x][4].
// `w` holds the kernel as 8x8 blocks [tap][cin / 8][cout / 8][8 cin][8 cout]; `bias` the bias, [cout]. T is the
// accumulator type.
struct UpConvArgs {
    device const half* in;
    device half* out;
    device const float* bias;
    device const uint* list;
    uint n;
    uint plane;
    device const half* planes;
    device const float* w0;
};

template <uint CIN, uint COUT, uint MB, uint MODE, typename T, typename W>
static inline void up_conv_units(thread const UpConvArgs& args, W w, constant UpGeom& g, uint first, ushort lane) {
    constexpr uint CB = CIN / 8;
    constexpr uint OB = (COUT + 7) / 8;
    const uint n = args.n;
    device const half* in = args.in + args.plane * g.featureStride;

    // The two elements a lane owns: row fm (the pixel), columns fn and fn + 1 (the channels).
    const ushort qid = lane / 4;
    const ushort fm = (qid & 4) + ((lane / 2) % 4);
    const ushort fn = (qid & 2) * 2 + (lane % 2) * 2;

    uint entries[MB];
    uint base[MB];
    for (uint m = 0; m < MB; m++) {
        entries[m] = args.list[min(first + m, n - 1)];
        const uint ry = entries[m] >> 16, ux = entries[m] & 0xffffu;
        // Tap (0, 0) of the unit's first pixel: band row ry - 1, column 8ux - 1.
        base[m] = (ry * g.wp + ux * 8 + 7) * CIN;
    }

    // Zero-initialised: the bias is added in the epilogue, which keeps the accumulators out of per-lane writes.
    simdgroup_matrix<T, 8, 8> acc[MB][OB];
    for (uint ob = 0; ob < OB; ob++)
        for (uint m = 0; m < MB; m++) acc[m][ob] = simdgroup_matrix<T, 8, 8>(T(0));

    for (uint ky = 0; ky < 3; ky++) {
        for (uint kx = 0; kx < 3; kx++) {
            const uint tapOffset = (ky * g.wp + kx) * CIN;
            W wt = w + (ky * 3 + kx) * CB * OB * 64;
            for (uint cb = 0; cb < CB; cb++) {
                simdgroup_half8x8 a[MB];
                for (uint m = 0; m < MB; m++) simdgroup_load(a[m], in + base[m] + tapOffset + cb * 8, CIN);
                for (uint ob = 0; ob < OB; ob++) {
                    simdgroup_half8x8 b;
                    simdgroup_load(b, wt + (cb * OB + ob) * 64, 8);
                    for (uint m = 0; m < MB; m++) simdgroup_multiply_accumulate(acc[m][ob], a[m], b, acc[m][ob]);
                }
            }
        }
    }

    for (uint m = 0; m < MB; m++) {
        if (first + m >= n) break;
        const uint ry = entries[m] >> 16, ux = entries[m] & 0xffffu;
        const uint x = ux * 8 + fm;
        const bool inside = x < g.width;
        const uint pixel = up_pixel(g, int(ry), int(x));
        float v9[9];
        if (MODE == 1) {
            device const half* p = args.planes + args.plane * g.pixelStride + pixel;
            for (uint ky = 0; ky < 3; ky++)
                for (uint kx = 0; kx < 3; kx++) v9[ky * 3 + kx] = float(p[(int(ky) - 1) * int(g.wp) + int(kx) - 1]);
        }
        for (uint ob = 0; ob < OB; ob++) {
            const uint c = ob * 8 + fn;
            float2 v = float2(float(acc[m][ob].thread_elements()[0]), float(acc[m][ob].thread_elements()[1]));
            if (c < COUT) v += float2(args.bias[c], args.bias[c + 1]);
            if (MODE == 1) {
                for (uint j = 0; j < 2; j++) {
                    device const float* k0 = args.w0 + (c + j) * 10;
                    float s = k0[9];
                    for (uint k = 0; k < 9; k++) s = fma(k0[k], v9[k], s);
                    v[j] += s;
                }
            }
            if (MODE == 0) v = max(v, 0.0f);
            if (!inside) v = 0.0f;
            if (MODE == 2) {
                if (c < 4) *(device half2*)(args.out + args.plane * g.pixelStride * 4 + pixel * 4 + c) = half2(v);
            } else {
                *(device half2*)(args.out + args.plane * g.featureStride + pixel * COUT + c) = half2(v);
            }
        }
    }
}

// One batch of MB units per simdgroup, the kernel read from device memory; dispatched indirectly to the list's size.
template <uint CIN, uint COUT, uint MB, uint MODE, typename T>
kernel void up_conv(device const half* in [[buffer(0)]],
                    device half* out [[buffer(1)]],
                    device const half* wts [[buffer(2)]],
                    device const float* bias [[buffer(3)]],
                    device const uint* list [[buffer(4)]],
                    device const uint* count [[buffer(5)]],
                    constant UpGeom& g [[buffer(6)]],
                    constant uint& planeBase [[buffer(7)]],
                    device const half* planes [[buffer(8)]],
                    device const float* w0 [[buffer(9)]],
                    uint2 tg [[threadgroup_position_in_grid]],
                    ushort sgi [[simdgroup_index_in_threadgroup]],
                    ushort sgs [[simdgroups_per_threadgroup]],
                    ushort lane [[thread_index_in_simdgroup]]) {
    const uint n = count[0];
    const uint first = (tg.x * sgs + sgi) * MB;
    if (first >= n) return;
    const UpConvArgs args = { in, out, bias, list, n, planeBase + tg.y, planes, w0 };
    up_conv_units<CIN, COUT, MB, MODE, T>(args, wts, g, first, lane);
}

// Persistent threadgroups: each copies the layer's kernel into threadgroup memory once, then its simdgroups walk the
// list MB units at a time.
template <uint CIN, uint COUT, uint MB, uint MODE, typename T>
kernel void up_conv_tg(device const half* in [[buffer(0)]],
                       device half* out [[buffer(1)]],
                       device const half* wts [[buffer(2)]],
                       device const float* bias [[buffer(3)]],
                       device const uint* list [[buffer(4)]],
                       device const uint* count [[buffer(5)]],
                       constant UpGeom& g [[buffer(6)]],
                       constant uint& planeBase [[buffer(7)]],
                       device const half* planes [[buffer(8)]],
                       device const float* w0 [[buffer(9)]],
                       uint2 tg [[threadgroup_position_in_grid]],
                       uint2 groups [[threadgroups_per_grid]],
                       ushort ti [[thread_index_in_threadgroup]],
                       uint2 tn [[threads_per_threadgroup]],
                       ushort sgi [[simdgroup_index_in_threadgroup]],
                       ushort sgs [[simdgroups_per_threadgroup]],
                       ushort lane [[thread_index_in_simdgroup]]) {
    constexpr uint SIZE = 9 * (CIN / 8) * ((COUT + 7) / 8) * 64;
    threadgroup half shared[SIZE];
    for (uint i = ti; i < SIZE / 4; i += tn.x) ((threadgroup half4*)shared)[i] = ((device const half4*)wts)[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint n = count[0];
    const UpConvArgs args = { in, out, bias, list, n, planeBase + tg.y, planes, w0 };
    for (uint first = (tg.x * sgs + sgi) * MB; first < n; first += groups.x * sgs * MB) {
        up_conv_units<CIN, COUT, MB, MODE, T>(args, (threadgroup const half*)shared, g, first, lane);
    }
}

template [[host_name("up_conv_first_16")]] kernel void up_conv_first<16>(device const half*, device half*, device const float*, device const uint*, device const uint*, constant UpGeom&, constant uint&, uint2, uint2, uint);
template [[host_name("up_conv_first_32")]] kernel void up_conv_first<32>(device const half*, device half*, device const float*, device const uint*, device const uint*, constant UpGeom&, constant uint&, uint2, uint2, uint);

#define UP_CONV(K, C, CO, MB, MODE, T, TN) \\
template [[host_name(#K "_" #C "_" #CO "_m" #MB "_" #MODE "_" #TN)]] kernel void K<C, CO, MB, MODE, T>( \\
    device const half*, device half*, device const half*, device const float*, device const uint*, device const uint*, \\
    constant UpGeom&, constant uint&, device const half*, device const float*, uint2, ushort, ushort, ushort);
#define UP_CONV_TG(C, CO, MB, MODE, T, TN) \\
template [[host_name("up_conv_tg_" #C "_" #CO "_m" #MB "_" #MODE "_" #TN)]] kernel void up_conv_tg<C, CO, MB, MODE, T>( \\
    device const half*, device half*, device const half*, device const float*, device const uint*, device const uint*, \\
    constant UpGeom&, constant uint&, device const half*, device const float*, uint2, uint2, ushort, uint2, ushort, ushort, ushort);
/*UP_CONV_INSTANCES*/

// MARK: - Composite

// One source pixel's 2x2 output block: the networks' alpha and premultiplied luma (sub-pixel 2j + i), plus the
// source's chroma interpolated bilinearly (alpha-weighted, so the colour of transparent pixels never bleeds in) and
// scaled by the new alpha. Alpha is clamped to [0, 1] and colour to [0, alpha], which removes the networks' overshoot
// halos. (x, y) is a region position.
static inline void up_write_block(texture2d<float, access::read> src, texture2d<float, access::write> dst,
                                  constant UpGeom& g, uint x, uint y, half4 alpha, half4 luma) {
    const uint2 o = uint2(2 * (int(x) + g.originX), 2 * (int(y) + g.originY));
    float4 n[3][3];
    for (int dy = -1; dy <= 1; dy++)
        for (int dx = -1; dx <= 1; dx++) n[dy + 1][dx + 1] = up_source(src, g, int(x) + dx, int(y) + dy);
    for (uint j = 0; j < 2; j++) {
        for (uint i = 0; i < 2; i++) {
            // Sub-pixel (i, j) sits a quarter pixel towards neighbour (2i - 1, 2j - 1): weights 3/4 and 1/4 per axis.
            const uint nx = 2 * i, ny = 2 * j;
            const float4 c = (9.0f * n[1][1] + 3.0f * n[1][nx] + 3.0f * n[ny][1] + n[ny][nx]) * (1.0f / 16.0f);
            const float3 chroma = c.a > (1.0f / 1024.0f) ? (c.rgb - dot(c.rgb, UP_LUMA)) / c.a : float3(0.0f);
            const float a = clamp(float(alpha[j * 2 + i]), 0.0f, 1.0f);
            // Both networks' outputs clamped to [0, 1], as ArtCNN's last step does.
            const float3 rgb = clamp(saturate(float(luma[j * 2 + i])) + a * chroma, 0.0f, a);
            dst.write(float4(rgb, a), o + uint2(i, j));
        }
    }
}

static inline bool up_supported(device const uint* support, constant UpGeom& g, uint x, uint y) {
    return ((support[y * g.wordsX + x / 32] >> (x % 32)) & 1u) != 0;
}

static inline bool up_in_picture(constant UpGeom& g, uint x, uint y) {
    const int px = int(x) + g.originX, py = int(y) + g.originY;
    return px >= 0 && py >= 0 && px < int(g.pictureWidth) && py < int(g.pictureHeight);
}

static inline void up_write_clear(texture2d<float, access::write> dst, constant UpGeom& g, uint x, uint y) {
    const uint2 o = uint2(2 * (int(x) + g.originX), 2 * (int(y) + g.originY));
    for (uint j = 0; j < 2; j++)
        for (uint i = 0; i < 2; i++) dst.write(float4(0.0f), o + uint2(i, j));
}

// The composite of one band from the GPU networks' sub-pixel rasters. Pixels outside the S-pixel support of content
// are exactly transparent.
kernel void up_composite(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         device const half* outputs [[buffer(0)]],
                         device const uint* support [[buffer(1)]],
                         constant UpGeom& g [[buffer(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    const uint x = gid.x;
    const uint y = g.outRow0 + gid.y;
    if (x >= g.width || y >= g.outRow1 || !up_in_picture(g, x, y)) return;
    if (!up_supported(support, g, x, y)) return up_write_clear(dst, g, x, y);
    const uint pixel = up_pixel(g, int(y) - g.row0, int(x));
    up_write_block(src, dst, g, x, y, *(device const half4*)(outputs + pixel * 4),
                   *(device const half4*)(outputs + g.pixelStride * 4 + pixel * 4));
}

// MARK: - Neural Engine tiles

// One window of the kept area's grid (SubtitleUpscaleTilePlan): its picture position, and the part of its core the
// composite writes (the core within the kept area), in picture coordinates. The window is the core plus the
// network's 7-pixel reach, transparent where it leaves the picture.
struct UpWindow {
    int x;
    int y;
    int coreX;
    int coreY;
    uint coreWidth;
    uint coreHeight;
};

// One window's model input, alpha and premultiplied luma, into its two IOSurface textures. Dispatched over the window.
kernel void up_tile_gather(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<half, access::write> alpha [[texture(1)]],
                           texture2d<half, access::write> luma [[texture(2)]],
                           constant UpGeom& g [[buffer(0)]],
                           constant UpWindow& w [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= alpha.get_width() || gid.y >= alpha.get_height()) return;
    const int2 p = int2(w.x, w.y) + int2(gid);
    float4 c = 0.0f;
    if (p.x >= 0 && p.y >= 0 && p.x < int(g.pictureWidth) && p.y < int(g.pictureHeight))
        c = up_premultiplied(src.read(uint2(p)), g);
    alpha.write(half4(half(c.a)), gid);
    luma.write(half4(half(dot(c.rgb, UP_LUMA))), gid);
}

// One window's composite over its core: the models' outputs are its two IOSurface textures, the four sub-pixel
// channels stacked, channel 2 * j + i (output pixel (2x + i, 2y + j)) from row (2 * j + i) * window height.
kernel void up_composite_tiles(texture2d<float, access::read> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               texture2d<half, access::read> alpha [[texture(2)]],
                               texture2d<half, access::read> luma [[texture(3)]],
                               device const uint* support [[buffer(0)]],
                               constant UpGeom& g [[buffer(1)]],
                               constant UpWindow& w [[buffer(2)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= w.coreWidth || gid.y >= w.coreHeight) return;
    const int px = w.coreX + int(gid.x), py = w.coreY + int(gid.y);
    const uint x = uint(px - g.originX), y = uint(py - g.originY);
    if (!up_supported(support, g, x, y)) return up_write_clear(dst, g, x, y);
    const uint2 t = uint2(uint(px - w.x), uint(py - w.y));
    const uint h = alpha.get_height() / 4;
    half4 a, l;
    for (uint k = 0; k < 4; k++) {
        a[k] = alpha.read(t + uint2(0, k * h)).r;
        l[k] = luma.read(t + uint2(0, k * h)).r;
    }
    up_write_block(src, dst, g, x, y, a, l);
}

// Transparency for the destination outside the rectangle `g` names (origin and size; the region, or the Neural Engine
// backend's kept area): one thread per 2x2 output block.
kernel void up_clear_outside(texture2d<float, access::write> dst [[texture(0)]],
                             constant UpGeom& g [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= g.pictureWidth || gid.y >= g.pictureHeight) return;
    const int x = int(gid.x) - g.originX, y = int(gid.y) - g.originY;
    if (x >= 0 && y >= 0 && x < int(g.width) && y < int(g.height)) return;
    for (uint j = 0; j < 2; j++)
        for (uint i = 0; i < 2; i++) dst.write(float4(0.0f), 2 * gid + uint2(i, j));
}

// MARK: - Resample

static inline float up_lanczos3(float d) {
    d = fabs(d);
    if (d < 1e-5f) return 1.0f;
    if (d >= 3.0f) return 0.0f;
    const float p = M_PI_F * d;
    return 3.0f * sin(p) * sin(p / 3.0f) / (p * p);
}

// Separable Lanczos-3 on premultiplied colour, widened by the scale when reducing so it also low-passes. Outside the
// picture is transparent. `axis` 0 resamples x (dst width, src height), 1 resamples y; the y pass clamps.
kernel void up_resample(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant uint& axis [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    const float srcLength = float(axis == 0 ? src.get_width() : src.get_height());
    const float dstLength = float(axis == 0 ? dst.get_width() : dst.get_height());
    const float scale = srcLength / dstLength;
    const float widen = max(scale, 1.0f);
    const float centre = (float(axis == 0 ? gid.x : gid.y) + 0.5f) * scale - 0.5f;
    const int lo = int(floor(centre - 3.0f * widen)) + 1;
    const int hi = int(floor(centre + 3.0f * widen));
    float4 sum = 0.0f;
    float weights = 0.0f;
    for (int k = lo; k <= hi; k++) {
        const float w = up_lanczos3((float(k) - centre) / widen);
        weights += w;
        if (k < 0 || k >= int(srcLength)) continue;
        sum += w * src.read(axis == 0 ? uint2(uint(k), gid.y) : uint2(gid.x, uint(k)));
    }
    float4 c = sum / weights;
    if (axis == 1) {
        c.a = clamp(c.a, 0.0f, 1.0f);
        c.rgb = clamp(c.rgb, 0.0f, c.a);
    }
    dst.write(c, gid);
}
"""
}
