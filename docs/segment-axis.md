# Honest segment boundaries and the in-band clock

load-time Cues check that was built and withdrawn on its cost.

## Why

AVPlayer places the first segment of every run it opens at that segment's playlist position, whatever
`tfdt` the segment carries, and plays continuously from there (AE#418, measured with
`play --picture-probe`). A segment whose content does not begin at its advertised start therefore gives
the run an item-to-source offset. Apple's authoring spec makes that unavoidable wherever a boundary is not
a sync sample: "Video segments MUST start with an IDR frame" (HLS Authoring Specification 7.4), and a VOD
playlist is fixed before playback.

The engine has to know that offset to report position, place subtitles and captions, and land seeks. It
predicts it today: about 1,100 lines of `HLSVideoEngine.swift` (3641 to 4700) compose an axis per
placement, read `AVPlayerItem.loadedTimeRanges` to check it, learn a "distance" from the readings, and
roll back or keep a composition when nothing can be read. Every round of AE#418 added another inference
about AVPlayer, and the inference fails where `loadedTimeRanges` cannot tell two cases apart: on the
B-frame cues-lie fixture a seek made AVPlayer append a re-aimed segment to the run it was playing, the
engine composed -12.167 s, the picture stayed on -9.000 s, and the published position ran 3.2 s (77
frames) off the picture. The build before `4260bd17` does the same, to the tick.

The fix has two parts and no overlap between them: make the offset not exist wherever the source can
state its random-access points, and measure it, from the content itself, where it cannot.

## Measured

### The in-band clock (probe, 2026-10-25)

