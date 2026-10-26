# The software route: one GPU pass, inside the native player

Status: written 2026-10-24 on `research/12bit-fel`, updated 2026-10-26. The GPU cutover is done: a software-decoded
picture reaches the display, and every still, in one GPU pass with no CPU pass over its pixels. Parts 2 (the GPU
finisher and H.273 colour) and 3 (AV1 into the slabs) are built; parts 4 (bwdif on the GPU) and 6 (film in
interlaced carriage) are built and verified on device; part 5 (AV1 film grain, its synthesis on the GPU since
2026-10-26) is built and bit exact on the Argon streams; part 7 (stills) is built, its device check open. Part 8
records the mid-stream colour fixes part 5's conformance run led to. Part 9 (2026-10-26) is the one GPU submission
layer every GPU user goes through, the software decoder's frame path without CPU waits, the libraries' binary ABI, and
the engine's own shaders precompiled with an A15 pipeline archive; built, not yet run on the TV. Part 1 (one overlay for every picture AVPlayer cannot show) is open. What is left is in
"Order of work" at the end. The colour equations are in [colour-representation.md](colour-representation.md).

What still passes over pixels on the CPU, each on purpose:

- rawvideo and libavcodec's paletted pictures are copied into a slab once (for rawvideo the copy is the decode);
- Dolby Vision profile 5 / AV1 10.0 stills, behind the `DolbyVisionStillReshaping` trait (off by default; playback
  and the default scrub preview leave the reconstruction to the system compositor);
- H.274 film grain (H.264 / HEVC SEI), which libavcodec applies; rare in practice, and not AV1's process.

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

## Part 1. One overlay for every picture AVPlayer cannot show (open)

### The idea

AVPlayer plays a **placeholder** video track carrying the source's real format: size, colour, HDR metadata and the
Dolby Vision RPU. Its rendering is suppressed (`AVPlayerItemVideoOutput.suppressesPlayerRendering`), and it plays the
source's real audio. Our own pictures are drawn on a sample-buffer layer inside AVKit's player layer, under the
subtitles, and timed by the item's clock. AVPlayer owns the clock, audio, transport, subtitles, seeking and the display
mode. We own the picture.

The FEL overlay already works this way, with the base layer standing in for the placeholder. It becomes the general
**software overlay**: one presenter with two frame sources.

This is a hard cutover. Every source the software host played moves to the overlay, with no second path and no
fallback. `SoftwarePlaybackHost` and its files go back to upstream's version.

### What the device probes established (LG G5, Apple TV 4K 3rd gen, tvOS 27.2)

Probe: `Probes/DolbyVisionPulse`, `SEQ=placeholder` (`Scripts/build_placeholder.sh`, `Device/Host/PulsePlaceholder.swift`,
`2edac71f`).

- The display mode follows the placeholder: a `dvh1` placeholder puts the TV in Dolby Vision, `hvc1` HDR10 in HDR10.
- **The Dolby Vision metadata that reaches the panel is always the RPU in the stream AVPlayer plays, never the overlay
  layer's `DolbyVisionRPUData` attachment.**
  - Arm GD (placeholder RPU constant, overlay RPU pulsing) stayed steady.
  - Arm GV (HDR10 placeholder, DV criteria set by the host) stayed steady.
  - Arm GX (placeholder RPU pulsing, overlay RPU constant) pulsed.

  The FEL overlay therefore puts its composed-form RPU, and the amplifier override, into AVPlayer's packets and
  attaches none (`ff0cbd3d`).
- **Arm GE, the intended design, worked.** A `dvh1` placeholder carried the source's per-frame RPU (`ph_dv_l2`), and
  the overlay showed the source's frames (`pulse_l2`). The TV was in Dolby Vision with the pulse in step.

### Why AVPlayer needs no help with buffering

The source, container and HLS are the same as on the hardware route. Only the picture's decoder changes. AVPlayer
buffers placeholder segments as freely as real ones. The tap holds the real packets compressed, and the decoder runs
just ahead of the clock, as AVPlayer's own decoder does.

The one thing AVPlayer cannot do is wait for a decoder it does not own. It prerolls the placeholder, which is
instant, and starts the clock. So after a start or a seek, the first fragment is held until our decoder has the
target picture. After that the decoder only has to keep pace. A picture that misses its refresh is counted, as the
FEL overlay counts late frames today.

### Design

