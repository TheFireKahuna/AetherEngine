# Timing model

How the engine times video, sound and the overlay's pictures, what AVPlayer does with those times, and how to tell
on a device that it is all working. Read this before changing muxing, timestamps, segments, the overlay, or anything
that reads AVPlayer's clock. Most of it was established the hard way on 2026-10-27/28 (see "The 2026-10-28
regression" at the end).

Related: [segment-axis.md](segment-axis.md) (segment boundaries, the in-band clock), [seek-cost.md](seek-cost.md)
(seek cost, the overlay's start hold and frame identity), [software-route-gpu.md](software-route-gpu.md) (the
software decode, film cadence).

## The times involved

| Time | What it is | Owner |
|---|---|---|
| Source time | A packet's timestamp in the source container | the demuxer |
| Item axis | Source time less the producer run's shift (`videoShiftPts`): the axis the producer writes | the producer |
| Served time | The presentation time a video sample is written at, in the session's served time base | `HLSSegmentProducer.servedVideoTime` |
| Item time | When AVPlayer presents a sample: its served time plus the run's axis | AVPlayer |
| Axis | Item time less served time for a run; zero on an honest plan, up to EXTINF's rounding | measured by the in-band clock |
| Clock | AVPlayer's item timebase, which the overlay's layer follows one for one | AVPlayer |

## Video carriage

