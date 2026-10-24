# Colour representation on the software route

What `PlanarFrameFinisher` does to a decoded picture's sample values, written as the equations it implements.
The source is **Rec. ITU-T H.273 (V4) (07/2024)** (twin text ISO/IEC 23091-2); equation numbers below are
H.273's. The Metal kernels and the double-precision reference in the tests implement exactly this page.

The finisher never changes what the colour *is*. It changes how the same R′G′B′ is represented, where the
source's representation is one CoreVideo cannot tag: it decodes the samples to the signals H.273 defines
(E′R, E′G, E′B or E′Y, E′PB, E′PR) and encodes them again with a representation the display layer reads.
Colour primaries and transfer characteristics pass through as tags.

## Notation

From H.273 clause 5:

- `Round( x ) = Sign( x ) * Floor( Abs( x ) + 0.5 )` (8)
- `Clip3( x, y, z )` = x if z < x, y if z > y, else z (4); `Clip1Y( x ) = Clip3( 0, ( 1 << BitDepthY ) − 1, x )` (2),
  `Clip1C` likewise with BitDepthC.
- `( x )′` is the transfer characteristics function (Table 3) applied to x.

`d` is a source component's bit depth, `n` the output's (8, 10 or 16).

## 1. Codes and signals

### Y′CbCr (MatrixCoefficients 1, 4–7, 9–15)

Encoding, VideoFullRangeFlag = 0 (30–32):

    Y  = Clip1Y( Round( ( 1 << ( n − 8 ) ) * ( 219 * E′Y  + 16  ) ) )
    Cb = Clip1C( Round( ( 1 << ( n − 8 ) ) * ( 224 * E′PB + 128 ) ) )
    Cr = Clip1C( Round( ( 1 << ( n − 8 ) ) * ( 224 * E′PR + 128 ) ) )

VideoFullRangeFlag = 1 (36–38):

    Y  = Clip1Y( Round( ( ( 1 << n ) − 1 ) * E′Y ) )
    Cb = Clip1C( Round( ( ( 1 << n ) − 1 ) * E′PB + ( 1 << ( n − 1 ) ) ) )
    Cr = Clip1C( Round( ( ( 1 << n ) − 1 ) * E′PR + ( 1 << ( n − 1 ) ) ) )

Decoding a d-bit code is the exact inverse of the matching pair (no rounding):

    video:  E′Y = ( Y / 2^(d−8) − 16 ) / 219        E′PB = ( Cb / 2^(d−8) − 128 ) / 224
    full:   E′Y = Y / ( 2^d − 1 )                  E′PB = ( Cb − 2^(d−1) ) / ( 2^d − 1 )

### A change of bit depth

Decoding at d bits and encoding at n bits, same range:

- **Video range:** `Y_n = Y_d * 2^(n−d)`, a left shift, exact; the same for chroma.
- **Full range:** `Y_n = Round( Y_d * ( 2^n − 1 ) / ( 2^d − 1 ) )`,
  `C_n = Round( ( C_d − 2^(d−1) ) * ( 2^n − 1 ) / ( 2^d − 1 ) + 2^(n−1) )`. Not a shift: full-range 8-bit 255 is
  10-bit 1023, not 1020.

### Ordered dither to 10 bits

When the source is deeper than the 10 bits a P010 / P210 / P410 buffer keeps, the 10-bit target value is formed
with six fraction bits (a 16-bit word `w = Round( 64 * target )`, which for video range is `C_d << (16 − d)`
exactly) and ordered down: `w′ = ( w + T ) & 0xFFC0`, saturating at `0xFFC0`, with `T` the 8x8 Bayer threshold
(0...63) at (row & 7, word & 7) of the plane's 16-bit words. Not part of H.273; it replaces truncation.

### R′G′B′ codes (MatrixCoefficients 0, 8, 16, 17)

`BitDepthRGB` = BitDepthY for 0 and 8 (23), BitDepthY − 2 for 16 (24), BitDepthY − 1 for 17 (25);
`MaxValRGB = ( 1 << BitDepthRGB ) − 1` (26). The codes relate to E′ as (27–29) and (33–35):

    video:  R = Clip3( 0, MaxValRGB, ( 1 << ( BitDepthRGB − 8 ) ) * ( 219 * E′R + 16 ) )
    full:   R = Clip3( 0, MaxValRGB, MaxValRGB * E′R )

