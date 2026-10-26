import Darwin
import Foundation

/// Bytes of a source already fetched, kept on disk so that no reader fetches them a second time.
///
/// Several readers fetch one source at once (the pump, the subtitle prefetcher, the indexed subtitle
/// fill, the I-frame reader, open-time probes, a prewarm), and each kept its bytes to itself, so the
/// same ranges crossed the wire again and again: `SourceByteLedger` measured a third of a session's
/// traffic as bytes fetched before. Every network delivery is written here, every fetch path asks here
/// first, and the pump plans its ranges around what is held, so a byte is fetched once whichever
/// reader gets to it first.
///
/// One sparse file per source in the tmp volume, each byte written at its own offset (APFS keeps the
/// gaps unallocated), with a `ByteSpanSet` saying which bytes are valid. Eviction is least recently
/// used by `blockBytes` block and gives the space back with `F_PUNCHHOLE`. The budget is a claim on
/// the same tmp-volume allowance the segment caches share (`RetentionClaims`), so the two never
/// promise each other the same free space, and it is sized again as the cache writes, since the disk
/// can fill under a long session.
///
/// A source is a `SourceCacheKey`: the credential-free URL plus a digest of how it is asked for, so
/// bytes cross between readers of one session and never between users. Each source records the body
/// its bytes are from (`SourceVersion`: the length, and the origin's `ETag` and `Last-Modified`). A
/// response that states another body drops what was held, since the same request now answers with
/// different bytes; a delivery from a response that states another body than the recorded one is
/// not kept; and bytes are served only to a reader whose idea of the total size matches.
///
/// Whatever else is kept per source goes with it: `observeReleases` tells the source's index
/// (`SourceIndexRegistry`) when the source is let go.
///
/// What a reader streams through is kept only where someone can come back for it (`Retention`): a
/// lone reader playing a film from start to end never reads the middle again, and keeping it wrote
/// the whole film to flash once per viewing.
///
/// A reader uses the cache only when it is handed one (`AVIOReader(sourceCache:)`,
/// `HTTPDiscIOReader(sourceCache:)`): the engine's own construction sites pass `shared`, and a reader
/// built without it fetches everything itself, as every reader did before.
final class SourceByteCache: @unchecked Sendable {
    static let shared = SourceByteCache()

    /// Eviction unit, and the granularity of recency.
    static let blockBytes: Int64 = 4 << 20
    /// A held span shorter than this is not worth a request boundary of its own: the pump fetches
    /// straight through it rather than split a range around a subtitle block. The default until a
    /// reader has measured its link; from then on the reader uses what the link moves in one round
    /// trip (`AVIOReader.heldSpanWorthASplitLocked`).
    static let minimumServeBytes: Int64 = 256 << 10
    /// How long a source's bytes outlive its last reader. A reload, a track switch or a resume from
    /// the detail page closes every reader and opens new ones moments later.
    static let releaseGraceSeconds: TimeInterval = 300
    /// Bytes that may wait in memory for their write before readers hold their next request
    /// (`waitForWriteRoom`): the cache must never become the thing that holds a gigabyte of RAM, and
    /// a delivery it threw away would be fetched again by the next reader that wants it.
    static let maxPendingWriteBytes = 64 << 20
    /// Most the shared cache claims, whatever the volume has free.
    static let budgetCeilingBytes: Int64 = 4 << 30
    /// How far from either end of a source a streamed delivery is kept whoever else is reading: the
    /// head holds what the parse returns to and what a later open replays (Matroska header and
    /// attachments, a front `moov`), the end holds the trailing index (cues, a rear `moov`).
    static let streamEdgeBytes: Int64 = 64 << 20

    /// Which deliveries are kept.
    enum Retention: Sendable {
        /// Bytes a reader asked for by position (a detour, the tail, a chunk): kept.
        case always
        /// A reader's sequential stream: kept within `streamEdgeBytes` of either end of the source,
        /// or while another reader streams it and can come back for the bytes (the subtitle walk ahead
        /// of the pump, the pump behind it). A reader asking by position does not count: it reads only
        /// the bytes it names, which are kept. Otherwise passed over, which costs only a fetch if a
        /// later reader does want them.
        case streamed
    }

