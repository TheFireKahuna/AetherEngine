# Audio as its own rendition

Status: built, 2026-10-26: the two shapes, the demuxed producer, cache, provider, server and master (9dc24723);
the joined view a refused master falls back to (2e9797a6). `ProducerDeterminismTests`, `DemuxedAVSyncTests` and
`DemuxedOutputTests` pass with the app's traits. Not yet built: the forward-shifted timeline origin (section 3).
Device acceptance pending. One cutover:
a session served through a master moves from muxed segments to Apple's shape, a video-only variant and an
audio rendition declared by `EXT-X-MEDIA:TYPE=AUDIO,URI=...`, with no transition period. A session AVPlayer
must play from a bare media playlist keeps muxed segments, because a media playlist cannot reference a
rendition (see "Two shapes"). Each session is one shape for its whole life.

## Why

The engine muxes video and audio into each fMP4 segment (one init with two `trak`s, one `moof` with two
`traf`s per segment). The master's `EXT-X-MEDIA:TYPE=AUDIO` has no `URI`; it exists only because it is
where AVFoundation reads the audio's language and `CHANNELS` (AE#458, AE#726). That is outside Apple's HLS
Authoring Specification for every multichannel title we serve:

- 9.5: "You SHOULD deliver video and audio as separate streams."
- 9.6: "If you have multichannel audio, you MUST use separate audio streams."
- 9.7: alternative audio (languages, commentary, description) MUST use separate audio streams.
- 8.9: separate audio streams MUST be declared using `EXT-X-MEDIA` tags.

Separate audio also makes the work that led here possible: audio can be re-cut without touching video (an
audio delay, a track change), and a rendition switch inside one item replaces a session rebuild.

## What the spec and the protocol fix

- **Packaging.** fMP4 audio (2.1; MUST for FLAC, ALAC, xHE-AAC and APAC, 2.25), `EXT-X-MAP` per playlist
  (8.20), one audio stream per segment (2.17), every `traf` with a `tfdt` (rfc8216bis 3.3).
- **Playlists agree.** The same target duration (8.2), the same content duration and media time range
  (8.3, 8.7), discontinuities at the same points (8.15), and segment boundaries at the same points in time
  (8.22, SHOULD; audio lands on the nearest audio frame, which our routing rule already does).
- **Segment starts.** APAC segments start with an ASP (7.9); `EXT-X-INDEPENDENT-SEGMENTS` covers every
  playlist (9.11), so every audio segment decodes on its own, which the segment runs already guarantee.
- **Timing.** Renditions synchronise by media timestamp within a discontinuity domain: "Matching content in
  Variant Streams and Renditions MUST have matching timestamps" (rfc8216bis), and "the first segment of every
  Media Playlist ... MUST start at the same media timestamp" (RFC 8216 6.2.4). Audio and video `tfdt` share
  one timeline origin. "In HLS, playback starts at the earliest presentation time of video sample" (WWDC20
  10011), so audio may start before video.
- **Priming and negative time.** Apple's HLS profile writes no edit list: "baseMediaDecodeTime of audio
  media is shifted the amount of priming backward", and because `tfdt` is unsigned, "shift both audio and
  video forward by same time offset"; mediafilesegmenter uses ten seconds (WWDC20 10011). HLS clients assume
  no relationship between the first segment's media timestamp and presentation time (Apple, developer forums
  thread 113190).
- **Master.** `CODECS` lists every format of the variant's renditions; `BANDWIDTH` and `AVERAGE-BANDWIDTH`
  are the largest sums over playable combinations (9.13, 9.14); `LANGUAGE` on every non-video `EXT-X-MEDIA`
  (8.10); `CHANNELS` on every audio rendition (`16/JOC` for E-AC-3 Atmos, `count/3OA/BED-n` style for APAC);
  tvOS forbids audio-only variants (9.20 tvOS), which a rendition is not.
- **Metadata.** The spec places no in-band `emsg` on a rendition; it stays on video.

## Two shapes

Where AVPlayer refuses the master, the engine plays the bare media playlist, which bypasses the variant
filter that refuses it. A media playlist has no way to name an audio rendition, so those sessions carry
audio muxed, as today:

