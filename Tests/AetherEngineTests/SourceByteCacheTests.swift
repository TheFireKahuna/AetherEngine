import Foundation
import Testing
@testable import AetherEngine

/// The shared source cache: held spans, what it refuses to serve, eviction, and the readers on top.
@Suite("Source byte cache: a byte fetched once is served to every reader after")
struct SourceByteCacheTests {

    private static func freshCache(budget: Int64 = 64 << 20, grace: TimeInterval = 300) -> SourceByteCache {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SourceByteCache(directory: dir, budget: .fixed(budget), releaseGrace: grace)
    }

    private static func pattern(_ count: Int, seed: Int = 0) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ seed) })
    }

    private static let sourceURL = URL(string: "https://media.example.com/Videos/abc/stream.mkv?static=true&api_key=AAAA")!
    private static let source = SourceCacheKey(url: sourceURL, headers: ["User-Agent": "Sodalite"])

    private static func key(_ string: String) -> SourceCacheKey {
        SourceCacheKey(url: URL(string: string)!, headers: [:])
    }

    // MARK: Span set

    @Test("Removing a range splits the spans it straddles and leaves the rest")
    func removeSplitsStraddledSpans() {
        var spans = ByteSpanSet()
        spans.insert(start: 0, end: 100)
        spans.insert(start: 200, end: 300)
        spans.remove(start: 50, end: 250)
        #expect(spans.spans == [.init(start: 0, end: 50), .init(start: 250, end: 300)])
        spans.remove(start: 50, end: 250)
        #expect(spans.totalBytes == 100)
    }

    @Test("Contiguous length runs to the end of the covering span, zero in a gap")
    func contiguousLength() {
        var spans = ByteSpanSet()
        spans.insert(start: 10, end: 20)
        #expect(spans.contiguousLength(from: 10) == 10)
        #expect(spans.contiguousLength(from: 19) == 1)
        #expect(spans.contiguousLength(from: 20) == 0)
        #expect(spans.contiguousLength(from: 5) == 0)
    }

    @Test("The next span skips the one covering the offset and any too short to serve")
    func nextSpanSkipsCoveringAndShort() {
        var spans = ByteSpanSet()
        spans.insert(start: 0, end: 10)
        spans.insert(start: 20, end: 22)
        spans.insert(start: 40, end: 100)
        #expect(spans.nextSpan(after: 5, before: 1000)?.start == 20)
        #expect(spans.nextSpan(after: 5, before: 1000, minLength: 10)?.start == 40)
        #expect(spans.nextSpan(after: 5, before: 40, minLength: 10) == nil)
    }

    // MARK: The cache

    @Test("Stored bytes come back byte for byte to the same request, up to the held run")
    func storedBytesComeBack() throws {
        let cache = Self.freshCache()
        let data = Self.pattern(300_000)
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.store(data, at: 1_000_000, version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        let sameRequest = SourceCacheKey(url: Self.sourceURL, headers: ["User-Agent": "Sodalite"])
        let back = try #require(cache.read(sameRequest, at: 1_000_000, maxLength: 1 << 20, expectedSize: 10_000_000))
        #expect(back == data)
        let middle = try #require(cache.read(Self.source, at: 1_100_000, maxLength: 1000, expectedSize: 10_000_000))
        #expect(middle == data.subdata(in: 100_000..<101_000))
        #expect(cache.read(Self.source, at: 999_999, maxLength: 10, expectedSize: 10_000_000) == nil)
        #expect(cache.heldLength(Self.source, at: 1_000_000, expectedSize: 10_000_000) == 300_000)
    }

    /// The #551 rule for warms, applied to the cache: another token, user or header set may be
    /// answered with another body, so nothing crosses between them.
    @Test("Another token or header set is another entry: nothing crosses between them")
    func credentialsAndHeadersSeparateEntries() {
        let cache = Self.freshCache()
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.store(Self.pattern(1000), at: 0, version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        let otherToken = SourceCacheKey(
            url: URL(string: "https://media.example.com/Videos/abc/stream.mkv?static=true&api_key=BBBB")!,
            headers: ["User-Agent": "Sodalite"])
        let otherHeaders = SourceCacheKey(url: Self.sourceURL, headers: ["Authorization": "other"])
        #expect(cache.read(otherToken, at: 0, maxLength: 1000, expectedSize: 10_000_000) == nil)
        #expect(cache.read(otherHeaders, at: 0, maxLength: 1000, expectedSize: 10_000_000) == nil)
        #expect(!Self.source.id.contains("AAAA"))
        #expect(otherToken.display == Self.source.display)
    }

    /// Read-your-writes: a reader that fetched a block reads it straight back, before its write has
    /// landed, and a read across what is on disk and what is still pending comes back as one run.
    @Test("Stored bytes are servable at once, and a read stitches pending and written bytes")
    func storedBytesAreServableAtOnce() throws {
        let cache = Self.freshCache()
        let first = Self.pattern(100_000, seed: 3)
        let second = Self.pattern(50_000, seed: 4)
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.store(first, at: 0, version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        cache.store(second, at: 100_000, version: SourceVersion(), for: Self.source)
        // No drain: `second` may still be pending.
        #expect(cache.heldLength(Self.source, at: 0, expectedSize: 10_000_000) == 150_000)
        let whole = try #require(cache.read(Self.source, at: 50_000, maxLength: 100_000, expectedSize: 10_000_000))
        #expect(whole == first.subdata(in: 50_000..<100_000) + second)
        cache.drainWritesForTesting()
        #expect(try #require(cache.read(Self.source, at: 100_000, maxLength: 50_000, expectedSize: 10_000_000)) == second)
    }

    @Test("A reader that knows the source under another size is served nothing")
    func sizeMismatchIsNotServed() {
        let cache = Self.freshCache()
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.store(Self.pattern(1000), at: 0, version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        #expect(cache.read(Self.source, at: 0, maxLength: 1000, expectedSize: 9_999_999) == nil)
        #expect(cache.heldLength(Self.source, at: 0, expectedSize: 9_999_999) == 0)
    }

    @Test("A source whose size changes loses everything held for it")
    func sizeChangeDropsHeldBytes() {
        let cache = Self.freshCache()
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.store(Self.pattern(1000), at: 0, version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        cache.noteVersion(SourceVersion(size: 12_000_000), for: Self.source)
        #expect(cache.read(Self.source, at: 0, maxLength: 1000, expectedSize: 12_000_000) == nil)
        #expect(cache.heldBytesForTesting(Self.source) == 0)
    }

    // MARK: Which body

    @Test("Versions compare only what both sides state, and a response states its size and validators")
    func versionsCompareWhatBothState() throws {
        let v1 = SourceVersion(size: 100, etag: "\"v1\"")
        #expect(!v1.contradicts(SourceVersion(size: 100)))
        #expect(!v1.contradicts(SourceVersion(lastModified: "Tue, 01 Oct 2024 10:00:00 GMT")))
        #expect(v1.contradicts(SourceVersion(size: 100, etag: "\"v2\"")))
        #expect(v1.contradicts(SourceVersion(size: 101)))
        #expect(SourceVersion(lastModified: "a").contradicts(SourceVersion(etag: "x", lastModified: "b")))
        #expect(SourceVersion(size: 0, etag: "") == SourceVersion(), "no size and no validators say nothing")
        let http = try #require(HTTPURLResponse(
            url: URL(string: "https://media.example.com/a.mkv")!, statusCode: 206, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Range": "bytes 100-199/5000", "ETag": "W/\"abc\"",
                           "Last-Modified": "Tue, 01 Oct 2024 10:00:00 GMT"]))
        #expect(SourceVersion(http, requestedOffset: 100)
                == SourceVersion(size: 5000, etag: "W/\"abc\"", lastModified: "Tue, 01 Oct 2024 10:00:00 GMT"))
    }

    @Test("A response stating another ETag or Last-Modified drops what was held; the same body keeps it")
    func anotherBodyDropsHeldBytes() {
        let cache = Self.freshCache()
        let v1 = SourceVersion(size: 10_000_000, etag: "\"v1\"")
        cache.noteVersion(v1, for: Self.source)
        cache.store(Self.pattern(1000), at: 0, version: v1, for: Self.source)
        cache.drainWritesForTesting()
        // The same body, said again, or with a validator it had not stated before: nothing goes.
        cache.noteVersion(SourceVersion(size: 10_000_000), for: Self.source)
        cache.noteVersion(SourceVersion(size: 10_000_000, etag: "\"v1\"", lastModified: "Mon, 30 Sep 2024 08:00:00 GMT"),
                          for: Self.source)
        #expect(cache.heldBytesForTesting(Self.source) == 1000)
        #expect(cache.knownVersion(Self.source)?.lastModified == "Mon, 30 Sep 2024 08:00:00 GMT")
        // Last-Modified alone says it is another body.
        cache.noteVersion(SourceVersion(size: 10_000_000, lastModified: "Tue, 01 Oct 2024 10:00:00 GMT"), for: Self.source)
        #expect(cache.heldBytesForTesting(Self.source) == 0)
        #expect(cache.read(Self.source, at: 0, maxLength: 1000, expectedSize: 10_000_000) == nil)
        let v2 = SourceVersion(size: 10_000_000, etag: "\"v2\"")
        cache.store(Self.pattern(1000), at: 0, version: v2, for: Self.source)
        cache.drainWritesForTesting()
        cache.noteVersion(SourceVersion(size: 10_000_000, etag: "\"v3\""), for: Self.source)
        #expect(cache.heldBytesForTesting(Self.source) == 0)
    }

    /// A connection answered before the file was replaced goes on delivering the old body after a
    /// newer response has said the new one.
    @Test("A delivery from another body than the recorded one is not kept")
    func staleDeliveryIsNotKept() {
        let cache = Self.freshCache()
        let v2 = SourceVersion(size: 10_000_000, etag: "\"v2\"")
        cache.noteVersion(v2, for: Self.source)
        cache.store(Self.pattern(1000), at: 0, version: SourceVersion(size: 10_000_000, etag: "\"v1\""),
                    for: Self.source)
        cache.drainWritesForTesting()
        #expect(cache.heldLength(Self.source, at: 0, expectedSize: 10_000_000) == 0)
        cache.store(Self.pattern(1000), at: 0, version: v2, for: Self.source)
        cache.store(Self.pattern(1000), at: 1000, version: SourceVersion(size: 10_000_000), for: Self.source)
        cache.drainWritesForTesting()
        #expect(cache.heldBytesForTesting(Self.source) == 2000)
    }

    // MARK: The write queue

    @Test("Writes past the pending bound are all kept, and a request waits until the disk has caught up",
          .timeLimit(.minutes(1)))
    func writesPastTheBoundAreKept() {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-cache-bound-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = SourceByteCache(directory: dir, budget: .fixed(256 << 20), pendingWriteBound: 1 << 20,
                                    removesDirectory: true)
        cache.readerOpened(Self.source, streams: true)
        cache.noteVersion(SourceVersion(size: 64 << 20), for: Self.source)
        // Faster than any disk: 32 MB stored back to back, as deliveries outrunning the writes.
        let piece = Self.pattern(64 << 10)
        for n in 0..<512 {
            cache.store(piece, at: Int64(n) * Int64(piece.count), version: SourceVersion(), for: Self.source)
        }
        #expect(cache.pendingWriteBytesForTesting > 1 << 20)
        cache.waitForWriteRoom(for: Self.source)
        #expect(cache.pendingWriteBytesForTesting <= 1 << 20)
        #expect(cache.writeWaitNanosForTesting(Self.source) > 0)
        cache.drainWritesForTesting()
        #expect(cache.heldBytesForTesting(Self.source) == 32 << 20)
        // Within the bound, a request goes out at once.
        cache.waitForWriteRoom(for: Self.source)
    }

    // MARK: The budget

    private final class FreeSpace: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: Int64
        init(_ bytes: Int64) { self.bytes = bytes }
        var value: Int64 { get { lock.withLock { bytes } } set { lock.withLock { bytes = newValue } } }
    }

    @Test("The budget is sized again as the cache writes, and a fuller disk evicts down to it")
    func budgetFollowsTheFreeSpace() {
        let block = SourceByteCache.blockBytes
        let free = FreeSpace(32 * block)
        let ledger = RetentionClaims()
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-cache-budget-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = SourceByteCache(
            directory: dir,
            budget: .claimed(.init(claims: ledger, freeSpace: { free.value }, sizing: { Int(($0 ?? 0) / 4) },
                                   reviewEvery: 4 * block)),
            removesDirectory: true)
        #expect(cache.byteBudgetForTesting == 8 * block)
        cache.readerOpened(Self.source, streams: true)
        cache.noteVersion(SourceVersion(size: 64 * block), for: Self.source)
        for n in 0..<3 {
            cache.store(Self.pattern(Int(block), seed: n), at: Int64(n) * block, version: SourceVersion(), for: Self.source)
        }
        cache.drainWritesForTesting()
        #expect(cache.heldBytesForTesting(Self.source) == 3 * block)

        // The disk filled under the session: 5 blocks free besides the 3 this cache wrote.
        free.value = 5 * block
        cache.reviewBudget()
        #expect(cache.byteBudgetForTesting == 2 * block)
        #expect(cache.heldBytesForTesting(Self.source) == 2 * block)

        // Room again: the next writes size the claim up without being asked. The first of them lands
        // under the old budget (and evicts one block) and is the one that reviews it.
        free.value = 400 * block
        for n in 3..<7 {
            cache.store(Self.pattern(Int(block), seed: n), at: Int64(n) * block, version: SourceVersion(), for: Self.source)
        }
        cache.drainWritesForTesting()
        #expect(cache.byteBudgetForTesting >= 100 * block)
        #expect(cache.heldBytesForTesting(Self.source) == 5 * block)
    }

    @Test("Past the budget the least recently used block goes, and its range reads as not held")
    func evictionDropsLeastRecentBlock() throws {
        let block = Int(SourceByteCache.blockBytes)
        let cache = Self.freshCache(budget: Int64(2 * block))
        cache.noteVersion(SourceVersion(size: Int64(8 * block)), for: Self.source)
        cache.store(Self.pattern(block, seed: 1), at: 0, version: SourceVersion(), for: Self.source)
        cache.store(Self.pattern(block, seed: 2), at: Int64(block), version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        // Block 0 is read, so block 1 is now the least recently used one.
        _ = cache.read(Self.source, at: 0, maxLength: 16, expectedSize: Int64(8 * block))
        cache.store(Self.pattern(block, seed: 3), at: Int64(2 * block), version: SourceVersion(), for: Self.source)
        cache.drainWritesForTesting()
        #expect(cache.heldBytesForTesting(Self.source) == Int64(2 * block))
        #expect(cache.heldLength(Self.source, at: Int64(block), expectedSize: Int64(8 * block)) == 0)
        let kept = try #require(cache.read(Self.source, at: 0, maxLength: block, expectedSize: Int64(8 * block)))
        #expect(kept == Self.pattern(block, seed: 1))
    }

    @Test("A source goes after its grace once its last reader closes, and a returning reader keeps it")
    func releaseFollowsTheGrace() async throws {
        let cache = Self.freshCache(grace: 0.2)
        let kept = Self.key("https://media.example.com/kept")
        let gone = Self.key("https://media.example.com/gone")
        for url in [kept, gone] {
            cache.readerOpened(url, streams: true)
            cache.store(Self.pattern(100), at: 0, version: SourceVersion(), for: url)
        }
        cache.drainWritesForTesting()
        cache.readerClosed(kept, streams: true)
        cache.readerClosed(gone, streams: true)
        cache.readerOpened(kept, streams: true)
        try await Task.sleep(for: .milliseconds(600))
        #expect(cache.heldBytesForTesting(kept) == 100)
        #expect(cache.heldBytesForTesting(gone) == 0)
    }

    /// `AetherEngine.discardPrewarmedSources`: a host leaving the context its warms were made for
    /// lets them go now, while a source a session is reading stays.
    @Test("Releasing idle sources drops what no reader has open and keeps what one does")
    func releaseIdleKeepsOpenSources() {
        let cache = Self.freshCache()
        let warmed = Self.key("https://media.example.com/warmed")
        let playing = Self.key("https://media.example.com/playing")
        cache.store(Self.pattern(100), at: 0, version: SourceVersion(), for: warmed)
        cache.readerOpened(playing, streams: true)
        cache.store(Self.pattern(100), at: 0, version: SourceVersion(), for: playing)
        cache.noteResolvedURL(URL(string: "https://edge.example.com/warmed"), for: warmed)
        cache.drainWritesForTesting()
        cache.releaseIdleSources()
        #expect(cache.heldBytesForTesting(warmed) == 0)
        #expect(cache.resolvedURL(for: warmed) == nil)
        #expect(cache.heldBytesForTesting(playing) == 100)
    }

    @Test("A lone reader's stream is kept near either end and passed over in the middle")
    func loneStreamKeepsOnlyTheEdges() {
        let cache = Self.freshCache(budget: 1 << 30)
        let size: Int64 = 1 << 30
        let edge = SourceByteCache.streamEdgeBytes
        cache.readerOpened(Self.source, streams: true)
        cache.noteVersion(SourceVersion(size: size), for: Self.source)
        let chunk = Self.pattern(1000)
        for offset in [0, edge - 1, size / 2, edge + 999, size - edge - 1000, size - edge - 999] {
            cache.store(chunk, at: offset, version: SourceVersion(), for: Self.source, retention: .streamed)
        }
        cache.drainWritesForTesting()
        #expect(cache.heldLength(Self.source, at: 0, expectedSize: size) == 1000)
        #expect(cache.heldLength(Self.source, at: edge - 1, expectedSize: size) == 1000)
        #expect(cache.heldLength(Self.source, at: size / 2, expectedSize: size) == 0)
        #expect(cache.heldLength(Self.source, at: edge + 999, expectedSize: size) == 0)
        #expect(cache.heldLength(Self.source, at: size - edge - 1000, expectedSize: size) == 0)
        #expect(cache.heldLength(Self.source, at: size - edge - 999, expectedSize: size) == 1000)
    }

    @Test("Bytes asked for by position are kept wherever they are, and a stream of unknown size is kept")
    func positionalAndUnsizedAreKept() {
        let cache = Self.freshCache(budget: 1 << 30)
        let sized = Self.key("https://media.example.com/sized")
        let unsized = Self.key("https://media.example.com/unsized")
        let middle: Int64 = 512 << 20
        cache.readerOpened(sized, streams: true)
        cache.readerOpened(unsized, streams: true)
        cache.noteVersion(SourceVersion(size: 1 << 30), for: sized)
        cache.store(Self.pattern(1000), at: middle, version: SourceVersion(), for: sized)
        cache.store(Self.pattern(1000), at: middle, version: SourceVersion(), for: unsized, retention: .streamed)
        cache.drainWritesForTesting()
        #expect(cache.heldLength(sized, at: middle, expectedSize: 1 << 30) == 1000)
        #expect(cache.heldLength(unsized, at: middle, expectedSize: nil) == 1000)
    }

    @Test("A stream is kept while another reader of the source is open, and passed over once it closes")
    func streamIsKeptWhileShared() {
        let cache = Self.freshCache(budget: 1 << 30)
        let size: Int64 = 1 << 30
        let middle: Int64 = 512 << 20
        cache.readerOpened(Self.source, streams: true)
        cache.readerOpened(Self.source, streams: true)
        cache.noteVersion(SourceVersion(size: size), for: Self.source)
        cache.store(Self.pattern(1000), at: middle, version: SourceVersion(), for: Self.source, retention: .streamed)
        cache.readerClosed(Self.source, streams: true)
        cache.store(Self.pattern(1000), at: middle + 1000, version: SourceVersion(), for: Self.source, retention: .streamed)
        cache.drainWritesForTesting()
        #expect(cache.heldLength(Self.source, at: middle, expectedSize: size) == 1000)
        #expect(cache.heldLength(Self.source, at: middle + 1000, expectedSize: size) == 0)
    }

    @Test("A redirect target is kept per source and forgotten only while it is still the recorded one")
    func resolvedTargetIsForgottenOnlyIfCurrent() throws {
        let cache = Self.freshCache()
        let edgeA = try #require(URL(string: "https://edge-a.example.com/x"))
        let edgeB = try #require(URL(string: "https://edge-b.example.com/x"))
        cache.noteResolvedURL(edgeA, for: Self.source)
        cache.noteResolvedURL(edgeB, for: Self.source)
        cache.forgetResolvedURL(edgeA, for: Self.source)
        #expect(cache.resolvedURL(for: Self.source) == edgeB)
        cache.forgetResolvedURL(edgeB, for: Self.source)
        #expect(cache.resolvedURL(for: Self.source) == nil)
    }

    // MARK: Through the reader

    /// Reads all of `url` through a real AVIOReader and returns the bytes.
    private static func readAll(_ url: URL, label: String, size: Int, prefetch: Bool) throws -> Data {
        let reader = AVIOReader(url: url, label: label, prefetchEnabled: prefetch, sourceCache: .shared)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        var out = Data()
        while out.count < size {
            let n = reader.read(into: buf, size: Int32(64 * 1024))
            if n <= 0 { break }
            out.append(buf, count: Int(n))
        }
        return out
    }

    @Test("A second reader of a source is served from the cache, not the origin",
          .timeLimit(.minutes(1)), arguments: [false, true])
    func secondReaderIsServedFromTheCache(persistent: Bool) throws {
        let size = 3 * 1024 * 1024 + 12_345
        let body = Self.pattern(size, seed: persistent ? 7 : 9)
        let origin = try #require(KeepAliveRangeOrigin(data: body))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/cache-\(UUID().uuidString).bin")!
        let hold = AVIOReader(url: url, label: "hold", prefetchEnabled: false, sourceCache: .shared)
        defer { hold.close() }

        #expect(try Self.readAll(url, label: "first", size: size, prefetch: persistent) == body)
        SourceByteCache.shared.drainWritesForTesting()
        #expect(try Self.readAll(url, label: "second", size: size, prefetch: persistent) == body)

        let books = try #require(SourceByteLedger.shared.snapshot(.init(url)))
        let second = books.byReader["second"] ?? .init()
        #expect(second.fromCache >= Int64(size) - 64 * 1024)
        #expect(second.duplicate == 0)
        #expect(books.duplicate == 0)
    }

    @Test("The pump fetches around a held span in the middle, and the bytes it plays are intact",
          .timeLimit(.minutes(1)))
    func pumpSplitsItsRangeAroundAHeldSpan() throws {
        let size = 6 * 1024 * 1024
        let body = Self.pattern(size, seed: 11)
        let origin = try #require(KeepAliveRangeOrigin(data: body))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/split-\(UUID().uuidString).bin")!
        let hold = AVIOReader(url: url, label: "hold", prefetchEnabled: false, sourceCache: .shared)
        defer { hold.close() }

        let held = 2 * 1024 * 1024 ..< 3 * 1024 * 1024
        let key = SourceCacheKey(url: url, headers: [:])
        SourceByteCache.shared.noteVersion(SourceVersion(size: Int64(size)), for: key)
        SourceByteCache.shared.store(body.subdata(in: held), at: Int64(held.lowerBound), version: SourceVersion(), for: key)
        SourceByteCache.shared.drainWritesForTesting()

        #expect(try Self.readAll(url, label: "pump", size: size, prefetch: true) == body)
        let books = try #require(SourceByteLedger.shared.snapshot(.init(url)))
        let pump = books.byReader["pump"] ?? .init()
        #expect(pump.fromCache >= Int64(held.count))
        #expect(pump.duplicate == 0)
        #expect(pump.fetched <= Int64(size - held.count))
    }

    /// The whole pump through a real reader: alone, it keeps the head and the end and passes over the
    /// middle; beside another reader of the source, it keeps everything. The edge is sized to the file.
    /// Who else reads the source while the pump plays it.
    enum Beside: CaseIterable, Sendable { case nobody, aStream, exactRanges }

    @Test("A lone pump keeps only the ends of what it streams; beside another stream it keeps it all, beside a reader of exact ranges only the ends",
          .timeLimit(.minutes(1)), arguments: Beside.allCases)
    func pumpKeepsTheMiddleOnlyWhenShared(beside: Beside) throws {
        let size = 6 * 1024 * 1024
        let edge: Int64 = 1024 * 1024
        let body = Self.pattern(size, seed: beside == .aStream ? 13 : 17)
        let origin = try #require(KeepAliveRangeOrigin(data: body))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/edges-\(UUID().uuidString).bin")!
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let cache = SourceByteCache(directory: dir, budget: .fixed(64 << 20), streamEdge: edge)
        // A subtitle pull's reader asks for its frames by position, so it is no reason to keep the stream.
        let streamHold = beside == .aStream
            ? AVIOReader(url: url, label: "hold", prefetchEnabled: false, sourceCache: cache) : nil
        defer { streamHold?.close() }
        let rangeHold = beside == .exactRanges
            ? try #require(HTTPDiscIOReader(url: url, extraHeaders: [:], sourceCache: cache, label: "subpull")) : nil
        defer { rangeHold?.close() }

        let reader = AVIOReader(url: url, label: "pump", prefetchEnabled: true, sourceCache: cache)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }
        var played = Data()
        while played.count < size {
            let n = reader.read(into: buf, size: Int32(64 * 1024))
            if n <= 0 { break }
            played.append(buf, count: Int(n))
        }
        #expect(played == body)
        cache.drainWritesForTesting()

        let key = SourceCacheKey(url: url, headers: [:])
        let total = Int64(size)
        #expect(cache.heldLength(key, at: 0, expectedSize: total) >= edge)
        #expect(cache.heldLength(key, at: total - edge, expectedSize: total) == edge)
        let middle = cache.heldLength(key, at: total / 2, expectedSize: total)
        if beside == .aStream {
            #expect(middle > 0)
        } else {
            #expect(middle == 0)
        }
    }

    /// A file replaced behind the same URL at the same size: the held span the pump would replay
    /// from disk is the old body, and the first response's `ETag` says so before it is read.
    @Test("The pump does not replay a held span of a replaced file", .timeLimit(.minutes(1)))
    func pumpDoesNotReplayAReplacedFile() throws {
        let size = 6 * 1024 * 1024
        let old = Self.pattern(size, seed: 31)
        let new = Self.pattern(size, seed: 32)
        let origin = try #require(KeepAliveRangeOrigin(data: new, etag: "\"v2\""))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/replaced-\(UUID().uuidString).bin")!
        let hold = AVIOReader(url: url, label: "hold", prefetchEnabled: false, sourceCache: .shared)
        defer { hold.close() }

        let held = 2 * 1024 * 1024 ..< 3 * 1024 * 1024
        let key = SourceCacheKey(url: url, headers: [:])
        let before = SourceVersion(size: Int64(size), etag: "\"v1\"")
        SourceByteCache.shared.noteVersion(before, for: key)
        SourceByteCache.shared.store(old.subdata(in: held), at: Int64(held.lowerBound), version: before, for: key)
        SourceByteCache.shared.drainWritesForTesting()

        #expect(try Self.readAll(url, label: "pump", size: size, prefetch: true) == new)
        #expect(SourceByteCache.shared.knownVersion(key)?.etag == "\"v2\"")
    }

    // MARK: Exact ranges

    /// The indexed subtitle fill asks for a block's few hundred bytes. It used to be charged a 64 KB
    /// read-ahead window per block (interleaved video), and a reader, session and connection per lane.
    @Test("A range read fetches exactly the gap, serves the rest from the cache, and lanes share one reader",
          .timeLimit(.minutes(1)))
    func rangeReadsAreExact() throws {
        let size = 2 * 1024 * 1024
        let body = Self.pattern(size, seed: 5)
        let origin = try #require(KeepAliveRangeOrigin(data: body))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/exact-\(UUID().uuidString).mkv")!
        let cache = Self.freshCache()
        let reader = try #require(HTTPDiscIOReader(url: url, sourceCache: cache, label: "subindex"))
        defer { reader.close() }

        #expect(reader.readRange(at: 1000, count: 568) == body.subdata(in: 1000..<1568))
        cache.drainWritesForTesting()
        #expect(reader.readRange(at: 1200, count: 600) == body.subdata(in: 1200..<1800))
        let books = try #require(SourceByteLedger.shared.snapshot(.init(url)))
        let lane = books.byReader["subindex"] ?? .init()
        #expect(lane.fetched == 568 + 232)
        #expect(lane.fromCache == 368)
        #expect(lane.duplicate == 0)
        #expect(reader.readRange(at: Int64(size) - 10, count: 100) == body.subdata(in: (size - 10)..<size))

        let source = IOReaderByteSource(reader, closesReader: false)
        #expect(source.isConcurrent)
        var results = [[UInt8]?](repeating: nil, count: 12)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: 12) { lane in
            let got = source.read(at: Int64(100_000 + lane * 10_000), count: 700)
            lock.lock(); results[lane] = got; lock.unlock()
        }
        for lane in 0..<12 {
            let at = 100_000 + lane * 10_000
            #expect(results[lane] == [UInt8](body.subdata(in: at..<(at + 700))))
        }
    }

    /// A reader that opens on the size the cache knows asks the origin nothing, so it reads what the
    /// cache holds until its first response; from that response on, the old body is gone.
    @Test("A range reader's first response after a replacement drops the old body", .timeLimit(.minutes(1)))
    func rangeReaderDropsAReplacedFile() throws {
        let size = 2 * 1024 * 1024
        let old = Self.pattern(size, seed: 41)
        let new = Self.pattern(size, seed: 42)
        let origin = try #require(KeepAliveRangeOrigin(data: old, etag: "\"v1\""))
        defer { origin.stop() }
        let url = URL(string: "http://127.0.0.1:\(origin.port)/replaced-\(UUID().uuidString).mkv")!
        let cache = Self.freshCache()
        let first = try #require(HTTPDiscIOReader(url: url, sourceCache: cache, label: "first"))
        #expect(first.readRange(at: 1000, count: 4096) == old.subdata(in: 1000..<5096))
        cache.drainWritesForTesting()
        #expect(cache.knownVersion(SourceCacheKey(url: url, headers: [:]))?.etag == "\"v1\"")

        origin.replace(with: new, etag: "\"v2\"")
        let second = try #require(HTTPDiscIOReader(url: url, sourceCache: cache, label: "second"))
        defer { second.close() }
        first.close()
        #expect(second.readRange(at: 100_000, count: 4096) == new.subdata(in: 100_000..<104_096))
        #expect(second.readRange(at: 1000, count: 4096) == new.subdata(in: 1000..<5096))
    }
}
