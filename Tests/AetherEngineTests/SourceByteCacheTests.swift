import Foundation
import Testing
@testable import AetherEngine

/// The shared source cache: held spans, what it refuses to serve, eviction, and the readers on top.
@Suite("Source byte cache: a byte fetched once is served to every reader after")
struct SourceByteCacheTests {

    private static func freshCache(budget: Int64 = 64 << 20, grace: TimeInterval = 300) -> SourceByteCache {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "source-cache-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        return SourceByteCache(directory: dir, byteBudget: budget, releaseGrace: grace)
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
        cache.noteTotalSize(10_000_000, for: Self.source)
        cache.store(data, at: 1_000_000, for: Self.source)
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
        cache.noteTotalSize(10_000_000, for: Self.source)
        cache.store(Self.pattern(1000), at: 0, for: Self.source)
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

    @Test("A reader that knows the source under another size is served nothing")
    func sizeMismatchIsNotServed() {
        let cache = Self.freshCache()
        cache.noteTotalSize(10_000_000, for: Self.source)
        cache.store(Self.pattern(1000), at: 0, for: Self.source)
        cache.drainWritesForTesting()
        #expect(cache.read(Self.source, at: 0, maxLength: 1000, expectedSize: 9_999_999) == nil)
        #expect(cache.heldLength(Self.source, at: 0, expectedSize: 9_999_999) == 0)
    }

    @Test("A source whose size changes loses everything held for it")
    func sizeChangeDropsHeldBytes() {
        let cache = Self.freshCache()
        cache.noteTotalSize(10_000_000, for: Self.source)
        cache.store(Self.pattern(1000), at: 0, for: Self.source)
        cache.drainWritesForTesting()
        cache.noteTotalSize(12_000_000, for: Self.source)
        #expect(cache.read(Self.source, at: 0, maxLength: 1000, expectedSize: 12_000_000) == nil)
        #expect(cache.heldBytesForTesting(Self.source) == 0)
    }

    @Test("Past the budget the least recently used block goes, and its range reads as not held")
    func evictionDropsLeastRecentBlock() throws {
        let block = Int(SourceByteCache.blockBytes)
        let cache = Self.freshCache(budget: Int64(2 * block))
        cache.noteTotalSize(Int64(8 * block), for: Self.source)
        cache.store(Self.pattern(block, seed: 1), at: 0, for: Self.source)
        cache.store(Self.pattern(block, seed: 2), at: Int64(block), for: Self.source)
        cache.drainWritesForTesting()
        // Block 0 is read, so block 1 is now the least recently used one.
        _ = cache.read(Self.source, at: 0, maxLength: 16, expectedSize: Int64(8 * block))
        cache.store(Self.pattern(block, seed: 3), at: Int64(2 * block), for: Self.source)
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
            cache.readerOpened(url)
            cache.store(Self.pattern(100), at: 0, for: url)
        }
        cache.drainWritesForTesting()
        cache.readerClosed(kept)
        cache.readerClosed(gone)
        cache.readerOpened(kept)
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
        cache.store(Self.pattern(100), at: 0, for: warmed)
        cache.readerOpened(playing)
        cache.store(Self.pattern(100), at: 0, for: playing)
        cache.noteResolvedURL(URL(string: "https://edge.example.com/warmed"), for: warmed)
        cache.drainWritesForTesting()
        cache.releaseIdleSources()
        #expect(cache.heldBytesForTesting(warmed) == 0)
        #expect(cache.resolvedURL(for: warmed) == nil)
        #expect(cache.heldBytesForTesting(playing) == 100)
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

        let books = try #require(SourceByteLedger.shared.snapshot(url))
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
        SourceByteCache.shared.noteTotalSize(Int64(size), for: key)
        SourceByteCache.shared.store(body.subdata(in: held), at: Int64(held.lowerBound), for: key)
        SourceByteCache.shared.drainWritesForTesting()

        #expect(try Self.readAll(url, label: "pump", size: size, prefetch: true) == body)
        let books = try #require(SourceByteLedger.shared.snapshot(url))
        let pump = books.byReader["pump"] ?? .init()
        #expect(pump.fromCache >= Int64(held.count))
        #expect(pump.duplicate == 0)
        #expect(pump.fetched <= Int64(size - held.count))
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
        let books = try #require(SourceByteLedger.shared.snapshot(url))
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
}