1. **`SoftwareOverlayRenderer`** (`Native/`) is today's `FelOverlayRenderer` with the picture step behind a frame
   source. It is built outside the `DualLayerDolbyVision` trait; the FEL source stays inside it.
   - **FEL source:** pairs AVPlayer's base-layer frame with the enhancement layer, as today.
   - **Decode source:** the latest decoded picture at or before the item time of the target refresh. The output
     timeline is not the packet timeline: field-rate bwdif doubles it, decimation drops one picture in five, and
     soft telecine retimes it. So the clock chooses the picture, and the placeholder's frames only signal that
     frames are coming.
   - **At scan rates** (rate other than 0 or 1), AVPlayer plays the I-frame tier and the renderer shows the frames
     its video output decodes.
   - **PiP** takes the overlay layer itself, with lossless pixels
     (`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`).
2. **`OverlayPacketTap`** (`Video/`) is `FelEnhancementTap`'s store, runs, keyframe restarts and decode loop, shared
   by both sources.
   - **FEL tap:** keeps the enhancement-layer packets and the composer parameters.
   - **Decode tap:** keeps whole source packets, about a minute behind the clock, and decodes them with
     `SoftwareVideoDecoder`, configured as the software host configures it (`DeinterlaceConfig`, the film carriage
     from the load probe).
   - **One decoder per session.** A seek flushes it and never reopens it, so the slab allocator, the finisher's
     pipelines and plan cache, the buffer pool and the grain tables all stay warm. Pictures before the target are
     decoded as references only (`skipUntilPTS`).
   - A seek back into resident segments restarts from a keyframe the tap already holds. A short forward seek inside
     the decoded window restarts nothing.
   - The decoder is reopened only when the stream changes.
   - **The decode lead** is a few pictures, not the FEL tap's 0.75 s, which is about 450 MB at 4K24.
   - **Captions** come from the decoder's `onA53Captions`, because the producer's A53 scan sees only placeholder
     bytes.
