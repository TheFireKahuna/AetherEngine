# The software route: one GPU pass, inside the native player

Status: plan, written 2026-10-24 on `research/12bit-fel`. Parts 2 (the GPU finisher and H.273 colour) and 3 (AV1 into
the slabs) are built and committed; parts 4 (bwdif on the GPU) and 6 (film in interlaced carriage) are built and verified on device; part 5 (AV1 film grain) is built and conformance-tested; parts 1 and 7 are open. The colour equations are in [colour-representation.md](colour-representation.md).

## Why

The engine has two playback architectures. The native route plays through AVPlayer (HLS the engine serves itself);
the software route (`SoftwarePlaybackHost`) decodes with FFmpeg / dav1d and renders through
`AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` on its own clock. Every feature is built twice or
missing on one side: audio (Atmos needed the silent-AVPlayer keep-alive trick on the software route), lip sync,
subtitles, AVKit's transport bar (the private-controller spike rendered it but it never ticked), scrub thumbnails,
seeking. The software route also copied every decoded picture on the CPU (swscale), and its deinterlacer front end
copied twice more.

The goal is one architecture: **software-decoded pictures shown inside the native player**, and **no CPU pass over
the pixels after decode**.

## Part 1. The software route inside AVPlayer (open)

### The idea

AVPlayer plays a **placeholder** video track in the source's real format, with its rendering suppressed
(`AVPlayerItemVideoOutput.suppressesPlayerRendering`), and the source's real audio. Our decoder's pictures are drawn
on a sample-buffer layer inside AVKit's player layer, under the subtitles, timed by the item's clock. This is the
FEL overlay route (`FelOverlayRenderer`) without the base layer: AVPlayer owns the clock, audio, transport, subtitles,
seeking and the display mode; we own the picture.

### What the device probes established (LG G5, Apple TV 4K 3rd gen, tvOS 27.2)

Probe: `Probes/DolbyVisionPulse`, `SEQ=placeholder` (`Scripts/build_placeholder.sh`, `Device/Host/PulsePlaceholder.swift`;
not committed yet).

- The display mode follows the placeholder: a `dvh1` placeholder puts the TV in Dolby Vision, `hvc1` HDR10 in HDR10.
- **The Dolby Vision metadata that reaches the panel is always the RPU in the stream AVPlayer plays, never the overlay
  layer's `DolbyVisionRPUData` attachment.** Arms GD (placeholder constant RPU, overlay pulsing RPU) and GV
  (HDR10 placeholder, DV criteria set by the host) stayed steady; GX (placeholder pulsing, overlay constant) pulsed.
- The FEL overlay works because `DoviRpuConverter.separateDualLayers` writes the composed-form 8.1 RPU into the
  packets AVPlayer plays (`out = thisFEL ? forms.composed : forms.baseLayer`); the overlay's own attachment is
  redundant.
- **Arm GE, the intended design, worked:** a `dvh1` placeholder carrying the source's per-frame RPU (`ph_dv_l2`),
  AVKit setting the mode, the overlay showing the source's frames (`pulse_l2`): Dolby Vision, the pulse in step.

### Design

- **The placeholder** is built on device per source, with VideoToolbox's hardware encoder (a flat picture encoded
  once, then stamped with the source's timestamps; no hand-written bitstream). It matches the source in coded and
  display size (crop, aspect), Main10 or the source's profile, colour primaries, transfer and matrix in the VUI, and
  frame rate. Its keyframes and segments are ours to choose (short, about 1 s, each starting on a keyframe): scrub
  thumbnails come from the separate SDR I-frame tier built from source keyframes, not from the placeholder.
- **Metadata rides in the placeholder bitstream, with the source's values**, in the packet with the matching
  timestamp: the Dolby Vision RPU as an unspec62 NAL (for AV1 profile 10 moved from its T.35 OBU), HDR10+ as SEI,
  mastering display and content light level as SEI and in the init segment (`mdcv` / `clli`) from the source, none if
  the source has none.
- **Readiness is the segment server's.** AVPlayer waits only for decoders it owns. The engine serves the HLS, so it
  holds the placeholder segment for time T until our decoder has frames past T plus a margin: after a seek AVPlayer
  waits for the segment at the target, and a decoder falling behind stalls AVPlayer at a segment boundary with its
  own spinner. Decoded frames held ahead: about a second at 4K (P010, a few hundred MB), tuned by segment length.
