import Testing
import Foundation
@testable import AetherEngine

extension PrewarmSuites {
    /// #551: what a warmed source is worth at the next open.
    ///
    /// The claim being pinned is not "fewer bytes" but "no round trip": the reads a cold open pays
    /// three sequential round trips for (#281) are served out of the source cache the warm filled,
    /// and the data connection starts where the warm bytes end instead of at byte zero.
    ///
    /// Each test warms into a source cache of its own. `.serialized` because the origin budget is
    /// process-wide, so nothing here resets it globally; each server has its own port and therefore
    /// its own origin key.
    @Suite("Source prewarm adoption (#551)", .serialized, .timeLimit(.minutes(2)))
    struct SourcePrewarmAdoptionTests {

        private let fileSize: Int64 = 64 * 1024 * 1024
        private let warmBytes = 256 * 1024

        private func url(_ server: ThrottledOriginServer) -> URL {
            URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!
        }

        private func freshCache() -> SourceByteCache {
            SourceByteCache(directory: FileManager.default.temporaryDirectory
                .appending(path: "prewarm-adopt-\(UUID().uuidString)", directoryHint: .isDirectory),
                            budget: .fixed(64 << 20))
        }

        private func warm(_ server: ThrottledOriginServer, bytes: Int, into cache: SourceByteCache) async {
            _ = await SourcePrewarmFetcher.warm(url: url(server), extraHeaders: [:],
                                                byteBudget: bytes, into: cache)
        }

        /// A request the read loop issues asynchronously is still on the wire when the read that
        /// caused it returns. Waiting for it here is the test's job, not the reader's.
        private func waitForRequest(_ server: ThrottledOriginServer, startingAt start: Int64) async throws {
            try await waitFor {
                server.requestedRanges.contains(where: { $0.start == start })
            }
        }

        private func read(_ reader: AVIOReader, _ size: Int) -> Int32 {
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            defer { buf.deallocate() }
            return reader.read(into: buf, size: Int32(size))
        }

        @Test("the reads inside the warm head cost no request at all")
        func warmHeadServesWithoutTheNetwork() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)
            let warmRequests = server.rangeRequestCount

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(read(reader, 64 * 1024) == 64 * 1024)
            #expect(read(reader, 64 * 1024) == 64 * 1024)

