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
/// promise each other the same free space.
///
/// A source is a `SourceCacheKey`: the credential-free URL plus a digest of how it is asked for, so
/// bytes cross between readers of one session and never between users. Bytes are served only to a
/// reader whose idea of the total size matches the size the cache recorded, and a size that changes
/// drops what was held: the same request answering with a different length is a different body.
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
    /// Bytes that may wait in memory for their write. Past it new writes are dropped (and fetched
    /// again if needed): the cache must never become the thing that holds a gigabyte of RAM.
    static let maxPendingWriteBytes = 64 << 20
    /// Most the shared cache claims, whatever the volume has free.
    static let budgetCeilingBytes: Int64 = 4 << 30

    private final class Source: @unchecked Sendable {
        let fd: Int32
        let path: String
        /// What is on disk.
        var spans = ByteSpanSet()
        /// Stored and not yet written, readable all the same: a reader that fetched a block must be
        /// able to read it straight back, or the write's latency would be a window in which the next
        /// reader fetches it again.
        var pending: [(id: UInt64, offset: Int64, data: Data)] = []
        /// What a read can be served from: on disk or pending.
        var visible = ByteSpanSet()
        /// Block index to the tick it was last written or read.
        var blockUse: [Int64: UInt64] = [:]
        var totalSize: Int64?
        /// Where the source's bytes were actually served from, redirects followed (#551 round 2):
        /// a reader that pins it does not pay the resolver's 302 again.
        var resolvedURL: URL?
        var openReaders = 0
        /// Bumped by every eviction, so a read that raced one is discarded instead of returning a
        /// punched hole's zeros.
        var evictions: UInt64 = 0
        var release: DispatchWorkItem?
        var servedBytes: Int64 = 0
        var storedBytes: Int64 = 0

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
    private let byteBudget: Int64
    private let releaseGrace: TimeInterval
    private let claim: RetentionClaims.Claim?
    private let lock = NSLock()
    private var sources: [SourceCacheKey: Source] = [:]
    private var heldBytes: Int64 = 0
    private var pendingWriteBytes = 0
    private var nextPendingID: UInt64 = 0
    private var clock: UInt64 = 0
    private var droppedWriteLogged = false
    private var directoryReady = false
    private let writeQueue = DispatchQueue(label: "aether.source-cache.write", qos: .utility)
    private let releaseQueue = DispatchQueue(label: "aether.source-cache.release", qos: .utility)

    /// The shared cache: the engine's own directory, emptied of whatever an earlier process left, and
    /// a budget claimed beside the segment caches'.
    private convenience init() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "aether-source-cache", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: directory)
        let claim = RetentionClaims.shared.claim(
            volumeAvailableBytes: RetentionClaims.tmpVolumeAvailableBytes()
        ) { left in
            Int(min(Self.budgetCeilingBytes, (left ?? Self.budgetCeilingBytes) / 4))
        }
        self.init(directory: directory, byteBudget: Int64(claim.bytes), claim: claim)
    }

    init(directory: URL, byteBudget: Int64, claim: RetentionClaims.Claim? = nil,
         releaseGrace: TimeInterval = SourceByteCache.releaseGraceSeconds, removesDirectory: Bool = false) {
        self.directory = directory
        self.removesDirectory = removesDirectory
        self.byteBudget = max(0, byteBudget)
        self.releaseGrace = releaseGrace
        self.claim = claim
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
            byteBudget: scopedBudgetBytes, releaseGrace: 0, removesDirectory: true)
    }

    static let scopedBudgetBytes: Int64 = 64 << 20

    deinit {
        if removesDirectory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Lifetime

    func readerOpened(_ key: SourceCacheKey) {
        lock.lock(); defer { lock.unlock() }
        guard let source = sourceLocked(key, create: true) else { return }
        source.openReaders += 1
        source.release?.cancel()
        source.release = nil
    }

    func readerClosed(_ key: SourceCacheKey) {
        lock.lock(); defer { lock.unlock() }
        guard let source = sources[key] else { return }
        source.openReaders = max(0, source.openReaders - 1)
        scheduleReleaseLocked(key, source)
    }

    /// The total size a reader learned for `url`. A different size from the one recorded means a
    /// different body behind the same URL, and everything held for it goes.
    func noteTotalSize(_ size: Int64, for key: SourceCacheKey) {
        guard size > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard let source = sourceLocked(key, create: true) else { return }
        if let known = source.totalSize, known != size {
                heldBytes -= source.spans.totalBytes
            guard let fresh = Source(directory: directory) else { sources[key] = nil; return }
            fresh.totalSize = size
            fresh.openReaders = source.openReaders
            source.release?.cancel()
            sources[key] = fresh
            scheduleReleaseLocked(key, fresh)
            EngineLog.emit(
                "[SourceCache] \(key.display) changed size \(known) -> \(size); "
                + "dropped what was held for it", category: .demux)
            return
        }
        source.totalSize = size
        scheduleReleaseLocked(key, source)
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
        lock.lock(); defer { lock.unlock() }
        for (key, source) in sources where source.openReaders == 0 {
            source.release?.cancel()
            heldBytes -= source.spans.totalBytes
            sources[key] = nil
        }
    }

    /// The total size recorded for `url`, whichever reader learned it and under whichever token.
    func knownSize(_ key: SourceCacheKey) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return sources[key]?.totalSize
    }

    // MARK: - Bytes

    /// Keeps `data`, which a reader fetched for `url` at `offset`. Servable from the moment it is
    /// stored (out of memory until its write lands); a write that would grow the queue past its bound
    /// is dropped instead.
    func store(_ data: Data, at offset: Int64, for key: SourceCacheKey) {
        guard !data.isEmpty, offset >= 0, byteBudget > 0 else { return }
        lock.lock()
        guard let source = sourceLocked(key, create: true) else { lock.unlock(); return }
        guard pendingWriteBytes + data.count <= Self.maxPendingWriteBytes else {
            let first = !droppedWriteLogged
            droppedWriteLogged = true
            lock.unlock()
            if first {
                EngineLog.emit(
                    "[SourceCache] write queue full (\(Self.maxPendingWriteBytes >> 20) MB pending); "
                    + "dropping writes until it drains", category: .demux)
            }
            return
        }
        pendingWriteBytes += data.count
        nextPendingID &+= 1
        let id = nextPendingID
        source.pending.append((id, offset, data))
        source.visible.insert(start: offset, end: offset + Int64(data.count))
        scheduleReleaseLocked(key, source)
        lock.unlock()

        writeQueue.async { [self] in
            let written = Self.writeAll(source.fd, data, at: offset)
            lock.lock()
            defer { lock.unlock() }
            pendingWriteBytes -= data.count
            source.pending.removeAll { $0.id == id }
            guard written, sources[key] === source else {
                rebuildVisibleLocked(source)
                return
            }
            let added = source.spans.insert(start: offset, end: offset + Int64(data.count))
            heldBytes += added
            source.storedBytes += added
            touchLocked(source, start: offset, end: offset + Int64(data.count))
            evictLocked()
        }
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
                pieces.append(.memory(entry.data.subdata(in: from..<(from + take))))
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

        var data = Data(capacity: length)
        var complete = true
        for piece in pieces {
            switch piece {
            case .memory(let bytes):
                data.append(bytes)
            case .file(let at, let count):
                var chunk = Data(count: count)
                let read = chunk.withUnsafeMutableBytes { raw -> Bool in
                    guard let base = raw.baseAddress else { return false }
                    var done = 0
                    while done < count {
                        let n = pread(source.fd, base + done, count - done, off_t(at) + off_t(done))
                        if n > 0 { done += n } else if n < 0, errno == EINTR { continue } else { return false }
                    }
                    return true
                }
                guard read else { complete = false; break }
                data.append(chunk)
            }
            if !complete { break }
        }
        lock.lock()
        let valid = complete && source.evictions == epoch && sources[key] === source
        if valid { source.servedBytes += Int64(length) }
        lock.unlock()
        return valid ? data : nil
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
        if let expectedSize, expectedSize > 0, let known = source.totalSize, known != expectedSize {
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
            let stored = source.storedBytes, served = source.servedBytes
            self.lock.unlock()
            if stored > 0 {
                EngineLog.emit(
                    "[SourceCache] \(display) released: stored \(Self.mb(stored)), "
                    + "served \(Self.mb(served)) back to readers", category: .demux)
            }
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

    private static func writeAll(_ fd: Int32, _ data: Data, at offset: Int64) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var done = 0
            while done < raw.count {
                let n = pwrite(fd, base + done, raw.count - done, off_t(offset) + off_t(done))
                if n > 0 { done += n } else if n < 0, errno == EINTR { continue } else { return false }
            }
            return true
        }
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