- **Timing follows what the FEL overlay follows.** The FEL overlay presents against
  `AVPlayerItemVideoOutput.itemTime(forHostTime:)` with display-link stamping and measured picture against audio at
  -23.7 ms, steady. The placeholder probe's child-of-`item.timebase` layer read about +170 ms against `item.timebase`;
  that probe did not time frames the way the FEL overlay does, so the overlay generalises `FelOverlayRenderer`'s
  presentation instead.
- **The overlay generalises `FelOverlayRenderer`** from "compose the FEL residual" to "present the frame source
  attached": FEL composition and software decode become two frame sources for one presenter.

### Order of work

1. Commit the placeholder probe (the files above, `run_tv.sh`'s `SEQ=placeholder`, `PH_ARMS`).
2. Placeholder builder (VideoToolbox, per source, at load) with per-packet RPU / HDR10+ injection in
   `HLSSegmentProducer`.
3. Segment gating by decoder readiness in the segment server.
4. `FelOverlayRenderer` generalised to any frame source; software decoders feed it.
5. A device check per arm the probe already has (DV, HDR10, HLG, Atmos, transport bar, pause, scrub, seek), then a
   lip-sync check with a flash-and-beep clip filmed by phone.

### SoftwarePlaybackHost

Once the overlay plays every software codec, the software host is dead code for this fork. Decision pending: revert
our fork's edits to the software host to upstream's version and leave it in place (merges stay clean), or delete it.
Our edits there total about 2.1k lines (`AudioOutput`, `AudioRendererIO`, `VideoRendererIO`, `DualLayerVideoDecoder`,
`SoftwarePlaybackHost`, `SampleBufferRenderer`, the APAC keep-alive pieces). Shared files need per-file care:
`AtmosOutputActivator` is used by the native route, `AudioOutput` by the audio-only host, `DoviComposedRpuOverride`
by the overlay. `aetherctl play --fel` and the pulse probe's soak arm use the software route on purpose.

## Part 2. Zero-copy decode and the GPU finisher (built)

Commits: `b91a82e3` (allocator, finisher, parity with the CPU path), `9f88396e` (decoder switch, swscale gone),
`c2849b34` (exact integer resampling), `0dc762d8` (matrix conversions), `a29388b3` (constant luminance, float32 fast
path with exact rounding, block threads, luma table), `3df7eaa6` (the colour document).

- **`DecodeFrameAllocator`** (`Decoder/DecodeFrameAllocator.swift`): `get_buffer2` for every DR1 decoder, laying planes
  out as `avcodec_default_get_buffer2` does inside shared-storage `MTLBuffer` slabs; libavcodec's reference counting
  returns them. Pictures a decoder keeps in its own memory (rawvideo, which points into the packet; libavcodec's
  paletted buffers) are copied into a slab: for rawvideo the copy is the decode, and its rate is bounded by the input.
- **`PlanarFrameFinisher`** (`Video/Metal/`): one GPU pass into the display buffer. The source is read from its
  `AVPixFmtDescriptor` as `av_read_image_line2` reads it (planar, semi-planar, packed, grey, RGB, palette, bitstream,
  big-endian); a format it cannot describe is refused when the decoder opens. Each format gets a pipeline specialised
  with function constants.
- **Conformance** to H.273 and the codec specs, every output code correctly rounded (colour-representation.md
  sections 4 and 5): full range scaled by (2^n - 1), RGB at its own range, chroma siting from each codec's signal,
  exact integer Catmull-Rom resampling, no vertical resampling of interlaced pictures, `AV_CODEC_FLAG_UNALIGNED` so
  the conformance window's left crop is exact, every MatrixCoefficients value converted, tagged or refused.
- Two output bugs of the swscale path were measured and fixed with it: the last chroma column of an odd-width 4:2:0
  picture into P010 was never written (`planarToP01xWrapper` writes `src_w / 2`), and a left crop was rounded down
  for CPU alignment.
- Speed, 4K frame, M4 Pro, warm GPU: pack 0.2 to 0.6 ms, matrix conversion 4:2:0 to 4:4:4 1.5 ms, constant luminance
  1.2 to 1.5 ms. Not measured on the Apple TV yet.

## Part 3. libdav1d into the slabs (built)

FFmpeg's libdav1d wrapper allocates through its own `av_buffer_pool_init(size, NULL)` (`libavcodec/libdav1d.c:92`,
plain `av_malloc`) and never called `get_buffer2`, so AV1 pictures were copied into a slab. Built: FFmpegBuild
`1385171` (`patches/libdav1d-get-buffer2.patch`, in 3.10.1 at `768d164`); the engine installs its allocator on libdav1d
as on every DR1 decoder, and `Dav1dSlabDecodeTests` checks every picture lands in a slab and equals libdav1d's own
decode.