- **Media-direct start** (`resolveUseMasterPlaylist`): an HDR or Dolby Vision source on a panel not in HDR
  mode (a master is refused, a media playlist is tone-mapped), and an HDR source with no frame rate (#130).
  An SDR H.264 session with nothing needing a master is served the master, in the demuxed shape, instead.
- **The #98 fallback:** AVPlayer refused the master (-11868, -11848, -1002); the reload plays media-direct.
- **AirPlay to an SDR receiver** (`AirPlayPlaylistDecision`): any HDR master is refused there.

Everything else is served through a master in the demuxed shape. The shape (`HLSOutputShape`) is decided in
`prepare()` before the first producer is built, from the playlist the load planned before the display switch
(`plannedServesMaster`, a8ebc8ba): demuxed when the master is planned and the source carries audio, muxed
otherwise, including a load that leaves the answer to the settled panel (live, and an unproven HDR-eligible
display the host may not attempt), since muxed plays from either playlist. It never changes within a session. A
cascade that ends video-only is muxed.

Where a demuxed session's master is refused, it swaps in place, as a muxed session does, to its two renditions
joined (`FMP4Join`, `muxed.m3u8`): each segment the video's and the audio's cut files merged at box level into
the layout a muxed segment has, one `moof` with a `traf` per track over one `mdat`. Only boxes are rearranged,
so every sample keeps its bytes and timing and the joined view is as deterministic as the renditions. A joined
segment is ready when its audio half is, the same moment the muxed shape's cut gate and the audio rendition wait
for: both need the source read to the next boundary.

Whether a tvOS 27 panel parked in SDR still refuses an HDR master is measured on the G5 (acceptance 7). If
it no longer does, the first case moves to the demuxed shape; AirPlay to an SDR receiver keeps the muxed
one regardless.

## The demuxed shape

```
master.m3u8
  #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME=...,LANGUAGE=...,CHANNELS=...,DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"
  #EXT-X-STREAM-INF:...,CODECS="<video>,<audio>",AUDIO="aud",...   media.m3u8
  (I-frame and subtitle renditions as today)
media.m3u8   video only: init.mp4 (+ versioned inits), seg<N>.mp4, the emsg in-band clock
audio.m3u8   audio only: audio-init.mp4, audio<N>.mp4, the same index space, EXTINF, discontinuities
```

One audio rendition, the selected track, as today. Serving every source track as a rendition (AVKit's own
audio menu, switching without a rebuild) is the follow-up this shape enables; it is not part of the cutover,
which changes no host-visible behaviour except where noted.

## Design

### 1. One pump, one or two muxers

`HLSSegmentProducer` keeps one pump, one demuxer read and one restart lifecycle. Demuxed, it writes two
`MP4SegmentMuxer`s, video and audio, each with its own cursor, cut, staging file and adoption; muxed, the one
muxer it writes today. Restarts, revives and epochs stay atomic across the renditions because there is still
one producer.

- **Routing is unchanged.** Video by the keyframe-gated cutter, audio by `AudioRunPlan` (the segment its last
  sample plays in). Each muxer cuts when its own track routes past a boundary, so a late audio packet can no
  longer be pushed into a later file by the video cursor.
- **The cut gate is the muxed shape's.** `SegmentCutGate` exists so both tracks land on the right side of a
  boundary in one file; demuxed, each track has its own file and nothing is held, so the producer does not
  build the gate. The #731 bridge settle before a cut stays where audio follows the video cutter.
- **Restart gates, the pregate audio buffer and the shared shift are unchanged** (`audioShiftPts` inherits the
  video shift, which is what keeps both renditions on one timeline).

### 2. The audio-only muxer

`MP4SegmentMuxer` today requires video and hardcodes stream 0 video, 1 audio. It gains an audio-only form
(the video-only form already exists, `IFrameFragmentBuilder`):

- stream indices from the configuration, not constants; the clock state and NAL sanitizer only with video;
- the #64 interim-flush bound on the audio DTS window for the audio muxer, so progressive delivery still
  streams audio;
- per muxer: the AE#222 wedge guards and moov prime (audio only, so video's init and segments are never held
  by audio's sample entry), the audio delay and before-zero rule (audio only), `mdhd` language and the APAC
  sample-entry and pre-roll rewrite (audio only), the `emsg` (video only), `SegmentOpening` (picture from
  video, sound span from audio).

### 3. One timeline origin, shifted forward (not yet built)

Both shapes. Every track is written on the item axis plus a constant origin offset, as Apple's tools do. The offset
covers the largest audio delay (`AudioDelayPolicy.maxAbsSeconds`, 2 s) plus the longest audio frame, so no
audio timestamp is ever below zero:

- **The negative-delay start loss goes** (item 1 of the gapless review): the packet that straddles 0:00 is
  written whole, and nothing before the first picture is cut, because playback starts at the earliest video
  presentation time.
- **The muxer's before-zero drop and its AE#561 comment go**: there is no below zero.
- The in-band clock already measures where AVPlayer places each segment, so position and subtitles need
  nothing; the offset is invisible to the host.

### 4. Cache, provider and server

- **Cache.** A second `SegmentCache` for the audio rendition, beside the video's. The session's retention budget is
  split between them by bitrate, the audio's share its bitrate's share of the session's, so both keep about the
  same span resident; the claim counts both. Init versions stay video-only (a program switch rotates the video
  muxer; the audio playlist takes the discontinuity at the same index, 8.15).
- **Requests.** Only video requests declare the video's target and drive `handleTargetChange` (restarts, the #358
  fold re-anchor, the fetch high-water backpressure reads). An audio request waits for the producer's march, which
  cuts both renditions of an index, and restarts the producer only where no march reaches the index: a producer
  stopped after adopting an index's video and before its audio, or audio evicted while the video stayed resident.
