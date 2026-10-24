import Foundation
import Testing
@testable import AetherEngine

/// One index per source, parsed once: however many consumers ask, and however they race.
@Suite("Source index registry: a source's index is parsed once for every consumer")
struct SourceIndexRegistryTests {

    private static func key(_ name: String, size: Int64 = 1_000) -> SourceIndexRegistry.Key {
        .init(source: SourceCacheKey(url: URL(string: "https://media.example.com/\(name).mkv")!, headers: [:]),
              size: size)
    }

    /// Counts how often the registry asked for a byte source, which is how often it parsed.
    private final class Opener: @unchecked Sendable {
        private let lock = NSLock()
        private var opens = 0
        let bytes: [UInt8]
        init(_ bytes: [UInt8]) { self.bytes = bytes }
        var count: Int { lock.lock(); defer { lock.unlock() }; return opens }
        func open() -> RandomAccessByteSource? {
            lock.lock(); opens += 1; lock.unlock()
            return IOReaderByteSource(DataIOReader(data: Data(bytes)))
        }
    }

    @Test("Consumers racing for one source share one parse, and a consumer after them parses nothing")
    func racingConsumersShareOneParse() async throws {
        let registry = SourceIndexRegistry()
        let opener = Opener(MatroskaCueIndexTests.fixture().bytes)
        let key = Self.key("race")
        let tracks = await withTaskGroup(of: [UInt64].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let outcome = await registry.matroskaIndex(for: key, open: { opener.open() })
                    return outcome.index.map { Array($0.blocksByTrack.keys).sorted() } ?? []
                }
            }
            var all: [[UInt64]] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(tracks.count == 12)
        #expect(Set(tracks).count == 1)
        #expect(tracks.first?.isEmpty == false)
        #expect(opener.count == 1)
        #expect(registry.parseCount == 1)

        _ = await registry.matroskaIndex(for: key, open: { opener.open() })
        #expect(registry.parseCount == 1)
    }

    @Test("Another source, or the same request at another size, is another index")
    func sourceAndSizeNameTheIndex() async {
        let registry = SourceIndexRegistry()
        let opener = Opener(MatroskaCueIndexTests.fixture().bytes)
        _ = await registry.matroskaIndex(for: Self.key("a"), open: { opener.open() })
        _ = await registry.matroskaIndex(for: Self.key("b"), open: { opener.open() })
        _ = await registry.matroskaIndex(for: Self.key("a", size: 2_000), open: { opener.open() })
        _ = await registry.matroskaIndex(for: Self.key("a"), open: { opener.open() })
        #expect(registry.parseCount == 3)
    }

    @Test("A source that is not Matroska is a kept answer, not a parse per consumer")
    func permanentRefusalIsKept() async {
        let registry = SourceIndexRegistry()
        let opener = Opener([UInt8](repeating: 7, count: 70_000))
        let first = await registry.matroskaIndex(for: Self.key("plain"), open: { opener.open() })
        let second = await registry.matroskaIndex(for: Self.key("plain"), open: { opener.open() })
        guard case .unavailable(.notMatroska) = first, case .unavailable(.notMatroska) = second else {
            Issue.record("expected notMatroska twice, got \(first) and \(second)")
            return
        }
        #expect(opener.count == 1)
    }

    /// A range an origin dropped surfaces as malformed as readily as a corrupt file does, so the
    /// next consumer is allowed to try again.
    @Test("A read that broke off is not remembered: the next consumer tries again")
    func brokenReadIsRetried() async {
        let registry = SourceIndexRegistry()
        let counter = Opener([])
        let unreadable: @Sendable () -> RandomAccessByteSource? = { _ = counter.open(); return nil }
        let first = await registry.matroskaIndex(for: Self.key("flaky"), open: unreadable)
        guard case .unavailable(.malformed) = first else {
            Issue.record("expected malformed, got \(first)")
            return
        }
        let good = Opener(MatroskaCueIndexTests.fixture().bytes)
        let second = await registry.matroskaIndex(for: Self.key("flaky"), open: { good.open() })
        #expect(second.index != nil)
        #expect(counter.count == 1)
        #expect(good.count == 1)
    }

    @Test("Past capacity the least recently asked for index goes, and is parsed again if asked for")
    func capacityEvictsTheOldest() async {
        let registry = SourceIndexRegistry()
        let opener = Opener(MatroskaCueIndexTests.fixture().bytes)
        for n in 0...SourceIndexRegistry.capacity {
            _ = await registry.matroskaIndex(for: Self.key("cap\(n)"), open: { opener.open() })
        }
        #expect(registry.parseCount == SourceIndexRegistry.capacity + 1)
        _ = await registry.matroskaIndex(for: Self.key("cap\(SourceIndexRegistry.capacity)"), open: { opener.open() })
        #expect(registry.parseCount == SourceIndexRegistry.capacity + 1)
        _ = await registry.matroskaIndex(for: Self.key("cap0"), open: { opener.open() })
        #expect(registry.parseCount == SourceIndexRegistry.capacity + 2)
    }
}