1. FFmpegBuild patch (`patches/`): `libdav1d_picture_allocator` asks `avctx->get_buffer2` for a picture of the
   128-aligned size when the caller supplied one, and uses its `buf[0]` as `allocator_data`. dav1d's contract: planes
   64-byte aligned, dimensions a multiple of 128, 64 bytes of padding, U and V sharing a stride; allocation on the
   thread calling `dav1d_get_picture`, release from any frame thread (`DecodeFrameAllocator`'s free callback is
   thread-safe). Test with `n_threads > 1`.
2. Release FFmpegBuild, bump the engine's pin, and add AV1 to the parity tests (a decode through the slab path equals
   the copied path).

## Part 4. Deinterlacing: FFmpeg's bwdif on the GPU (built, verified on device)

The first attempt ran `yadif_videotoolbox` on the finisher's display buffers and displayed its output directly
(`efeef135`). On the Apple TV the picture froze while frames kept being enqueued (`SEQ=deint`, 2026-10-25; the
progressive control moved). Cause: FFmpeg's VideoToolbox frames context keeps an AVBufferPool in front of its
CVPixelBufferPool and hands a buffer out again as soon as its AVFrame is freed, while the display layer still holds
it. The old VTPixelTransfer copy had hidden that. Rather than patch FFmpeg's pool, the deinterlacer moved into the
finisher, so every picture it shows comes from the finisher's own CoreVideo pool.

**Reference.** bwdif has no specification beyond FFmpeg's C, so the C is the reference: `libavfilter/bwdifdsp.c`
(the per-sample arithmetic), `vf_bwdif.c` (which rows, the reference offsets at the top and bottom, intra and edge
rows) and `yadif_common.c` (the window, parities, first and last fields, timestamps, progressive pass-through), with
`deint=interlaced` and `parity=auto`. `BwdifReferenceTests` runs libavfilter's bwdif and ours on the same frames and
requires every output equal: count, timestamps, every sample of every plane, 8 to 16 bits, 4:2:0 / 4:2:2 / 4:4:4 /
4:1:1 / 4:4:0 / 4:1:0, grey, semi-planar and packed sources (against bwdif on their planar equivalent), both field
orders, field and frame rate, odd sizes, progressive and repeat-field pictures, missing timestamps, one- and
two-picture streams.

**Structure.** Two dispatches in one GPU submission:

