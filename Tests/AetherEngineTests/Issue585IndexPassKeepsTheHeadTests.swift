import Testing
import Foundation
@testable import AetherEngine

/// AE#585: the open phase ends at `probeStreams`, and the very next thing the native path does is
/// the cue prewarm, a bounded seek into the middle of the title so libavformat loads the container
/// index. That read is outside the retained head, so #281's drop rule fired on it and threw the
/// head away. The cursor is then reset to zero and playback's first read re-fetched the same bytes:
/// 8 MB re-downloaded per warmed session, the whole warm spent on nothing but the parse.
///
/// The head now lives in the source cache, which nothing releases on a read that moved away, so the
/// index pass needs no bracket and the drop rule is gone: a return to the head is a cache read
/// whatever ran in between.
@Suite("A return to the head after the index pass costs no request (#585)")
struct Issue585IndexPassKeepsTheHeadTests {

    private let fileSize: Int64 = 512 * 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    private func read(_ reader: AVIOReader, _ size: Int) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(size))
    }

    /// The shape from the report: prewarm to the middle, cursor back to zero, playback's first read
    /// served from bytes already in hand.
    @Test("the cue prewarm's seek does not release the head")
    func indexPassKeepsTheHead() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)   // the parse's walk from byte zero

        // The cue prewarm: one bounded excursion to the middle for the container's index.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterPrewarm = server.rangeRequestCount

        // The cursor reset, and then playback's first read.
        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "playback's first read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterPrewarm,
                "the prewarm dropped the head and playback re-fetched it: \(server.requestedRanges)")
    }

    /// What the drop rule used to give back: playback moving far away and then returning to the
    /// head. The head stays in the source cache, so the return is a read, not a refetch.
    @Test("the head stays servable after playback has moved away from it")
    func theHeadOutlivesAMoveAway() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)

        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        #expect(read(reader, 32 * 1024) == 32 * 1024)

        #expect(server.rangeRequestCount == requestsAfterSeek,
                "the return to the head was fetched again: \(server.requestedRanges)")
    }
}
