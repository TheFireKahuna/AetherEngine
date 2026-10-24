# The software route: one GPU pass, inside the native player

Status: plan, written 2026-10-24 on `research/12bit-fel`. Part 2 (the GPU finisher and H.273 colour) is built and
committed; parts 1, 3, 4 and 5 are open. The colour equations are in [colour-representation.md](colour-representation.md).

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

## Part 3. libdav1d into the slabs (open)

FFmpeg's libdav1d wrapper allocates through its own `av_buffer_pool_init(size, NULL)` (`libavcodec/libdav1d.c:77`,
plain `av_malloc`) and never calls `get_buffer2`, so AV1 pictures are still copied into a slab today.

1. FFmpegBuild patch (`patches/`): `libdav1d_picture_allocator` asks `avctx->get_buffer2` for a picture of the
   128-aligned size when the caller supplied one, and uses its `buf[0]` as `allocator_data`. dav1d's contract: planes
   64-byte aligned, dimensions a multiple of 128, 64 bytes of padding, U and V sharing a stride; allocation on the
   thread calling `dav1d_get_picture`, release from any frame thread (`DecodeFrameAllocator`'s free callback is
   thread-safe). Test with `n_threads > 1`.
2. Release FFmpegBuild, bump the engine's pin, and add AV1 to the parity tests (a decode through the slab path equals
   the copied path).

## Part 4. Deinterlacing after the finisher (open)

Today: `format=nv12,hwupload,yadif_videotoolbox` (two CPU passes: swscale in the filter graph and `av_frame_copy` into
an IOSurface), then a VTPixelTransferSession copy into our pool; a CPU `bwdif` fallback when the hardware graph
fails, and `DeinterlaceMode.software`.

1. **Deinterlace after the finisher**, on display-format buffers. Every format the decoder outputs (NV12, P010, NV16,
   P210, P216, NV24, P410, P416) is in `yadif_videotoolbox`'s and VideoToolbox's supported sets, so the hardware
   graph has no format it can fail on.
2. **FFmpegBuild patch (about 25 lines):** `AVVTFramesContext` gains a pixel-buffer-attributes dictionary that
   `vt_pool_alloc` merges into its pool; `vf_yadif_videotoolbox`'s `do_config_output` copies it from the input frame
   context to the output. The engine creates the input frame context with the display pool's attributes (Metal
   compatibility, the renderer's recommendation), so yadif's output buffers are made like the display buffers.
   While there, `vf_yadif_videotoolbox`'s silent pass-through on an unsupported format becomes an error.
3. **Device test:** yadif output displayed directly, without the VTPixelTransfer copy. The comment that the tvOS
   direct video plane wedges on foreign IOSurfaces (commit `687178e1`, ported from a fork) is an unverified field
   note; the attribute difference (`kCVPixelBufferMetalCompatibilityKey`) is the likely cause.
4. Remove the CPU path: `bwdif`, `DeinterlaceMode.software`, the `hwDisabled` fallback latch. A hardware graph that
   cannot be built is a logged error, not a switch to the CPU. A GPU bwdif port stays a later quality option (yadif
   is what runs on the hardware path today); interlaced consumer content is 8-bit 4:2:0.

## Part 5. AV1 film grain on the GPU (open)

dav1d applies film grain on the CPU by default, writing a second, grained picture. Set
`AV_CODEC_EXPORT_DATA_FILM_GRAIN` (the wrapper then sets `apply_grain = 0`, `libdav1d.c:231`) and apply the grain in
the finisher. AV1 specifies the synthesis exactly (section 7.18.3, its pseudo-random generator included): the CPU
builds the per-frame grain templates, the kernel applies them per 32x32 block, and the result must match dav1d's
own grain bit for bit on test streams.

## Banked

- **Zero-copy rawvideo** by allocating its packets in slabs. Worth it only if a local or loopback producer ever feeds
  raw frames (then the copy is 300 to 750 MB/s, not bounded by the network).
- **A GPU bwdif** port, as a quality upgrade over yadif.
- **XYZ (MC 11, ST 428 primaries)**: showing it is a gamut conversion, not a representation change; refused today.

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
