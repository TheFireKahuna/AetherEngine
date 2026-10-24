import Testing
import Foundation
@testable import AetherEngine

/// AE#782: a producer restart behind the reader's window used to be served as serial 4 MB detour
/// blocks until 8 MB of it had gone by, which is the parse-read policy (#69), not playback's. A
/// restart now tells the reader, and the first backward read the source cache cannot serve anchors
/// the streaming connection at the landing.
@Suite("AE#782 restart re-anchors at the landing")
struct Issue782RestartReanchorTests {

    private static let chunk = 256 * 1024

    /// The detour fetch's 4 s interactive budget is a wall clock: on a loaded runner a 4 MB block
    /// missed it, fell through to the rescue reconnect AT the landing, and the parse-read assertions
    /// read that as the AE#782 anchor. The policy under test is where the read goes, not how fast.
    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!, detourFetchBudget: 30)
    }

    private func readForward(_ reader: AVIOReader, _ buf: UnsafeMutablePointer<UInt8>, bytes: Int) -> Bool {
        var read = 0
        while read < bytes {
            let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
            if n <= 0 { return false }
            read += n
        }
        return true
    }

    private func matchesPattern(_ buf: UnsafeMutablePointer<UInt8>, count: Int, at offset: Int64) -> Bool {
        (0..<count).allSatisfy { buf[$0] == ThrottledOriginServer.patternByte(at: offset + Int64($0)) }
    }

    /// The reader first reads at the head, then far forward, so the region the tests land in (around
    /// 20 MB) is behind the window and was never fetched: the bytes the source cache cannot serve,
    /// which is the only read this policy decides. A landing in bytes already held is served from
    /// the cache with no request at all, whatever the policy.
    private func positionedAhead(_ reader: AVIOReader, _ buf: UnsafeMutablePointer<UInt8>) throws {
        try reader.open()
        #expect(readForward(reader, buf, bytes: 1024 * 1024))
        let ahead: Int64 = 40 * 1024 * 1024
        #expect(reader.seek(offset: ahead, whence: Int32(SEEK_SET)) == ahead)
        #expect(readForward(reader, buf, bytes: 13 * 1024 * 1024))
    }

    private static let blockStart: Int64 = 20 * 1024 * 1024
    private static let blockBytes: Int64 = 4 * 1024 * 1024

    private func isDetourBlock(_ range: (start: Int64, end: Int64?), at start: Int64) -> Bool {
        range.start == start && range.end == start + Self.blockBytes - 1
    }

    @Test("a backward read after a playback reposition opens the connection there, not a detour block",
          .timeLimit(.minutes(2)))
    func repositionAnchorsAtLanding() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        try positionedAhead(reader, buf)

        let landing = Self.blockStart + 4321
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        reader.notePlaybackRepositioned()
        let n = Int(reader.read(into: buf, size: Int32(Self.chunk)))
        #expect(n > 0)
        #expect(matchesPattern(buf, count: n, at: landing), "the landing served the wrong bytes")

        let ranges = server.requestedRanges
        #expect(!ranges.contains { isDetourBlock($0, at: Self.blockStart) }, "the landing was served as a detour block")
        #expect(ranges.contains { $0.start == landing },
                "no connection was anchored at the landing: \(ranges.map(\.start))")
    }

    @Test("without the reposition the same read is still a detour, so the parse-read policy is unchanged",
          .timeLimit(.minutes(2)))
    func parseReadStillDetours() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        try positionedAhead(reader, buf)

        let landing = Self.blockStart + 4321
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        let ranges = server.requestedRanges
        #expect(ranges.contains { isDetourBlock($0, at: Self.blockStart) }, "no detour block: \(ranges.map(\.start))")
        #expect(!ranges.contains { $0.start == landing })
    }

    @Test("held bytes still serve the landing, and the first miss past them anchors",
          .timeLimit(.minutes(2)))
    func heldBytesServeFirst() throws {
        let server = try #require(ThrottledOriginServer(totalSize: 64 * 1024 * 1024, throttleUs: 1000, patternedBody: true))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunk)
        defer { buf.deallocate() }
        try positionedAhead(reader, buf)

        // An earlier scrub left the block at 20 to 24 MB held.
        #expect(reader.seek(offset: Self.blockStart, whence: Int32(SEEK_SET)) == Self.blockStart)
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        #expect(server.requestedRanges.contains { isDetourBlock($0, at: Self.blockStart) })
        let requestsBefore = server.requestedRanges.count

        let landing = Self.blockStart + 2 * 1024 * 1024
        #expect(reader.seek(offset: landing, whence: Int32(SEEK_SET)) == landing)
        reader.notePlaybackRepositioned()
        #expect(reader.read(into: buf, size: Int32(Self.chunk)) > 0)
        #expect(server.requestedRanges.count == requestsBefore, "a held landing went to the network")

        #expect(readForward(reader, buf, bytes: 3 * 1024 * 1024))
        let heldEnd = Self.blockStart + Self.blockBytes
        let ranges = server.requestedRanges
        #expect(ranges.contains { $0.start == heldEnd },
                "the first miss past the held block did not anchor there: \(ranges.map(\.start))")
        #expect(!ranges.contains { isDetourBlock($0, at: heldEnd) },
                "the first miss past the held block was fetched as a detour block")
    }
}
