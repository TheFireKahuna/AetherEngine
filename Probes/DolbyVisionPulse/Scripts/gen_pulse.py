#!/usr/bin/env python3
"""Synthetic Dolby Vision pulse clips for the RPU-consumption experiment.

The pixels are identical in every variant and every phase, except for a frame-counter strip that
the analysis reads back from the phone video. Only the RPU changes:

  l2    L1 constant (true stats); L2 trims at 100/600/1000/4000-nit targets switch neutral <-> extreme
  l1    L1 max_pq switches 100 nits <-> 10000 nits; no trims
  null  L1 constant, L2 trims always neutral (same shot boundaries as l2)
  l8    CM v4.0: L1 constant, L2 trims always neutral; L8 trims at the 100/600/1000/higher presets
        switch neutral <-> extreme. Only a CM v4.0 display manager can see the switch, so a pulse
        means the L8 blocks reached the panel; a v2.9-only path (or one that drops L8) stays flat.
  l2v4  CM v4.0 without L8 (the safe-default blocks L3/L9/L11/L254 only), L2 switching as in l2. A CM v4.0
        display manager ignores L2, so it stays flat where v4.0 arrives intact; it pulses like l2 where the
        v4.0 list is stripped or the panel runs CM v2.9.
  l8a-h the L8 ladder (L8_LADDER): the l8 tone pulse with one 10-byte block at 100 nits (a), at 1000 nits (b),
        five 10-byte blocks (c), one 25-byte block at 1000 nits (d); then at 1000 nits a realistic tone trim (e)
        and a saturation-only trim (f), the extreme trim at 600 nits (g), and a's block at 25 bytes (h).
  hue   CM v4.0, L2 and the L8 tone trims neutral; only the L8 six-vector trims switch (red hue rotated,
        cyan desaturated). Red and cyan move, greys and the other colours stay put, only when the panel's own
        CM v4.0 consumes the L8 blocks: CM v2.9 has no per-hue control (the colour-aware analysis,
        analyze.py --color, measures it).

Timeline at 24000/1001 fps: 144 frames of phase A (pre-roll, lets the HDMI mode switch settle),
then 20 phases of 72 frames alternating B, A, B, ... (10 cycles of ~6 s). The phase of any frame is
a pure function of its index, see `phase_of`.

Usage: gen_pulse.py layout                  -> layout.json (patch boxes, code cells) on stdout
       gen_pulse.py frames                  -> raw yuv420p10le frames on stdout (feed x265)
       gen_pulse.py rpu-json <variant>      -> dovi_tool generate config on stdout
       gen_pulse.py el-frames               -> raw 1920x1080 yuv420p10le EL frames on stdout (feed x265)
       gen_pulse.py el-design               -> the EL residual design (patches, EL codes) as JSON

       gen_pulse.py sub10-frames            -> raw 1920x1080 yuv420p10le EL frames for p7fel_sub10
       gen_pulse.py sub10-design            -> the sub-10-bit residual design as JSON

       gen_pulse.py card-frames / card-el-frames      -> BL (4K, flat N) / EL frames for p7fel_card
       gen_pulse.py card-design / card-amp-args      -> the card design as JSON / the card_rpu arguments
       gen_pulse.py bullseye-frames / bullseye-el-frames -> BL / EL frames for p7fel_bullseye
       gen_pulse.py still-rpu-json card|bullseye     -> dovi_tool generate config for those two clips

card-* is the amplifier test card p7fel_card, bullseye-* its fallback p7fel_bullseye: see the comments
above card_design and bullseye_planes.

sub10-frames is for the bit-survival clip p7fel_sub10: the RPU is constant (`null`); on SUB10_PATCHES
the residual is -2 VDR codes (-1/2 of a 10-bit code) in phase A and +1 (+1/4) in phase B. Rounded to
10 bits both phases give the base layer's own code, so the 3/4-code swing exists only below 10 bits:
a display path that keeps 12 bits pulses, one that rounds to 10 stays flat, and ordered dither
(which carries the mean) pulses as the positive control.

el-frames is for the p7fel_el clip: the RPU is constant (as in `null`), the enhancement layer is flat
512 (zero residual) in phase A and carries a positive luma residual on EL_PATCHES in phase B.
"""
import json
import sys

import numpy as np

