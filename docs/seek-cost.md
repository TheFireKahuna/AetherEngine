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