    /// How big the cache may grow.
    enum Budget: Sendable {
        /// A fixed size: a reader's own cache, and tests.
        case fixed(Int64)
        /// A claim beside the segment caches', sized again every `reviewEvery` bytes written.
        case claimed(Allowance)
    }

    /// The shared cache's claim on the tmp volume: `sizing` over what `freeSpace` reports, less what
    /// the other claims of `claims` have yet to write.
    struct Allowance: Sendable {
        let claims: RetentionClaims
        let freeSpace: @Sendable () -> Int64?
        let sizing: @Sendable (Int64?) -> Int
        let reviewEvery: Int64

        /// Up to `budgetCeilingBytes` or a quarter of the space left, reviewed every 256 MB written
        /// (about half a minute of an 80 Mbit/s film fetched at its bitrate).
        static let shared = Allowance(
            claims: .shared, freeSpace: { RetentionClaims.tmpVolumeAvailableBytes() },
            sizing: { left in Int(min(SourceByteCache.budgetCeilingBytes, (left ?? SourceByteCache.budgetCeilingBytes) / 4)) },
            reviewEvery: 256 << 20)
    }

    private final class Source: @unchecked Sendable {
        let fd: Int32
        let path: String
        /// What is on disk.
        var spans = ByteSpanSet()
        /// Stored and not yet written, readable all the same: a reader that fetched a block must be
        /// able to read it straight back, or the write's latency would be a window in which the next
        /// reader fetches it again.
        /// In store order, which is the order their writes land in, so a landed write is always the
        /// first entry.
        var pending: [(offset: Int64, data: Data)] = []
        /// What a read can be served from: on disk or pending.
        var visible = ByteSpanSet()
        /// Block index to the tick it was last written or read.
        var blockUse: [Int64: UInt64] = [:]
        /// The body the held bytes are from.
        var version = SourceVersion()
        /// Where the source's bytes were actually served from, redirects followed (#551 round 2):
        /// a reader that pins it does not pay the resolver's 302 again.
        var resolvedURL: URL?
        /// Every open reader: the source is let go only when none is left.
        var openReaders = 0
        /// The open readers that stream it (`readerOpened(_:streams:)`): only another of these comes back
        /// for a stream's bytes, so only these decide whether a streamed delivery is kept.
        var streamingReaders = 0
        /// Bumped by every eviction, so a read that raced one is discarded instead of returning a
        /// punched hole's zeros.
        var evictions: UInt64 = 0
        var release: DispatchWorkItem?
        var servedBytes: Int64 = 0
        var storedBytes: Int64 = 0
        /// Streamed by a lone reader and not kept (`Retention.streamed`).
        var passedOverBytes: Int64 = 0
        /// How long this source's readers held a request for the disk (`waitForWriteRoom`).
        var writeWaitNanos: UInt64 = 0

        init?(directory: URL) {
            path = directory.appending(path: UUID().uuidString + ".bin").path
            fd = Darwin.open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
            guard fd >= 0 else { return nil }
        }

        /// The file goes with the last reference, which a write or a read in flight holds, so a
        /// source released mid-read still has its descriptor until that read returns.
        deinit {
            Darwin.close(fd)
            unlink(path)
        }
    }

