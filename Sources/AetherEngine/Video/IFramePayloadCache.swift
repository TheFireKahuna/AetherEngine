// Sources/AetherEngine/Video/IFramePayloadCache.swift
import Foundation

/// AE#682: keyframe payloads read for the I-frame rendition, in memory with a byte cap, so a still or a
/// fragment built again never waits on the disk. It holds the raw keyframe rather than the built fragment
/// so a neighbour can be re-stamped for an index whose own read failed.
final class IFramePayloadCache: @unchecked Sendable {
    /// About a hundred 4K keyframes: room for a scrub's neighbourhood and AVKit's overview burst.
    static let defaultByteLimit = 128 * 1024 * 1024

    private let byteLimit: Int
    private let lock = NSLock()
    private var payloads: [Int: Data] = [:]
    private var recency: [Int] = []
    private var totalBytes = 0

    init(byteLimit: Int = defaultByteLimit) {
        self.byteLimit = byteLimit
    }

    private func forgetLocked(_ index: Int) {
        guard let data = payloads.removeValue(forKey: index) else { return }
        totalBytes -= data.count
        recency.removeAll { $0 == index }
    }

    func payload(for index: Int) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let data = payloads[index] else { return nil }
        recency.removeAll { $0 == index }
        recency.append(index)
        return data
    }

    func store(_ data: Data, for index: Int) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        forgetLocked(index)
        payloads[index] = data
        totalBytes += data.count
        recency.append(index)
        while totalBytes > byteLimit, let oldest = recency.first, oldest != index {
            forgetLocked(oldest)
        }
    }

    func nearestIndex(to index: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return payloads.keys.min { a, b in
            let da = abs(a - index), db = abs(b - index)
            return da != db ? da < db : a < b
        }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        payloads.removeAll()
        recency.removeAll()
        totalBytes = 0
    }
}
