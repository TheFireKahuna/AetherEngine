#!/usr/bin/env python3
"""The amplifier test card (p7fel_card) and its fallback (p7fel_bullseye) on the Mac: a numpy model of the engine's
FEL composer luma path, the feltest verification, and preview images of what each outcome looks like on screen.

Usage: card.py verify [--out DIR] [--modes m1,m2]  run `aetherctl feltest --probe-at` on every card element in every
                                                   --fel-output mode, compare each word with the model, print a table
       card.py preview [--out DIR]                 out/card_preview_<outcome>.png (1920x1080) and out/CARD.md
       card.py bullseye [--out DIR]                model statistics for p7fel_bullseye, plus feltest probes

The model reads the dither tables from the engine's own shader source (DolbyVisionFEL.metal) and mirrors
dovi_compose_luma: identity polynomial (vdr = 4 * BL), bilinear centre-aligned EL upsampling rounded half up,
DoviFelComposer.inverseNlq, then the output quantiser of each mode. feltest needs the engine's DualLayerDolbyVision
trait; it is run from the AetherEngine root with DEVELOPER_DIR set to Xcode (override with $DEVELOPER_DIR).
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

import gen_pulse as gp

HERE = Path(__file__).resolve().parent
ENGINE = HERE.parents[2]
SHADER = ENGINE / "Sources/AetherFELShaders/Shaders/DolbyVisionFEL.metal"
MODES = ["p010-round", "p010", "p010-bluenoise", "p010-full", "sv22"]


# ---------------------------------------------------------------- composer model
def shader_tables():
    src = SHADER.read_text()
    m = re.search(r"dovi_bayer_8x8\[64\] = \{(.*?)\};", src, re.S)
    bayer = np.array([float(a) / float(b) for a, b in re.findall(r"([\d.]+)f/([\d.]+)f", m.group(1))])
    m = re.search(r"dovi_blue_noise_64\[4096\] = \{(.*?)\};", src, re.S)
    blue = np.array([int(v) for v in re.findall(r"\d+", m.group(1))])
    assert bayer.size == 64 and blue.size == 4096, (bayer.size, blue.size)
    return bayer.reshape(8, 8), blue.reshape(64, 64)


def upsample_el(el):
    """dovi_upsample_el + dovi_el_code for a 2:1 EL: bilinear at n_el = (n + 1/2) / 2 - 1/2, edges clamped."""
    def axis(n_bl, n_el):
        u = (np.arange(n_bl) + 0.5) * 0.5 - 0.5
        i = np.floor(u)
        f = u - i
        i = i.astype(int)
        return np.clip(i, 0, n_el - 1), np.clip(i + 1, 0, n_el - 1), f
    y0, y1, fy = axis(gp.H, el.shape[0])
    x0, x1, fx = axis(gp.W, el.shape[1])
    e = el.astype(np.float64)
    top = e[y0][:, x0] * (1 - fx) + e[y0][:, x1] * fx
    bot = e[y1][:, x0] * (1 - fx) + e[y1][:, x1] * fx
    v = top * (1 - fy)[:, None] + bot * fy[:, None]
    return np.floor(v + 0.5).astype(int)


def compose_vdr(bl, el):
    lut = np.array([gp.inverse_nlq(c) for c in range(1024)])
    return np.clip(4 * bl.astype(int) + lut[upsample_el(el)], 0, 4095)


def quantize(vdr, mode, frame=0, tables=None):
    """Raw 16-bit luma words the engine writes for VDR values `vdr` (full 4K plane) in output `mode`."""
    if mode in ("p010-full", "sv22"):
        return np.clip((vdr * 64 + 2) // 4, 64 << 6, 940 << 6)
    v = vdr / 4.0
    if mode == "p010-round":
        d = 0.5
    else:
        bayer, blue = tables or shader_tables()
        yy, xx = np.mgrid[0:vdr.shape[0], 0:vdr.shape[1]]
        if mode == "p010":
            d = bayer[yy % 8, xx % 8]
            if frame & 1:
                d = 63 / 64 - d
            d = d + 0.5 / 64
        else:
            d = (blue[yy & 63, xx & 63] + 0.5) / 4096
    return np.clip(np.floor(v + d), 64, 940).astype(int) << 6


def card_planes():
    return np.full((gp.H, gp.W), gp.CARD_N), gp.card_el_plane()


# ---------------------------------------------------------------- feltest
def feltest(clip, mode, x, y, frames=48):
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    cmd = ["swift", "run", "--traits", "DualLayerDolbyVision", "aetherctl", "feltest", "--frames", str(frames),
           "--fel-output", mode, "--probe-at", f"{x},{y}", str(clip)]
    out = subprocess.run(cmd, cwd=ENGINE, env=env, capture_output=True, text=True).stdout
    words = []
    for a, b, w in re.findall(r"frames (\d+)-(\d+): (\d+) =", out):
        words += [int(w)] * (int(b) - int(a) + 1)
    if not words:
        sys.exit(f"feltest gave no probe words for {mode} at {x},{y}:\n{out[-2000:]}")
    return words


def fmt(w):
    return f"{w} ({w >> 6}+{w & 63}/64)"


def verify(out, modes, clip=None, elements=None, planes=None, label="card"):
    clip = clip or out / "p7fel_card.mp4"
    elements = elements or gp.card_design()["elements"]
    vdr = compose_vdr(*(planes or card_planes()))
    tables = shader_tables()
    model = {(m, f): quantize(vdr, m, f, tables) for m in modes for f in (0, 1)}
    rows, ok = [], True
    for e in elements:
        x, y = e["probe"]
        for m in modes:
            dithered = m in ("p010", "p010-bluenoise")
            pts = [(x + i, y + j) for j in range(4) for i in range(4)] if dithered else [(x, y)]
            seen, hi, n = set(), 0, 0
            for px, py in pts:
                words = feltest(clip, m, px, py)
                want = {int(model[(m, f)][py, px]) for f in ((0, 1) if m == "p010" else (0,))}
                if not set(words) <= want or (m == "p010" and len(want) == 2 and set(words) != want):
                    ok = False
                    print(f"MISMATCH {label} {e['name']} {m} at {px},{py}: engine {sorted(set(words))}, model {sorted(want)}")
                seen |= set(words)
                hi += sum(w > (vdr[py, px] // 4) << 6 for w in words)
                n += len(words)
            rows.append((e["name"], m, e.get("expect_code"), sorted(seen), hi / n if dithered else None, len(pts)))
    print(f"\n{label}: raw 16-bit luma words (10-bit code + fraction/64); dithered modes over a 4x4 pixel block x 42 frames")
    print(f"{'element':11} {'mode':15} {'designed':>9}  words seen                         share at code+1")
    for name, m, exp, seen, share, npx in rows:
        s = ", ".join(fmt(w) for w in seen)
        print(f"{name:11} {m:15} {exp if exp is not None else '':>9}  {s:34} {'' if share is None else f'{100 * share:.0f}%'}")
    print("engine == model for every probed pixel and frame" if ok else "SOME PIXELS DIFFER FROM THE MODEL")
    return ok


# ---------------------------------------------------------------- previews
def pq_nits(e):
    m1, m2 = 2610 / 16384, 2523 / 4096 * 128
    c1, c2, c3 = 3424 / 4096, 2413 / 4096 * 32, 2392 / 4096 * 32
    p = np.power(np.clip(e, 0, 1), 1 / m2)
    return 10000 * np.power(np.maximum(p - c1, 0) / (c2 - c3 * p), 1 / m1)


OUTCOMES = [
    ("identity", "control: the engine's usual identity RPU, any outcome", "flat grey: the card is invisible without the amplifier"),
    ("truncated", "the 12-bit composite truncated to 10 bits before the amplifier", "border only"),
    ("rounded", "rounded to 10 bits (p010-round, or a path that rounds)", "border and 1/2"),
    ("bayer", "p010 (Bayer dither) reaching the amplifier at 10 bits", "border solid; 1/2 and 12 as fine stipple at their mean level"),
    ("bluenoise", "p010-bluenoise reaching the amplifier at 10 bits", "border solid; 1/2 and 12 as fine grain at their mean level"),
    ("full12", ">= 12 bits reach the amplifier (p010-full / sv22 intact)", "border, 1/2 and 12 all solid and smooth"),
]


def delivered(vdr, outcome, tables):
    """The value (in 10-bit codes) that reaches the amplifier under each outcome."""
    if outcome in ("full12", "identity"):
        return vdr / 4.0
    if outcome == "truncated":
        return (vdr // 4).astype(float)
    mode = {"rounded": "p010-round", "bayer": "p010", "bluenoise": "p010-bluenoise"}[outcome]
    return (quantize(vdr, mode, 0, tables) >> 6).astype(float)


def preview(out):
    from PIL import Image, ImageDraw, ImageFont
    vdr = compose_vdr(*card_planes())
    tables = shader_tables()
    white = 250.0                                   # display nits mapped to PNG white
    lines = []
    for name, what, expect in OUTCOMES:
        x = delivered(vdr, name, tables)
        y10 = x if name == "identity" else gp.amp_curve(x)
        nits = pq_nits((y10 - 64) / 876)
        nits = nits.reshape(gp.H // 2, 2, gp.W // 2, 2).mean(axis=(1, 3))   # 2x2 average, in linear light
        img = np.round(255 * np.power(np.clip(nits / white, 0, 1), 1 / 2.2)).astype(np.uint8)
        im = Image.fromarray(img, "L").convert("RGB")
        d = ImageDraw.Draw(im)
        try:
            font = ImageFont.load_default(size=28)
        except TypeError:
            font = ImageFont.load_default()
        d.text((90, 880), f"{name}: {what}", fill=(255, 220, 0), font=font)
        d.text((90, 920), f"expect: {expect}", fill=(255, 220, 0), font=font)
        im.save(out / f"card_preview_{name}.png")
        vals = {e["name"]: float(gp.amp_curve(np.array(x[e["probe"][1], e["probe"][0]])) if name != "identity"
                                 else x[e["probe"][1], e["probe"][0]]) for e in gp.card_design()["elements"]}
        lines.append(f"| `card_preview_{name}.png` | {what} | {expect} |")
        print(f"card_preview_{name}.png  " + "  ".join(f"{k}={v:.2f}" for k, v in vals.items()))
    f_n = gp.amp_curve(gp.CARD_N)
    md = f"""# p7fel_card: the amplifier test card

