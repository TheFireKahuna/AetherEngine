# Seek cost on the loopback path

Where the time goes when a viewer seeks outside the buffered window on the native path (AVPlayer playing
the engine's loopback HLS), and how to cut it without moving audio against video.

## Measured (Apple TV, 2026-10-25/26, remote MKV, HEVC + TrueHD Atmos through the spatial bridge)

From AVPlayer asking for the target segment to the target picture on screen:

- Inside the buffered window, or to the start: 133 to 250 ms.
- Outside it: 661 ms, 755 ms, 814 ms, 828 ms, 1.12 s, 1.77 s.

Two of the slow ones, step by step:

| Step | 1.18 s seek | 1.81 s seek |
|---|---|---|
| AVPlayer asks for the segment; the producer restarts | 38 ms | 21 ms |
| First bytes from the origin | ~110 ms | not logged separately |
| Read up to the target's keyframe | 470 ms | 1,354 ms |
| Read the rest of the first segment (18.2 MB / 12.7 MB) | 400 ms | 330 ms |
| AVPlayer loads, decodes and displays | 153 ms | 106 ms |

Each seek opens one reader on the origin and reads forward once; the audio bridge takes its packets from the
producer's read, so nothing is fetched twice. The buffered window does not help because the target is
outside it.

## Where the bytes go

```
keyframe K0        target - pre-roll              target keyframe K1
   |----- A -----------|------------- B ---------------|----- first segment ----->
```

- **Pre-roll.** The audio bridge reads 1.66 s of source before the target (`AudioSegmentRuns.preRollSeconds`),
  so the encoder reaches the boundary in the state continuous playback left it in and the restarted segment
  is the segment continuous playback cut. Of that, 0.5 s is a fixed allowance for the longest packet of any
  bridged codec (Vorbis at 8 kHz); TrueHD's packets are under a millisecond.
- **A:** the read can start only at a keyframe the container's index lists, the one at or before
  target - pre-roll. Everything in A is read and dropped: its audio is earlier than the encoder needs and its
  video is before the target.
- **B:** its audio feeds the encoder; its video is dropped. An interleaved container stores both together,
  so B's video is the cost of B's audio.
- **First segment:** AVPlayer receives nothing until the whole segment (2 to 2.6 s of media, 12 to 18 MB) is
  written, because segments are served at their cut.

## The rule

Seeking cannot move audio against video: every sample's position comes from the bitstream and the segment
plan, and nothing below changes that. The pre-roll protects something narrower, that the restarted audio
equals continuous playback's. So every change below must leave the delivered samples identical to continuous
playback's, which `AudioSegmentRunsTests` ("a seek makes the segments continuous playback made") checks byte
for byte, and each one ends with a lip-sync check on the TV.

## Steps, safest first

1. **Serve the first segment while it is written.** Done: every VOD segment is now served as it is written
   (the former opt-in `progressiveSegmentDelivery`, now the only behaviour; live still serves at the cut).
   The muxer flushes a fragment every 0.5 s and the loopback server sends each one as it lands. Samples and
   timestamps are unchanged: the A/V sync suite places the click on the white frame to the sample for every
   container and codec, with audio delays of ±0.7 s (longer than the fragment window) and for a demuxed
   audio rendition, and a restarted segment still equals the continuous one byte for byte (mfhd aside).
   Measured on a Mac (Trap, 4K HEVC at 97 Mbit/s, TrueHD Atmos, from Jellyfin), seek to landed:

   | Target | Whole segments | Progressive |
   |---|---|---|
   | 1200 s | 489 ms | 398 ms |
   | 3000 s | 536 ms | 448 ms |
   | 4500 s | 736 ms | 585 ms |
   | 5200 s | 864 ms | 661 ms |

   The wait for the first segment roughly halves (438-796 ms to 227-383 ms); AVPlayer still buffers some way
   into it before it lands. Owed: the same pattern on the TV.
2. **Overlap the reads.** While A and B arrive, fetch from K1's offset on a second range request, and hand
   the producer packets in file order. Same packets, same order. Pays only if one connection does not fill
   the link; measure that first.
3. **Size the pre-roll's packet allowance by codec.** Replace the fixed 0.5 s with the longest packet the
   bridged codec can carry. Same encoder input from the boundary's packet on; proven by the byte-for-byte
   test across every bridged codec, the spatial bridge included. Saves about 0.5 s of media per seek.
4. **Start inside the previous group of pictures.** Use the container's cluster timestamps to begin at the
   cluster holding target - pre-roll rather than at K0. Pays only on titles muxed with clusters shorter than a
   group of pictures; survey the library first.

Not done: a pre-roll shorter than the encoder's memory. That changes the audio at the seek point.

## Overlay sessions: the picture a seek starts on

On an overlay session (a Profile 7 FEL composed over its base layer, or a codec the engine decodes itself) the
producer holds a run's first segment from AVPlayer until the overlay has decoded the picture AVPlayer starts on
(`OverlayRunStart`), so the first frame shown is the full picture. Before this work the hold waited for the wrong
picture:

- It waited for a picture within 0.1 s of the run's first keyframe, while the decoder worked toward AVPlayer's clock.
  A resume or seek partway into a group of pictures waited out the 5 s bound (a TRON resume on an iPhone:
  `no picture yet, released after 5005 ms`).
- A run was detected by decode time going backwards, so a forward seek opened no run and was held for nothing.
- On a seek during playback the overlay learned the target only when AVPlayer's clock moved, which happens when the
  seek completes, after the held segment is released. Measured on a Mac with Civil War from Jellyfin: the hold
  passed at once, and the seek to 900.45 s showed 67 frames not ready and 19 composed with the residual off.

### What AVPlayer does, measured

- A zero-tolerance seek moves the clock only once the target segment is complete. Serving the segment up to and
  including the fragment holding the target is not enough: AVPlayer neither moves its clock nor decodes a frame, and
  after about 3.5 s asks for the rest with a Range request. The hold stays a whole-segment hold.
- `currentTime()` reports a pending seek's target 50 to 57 ms after the seek, before any of its data arrives, while
  the item's timebase (which the overlay follows) stays where it was. This holds for every seek: the engine's own,
  AVKit's transport bar, a resume.
- AVPlayer asks for the segment about 2 ms after the seek, before `currentTime()` reports the target (the same race
  #207 notes), so the target is read when the hold decides, not when the run opens.
- When it starts playing, AVPlayer's timebase runs from 50 to 185 ms before the target so as to reach it at the host
  time it starts on, while the item sits at the target (`setRate(_:time:atHostTime:)`, documented). Nothing before
  the target is shown, so the overlay holding the target's picture through that lead is correct.
- While a freshly loaded item gets ready, its clock stages at the first picture of the segment it asked for, then
  returns to the target. That staging is not a target.

### The fix

- The producer marks every run: its first video unit opens one, whichever way the seek went.
- The picture AVPlayer starts on is the one on screen at its reported time (`currentTime()`), read off the main
  actor as #134 does. Until AVPlayer exists (a load whose first run is cut before the item is made) the session's
  start position stands in, which is what AVPlayer then reports.
- If the reported time is not yet inside the run, the hold waits a short bound for it (the report lands within
  60 ms of a seek) before treating the run as cut ahead of a playing clock, which holds nothing.
- The decode works toward that picture as soon as it is known, and AVPlayer's staging does not move it.
- The hold passes exactly when the picture on screen at the target is decoded: the newest at or before it, once a
  picture at or after it exists. No tolerance window.
- The 5 s bound stays, as a failure bound only.

Proof: unit tests of the hold and the tap; the overlay A/V sync test resumed partway into a group of pictures
(nothing before the resume point presented, started within 3 s, the click on the white picture); the Civil War FEL
run from Jellyfin with a resume and mid-group seeks, every seek held for its own picture with no frame not ready or
composed without its residual. On the TV: a FEL resume and transport-bar scrubs, with the same counters.

## Overlay sessions: one time for a frame

The overlay names every frame by the time AVPlayer is served it at, exactly: the producer computes it once
(`HLSSegmentProducer.servedVideoTime`, the frame grid's slot where AE#886 puts video on one, the frame's own time
otherwise, in the session's one served time base) and hands it to the taps. The unit, the decoder's picture of it
(the decoders run in that time base) and AVPlayer's frame share it. Before, the taps named frames by the source's
whole milliseconds and the renderer asked for each at that time plus 0.5 ms, which held only while video was served
at those milliseconds; on the frame grid the request landed before the frame, the pull stopped at AVPlayer's output
edge, the look-ahead fell from about 370 ms to the clock, and FEL frames were composed with the residual off.

- AVPlayer's item time for a frame is its served time plus the run's axis, which an honest plan keeps within
  EXTINF's rounding of zero.
- The renderer asks the output for a frame at the middle of the interval it is served for
  (`OverlayFrameSource.frameInterval(after:)`): `pixelBufferAndDisplayTime(forItemTime:)` hands over the frame on
  display at that time, which is that frame for any axis under half a frame.
- AVPlayer's frame is paired with the unit nearest the time AVPlayer reports for it, which is its own while the axis
  is under half a frame (`OverlayPacketTap.unit(at:)`).
- Not covered: a run whose axis is half a frame or more (a Matroska cue naming an ordinary frame, AE#408). The
  in-band clock measures it; the overlay does not apply it yet.