1. `pf_bwdif` ([LibDeinterlace](https://github.com/TheFireKahuna/LibDeinterlace)) reads the previous, current and
   next decoded pictures in their slabs through a descriptor reader and writes the deinterlaced components at the source's depth into a planar scratch
   picture (the source's planar equivalent: NV12 becomes yuv420p, P010 yuv420p10).
2. `pf_finish` reads the scratch as an ordinary progressive picture: every conversion and rounding guarantee of Part 2
   applies unchanged.

Splitting the stages keeps exactness checkable per stage (the scratch against libavfilter, the finisher against its
own reference) and costs one GPU-internal write and read of the source planes; a single kernel would run bwdif again
for every resampling tap.

**Throughput.** `BwdifWindow` (LibDeinterlace) holds references to the decoded frames, no copies. All the
outputs one decoded frame releases (the previous picture's second field, this one's first) go in one command buffer:
one commit, one wait. The encoder is concurrent: every bwdif dispatch of every field and plane runs together, then
one barrier, then every finishing dispatch (a constant-luminance job, whose later dispatches read its first's list,
gets its own serial command buffer). One thread writes four columns of a row pair, the kept row copied and the row
between interpolated, so the window's rows are shared through the cache. Integer arithmetic as the C (the 16-bit worst
case stays under 2^31). The bwdif pipeline compiles off-thread when the decoder opens a stream that declares
interlacing. Fields before a seek's target are scheduled (they are the next field's neighbours) but not written.

**Removed:** the yadif graph and its VideoToolbox device (`DeinterlaceFilter`), the warm-up and its wait in the load
path (`DeinterlaceHardwareWarmup`), `DeinterlaceMode`. FFmpegBuild's `videotoolbox-pixel-buffer-attributes.patch` is
no longer used by the engine (dropping it from FFmpegBuild is a separate decision); the CoreVideo-pool patch written
during the diagnosis was not committed.

**Device test** (`SEQ=deint`, LG G5, 2026-10-25): the progressive control, field rate with a seek, frame rate and the
wrong-field-order control all play as the legend says; 50 / 25 pictures a second shown, none dropped. **Open:** timings
per frame on the M4 and the A15.

## Part 5. AV1 film grain on the GPU (built)

The last CPU pass over a software-decoded picture: dav1d applies grain by default, writing a second, grained copy
of every picture. The target is the specification's Option 1, bit for bit.

### 5.1 What the specification requires

- **Normative status** (AV1 7.2): with `film_grain_params_present`, "a decoder shall implement a film grain synthesis
  process"; a conformant decoder either produces output "identical in all respects ... including applying the exact
  film grain synthesis process as specified in section 7.18.3" (Option 1), or keeps the pre-grain picture identical
  and adds grain with no "perceptually significant differences" (Option 2, defined by whoever accredits). Skipping it
  is not conformant. We take Option 1.
- **Output only** (7.18, 7.20): references store the pre-grain picture; grain is applied to `OutY/U/V` alone.
- **Parameters per shown frame** (5.9.30, 6.8.20): `update_grain = 0` loads a reference's set except `grain_seed`;
  `show_existing_frame` loads the shown frame's set with its seed (the same pattern repeats). dav1d resolves all of it;
  FFmpeg's `AV_FRAME_DATA_FILM_GRAIN_PARAMS` (`AVFilmGrainAOMParams`) carries the final set with the offsets already
  removed (`ar_coeffs`, `uv_mult`, `uv_mult_luma` less 128, `uv_offset` less 256, `scaling_shift` and
  `ar_coeff_shift` with their 8 and 6 added), `limit_output_range` = `clip_to_restricted_range`. `MC_IDENTITY` has no
  field: it is the frame's own matrix (`AVCOL_SPC_RGB`).
- **The process** (7.18.3, unchanged since 2018; no normative errata):
  1. A 16-bit LFSR (`get_random_number`) seeded with `grain_seed` draws from `Gaussian_Sequence` (2048 entries) into
     an 82 x 73 luma template, shifted by `12 - BitDepth + grain_scale_shift` with `Round2`; Cb and Cr from seeds
     `grain_seed ^ 0xb524` / `^ 0x49d8`, 44 x 38 (4:2:0), 44 x 73 (4:2:2) or 82 x 73. A plane with no points draws
     nothing.
  2. A causal auto-regressive filter of lag 0..3 (24 luma, 25 chroma coefficients, the last the luma correlation),
     in place, raster order, from (3, 3) to (w - 3, h), `Round2(sum, ar_coeff_shift)`, clipped to
     `GrainMin..GrainMax` (`-128..127` scaled by `BitDepth - 8`). Chroma reads the filtered luma template, averaged over
     its subsampling with `Round2`.
  3. Scaling: a 256-entry piecewise-linear LUT per plane (`delta = deltaY * ((65536 + (deltaX >> 1)) / deltaX)`,
     divide first), read at higher depths by `scale_lut`, which interpolates between entries with `Round2`.
  4. Per 32 x 32 luma block, one 8-bit draw from a stripe LFSR re-seeded every 32 rows from `grain_seed` and the
     stripe number gives `offsetX = rand >> 4`, `offsetY = rand & 15`, shared by all planes (template origin
     `9 + 2 * offset`, or `6 + offset` on a subsampled axis). With `overlap_flag`, two columns (one subsampled) blend
     with the left block at 27 / 17 and 17 / 27 (23 / 22 subsampled), `Round2(, 5)` and clip; then two rows with the
     block above, the same way. Horizontal first, then vertical, each rounded and clipped.
  5. Chroma before luma, from the un-noised luma: `averageLuma` is the top luma row of the pair, averaged
     horizontally (`lumaNextX = Min(lumaX + 1, w - 1)` at an odd right edge); with `chroma_scaling_from_luma` it indexes
     the LUT directly, otherwise `Clip1(((averageLuma * cb_luma_mult + orig * cb_mult) >> 6) + (cb_offset << (BitDepth - 8)))`.
     `noise = Round2(scale_lut(v) * grain, ScalingShift)`, the sample clipped to `0..2^BitDepth - 1`, or with
     `clip_to_restricted_range` to `16..235` (`240` chroma, `235` under `MC_IDENTITY`) scaled to the depth.
  6. Edge cases the spec defines: partial blocks at the right and bottom, odd sizes, monochrome (luma only),
     `num_y_points = 0` (luma untouched, not even clipped), chroma clipped whenever `chroma_scaling_from_luma` is set,
     even with zero noise.

### 5.2 Sources and licences

- **The specification is the normative reference** (7.18.3 and its `Gaussian_Sequence` table); **dav1d's C
  (`src/filmgrain_tmpl.c`, `src/fg_apply_tmpl.c`, BSD-2-Clause) is the implementation reference**, derived from where it
  is the clearer statement. Its layout is already the GPU's (templates once per frame, the LUTs expanded to every code
  value, application per sample), and its fix history is the list of traps: divide before multiply in the LUT,
  chroma from un-noised luma, the high-depth LUT index, odd edges, the clip-only case. BSD-2 sits inside the engine:
  it permits App Store distribution already, so the exception is not needed for it. The derived files carry dav1d's
  notice (© 2018 Niklas Haas, © 2018 VideoLAN and dav1d authors, © 2018 Two Orioles, LLC; both clauses and the
  disclaimer) beside the engine's header, and the app's acknowledgements carry it too.