    private let directory: URL
    /// A cache made for one reader removes its directory with itself.
    private let removesDirectory: Bool
    private var byteBudget: Int64
    private let releaseGrace: TimeInterval
    private let allowance: Allowance?
    private let claim: RetentionClaims.Claim?
    private let pendingWriteBound: Int
    /// `streamEdgeBytes`, unless a test sizes it to its file.
    private let streamEdge: Int64
    /// The cache's one lock, and the condition a reader waiting for the disk waits on.
    private let lock = NSCondition()
    private var sources: [SourceCacheKey: Source] = [:]
    private var heldBytes: Int64 = 0
    private var pendingWriteBytes = 0
    /// Stored deliveries not yet handed to the disk, oldest first, across every source. One drain
    /// on `writeQueue` takes whatever has queued up, so a burst of small deliveries costs one
    /// dispatch and one `pwritev` per contiguous run rather than a dispatch and a `pwrite` each.
    private var queuedWrites: [(source: Source, key: SourceCacheKey, offset: Int64, data: Data)] = []
    private var drainScheduled = false
    private var clock: UInt64 = 0
    private var storedSinceReview: Int64 = 0
    private var writeWaitLogged = false
    private var directoryReady = false
    private var releaseObservers: [@Sendable (SourceCacheKey) -> Void] = []
    /// Readers wait on it once the queue is full, and they read at playback priority: a queue below
    /// theirs would be the thing they wait for, and utility I/O is throttled behind theirs.
    private let writeQueue = DispatchQueue(label: "aether.source-cache.write", qos: .userInitiated)
    private let releaseQueue = DispatchQueue(label: "aether.source-cache.release", qos: .utility)