3. **The placeholder.** One flat picture is encoded at load as an HEVC Main10 IDR by `VTCompressionSession`, at the
   source's coded size with the source's colour in the VUI.
   - Every video packet's payload becomes that IDR plus the source's metadata for that picture. The packet keeps its
     pts, dts, duration and key flag.
   - Every sample is an independent IDR, so any order the source decodes and presents in is valid.
   - **Metadata per packet:**
     - the Dolby Vision RPU as an unspec62 NAL (AV1 profile 10 moves it from its T.35 metadata OBU);
     - HDR10+ as a T.35 SEI (the same payload as AV1's metadata OBU).
   - **The init** has the placeholder's own `hvcC`. Its `colr`, `mdcv` / `clli` and `dvcC` come from the source,
     derived as the native route derives them. CODECS come from the placeholder's record.
   - **Where:** `prepare()` accepts every codec the decoder takes. The substitution happens where the FEL tap's
     rewrite runs, before `finalizeAndWriteVideo`'s HDR10+ and A53 scans.
4. **The I-frame tiers.**
   - **Scan tier:** the source's keyframes encoded by the hardware encoder in their own range, HDR10 or Dolby Vision
     8.1 with the keyframe's RPU, at up to 1080p (`IFrameStillBuilder` without its tone map). The main player of an
     HDR session drops an SDR tier, so the scan tier cannot be SDR.
   - **Thumbnail tier:** the SDR stills tier, unchanged. It already decodes every codec through
     `FrameDecodeContext`.
5. **Readiness and routing.**
   - Overlay sessions serve progressively. After a start or a seek, the first fragment waits for the decode tap's
     target picture.
   - The display criteria take the output rate: the field rate for bwdif, the film rate for film.
   - Everything `VideoRoutingPolicy.requiresSoftwarePath` sent to the software host goes to the overlay, live
     included. That covers:
     - codecs outside AVPlayer;
     - AV1 without hardware;
     - MVC;
     - interlaced H.264;
     - formats VideoToolbox cannot decode;
     - forward-only sources;
     - the `.software` preference.
   - The escalations do the same. The placeholder's init never changes, and the decoder takes in-band
     parameter-set changes.
   - AV1 profile 10.0 (IPT, Profile 5's equivalent) stays refused: its reshaping happens in the system compositor,
     which overlay pixels never pass through. AV1 10.1 and 10.4 play.

### Order of work

1. Rename and split, with no behaviour change: `SoftwareOverlayRenderer` plus the FEL source, and `OverlayPacketTap`
   plus the FEL tap.
2. The placeholder, metadata carriage, `prepare()` for every codec, the scan tier.
3. The decode source, captions, scan rates, PiP.
4. Readiness, then the routing cutover. `SoftwarePlaybackHost` and its files go back to upstream.
5. Device checks per source class: AV1 HDR10 / HDR10+ / Dolby Vision 10.1, MPEG-2 1080i, film, VC-1. Then the
   transport bar, pause, scrub, scan timing, seek, PiP and Atmos. Then a lip-sync check with a flash-and-beep clip
   filmed by phone.

Our fork's edits to the software host total about 2.1k lines (`AudioOutput`, `AudioRendererIO`, `VideoRendererIO`,
`DualLayerVideoDecoder`, `SoftwarePlaybackHost`, `SampleBufferRenderer`, the APAC keep-alive pieces). Files the
native route shares need per-file care: `AtmosOutputActivator` (native route), `AudioOutput` (the audio-only host),
`DoviComposedRpuOverride` (the overlay).

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
- **Synthesis, on the GPU, per parameter set** (2026-10-26; it was CPU work before): the CPU writes a 32-word header
  and passes the set (208 bytes) as a constant argument. The kernels split the work by role: `fg_luma` (one
  threadgroup: the luma template's draws, then its auto-regression), `fg_chroma_draws` (Cb and Cr, a threadgroup
  each), `fg_scaling` (a thread a table entry) and `fg_offsets` (a thread a block row) run at once; after one barrier,
  `fg_chroma_regress` runs both chroma auto-regressions at once, reading the finished luma template. Each thread's run
  of draws starts with one jump of the LFSR by GF(2) jump matrices and then steps it; each auto-regression is a
  wavefront (the anti-diagonal `x + (lag + 1) y` goes once every earlier one has, a thread a row). The synthesis is a
  pass of its own in the frame's batch, beside the deinterlacer's fields, and the finishes wait on its fence; it is
  encoded only when a slot's tables do not already hold the set (a repeated `show_existing_frame` costs nothing), and
  a batch that fails marks its tables as holding nothing. On the M4 Pro a lag-3 10-bit 4:2:0 set takes 0.89 ms of GPU
  time (1.25 ms as one threadgroup), lag-2 8-bit 4:2:2 0.52 ms (0.82); the luma auto-regression is the critical path.
- **Application, on the GPU**: the noise at a sample is a pure function of the templates, its block's offsets and its
  left / upper neighbours' in the overlap, so one function in the shader source computes the grained value of any
  sample. The finisher's reader calls it for every tap it reads (chroma taps with the un-noised luma at their own
  site), so the grain is inside the one pass, and stills (Part 7) get it with no work of their own.
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

- `Video/FilmGrain/`: `FilmGrainParameters` (from `AV_FRAME_DATA_FILM_GRAIN_PARAMS`), `FilmGrainSynthesis` (the
  buffer's layout, its header and the synthesis arguments) and `Shaders/FilmGrain.h` (the synthesis kernels, the LFSR jump
  matrices and the per-sample `fg_*`). The finisher's `pf_c0..2` read through `pf_grained` under `FC_GRAIN`
  (function constant 31), so every path (pack, resample, grey, RGB, convert, constant luminance) takes grain on the
  samples it reads. `DisplayBufferWriter.install` turns on `AV_CODEC_EXPORT_DATA_FILM_GRAIN` for libdav1d only (H.264 /
  HEVC grain is H.274's, which libavcodec applies).
- A15 (offline counts, `research/a15-registers`): the synthesis kernels 8 to 24 registers; the grained finish 16 to 18 at 8, 10
  and 12 bits, 4:2:0 and 4:4:4, no stack or calls (`pf_grained` is forced inline: outlined, it was six calls a pixel).
- `FilmGrainTests`: the display writer's picture with the GPU's grain equals its picture of libdav1d's grained output,
  picture digest for picture digest. Argon (`AETHER_ARGON=1`, opt-in; `AETHER_ARGON_DIRS` / `AETHER_ARGON_STREAMS`
  narrow it): all 13 directories pass. A stream whose colour the writer refuses (ST 428 primaries, reserved matrices)
  is counted as refused, not compared. Run it in batches of a few directories: each decode is wrapped in an
  autorelease pool (one directory peaked at 6.8 GB without, 1.5 GB with), and all 13 at once still take several GB.
  Before the writer path, the grained planes against `md5_ref` gave 1508 of 1512.
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

Everything runs on the GPU, the decisions included, with no read back before the next picture (LibDeinterlace
2.0.0, from 2026-10-26):

- **Statistics**, from the decoded pictures alone, in a pass that may run beside earlier batches' work: the luma
  differences per 8 x 8 cell (`iv_luma`), the field difference map (`fm_diffmap`, `build_diff_map`) and the match
  accumulations (`fm_accumulate`, `compare_fields`), as exact integer partial sums.
- **The scene test** (`iv_scene`): fieldmatch reads comb scores only on a scene change (`combmatch=sc`), so the test
  also writes the comb kernel's indirect dispatch, every cell or none; `iv_comb` counts the three weaves' combed pixels
  only then.
- **The decision** (`iv_match_decide`): `compare_fields`'s single-precision ratios (the same float operations in the
  same order, compiled with IEEE math), `checkmm`, the combed verdict, into the picture's record; and bwdif's window
  decision for the picture before it, which writes bwdif's threadgroups into that picture's record: all of them to
  deinterlace, none to pass the weave through. A passed-through picture is not copied: its readers (decimate's block
  sums, the finisher) bind both pictures and choose by the record.