so `E′R = ( R / 2^(BitDepthRGB−8) − 16 ) / 219` or `E′R = R / MaxValRGB`. **An RGB source can be video range**:
the range flag applies to it as to Y′CbCr.

## 2. Matrices

### K_R and K_B (Table 4)

| MC | K_R | K_B | |
|---|---|---|---|
| 1 | 0.2126 | 0.0722 | BT.709 |
| 4 | 0.30 | 0.11 | FCC |
| 5, 6 | 0.299 | 0.114 | BT.601 (functionally the same) |
| 7 | 0.212 | 0.087 | SMPTE ST 240 |
| 9, 10 | 0.2627 | 0.0593 | BT.2020 NCL / CL |
| 12, 13 | from the colour primaries, (39)–(44) | | chromaticity-derived |

For 12 and 13, with (x, y) of red, green, blue and white from Table 2 and `z = 1 − ( x + y )` (41–44):

    K_R = y_R * ( x_W * ( y_G * z_B − y_B * z_G ) + y_W * ( x_B * z_G − x_G * z_B ) + z_W * ( x_G * y_B − x_B * y_G ) )
        / ( y_W * ( x_R * ( y_G * z_B − y_B * z_G ) + x_G * ( y_B * z_R − y_R * z_B ) + x_B * ( y_R * z_G − y_G * z_R ) ) )   (39)

    K_B = y_B * ( x_W * ( y_R * z_G − y_G * z_R ) + y_W * ( x_G * z_R − x_R * z_G ) + z_W * ( x_R * y_G − x_G * y_R ) )
        / ( y_W * ( x_R * ( y_G * z_B − y_B * z_G ) + x_G * ( y_B * z_R − y_R * z_B ) + x_B * ( y_R * z_G − y_G * z_R ) ) )   (40)

### Colour primaries for (39)–(44) (Table 2)

| CP | red x, y | green x, y | blue x, y | white x, y |
|---|---|---|---|---|
| 1 | 0.640, 0.330 | 0.300, 0.600 | 0.150, 0.060 | 0.3127, 0.3290 (D65) |
| 4 | 0.67, 0.33 | 0.21, 0.71 | 0.14, 0.08 | 0.310, 0.316 (C) |
| 5 | 0.64, 0.33 | 0.29, 0.60 | 0.15, 0.06 | 0.3127, 0.3290 |
| 6, 7 | 0.630, 0.340 | 0.310, 0.595 | 0.155, 0.070 | 0.3127, 0.3290 |
| 8 | 0.681, 0.319 | 0.243, 0.692 | 0.145, 0.049 | 0.310, 0.316 (C) |
| 9 | 0.708, 0.292 | 0.170, 0.797 | 0.131, 0.046 | 0.3127, 0.3290 |
| 11 | 0.680, 0.320 | 0.265, 0.690 | 0.150, 0.060 | 0.314, 0.351 |
| 12 | 0.680, 0.320 | 0.265, 0.690 | 0.150, 0.060 | 0.3127, 0.3290 |
| 22 | 0.630, 0.340 | 0.295, 0.605 | 0.155, 0.077 | 0.3127, 0.3290 |

10 (SMPTE ST 428, XYZ) is refused (section 4). A chromaticity-derived stream (MC 12, 13) whose primaries are
unspecified or reserved has no K_R, K_B and is refused.

### Non-constant luminance (MC 1, 4–7, 9, 12)

Encoding (45–47): `E′Y = K_R E′R + ( 1 − K_R − K_B ) E′G + K_B E′B`, `E′PB = 0.5 ( E′B − E′Y ) / ( 1 − K_B )`,
`E′PR = 0.5 ( E′R − E′Y ) / ( 1 − K_R )`. Decoding is its exact inverse:

    E′R = E′Y + 2 ( 1 − K_R ) E′PR
    E′B = E′Y + 2 ( 1 − K_B ) E′PB
    E′G = ( E′Y − K_R E′R − K_B E′B ) / ( 1 − K_R − K_B )

### Constant luminance (MC 10, 13)