Composed luma (12-bit VDR, shown as 10-bit code + fraction): background {gp.CARD_N}, "12" {gp.CARD_N}.25, "1/2"
{gp.CARD_N}.5, border {gp.CARD_N + 1}. With the engine's usual identity RPU that is flat ~{pq_nits((gp.CARD_N - 64) / 876):.0f}-nit grey. With
`card_amp10.bin` attached instead, whoever applies the RPU's luma curve maps [{gp.CARD_LO}, {gp.CARD_HI}) with slope
{gp.CARD_SLOPE}: background -> {f_n:.0f} (~{pq_nits((f_n - 64) / 876):.0f} nit), "12" -> {gp.amp_curve(gp.CARD_N + .25):.0f}, "1/2" ->
{gp.amp_curve(gp.CARD_N + .5):.0f}, border -> {gp.amp_curve(gp.CARD_N + 1):.0f} (~{pq_nits((gp.amp_curve(gp.CARD_N + 1) - 64) / 876):.0f} nit). Legend: the border is the control and must show
whenever the amplifier is applied; "1/2" shows when the path rounds or keeps 11+ bits and vanishes when it
truncates; "12" shows only if 12 bits reach the amplifier. Solid, smooth glyphs mean the bits survived. A glyph
that shows as stipple or grain is dither (p010 / p010-bluenoise) carrying the mean through 10 bits, which is a
positive control for the path but not proof of 12 bits. If even the border is missing, the curve is not being
applied (or the RPU was dropped). The previews assume the TV renders 100-200 nit 1:1 (PNG white = {white:.0f} nit,
gamma 2.2) and average 2x2 pixels in linear light.