- **Served time base.** A VOD track whose container tick is 0.1 ms or coarser (in practice Matroska's 1 ms) and
  whose rate is exactly a standard one is muxed on its exact frame grid (AE#886, `CFRFrameGrid`): 1/24000 with 1001
  ticks a frame for 23.976. Every timestamp within one source tick of a grid slot is placed on it; anything farther
  (variable rate, an edit, a splice, drift) keeps its own time (`offGrid` on the pump's finish line). Every other
  track is served in its source time base. One served time base per session, the same for every producer.
- **Why the grid.** Matroska's 1 ms ticks reach AVPlayer as 41/42 ms steps at 23.976. At 59.94 Hz every second frame
  sits on a refresh boundary, so the rounding moves frames to the neighbouring refresh and 3:2 cadence breaks. On a
  matched 23.976 Hz TV mode it rarely shows.
- **One source of truth.** `servedVideoTime(_:)` computes a packet's served time once; the write serves the packet
  at it and the overlay's taps name its unit by it.

## Sound placement

Sound is placed independently of the video grid, to the sample:

- **`SourceGrid`** puts decoded and stream-copied audio on its codec's frame lattice (AAC 1024, AC-3 1536, E-AC-3
  256, TrueHD 40, DTS from its header), so a run's audio sits where continuous playback puts it whatever the
  container rounded. A timestamp may be up to three ticks from its frame and still name it; a remux was measured
  drifting 112 samples (2.3 ms) at 48 kHz and snapping back. A long lattice only moves a run on a cut or a sustained
  phase shift.
- **Stream clocks** (`StreamClockPlacement`, `CopiedAudioTiming`): TrueHD and DTS are placed by their own bitstream
  clocks (output timing, frame counts), container timestamps only coarsely (research/dts-timing/README.md).
- **The sanitizer's sound rule** (`OutputTimestampSanitizer`): a sound packet that repeats sound already written is
  dropped rather than shrinking the track's timeline.
- **Routing** (`AudioRunPlan`): a packet belongs to the segment its last sample plays in; a restart reads from before
  its boundary (`producerReadStart`, the bridge's pre-roll) so the restarted segment equals continuous playback's,
  byte for byte (`AudioSegmentRunsTests`).
- **Proof:** `AVSyncTests` place the click on the white frame to the sample, through the native route, the demuxed
  audio rendition and the overlay, with audio delays longer than a fragment.

The video grid does not replace any of this: Matroska's audio timestamps are still rounded.

## Our own decode

`FilmCadence` retimes soft-telecined film onto an exact film grid inside the software decoder, so each picture gets
a refresh of its own. The overlay presents those pictures on its own clock (`.clock` pacing), not AVPlayer's frames.

## The overlay's timing contract

The overlay (`SoftwareOverlayRenderer`) draws over an AVPlayer whose rendering is suppressed: a Profile 7 FEL
composed over AVPlayer's base-layer frames (`.outputFrames`), or the session's own decode of a stream AVPlayer is
served a placeholder of (`.clock`).

- **Frame identity is the served time.** Units, the decoders' pictures (they run in the served time base) and
  AVPlayer's frames share it (`OverlayPacketTap`, `ServedVideoTime`). No millisecond keys.
- **Asking for a frame.** `pixelBufferAndDisplayTime(forItemTime:)` hands over the frame on display at the time
  asked, so the renderer asks at the middle of the interval the frame is served for
  (`OverlayFrameSource.frameInterval(after:)`): that frame for any axis under half a frame.
- **Pairing.** AVPlayer's frame is paired with the unit nearest the time AVPlayer reports for it.
- **Pacing.** The layer's timebase follows the item's one for one; each refresh tops the layer up to 9 frames ahead
  (about 370 ms at 24p) as soon as AVPlayer has decoded them, and the layer chooses the refresh. The make queue
  composes off the render queue.
- **FEL.** A frame waits for its enhancement picture while it is more than 0.1 s from the clock, then is composed
  with the residual off. The look-ahead is what gives the enhancement decode its time.
- **Start of a run (a load, a resume, a seek).** The producer holds a run's first segment until the picture AVPlayer
  starts on is decoded (`OverlayRunStart`):
  - every producer's first video unit opens a run, forward and backward seeks alike;
  - the target is AVPlayer's reported time (`currentTime()`), waited for briefly; before AVPlayer exists, the
    session's start position;
  - AVPlayer's staging and a clock still reading where a seek left from do not move the decode;
  - the hold passes when the picture on screen at the target is decoded, exactly;
  - the run being cut is not trimmed while the clock has left it (a backward seek's units are far behind the stale
    clock).
- **Not covered:** a run whose axis is half a frame or more (a Matroska cue naming an ordinary frame, AE#408). The
  in-band clock measures it; the overlay does not apply it yet.

## What AVPlayer does (verified)

- **Seeks are zero tolerance** in the engine (`NativeAVPlayerHost`). When playback starts, the item's timebase runs
  from 50 to 185 ms before the target so as to reach it at the host time it starts on, while the item's time sits at
  the target. This is `setRate(_:time:atHostTime:)`'s documented behaviour (AVPlayer.h), measured at 50 ms on Mac
  speakers, 106 ms on an iPhone speaker and 185 ms on an Apple TV with AirPods. Nothing before the target is shown,
  so holding the target's picture through that lead is correct.
- **`currentTime()` reports a pending seek's target** about 50 ms after the seek, before any of its data arrives.
  The item's timebase moves only when the seek's segment is complete.
- **AVPlayer asks for the seek's segment** about 2 ms after the seek, before `currentTime()` reports the target.
- **A seek does not complete on a partial segment.** Served up to and including the fragment holding the target,
  AVPlayer neither moves its clock nor decodes a frame, and after about 3.5 s asks for the rest with a Range request.
- **Staging.** While a freshly loaded item gets ready, its clock stages at the first picture of the segment it asked
  for, then returns to the target.
- **Segment placement.** AVPlayer places a run's first segment at its playlist position whatever `tfdt` it carries,
  and plays continuously from there (segment-axis.md). With the engine's playlist (`EXT-X-INDEPENDENT-SEGMENTS`) a
  seek asks for the target's segment first.
- **The engine's own landing** starts playback at 1.5 s buffered ahead, rechecking for up to 3 s, then leaves it to
  AVPlayer's auto-wait.
- **APIs on tvOS 27.** `copyPixelBuffer(forItemTime:itemTimeForDisplay:)` and the dictionary initializer are
  deprecated for `pixelBufferAndDisplayTime(forItemTime:)` and `init(pixelBufferAttributes: CVPixelBufferAttributes)`
  (both from 26); `ItemVideoOutput` holds the only fallback. `AVPlayerItemSampleBufferOutput` (27) delivers decoded
  PCM audio only.

## Health check on a device

The overlay logs a counter line every 10 s (`[SoftwareOverlay] pulled …`) and per-frame timings. On a healthy FEL
session (Apple TV, 23.976, matched mode):

| Counter | Healthy | Broken (2026-10-27) |
|---|---|---|
| late | 1 to 10 in 10,000 | 1155 of 1595 |
| residual off | 0 | 568 of 1595 |
| refreshes ending `at look-ahead` per 10 s | 142 to 382 | 0 |
| refreshes ending `at output edge` per 10 s | about 18 | 222 |
| pulled ahead of the clock (median) | about 370 ms | 0.4 ms |
| pictures on screen for one refresh | 240 of 240 | 19 of 36, 79 out of order |

The TV's log is served by the app (`curl http://upstairs-lounge.local:8742/grep?q=…`). On a Mac, `aetherctl play
<url> --fel --assert-dv` prints the same lines; keep the display awake (`caffeinate -u`).

## The 2026-10-28 regression

- **What happened.** Our work was folded onto upstream, which brought in AE#886's frame grid. Our overlay named
  frames by the source's whole milliseconds and asked AVPlayer for each at that time plus 0.5 ms. With video served
  on the grid a frame can sit up to a source tick from its millisecond, the request landed before the frame, the
  pull stopped at AVPlayer's output edge, the look-ahead collapsed and FEL frames went out late and without their
  residual.
- **Why it was missed.** Each design was correct alone; the producer-to-overlay timing contract was not reconciled,
  and FEL was not played on the TV before the folded branch was installed.
- **Fix** (`0f195745`): one frame identity, the served time, everywhere in the overlay.
- **Ruled out on the way:** progressive segment delivery (switched off, still broken), the renderer and composer
  diffs (the look-ahead of 9 frames is the same value on both branches), the GPU layer, the enhancement decode.
- **Lesson.** When an upstream change touches muxing, timestamps, segments or AVPlayer's output, read our side of
  the contract end to end before judging, and play a FEL title on the TV, comparing the counters above.

## Measuring

- Use the engine's own segments for AVPlayer experiments (serve with `aetherctl serve` and copy them). FFmpeg's hls
  segmenter with `frag_duration` produced segments whose fragments did not match their declared durations.
- `aetherctl serve` takes H.264 and HEVC only, and no request headers.
- Prefer the API's documented contract to a measurement where one exists; measure only what it leaves open.
