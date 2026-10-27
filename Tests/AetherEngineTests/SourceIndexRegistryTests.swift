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

    /// Counts how often the registry ran a read of the bytes, which is how often it parsed. The bytes are a file read
    /// as the engine reads one.
    private final class Opener: @unchecked Sendable {
        private let lock = NSLock()
        private var opens = 0
        private let reader: IOReader
        init(_ bytes: [UInt8]) throws {
            let url = FileManager.default.temporaryDirectory.appending(path: "index-registry-\(UUID().uuidString).mkv")
            try Data(bytes).write(to: url)
            reader = try #require(FileIOReader(url: url))
        }
        /// A source whose every read fails, as a dropped connection's do: an origin gone after the reader opened.
        init(dropped: Void) throws {
            let origin = try #require(KeepAliveRangeOrigin(data: Data(MatroskaCueIndexTests.fixture().bytes)))
            reader = try #require(HTTPDiscIOReader(url: URL(string: "http://127.0.0.1:\(origin.port)/flaky.mkv")!, maxRetries: 0))
            origin.stop()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return opens }
        func read(_ token: SourceIndexRegistry.ParseToken) throws -> any SourceIndex {
            lock.lock(); opens += 1; lock.unlock()
            return try MatroskaCueIndex.read(from: IOReaderByteSource(reader), token: token)
        }
    }

    @Test("Consumers racing for one source share one parse, and a consumer after them parses nothing")
    func racingConsumersShareOneParse() async throws {
        let key = Self.key("race")
        let opener = try Opener(MatroskaCueIndexTests.fixture().bytes)
        let tracks = await withTaskGroup(of: [UInt64].self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let outcome = await registry.index(for: key, read: opener.read)
                    return outcome.index.map { $0.subtitleTracks.map(\.number) } ?? []
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

        _ = await registry.index(for: key, read: opener.read)
        #expect(registry.parseCount == 1)
    }

    @Test("Another source, or the same request at another size, is another index")
    func sourceAndSizeNameTheIndex() async throws {
        let opener = try Opener(MatroskaCueIndexTests.fixture().bytes)
        _ = await registry.index(for: Self.key("a"), read: opener.read)
        _ = await registry.index(for: Self.key("b"), read: opener.read)
        _ = await registry.index(for: Self.key("a", size: 2_000), read: opener.read)
        _ = await registry.index(for: Self.key("a"), read: opener.read)
        #expect(registry.parseCount == 3)
    }

    @Test("A source no reader covers is a kept answer, not a parse per consumer")
    func permanentRefusalIsKept() async throws {
        let opener = try Opener([UInt8](repeating: 7, count: 70_000))
        let first = await registry.index(for: Self.key("plain"), read: opener.read)
        let second = await registry.index(for: Self.key("plain"), read: opener.read)
        guard case .unavailable(.unsupportedContainer) = first, case .unavailable(.unsupportedContainer) = second else {
            Issue.record("expected unsupportedContainer twice, got \(first) and \(second)")
            return
        }
        #expect(opener.count == 1)
    }

    /// A range an origin dropped surfaces as malformed as readily as a corrupt file does, so the
    /// next consumer is allowed to try again.
    @Test("A read that broke off is not remembered: the next consumer tries again")
    func brokenReadIsRetried() async throws {
        let counter = try Opener(dropped: ())
        let first = await registry.index(for: Self.key("flaky"), read: counter.read)
        guard case .unavailable(.malformed) = first else {
            Issue.record("expected malformed, got \(first)")
            return
        }
        let good = try Opener(MatroskaCueIndexTests.fixture().bytes)
        let second = await registry.index(for: Self.key("flaky"), read: good.read)
        #expect(second.index != nil)
        #expect(counter.count == 1)
        #expect(good.count == 1)
    }

    func anotherBodyDropsTheIndex() async throws {
        let opener = try Opener(MatroskaCueIndexTests.fixture().bytes)
    }
    func unheldSourceKeepsNothing() async throws {
        let opener = try Opener(MatroskaCueIndexTests.fixture().bytes)
    }
    func idleReleaseDropsTheIndex() async throws {
        _ = await registry.index(for: key, read: try Opener(MatroskaCueIndexTests.fixture().bytes).read)
    }
}