Each VOD segment carried an `emsg` version 1 box before its `moof`: scheme
`https://developer.apple.com/streaming/emsg-id3` (the scheme Apple's clients require for ID3 in fMP4),
timescale and `presentation_time` of the segment's first picture, and an ID3v2.4 `TXXX` frame stating its
index, its `tfdt` and its source time. `AVPlayerItemMetadataOutput` handed each one back stamped with the
item time AVPlayer played it at. Both are public API.

Against the picture (`--picture-probe`, timecode fixtures), the measured axis (source minus item) equalled
the picture's `axisErr` on every arm:

| Arm | Picture | Metadata | Current model |
|---|---|---|---|
| late open, resume at 75.0 (`tc-late.mkv`) | +0.225 | +0.225 | +0.225 |
| early re-aim, resume at 53 plus a seek (`tc-cues-lie.mkv`) | -9.000 | -9.000 | -9.000 |
| seek burst 65, 60, 70, 58 (`tc-bf-cues-lie.mkv`) | -9.000 | -9.000, every segment | up to 78 frames off |
| re-aimed seg34 appended to a playing run | -9.000 | -9.000 | -12.167 |

The output has to be asked for every identifier and filtered by the reader: asked for the ID3 `TXXX`
identifier alone, it stamps a group with the segment's raw `tfdt` instead of the item time AVPlayer plays
it at (75.125 against 74.900 on a segment AVPlayer placed 0.225 s below its `tfdt`, the picture on the
second).

Delivery, with `advanceIntervalForDelegateInvocation = 5`: about 4 s ahead of the frames. The segment a
seek or a mount lands in is delivered at the landing, even though its start is behind the playhead,
provided the output is attached when the item is created (attached a second late, the mount's segment was
missed).

On the Apple TV 4K (A15, tvOS 27.2), *The Batman* (4K HEVC Dolby Vision, TrueHD bridged) through the app
from Jellyfin: 166 groups, every segment of every run, all five landings including three scrubs, lead about
4.0 s. That title's plan is keyframe-true, so its axis read 0 throughout; a non-zero axis is proven on the
Mac only.

### What the containers state

| Source | Random-access points | What the plan uses today |
|---|---|---|
| MP4/MOV | `stss` | `stss`, through libavformat's index |
| Matroska | Cues. RFC 9559 22.1: "each keyframe SHOULD be referenced by a CuePoint", "RECOMMENDED to not reference non-keyframes". 10.4: a RAP MUST set the keyframe flag, or its BlockGroup MUST NOT hold a `ReferenceBlock`. `CueClusterPosition` mandatory; `CueRelativePosition` (DocTypeVersion 4) and `CueBlockNumber` optional. 25.1: clusters RECOMMENDED at most 5 s or 5 MB. | libavformat's index, which enters every cue as a keyframe (AE#408) |
| loose `.m2ts`, plain TS | nothing in the container. In-band only (`random_access_indicator`, NAL types); Blu-ray caps the spacing at about 1 s | uniform grid |
| HLS sources | their own segment starts | used (AE#268) |

The library this has to serve is 1,951 items: 1,915 Matroska, 36 MP4, one `.m2ts`.

MPEG-TS and PS have an index only in the sense that libavformat records what it read, and the packets a
timestamp search probed are entered "flagged keyframe whatever they are" (`Demuxer.indexedKeyframes`), so
a TS keyframe plan can carry false boundaries too; it is only used when it passes the coverage test.

### Checking Matroska Cues at load (built, measured, withdrawn)

Each plan boundary's block was read for its keyframe flag before the plan was built (one read per
boundary with `CueRelativePosition`, 32 lanes, started when the probe opened). Exact, and on the
lying-Cues fixtures every arm then opened on its boundary with no re-aim and axis 0. But a plan at the
2 s target has about 5,000 boundaries for a long film, and the cost is the origin seeking its disk:

| Title (4K remux, Jellyfin) | Boundaries | Plan waited | Refused |
|---|---|---|---|
| *Dune: Part Two*, cold | 4,975 | 10.7 s | 0 |
| *Blade Runner 2049*, cold | 4,914 | 10.4 s | 0 |
| *The Batman*, warm | 5,286 | 2.3 s | 0 |

About 8 s of that would be added to a cold start on the Apple TV, for every Matroska file, to guard
against the rare one whose Cues name ordinary frames; nothing in a file states its Cues are honest without
reading them. Withdrawn: the boundary is checked where the producer reads the block anyway.

## Design

### 1. Honest boundaries

Each source's plan comes from the random-access points it states, so every segment begins where the
playlist says and the offset is zero by construction.

- **Matroska:** the Cues are the plan's boundaries, as RFC 9559 22.1 intends, and the block's own flag is
  the truth: the producer reads each boundary's packet when it opens a segment there and sees whether it
  is a sync sample, at no cost. A file that follows the spec (every one measured) opens every segment on
  its boundary. One whose Cues name ordinary frames (AE#408) is caught at that read: the AE#408 re-aim
  opens on the covering sync sample, and part 2 measures the offset.
- **Loose `.m2ts` and TS:** the uniform grid stays. The offset is bounded, known exactly to the producer
  at its gate, and measured by part 2.

The AE#408 re-aim stays, for the one case it exists for: a Matroska cue that names a block that is not a
sync sample. A uniform grid never claimed random access, and an honest plan never triggers it.

### 2. The in-band clock

The `emsg` above, written by the muxer at the start of every VOD segment, and an
`AVPlayerItemMetadataOutput` attached by the host when the item is created. The engine's item-to-source
map is what that output reports, segment by segment: reported position, subtitles and captions read it.
On an honest plan it reads zero. On the uniform grid it reads the run's offset, and a seek landing is
corrected by the landing segment's own report, which arrives at the landing.

### 3. Deleted

- The AE#418 model: compositions, `PublishedPlacement`, placement readings off `loadedTimeRanges`, the
  learned displacement, held and unreadable resolution, the AE#481 landing reading, the #534 snaps, and the
  sampling tasks in `AetherEngine+Diagnostics`.
- `4260bd17`'s per-segment sound lag and `positionedItemSeconds`, which exist only to correct those
  readings.
- `EpochAxisTable`, down to what the measured map needs or replaced by it.
- AE#412 recuts, re-evaluated: they exist for segments that carry no random-access point at all, which an
  honest plan cannot produce and Blu-ray's GOP cap rules out on a loose `.m2ts`.

## A/V sync

None of this moves audio against video. Honest boundaries change which timestamps start segments, not any
sample's timestamp; audio and video keep one shift. The `emsg` is metadata: no sample and no `tfdt`
changes, and `trun` offsets are relative to their `moof`, so a box before it moves nothing. That is
proved, not argued: `AVSyncTests` (click on the white frame, to the sample) pass with the box written. The
deleted model only ever fed position, subtitles and seek targets.

Audio has one routing rule (`AudioRunPlan`): a packet belongs to the segment its last sample plays in, on
the output timeline with the audio delay in, copied or bridged. A packet that plays across a boundary
opens the segment after it, so a segment has sound from its first picture and a seek is not silent until
the next audio frame; with a delay, the sound that plays at a boundary is in that segment. A run reads
from where that packet is (`producerReadStart`). Outside this plan: everything after AVPlayer (tvOS
output, HDMI, the receiver).

## Order of work

2. **The in-band clock, as one cutover** that writes the `emsg`, attaches the output, maps position from
   it, and deletes the model. Done (`b85e7ed0`).
3. **Acceptance:** the picture-probe arms (late open, early, appended run, seek burst, drought, uniform-grid
   TS); `AVSyncTests` with the box written (passing); the producer determinism test (#8 step 2), segment N
   byte-identical continuous or after seeks (`ProducerDeterminismTests`, passing on every audio route); on
   the Apple TV, a 4K Matroska title and the `.m2ts`.

   The determinism test found three places a run's first segment differed from continuous playback's, each
   fixed by a rule the producer already had: the muxer now cuts once every track has reached the segment
   (`SegmentCutGate`), not when video does; a run reads from before its boundary where the container
   stores no decode times (`producerReadStart`), so libavformat rebuilds them as it did playing
   through; and a run's audio starts at its plan boundary, not at its keyframe's decode time. The moov
   flush of its own that split a run's first segment into two fragments is gone.