Encoding (66–75): `E_Y = K_R E_R + ( 1 − K_R − K_B ) E_G + K_B E_B` in linear light, `E′Y = ( E_Y )′`, and

    E′PB = ( E′B − E′Y ) / ( 2 N_B )  for −N_B <= E′B − E′Y <= 0        N_B = ( 1 − K_B )′     (68), (72)
    E′PB = ( E′B − E′Y ) / ( 2 P_B )  for 0 < E′B − E′Y <= P_B          P_B = 1 − ( K_B )′     (69), (73)
    E′PR likewise with N_R = ( 1 − K_R )′, P_R = 1 − ( K_R )′                                  (70), (71), (74), (75)

Decoding: the sign of E′PB is the sign of E′B − E′Y, so

    E′B = E′Y + 2 N_B E′PB  if E′PB <= 0,   E′Y + 2 P_B E′PB  otherwise
    E′R = E′Y + 2 N_R E′PR  if E′PR <= 0,   E′Y + 2 P_R E′PR  otherwise
    E_R, E_B, E_Y = inverse transfer of E′R, E′B, E′Y
    E_G = ( E_Y − K_R E_R − K_B E_B ) / ( 1 − K_R − K_B ),   E′G = ( E_G )′

### YCgCo (MC 8, BitDepthC = BitDepthY) and YCgCo-R (MC 8 with BitDepthC ≠ BitDepthY, 16, 17)

Integer inverses on the codes, `h = 1 << ( BitDepthC − 1 )`:

    YCgCo (54–57):    t = Y − ( Cb − h );  G = Clip1Y( Y + ( Cb − h ) );  B = Clip1Y( t − ( Cr − h ) );  R = Clip1Y( t + ( Cr − h ) )
    YCgCo-R (62–65):  t = Y − ( ( Cb − h ) >> 1 );  G = Clip3( 0, MaxValRGB, t + ( Cb − h ) );
                      B = Clip3( 0, MaxValRGB, t − ( ( Cr − h ) >> 1 ) );  R = Clip3( 0, MaxValRGB, B + ( Cr − h ) )

`>>` is an arithmetic shift of a signed value (H.273 5.3). The variables are assigned in order, so the `B` in
(65) is the clipped B of (64). The R, G, B codes then decode to E′ by section 1 (R′G′B′ codes).

### Identity (MC 0)

`Y = G`, `Cb = B`, `Cr = R` (48–50): libavcodec hands these over as planar GBR, and they decode to E′ by
section 1 (R′G′B′ codes). Primaries 10 (SMPTE ST 428 XYZ) make the planes Y, Z, X: refused (see 4).

## 3. Transfer characteristics (Table 3), for constant luminance

Each forward function V = f( L ) and its inverse. α and β are defined by H.273 as the constants that make the
segments meet with continuous value and slope:

| TC | Forward | Inverse | Constants |
|---|---|---|---|
| 1, 6, 14, 15 | `4.5 L` for L < β; `α L^0.45 − ( α − 1 )` | `V / 4.5` for V < 4.5 β; `( ( V + α − 1 ) / α )^( 1 / 0.45 )` | α = 1.099296826809442, β = 0.018053968510807 |
| 7 | `4.0 L` for L < β; `α L^0.45 − ( α − 1 )` | as above with 4.0 | α = 1.111572195921731, β = 0.022821585529445 |
| 4 | `L^( 1 / 2.2 )` | `V^2.2` | H.273 says only "assumed display gamma 2.2"; the power law is the conventional reading |
| 5 | `L^( 1 / 2.8 )` | `V^2.8` | likewise, "assumed display gamma 2.8" |
| 8 | `L` | `V` | |
| 13 (MC ≠ 0) | `12.92 L` for −β < L < β; `α L^( 1/2.4 ) − ( α − 1 )` for L >= β; odd-symmetric below −β | the inverse of each segment | α = 1.055010718947587, β = 0.003041282560128 |
| 16 (PQ) | `( ( c1 + c2 L^n ) / ( 1 + c3 L^n ) )^m` | `( max( V^(1/m) − c1, 0 ) / ( c2 − c3 V^(1/m) ) )^( 1/n )` | c1 = 107/128, c2 = 2413/128, c3 = 2392/128, m = 2523/32, n = 1305/8192 |
| 18 (HLG) | `Sqrt( 3 ) L^0.5` for L <= 1/12; `a Ln( 12 L − b ) + c` | `V^2 / 3` for V <= 0.5; `( Exp( ( V − c ) / a ) + b ) / 12` | a = 0.17883277, b = 0.28466892, c = 0.55991073 |

