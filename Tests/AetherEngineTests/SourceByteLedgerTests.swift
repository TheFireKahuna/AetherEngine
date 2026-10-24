import Foundation
import Testing
@testable import AetherEngine

/// The duplicate-traffic ledger: what fetched minus unique means, and that it means it across readers.
@Suite("Source byte ledger: fetched, unique and duplicate bytes per source")
struct SourceByteLedgerTests {

    private static let source = URL(string: "https://media.example.com/Videos/abc/stream.mkv?static=true")!

    // MARK: Span union

    @Test("A span over bytes already covered adds only the bytes that were not")
    func insertCountsOnlyNewBytes() {
        var spans = ByteSpanSet()
        #expect(spans.insert(start: 0, end: 100) == 100)
        #expect(spans.insert(start: 50, end: 150) == 50)
        #expect(spans.insert(start: 0, end: 150) == 0)
        #expect(spans.spans.count == 1)
        #expect(spans.spans[0] == .init(start: 0, end: 150))
    }

    @Test("Disjoint spans stay apart, and a span bridging them merges all three")
    func insertMergesAcrossGaps() {
        var spans = ByteSpanSet()
        spans.insert(start: 0, end: 10)
        spans.insert(start: 100, end: 110)
        spans.insert(start: 50, end: 60)
        #expect(spans.spans.count == 3)
        #expect(spans.insert(start: 5, end: 105) == 100 - 5 - 10 - 5)
        #expect(spans.spans.count == 1)
        #expect(spans.spans[0] == .init(start: 0, end: 110))
    }

    @Test("Touching spans merge without counting the shared edge twice")
    func insertMergesTouchingSpans() {
        var spans = ByteSpanSet()
        spans.insert(start: 0, end: 10)
        #expect(spans.insert(start: 10, end: 20) == 10)
        #expect(spans.spans.count == 1)
    }

    // MARK: Books

    @Test("A side reader re-reading the pump's bytes is charged as duplicate, the pump is not")
    func duplicateIsChargedToTheRereadingReader() throws {
        let ledger = SourceByteLedger()
        ledger.readerOpened(Self.source)
        ledger.readerOpened(Self.source)
        ledger.record(Self.source, reader: "pump", offset: 0, count: 1000)
        ledger.record(Self.source, reader: "subs", offset: 200, count: 300)
        ledger.record(Self.source, reader: "subs", offset: 1000, count: 100)
        let books = try #require(ledger.snapshot(Self.source))
        #expect(books.fetched == 1400)
        #expect(books.unique == 1100)
        #expect(books.duplicate == 300)
        #expect(books.byReader["pump"]?.duplicate == 0)
        #expect(books.byReader["subs"]?.duplicate == 300)
    }

    @Test("Discarded bytes count as fetched, cover nothing, and are not called duplicate")
    func discardedBytesAreTheirOwnLine() throws {
        let ledger = SourceByteLedger()
        ledger.readerOpened(Self.source)
        ledger.record(Self.source, reader: "pump", offset: 0, count: 500)
        ledger.discard(Self.source, reader: "pump", count: 200)
        let books = try #require(ledger.snapshot(Self.source))
        #expect(books.fetched == 700)
        #expect(books.unique == 500)
        #expect(books.discarded == 200)
        #expect(books.duplicate == 0)
    }

    @Test("A re-minted token is the same source, and no credential reaches the key")
    func credentialQueryItemsNeitherSplitNorLeak() throws {
        let ledger = SourceByteLedger()
        let first = URL(string: "https://media.example.com/Videos/abc/stream.mkv?static=true&api_key=AAAA")!
        let second = URL(string: "https://media.example.com/Videos/abc/stream.mkv?static=true&api_key=BBBB")!
        ledger.readerOpened(first)
        ledger.record(first, reader: "pump", offset: 0, count: 100)
        ledger.record(second, reader: "pump", offset: 0, count: 100)
        #expect(try #require(ledger.snapshot(first)).duplicate == 100)
        #expect(!SourceByteLedger.sourceKey(first).contains("AAAA"))
        #expect(SourceByteLedger.sourceKey(first).contains("static=true"))
        #expect(!SourceByteLedger.display(first).contains("?"))
    }

    @Test("Different query parameters are different sources")
    func differentParametersAreDifferentSources() throws {
        let ledger = SourceByteLedger()
        let a = URL(string: "https://media.example.com/Videos/abc/stream?audioStreamIndex=1")!
        let b = URL(string: "https://media.example.com/Videos/abc/stream?audioStreamIndex=2")!
        ledger.record(a, reader: "pump", offset: 0, count: 100)
        ledger.record(b, reader: "pump", offset: 0, count: 100)
        #expect(try #require(ledger.snapshot(b)).duplicate == 0)
    }

    @Test("The books close with the last reader, and say so in one line")
    func booksCloseWithTheLastReader() {
        let tap = EngineLogCapture()
        defer { tap.end() }
        let ledger = SourceByteLedger()
        let url = URL(string: "https://ledger-close.example.com/Videos/abc/stream.mkv")!
        ledger.readerOpened(url)
        ledger.readerOpened(url)
        ledger.record(url, reader: "pump", offset: 0, count: 1_048_576)
        ledger.record(url, reader: "subs", offset: 0, count: 1_048_576)
        ledger.readerClosed(url, reader: "subs")
        #expect(ledger.snapshot(url) != nil)
        ledger.readerClosed(url, reader: "pump")
        #expect(ledger.snapshot(url) == nil)
        let lines = tap.matching("[SourceLedger] ledger-close.example.com")
        #expect(lines.count == 2)
        #expect(lines.last?.contains("source done") == true)
        #expect(lines.last?.contains("duplicate 1.0 MB (50.0%)") == true)
        #expect(lines.last?.contains("subs 1.0 MB dup 1.0 MB") == true)
    }

    @Test("A burst of closes over unchanged books is one line, and the final close always speaks")
    func unchangedBooksStayQuiet() {
        let tap = EngineLogCapture()
        defer { tap.end() }
        let ledger = SourceByteLedger()
        let url = URL(string: "https://ledger-burst.example.com/Videos/abc/stream.mkv")!
        for _ in 0..<13 { ledger.readerOpened(url) }
        ledger.record(url, reader: "disc", offset: 0, count: 4096)
        for _ in 0..<12 { ledger.readerClosed(url, reader: "disc") }
        #expect(tap.matching("[SourceLedger] ledger-burst.example.com").count == 1)
        ledger.readerClosed(url, reader: "pump")
        let lines = tap.matching("[SourceLedger] ledger-burst.example.com")
        #expect(lines.count == 2)
        #expect(lines.last?.contains("source done") == true)
    }

    @Test("Books nobody closes (a prewarm that never played) are evicted, open ones are not")
    func abandonedBooksAreEvicted() {
        let ledger = SourceByteLedger()
        let open = URL(string: "https://media.example.com/open")!
        ledger.readerOpened(open)
        ledger.record(open, reader: "pump", offset: 0, count: 1)
        for index in 0..<(SourceByteLedger.maxSources + 8) {
            ledger.record(URL(string: "https://media.example.com/warm/\(index)")!,
                          reader: "prewarm", offset: 0, count: 1)
        }
        #expect(ledger.snapshot(open) != nil)
        #expect(ledger.snapshot(URL(string: "https://media.example.com/warm/0")!) == nil)
    }
}
