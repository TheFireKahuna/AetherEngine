import Foundation

/// The HLS ingests' segment pipeline: segments go to the consumer strictly in playlist order, the one
/// it is waiting for as its bytes arrive and the next few fetched whole alongside it.
///
/// Holding every segment whole before its first byte moved put a full segment's download in front of
/// the demuxer at every start and after every seek (15-25 MB for a UHD segment: seconds), and in
/// front of every new live segment. Streaming the head-of-line segment removes that wait, and the
/// prefetch window keeps the link busy across segment boundaries, which is what the whole-segment
/// pipeline was for.
enum SegmentPipeline {

    /// Delivers segments `0..<count` in order through `deliver(index, bytes, isLast)`, which answers
    /// false to stop (the consumer is gone). A segment is fetched whole (`fetchWhole`) when it is
    /// within `window()` of the one being delivered, and otherwise streamed (`stream`) once it is the
    /// one being delivered; `canStream` keeps a segment whole regardless (an encrypted one has to be
    /// decrypted as a unit). `window` is read before every spawn, so a caller can narrow it once it
    /// knows a segment's size. Returns false when the consumer stopped it.
    static func run(
        count: Int,
        window: () -> Int,
        canStream: (Int) -> Bool,
        fetchWhole: @escaping @Sendable (Int) async throws -> Data,
        stream: (Int, _ deliver: (Data) async throws -> Bool) async throws -> Bool,
        deliver: @escaping (Int, Data, _ isLast: Bool) async throws -> Bool
    ) async throws -> Bool {
        var prefetched: [Int: Task<Data, Error>] = [:]
        defer { prefetched.values.forEach { $0.cancel() } }
        var nextToSpawn = 1
        for index in 0..<count {
            try Task.checkCancellation()
            nextToSpawn = max(nextToSpawn, index + 1)
            while nextToSpawn < count, nextToSpawn < index + max(1, window()) {
                let spawned = nextToSpawn
                prefetched[spawned] = Task { try await fetchWhole(spawned) }
                nextToSpawn += 1
            }
            if let task = prefetched.removeValue(forKey: index) {
                let bytes = try await withTaskCancellationHandler {
                    try await task.value
                } onCancel: {
                    task.cancel()
                }
                guard try await deliver(index, bytes, true) else { return false }
            } else if canStream(index) {
                var pending: Data?
                let completed = try await stream(index) { chunk in
                    // One chunk behind, so the last one goes out marked as the segment's end.
                    if let previous = pending, !(try await deliver(index, previous, false)) { return false }
                    pending = chunk
                    return true
                }
                guard completed else { return false }
                guard try await deliver(index, pending ?? Data(), true) else { return false }
            } else {
                guard try await deliver(index, try await fetchWhole(index), true) else { return false }
            }
        }
        return true
    }
}
