import Foundation

/// Metal source for the deinterlacer's first dispatch (``PlanarFrameFinisher``, a field job): FFmpeg's bwdif,
/// transcribed from libavfilter/bwdifdsp.c (`FILTER_INTRA`, `FILTER1`, `SPAT_CHECK`, `FILTER_LINE`, `FILTER_EDGE`,
/// `FILTER2`) and vf_bwdif.c's `filter_slice` (which rows, which reference offsets at the picture's top and bottom).
/// bwdif has no specification beyond that C, so the C is the reference: the same integer arithmetic, sample for
/// sample, and the tests compare every output field with libavfilter's own bwdif.
///
/// Compiled into the finisher's library, so it reads the source through the same descriptor reader: one component
/// per dispatch, of three pictures (previous, current, next) whose planes may sit in different slabs. It writes the
/// deinterlaced component at the source's depth into a planar scratch picture, little-endian, one or two bytes a
/// sample, which the finisher's second dispatch reads as an ordinary progressive picture.
extension PlanarFrameShaderSource {
    static let bwdif = """

// MARK: - Deinterlacing (bwdif)

struct PFPicture {
    uint plane_offset[4];
    uint linesize[4];
};

struct PFBwdif {
    PFPicture prev;
    PFPicture cur;
    PFPicture next;
    uint width;          // the component's plane
    uint height;
    uint component;      // 0, 1, 2
    uint parity;         // rows with (y ^ parity) & 1 are interpolated, the others are the current field's
    uint field_parity;   // vf_bwdif's parity ^ tff: prev2 / next2 are prev / cur when 1, cur / next when 0
    uint intra;          // the stream's first or last field: FILTER_INTRA, the current field alone
    uint clip_max;       // (1 << depth) - 1
    uint out_offset;     // the scratch plane
    uint out_linesize;
    uint out_wide;       // two bytes a sample
};

// bwdifdsp.c's coefficients, over 2^13.
constant int PF_BW_LF0 = 4309, PF_BW_LF1 = 213;
constant int PF_BW_HF0 = 5570, PF_BW_HF1 = 3801, PF_BW_HF2 = 1016;
constant int PF_BW_SP0 = 5077, PF_BW_SP1 = 981;

static inline int pf_bw_read(device const uchar* s, constant PFPicture& p, uint c, uint x, int y) {
    uint plane = c == 0u ? FC_C0_PLANE : (c == 1u ? FC_C1_PLANE : FC_C2_PLANE);
    device const uchar* row = s + p.plane_offset[plane] + uint(y) * p.linesize[plane];
    if (c == 0u) { return int(pf_read_row(row, FC_C0_STEP, FC_C0_OFFSET, FC_C0_SHIFT, FC_C0_DEPTH, x)); }
    if (c == 1u) { return int(pf_read_row(row, FC_C1_STEP, FC_C1_OFFSET, FC_C1_SHIFT, FC_C1_DEPTH, x)); }
    return int(pf_read_row(row, FC_C2_STEP, FC_C2_OFFSET, FC_C2_SHIFT, FC_C2_DEPTH, x));
}

// One interpolated sample at (x, y). The reference offsets are vf_bwdif.c's: mirrored at the picture's top and
// bottom for intra and edge rows, plain +-1 ... +-4 rows elsewhere.
static inline int pf_bw_sample(device const uchar* prev, device const uchar* cur, device const uchar* next,
                               constant PFBwdif& b, uint x, int y) {
    int h = int(b.height);
    uint c = b.component;
    int clip_max = int(b.clip_max);
    #define CUR(r)  pf_bw_read(cur, b.cur, c, x, y + (r))
    #define PREV(r) pf_bw_read(prev, b.prev, c, x, y + (r))
    #define NEXT(r) pf_bw_read(next, b.next, c, x, y + (r))
    #define P2(r)   (b.field_parity ? PREV(r) : CUR(r))
    #define N2(r)   (b.field_parity ? CUR(r) : NEXT(r))
    if (b.intra != 0u) {
        int prefs = y + 1 < h ? 1 : -1, mrefs = y > 0 ? -1 : 1;
        int prefs3 = y + 3 < h ? 3 : -1, mrefs3 = y > 2 ? -3 : 1;
        int interpol = (PF_BW_SP0 * (CUR(mrefs) + CUR(prefs)) - PF_BW_SP1 * (CUR(mrefs3) + CUR(prefs3))) >> 13;
        return clamp(interpol, 0, clip_max);
    }
    bool edge = y < 4 || y + 5 > h;
    int prefs = edge && y + 1 >= h ? -1 : 1;
    int mrefs = edge && y <= 0 ? 1 : -1;
    // FILTER1
    int c0 = CUR(mrefs);
    int p2 = P2(0), n2 = N2(0);
    int d = (p2 + n2) >> 1;
    int e = CUR(prefs);
    int temporal_diff0 = abs(p2 - n2);
    int temporal_diff1 = (abs(PREV(mrefs) - c0) + abs(PREV(prefs) - e)) >> 1;
    int temporal_diff2 = (abs(NEXT(mrefs) - c0) + abs(NEXT(prefs) - e)) >> 1;
    int diff = max(max(temporal_diff0 >> 1, temporal_diff1), temporal_diff2);
    if (diff == 0) { return d; }
    // SPAT_CHECK: every line row, and edge rows away from the outermost two (vf_bwdif.c's `spat`).
    if (!edge || !(y < 2 || y + 3 > h)) {
        int bb = ((P2(-2) + N2(-2)) >> 1) - c0;
        int f = ((P2(2) + N2(2)) >> 1) - e;
        int dc = d - c0;
        int de = d - e;
        int mx = max(max(de, dc), min(bb, f));
        int mn = min(min(de, dc), max(bb, f));
        diff = max(max(diff, mn), -mx);
    }
    int interpol;
    if (edge) {
        // FILTER_EDGE
        interpol = (c0 + e) >> 1;
    } else if (abs(c0 - e) > temporal_diff0) {
        // FILTER_LINE, high-frequency branch
        interpol = (((PF_BW_HF0 * (p2 + n2)
                      - PF_BW_HF1 * (P2(-2) + N2(-2) + P2(2) + N2(2))
                      + PF_BW_HF2 * (P2(-4) + N2(-4) + P2(4) + N2(4))) >> 2)
                    + PF_BW_LF0 * (c0 + e) - PF_BW_LF1 * (CUR(-3) + CUR(3))) >> 13;
    } else {
        interpol = (PF_BW_SP0 * (c0 + e) - PF_BW_SP1 * (CUR(-3) + CUR(3))) >> 13;
    }
    #undef CUR
    #undef PREV
    #undef NEXT
    #undef P2
    #undef N2
    // FILTER2
    if (interpol > d + diff) {
        interpol = d + diff;
    } else if (interpol < d - diff) {
        interpol = d - diff;
    }
    return clamp(interpol, 0, clip_max);
}

static inline void pf_bw_write(device uchar* out, constant PFBwdif& b, uint x, uint y, int v) {
    device uchar* row = out + b.out_offset + y * b.out_linesize;
    if (b.out_wide != 0u) {
        *(device ushort*)(row + 2u * x) = ushort(v);
    } else {
        row[x] = uchar(v);
    }
}

// One thread per four columns of a row pair: the current field's row, copied, and the row between, interpolated.
// Four adjacent samples share every row of their window, so its loads come from the same cache lines.
kernel void pf_bwdif(device const uchar*  prev  [[buffer(0)]],
                     constant PFBwdif&    b     [[buffer(1)]],
                     device const uchar*  cur   [[buffer(5)]],
                     device const uchar*  next  [[buffer(6)]],
                     device uchar*        out   [[buffer(7)]],
                     uint2                gid   [[thread_position_in_grid]]) {
    uint x0 = gid.x * 4u;
    if (x0 >= b.width) { return; }
    uint kept = 2u * gid.y + b.parity;
    uint interpolated = 2u * gid.y + (b.parity ^ 1u);
    uint n = min(4u, b.width - x0);
    for (uint i = 0u; i < n; ++i) {
        uint x = x0 + i;
        if (kept < b.height) {
            pf_bw_write(out, b, x, kept, pf_bw_read(cur, b.cur, b.component, x, int(kept)));
        }
        if (interpolated < b.height) {
            pf_bw_write(out, b, x, interpolated, pf_bw_sample(prev, cur, next, b, x, int(interpolated)));
        }
    }
}
"""
}