- **Not derived from FFmpeg's applier** (`libavcodec/aom_film_grain*.c`, LGPL-2.1+, itself a port of dav1d's C):
  outside what the exception can cover, and dav1d's original says the same under BSD-2. Reading `AVFilmGrainParams`
  through FFmpegBuild's headers is use of its API, as everywhere.
- **dav1d and libaom are also the oracles**: dav1d applies grain itself and is verified bit exact on the Argon
  streams (`md5_ref`).
- **Patents**: the same position as decoding AV1 at all (the engine ships dav1d already). The AOM Patent License 1.0
  covers AOM licensors and asks for its text in source and binary notices, which neither FFmpegBuild (`LICENSES/` has
  dav1d's BSD-2 only) nor the engine ships today: add it. Sisvel's AV1 pool claims essential patents; the one
  film-grain patent found (Dolby, EP 3678097) was revoked by the EPO in 2022. Not legal advice.

### 5.3 Design

- **Decoder**: `AV_CODEC_EXPORT_DATA_FILM_GRAIN` on libdav1d (the wrapper then turns `apply_grain` off,
  `libdav1d.c:280`); each frame's `AV_FRAME_DATA_FILM_GRAIN_PARAMS` travels with it to the finisher.
- **CPU, per frame** (inherently serial, about 20k samples): the three templates (LFSR, AR filter), the LUTs expanded
  to `2^BitDepth` entries, the block offsets (one LFSR per stripe, a few hundred values). Cached on the parameter
  set and seed (a repeated `show_existing_frame` costs nothing).
- **GPU**: the noise at a sample is a pure function of the templates, its block's offsets and its left / upper
  neighbours' in the overlap, so one function in the shader source computes the grained value of any sample. The
  finisher's reader calls it for every tap it reads (chroma taps with the un-noised luma at their own site), so the
  grain is inside the one pass, and stills (Part 7) get it with no work of their own. A second kernel writes grained
  planes with the same function: the conformance path, and what the finisher's grained output is tested against.
- Integer arithmetic in `int32` throughout (AR sums reach about 6.3 million, the 12-bit chroma combination about
  1 million). `Round2` and `>> 6` of a negative value need floor semantics: tested explicitly, not assumed of MSL.

### 5.4 Conformance

1. **Argon streams** (streams.videolan.org/argon): every profile, depth, subsampling, monochrome, odd size and clip
   case, with `md5_ref` (grain applied) per stream. dav1d with grain off, our grained planes, the same md5.
2. **libaom's vectors** `av1-1-b8-23-film_grain-50.ivf` and `av1-1-b10-23-film_grain-50.ivf`.
3. **Targeted streams** from SVT-AV1 4.2.0's `--fgs-table` (every lag, overlap on and off, chroma from luma, the
   restricted range, odd sizes, 8 and 10 bit), against Homebrew dav1d 1.5.4 with `--filmgrain 1` (the version
   FFmpegBuild ships).
4. **The fused path**: the finisher fed an ungrained picture and its parameters equals the finisher fed the oracle's
   grained picture, output code for output code.

### 5.5 Built and measured