W, H = 3840, 2160
FPS_NUM, FPS_DEN = 24000, 1001
PREROLL = 144
PHASE_LEN = 72
N_PHASES = 20
N_FRAMES = PREROLL + PHASE_LEN * N_PHASES  # 1584, ~66 s

CODE_BITS = 12  # frame index, Gray-coded
CELL_NITS = 300.0
FID_NITS = 300.0


def phase_of(i):
    """'A' or 'B' for frame index i."""
    if i < PREROLL:
        return "A"
    return "B" if ((i - PREROLL) // PHASE_LEN) % 2 == 0 else "A"


def pq(nits):
    m1 = 2610 / 16384
    m2 = 2523 / 4096 * 128
    c1 = 3424 / 4096
    c2 = 2413 / 4096 * 32
    c3 = 2392 / 4096 * 32
    y = np.power(np.asarray(nits, dtype=np.float64) / 10000.0, m1)
    return np.power((c1 + c2 * y) / (1 + c3 * y), m2)


def pq12(nits):
    return int(round(float(pq(nits)) * 4095))


# ---------------------------------------------------------------- layout
GRAY_NITS = [0.1, 1, 10, 50, 100, 200, 400, 600, 1000, 2000, 4000, 10000]
# Linear-light BT.2020 RGB in nits.
COLORS = {
    "gray150": (150, 150, 150),
    "red": (400, 60, 60),
    "green": (60, 300, 60),
    "blue": (60, 60, 400),
    "yellow": (300, 300, 40),
    "cyan": (40, 300, 300),
    "magenta": (300, 40, 300),
    "skin": (250, 160, 120),
}


def layout():
    boxes = []  # name, x0, y0, x1, y1, rgb nits
    pw, gap, x0 = 240, 40, 260
    for k, n in enumerate(GRAY_NITS):
        x = x0 + k * (pw + gap)
        boxes.append({"name": f"g{n:g}", "box": [x, 400, x + pw, 760], "rgb": [n, n, n]})
    cw, cgap = 380, 40
    cx0 = (W - (len(COLORS) * cw + (len(COLORS) - 1) * cgap)) // 2
    for k, (name, rgb) in enumerate(COLORS.items()):
        x = cx0 + k * (cw + cgap)
        boxes.append({"name": name, "box": [x, 880, x + cw, 1240], "rgb": list(rgb)})
    ramp = {"name": "ramp", "box": [260, 1360, 260 + 3320, 1560], "pq_range": [0.0, float(pq(1000))]}
    cells = []
    nc, cell, cgap2 = CODE_BITS + 4, 180, 20
    sx = (W - (nc * cell + (nc - 1) * cgap2)) // 2
    for k in range(nc):
        x = sx + k * (cell + cgap2)
        cells.append([x, 1720, x + cell, 1900])
    s, m = 200, 80
    fids = [[m, m, m + s, m + s], [W - m - s, m, W - m, m + s],
            [m, H - m - s, m + s, H - m], [W - m - s, H - m - s, W - m, H - m]]
    # Orientation tag right of the top-left fiducial.
    tag = [m + s + 60, m + 50, m + s + 160, m + 150]
    return {"width": W, "height": H, "fps": [FPS_NUM, FPS_DEN], "preroll": PREROLL,
            "phase_len": PHASE_LEN, "n_phases": N_PHASES, "n_frames": N_FRAMES,
            "patches": boxes, "ramp": ramp, "code_cells": cells, "code_bits": CODE_BITS,
            "fiducials": fids, "orientation_tag": tag, "cell_nits": CELL_NITS}


def code_bits_for(i):
    """16 cells: [1, gray(11..0), parity(gray 0-5), parity(gray 6-11), 1]."""
    g = i ^ (i >> 1)
    bits = [(g >> (CODE_BITS - 1 - b)) & 1 for b in range(CODE_BITS)]
    p_lo = sum(bits[CODE_BITS - 6:]) & 1
    p_hi = sum(bits[:CODE_BITS - 6]) & 1
    return [1] + bits + [p_lo, p_hi, 1]


def decode_bits(cells):
    """Inverse of code_bits_for; returns frame index or None if the check fails."""
    if len(cells) != CODE_BITS + 4 or cells[0] != 1 or cells[-1] != 1:
        return None
    bits = cells[1:1 + CODE_BITS]
    if (sum(bits[CODE_BITS - 6:]) & 1) != cells[CODE_BITS + 1] or (sum(bits[:CODE_BITS - 6]) & 1) != cells[CODE_BITS + 2]:
        return None
    g = 0
    for b in bits:
        g = (g << 1) | b
    n = 0
    while g:
        n ^= g
        g >>= 1
    return n


# ---------------------------------------------------------------- pixels
def rgb_nits_to_ycc10(rgb):
    r, g, b = (float(pq(c)) for c in rgb)
    y = 0.2627 * r + 0.6780 * g + 0.0593 * b
    cb = (b - y) / 1.8814
    cr = (r - y) / 1.4746
    return (int(round(64 + 876 * y)), int(round(512 + 896 * cb)), int(round(512 + 896 * cr)))


def base_planes(L):
    Y = np.full((H, W), 64, dtype=np.uint16)
    Cb = np.full((H // 2, W // 2), 512, dtype=np.uint16)
    Cr = np.full((H // 2, W // 2), 512, dtype=np.uint16)

    def fill(box, rgb):
        x0, y0, x1, y1 = box
        yv, cbv, crv = rgb_nits_to_ycc10(rgb)
        Y[y0:y1, x0:x1] = yv
        Cb[y0 // 2:y1 // 2, x0 // 2:x1 // 2] = cbv
        Cr[y0 // 2:y1 // 2, x0 // 2:x1 // 2] = crv

    for p in L["patches"]:
        fill(p["box"], p["rgb"])
    x0, y0, x1, y1 = L["ramp"]["box"]
    lo, hi = L["ramp"]["pq_range"]
    ramp = np.linspace(lo, hi, x1 - x0)
    Y[y0:y1, x0:x1] = np.round(64 + 876 * ramp).astype(np.uint16)[None, :]
    for f in L["fiducials"] + [L["orientation_tag"]]:
        fill(f, (FID_NITS,) * 3)
    return Y, Cb, Cr


def l1_stats(L):
    """L1 min/max/avg in 12-bit PQ over max(R',G',B'), code strip assumed half on."""
    Y, _, _ = base_planes(L)
    # Gray/colour patches: use max(R',G',B') per patch weighted by area.
    tot = W * H
    acc = 0.0
    mx = 0.0
    for p in L["patches"]:
        x0, y0, x1, y1 = p["box"]
        v = max(float(pq(c)) for c in p["rgb"])
        acc += v * (x1 - x0) * (y1 - y0)
        mx = max(mx, v)
    x0, y0, x1, y1 = L["ramp"]["box"]
    lo, hi = L["ramp"]["pq_range"]
    acc += (lo + hi) / 2 * (x1 - x0) * (y1 - y0)
    v = float(pq(FID_NITS))
    for f in L["fiducials"] + [L["orientation_tag"]]:
        acc += v * (f[2] - f[0]) * (f[3] - f[1])
    for c in L["code_cells"]:
        acc += 0.5 * float(pq(CELL_NITS)) * (c[2] - c[0]) * (c[3] - c[1])
    return 0, int(round(mx * 4095)), int(round(acc / tot * 4095))


def write_frames(out):
    L = layout()
    Y, Cb, Cr = base_planes(L)
    on = rgb_nits_to_ycc10((CELL_NITS,) * 3)[0]
    cb_bytes, cr_bytes = Cb.tobytes(), Cr.tobytes()
    for i in range(N_FRAMES):
        for bit, (x0, y0, x1, y1) in zip(code_bits_for(i), L["code_cells"]):
            Y[y0:y1, x0:x1] = on if bit else 64
        out.write(Y.tobytes())
        out.write(cb_bytes)
        out.write(cr_bytes)


# ---------------------------------------------------------------- enhancement layer (p7fel_el)
EL_W, EL_H = W // 2, H // 2
EL_FLAT = 512          # = nlq_offset of fel_orig.bin, i.e. zero residual
EL_GAIN = 0.17         # target luma change in PQ code value, fraction of the patch's own 10-bit Y
EL_MAX_DELTA10 = 120   # cap in 10-bit codes: the NLQ range is +-511 12-bit codes (= +-127.75 10-bit)
# Every other grey patch from 10 to 1000 nit, plus two colour patches. The rest are in-frame controls.
EL_PATCHES = ["g10", "g100", "g400", "g1000", "red", "cyan"]


def el_design():
    """Per target patch: BL Y, wanted 10-bit delta, EL code. fel_orig.bin NLQ (all components):
    nlq_offset 512, vdr_in_max 0.125, slope 2048 @ denom 23, threshold 0, vdr 12 bit. The composer's
    inverse NLQ then gives residual = (|EL-512| - 1/2) * 2048 >> 11 = |EL-512| - 1 VDR 12-bit codes
    (= 1/4 of a code in the 10-bit output), assuming the BL->VDR luma map is identity-scaled
    (poly c0=0, c1=1); that is checked empirically, not assumed."""
    out = []
    for p in layout()["patches"]:
        if p["name"] not in EL_PATCHES:
            continue
        y10 = rgb_nits_to_ycc10(p["rgb"])[0]
        d10 = min(int(round(EL_GAIN * y10)), EL_MAX_DELTA10, 940 - y10)
        d12 = 4 * d10
        out.append({"name": p["name"], "box": p["box"], "bl_y10": y10, "delta10": d10,
                    "delta_pct": round(100.0 * d10 / y10, 2), "el_code": EL_FLAT + d12 + 1})
    return out


def write_el_frames(out):
    A = np.full((EL_H, EL_W), EL_FLAT, dtype=np.uint16)
    B = A.copy()
    for d in el_design():
        x0, y0, x1, y1 = (v // 2 for v in d["box"])
        B[y0:y1, x0:x1] = d["el_code"]
    chroma = np.full((EL_H // 2) * (EL_W // 2), EL_FLAT, dtype=np.uint16).tobytes()
    fa = A.tobytes() + chroma + chroma
    fb = B.tobytes() + chroma + chroma
    for i in range(N_FRAMES):
        out.write(fb if phase_of(i) == "B" else fa)


# ---------------------------------------------------------------- sub-10-bit residual (p7fel_sub10)
# residual = |EL - 512| - 1 VDR codes (el_design's model of fel_orig.bin), applied with the EL's sign.
SUB10_EL_A = EL_FLAT - 3   # -2 VDR codes: 1/2 of a 10-bit code down, which rounds back up to the BL code
SUB10_EL_B = EL_FLAT + 2   # +1 VDR code: 1/4 of a 10-bit code up, which rounds back down to it
# Mid greys and two colours; the other patches stay flat as in-frame controls. Not g0.1 (black clamp)
# or the top greys (L1/trim roll-off can compress the swing there).
SUB10_PATCHES = ["g1", "g10", "g50", "g100", "g200", "g400", "gray150", "skin"]


def sub10_design():
    return {"el_a": SUB10_EL_A, "el_b": SUB10_EL_B, "vdr_a": -2, "vdr_b": 1,
            "patches": [{"name": p["name"], "box": p["box"], "bl_y10": rgb_nits_to_ycc10(p["rgb"])[0]}
                        for p in layout()["patches"] if p["name"] in SUB10_PATCHES]}


def write_sub10_frames(out):
    A = np.full((EL_H, EL_W), EL_FLAT, dtype=np.uint16)
    B = A.copy()
    for d in sub10_design()["patches"]:
        x0, y0, x1, y1 = (v // 2 for v in d["box"])
        A[y0:y1, x0:x1] = SUB10_EL_A
        B[y0:y1, x0:x1] = SUB10_EL_B
    chroma = np.full((EL_H // 2) * (EL_W // 2), EL_FLAT, dtype=np.uint16).tobytes()
    fa = A.tobytes() + chroma + chroma
    fb = B.tobytes() + chroma + chroma
    for i in range(N_FRAMES):
        out.write(fb if phase_of(i) == "B" else fa)


# ---------------------------------------------------------------- test card (p7fel_card)
# A static card whose composed VDR luma is exactly N, N+1/4, N+1/2 and N+1 10-bit codes (VDR 4N .. 4N+4), on a flat
# base layer at N: every offset is enhancement-layer residual. Seen through the engine's usual identity RPU it is
# flat grey (a quarter code is far below visibility); through the amplifier RPU (Tools/card_rpu, slope CARD_SLOPE
# over [CARD_LO, CARD_HI)) each quarter code becomes 16 codes, so the glyphs show iff those bits reached whoever
# applies the curve:
#   border  N + 1    (VDR +4)  the control, visible whenever the amplifier is applied at all
#   "1/2"   N + 1/2  (VDR +2)  visible if the path rounds (or keeps >= 11 bits); gone if it truncates
#   "12"    N + 1/4  (VDR +1)  visible only if >= 12 bits reach the amplifier (truncation and rounding both give N)
# No "16" glyph: the clip's VDR is 12-bit (vdr_bit_depth_minus8 4 in fel_orig.bin), so N + 1/16 is not a
# composable value; a deeper VDR would change the RPU and the converter path under test.
CARD_FRAMES = 360            # 15 s at 24000/1001
CARD_N = 448                 # 10-bit BL code, ~41 nit (PQ 0.438); the amplified card spans 511..575 = ~103..196 nit
CARD_SLOPE = 64              # amplifier slope: 1/4 code -> 16 codes, 1/2 -> 32, 1 -> 64
CARD_LO, CARD_HI = CARD_N - 1, CARD_N + 2   # the steep piece covers [447, 450): one code of margin each side
CARD_BORDER = 60             # EL px (120 at 4K)
CARD_CELL = 48               # EL px per font cell: every stroke is 48 EL px (96 at 4K)
# fel_orig.bin's luma NLQ, as DoviFelComposer.inverseNlq reads it.
NLQ = dict(offset=512, scale=2048, shift=23 - 12, threshold=0, vdr_in_max=512)

FONT = {  # 5x7
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "/": ["....#", "....#", "...#.", "..#..", ".#...", "#....", "#...."],
}


def inverse_nlq(el, p=NLQ):
    """DoviFelComposer.inverseNlq for one 10-bit EL code, in VDR (12-bit) code units."""
    r = el - p["offset"]
    if r == 0:
        return 0
    mag = ((2 * abs(r) - 1) * p["scale"] + 2 * p["threshold"]) >> (p["shift"] + 1)
    mag = min(mag, p["vdr_in_max"])
    return mag if r > 0 else -mag


def el_code_for(vdr):
    """The EL code nearest 512 whose inverse NLQ is exactly `vdr` (|EL - 512| = |vdr| + 1 for this NLQ)."""
    for d in range(0, 512):
        for el in (512 + d, 512 - d):
            if inverse_nlq(el) == vdr:
                return el
    raise ValueError(vdr)


def text_mask(text, x0, y0, cell, shape):
    m = np.zeros(shape, dtype=bool)
    x = x0
    for ch in text:
        for r, row in enumerate(FONT[ch]):
            for c, on in enumerate(row):
                if on == "#":
                    m[y0 + r * cell:y0 + (r + 1) * cell, x + c * cell:x + (c + 1) * cell] = True
        x += 6 * cell
    return m


def text_width(text, cell):
    return (6 * len(text) - 1) * cell


def card_design():
    """Elements in EL coordinates (1920x1080), their VDR offset and EL code, probe pixels in 4K coordinates
    (each the centre of a stroke, at least 20 EL px from any edge, where the bilinear EL upsampling is exact)."""
    c = CARD_CELL
    half_x = 540 - text_width("1/2", c) // 2
    twelve_x = 1440 - text_width("12", c) // 2
    y0 = 540 - 7 * c // 2
    elements = [
        {"name": "background", "vdr": 0, "probe": [1920, 300]},
        {"name": "border", "vdr": 4, "probe": [CARD_BORDER, 1080]},
        {"name": "half", "text": "1/2", "x0": half_x, "y0": y0, "vdr": 2,
         "probe": [2 * (half_x + 2 * c + c // 2), 2 * (y0 + 3 * c + c // 2)]},
        {"name": "twelve", "text": "12", "x0": twelve_x, "y0": y0, "vdr": 1,
         "probe": [2 * (twelve_x + 2 * c + c // 2), 2 * (y0 + 3 * c + c // 2)]},
    ]
    for e in elements:
        e["el_code"] = el_code_for(e["vdr"])
        e["expect_vdr"] = 4 * CARD_N + e["vdr"]
        e["expect_code"] = CARD_N + e["vdr"] / 4
    return {"n": CARD_N, "frames": CARD_FRAMES, "el_size": [EL_W, EL_H], "border_el_px": CARD_BORDER,
            "cell_el_px": c, "nlq": NLQ, "elements": elements,
            "amp": {"lo": CARD_LO, "hi": CARD_HI, "slope": CARD_SLOPE}}


def card_el_plane():
    d = card_design()
    E = np.full((EL_H, EL_W), EL_FLAT, dtype=np.uint16)
    b = CARD_BORDER
    border = next(e for e in d["elements"] if e["name"] == "border")
    E[:b, :] = E[-b:, :] = E[:, :b] = E[:, -b:] = border["el_code"]
    for e in d["elements"]:
        if "text" in e:
            E[text_mask(e["text"], e["x0"], e["y0"], CARD_CELL, E.shape)] = e["el_code"]
    return E


def write_flat_el(out, Y, n):
    chroma = np.full((EL_H // 2) * (EL_W // 2), EL_FLAT, dtype=np.uint16).tobytes()
    f = Y.astype(np.uint16).tobytes() + chroma + chroma
    for _ in range(n):
        out.write(f)


def write_bl(out, Y, n):
    chroma = np.full((H // 2) * (W // 2), 512, dtype=np.uint16).tobytes()
    f = Y.astype(np.uint16).tobytes() + chroma + chroma
    for _ in range(n):
        out.write(f)


def pq12_code10(c):
    """12-bit PQ (L1 units) of a limited-range 10-bit luma code."""
    return int(round((c - 64) / 876 * 4095))


def amp_curve(x):
    """The amplifier curve card_rpu writes, in 10-bit codes (see Tools/card_rpu/src/main.rs)."""
    x = np.asarray(x, dtype=np.float64)
    f_hi = CARD_LO + CARD_SLOPE * (CARD_HI - CARD_LO)
    s2 = (1023 - f_hi) / (1023 - CARD_HI)
    return np.where(x < CARD_LO, x, np.where(x < CARD_HI, CARD_LO + CARD_SLOPE * (x - CARD_LO),
                                            f_hi + (x - CARD_HI) * s2))


def card_amp_l1():
    """L1 for the amplified card (12-bit PQ): min = background, max = border, avg area-weighted."""
    E = card_el_plane()
    vdr = np.vectorize(inverse_nlq)(E)
    out = amp_curve(CARD_N + vdr / 4)
    pq = (out - 64) / 876 * 4095
    return int(round(pq.min())), int(round(pq.max())), int(round(pq.mean()))


# ---------------------------------------------------------------- bullseye (p7fel_bullseye)
# Dark radial gradient, centre BULL_CENTER to corners BULL_EDGE 10-bit codes (~0.6 to ~0.3 nit): one 10-bit step
# every ~90 px, ~2.5% luminance per step, at the edge of what a dark-adapted eye sees on an OLED. Left half: the
# target rounded to whole 10-bit codes (BL only, EL flat); right half: the same target at full 12-bit VDR
# precision, BL plus a -2..+1 VDR residual, so a quarter-code step every ~23 px. Both computed on 2x2 blocks, so
# each block is one EL texel and the bilinear EL upsampling is exact except along the residual's wrap lines
# (+1 -> -2), where one 4K pixel each side is off by one VDR code.
BULL_CENTER, BULL_EDGE = 176, 152
BULL_DIVIDER = 8             # 4K px wide divider at BULL_EDGE - 8


def bullseye_planes():
    by, bx = np.mgrid[0:EL_H, 0:EL_W]
    r = np.hypot(2 * bx + 1 - W / 2, 2 * by + 1 - H / 2) / np.hypot(W / 2, H / 2)
    t = 4 * (BULL_CENTER - (BULL_CENTER - BULL_EDGE) * r)       # VDR target, float
    left = bx < EL_W // 2
    vdr = np.where(left, 4 * np.floor(t / 4 + 0.5), np.floor(t + 0.5)).astype(np.int64)
    bl = (vdr + 2) // 4
    res = vdr - 4 * bl
    el = np.where(res == 0, EL_FLAT, np.vectorize(el_code_for)(res)).astype(np.uint16)
    el[left] = EL_FLAT
    Y = np.repeat(np.repeat(bl, 2, axis=0), 2, axis=1).astype(np.uint16)
    Y[:, W // 2 - BULL_DIVIDER // 2:W // 2 + BULL_DIVIDER // 2] = BULL_EDGE - 8
    return Y, el, vdr


# ---------------------------------------------------------------- RPU configs
NEUTRAL_TRIM = dict(trim_slope=2048, trim_offset=2048, trim_power=2048,
                    trim_chroma_weight=2048, trim_saturation_gain=2048, ms_weight=2048)
# Darker and nearly monochrome: slope 0.625, offset -1/16, power 1.375, saturation -0.5.
EXTREME_TRIM = dict(trim_slope=512, trim_offset=1792, trim_power=3584,
                    trim_chroma_weight=2048, trim_saturation_gain=0, ms_weight=2048)
TRIM_TARGETS = [100, 600, 1000, 4000]
# L8 addresses targets by preset index, not by nits, and a frame carries at most 5 L8 blocks. A 1000-2000
# nit panel (the G5) interpolates between the 1000- and 2000-nit trims, so both primaries variants of each
# are present (48/49: 1000 nits, 37/38: 2000 nits, per dolby_vision's trim_target_nits), plus the 100-nit
# BT.709 target (1) every real master carries. 600 nits (27) is left out to stay within five blocks.
L8_TARGET_INDICES = [1, 48, 49, 37, 38]
# Length 25 carries the six-vector fields; neutral is 2048 in the 12-bit fields and 128 in the vectors.
L8_VECTORS_NEUTRAL = {f"{k}_vector_field{i}": 128 for k in ("saturation", "hue") for i in range(6)}
L8_NEUTRAL_TRIM = dict(NEUTRAL_TRIM, target_mid_contrast=2048, clip_trim=2048, **L8_VECTORS_NEUTRAL)
L8_EXTREME_TRIM = dict(L8_NEUTRAL_TRIM, **EXTREME_TRIM)
# CM v4.0-only signature: tone trims neutral, only two secondaries move. Vector order is R, Y, G, C, B, M:
# the red hue is rotated and cyan is fully desaturated, so a v4.0 display manager moves the red and cyan
# patches and nothing else. CM v2.9 has no per-hue control, so no L2 trim (derived or not) can produce it.
L8_HUE_TRIM = dict(L8_NEUTRAL_TRIM, hue_vector_field0=32, saturation_vector_field3=0)
# The L8 ladder: the l8 tone pulse with fewer or shorter blocks, from what streaming masters carry (one
# 10-byte block at the 100-nit target) up to l8's five 25-byte blocks, to find where L8 stops working.
# variant -> (target indices, block length, phase B trim)
# On the G5 (2026-10-20) a: dims; b, c, d: a black flash at each switch and no trim. e-h then separate
# "the 1000-nit target" from "an extreme trim at the target nearest the panel's peak".
L8_MILD_TRIM = dict(L8_NEUTRAL_TRIM, trim_slope=1843, trim_power=2253)       # slope -0.1, power +0.1
L8_SAT_ONLY_TRIM = dict(L8_NEUTRAL_TRIM, trim_saturation_gain=0)             # tone neutral, saturation -1
L8_LADDER = {
    "l8a": ([1], 10, L8_EXTREME_TRIM),                   # one short block, 100 nits
    "l8b": ([48], 10, L8_EXTREME_TRIM),                  # one short block, 1000 nits
    "l8c": (L8_TARGET_INDICES, 10, L8_EXTREME_TRIM),     # five short blocks
    "l8d": ([48], 25, L8_EXTREME_TRIM),                  # one long block, 1000 nits
    "l8e": ([48], 10, L8_MILD_TRIM),                     # 1000 nits, a realistic tone trim
    "l8f": ([48], 10, L8_SAT_ONLY_TRIM),                 # 1000 nits, saturation only
    "l8g": ([27], 10, L8_EXTREME_TRIM),                  # 600 nits, extreme
    "l8h": ([1], 25, L8_EXTREME_TRIM),                   # 100 nits as a, long block
}
V40_VARIANTS = ("l8", "l2v4", "hue") + tuple(L8_LADDER)


def shots():
    """(start, duration, phase) covering the timeline."""
    out = [(0, PREROLL, "A")]
    for k in range(N_PHASES):
        s = PREROLL + k * PHASE_LEN
        out.append((s, PHASE_LEN, phase_of(s)))
    return out


def rpu_config(variant):
    L = layout()
    mn, mx, avg = l1_stats(L)
    cfg = {
        "cm_version": "V40" if variant in V40_VARIANTS else "V29",
        "profile": "8.1",
        "length": N_FRAMES,
        "level6": {"max_display_mastering_luminance": 10000, "min_display_mastering_luminance": 1,
                   "max_content_light_level": 10000, "max_frame_average_light_level": 400},
        "shots": [],
    }
    for start, dur, ph in shots():
        blocks = []
        if variant == "l1":
            peak = 2081 if ph == "A" else 4095
            blocks.append({"Level1": {"min_pq": mn, "max_pq": peak, "avg_pq": min(avg, peak)}})
        else:
            blocks.append({"Level1": {"min_pq": mn, "max_pq": mx, "avg_pq": avg}})
            trim = EXTREME_TRIM if (variant in ("l2", "l2v4") and ph == "B") else NEUTRAL_TRIM
            for t in TRIM_TARGETS:
                blocks.append({"Level2": dict(target_max_pq=pq12(t), **trim)})
            if variant in ("l8", "hue") or variant in L8_LADDER:
                pulse8 = L8_HUE_TRIM if variant == "hue" else L8_EXTREME_TRIM
                indices, length, pulse8 = L8_LADDER.get(variant, (L8_TARGET_INDICES, 25, pulse8))
                trim8 = pulse8 if ph == "B" else L8_NEUTRAL_TRIM
                for idx in indices:
                    # a short block simply doesn't carry the fields past its length
                    blocks.append({"Level8": dict(length=length, target_display_index=idx, **trim8)})
        cfg["shots"].append({"start": start, "duration": dur, "metadata_blocks": blocks})
    return cfg



def still_rpu_config(name):
    """dovi_tool generate config for the static card / bullseye clips: one shot, L1 of the composed picture as the
    engine shows it (identity mapping), neutral L2, a 1000-nit grade in L6."""
    if name == "card":
        lo, hi, avg = pq12_code10(CARD_N), pq12_code10(CARD_N + 1), pq12_code10(CARD_N)
    else:
        lo, hi, avg = pq12_code10(BULL_EDGE - 8), pq12_code10(BULL_CENTER), pq12_code10((BULL_CENTER + BULL_EDGE) / 2)
    blocks = [{"Level1": {"min_pq": lo, "max_pq": max(hi, 2081), "avg_pq": avg}}]
    blocks += [{"Level2": dict(target_max_pq=pq12(t), **NEUTRAL_TRIM)} for t in TRIM_TARGETS]
    return {"cm_version": "V29", "profile": "8.1", "length": CARD_FRAMES,
            "level6": {"max_display_mastering_luminance": 1000, "min_display_mastering_luminance": 1,
                       "max_content_light_level": 1000, "max_frame_average_light_level": 400},
            "shots": [{"start": 0, "duration": CARD_FRAMES, "metadata_blocks": blocks}]}

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "layout":
        L = layout()
        L["l1"] = dict(zip(["min_pq", "max_pq", "avg_pq"], l1_stats(L)))
        json.dump(L, sys.stdout, indent=1)
    elif cmd == "frames":
        write_frames(sys.stdout.buffer)
    elif cmd == "el-frames":
        write_el_frames(sys.stdout.buffer)
    elif cmd == "sub10-frames":
        write_sub10_frames(sys.stdout.buffer)
    elif cmd == "sub10-design":
        json.dump(sub10_design(), sys.stdout, indent=1)
    elif cmd == "el-design":
        json.dump(el_design(), sys.stdout, indent=1)
    elif cmd == "card-design":
        d = card_design()
        d["amp"]["l1"] = card_amp_l1()
        json.dump(d, sys.stdout, indent=1)
    elif cmd == "card-frames":
        write_bl(sys.stdout.buffer, np.full((H, W), CARD_N), CARD_FRAMES)
    elif cmd == "card-el-frames":
        write_flat_el(sys.stdout.buffer, card_el_plane(), CARD_FRAMES)
    elif cmd == "card-amp-args":
        print(CARD_N, CARD_SLOPE, CARD_LO, CARD_HI, *card_amp_l1())
    elif cmd == "bullseye-frames":
        write_bl(sys.stdout.buffer, bullseye_planes()[0], CARD_FRAMES)
    elif cmd == "bullseye-el-frames":
        write_flat_el(sys.stdout.buffer, bullseye_planes()[1], CARD_FRAMES)
    elif cmd == "still-rpu-json" and len(sys.argv) == 3 and sys.argv[2] in ("card", "bullseye"):
        json.dump(still_rpu_config(sys.argv[2]), sys.stdout, indent=1)
    elif cmd == "rpu-json" and len(sys.argv) == 3 and sys.argv[2] in ("l1", "l2", "null") + V40_VARIANTS:
        json.dump(rpu_config(sys.argv[2]), sys.stdout, indent=1)
    else:
        sys.exit(__doc__)