- **The weave** (`iv_weave`), **bwdif** (`pf_bwdif`, indirect from the record), **decimate** (`iv_blocks`,
  `iv_decimate`): the cycle decision writes each picture's kept word, and the finisher's job for a dropped picture
  dispatches nothing (`pf_gate`).
- **Ordering**: a push's two passes are ordered by fences (statistics, the chain's state, and one per set of working
  buffers against its last reader), not by ordering every batch after all earlier work; a caller's pass reading the
  outputs waits on `InverseTelecine.fence`. The CPU reads the decisions only in the batch's completion (whether a
  picture goes out, its timestamp).

### 6.3 Decimation

The reference is FFmpeg's `decimate` (VapourSynth VDecimate) at its defaults: `cycle=5`, `dupthresh=1.1`,
`scthresh=15`, `blockx=blocky=32`, `chroma=1`, `mixed=0`. Per cycle of five matched pictures it drops the one most
like its predecessor (block sums of absolute differences and the decision, both on the GPU, 6.2) and stamps the four
kept on the decimated time base (`dec_tb = 1001/24000` from 29.97). Panel rate 24000/1001.

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

## Part 7. Stills on the playback path (built; device check open)

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

### 7.1 Built

`282a72e8`. `DisplayBufferWriter` (Decoder/), `StillRenderer` (FrameExtractor/); `FrameDecodeContext`,
`IFrameStillBuilder` and `SoftwareStillExtractor` cut over; `HDRToneMapper` and every swscale call removed. A hardware
context gets the writer too: a codec the hwaccel declines (MPEG-4 Part 2) decodes in software on it.
`StillColorspaceTests` check stills end to end through the writer and the renderer: BT.709 and untagged HD / SD
matrices, full-range JPEG formats, HDR to BT.709 SDR. Changed by design: `FrameExtractor`'s HDR snapshots take Apple's
curve instead of FFmpeg's tonemap. Open: AV1 HDR scrub thumbnails on the Apple TV (grain included).

## Part 8. Colour that changes mid-stream (built)

Four of Argon's 1512 grain streams missed `md5_ref` (5.5): frames after a sequence header without a colour
description kept the previous header's matrix. The same class of fault was in more places, each now fixed.

- **FFmpegBuild 3.10.1 (`6a2d3af`)**, three patches, each with a test in `ColourPerSequenceTests` that unpatched
  FFmpeg 9.0.2 fails:
  - `libdav1d-colour-per-sequence.patch`: each AV1 sequence header's own colour (AV1 6.4.2: unspecified without a
    description), and dav1d's unknown chroma location as unspecified. All 1512 Argon grain streams now pass.
  - `h264-colour-per-sps.patch`: each SPS's own colour and range (H.264 E.2.1). A container's declaration still
    wins where the bitstream says nothing: `avformat_find_stream_info` restores it (`parameters_from_context`).
  - `h2645-alternative-transfer-cvs.patch`: the alternative transfer characteristics SEI (HLG over a BT.2020
    transfer, 3GPP TS 26.118) lasts one coded video sequence (H.265 D.3), and crosses H.264's frame threads.
  - HEVC's own colour export was already per SPS.