- `Video/FilmGrain/`: `FilmGrainParameters` (from `AV_FRAME_DATA_FILM_GRAIN_PARAMS`), `FilmGrainSynthesis` (templates,
  LUTs, offsets, written straight into a shared buffer, about 57 KB at 4K, rewritten only when the set changes) and
  `FilmGrainShaderSource` (`fg_*`). The finisher's `pf_c0..2` read through `pf_grained` under `FC_GRAIN` (function
  constant 31), so every path (pack, resample, grey, RGB, convert, constant luminance) takes grain on the samples it
  reads; `fg_planes` writes the grained planes for conformance. `DisplayBufferWriter.install` turns on
  `AV_CODEC_EXPORT_DATA_FILM_GRAIN` for libdav1d only (H.264 / HEVC grain is H.274's, which libavcodec applies).
- `FilmGrainTests`: the finisher with grain equals libdav1d's grained picture through the finisher, at 4:2:0, 4:2:2 and
  4:4:4 output. Argon (`AETHER_ARGON=1`, opt-in, about two minutes): 1508 of the 1512 grain streams give `md5_ref`.
- The four others are not grain: FFmpeg's `libdav1d_init_params` (upstream master too) updates the colourspace only
  when a sequence header carries a colour description, so a later header without one keeps the earlier matrix
  instead of AV1's `MC_UNSPECIFIED`. Frames after such a switch arrive labelled RGB (and as `gbrp` at 4:4:4), so
  `MC_IDENTITY`'s 235 chroma limit is taken where dav1d takes 240. Decoded with each frame's true matrix, every frame
  of the four matches (the mismatching frames under "identity" and under "not identity" never overlap). The same stale
  label misreads such frames for display. The fix is in FFmpegBuild: assign the sequence's values unconditionally
  (dav1d already writes UNKNOWN when the description is absent), and `DAV1D_CHR_UNKNOWN` to `AVCHROMA_LOC_UNSPECIFIED`.

## Part 6. Film in interlaced carriage: soft telecine, field matching, decimation (built, verified on device)

**Licensing.** bwdif, fieldmatch and decimate are transcriptions of FFmpeg's C (LGPL-2.1-or-later), so they cannot sit
under the engine's App Store exception. They live in their own dynamic library,
[LibDeinterlace](https://github.com/TheFireKahuna/LibDeinterlace) (LGPL-2.1-or-later, replaceable like FFmpegBuild's
frameworks), with the bit-exact reference suites; the engine keeps the finisher, the decoder, `FilmCadence` (written
from the codec standards) and the engagement policy.

Film (24 or 23.976 frames a second) reaches the software route inside 29.97i / 25i carriage three ways. Each has
one correct presentation: the film frames, each shown once, at the film rate, with the panel at that rate.

### 6.1 Soft telecine: the codec standards' own signalling

The pictures are coded progressive at the film rate; flags tell a field-based display which fields to repeat.
FFmpeg's decoders map them onto `AVFrame.repeat_pict`, extra half-frame durations, so a picture is displayed for
(2 + `repeat_pict`) fields:

| Standard | Signalling | `repeat_pict` |
|---|---|---|
| H.262 / MPEG-2 (6.3.10), `progressive_sequence = 0` | `progressive_frame = 1`, `repeat_first_field = 1`: three fields | 1 |
| H.262 / MPEG-2, `progressive_sequence = 1` (ATSC 720p film) | `repeat_first_field` with `top_field_first` 0 / 1: two / three frames | 2 / 4 |
| H.264 Annex D, picture timing SEI `pic_struct` (Table D-1) | 5 / 6: top-bottom-top / bottom-top-bottom | 1 |
| | 7 / 8: frame doubling / tripling | 2 / 4 |
| SMPTE 421M / VC-1 (advanced profile, PULLDOWN) | `RFF` / `RPTFRM` | 1 / 2 x RPTFRM |

The pictures are progressive and pass the deinterlacer untouched (yadif_common.c's `deint=interlaced`). What is
missing is the timing:

- **Cadence.** A run of progressive pictures whose durations alternate 2, 3 fields (or 2, 3 frames in a progressive
  sequence) is film at 4/5 of the carriage rate. `FilmCadence` (`Decoder/FilmCadence.swift`) recognises it from four
  pictures' flags.
- **Timestamps.** Shown on their field timeline (33.4 ms, 50.0 ms, ...) on a 23.976 Hz panel, two pictures can land on
  one refresh, depending on the refresh phase, and one is lost. A run is therefore re-timed onto a uniform grid of one
  film period (5x/8 carriage frames for durations x, 3x/2), anchored at the run's first picture and computed per index.
  The grid and the field timeline agree at every cycle (4 pictures = 10 fields) and lie at most half a field apart inside
  it. Container timestamps are less exact than the flags: x264's `--pulldown 32` places a cycle's pictures at 0, 4, 6
  and 8 fields. So a run ends on an interlaced picture, a duration that breaks the alternation, or a timestamp more
  than one carriage frame from its slot (an edit, a splice), and detection starts over. Applied to every decoded
  picture in `SoftwareVideoDecoder`, reset on seek and at end of stream.
- **Panel rate.** For MPEG-2 and VC-1 at a 29.97 / 30 / 59.94 / 60 carriage (VOD, seekable), the load decodes a sample
  (`InterlaceProbe.filmRate`, the #232 sampler) and, when it is a film run, asks for 4/5 of the carriage rate
  (24000/1001 from 30000/1001) instead of the container's rate.
- **H.264** soft telecine is progressive-flagged, so #232 routes it to AVPlayer; its timing on the native route
  (AVPlayer presents the container's timestamps) is not covered here.

Test streams: `Probes/DolbyVisionPulse/Scripts/mpeg2_pulldown.py` applies 3:2 soft telecine to an MPEG-2 elementary
stream in place (frame_rate_code, progressive_sequence, top_field_first, repeat_first_field), as DVD pulldown tools
do; x264's own `--pulldown 32 --fake-interlaced` makes the H.264 equivalent (FFmpeg's libx264 wrapper does not pass
pulldown through).

### 6.2 Hard telecine and progressive-segmented film: field matching

The pulldown is in the pixels. Five interlaced frames carry four film frames (AA BB BC CD DD); progressive-segmented
film (PsF, 2:2, European 25p in 1080i50) carries each film frame as its two fields. No standard defines recovery; the
reference is FFmpeg's `fieldmatch` (VapourSynth VFM) at its defaults: `order=auto`, `mode=pc_n`, `field=auto`,
`mchroma=1`, no exclusion band, `scthresh=12`, `combmatch=sc`, `cthresh=9`, `chroma=0`, `blockx=blocky=16`,
`combpel=80`. Its scope is FFmpeg's: 8-bit planar 4:4:4, 4:2:2, 4:2:0, 4:1:1, 4:1:0. A picture it cannot match
(still combed) is deinterlaced by bwdif at frame rate (`deint=interlaced`, FFmpeg's documented recipe with bwdif in
yadif's place).

- **GPU:** the per-pixel stages are integer: the field difference map (`build_diff_map`), the match accumulations
  (`compare_fields`), the comb mask and its block counts (`calc_combed_score`), the luma differences of the scene
  check. They run as kernels that write exact integer partial sums.
- **CPU:** the decisions: `compare_fields`'s single-precision ratios, `checkmm`, the scene check, the match. The
  same float operations in the same order give the same results.
- **Output:** a weave of two fields: a copy, written into the scratch picture by the same first dispatch that runs
  bwdif, then finished as any picture.

### 6.3 Decimation

The reference is FFmpeg's `decimate` (VapourSynth VDecimate) at its defaults: `cycle=5`, `dupthresh=1.1`,
`scthresh=15`, `blockx=blocky=32`, `chroma=1`, `mixed=0`. Per cycle of five matched pictures it drops the one most
like its predecessor (block sums of absolute differences: GPU partial sums, CPU decision) and stamps the four kept
on the decimated time base (`dec_tb = 1001/24000` from 29.97). Panel rate 24000/1001.

### 6.4 Engagement

Which stage a stream gets is engine policy (FFmpeg leaves it to whoever builds the graph). The load probe already
decodes a sample of a declared-interlaced stream (`InterlaceProbe`, #232); it also runs the field matcher and the
decimator over it:

| Sample | Stage | Panel |
|---|---|---|
| progressive pictures in a 2-3 repeat cadence | 6.1 | 4/5 of the carriage rate |
| interlaced pictures that match into progressive frames, with one duplicate per cycle of five | 6.2 + 6.3 | 4/5 |
| interlaced pictures that match their own fields (PsF) | 6.2, no decimation | the frame rate |
| anything else | bwdif (Part 4), field rate | the field rate |

A change of content during playback keeps the panel and the stage chosen at load, as a broadcast receiver's film
mode does; the stages themselves cope with breaks (re-anchoring, combed pictures to bwdif).

### 6.5 Conformance

- 6.1 against the standards' arithmetic: field durations from each codec's flags on encoded test streams (MPEG-2
  with RFF in both sequence types, H.264 with `pic_struct`), the uniform grid and its half-field invariant.
- 6.2 and 6.3 against FFmpeg on the same frames (LibDeinterlace's `InverseTelecineReferenceTests`, the `ffmpeg`
  command-line tool, whose sources of all five filters are byte for byte n8.1.3's): the chain
  `fieldmatch,bwdif=mode=send_frame:deint=interlaced,decimate`, every output picture and timestamp equal, on 3:2 in
  both field orders, 4:2:2, a scene cut, an edit, a mid-cycle end, and 2:2. All equal.
- The engagement table on the probe, and a `SEQ` arm on the TV for each row.
- On the TV (`SEQ=film`, 2026-10-25), each clip with film handling on and off (`film=off`), read from the counters:
  soft telecine 23.976 on a 23.98 Hz panel, one picture per 41.7 ms (off: 59.94 Hz, 33.4 / 50.1 ms, the 3:2 judder);
  hard telecine 24 pictures a second on 23.98 Hz (off: 60 deinterlaced a second on 59.94 Hz); 2:2 25 a second on
  50 Hz (off: 50 deinterlaced). The only drops fell in the first second, across the panel's mode switch. By eye the
  difference did not show on the G5, which likely smooths 3:2 at 59.94 Hz itself.

## Part 7. Stills on the playback path (open)

Every still (the SDR I-frame tier AVKit's scrub thumbnails play, `FrameExtractor`'s thumbnails and snapshots, the
software host's packet-run stills) is a picture the player would show, so it is made the way playback makes it,
plus one scale and colour step.

What there was: a VideoToolbox decode went to memory (`av_hwframe_transfer_data`), a software decode stayed in
libavcodec's buffers, and both then went through swscale into RGBA on the CPU (`convertToCGImage`, with its own
matrix choice re-derived from `ColorAttachments`), or for HDR through a zscale + tonemap graph (`HDRToneMapper`,
FFmpeg's curve, not Apple's), and the I-frame tier then drew that image into a buffer with Core Graphics. Only a
VideoToolbox keyframe in the I-frame tier stayed on the GPU (`decodeScaledStill`).

The path:

1. **Decode as playback decodes.** VideoToolbox where the still decoder already takes it (its frames are display
   buffers); otherwise libavcodec into the slabs (`DecodeFrameAllocator`), and the finisher writes the display
   buffer. The picture-to-display-buffer step is one type, `DisplayBufferWriter`, taken out of
   `SoftwareVideoDecoder`: the slabs, the finisher, the plan cache, the buffer pool, colour / chroma siting / HDR
   static attachments. The decoder and the still decoder both use it; nothing else makes a display buffer.
2. **One GPU step to the still.** `StillRenderer`: `VTPixelTransferSession` scales the display buffer to the still's
   size and maps it to the destination in the same pass. An HDR picture (PQ, HLG) maps to BT.709 SDR, Apple's own
   curve, the one `AVAssetImageGenerator`'s force-SDR policy gives; an SDR picture keeps its primaries and transfer.
   The I-frame tier takes 10-bit 4:2:0 for the encoder; a `CGImage` is a BGRA buffer of its own, wrapped without a
   copy (a pooled buffer would be repainted under an image the host still shows).
3. **Removed:** swscale (the engine's last use), `HDRToneMapper` and its filter graph, the hardware-frame transfer and
   the software re-open it fell back to, the RGBA copies, the Core Graphics redraws.

Dolby Vision profile 5 / AV1 10.0 is not on this path. Playback leaves its reconstruction to the system (the native
route serves it as `dvh1.05`; the software route refuses it, AE#461), and the default build's scrub preview does the
same (`AetherScrubPreviewView`, the system compositor). The `DolbyVisionStillReshaping` trait's CPU converter keeps
reading the decoded frame as before; whether it stays is open.

Part 5's grain then reaches stills with no work of their own: they go through the finisher.

Conformance: a still of a known picture through the software and the VideoToolbox decode, against the display
buffer playback shows (BT.709 bars at the code values, an untagged SD picture with playback's BT.601 guess, full
range, an anamorphic picture at its display aspect); HDR10 and HLG sources give BT.709 SDR stills.

## Banked

- **Zero-copy rawvideo** by allocating its packets in slabs. Worth it only if a local or loopback producer ever feeds
  raw frames (then the copy is 300 to 750 MB/s, not bounded by the network).
- **XYZ (ST 428 primaries) and MatrixCoefficients 11 / 15**: showing them is a gamut or model conversion, not a representation change; refused today.

## Open questions

- **The FEL overlay's 12-bit result.** The `cardov` arms OR / OS put the amplifier RPU override
  (`DoviComposedRpuOverride`) on the overlay layer's frames only. By the placeholder findings that attachment never
  reaches the panel, so "the overlay kept the sub-10-bit steps" (`61c7412f`) is unproven on the native route until the
  override is written into the segment producer's packets and the card test is repeated.
- **dav1d throughput on the A15** at 4K 10-bit (with and without film grain) is unmeasured; it sets the decode-ahead
  the segment gating needs.
- **The finisher's speed on the Apple TV** is unmeasured (all figures are M4 Pro).
- **ICtCp tagging** relies on CoreVideo's own `ITU_R_2100_ICtCp` tag (code point 14, absent from the public headers);
  whether tvOS's display layer decodes it correctly is untested.