The α and β for TC 7 and 13 are computed from that definition: both conditions hold to 1e-15 at the values
above. The familiar rounded 1.1115 / 0.0228 and 1.055 / 0.0031308 do not meet it. For TC 1 the same computation
reproduces H.273's quoted values, which also satisfy its α = 1 + 5.5 β. A constant-
luminance stream with any other TC (2, 3, 9–12, 17, reserved) is refused: no inverse is defined over its range.

## 4. What the finisher does per MatrixCoefficients

| MC | CoreVideo tag | Finisher |
|---|---|---|
| 1, 5, 6, 7, 9 | 709 / 601 / 601 / 240M / 2020 | samples kept; tagged |
| 14 (ICtCp) | `ITU_R_2100_ICtCp` (CoreVideo's own; not in the public headers) | samples kept; tagged |
| 0 (GBR) | none | decode R′G′B′ codes; encode Y′CbCr |
| 4, 12 | none | decode NCL with the source K_R, K_B; encode |
| 10, 13 | none (10 used to be tagged as 9, wrongly) | decode constant luminance; encode |
| 8, 16, 17 | none | YCgCo / YCgCo-R inverse; encode |
| 2 (unspecified) | inferred (`ColorAttachments.presented`) | samples kept; tagged |
| 11 (Y′D′ZD′X), primaries 10 (XYZ) | none | refused: XYZ has no CoreVideo primaries; showing it is a gamut conversion, not a representation change |
| 15 (IPT-C2) | `IPT_C2` | refused here: Dolby Vision profile 5, decoded only with its RPU |
| 3, 18–255 | | refused (reserved) |

**Encoding:** non-constant luminance (45–47), then (30–32) or (36–38) at the output depth and the source's
range (video range for RGB sources and for 16-bit outputs, which CoreVideo defines video range only). K_R, K_B
of the output matrix follow the primaries: BT.2020 → MC 9; BT.709 and P3 (11, 12) → MC 1; BT.601 625 / 525,
SMPTE 240 (5, 6, 7) → MC 6 (the BT.601 tag); anything else → MC 1. CoreVideo's P3 matrix tags are deprecated
"no longer supported" (CVImageBuffer.h); any non-constant-luminance matrix carries R′G′B′ exactly, so the
choice only picks a tag the display decodes.

**Chroma:** a converted picture is written 4:4:4 (NV24 / P410 / P416). Every equation above is per pixel, and
10, 13 are not linear, so chroma is first resampled to every luma site (Catmull-Rom at the stream's chroma
siting) and the result is not subsampled again.

## 5. Precision

- **Integer paths** (pack, grey, full-range scaling, the dither) are exact: video range is a shift, and full
  range is evaluated in 64-bit integers. Its quotients have odd denominators, so they never tie, but float32
  cannot place them against the tie at 16-bit words.
- **RGB** is evaluated in 64-bit fixed point with 30 fraction bits (the affine rows are computed in double on the
  host). The error is under 2^-14 of a code.
- **Chroma resampling** is float32. At quarter and half phases the Catmull-Rom weights are n / 128, so the
  sums are exact.

`PlanarFrameFinisherTests` checks every output code against a float64 reference of this page, reading the
source through FFmpeg's `av_read_image_line2`. Every code must match, except where the reference lies within
1e-4 of a rounding tie.

## 6. Chroma siting

The resampler places samples by FFmpeg's `chroma_location`, which carries each codec's signal:

- H.264 / HEVC: `chroma_sample_loc_type` k is location k + 1; type 0 (LEFT) when the VUI carries none, as the
  specs infer.
- AV1: `CSP_VERTICAL` is LEFT and `CSP_COLOCATED` TOPLEFT (libdav1d).
- UNSPECIFIED resolves to LEFT, or CENTER for a JPEG (yuvj) format.

Horizontally, LEFT / TOPLEFT / BOTTOMLEFT are co-sited with the left luma sample and the others are centred.
Vertically, TOPLEFT / TOP sit on the top row, LEFT / CENTER between the rows, and BOTTOMLEFT / BOTTOM on the
bottom row. An interlaced picture is never resampled vertically: its chroma rows alternate between the fields.
