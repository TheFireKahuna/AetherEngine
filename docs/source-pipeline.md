# Source pipeline: every byte once, every index once, every output on demand

Status: in progress, written 2026-10-24 against `research/12bit-fel` at `a7a725e8` and the tvOS 27.2
SDK (Xcode 27.2), brought up to `503c69f5`, then the cache's validators, write bound and budget
review and the index's lifetime, then layer 3 step 4 (I-frame keyframes from the index), then layer 3
step 1 (one subtitle source per session), then layer 3 step 2 (native subtitles). Layers 1 and 2 are
built (layer 2 for Matroska and MP4); MPEG-TS has no index and is handled on its own terms (its section
below), including programs that change mid-stream; layer 3 is the remaining work, steps 1, 2 and 4 built. Each section says what is done, which tests hold
it, what is not yet ideal with the steps to get there, and what still waits for a device run.

Waiting for a device run, in the order worth doing them:

1. The single byte store (layer 1, "On device"): one title with subtitles, a few scrubs back, against
   the 06:15 session's open timings, reconnects, ledger and `memprobe`.
2. An MP4 with mov_text subtitles: the `MP4SampleIndex` path (`[SubtitleSource] routes ... indexed`,
   `[SubtitleSource] stream N complete from the index`).
3. A transport stream whose PMT changes: a live channel with server-side ads, or a DVR `.ts` that
   crosses a programme boundary, ideally one whose codec changes there (the TS section).
4. Scrubbing with keyframes from the index (layer 3, step 4): an MKV and an MP4, HDR included (the SDR
   stills tier reads the same keyframes), and one non-indexed container for the demuxer route.
   `[IFrameKeyframes] keyframes read from the index` and the `[SourceLedger]` line for the `iframe`
   reader, against a session before it.
5. One subtitle source (layer 3, step 1): an MKV with text and PGS tracks, an MP4 with mov_text, and a
   source whose subtitles are walked (an MKV without subtitle Cues, or a TS). Overlay, a native
   rendition in PiP, and a bitmap track's OCR rendition; then a few seeks. `[SubtitleSource] routes`,
   `reading from ...: indexed [...] walked [...]`, `complete from the index`, and one `subwalk` reader
   (or none) in `[SourceLedger]` where there were `prefetch` and `nativesubs` before.
6. Native subtitles (layer 3, step 2), both of Sodalite's chromes: a text track drawn by AVKit in the
   subtitle settings' style; an ASS track drawn by libass and a PGS track by the overlay, AVKit showing
   nothing under either; with subtitles off on a title with a forced track, tvOS showing its lines by
   itself (forced PGS in the overlay); the caption setting at Always On picking an SDH track; PiP and
   AirPlay showing every kind; a subtitle delay set in Settings mid-play moving a text track to the
   overlay, and PiP then rebuilding to serve it. `[NativeSubtitles] following ...` and
   `forced ordinal=N from the index`.
7. tvOS's own generated subtitles (step 2's follow-ups): the `subs` probe's `case=generated` on English
   speech without English subtitles, before the generated-option path is built.

## Why

A remote MKV played from Jellyfin over HTTP/3 on an Apple TV 4K, measured by `SourceByteLedger`
(the duplicate-traffic books, below) before any of this work:

| Session | Fetched | Unique | Duplicate | Where the duplicate came from |
|---|---|---|---|---|
| 06:15, before | 1,680 MB | 1,123 MB | 557 MB (33.2%) | subtitle prefetch 590 MB (508 dup), indexed subtitles 335 MB (35 dup), I-frame 29 MB (9 dup), pump 720 MB (6 dup) |
| 07:02 to 07:09, before | 35,948 MB | 16,096 MB | 19,852 MB (55.2%) | the subtitle prefetch walked 31.7 GB in seven minutes |
| 07:16, after layer 1 | 870 MB | 870 MB | 0.0 MB | 335 MB served from the source cache instead of the origin |

Every reader of a source fetched for itself, opened its own `URLSession` (so its own connection), and
kept what it fetched to itself. The subtitle prefetch demuxed the whole film to find its packets,
because libavformat reads every Matroska block off the wire before honouring a discard. The indexed
subtitle fill paid a 64 KB read-ahead window for each 568-byte cue, on twelve cloned readers.

## The target shape

Pull, not push. On tvOS 27.2 the consumer of almost everything is AVPlayer reading HLS, and it decides
when it wants each thing: video and audio segments (its forward buffer), subtitle renditions (AVKit
reads them about four minutes ahead), the forced rendition, the I-frame playlist for scrubbing. The
engine should answer each request by reading exactly the bytes it needs, once, and not guess a lead.

1. **One byte layer per source.** One `URLSession`, so one HTTP/3 connection per origin; one byte store
   under it; nothing above it talks to the network.
2. **One index per source, parsed once.** The container's own map (Matroska Cues, MP4 `moov`, an index
   the pump records for MPEG-TS), shared by seeking, keyframes and subtitle blocks.
3. **Every output a native HLS rendition, served on request.** Subtitle WebVTT segments and the I-frame
   playlist read exactly their bytes from the index when AVPlayer asks for them.
4. **A non-native island only where the platform has a gap.** PGS is not a format AVFoundation renders
   in HLS as far as is known, so it is OCR'd to text or drawn as an overlay, and the overlay pulls too.

## Layer 1: one byte layer per source (built)

### What it is

