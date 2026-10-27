import Testing
import Foundation
@testable import AetherEngine

/// A connection that goes quiet while the demuxer waits on it gets a second request raced against
/// it at the frontier, long before the stall threshold (sized for CPU starvation, #272) would act.
/// The origin serves part of a range and then stops writing without closing, the reader-observable
/// shape of a flow that died on a roam or a NAT drop.
@Suite("Hedged refill", .serialized, .offCooperativePool)
struct HedgedRefillTests {

    private static let totalSize: Int64 = 256 * 1024 * 1024
    private static let firstRange: Int64 = 2 * 1024 * 1024
    private static let silentAfter: Int64 = 1024 * 1024

    private static func read(_ reader: AVIOReader, bytes target: Int) -> Int {
        let sliceCap = 256 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: sliceCap)
        defer { buf.deallocate() }
        var got = 0
        let stopAt = Date().addingTimeInterval(60)
        while got < target && Date() < stopAt {
            let n = reader.read(into: buf, size: Int32(min(sliceCap, target - got)))
            if n <= 0 { break }
            got += Int(n)
        }
        return got
    }

    @Test("a refill that goes quiet is raced and replaced in seconds, not at the stall threshold",
          .timeLimit(.minutes(1)))
    func quietRefillIsHedged() throws {
        let silenceOffset = Self.firstRange
        let hedgeOffset = silenceOffset + Self.silentAfter
        let serverMaybe = ThrottledOriginServer(
            totalSize: Self.totalSize,
            respond: { _, offset, _ in
                offset == silenceOffset ? .serveThenGoSilent(afterBytes: Self.silentAfter) : .serve206
            })
        let server = try #require(serverMaybe)
        defer { server.stop() }
        // The shipped stall threshold: the hedge has to act well inside it on its own.
        let reader = AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!,
                                boundedInitialFetch: Self.firstRange)
        defer { reader.markClosed(); reader.close() }
        try reader.open()

        let started = Date()
        let target = 5 * 1024 * 1024
        #expect(Self.read(reader, bytes: target) == target)
        let elapsed = Date().timeIntervalSince(started)

        #expect(elapsed < AVIOReader.hedgeFloorSeconds + 6,
                "the read waited \(String(format: "%.1f", elapsed))s on a silent connection")
        #expect(server.requestedRanges.contains { $0.start == hedgeOffset },
                "no hedge at the frontier: \(server.requestedRanges)")
        #expect(reader.unproductiveReconnectsForTesting == 0, "a hedge charged the failure ladder")
    }

    @Test("the hedge waits out the floor, scales with the round trip and stays under the stall threshold")
    func hedgeDelayBounds() {
        #expect(AVIOReader.hedgeDelay(firstDataMs: 5, stallTimeout: 20) == AVIOReader.hedgeFloorSeconds)
        #expect(AVIOReader.hedgeDelay(firstDataMs: 800, stallTimeout: 20) == 4.8)
        #expect(AVIOReader.hedgeDelay(firstDataMs: 5_000, stallTimeout: 20) == 10)
    }
}