- **Fill from the container** (`ColourBackfill`, `09e23158`): a field is filled only until the bitstream states it.
  A remux with an empty VUI (AE#499) is filled throughout; a stream that stated its colour and falls silent is
  unspecified. For MPEG-TS the "container" value is the first SPS's, so filling from it brought the old colour back.
- **`HardwareVideoDecoder`** (the software route's HEVC, the FEL base layer): each picture's tags travel with it as
  VideoToolbox's frame refCon, from `HEVCInBandColour` (an SPS read through CoreMedia; the alternative transfer per
  coded video sequence). Base layer only (`dba6f3aa`).
- **Native route, live** (`09e23158`, `11a4140d`): an init built from in-band parameter sets (a join, an SSAI
  creative, a same-PID change) carries the new SPS's colour in `colr` (`InBandVideoConfig`), for HEVC as for H.264.
  Live HEVC keeps its in-band parameter sets (the #365 sample conversion, as VOD), and an HEVC VPS / SPS / PPS change
  gets a versioned init, as H.264's.
- **Native route, VOD HEVC** (`11a4140d`): `HEVCConfigurationTracker`, the H.264 tracker's counterpart, rebuilds the
  session on the software path when an IRAP's SPS has a decoder signature the `hvcC` lacks. A `hev1` file (no sets in
  its `hvcC`) has no baseline and is not tracked. Checked on a 4K HDR10 MKV and two Profile 7 FEL clips: no mismatch,
  one colour throughout.
- **Display mode, live** (`52b9b1d6`, `LiveDisplayRangeLatch`): the first HDR programme moves the panel into its mode
  when playback reaches it, once; the panel never comes back down in that session (each switch is an HDMI
  renegotiation, and SDR plays correctly inside an HDR mode).

Not done, by decision: a VOD colour-only change (same decoder signature, other colour). A VOD playlist is written once
with one init, so following it needs the change points before the playlist is served. The files it would serve are
joins whose container already carries the first part's colour for every player, and the case is rare. VIDEO-RANGE and
CODECS stay as the master declared them at load.

## Part 9. One GPU submission layer; the frame path without waits; the libraries' ABI (built, 2026-10-26)

### 9.1 The layer

`GPUSubmitter` (`Video/Metal/GPUSubmission.swift`) is the only way GPU work is submitted, by the engine and by the
libraries it encodes for. Metal 4 where the device has it (`MTL4CommandQueue`, command allocators, argument tables and
residency sets reused from batch to batch, explicit barriers), Metal 3 otherwise (unretained command buffers, a
concurrent encoder, memory barriers); the Apple TV 4K 2nd generation (A12) has no Metal 4 and takes the Metal 3 path.

- One queue per client, so no client holds up another: the FEL composer, each finisher, the subtitle upscaler (whose
  per-window event waits would otherwise stall video).
- A `GPUBatch` is one commit: passes, events waited on before it and signalled after it, one completion that only
  hands off. A `ComputePass` has bindings by index, small constant arguments (`setBytes`, a per-batch upload area,
  which Metal 4 needs), direct and indirect dispatches, `fill` (the encoder's own on Metal 4; a fill kernel in the same
  encoder on Metal 3, so neither splits a pass), barriers, and fences (`waitForFence`, `updateFence`) for passes that
  depend on one another without ordering the whole queue. Barriers and fences name the dispatch and blit stages.
- Pipelines: `makeComputePipeline(library:function:constants:archive:)`. On Metal 4 one `MTL4Compiler` per submitter
  makes them, looking in the request's Metal 4 binary archive first (each archive loaded once; one Metal refuses is
  logged and not used); a function with no constants is a plain descriptor, with constants a specialisation, as the
  archives were recorded. On Metal 3 the device compiles.

### 9.2 The software decoder's frame path