| Piece | File | What it does |
|---|---|---|
| `EngineHTTP.session` | `Network/EngineHTTP.swift` | The one URLSession for every engine fetch: the pump, chunk and detour reads, probes, the tail prefetch, the streaming GET, the prewarm, the indexed subtitle reader, the disc reader, both HLS ingest readers, the audio tap, the carriage probe, the remote subtitle proxy, live subtitle renditions, the origin relay. The idle timeout rides each request; the resource ceiling is a per-task deadline (`armResourceDeadline`, reported as `URLError(.timedOut)` by `BoundedFetch`); teardown ends an owner's own tasks (`EngineHTTPRequests`). One serial user-initiated callback queue. |
| `SourceByteCache` | `Demuxer/SourceByteCache.swift` | Every network delivery is kept, per source, in a sparse file in tmp. LRU by 4 MB block with `F_PUNCHHOLE`, budgeted through `RetentionClaims` beside the segment caches (up to 4 GiB or a quarter of free space), sized again every 256 MB written (`reviewBudget`, `RetentionClaims.Claim.resize`). Read-your-writes: a stored range is servable at once, from memory until its write lands. The kernel's page cache is the memory tier. Nothing is dropped: past 64 MB of pending writes, readers hold their next request until the disk catches up (`waitForWriteRoom`). Also holds per source the body its bytes are from and the resolved redirect target, and tells the index registry when a source goes (`observeReleases`). |
| `SourceVersion` | `Demuxer/ByteSpanSet.swift` | Which body a response came from: its total size, `ETag` and `Last-Modified`, compared only where both sides state a field. Every response whose bytes are kept is noted (`noteVersion`): another body drops what was held. Every delivery is stored with its response's version, and one from another body than the recorded one is not kept. |
| `SourceCacheKey` | `Demuxer/ByteSpanSet.swift` | What makes bytes shareable: the credential-free URL plus a SHA-256 of the credentials and request headers. Readers of one session share; another user, token or header set never does (the #551 rule). |
| `SourceByteLedger` | `Demuxer/SourceByteLedger.swift` | Per source and per reader: fetched, unique, duplicate, discarded, served from cache. One line per reader close when the books changed, and a final line per source. |
| `RangeReadableIOReader` | `IO/IOReader.swift` | Exact range reads, concurrent, no cursor. `HTTPDiscIOReader` serves held bytes and fetches exactly the gaps; one reader serves all twelve indexed-subtitle lanes. |

How `AVIOReader` uses the cache:

- A read outside the live window is served from the cache before any network path, outside `winCond`.
- The pump plans its ranges around what is held: a held span replays as a range of its own (`CachedSpanTransfer`, the third `PersistentTransfer` shape), and a network range stops where a held span worth a split begins (one round trip of the link's bytes, `heldSpanWorthASplit`).
- An open adopts the cached size and redirect target, so a warm head or another reader's head replays from disk and the open owes the origin nothing (#551).
- A detour miss fetches its 4 MB block on the side as before (#69); the cache keeps it.
- The tail prefetch is skipped when the tail is held, and a fetched tail is stored before the waiting read is woken.
- Every reader has a cache: the shared one at the engine's construction sites, a scoped one of its own otherwise (`SourceByteCache.scoped`), so there is one read path.

A warm (`AetherEngine.prewarm`) is the cache filled ahead of the load: head, tail, size and redirect
target, under the request the load will make. `isPrewarmed` asks the cache; `discardPrewarmedSources`
releases what no session is reading.

### Guarantees and the tests that hold them

| Guarantee | Tests |
|---|---|
| A byte any reader fetched is served to every later reader of the same request, from the cache, byte for byte | `SourceByteCacheTests` (second reader in both read modes, pump split around a held span, read-your-writes, exact range reads) |
| Nothing crosses between tokens, users or header sets; a changed size drops what was held | `SourceByteCacheTests` |
| One pool: repeated opens leave at most one pooled connection (audit NET-110) | `RemoteDiscSessionReleaseTests` |
| The shipped pool does not park a third open-ended request (#450) and calls back at playback priority | `Issue450ConcurrentReaderCeilingTests`, `PlaybackNetworkPriorityTests` |
| A warm open costs no request inside the warm, fetches from the frontier, adopts size and redirect, is shared by a second open | `SourcePrewarmAdoptionTests`, `SourcePrewarmFetcherTests`, `Issue551RedirectHandoffTests`, `Issue647DiscReaderPrewarmTests` |
| A return to the head, before or after the index pass or a move away, costs no request (#281, AE#585) | `Issue281ColdStartRoundTripTests`, `Issue585IndexPassKeepsTheHeadTests` |
| A backward read into unfetched bytes keeps the detour and restart policies (#69, AE#782, DMX-105) | `Issue782RestartReanchorTests`, `DetourOriginTicketTests` |
| The books are right | `SourceByteLedgerTests` |
| Another body (`ETag`, `Last-Modified`, size) drops what was held, and a stale delivery is not kept; the pump does not replay a held span of a replaced file; a range reader drops the old body at its first response | `SourceByteCacheTests` (versions, `pumpDoesNotReplayAReplacedFile`, `rangeReaderDropsAReplacedFile`) |
| Writes past the pending bound are all kept, and a request waits for the disk; the budget is sized again as the cache writes and evicts down to it | `SourceByteCacheTests`, `Issue687RetentionClaimsTests.resizeCountsOwnWritesBack` |

### On device

- `[AVIOReader] origin transport: h3 over IPv6 at https://jellyfin.home.freehomenext.com` (no flag needed: the server's HTTPS DNS record advertises `alpn="h2,h3"`; a fresh ephemeral session's first request is h3).
- `[SourceLedger] ... duplicate 0.0 MB (0.0%), served from cache 334.9 MB` after the cache landed.
- The single byte store (`a7a725e8`) is not yet measured on device. To do: the same title with subtitles,
  scrub back a few times, and compare `[Demuxer] open timings`, slow-read lines, reconnects around the
  scrubs, `[SourceLedger]` and `memprobe` RSS against the 06:15 session.

### Not yet ideal, and the steps

1. **Remote HLS is outside the cache and the ledger.** On the remote-HLS bypass AVPlayer fetches
   segments itself, and the audio tap (`AudioTapHLSFetcher`) fetches the same playlist and segments
   again (read from the code, not yet measured: the ledger cannot see it, which is the first step). The ingest readers, the relay and the carriage probe fetch whole segments by URL, which the
   ledger does not book (it books byte ranges of one source).
   - Book segment fetches in the ledger, keyed per segment URL, so the duplicate is measured.
   - Give the HLS fetchers whole-body entries in the source cache, keyed per segment URL, so the tap,
     the relay and the ingest read a segment once.
   - Where the tap duplicates AVPlayer on the bypass, have it read what AVPlayer was served (through
     the relay, which already sits between them when trust requires it) rather than fetch again.
2. **The cache trusts size and headers, not the body's version. Done.** A source records the body its
   bytes are from (`SourceVersion`). Every response whose bytes are kept is noted where it arrives:
   the pump's connection response, the size probes and the HEAD fallback, the detour, chunk, tail and
   streaming fetches, the range reader's GETs, the prewarm. A response stating another `ETag`,
   `Last-Modified` or size drops what was held (and the source's index with it), and a delivery
   from another body than the recorded one (a connection answered before the replacement) is not
   kept. The #551 adoption check compares the whole version, not just the size.
   - Left: an open that adopts the cache's bytes asks the origin nothing, so it reads what the cache
     holds until its first network response (the pump's first range past the held head, a range
     reader's first gap). A replacement is caught there, after the old head was read. Inside the
     five-minute grace only; closing it would cost the round trip the adoption exists to save.
3. **Small held spans are fetched through.** The pump splits a range around a held span only when
   the span is worth a split: `AVIOReader.heldSpanWorthASplit(bytesPerSecond:firstDataMs:)`, the bytes
   the link moves in one round trip (64 KB floor; 256 KB until a rate is measured). A span below that
   is cheaper to fetch through than to wait a round trip for, so subtitle blocks the index read ahead
   of the pump can still be fetched again. Tiny, and now the right trade by the link's own numbers.
   - Layer 3 removes the reads ahead of the pump that leave these spans.
4. **Writes can be dropped. Done.** A store now never drops and never blocks. Past 64 MB of pending
   writes, a reader waits before it sends its next request (`waitForWriteRoom`: the pump's connection
   start, every short fetch through `syncRequest`, each range GET of the range reader), so a link
   faster than the disk is slowed to the disk. The wait is not in the delivery callback, which has
   no flow control to push back with (#174: CFNetwork keeps reading into its own buffers), so the
   queue can exceed the bound by what is already in flight. The write queue runs at the readers'
   priority: utility I/O is throttled behind theirs, which is how it could fall behind at all.
   `[SourceCache] ... released: ..., requests waited N ms for the disk` says if it ever happens.
   - Left: the prewarm does not wait (async, a few bounded ranges).
5. **The budget is sized once. Done.** The shared claim is sized again every 256 MB the cache writes,
   from the free space then plus what the cache has written (the measurement no longer counts it)
   less what other claims have yet to write, and the cache evicts down to it. Segment caches still
   size once per session, which is their lifetime.
6. **Fixed fetch sizes where exact would do. Done.** `IO/ReadAhead.swift` sizes the chunk path to the
   read (a floor, doubling on sequential continuation up to a ceiling), and a detour fetches from the
   read offset starting at 256 KB and growing to 4 MB (`ExactFetchSizeTests`). Layer 3 replaces the
   I-frame reads outright.
7. **The forward-prefetch runaway was never root-caused.** 31.7 GB in seven minutes on the walk path,
   far beyond any lead. On indexed Matroska the index path replaced the walk, so it no longer happens
   there, but the walk remains for other containers.
   - Reproduce on a non-Matroska source with the ledger and `SubtitlePrefetchTelemetry` (restarts,
     re-anchors, parks) and fix the cause; layer 3 then retires the walk.
8. **Intentional, recorded here so they are not mistaken for leftovers:** the system-trust probe keeps
   its own session (it must not ride a connection the host's evaluator accepted); the HTTP/1.1 stream
   transports keep theirs (`HeldSourceConnection`, `PersistentHTTP1Transport`); Sodalite's own sessions
   stay separate (they carry nothing playback depends on, and merging would cost the app's HTTP cache
   and its 304 revalidation, Sodalite#12).

## Layer 2: one index per source (built for Matroska and MP4)

### What it is

| Piece | File | What it does |
|---|---|---|
| `SourceIndex` | `Demuxer/SourceIndex.swift` | The one shape every consumer reads: subtitle tracks, each track's frames (time, duration, where), `readFrame` returning the packet libavformat would hand over (for Matroska: stripped header restored, zlib inflated, WebVTT split into text and settings), the codecs for which that holds (`packetCodecs`), and the stream-to-track pairing. |
| `MatroskaCueIndex` | `Demuxer/MatroskaCueIndex.swift` | Matroska's Cues, parsed off the source. Also the video keyframes, read as packets (`readKeyframe`): where the Cues place the block, or, for a cue without `CueRelativePosition`, the block in its cluster whose time (cluster timestamp plus block offset) is the cue's. |
| `MP4SampleIndex` | `Demuxer/MP4SampleIndex.swift` | An MP4's sample tables, not parsed again: the entries libavformat built at open (`Demuxer.sampleTable`, edit lists applied), which are what `av_read_frame` reads its packets from. Subtitles: mov_text only; a fragmented file's (an `mvex` in the `moov`) are never whole, and a track with an entry the edit list marks to discard is not trusted. Video keyframes: each keyframe entry's sample (position and size), fragmented files included, since every keyframe a plan lists is an entry the demuxer had. |
| `SourceIndexRegistry` | `Demuxer/SourceIndexRegistry.swift` | One index per source and size, for whichever container the demuxer opened (`index(of:headers:demuxer:through:)`). Racing callers share the one read; later callers get the result. An uncovered container and a file without an index are kept answers; a read that broke off (including an unreadable head) is not, so the next consumer retries. The key is derived from the request and the reader's own size, so two consumers cannot name a source differently. |
| `ParseToken` | same | Both index readers require one and only the registry can make it, so a second read cannot be added by accident. The parser's unit tests use a debug-only token; a release build pins that no production code does. |
| Index consumers | `AetherEngine+SourceIndex.swift` | One exact reader factory (`indexedSourceReader`, with a shorter request budget for a consumer a viewer waits on) and one opener over it for files and remote sources (`indexReader`), one subtitle stream listing (`indexedSubtitleStreams`), one video track listing (`indexedVideoTracks`). |

Consumers today, all container-agnostic: the I-frame rendition and the compositor preview
(`IFrameKeyframeReader`, layer 3 step 4) and the session's subtitle source (`SubtitleSource`, layer 3
step 1), which reads every stream the index lists in full from it (`SubtitleForwardPrefetcher.IndexSource`)
and fills those streams' text renditions whole. On an MP4 the walk it replaces delivered every video
keyframe (its pacing stream sits at `AVDISCARD_NONKEY`, and `mov_read_packet` reads a keyframe's bytes
before handing it over).

### Guarantees and the tests that hold them

| Guarantee | Tests |
|---|---|
| Twelve racing consumers, one parse; a later consumer, no parse; source and size name the index; an index goes with its source (grace, idle release, another body) and is kept only while the cache holds the source | `SourceIndexRegistryTests` |
| The index read stores the same packets the walk would, in one time order, re-anchors in place, ends a dropped connection as a read failure, and takes each stream it can stand in for | `SubtitleIndexPrefetchTests` |
| An MP4 sample read from the index is the packet `av_read_frame` hands over (bytes, time, duration), an empty edit included; the prefetch from it stores what its walk stores; an edit-list cut or a fragmented file's subtitles are not trusted, and a fragmented file's keyframes read | `MP4SampleIndexTests` (fixtures made by ffmpeg and MP4Box, embedded) |
| A keyframe read from the index (Matroska with and without `CueRelativePosition`, MP4) or by the demuxer route (FLV) is the packet `av_read_frame` hands over | `IFrameKeyframeReaderTests` (fixtures made by ffmpeg, embedded) |
| The walk's contract is unchanged through the one loop | `Issue151SubtitleForwardPrefetchTests`, `Issue230PrefetchReadPositionParkTests`, `Issue231PrefetchRestartTests`, `Issue234SideReaderSeekAnchorTests`, `Issue240SideReaderLinkPriorityTests` |

### Not yet ideal, and the steps

1. **Matroska and MP4 only.** MP4 is done: `MP4SampleIndex` behind the same `SourceIndex`, every
   consumer moved onto it. MPEG-TS (and so every Blu-ray remux in `.m2ts`) has no index at all, and
   a recorded one was looked at and not built (see the decisions below): the TS walk is cheap, and
   what a recording would serve (back-seeks, re-reads) libavformat's own index entries largely cover.
   - Keyframes are on `SourceIndex` for both (`coversKeyframes`, `readKeyframe`), addressed by the
     position libavformat's index gives the segment plan (`Demuxer.indexedKeyframeEntries`), so the
     plan and the reads name a keyframe the same way.
2. **The index is named for subtitles and exposes only them. Done.** It is `MatroskaCueIndex`
   (`Demuxer/MatroskaCueIndex.swift`), and it exposes `videoTracks`, `keyframes(track:)` and
   `byteOffset(of:)` for the I-frame playlist and seeking (`MatroskaCueIndexTests.videoKeyframes`).
3. **WebVTT kept the whole prefetch on the walk. Done.** A Matroska WebVTT block carries its
   identifier, settings and text in the block itself; `MatroskaCueIndex.webVTTCue` splits it the way
   `matroska_parse_webvtt` does, and both the prefetch and the indexed fill store the text with the
   settings beside it (#233; `webVTTSplitMatchesTheDemuxer`, `webVTTFromTheIndex`). zlib-compressed
   frames are inflated by the index reader as libavformat inflates them (`ZlibBlock`), so neither is
   an exception any more. What still sends a stream to the walk (per stream, since layer 3 step 1): a
   Matroska file with incomplete or no Cues, a bzlib/lzo or encrypted track, a codec outside the
   index's `packetCodecs` (DVD and DVB bitmaps, whose packet parity with FFmpeg is unverified; in an
   MP4 anything but mov_text), a fragmented MP4 or an MP4 track its edit list cuts, and every MPEG-TS
   source (step 1).
4. **The index outlives its source. Done.** The registry keeps an index while the source cache holds
   its source at that size: while a reader has it open, through the grace after the last close (so a
   reload or a track switch finds it), and no longer once the source is let go
   (`SourceByteCache.observeReleases`: the grace, `releaseIdleSources`, another body). The cap of
   eight is gone. A source the cache does not hold (a local file, a host's own reader) keeps its
   index only while it is read, for the consumers racing for it; such a source is read once per
   load, from disk.
5. **"Parsed once" holds for the engine's parser, not for libavformat.** Every side demuxer (the
   I-frame reader's demuxer route, the subtitle source's walk, the still extractor, the Atmos
   confirmation and the Dolby Vision audit) parses the container header and its cues again: no
   network now, but CPU and memory each time. A session whose subtitle streams the index lists in full
   opens no subtitle demuxer at all.
   - What remains (the Atmos confirmation, the DV audit) should read their few packets through the
     index too.
6. **An indexed text stream's frames are read twice.** The source fills its rendition whole at load,
   and its loop reads the same frames again into the packet store for the overlay as the lead asks. The
   second read is a cache hit, but it is a second parse.
   - Layer 3 step 3 (the overlay pulls) makes the packet store a cache of what was pulled; the rendition
     fill can then hand its frames over.

## MPEG-TS: no index, and programs that change (built)

A transport stream has no index of its own, and a program's stream table (its PMT) can change in the
middle of it: an ad on its own PIDs, a recording crossing a programme boundary, an encoder restart.

### What it is

| Piece | File | What it does |
|---|---|---|
| The cue prewarm only where a seek loads an index | `HLSVideoEngine+SegmentPlanning.swift` (`cuePrewarmMayRun`), `Demuxer.loadsIndexOnFirstSeek` | The mid-file seek that makes libavformat read Matroska's Cues ran on every container. On mpegts and mpegps (every disc) it was a whole-file timestamp search, mostly network reads into unwatched parts of the file, whose only product was probe entries flagged keyframe whatever they are (`mpegts_get_dts`). One rule now gates it for the pump and the subtitle source's walk. |
| The uniform plan anchored on the first IRAP | `measureKeyframeSpacing`, `uniformPlanAnchor` | Segment 0 sits on the content's first random-access point on the plan's own (decode) axis, read from the head of the source. It sat on the index's first entry (on TS, whatever packet was at byte 0) or on `start_time`, a presentation time a composition offset above the IRAP's decode time, which put the IRAP below segment 0 (the AE#561 failure). Matroska's untrusted-index fallback had the same mismatch with its Cues. |
| Keyframes kept for seeks | `Demuxer.recordKeyframeLocked` | Each video keyframe read on a seekable, non-disc mpegts/mpegps source goes into libavformat's own index (position, decode time), within `max_index_size`, so `ff_seek_frame_binary` bounds a seek back into what was read instead of searching the file. |
| Program succession | `Demuxer/ProgramSuccession.swift`, `Demuxer` | A role (program, media type, ordinal in PMT order) is taken from the first PMT at the open. A new PID that holds a role's place, once the role's stream has left the program, is read under the role's stream index; each such packet says the stream it came from (`Demuxer.sourceStream(of:)`, in `AVPacket.opaque`). An added track is never folded in. The old PID's last frames, which libavformat's parser lets go only at its next frame or at EOF, are dropped by position. Successors are nobody's new track in the track lists. |
| The producer across a change | `HLSSegmentProducer` (`sourceChange`, `noteProgramChange`) | Each pump compares a packet's source with what its roles are set up for. Live: an ad gets a versioned init on its first keyframe with in-band SPS/PPS (the programme's DV/colour overrides dropped, P7 off); the programme coming back opens on any keyframe with the open's own init and gets them back. VOD plays on through a same-codec change; a video or audio codec change ends the epoch for the software path. Live audio of another codec is left out of the init until the role is back. |
| The software path across a change | `SoftwarePlaybackHost.roleSources`, `SoftwareSourceWatch` | `load` positions first and opens decoders for the stream each role is on there. Where packets are consumed (the read-ahead spool and the live ring carry the source), the same codec on a new stream decodes on; another codec is held out and the session is rebuilt once at the playhead (`reloadAtCurrentPosition`, `programCodecRebuildLimit`). |

### Guarantees and the tests that hold them

| Guarantee | Tests |
|---|---|
| A prewarm runs only on Matroska; the uniform plan anchors on the first IRAP's decode time from a clean or a mid-GOP start; the keyframes read go into libavformat's index, and a seek back reads nothing (631 KB cold on the test stream) | `TransportStreamSeekIndexTests`, `Issue550CuePrewarmPolicyTests` |
| A new video or audio PID takes its role, every frame in order on the chosen stream; an added track takes none; an ad and the programme's return; warm and cold seeks; discard inheritance; roles by type and order | `ProgramSuccessionTests` |
| Live ad and return as three inits; VOD plays through a same-codec boundary; VOD video and audio codec changes escalate, also for a pump started past the change; live audio on a new PID | `ProgramChangeProducerTests` |
| The software watch's verdicts; the source through the spool envelope and the stored form; the decoders' streams before and after a cold seek past an H.264 to HEVC change | `SoftwareProgramChangeTests` |

`TransportStreamFixture` writes these streams cell by cell around real H.264, HEVC and AC-3, so
libavformat's own parsers and PMT handling are what the tests run against.

### Not yet ideal, and the steps

1. **Live audio of another codec is silent for the length of the change.** The fMP4 init describes one
   audio codec, so the pump leaves the new one out until the role is back.
   - A versioned init for audio, as video has, if a real stream ever needs it.
2. **A same-codec change on the software path relies on the decoder.** libavcodec reads the new
   stream's in-band parameters; a VideoToolbox session built from the open's `hvcC` may not take a
   successor whose parameter sets differ.
   - Rebuild on any source change for a hardware decoder, if the device shows it.
3. **The old PID's last frame or two are lost at a change.** libavformat's parser holds them until the
   next frame on that PID or the end of the stream; they arrive after the new PID's frames and are
   dropped as leftovers.
4. **libavformat's program list is not always exact.** After `find_stream_info`'s duration estimate it
   can name the old and the new streams together, and after a seek it is corrected only at the next
   PMT cell. A new stream judged to take no role is therefore judged again when the programs change.

## Layer 3: every output on request (steps 1 to 5 built)

In order, each step replacing a reader rather than adding one:

1. **One subtitle source per session. Built.** `SubtitleSource` (`Subtitles/SubtitleSource.swift`) is
   the session's one reader of its embedded subtitle streams; the forward prefetcher, the native side
   readers and the indexed fill are gone as separate readers.
   - **Routes, once per session, per stream.** The index (through `SourceIndexRegistry`, asked with the
     session's own demuxer) takes each stream it lists in full in a codec whose frame is its packet
     (`IndexSource.plan`); every other stream is walked. Files and host sources use the index too.
   - **Demand.** The overlay drainer (its window plus #362's margin), the OCR worker (270 s, or as far
     as AVKit asks its rendition) and a native text rendition (selected, or the forced one the player
     asked for: 300 s, or as far as AVKit asks) each state a lead; the loop reads to the furthest and
     asks again at every park, so a raised lead needs no new session. Nobody asking stops the reading,
     judged after the change that withdrew the last demand, so a re-arm moves it instead of reopening it.
   - **One loop.** The index and the walk are read as one (`CompositeSource`, each step from whichever
     is behind), so there is one park, one in-place re-anchor (#240), one restart budget (#231) and one
     coverage frontier (#416). The walk is one side demuxer for every walked stream, opened only when a
     walked stream is demanded, after any producer restart (#93), yielding the link (#240); it harvests
     into the packet store and decodes each text stream into its cue store as it reads.
   - **Renditions.** An indexed text stream's rendition is filled whole at load and marked complete; a
     walked one is filled by the walk as it reads. Every text cue, the pump tap's included, is decoded
     by a decoder from the session's one factory (`makeOverlayDecoder`, the session's markup and
     teletext options), so a line cannot be stored once with ASS markup and once without.
   - **OCR.** One worker for both routes, reading the packet store its demand keeps ahead. The forced
     rendition is recognized the same way, forced lines only, as far ahead as its demand.
2. **Native subtitles, served as AVKit asks for them. Built.** The engine behaves as a VOD origin whose
   renditions are complete files, and AVFoundation's legible selection is the one record of what shows.
   Apple's HLS authoring specification and our device logs set the constraints: subtitles reach AVKit as
   WebVTT (or text-profile IMSC1) only, so no image subtitles (4.2, 5.2); a served segment is final, an
   empty one meaning "no subtitles here" (RFC 8216bis 3.1.4) and kept by AVKit; AVKit fetches a rendition
   about four minutes ahead of the video, and the whole forward window in one burst at selection; it gives
   up on a segment after about 1.75 s, and a hold that long slips frames. So a rendition has to be ready
   ahead of AVKit's fetching, and every request is answered at once from what is determined.
   - **Who draws.** AVKit selects and draws every text track: WebVTT passed through, and SRT, mov_text,
     teletext and TTML converted with italic, bold, underline and `\an` alignment (cue settings).
     CEA-608/708 stay in-band captions. The overlay draws what AVKit cannot: ASS with its styling
     (libass) and bitmap tracks (PGS, DVB, VobSub), forced bitmap lines included; their WebVTT
     renditions (ASS reduced to emphasis and alignment, bitmaps recognized by OCR) serve PiP, AirPlay
     and external displays.
   - **Selection.** The engine follows AVFoundation's legible selection, whether the viewer, the host or
     tvOS made it (forced subtitles with subtitles off, SDH under Always On, automatic captions), and a
     host pick is a selection of the matching option. The deselect pin is gone. A text track's
     rendition is drawn by AVKit unsuppressed; for an overlay-drawn track the engine's legible output
     suppresses AVKit (`suppressesPlayerRendering`), the line cleared first so none freezes, and the
     drainer feeds the overlay. While the rendition is the display (`setNativeSubtitleRendering(true)`:
     PiP, AirPlay, an external display) suppression is lifted. Device-verified 2026-10-25 (`SEQ=subs`).
   - **Declarations.** SDH tracks carry the accessibility `CHARACTERISTICS` with `AUTOSELECT=YES` (4.5,
     4.6); every forced track `FORCED=YES` with `AUTOSELECT=YES` (5.11).
   - **Delay.** The subtitle delay a session starts with is served: every cue time is written with it,
     from the first fetch, so AVKit draws it natively. A delay changed during the session moves the text
     track to the overlay, which applies it at once; when the rendition becomes the display with a
     served delay that differs, the session is rebuilt in place (`reloadAtCurrentPosition`) so the new
     item serves the current one, and AVKit draws natively again from then on.
   - **Serving.** AVKit's fetch of a rendition's playlist starts its reading and every segment request
     moves its frontier: an indexed text rendition is complete at load; an indexed forced bitmap
     rendition is complete at load (the display sets' composition headers find the forced ones, and
     only those are recognized); a full bitmap rendition is recognized by the OCR worker ahead of
     AVKit's frontier (its lead follows AVKit's requests); a walked stream is read ahead of the frontier,
     and keeps the selection pre-fill and the empty-rendition gate, since a walk cannot answer a burst
     four minutes ahead within a second. A host pick starts the overlay at once and then selects the
     option, so the pre-fill's wait shows the overlay's lines rather than none. The loopback's
     whole-program `.vtt` (dead) is gone; the remote-HLS bypass's injected renditions keep theirs.
   - **Served text.** Italic, bold and underline from SRT tags, ASS overrides (a styled ASS track's
     event text, overrides intact) and rich-text runs; `\an` and `\pos` as cue settings
     (`WebVTTCueSettings.settings(for:)`, the parser's inverse). Colour and font are left to the
     viewer's caption style and the host's text style rules.
   - **Follow-ups, from the tvOS 27.2 SDK, rfc8216bis-22 and WWDC26 session 256 (not built).**
     - *OCR renditions are machine-generated.* rfc8216bis-22 lets any rendition carry
       `public.machine-generated` "to indicate the Rendition was authored or translated
       programmatically"; the SDK has `AVMediaCharacteristicMachineGenerated` on tvOS 26. A bitmap
       track's rendition (recognized by OCR, forced or full) declares it in `CHARACTERISTICS`, beside
       the accessibility characteristics an SDH one already carries. A text track's rendition (converted,
       not generated) and an ASS track's (reduced, not generated) do not.
     - *tvOS generates subtitles of its own.* tvOS 27 transcribes English audio into English
       subtitles on device, with no code, for HLS (live included) and files (session 256), and
       `-[AVPlayerItem selectableMediaSelectionOptionsInMediaSelectionGroup:]` (tvOS 27) exists because
       such an option "may require that the source audio option is currently selected". Today
       `followNativeSubtitleSelection` matches the selected option to a track by its position in the
       group and its language (`nativeOrdinal(forOptionAt:...)`), so a generated English option can be
       taken for the source's English track or shift the positions of the others; and a generated option
       selected while the legible output suppresses goes through the "no option" branch, which keeps the
       suppression and may hide tvOS's own lines. The cutover: options are matched to the engine's
       renditions by identity (the rendition's own `NAME`/URI the engine declared, through the option's
       `propertyList`/display name, not by position), an option that matches none of them and has
       `.machineGenerated` is tvOS's own (drawn by AVKit: suppression lifted, the overlay fed nothing,
       `primarySubtitleDrawnByAVKit` true), and the host sees it as a selection like any other. The
       machine-generated characteristic on our OCR renditions (above) is then never the deciding signal,
       since those match by identity first.
     - *Probe before building the generated-option path:* a `subs` arm (`case=generated`) on a fixture
       with English speech and no English subtitles: is a generated option in the group, how is it named
       and characterised, does AVFoundation select it by itself (subtitles Always On, and the forcedOnly
       default), and does a suppressing legible output hide it.
     - *Caption style preview (tvOS 26.4).* `-[AVPlayerLayer setCaptionPreviewProfileID:position:text:]`
       and `stopShowingCaptionPreview` show a style preview and hide AVKit's own lines while it shows;
       the overlay is not AVKit's, so a host that offers the preview hides the overlay for its duration
       (Sodalite's subtitle style menu; nothing in the engine).
     - *Authoring 5.8* (a language's regular rendition also contains its forced lines) holds whenever
       the source's regular track carries them, which is the authored norm; nothing is synthesised.
3. **The PGS overlay pulls. Built.** The drainer and the OCR worker ask the subtitle source for their
   windows around the playhead; for an indexed stream the packet store becomes a cache of what was
   pulled, not a buffer filled ahead.
   - **Why the engine still draws.** tvOS 27.2 offers no native route for a bitmap subtitle:
     `AVPlayerItemRenderedLegibleOutput` and `AVRenderedCaptionImage` are unavailable on tvOS,
     `AVCaptionRenderer` there has only its style preview, the new `AVPlayerItemSampleBufferOutput`
     delivers "only ... decoded PCM audio" of HLS items, and HLS carries WebVTT and IMSC1's text
     profile only (authoring 4.2, 5.2; AirPlay 2 TVs WebVTT only). So bitmaps stay the overlay's, read
     the way Apple's own pull output is meant to be used: far ahead of the play time, paced against
     the item's timebase, paused once near-term playback is covered.
   - **The pull.** `SubtitleSource.pull(stream, from:through:)` reads the index's blocks in that span
     on the fill's parallel lanes (`readFrames`), through the exact range reader over the shared source
     cache: each frame is a ranged read of its own few bytes, kept by the cache as a positional read
     (`Retention.always`, `d03c96e7`), so a pull asked again after the store evicted it is served from
     disk. It does not lean on the pump's bytes, which a lone reader's stream no longer leaves in the
     cache away from the source's ends; it stores the frames and records the span as pulled for that
     stream.
   - **No session-long reader of the source.** The cache keeps a streamed delivery whenever another
     reader of the source is open (`openReaders < 2`), so the index reader the subtitle source holds
     for the session (`Resolution.root`, `subindex`) turns the pump's whole film back into flash
     writes. Built: the index is parsed through that reader and it is closed; every read of frames
     (the fill, the forced lines, a pull) opens its lanes for the read and closes them after
     (`FrameReaders.url`). A host's own reader, outside the cache, is held as the one clone; one that can
     neither read exact ranges nor hand out independent readers cannot be pulled, so its streams are all
     walked. And the cache counts only the readers that stream a source (`readerOpened(_:streams:)`:
     `AVIOReader` streams, `HTTPDiscIOReader` asks by position) when it decides whether a streamed
     delivery is kept; every reader still holds the source open. So a pull, or any reader of exact
     ranges, beside the pump keeps nothing of its stream but the ends (`SourceByteCacheTests`, the pump
     beside a reader of exact ranges). Pulls of one
     stream are coalesced (a span already pulled or in flight is not asked again) and a newer landing
     cancels an older one's unread remainder.
   - **The drainer asks for its own window, nothing more.** Each tick it pulls `[playhead - backscan,
     playhead + lead]` and decodes only as far as the pulls reach (`pulledReach`), so a stretch not yet
     pulled waits for its pull rather than reading as silence. A pull reads 30 s past what it was asked
     (`pullAheadSeconds`), so the window moving with the playhead costs a read about every half minute;
     a window of PGS is a few dozen frames over twelve lanes, so a landing costs a few round trips. A
     frame that fails to read three times running is passed over. The overlay's 15 s margin past the
     window is the walk's only: it existed so the set at the window's edge had its clear stored, and an
     indexed set's end comes from the index (below).
   - **Landings are signalled natively. Built.** On the HLS route every item the host attaches
     (`NativeAVPlayerHost.onDidAttachItem`, so the in-place swaps' items too, which used to miss step 2's
     legible output and selection observer) is observed for `AVPlayerItemTimeJumpedNotification`, and
     each one is a landing (`subtitleLanded`): the drain and the OCR worker reset on it exactly once
     (`SubtitleRepositioning.signalled`, a landing count on the cursor), stand at the landing until the
     picture reports a time of its own (`sourceTime` follows the presented frame, #49, which stays on the
     old one while AVPlayer buffers towards the target, #123), and #93's rendition re-anchor is checked
     on it. Measured on macOS 27 with the `subs` fixture: the notification arrives for every seek, paused
     ones included, on the main queue with the seek's completion and the item time already at the
     target, and for each step of a reverse scan (about four a second); the legible output's
     `outputSequenceWasFlushed:` arrives with it, but only on an item with legible media, so the
     notification is the one used. The other way the source-axis playhead moves is the axis moving under
     it: since `b85e7ed0` each VOD run's axis is read in band, and the landing segment's clock arrives at
     or after the landing it corrects (by 9 s on the AE#418 chain); a live program boundary rebases
     source PTS. `setPresentationAxis`, which every change passes, counts such a move as a landing at
     the corrected position. The jump threshold (#271) and #93's
     60 s rendered-time rule are gone from it; the threshold stays the software route's, which has no
     AVPlayer. The landing pull (above) will start here.
   - **Pacing reads the clock playback runs on. Built.** The walk's lead is judged against
     `SourcePlayheadClock`, read where it parks, off the main actor: on the native route
     `AVPlayerItem.timebase` folded onto the source axis by the seam shift the engine states as it folds
     `sourceTime` (and wherever the axis moves), so the walk follows a landing as soon as the timebase
     jumps rather than when the picture gets there; on the software route the synchronizer's source-axis
     timebase (`SoftwarePlaybackHost.presentationTimebases`). While no clock runs (a load before its item
     attaches) nothing plays, and the walk waits; a session that goes away closes its source, which
     cancels it, so a missing clock is no longer read as the engine having gone.
   - **What the index makes exact.** A bitmap set's end is the next block's time in the index, known
     without reading it, so `firstPTS(after:)` and its derivation horizon (#362 round 2) are the walk's
     only; a pulled span has no holes, so the harvest-gap hold (#362) is the walk's only; a pulled span
     is read by construction, so the landing-ground check (#416) is the walk's only.
   - **One writer per route.** Once the routes settle, the store passes over a harvest of an indexed
     stream (`setPulledStreams`), whichever host's pump or tap it comes from, and the pump's decode tap
     (`subtitleTapRoutes`, Sodalite#32, which decoded every text stream although an indexed stream's
     rendition is complete at load) leaves the indexed streams (`excludeFromSubtitleTap`). Until the routes
     settle every stream is drained as walked, from the pump's harvest. A consumer's demand names its
     streams, and the walk runs only while one of them is walked. `IndexSource`'s forward stepping and `CompositeSource` are
     deleted; the loop is the walk alone and runs only while a walked stream is demanded. A walked
     stream keeps the walk and the pump, with #362 and #416 as they are; live, which has no source at
     all, keeps the pump alone.
   - **The store as a cache.** An indexed stream's packets can be pulled again, so they evict by
     distance from the playhead, not oldest first, and a seek back past what was evicted is a pull
     (#125's deferred case closes). The per-stream and aggregate caps (#125, #166) then bound the walked
     streams only.
   - **The rendition fill hands over its frames.** `fillIndexedRenditions` already reads every frame
     of an indexed text stream at load; it stores them as pulled for the whole stream, so the overlay
     never reads a text frame twice (layer 2, item 6).
   - **OCR pulls the same way.** The OCR worker pulls its window, as far ahead as AVKit's requests
     move it, so a full bitmap rendition's recognition is bounded by its CPU budget, not by what the
     store holds (step 2's decision on full bitmap tracks is reopened once this is built).
   - **Tests.** `Issue362HarvestHoleTests`, `Issue362AuthoredClearTests` and `Issue416LandingGroundTests`
     keep the walked route; their indexed cases become pull tests (a landing decodes from a pulled span,
     an indexed set ends at the index's next block, a seek back past an evicted span pulls it again).
     `Issue125`/`Issue166` keep the walked streams; `SubtitleIndexPrefetchTests` become pull tests.
   - **Logs.** `[SubtitleSource] pulled stream N a-b s (k frames, from cache m)`, the narrowed taps
     (`[HLSVideoEngine] subtitle pump tap armed for streams [...]` naming the walked ones), and no
     `subwalk` reader in `[SourceLedger]` for a source whose streams are all indexed.
4. **The I-frame playlist from the index, and dense stills without one. Built.** `IFrameKeyframeReader`
   (`Video/IFrameKeyframeReader.swift`, the side reader reworked) reads each keyframe one of two ways,
   settled once per session by what the index covers:
   - **The index** (Matroska's Cues, an MP4's sample entries): the keyframe is read exactly at the
     position the plan's own index entry gives, through the exact range reader and the shared source
     cache. No demuxer, no header parse, no read-ahead window.
   - **libavformat**, for every other container (AVI, FLV, ASF, ...): their packets are wrapped in
     framing only a demuxer takes apart (a chunk header, a tag, multiplexed payloads), so a demuxer
     of its own still reads the keyframe there, seeking to its time.

   The index is asked of `SourceIndexRegistry` (`HLSVideoEngine.iFrameKeyframeIndex`), so a source
   the subtitle fill already indexed costs nothing more. An index that could not be read is a failed
   request with the cool-down, asked again after it, never the demuxer route. Both routes share the
   cool-down, interrupt, close and the P7 to 8.1 conversion. The compositor preview reads through the
   same reader. Entries, eligibility, the SDR stills tier and the fragments are unchanged.
   - **The demuxer route reads exact ranges.** It opens on the exact range reader over the shared source
     cache (`AetherEngine.indexReader`), not on a streaming `AVIOReader`: a seek reads what it lands on
     and nothing streams ahead of it. A disc title opens as the session's (its title, its cache key)
     and seeks by its EP maps or time map.
   - **Blu-ray titles serve their keyframes.** Their plan is keyframe-aligned on the EP maps
     (`19f8f4bf`), so the `discSource` exclusion is gone; each keyframe is read where the EP map seek
     lands.
   - **A source with no keyframe list serves dense stills.** An MPEG-TS recording (or a DVD title) plans
     on the uniform grid, and listing its keyframes before the first scrub would mean reading the whole
     file. RFC 8216bis lets an I-frame playlist list any subset of I-frames, but each at its own
     presentation time (4.4.3.6), and Apple's authoring specification recommends a dedicated dense
     rendition at one frame a second (6.2), SDR on tvOS (6.16). So such a source
     (`IFrameRenditionEligibility.Timeline.stills`, `Demuxer.seeksToTimeWithoutIndex`) lists one SDR
     HEVC still a second (`denseStillEntries`), each the picture at its own time: the reader collects
     the packets from the last keyframe at or before the time to the first picture at or after it
     (`IFrameKeyframeReader.pictureRun`), the still builder decodes them and encodes that picture as an
     intra frame (`IFrameStillBuilder.encode(run:)`, the same decoder and encoder as the HDR session's
     SDR tier), and the master declares the stills alone with their own codec, range and size. The
     keyframes the session's pump has read (`Demuxer.recordedKeyframes`) are adopted into the reader's
     index and a run opens exactly on a recorded keyframe where one covers the time; elsewhere the
     timestamp search lands near the time, and the reader steps back (1, 2, 4, 8, 16 s) until the run
     opens before it. Tests: `IFrameDenseStillsTests` (a real session over a TS file serves six stills
     at their times; a run opens on the last keyframe at or before its time and ends past its picture),
     `IFrameRenditionEligibilityTests`.

5. **Unindexed containers: the pump reads ahead. Built.** A subtitle stream the index does not list in
   full (a transport stream's, a disc's, a Matroska file's without subtitle Cues, a fragmented MP4's) is
   interleaved with the video, so reading it early means reading the video early; that is now the pump's
   own read-ahead, and the walk (`SubtitleForwardPrefetcher`, its side demuxer, the link arbitration of
   #240, the restart budget of #231, the byte-estimate positioning of #112 and the pacing stream of #230)
   is gone. A pumped stream's packets come only from the session's reader of the source.
   - **Demand.** The consumers state their leads as before (`SubtitleSource.demand`); `Leads.readAhead`
     answers, off the main actor, the furthest lead of a consumer of a stream the index does not read
     (before the routes settle, every stream counts). The engine folds it with the playback clock
     (`SourcePlayheadClock`) into a source time.
   - **The native route.** Every producer asks it at its advance park (`subtitleReadAheadReach`, the
     segment holding that time on the plan's axis, plus one) and reads on past its forward window to it;
     the disk park (#207) still bounds the run, so a UHD remux at the 2 GiB budget reads as far as the
     budget allows. Segments cut ahead stay in the segment cache, where the bytes the walk left in the
     source cache used to wait for the pump, so the disk cost is the same and the second demux is gone.
   - **The software route.** The VOD read-ahead (`SoftwarePacketReadAhead`) takes the lead as its
     forward window and harvests subtitle packets where it reads, not where they are decoded. A local
     file, which has no read-ahead, harvests at its read loop's pace, as before #151.
   - **Coverage.** The pump states where it has read (`onSourceReadThrough`, the video's decode time
     every half second, `.infinity` at the end of the source): each producer anchors its run of the
     harvest coverage (#416) at its first read and extends it, the cue stores it decodes into are read
     to a margin short of it, and the end of the source is `via=eof`. The #250 statement's frontier is
     now the store's own (`harvestReach`, or `pulledReach` for an indexed stream: `via=read`), not a
     side reader's telemetry; the store has one writer, so its writer keys are gone.
   - **Tests.** `SubtitlePumpReadAheadTests` (the real producer over a TS fixture parks at its window
     and reads on to the reach, then to the end; the software read-ahead reads past its window as far as
     asked; the leads; end of source in the store and the cue stores), `SubtitleSourceTests` (routes,
     demand lifecycle, a pumped stream asks and an indexed one does not), `Issue250`/`Issue318` on the
     store's frontier, `Issue416` with one writer. The walk's own suites are deleted with it.
   - **Logs.** `[SubtitleSource] the pump reads ahead for [...]`, `... read-ahead lapsed (reason=...)`,
     and `subReadAhead=270s subRead=41.2s` in the memprobe line.

When layer 3 is done the readers of a playing source are the pump, exact index reads, and nothing
else; the ledger's per-reader lines should show exactly that.

## Decisions, and the ones that were reverted

- **HTTP/3 comes from the server's HTTPS DNS record, not from a client flag.** `assumesHTTP3Capable`
  and a learned per-origin list were planned and dropped: a fresh ephemeral session's first request
  is already h3 (measured on the Mac against the same origin, confirmed on the Apple TV).
- **The cache is injected, and its key covers the request.** An earlier version keyed by URL alone and
  used one shared cache everywhere; tests then served stale bytes across loopback origins that reused a
  port, which was the production risk (another user, another body) showing up first in tests.
- **A test bypass was added and removed.** The superseded-probe test (LIF-107) held the RPU audit at a
  test origin; with the cache the audit no longer asks the origin. A per-origin bypass made the test
  pass by sending it down an uncached path production no longer runs. It was replaced by testing the
  rule itself: `publishProbedGeometry` checks the generation and writes in one step, unit-tested with a
  stale and a current generation.
- **An MP4's index is libavformat's, not a second `moov` parser.** The plan said "read the `moov`
  once, through the cache". The demuxer has already parsed it, with the edit list applied, and its
  entries are the walk's packets by definition; a parser of our own would have to reproduce
  `mov_fix_index` to match them. Completeness was first `entries == nb_frames`, which refused every
  ffmpeg-muxed mov_text track: `nb_frames` counts `stts` samples including the trailing one the edit
  list trims. The test against `av_read_frame` caught it.
- **No transport stream subtitle scanner, and no pump-recorded TS index.** A Swift cell scanner was
  built and proven packet for packet against `mpegts.c` for PGS and teletext (188/192/204-byte cells,
  split PES headers, a zero-length adaptation field, continuity breaks, a missing PTS, the program
  clock fix, the 33-bit wrap, a seek, lost sync), with mpeg2ts-reader as a second reference, then
  removed. The premise was that a TS subtitle walk is a second full demux: `AVDISCARD_NONKEY` is not
  implemented by mpegts, so the pacing video arrives whole and parsed. True, but measured it runs at
  about 5 GB/s (SIMD start-code search, memcpy-speed PES copies): a 60 GB remux costs the walk ~12 s
  of CPU over the film. The scanner did not beat it in a debug build, would not have read fewer
  bytes (subtitles interleave with video cell by cell), and DVB subtitles would have needed the
  `dvbsub` parser libavformat runs after the demuxer (`need_parsing` is FULL for every mpegts
  stream). Kept from it: libavformat's TS seek already records index entries as it searches
  (`mpegts_get_dts` → `av_add_index_entry`, every probed packet, flagged keyframe whatever it is),
  and its later seeks on the same demuxer use them as bounds (`ff_seek_frame_binary`); the demuxer's
  settings are public AVOptions (`ts_packetsize`, `resync_size`, `max_packet_size`,
  `fix_teletext_pts`, `merge_pmt_versions`).
- **The prefetch index path was first written as a second loop.** `runIndexed` duplicated the walk's
  contract and was replaced, before commit, by one loop over a `Source` with two implementations.
- **No memory tier of the engine's own.** The three RAM stores existed to avoid network round trips
  and to outlive the window's trim; the cache does both, and the kernel's page cache gives memory speed
  for what is hot. If the device measurement shows a regression, one generalised RAM tier in front of
  the cache is the fallback, not three.
- **Sodalite keeps its own sessions** (see layer 1, item 8).
- **The forced bitmap rendition is no longer read from composition headers, and a selected bitmap
  track is no longer recognized to the end of the film.** The indexed fill scanned every display
  set's first 512 bytes for the forced flag and recognized the whole forced rendition at load, and
  recognized a selected full track from the playhead to the end and round to the start. Both were a
  second OCR path beside the worker. The one worker reads as far ahead as its demand (270 s, or as far
  as AVKit asks), and the header scan, the prefix reads and `PGSCompositionHeader` went with them.
- **`eagerNativeSubtitleReaders` already did nothing.** Its branch ran only when the pump tap could not
  arm, which is exactly when no embedded text track exists for it to read. The branch is gone; the
  public option is still declared.
- **A demand that is withdrawn and asked again in one turn is not a stop.** The first version stopped
  the reading on the withdrawal, so the OCR worker's re-arm closed and reopened the walk.
- **A full bitmap rendition is not recognized to the end of the film.** It was planned; the worker
  reads its packets from the packet store, whose byte cap keeps a bitmap track's window, not its film,
  so the whole film would need a second recognition path beside the worker. The worker stays ahead of
  AVKit's frontier instead; the forced rendition, which is the one tvOS shows by itself, is whole.
- **The deselect pin and `systemCaptionRequest` are gone.** The engine held AVFoundation's selection off
  (Sodalite#38, #65) so that the overlay alone drew subtitles, and forwarded what the system asked for.
  With AVKit suppressed only for the tracks the overlay draws, the system's selection is simply
  followed.
- **Two ways to read a keyframe, by container.** Index-only was weighed: it would have left AVI, FLV
  and ASF titles without scrub thumbnails, since only libavformat can turn their index positions into
  packets and re-implementing their packet assembly is the duplicate parser this plan refuses
  elsewhere. So the index where it covers the container, a demuxer where only a demuxer can read it,
  the same split the subtitle source will have.
- **A Matroska cue without a relative position is matched by time, not taken as the cluster's first
  block.** The first version assumed muxers start a cluster at the keyframe; a short file whose one
  cluster holds every keyframe answered all of them with the first. The block's own time is exact.
- **No deadline on resolving the index.** The first version gave up after twice the read deadline;
  under load a Matroska parse that was slow but moving became failures and cool-downs. The reads it
  makes carry their own timeouts, and teardown interrupts the wait.
- **The write bound holds requests, not deliveries.** The first version waited inside `store`, which
  runs in the delivery callbacks; `appendPersistentData` records why that cannot work (#174, #220: a
  delivery callback that blocks does not slow the transport, CFNetwork keeps reading into its own
  buffers). The wait moved to where each reader sends its next request.
- **An index's lifetime is its source's, not a count.** A cap of eight indexes kept one for hours
  after its source went and could evict one a session was still using.
- **`merge_pmt_versions` was measured and refused.** It keeps the old `AVStream` across a PMT change,
  which looks like the fix for a reader stuck on the old index, but `mpegts.c` updates the stream type
  before the check that would update the codec, so an H.264 to HEVC change carried on labelled H.264,
  with nothing public to tell. Following the change ourselves (`ProgramSuccession`) keeps libavformat's
  correctly typed new streams.
- **A program change is a property of the packet, not an event.** The first version announced each
  change once and reset on a seek, assuming every reader restarts on the open's streams. A software
  host rebuilt onto a successor does not, so each packet now says where it came from and every reader
  compares with its own configuration.

## Reading the logs

| Line | What it says |
|---|---|
| `[AVIOReader] origin transport: h3 over IPv6 at ...` | The connection's protocol and address family, once per origin |
| `[SourceLedger] <source> <reader> closed: fetched ..., unique ..., duplicate ... (x%), served from cache ...; <reader> ... dup ... cache ...` | The books, per reader; the final line says `source done` |
| `[SourceCache] <source> released: stored ..., served ... back to readers[, requests waited N ms for the disk]` | A source's cache going, after its grace; the wait only if the disk ever fell behind |
| `[SourceCache] <source> is another body now (... -> ...); dropped what was held for it` | A response stated another size, `ETag` or `Last-Modified`: the file behind the request was replaced |
| `[SourceCache] <source> write queue past 64 MB: requests wait for the disk; the first waited N ms` | The disk fell behind the link, once per process |
| `[SourceCache] budget X MB -> Y MB (volume free Z MB)` | The claim sized again, when it moved by 64 MB or more |
| `[AVIOReader] <reader> conn start ... from the source cache` | A pump range replayed from disk |
| `[AVIOReader] <reader> source cache served the read at ...; no reconnect for it` | The first out-of-window read served from the cache, once per reader |
| `[SubtitleSource] routes in ... ms: indexed [...], walked <stream>: <why>, ...` / `every stream walked (<why>)` | Each subtitle stream's route, once per session |
| `[SubtitleSource] reading from Ts: indexed [...] walked [...] pacing=N` | A reading session started, and what it reads |
| `[SubtitleSource] stream N complete from the index: ... frames, ... cues in ... ms` | A text rendition filled whole at load |
| `[SubtitleSource] stopped reading (reason=...)` | Nobody asks any more, and the last consumer's reason |
| `[NativeSubtitles] following "<option>": track N ordinal M, drawn by AVKit` / `the overlay` | The selection AVFoundation holds, whoever made it, and who draws it |
| `[NativeSubtitles] AVKit suppressed (its line cleared first)` / `AVKit draws the rendition` | Suppression switched for an overlay-drawn track, or lifted |
| `[NativeSubtitles] forced ordinal=N from the index: ... display sets, ... forced, ... lines` | A forced bitmap rendition recognized whole at load |
| `[NativeSubtitles] the rendition is the display and serves a delay of ...; rebuilding` | A mid-session delay carried to PiP / AirPlay by a rebuild |
| `[HLSVideoEngine] cue prewarm: skipped, mpegts has no index a seek loads` | The prewarm left out on a container without a lazy index |
| `segment plan: uniform stride fallback (..., anchorPts=... (first IRAP read), ...)` | The uniform plan's anchor and where it came from |
| `[Demuxer] program change: stream N (PID 0x...) takes the role of stream M (PID 0x...)` | A PMT change followed: the new PID read as the role's stream |
| `[Demuxer] program change reaches the read: stream M now reads stream N (was K)` | The first packet of the role from another stream |
| `[HLSSegmentProducer] program change: video now on stream N (was M)[, another codec]` | What a pump makes of it |
| `SSAI video program switch: ...` / `muxer rotation (programme back)` | The live ad's init, and the programme's again |
| `[SWHost] program change: ...; rebuilding at the playhead` | The software path's rebuild for another codec |
| `[IFrameKeyframes] keyframes read from the index (track N)` / `keyframes read by a demuxer of their own: <why>` | Which route a session's I-frame keyframes took, once per session |
| `[IFrameKeyframes] <what>; leaving the source alone for Ns (consecutive failures: n)` | A failed keyframe read, index or open, and its cool-down |
