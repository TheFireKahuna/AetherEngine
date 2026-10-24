# Source pipeline: every byte once, every index once, every output on demand

Status: in progress, written 2026-10-24 against `research/12bit-fel` at `a7a725e8` and the tvOS 27.2
SDK (Xcode 27.2). Layers 1 and 2 are built and on device; layer 3 is the remaining work. Each
section says what is done, which tests hold it, and what is not yet ideal, with the steps to get
there.

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
| `SourceByteCache` | `Demuxer/SourceByteCache.swift` | Every network delivery is kept, per source, in a sparse file in tmp. LRU by 4 MB block with `F_PUNCHHOLE`, budgeted through `RetentionClaims` beside the segment caches (up to 4 GiB or a quarter of free space). Read-your-writes: a stored range is servable at once, from memory until its write lands. The kernel's page cache is the memory tier. Also holds per source the total size and the resolved redirect target. |
| `SourceCacheKey` | `Demuxer/ByteSpanSet.swift` | What makes bytes shareable: the credential-free URL plus a SHA-256 of the credentials and request headers. Readers of one session share; another user, token or header set never does (the #551 rule). |
| `SourceByteLedger` | `Demuxer/SourceByteLedger.swift` | Per source and per reader: fetched, unique, duplicate, discarded, served from cache. One line per reader close when the books changed, and a final line per source. |
| `RangeReadableIOReader` | `IO/IOReader.swift` | Exact range reads, concurrent, no cursor. `HTTPDiscIOReader` serves held bytes and fetches exactly the gaps; one reader serves all twelve indexed-subtitle lanes. |

How `AVIOReader` uses the cache:

- A read outside the live window is served from the cache before any network path, outside `winCond`.
- The pump plans its ranges around what is held: a held span replays as a range of its own (`CachedSpanTransfer`, the third `PersistentTransfer` shape), and a network range stops where a held span of at least 256 KB begins.
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
2. **The cache trusts size and headers, not the body's version.** A file replaced on the server with
   one of the same size, inside the five-minute grace, would be served stale.
   - Record `ETag` and `Last-Modified` from the first response per source; a reader whose response
     disagrees invalidates the source exactly as a size change does (`noteTotalSize`).
3. **Small held spans are fetched through.** The pump does not split a range around a held span under
   `minimumServeBytes` (256 KB), so subtitle blocks the index reads fetched ahead of the pump are
   fetched again when the pump reaches them. Tiny, but not zero.
   - Measure it in the ledger first. Over HTTP/3 a split costs a stream, not a handshake, so lower the
     threshold until the request count stops paying for itself; or, better, layer 3 removes the reads
     ahead of the pump that leave these spans.
4. **Writes can be dropped.** Past 64 MB of pending writes the cache drops new ones (a fast link
   outrunning the disk), and a dropped range can be fetched again.
   - Count dropped bytes in the ledger. If they ever show, back-pressure the writer (the delivery
     callbacks) instead of dropping.
5. **The budget is sized once.** The shared claim is computed at first use from free space then; it is
   not revisited if the disk fills during a long session.
   - Re-size on the segment caches' own schedule through `RetentionClaims`, evicting down to the new
     claim.
6. **Fixed fetch sizes where exact would do.** The chunk path (the I-frame reader, probes) fetches 1 MB
   chunks and a detour fetches a 4 MB block for a read of a few KB. With the cache beneath them that
   is waste, not duplicate, and with HTTP/3 a smaller request costs little.
   - Measure per path; size chunk and detour fetches to the read, grown on sequential continuation as
     `HTTPDiscIOReader.nextChunkSize` already does. Layer 3 replaces the I-frame reads outright.
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

## Layer 2: one index per source (built for Matroska)

### What it is

| Piece | File | What it does |
|---|---|---|
| `SourceIndexRegistry` | `Demuxer/SourceIndexRegistry.swift` | One index per source and size. Racing callers share the one parse; later callers get the result. Not-Matroska and no-Cues are kept answers; a read that broke off is not, so the next consumer retries. The key is derived from the request and the reader's own size (`matroskaIndex(of:headers:through:)`), so two consumers cannot name a source differently. |
| `ParseToken` | same | `MatroskaSubtitleIndex.read` requires one and only the registry can make it, so a second parse cannot be added by accident. The parser's unit tests use a debug-only token; a release build pins that no production code does. |
| Index consumers | `AetherEngine+SourceIndex.swift` | One exact reader factory (`indexedSourceReader`), one subtitle stream listing (`matroskaSubtitleStreams`), the prefetch source builder. |

Consumers today: the indexed subtitle fill (`AetherEngine+IndexedSubtitles.swift`) and the forward
subtitle prefetch, which reads blocks from the index instead of walking the stream when the index lists
every stream completely (`SubtitleForwardPrefetcher.IndexSource`, one loop over a `Source`).

### Guarantees and the tests that hold them

| Guarantee | Tests |
|---|---|
| Twelve racing consumers, one parse; a later consumer, no parse; source and size name the index | `SourceIndexRegistryTests` |
| The index prefetch stores the same packets the walk would, in one time order, re-anchors in place, ends a dropped connection as a read failure, is all or nothing | `SubtitleIndexPrefetchTests` |
| The walk's contract is unchanged through the one loop | `Issue151SubtitleForwardPrefetchTests`, `Issue230PrefetchReadPositionParkTests`, `Issue231PrefetchRestartTests`, `Issue234SideReaderSeekAnchorTests`, `Issue240SideReaderLinkPriorityTests` |

### Not yet ideal, and the steps

1. **Matroska only.** An MP4's `moov` has the same information (sample tables, sync samples) and no
   shared index; MPEG-TS has none at all.
   - Generalise the registry's outcome to a container index type with a Matroska and an MP4 parser
     (the `moov` is read once, through the cache).
   - For MPEG-TS and any source without one, have the pump record an index as it reads (keyframe and
     subtitle packet positions), registered under the same key, so later reads and seeks are served
     from the map instead of a walk.
2. **The index is named for subtitles and exposes only them.** `MatroskaSubtitleIndex` already parses
   every track's cues, video included.
   - Rename it to what it is (the source's cue index) and expose keyframe positions per video track,
     for the I-frame playlist and for seeking.
3. **WebVTT keeps the whole prefetch on the walk.** The index path is all or nothing, and WebVTT is
   excluded because its cue settings travel in BlockAdditions, which libavformat turns into side data
   (#233).
   - Parse BlockAdditions in the index's block reader so a WebVTT block becomes the same packet and
     settings, and drop it from the exclusion.
4. **The index outlives its source.** The registry keeps eight indexes, least recently asked for out;
   it is not tied to the source cache's lifetime.
   - Release an index with its source (`SourceByteCache` release), so the two share one lifetime.
5. **"Parsed once" holds for the engine's parser, not for libavformat.** Every side demuxer (the
   I-frame reader, the prefetch's own open, the native subtitle readers, the still extractor, the
   Atmos confirmation and the Dolby Vision audit) parses the container header and its cues again: no
   network now, but CPU and memory each time.
   - Layer 3 retires the side demuxers that only exist to read subtitles and keyframes. What remains
     (the Atmos confirmation, the DV audit) should read their few packets through the index too.
6. **Two consumers read the same subtitle blocks.** The indexed fill reads every text cue of the film
   at load for the native renditions; the prefetch reads blocks again for the packet store. The second
   read is a cache hit, but it is a second parse and decode.
   - Layer 3: one subtitle source feeds every store.

## Layer 3: every output on request (next)

In order, each step replacing a reader rather than adding one:

1. **One subtitle source per session.** "Stream S's packets from time T on", backed by the index where
   it covers the stream and by one stream walk otherwise. The packet store, the native cue stores and
   the OCR worker read from it. The forward prefetcher and the native side readers become its walk
   backend; the indexed fill's block loop becomes its index backend.
2. **Subtitle renditions served on request.** A WebVTT segment request from AVKit asks the subtitle
   source for exactly that segment's time range, so AVKit's own look-ahead is the lead. The forced
   rendition the same way (`FORCED=YES`). The fixed leads (`subtitleDrainLeadSeconds`, the OCR worker's
   270 s) stop being reasons to read ahead.
3. **The PGS overlay pulls.** The drainer asks the subtitle source for its window around the playhead;
   the packet store becomes a cache of what was pulled, not a buffer filled ahead.
4. **The I-frame playlist from the index.** `EXT-X-I-FRAMES-ONLY` entries from the keyframe positions,
   each keyframe read exactly; the I-frame side demuxer goes.
5. **Unindexed containers.** The pump records the index as it reads (layer 2, step 1); a request ahead
   of the pump in an unindexed interleaved file is the one case where reading the video early is
   inherent, and it goes through the pump's own read-ahead into the cache, not a second walker.

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
- **The prefetch index path was first written as a second loop.** `runIndexed` duplicated the walk's
  contract and was replaced, before commit, by one loop over a `Source` with two implementations.
- **No memory tier of the engine's own.** The three RAM stores existed to avoid network round trips
  and to outlive the window's trim; the cache does both, and the kernel's page cache gives memory speed
  for what is hot. If the device measurement shows a regression, one generalised RAM tier in front of
  the cache is the fallback, not three.
- **Sodalite keeps its own sessions** (see layer 1, item 8).

## Reading the logs

| Line | What it says |
|---|---|
| `[AVIOReader] origin transport: h3 over IPv6 at ...` | The connection's protocol and address family, once per origin |
| `[SourceLedger] <source> <reader> closed: fetched ..., unique ..., duplicate ... (x%), served from cache ...; <reader> ... dup ... cache ...` | The books, per reader; the final line says `source done` |
| `[SourceCache] <source> released: stored ..., served ... back to readers` | A source's cache going, after its grace |
| `[AVIOReader] <reader> conn start ... from the source cache` | A pump range replayed from disk |
| `[AVIOReader] <reader> source cache served the read at ...; no reconnect for it` | The first out-of-window read served from the cache, once per reader |
| `#151 forward prefetch started from the index` / `walking the stream` | Which subtitle prefetch source a session got |
| `[IndexedSubtitles] index read in ... ms` | The fill's index, parsed or shared |