    /// The shared cache: the engine's own directory, emptied of whatever an earlier process left, and
    /// a budget claimed beside the segment caches'.
    private convenience init() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "aether-source-cache", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        self.init(directory: directory, budget: .claimed(.shared))
    }

    init(directory: URL, budget: Budget, releaseGrace: TimeInterval = SourceByteCache.releaseGraceSeconds,
         pendingWriteBound: Int = SourceByteCache.maxPendingWriteBytes,
         streamEdge: Int64 = SourceByteCache.streamEdgeBytes, removesDirectory: Bool = false) {
        self.directory = directory
        self.streamEdge = streamEdge
        self.removesDirectory = removesDirectory
        self.releaseGrace = releaseGrace
        self.pendingWriteBound = pendingWriteBound
        switch budget {
        case .fixed(let bytes):
            byteBudget = max(0, bytes)
            allowance = nil
            claim = nil
        case .claimed(let allowance):
            let claim = allowance.claims.claim(volumeAvailableBytes: allowance.freeSpace(), sizing: allowance.sizing)
            byteBudget = Int64(claim.bytes)
            self.allowance = allowance
            self.claim = claim
        }
        claim?.track { [weak self] in self.map { Int($0.heldBytesSnapshot) } ?? 0 }
    }

    /// A cache of one reader's own, for a reader nobody handed the shared one (a reader built
    /// directly, as tests do): the same read path, so a reader never has a second way of keeping the
    /// bytes it fetched. Sized for what one reader re-reads (the head its parse returns to, backward
    /// detours), released as the reader closes, gone with it.
    static func scoped() -> SourceByteCache {
        SourceByteCache(
            directory: FileManager.default.temporaryDirectory
                .appending(path: "aether-reader-cache", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString, directoryHint: .isDirectory),
            budget: .fixed(scopedBudgetBytes), releaseGrace: 0, removesDirectory: true)
    }

    static let scopedBudgetBytes: Int64 = 64 << 20

    deinit {
        if removesDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Lifetime

    /// A reader of `key` opened. `streams`: it reads the source as a stream (the pump, the subtitle walk),
    /// rather than asking for the bytes it wants by position (an index's frames, a disc's blocks), whose
    /// deliveries are kept anyway (`Retention.always`) and which never come back for a stream's.
    func readerOpened(_ key: SourceCacheKey, streams: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let source = sourceLocked(key, create: true) else { return }
        source.openReaders += 1
        if streams { source.streamingReaders += 1 }
        source.release?.cancel()
        source.release = nil
    }

    /// The reader `readerOpened(_:streams:)` announced closed; `streams` as it was opened with.
    func readerClosed(_ key: SourceCacheKey, streams: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let source = sources[key] else { return }
        source.openReaders = max(0, source.openReaders - 1)
        if streams { source.streamingReaders = max(0, source.streamingReaders - 1) }
        scheduleReleaseLocked(key, source)
    }

    /// What a response says about the body behind `key`: its size, its validators. One that cannot
    /// be the recorded body means the file behind the request was replaced, and everything held for
    /// it goes, with whatever is kept beside it (`observeReleases`).
    func noteVersion(_ version: SourceVersion, for key: SourceCacheKey) {
        guard version != SourceVersion() else { return }
        lock.lock()
        guard let source = sourceLocked(key, create: true) else { lock.unlock(); return }
        guard source.version.contradicts(version) else {
            source.version = source.version.merged(with: version)
            scheduleReleaseLocked(key, source)
            lock.unlock()
            return
        }
        let was = source.version
        heldBytes -= source.spans.totalBytes
        source.release?.cancel()
        if let fresh = Source(directory: directory) {
            fresh.version = version
            fresh.openReaders = source.openReaders
            fresh.streamingReaders = source.streamingReaders
            sources[key] = fresh
            scheduleReleaseLocked(key, fresh)
        } else {
            sources[key] = nil
        }
        let observers = releaseObservers
        lock.unlock()
        EngineLog.emit(
            "[SourceCache] \(key.display) is another body now (\(was.description) -> \(version.description)); "
            + "dropped what was held for it", category: .demux)
        for observer in observers { observer(key) }
    }

    /// `observer` is told each source the cache lets go: after its grace, by `releaseIdleSources`, or
    /// when a response says it is another body now. Called outside the cache's lock.
    func observeReleases(_ observer: @escaping @Sendable (SourceCacheKey) -> Void) {
        lock.lock(); defer { lock.unlock() }
        releaseObservers.append(observer)
    }

    /// Records where `key`'s bytes were served from, redirects followed; nil leaves what is known.
    func noteResolvedURL(_ url: URL?, for key: SourceCacheKey) {
        guard let url else { return }
        lock.lock(); defer { lock.unlock() }
        sourceLocked(key, create: true)?.resolvedURL = url
    }

    /// Forgets `url` as `key`'s redirect target, when it still is the one recorded: a reader whose pin
    /// expired drops it here too, so the next reader resolves afresh instead of adopting a dead lease.
    func forgetResolvedURL(_ url: URL, for key: SourceCacheKey) {
        lock.lock(); defer { lock.unlock() }
        if sources[key]?.resolvedURL == url { sources[key]?.resolvedURL = nil }
    }

    /// The redirect target a reader of `key` learned, for the next reader to pin (#12).
    func resolvedURL(for key: SourceCacheKey) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return sources[key]?.resolvedURL
    }

    /// Lets go of every source no reader has open, now rather than after the grace: a host leaving the
    /// context its warms were made for (a sign-out, a server change).
    func releaseIdleSources() {
        lock.lock()
        var released: [SourceCacheKey] = []
        for (key, source) in sources where source.openReaders == 0 {
            source.release?.cancel()
            heldBytes -= source.spans.totalBytes
            sources[key] = nil
            released.append(key)
        }
        let observers = releaseObservers
        lock.unlock()
        for key in released { for observer in observers { observer(key) } }
    }

    /// The total size recorded for `url`, whichever reader learned it and under whichever token.
    func knownSize(_ key: SourceCacheKey) -> Int64? {
        knownVersion(key)?.size
    }

    /// The body recorded for `key`: what a reader that adopts the cache's bytes without asking the
    /// origin checks its first response against (#551).
    func knownVersion(_ key: SourceCacheKey) -> SourceVersion? {
        lock.lock(); defer { lock.unlock() }
        return sources[key]?.version
    }

    // MARK: - Bytes

    /// Keeps `data`, which a reader fetched for `key` at `offset` from a response that stated
    /// `version`. Servable from the moment it is stored (out of memory until its write lands). A
    /// delivery from another body than the recorded one is not kept: it came on a connection answered
    /// before the file behind the request was replaced. Never blocks and never drops: it is called
    /// from delivery callbacks, which have no flow control to push back with (#174), so the bound
    /// is kept where readers send their next request (`waitForWriteRoom`). `retention` says whether a
    /// streamed delivery is worth keeping (`Retention`).
    func store(_ data: Data, at offset: Int64, version: SourceVersion, for key: SourceCacheKey,
               retention: Retention = .always) {
        guard !data.isEmpty, offset >= 0 else { return }
        lock.lock()
        guard byteBudget > 0, let source = sourceLocked(key, create: true),
              !source.version.contradicts(version) else {
            lock.unlock()
            return
        }
        source.version = source.version.merged(with: version)
        let count = Int64(data.count)
        var pieces = [(offset: offset, data: data)]
        if retention == .streamed, source.streamingReaders < 2 {
            let parts = Self.edgeParts(offset: offset, count: count, size: source.version.size, edge: streamEdge)
            // A delivery is as large as the transport batched it, megabytes when the reader falls
            // behind, so only its bytes within the edges are kept. Copied out, so a pending piece does
            // not hold the whole delivery's buffer beyond what the pending bound counts.
            if parts != [offset..<(offset + count)] {
                pieces = parts.map { part in
                    let lower = data.startIndex + Int(part.lowerBound - offset)
                    return (offset: part.lowerBound, data: data.subdata(in: lower..<(lower + part.count)))
                }
            }
            source.passedOverBytes += count - parts.reduce(0) { $0 + Int64($1.count) }
        }
        for piece in pieces {
            pendingWriteBytes += piece.data.count
            source.pending.append(piece)
            source.visible.insert(start: piece.offset, end: piece.offset + Int64(piece.data.count))
            queuedWrites.append((source, key, piece.offset, piece.data))
        }
        scheduleReleaseLocked(key, source)
        guard !pieces.isEmpty else {
            lock.unlock()
            return
        }
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { writeQueue.async { [self] in drainWrites() } }
    }

    /// The parts of `count` bytes at `offset` that lie within `edge` of either end, in order. An
    /// unknown size has no middle to pass over, and a source no longer than two edges is all edge.
    static func edgeParts(offset: Int64, count: Int64, size: Int64?, edge: Int64) -> [Range<Int64>] {
        let end = offset + count
        guard let size, size - edge > edge else { return [offset..<end] }
        var parts: [Range<Int64>] = []
        if offset < edge { parts.append(offset..<min(end, edge)) }
        if end > size - edge { parts.append(max(offset, size - edge)..<end) }
        return parts
    }

    /// Writes whatever has queued, until nothing has. On `writeQueue`.
    private func drainWrites() {
        while true {
            lock.lock()
            let batch = queuedWrites
            queuedWrites.removeAll(keepingCapacity: true)
            if batch.isEmpty {
                drainScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()

            // Contiguous runs into one file go down as one vectored write.
            var outcomes = [Bool](repeating: false, count: batch.count)
            var runStart = 0
            while runStart < batch.count {
                var runEnd = runStart + 1
                var nextOffset = batch[runStart].offset + Int64(batch[runStart].data.count)
                while runEnd < batch.count, runEnd - runStart < Self.maxWriteRunEntries,
                      batch[runEnd].source === batch[runStart].source,
                      batch[runEnd].offset == nextOffset {
                    nextOffset += Int64(batch[runEnd].data.count)
                    runEnd += 1
                }
                let written = Self.writeRun(batch[runStart].source.fd,
                                            batch[runStart..<runEnd].map(\.data),
                                            at: batch[runStart].offset)
                for i in runStart..<runEnd { outcomes[i] = written }
                runStart = runEnd
            }

            lock.lock()
            var review = false
            var landed: [ObjectIdentifier: Int] = [:]
            var rebuild: [ObjectIdentifier: Source] = [:]
            for (i, item) in batch.enumerated() {
                let source = item.source
                let count = item.data.count
                pendingWriteBytes -= count
                landed[ObjectIdentifier(source), default: 0] += 1
                guard outcomes[i], sources[item.key] === source else {
                    rebuild[ObjectIdentifier(source)] = source
                    continue
                }
                let end = item.offset + Int64(count)
                let added = source.spans.insert(start: item.offset, end: end)
                heldBytes += added
                source.storedBytes += added
                touchLocked(source, start: item.offset, end: end)
                storedSinceReview += added
            }
            for item in batch {
                let id = ObjectIdentifier(item.source)
                guard let n = landed.removeValue(forKey: id) else { continue }
                item.source.pending.removeFirst(min(n, item.source.pending.count))
            }
            for source in rebuild.values { rebuildVisibleLocked(source) }
            evictLocked()
            if let allowance, storedSinceReview >= allowance.reviewEvery {
                storedSinceReview = 0
                review = true
            }
            lock.broadcast()
            lock.unlock()
            if review { reviewBudget() }
        }
    }

    /// Most deliveries one vectored write carries.
    private static let maxWriteRunEntries = 64

    /// Sizes the claim again from the free space now and evicts down to it. The disk can fill under
    /// a long session (another app, the segment caches), and a budget sized once at first use would
    /// go on claiming space that is no longer there. Free space no longer counts what this cache has
    /// written, so the claim adds it back (`RetentionClaims.Claim.resize`).
    func reviewBudget() {
        guard let allowance, let claim else { return }
        let free = allowance.freeSpace()
        let bytes = Int64(claim.resize(volumeAvailableBytes: free, sizing: allowance.sizing))
        lock.lock()
        let was = byteBudget
        byteBudget = bytes
        evictLocked()
        lock.unlock()
        if abs(bytes - was) >= Self.blockBytes * 16 {
            EngineLog.emit(
                "[SourceCache] budget \(Self.mb(was)) -> \(Self.mb(bytes)) "
                + "(volume free \(free.map(Self.mb) ?? "unknown"))", category: .demux)
        }
    }

    /// Blocks until the writes waiting in memory are back within their bound. A reader of `key`
    /// calls it before each request it sends, on its own thread: what the disk has not yet taken
    /// holds the next request back, so a link faster than the disk is slowed to it instead of the
    /// cache growing without end or throwing deliveries away. What a request already in flight
    /// delivers is kept whatever the queue holds.
    func waitForWriteRoom(for key: SourceCacheKey) {
        lock.lock()
        guard pendingWriteBytes > pendingWriteBound else { lock.unlock(); return }
        let began = DispatchTime.now().uptimeNanoseconds
        while pendingWriteBytes > pendingWriteBound { lock.wait() }
        let waited = DispatchTime.now().uptimeNanoseconds - began
        sources[key]?.writeWaitNanos += waited
        let first = !writeWaitLogged
        writeWaitLogged = true
        lock.unlock()
        if first {
            EngineLog.emit(
                "[SourceCache] \(key.display) write queue past \(pendingWriteBound >> 20) MB: requests wait for "
                + "the disk; the first waited \(waited / 1_000_000) ms", category: .demux)
        }
    }

    /// Whether a reader of `key` may send its next request now without `waitForWriteRoom` holding
    /// it. Never blocks.
    func hasWriteRoom(for key: SourceCacheKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pendingWriteBytes <= pendingWriteBound
    }

    /// The held bytes from `offset` on, up to `maxLength`, or nil when `offset` is not held or the
    /// cache knows the source under a different size than `expectedSize`. Stitched from what is
    /// pending (in memory) and what is on disk, so a run that crosses from one to the other is one
    /// read. Disk pages read back moments after they were written come out of the kernel's page
    /// cache, which is the memory tier: the cache keeps none of its own.
    func read(_ key: SourceCacheKey, at offset: Int64, maxLength: Int, expectedSize: Int64?) -> Data? {
        guard maxLength > 0, offset >= 0 else { return nil }
        enum Piece { case memory(Data), file(Int64, Int) }
        lock.lock()
        guard let source = servableLocked(key, expectedSize: expectedSize) else { lock.unlock(); return nil }
        var pieces: [Piece] = []
        var cursor = offset
        var remaining = maxLength
        while remaining > 0 {
            if let entry = source.pending.last(where: {
                $0.offset <= cursor && cursor < $0.offset + Int64($0.data.count)
            }) {
                let from = Int(cursor - entry.offset)
                let take = min(remaining, entry.data.count - from)
                // A slice shares the pending buffer; its bytes are copied once, into the result.
                let lower = entry.data.startIndex + from
                pieces.append(.memory(entry.data[lower..<(lower + take)]))
                cursor += Int64(take)
                remaining -= take
                continue
            }
            let onDisk = source.spans.contiguousLength(from: cursor)
            guard onDisk > 0 else { break }
            // Up to the next pending start at most: past it the pending bytes are the newer ones.
            let nextPending = source.pending.lazy.map(\.offset).filter { $0 > cursor }.min() ?? Int64.max
            let take = Int(min(Int64(remaining), onDisk, nextPending - cursor))
            pieces.append(.file(cursor, take))
            cursor += Int64(take)
            remaining -= take
        }
        let length = Int(cursor - offset)
        guard length > 0 else { lock.unlock(); return nil }
        let epoch = source.evictions
        touchLocked(source, start: offset, end: cursor)
        lock.unlock()

        // One buffer the result owns: each piece lands in place, read or copied exactly once.
        guard let buffer = malloc(length) else { return nil }
        var filled = 0
        var complete = true
        for piece in pieces {
            switch piece {
            case .memory(let bytes):
                bytes.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer + filled, count: bytes.count))
                filled += bytes.count
            case .file(let at, let count):
                var done = 0
                while done < count {
                    let n = pread(source.fd, buffer + filled + done, count - done, off_t(at) + off_t(done))
                    if n > 0 { done += n } else if n < 0, errno == EINTR { continue } else { complete = false; break }
                }
                filled += done
            }
            if !complete { break }
        }
        lock.lock()
        let valid = complete && source.evictions == epoch && sources[key] === source
        if valid { source.servedBytes += Int64(length) }
        lock.unlock()
        guard valid else {
            free(buffer)
            return nil
        }
        return Data(bytesNoCopy: buffer, count: length, deallocator: .free)
    }

    /// How many bytes from `offset` on are held for `url`, under the same size check `read` makes.
    func heldLength(_ key: SourceCacheKey, at offset: Int64, expectedSize: Int64?) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return servableLocked(key, expectedSize: expectedSize)?.visible.contiguousLength(from: offset) ?? 0
    }

    /// Where the next held span of at least `minLength` begins after `offset` and before `limit`.
    func nextHeldStart(_ key: SourceCacheKey, after offset: Int64, before limit: Int64,
                       minLength: Int64 = SourceByteCache.minimumServeBytes,
                       expectedSize: Int64?) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return servableLocked(key, expectedSize: expectedSize)?
            .visible.nextSpan(after: offset, before: limit, minLength: minLength)?.start
    }

    /// Returns once every write queued so far has landed, so the bytes are servable: a warm that
    /// reports itself done means a load right after it finds them.
    func flushWrites() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            writeQueue.async { done.resume() }
        }
    }

    /// Blocks until every write queued so far has landed. Tests only.
    func drainWritesForTesting() { writeQueue.sync {} }

    func heldBytesForTesting(_ key: SourceCacheKey) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return sources[key]?.spans.totalBytes ?? 0
    }

    var pendingWriteBytesForTesting: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingWriteBytes
    }

    var byteBudgetForTesting: Int64 {
        lock.lock(); defer { lock.unlock() }
        return byteBudget
    }

    func writeWaitNanosForTesting(_ key: SourceCacheKey) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return sources[key]?.writeWaitNanos ?? 0
    }

    fileprivate var heldBytesSnapshot: Int64 {
        lock.lock(); defer { lock.unlock() }
        return heldBytes
    }

    // MARK: - Books (callers hold `lock`)

    private func sourceLocked(_ key: SourceCacheKey, create: Bool) -> Source? {
        if let source = sources[key] { return source }
        guard create, ensureDirectoryLocked(), let source = Source(directory: directory) else { return nil }
        sources[key] = source
        return source
    }

    private func servableLocked(_ key: SourceCacheKey, expectedSize: Int64?) -> Source? {
        guard let source = sources[key] else { return nil }
        if let expectedSize, expectedSize > 0, let known = source.version.size, known != expectedSize {
            return nil
        }
        return source
    }

    private func ensureDirectoryLocked() -> Bool {
        if directoryReady { return true }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            directoryReady = true
        } catch {
            return false
        }
        return true
    }

    private func touchLocked(_ source: Source, start: Int64, end: Int64) {
        clock &+= 1
        var block = start / Self.blockBytes
        while block * Self.blockBytes < end {
            source.blockUse[block] = clock
            block += 1
        }
    }

    /// A source nobody has open goes after the grace, unless a reader comes back for it first.
    private func scheduleReleaseLocked(_ key: SourceCacheKey, _ source: Source) {
        guard source.openReaders == 0, source.release == nil else { return }
        let display = key.display
        let work = DispatchWorkItem { [weak self, weak source] in
            guard let self, let source else { return }
            self.lock.lock()
            guard self.sources[key] === source, source.openReaders == 0 else {
                self.lock.unlock()
                return
            }
            self.sources[key] = nil
            self.heldBytes -= source.spans.totalBytes
            let stored = source.storedBytes, served = source.servedBytes, waited = source.writeWaitNanos
            let passedOver = source.passedOverBytes
            let observers = self.releaseObservers
            self.lock.unlock()
            if stored > 0 || passedOver > 0 {
                EngineLog.emit(
                    "[SourceCache] \(display) released: stored \(Self.mb(stored)), "
                    + "served \(Self.mb(served)) back to readers"
                    + (passedOver > 0 ? ", passed over \(Self.mb(passedOver)) a lone reader streamed" : "")
                    + (waited > 0 ? ", requests waited \(waited / 1_000_000) ms for the disk" : ""),
                    category: .demux)
            }
            for observer in observers { observer(key) }
        }
        source.release = work
        releaseQueue.asyncAfter(deadline: .now() + releaseGrace, execute: work)
    }

    /// What is servable: on disk, and pending. Rebuilt when either side loses bytes (an eviction, a
    /// failed write); an insert only ever grows it, so a store extends it directly.
    private func rebuildVisibleLocked(_ source: Source) {
        var visible = source.spans
        for entry in source.pending {
            visible.insert(start: entry.offset, end: entry.offset + Int64(entry.data.count))
        }
        source.visible = visible
    }

    /// Least recently used blocks go, across every source, until the held bytes fit the budget.
    private func evictLocked() {
        while heldBytes > byteBudget {
            var victim: (source: Source, block: Int64, tick: UInt64)?
            for source in sources.values {
                for (block, tick) in source.blockUse where tick < (victim?.tick ?? .max) {
                    victim = (source, block, tick)
                }
            }
            guard let victim else { return }
            let start = victim.block * Self.blockBytes
            let before = victim.source.spans.totalBytes
            victim.source.spans.remove(start: start, end: start + Self.blockBytes)
            heldBytes -= before - victim.source.spans.totalBytes
            victim.source.blockUse[victim.block] = nil
            victim.source.evictions &+= 1
            rebuildVisibleLocked(victim.source)
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0,
                                    fp_offset: off_t(start), fp_length: off_t(Self.blockBytes))
            _ = fcntl(victim.source.fd, F_PUNCHHOLE, &hole)
        }
    }

    /// Writes `pieces` back to back from `offset`, as few `pwritev` calls as the kernel takes them in.
    private static func writeRun(_ fd: Int32, _ pieces: [Data], at offset: Int64) -> Bool {
        // Each piece's bytes stay pinned for the whole write by the nested closures.
        func write(_ index: Int, _ vectors: inout [iovec]) -> Bool {
            guard index < pieces.count else { return writeVectors(fd, &vectors, at: offset) }
            return pieces[index].withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress, raw.count > 0 else { return write(index + 1, &vectors) }
                vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base), iov_len: raw.count))
                return write(index + 1, &vectors)
            }
        }
        var vectors: [iovec] = []
        vectors.reserveCapacity(pieces.count)
        return write(0, &vectors)
    }

    private static func writeVectors(_ fd: Int32, _ vectors: inout [iovec], at offset: Int64) -> Bool {
        var position = off_t(offset)
        var first = 0
        while first < vectors.count {
            let n = vectors[first...].withUnsafeBufferPointer { buffer in
                pwritev(fd, buffer.baseAddress, Int32(buffer.count), position)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            position += off_t(n)
            var left = n
            while first < vectors.count, left >= vectors[first].iov_len {
                left -= vectors[first].iov_len
                first += 1
            }
            if left > 0 {
                vectors[first].iov_base = vectors[first].iov_base?.advanced(by: left)
                vectors[first].iov_len -= left
            }
        }
        return true
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