Per frame the decode thread decodes into a slab, looks up the cached plan, takes a pool buffer, takes a ticket and
encodes one batch (grain synthesis, inverse telecine or bwdif, the finish), commits, and moves on. Nothing on that path
waits for the GPU or reads its results back. The GPU's completion returns the finisher slot (three in flight before
back-pressure, which is waited for outside any lock) and hands the frame to `OrderedDelivery`, which delivers by ticket
in decode order, drops old epochs, and skips a failed frame's ticket. `flush()` bumps an atomic epoch and the decode
thread applies the reset itself; `close()` is one handshake. End of stream waits for the finisher to go idle (the
in-flight group is left only after the completion has handed its frame on) and then for delivery. Offline callers
(the probe, stills) wait on the same path. The overlay's decode thread drains an autorelease pool per access unit.

### 9.3 The libraries' ABI

LibDeinterlace 2.0.1 and LibMLSubUpscaler 2.0.0 ship as committed XCFrameworks (tvOS, iOS, macOS, visionOS, devices
and simulators, dSYMs), FFmpegBuild-style: the root package is a `binaryTarget`, the source package with its tests
and build in `Development/`. Built with library evolution, so the `.swiftinterface` is a stable ABI (a rebuilt
LibDeinterlace drops into an app, as LGPL-2.1 asks); public enums are `@frozen` only where no further case can exist.
Each library owns no queue and makes no pipeline: its submission protocol has the caller's batches, passes and
`makeComputePipeline(_:)`. Shaders are `.metal` resources compiled into each slice's `default.metallib`, with the math
mode in the source (`#pragma METAL fp math_mode(safe)` in LibDeinterlace, whose float ratios must equal the C's);
nothing compiles Metal source at run time.

The tvOS device slice of each carries a Metal 4 binary archive for the A15 (`applegpu_g14p`): the build records every
pipeline the library prewarms with a Metal 4 compiler and pipeline-data-set serializer, from that slice's own
`default.metallib`, and `metal-tt` translates the script (`.mtl4-json`). On the Mac's GPU the same chain serves all
68 of LibDeinterlace's pipelines from the archive. Limits, measured: Metal takes an archive only on the OS release it
targets (built for 27.0 it loads on 27.0.1; 26.0 and 27.2 are refused), so tvOS 28 compiles until the frameworks are
rebuilt; Metal 4 scripts do not target the A12, and classic archives cannot be specialised offline, so the A12 compiles
its pipelines at prewarm. `DeinterlaceKernels.prewarm(_:)` and `SubtitleUpscaler.prewarm(_:submission:)` make them
early.

### 9.4 Kernels and registers

Every kernel is checked offline for its A15 register allocation, spills, calls and outlined code
(`research/a15-registers/regs.py`, with `dump-finisher.py` for the engine's interpolated source): none spills. Per-frame
choices are function constants or indirect dispatches written on the GPU; a choice uniform over a dispatch (the
passthrough source) compiles into the per-dispatch preamble, not the per-pixel body.

### 9.5 The engine's shaders precompiled

The finisher (`Shaders/Finisher.metal`, with `FilmGrain.h`), the Metal 3 fill and the FEL composer
(`Sources/AetherFELShaders/Shaders/DolbyVisionFEL.metal`, a target of its own that only the `DualLayerDolbyVision`
trait links) are `.metal` resources the package compiles into its bundles' `default.metallib`; nothing compiles Metal
source at run time (the FEL benchmark's bisection variants aside, which edit the source a test hands it). The math mode
is in each file (`safe` for the finisher). Constants the Swift side shares (film grain's header words and buffer layout)
and the tables derived on the host (the double-float constants, the exp2 / log2 tables, the LFSR jumps) are numbers in
the source, held to their derivation by `ShaderTablesTests`.

Every pipeline is made by `GPUPipelines`, one per device for the process: on Metal 4 one compiler, the request's archive
first (`MTL4Archive` itself, so a miss is known: it is compiled and logged as `[GPUPipelines] <function> not in
<archive>`), on Metal 3 the device. Functions that read no function constant (the grain synthesis kernels, `pf_cl_prepare`,
`pf_gate`) are one pipeline each, not one per plan.

The planned set (`PlanarFrameFinisher.plannedSet`) is 74 finisher plans: the 62 of Order of work 3 and inverse
telecine's variants of the 8-bit planar ones; with grain's synthesis and decimate's gate, 80 pipelines, and the FEL
composer's 12 (every variant it tells apart). `Scripts/build-shader-archive.sh` builds the package for tvOS devices in
Release, records those 92 with a Metal 4 compiler (`ShaderHarvest`) and translates them for the A15 on tvOS 27.0 into
`Resources/AetherEngine-pipelines.metallib` (6.3 MB, 3.4 MB compressed; `metal-tt`'s compression options change
nothing). The archive is bound to the exact libraries: Xcode's Release build of the package and `swift build`'s compile
the kernels to the same bytes (measured), a Debug build does not. Rerun the script after any shader change and for a
new tvOS release. On the Mac, the same chain translated for its own GPU served every pipeline of the set (88 then) from the archive.

At launch the app calls `AetherEngine.prewarmSoftwareDecode()` (the planned set and LibDeinterlace's common formats,
about 150 pipelines) and `prewarmDualLayerDolbyVision()`, at utility priority.

## Banked

- **Zero-copy rawvideo** by allocating its packets in slabs. Worth it only if a local or loopback producer ever feeds
  raw frames (then the copy is 300 to 750 MB/s, not bounded by the network).
- **XYZ (ST 428 primaries) and MatrixCoefficients 11 / 15**: showing them is a gamut or model conversion, not a representation change; refused today.

## Open questions

- **The FEL overlay's 12-bit result.** The amplifier override now rides in AVPlayer's packets (`ff0cbd3d`); the
  `cardov` card test has to be repeated to show the sub-10-bit steps reach the panel on the native route.
- **dav1d throughput on the A15** at 4K 10-bit (with and without film grain) is unmeasured; it sets the decode-ahead
  the segment gating needs.
- **The finisher's speed on the Apple TV** is unmeasured (all figures are M4 Pro), and so are the grain's cost
  (the synthesis kernel's span, the per-sample application inside the finisher) and the software route's frame timing
  since 9.2 (to be read from the overlay's counters against the build before it).
- **GPU-wide timeouts in several-suite test runs: fixed (fa911014, LibDeinterlace 2.0.1).** Every command buffer in
  flight failing at once with Metal's timeout was a freed pipeline running on the GPU: two threads made the same
  pipeline at once and the cache stored the second over the first, which an already-encoded batch held without
  retaining. Caches now keep the first one made, and each batch holds the pipelines it sets until it completes.
- **The archives on the device**: whether the A15 takes the engine's and the libraries' pipelines from them (the
  engine's misses are logged by `GPUPipelines`; a refused archive is logged once), and the launch prewarm's time.
- **Device checks still owed**: part 7's AV1 HDR scrub thumbnails; live HEVC through the #365 sample conversion and a
  mid-stream parameter-set change; a live SDR to HDR programme switch (the panel switching once, AVPlayer playing on
  across it). The live ones need a probe sequence that serves a growing MPEG-TS.
- **The `DolbyVisionStillReshaping` trait**: whether its CPU converter stays (7).
- **ICtCp tagging** relies on CoreVideo's own `ITU_R_2100_ICtCp` tag (code point 14, absent from the public headers);
  whether tvOS's display layer decodes it correctly is untested.

## Order of work

1. Done (fa911014): the wrong output under load, a freed pipeline (open questions).
2. One TV run for the device checks: the software route's frame timing against the overlay's counters, the archives'
   hits, the subtitle upscaler's first run on the device.
3. Done (47bb4f89): the finisher's variants reduced, not moved. Constants a plan never reads take one value (the
   chroma siting only on resampled axes, as its class; big-endian only past a byte), so over a realistic stream set
   434 distinct pipelines became 62, the kernel and its per-pixel cost unchanged. Moving data-only constants into the
   frame's arguments was rejected: it adds registers and work to every pixel for a first-launch saving.
4. Done (9.5): the engine's own shaders precompiled, the A15 archive of the planned set, a prewarm at app launch.
5. Done (5.3): grain synthesis split by role, in a pass of its own beside the field bwdif; 29% less GPU time for a
   lag-3 4:2:0 set on the M4 Pro.
6. Deferred: a queue-level residency set for the long-lived allocations (slabs, pool buffers, tables). Measured on
   the M4 Pro, a batch's own set (a rotating 3 of 12 4K slabs, tables, textures) costs 3.9 us to commit with its
   submission, against 2.7 us with slabs and tables in a set on the queue: about a microsecond a frame, for lifetime
   registration in every owner of a long-lived buffer.
7. The PiP subtitle compositor's `CIContext` replaced by a blend kernel on the layer; Sodalite's log-export QR code
   drawn on the CPU.
8. Two long-running threads still drain no autorelease pool per iteration: the HLS segment producer's pump and the
   loopback audio reader.