- **Playlists.** `buildMediaPlaylistText` takes the rendition and lists the same indices, `EXTINF` and tags from the
  same snapshot, as the subtitle playlists already do; the audio's init is never versioned. The video playlist's
  build counters stay the video's.
- **Master.** The audio group is emitted whenever there is audio (a `NAME` when the track has no title,
  `LANGUAGE` always, `und` when unknown), with `URI="audio.m3u8"`. `CODECS`, `BANDWIDTH` and
  `AVERAGE-BANDWIDTH` already describe video plus audio. The `/audio.m3u8` alias to the media playlist goes.
- **Routes.** `audio.m3u8`, `audio-init.mp4` and `audio<N>.mp4`, served by the one segment function both
  renditions share (`HLSLocalServer.serveSegment`), progressive and early-header handling included; the video
  keeps its file fast path.

### 5. No audio in a segment

A muxed segment always held video; an audio segment can have no audio (a late-starting track, a gap in the
source, the AE#222 video-first interleave). A 0-byte cut ends the pump today (`MP4SegmentMuxer.swift:1007`).
The audio playlist still covers every index (8.3). It cannot mark one with `EXT-X-GAP`: a VOD playlist is written
before any segment is cut and read once, so which indices hold no audio is not known when it is. The index is
served instead as a fragment with no sample (`MP4SegmentMuxer.emptyFragment`: a `moof` whose one track fragment has
a `tfdt` at the segment's start and no run, ISO/IEC 14496-12 allows it, and an empty `mdat`), for an index the cut
found empty, one the audio skipped, one before the audio started and one after it ended. Bridged audio has no such
segments (it fills gaps with silence); copied audio passes the source's gaps through, as it does today.

### 6. Live and sequential origins

A live load leaves the playlist to the settled panel, so live is muxed and unchanged. A sequential origin can be
demuxed; its audio follows the video cutter as before, an index is advertised when its video is adopted, and an
audio request for it waits on the audio rendition's cache until the producer cuts it.

### 7. Hosts

The paths that play `media.m3u8` directly are the muxed shape's (see "Two shapes"); each decides the shape
with the route:

- the initial route's media-direct case, and any audio is now a reason to serve the master where it plays
  (`playlistDecision`'s audio term), so an SDR source with audio moves to the master;
- the #98 master-rejection fallback, the #35 gate's media step and the refused-AirPlay-master recovery swap
  their item as before: `mediaPlaylistURL`, the playlist that plays alone, is the joined view for a demuxed
  session, so these sites are unchanged;
- AirPlay's media rewrite takes that playlist's name from the session.

Readers of the served bytes:

- **The loopback audio tap (#95)** reads the audio rendition's init and segments in the demuxed shape, the way
  the remote-HLS tap already follows `EXT-X-MEDIA` audio URIs, and the muxed segments in the muxed one.
- **Scrub stills, the held picture, the compositor preview** read the video init and segments as now, with
  less I/O; their init and version lookup is the video rendition's.
- `aetherctl segverify` checks the video's decodability; its bare session is muxed.

Diagnostics counting requests or bytes (`numberOfMediaRequests`, `serverLifetimeBytesSent`, the live reload
watchdog) count both renditions; what they compare against is adjusted, not the counting.

Sodalite: nothing depends on the segment shape. Its own "Audio Track" menu stays, since one rendition is
served; its note "until the tracks are served as renditions" becomes the follow-up.

### 8. What is unchanged

Routing rules, segment plans, the in-band clock and its reader, the I-frame rendition (already video-only),
subtitle renditions, the FEL overlay, the Dolby Vision audit and the Atmos confirmation (all read the
session's packets, not segments), the software and sample-buffer routes (they take packets).

## Tests

- **Both shapes.** Every producer-level test runs both shapes: the same routes, segments and timing, one file
  or two.
- **Determinism.** `ProducerDeterminismTests` compares each rendition's segments, continuous against seeking,
  and keeps the sound-from-the-first-picture check across renditions (audio `audio<N>` against video `seg<N>`
  on the shared origin).
- **A/V sync.** `DemuxedAVSyncTests` read the white frame from the video rendition and the click from the audio
  rendition, each at its first `tfdt`, delays included, and the joined view to within half a sample of them.
- **The joined view.** One `moof` of two `traf`s whose samples equal both renditions'.
- **The muxed shape's tests stand:** a bare `HLSVideoEngine` session plans no playlist and so is muxed, which is
  what `RestartTimelineContinuityTests`, `InBandClockTests`, the per-track `traf` walks, the init sample-entry
  tests and the master-text tests read; they test the muxed shape unchanged.
- **New:** both playlists agree (indices, `EXTINF`, tags); an audio request waits for the producer instead of
  restarting it; the sample-less fragment's layout.
- `SegmentCutGateTests` stay with the muxed shape.

## Acceptance on the Apple TV

Measured on the G5 with the receiver, before the cutover is called done:

1. Video and audio start together and stay in sync on a Matroska, an MP4 and a TS source, copied and bridged,
   and on a TrueHD Atmos title (Atmos on the receiver) and an APAC title.
2. Seeks, a resume and an audio-track change behave as today.
3. A negative and a positive delay: nothing silent at 0:00 or after a seek.
4. The in-band clock still reads every segment (the `emsg` on video with a second rendition present).
5. An audio segment with no sample is played through.
6. The fallbacks play with sound: the #98 fallback onto the joined view, and AirPlay to an SDR receiver.
7. A panel parked in SDR (Match Content off) handed an HDR master with a demuxed audio rendition: refused or
   tone-mapped. This decides whether the media-direct start stays muxed.

## Follow-ups this enables (not in the cutover)

- **Every source audio track as a rendition**, switched by AVPlayer inside the item (AVKit's audio menu);
  Sodalite's own menu and `selectAudioTrack`'s rebuild retire.
- **A seamless audio-delay change:** only the audio rendition is re-cut, and the change reaches the playhead by
  a rendition switch rather than an item rebuild. Whether AVPlayer refetches a rendition it has played, how long
  the switch's audio gap is, and whether the receiver keeps Atmos locked across it are measured first;
  community reports of iOS 26 snapping back to the `DEFAULT=YES` rendition are checked on tvOS 27.

## Sources

- Apple, HLS Authoring Specification for Apple Devices (rev. 2025-06-26):
  https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html
- RFC 8216: https://www.rfc-editor.org/rfc/rfc8216 ; draft-pantos-hls-rfc8216bis-22:
  https://www.ietf.org/archive/id/draft-pantos-hls-rfc8216bis-22.txt
- WWDC20 10011, Author fragmented MPEG-4 content with AVAssetWriter:
  https://developer.apple.com/videos/play/wwdc2020/10011/
- Apple Positional Audio Codec: https://developer.apple.com/av-foundation/Apple-Positional-Audio-Codec.pdf
- Apple developer forums 113190 (tfdt and presentation time), 818465 (audio rendition selection on iOS 26)