| preview | outcome | what shows |
| --- | --- | --- |
""" + "\n".join(lines) + "\n"
    (out / "CARD.md").write_text(md)
    print(f"wrote {out / 'CARD.md'}")


# ---------------------------------------------------------------- bullseye
def bullseye(out):
    Y, el, target = gp.bullseye_planes()
    vdr = compose_vdr(Y, el)
    want = np.repeat(np.repeat(target, 2, axis=0), 2, axis=1)
    cols = np.ones(gp.W, bool)
    cols[gp.W // 2 - gp.BULL_DIVIDER // 2:gp.W // 2 + gp.BULL_DIVIDER // 2] = False
    for side, sl in (("left (10-bit)", slice(0, gp.W // 2)), ("right (12-bit)", slice(gp.W // 2, gp.W))):
        d = (vdr - want)[:, sl][:, cols[sl]]
        v = vdr[:, sl][:, cols[sl]]
        print(f"{side:15} VDR {v.min()}..{v.max()}, multiples of 4: {100 * np.mean(v % 4 == 0):.1f}%, "
              f"off target: {100 * np.mean(d != 0):.2f}% of pixels (max |err| {np.abs(d).max()} VDR)")
    w = gp.W // 2
    planes = (Y, el)
    pts = [{"name": "right-ring", "probe": [w + 600, gp.H // 2 + 1], "expect_code": None},
           {"name": "left-ring", "probe": [w - 600, gp.H // 2 + 1], "expect_code": None}]
    for p in pts:
        x, y = p["probe"]
        p["expect_code"] = vdr[y, x] / 4
    verify(out, ["p010-full", "p010-round"], clip=out / "p7fel_bullseye.mp4", elements=pts, planes=planes, label="bullseye")


if __name__ == "__main__":
    args = sys.argv[1:]
    cmd = args[0] if args else ""
    out = Path(args[args.index("--out") + 1]) if "--out" in args else HERE.parent / "out"
    modes = args[args.index("--modes") + 1].split(",") if "--modes" in args else MODES
    if cmd == "verify":
        sys.exit(0 if verify(out, modes) else 1)
    elif cmd == "preview":
        preview(out)
    elif cmd == "bullseye":
        bullseye(out)
    else:
        sys.exit(__doc__)
