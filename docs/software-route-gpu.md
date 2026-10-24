# The software route: one GPU pass, inside the native player

Status: plan, written 2026-10-24 on `research/12bit-fel`. Parts 2 (the GPU finisher and H.273 colour) and 3 (AV1 into
the slabs) are built and committed; part 4 (bwdif on the GPU) is built and awaits its device test; parts 1, 5 and 6 are
open. The colour equations are in [colour-representation.md](colour-representation.md).

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

## Part 4. Deinterlacing: FFmpeg's bwdif on the GPU (built; device test open)

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

1. `pf_bwdif` (`BwdifShaderSource.swift`) reads the previous, current and next decoded pictures in their slabs through
   the finisher's descriptor reader and writes the deinterlaced components at the source's depth into a planar scratch
   picture (the source's planar equivalent: NV12 becomes yuv420p, P010 yuv420p10).
2. `pf_finish` reads the scratch as an ordinary progressive picture: every conversion and rounding guarantee of Part 2
   applies unchanged.

Splitting the stages keeps exactness checkable per stage (the scratch against libavfilter, the finisher against its
own reference) and costs one GPU-internal write and read of the source planes; a single kernel would run bwdif again
for every resampling tap.

**Throughput.** `BwdifWindow` (`Decoder/BwdifWindow.swift`) holds references to the decoded frames, no copies. All the
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

**Open:** the device test (`SEQ=deint`), and timings per frame on the M4 and the A15.

## Part 5. AV1 film grain on the GPU (open)

dav1d applies film grain on the CPU by default, writing a second, grained picture. Set
`AV_CODEC_EXPORT_DATA_FILM_GRAIN` (the wrapper then turns dav1d's `apply_grain` off, `libdav1d.c:231`) and apply the grain in
the finisher. AV1 specifies the synthesis exactly (section 7.18.3, its pseudo-random generator included): the CPU
builds the per-frame grain templates, the kernel applies them per 32x32 block, and the result must match dav1d's
own grain bit for bit on test streams.

## Part 6. Film in interlaced carriage: soft telecine, field matching, decimation (open)

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

- **Cadence.** A run of progressive pictures whose field durations repeat 2, 3, 2, 3 (or frame durations 2, 3 in a
  progressive sequence) is film at 4/5 of the carriage rate. Detected from the flags of the decoded pictures, in the
  load probe's sample (for the panel rate) and continuously at playback (for the timestamps).
- **Timestamps.** The container's timestamps follow the field timeline (33.4 ms, 50.0 ms, ...). On a 23.976 Hz panel
  two of them can land on one refresh, depending on the refresh phase, and a picture is lost. A film run is therefore
  re-timed onto a uniform grid of one film period, anchored at the run's first picture. The grid and the field
  timeline agree at every cycle boundary (4 frames = 10 fields) and differ by at most half a field inside a cycle;
  a picture further than that from its grid slot ends the run and re-anchors (an edit, a cadence break, a seek).
- **Panel rate.** 4/5 of the carriage frame rate (24000/1001 from 30000/1001, 24 from 30) when the probe's sample is
  a film run, instead of the doubled field rate.

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
- 6.2 and 6.3 against libavfilter on the same frames, as `BwdifReferenceTests` does for bwdif: the chain
  `fieldmatch,bwdif=mode=send_frame:deint=interlaced,decimate`, every output picture and timestamp equal, on
  generated 3:2 and 2:2 material with edits, a video-originated segment, scene changes and both field orders.
- The engagement table on the probe, and a `SEQ` arm on the TV for each row.

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
