import Foundation
import Testing
@testable import AetherEngine

/// Fetches sized to what is read, not to a fixed block: the chunk path, and the pump's rule for when a
/// held span is worth ending a range for.
@Suite("Fetch sizes follow the read and the link")
struct ExactFetchSizeTests {

    /// A keyframe-style read through the chunk path: one read far into the file costs what it asked
    /// for, not the reader's whole chunk, and a walk that continues grows in steps.
    @Test("the chunk path fetches the read, and grows only while reads continue", .timeLimit(.minutes(1)))
    func chunkPathFetchesTheRead() throws {
        let size: Int64 = 64 * 1024 * 1024
        let server = try #require(ThrottledOriginServer(totalSize: size, patternedBody: true))
        defer { server.stop() }
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/keyframes.bin")!,
                                chunkSize: 1024 * 1024, prefetchEnabled: false)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64 * 1024)
        defer { buf.deallocate() }

        let far: Int64 = 40 * 1024 * 1024
        #expect(reader.seek(offset: far, whence: SEEK_SET) == far)
        #expect(reader.read(into: buf, size: 64 * 1024) == 64 * 1024)
        let first = try #require(server.requestedRanges.last { $0.start == far })
        #expect((first.end ?? 0) - far + 1 == 64 * 1024, "a 64 KB read fetched \(String(describing: first.end))")

        // The walk continues where the fetch ended: the next fetch doubles.
        #expect(reader.read(into: buf, size: 64 * 1024) == 64 * 1024)
        let second = try #require(server.requestedRanges.last { $0.start == far + 64 * 1024 })
        #expect((second.end ?? 0) - second.start + 1 == 128 * 1024)
    }

    @Test("a held span is worth a split once it outweighs what the link moves in a round trip")
    func splitThresholdFollowsTheLink() {
        // Unmeasured: the cache's default.
        #expect(AVIOReader.heldSpanWorthASplit(bytesPerSecond: 0, firstDataMs: 0) == SourceByteCache.minimumServeBytes)
        // A fast LAN, 100 MB/s with a 2 ms round trip: 200 KB.
        #expect(AVIOReader.heldSpanWorthASplit(bytesPerSecond: 100_000_000, firstDataMs: 2) == 200_000)
        // A slow, near link never splits below the floor.
        #expect(AVIOReader.heldSpanWorthASplit(bytesPerSecond: 1_000_000, firstDataMs: 1) == 64 * 1024)
        // A long fat pipe: 50 MB/s at 80 ms is 4 MB.
        #expect(AVIOReader.heldSpanWorthASplit(bytesPerSecond: 50_000_000, firstDataMs: 80) == 4_000_000)
    }
}