            let opened = server.requestedRanges.dropFirst(warmRequests)
            #expect(!opened.contains(where: { $0.start == 0 }),
                    "the open re-fetched bytes it already had: \(Array(opened))")
        }

        /// The data connection is not skipped, it is moved: playback still needs the bytes behind the
        /// warm head, and the reads past it fetch from the warm frontier, never from byte zero.
        @Test("the data connection starts where the warm bytes end")
        func connectionStartsAtTheWarmFrontier() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)
            let warmRequests = server.rangeRequestCount

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(read(reader, warmBytes + 64 * 1024) > 0)
            try await waitForRequest(server, startingAt: Int64(warmBytes))

            let opened = Array(server.requestedRanges.dropFirst(warmRequests))
            #expect(opened.contains(where: { $0.start == Int64(warmBytes) }),
                    "no connection at the warm frontier: \(opened)")
            #expect(!opened.contains(where: { $0.start == 0 }),
                    "the open went back to byte zero: \(opened)")
        }

        /// The size comes out of the warm, so the open neither probes for it nor waits on a response
        /// header to learn it. Without it the reader would fall back to the probe ladder and the whole
        /// saving would be spent there.
        @Test("the size is adopted with the bytes")
        func sizeIsAdopted() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()

            #expect(reader.resolvedByteSize == fileSize)
        }

        /// The latency claim, and the reason a loopback origin cannot make it: against an origin whose
        /// first byte costs two seconds, a cold open sits in `awaitFirstPersistentData` for them. A warm
        /// open has the head already and must not wait at all.
        @Test("a warm open does not wait for a first byte")
        func warmOpenDoesNotWaitForFirstByte() async throws {
            let cache = freshCache()
            let slow = ThrottledOriginServer(totalSize: fileSize,
                                             firstByteDelayUs: { _ in 2_000_000 })
            let server = try #require(slow)
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            let started = Date()
            try reader.open()
            let openSeconds = Date().timeIntervalSince(started)

            #expect(openSeconds < 1.0, "the warm open still waited \(openSeconds)s for a first byte")
            #expect(read(reader, 32 * 1024) == 32 * 1024)
        }

        /// A source that fits entirely inside the budget leaves nothing for a data connection to
        /// fetch, so none is opened. The guard matters because a connection asked for the range past
        /// the last byte is a 416, and the open would then look like a refusal.
        @Test("a fully warmed source opens without any connection at all", arguments: [40 * 1024, 128 * 1024])
        func fullyWarmedSourceOpensWithNoConnection(size: Int) async throws {
            let cache = freshCache()
            let small = Int64(size)
            let server = try #require(ThrottledOriginServer(totalSize: small))
            defer { server.stop() }
            await warm(server, bytes: 1 << 20, into: cache)
            let warmRequests = server.rangeRequestCount

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            #expect(read(reader, Int(small)) == Int32(small))

            #expect(reader.resolvedByteSize == small)
            // A tail request is asynchronous: counting immediately after open/read can pass before
            // the redundant bytes=-65536 request reaches the origin. This bound asserts absence;
            // it is not a deadline for a prerequisite event.
            let extraRequest = try await waitFor(upTo: .milliseconds(500)) {
                server.rangeRequestCount > warmRequests
            }
            #expect(!extraRequest,
                    "a fully adopted source issued another request: \(server.requestHeaders)")
            #expect(server.rangeRequestCount == warmRequests,
                    "the open connected for a source it already held whole: \(server.requestedRanges)")
        }

        @Test("a partial warm still prefetches the missing suffix")
        func partialWarmStillFetchesSuffix() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)
            let warmRequests = server.rangeRequestCount
            #expect(cache.heldLength(SourceCacheKey(url: url(server), headers: [:]), at: 0, expectedSize: nil) > 0)

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            try await waitFor {
                server.requestHeaders.dropFirst(warmRequests).contains {
                    $0["range"] == "bytes=-65536"
                }
            }
            #expect(read(reader, 32 * 1024) == 32 * 1024)
            #expect(reader.resolvedByteSize == fileSize)
        }

        /// A source nobody warmed keeps the cold path exactly as it was, byte for byte.
        @Test("an unwarmed source still opens from byte zero")
        func coldOpenIsUnchanged() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()

            #expect(server.requestedRanges.contains(where: { $0.start == 0 }),
                    "the cold open did not fetch from byte zero: \(server.requestedRanges)")
        }

        /// A warm is shared, not taken: a second session on the same URL is served the same bytes, out
        /// of the same cache, instead of fetching the head again.
        @Test("a second open on the same URL is warm too")
        func warmIsShared() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)

            let first = AVIOReader(url: url(server), sourceCache: cache)
            try first.open()
            first.markClosed(); first.close()
            let afterFirst = server.rangeRequestCount

            let second = AVIOReader(url: url(server), sourceCache: cache)
            defer { second.markClosed(); second.close() }
            try second.open()

            #expect(read(second, 64 * 1024) == 64 * 1024)
            let opened = Array(server.requestedRanges.dropFirst(afterFirst))
            #expect(!opened.contains(where: { $0.start == 0 }),
                    "the second open fetched the head again: \(opened)")
        }

        /// The URL is only half the request. An origin that varies on Referer or Authorization answers
        /// a different body under the same URL, and nothing about the bytes would show it, so a session
        /// whose headers differ from the warm's opens cold rather than adopting someone else's response.
        @Test("a warm fetched with different headers is not adopted")
        func headerMismatchOpensCold() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            _ = await SourcePrewarmFetcher.warm(url: url(server),
                                                extraHeaders: ["Referer": "http://portal.example/"],
                                                byteBudget: warmBytes, into: cache)
            let warmRequests = server.rangeRequestCount

            let reader = AVIOReader(url: url(server), sourceCache: cache)   // no headers: a different request
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            try await waitForRequest(server, startingAt: 0)

            let opened = Array(server.requestedRanges.dropFirst(warmRequests))
            #expect(opened.contains(where: { $0.start == 0 }),
                    "the open adopted a warm fetched under different headers: \(opened)")
        }

        /// The one adopted fact that could be wrong and could never be corrected: the size. The
        /// write-once rule treats any positive `fileSize` as settled, so a warm that belongs to a
        /// different response would fix a wrong EOF point for the whole session. The connection that is
        /// actually serving the session gets to overrule it.
        @Test("a connection that states a different size overrules the warm", .timeLimit(.minutes(1)))
        func sizeMismatchDropsTheWarm() async throws {
            let cache = freshCache()
            let server = try #require(ThrottledOriginServer(totalSize: fileSize))
            defer { server.stop() }
            await warm(server, bytes: warmBytes, into: cache)
            // The source is not what it was when it was warmed.
            let restated: Int64 = 32 * 1024 * 1024
            server.setTotalSize(restated)

            let reader = AVIOReader(url: url(server), sourceCache: cache)
            defer { reader.markClosed(); reader.close() }
            try reader.open()
            // Past the warm head, so a connection to the origin states the size it serves now.
            #expect(read(reader, warmBytes + 64 * 1024) > 0)
            try await waitFor { reader.resolvedByteSize == restated }

            #expect(reader.resolvedByteSize == restated,
                    "the session kept the warm's size over the one its own connection stated")
        }
    }
}
