import Foundation

/// What the running sessions may still write to the tmp volume (#687).
///
/// A session sizes its retention from the volume's free space, measured once at its start. A claim
/// another session has made but not yet written is still free at that moment, so several sessions
/// started together each took a quarter of the same space: four engines (a multiview host) claimed
/// four quarters, i.e. the volume the clamp exists to protect.
///
/// So every session claims here, and a new one is sized from what is really left: the free space
/// minus what the others have claimed and not yet written. A session alone gets what it always got;
/// n sessions together leave at least `(3/4)^n` of the volume.
final class RetentionClaims: @unchecked Sendable {

    static let shared = RetentionClaims()

    /// One session's allowance. Released by `release()` or when dropped.
    final class Claim: @unchecked Sendable {
        /// The allowance, as last sized (`resize`).
        var bytes: Int {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            return sizedBytes
        }
        /// What the other sessions could still write when this claim was sized; for the log.
        let heldBackBytes: Int
        private let id = UUID()
        private let ledger: RetentionClaims
        /// Under the ledger's lock.
        private var sizedBytes: Int

        fileprivate init(bytes: Int, heldBackBytes: Int, ledger: RetentionClaims) {
            sizedBytes = bytes
            self.heldBackBytes = heldBackBytes
            self.ledger = ledger
            ledger.entries[id] = Entry(bytes: bytes, used: nil)
        }

        /// Sizes the claim again with `sizing`, for a holder whose life outlasts the free space it was
        /// sized from (the source cache, which lives as long as the process). The space it is sized
        /// over is the free space now, plus what this claim has written (the measurement no longer
        /// counts it), less what the other claims have yet to write. Returns the new allowance.
        ///
        /// Runs this claim's `used` closure under the ledger's lock, as `claim` runs the others'.
        @discardableResult
        func resize(volumeAvailableBytes: Int64?, sizing: (Int64?) -> Int) -> Int {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            let heldBack = ledger.unwrittenLocked(excluding: id)
            let own = ledger.entries[id]?.used?() ?? 0
            let left = volumeAvailableBytes.map { max(0, $0 + Int64(own) - Int64(heldBack)) }
            sizedBytes = max(0, sizing(left))
            if ledger.entries[id] != nil { ledger.entries[id]?.bytes = sizedBytes }
            return sizedBytes
        }

        /// Reports what the session has written so far. Until it is set the whole claim counts as
        /// unwritten, which only ever sizes a later session smaller.
        func track(_ used: @escaping @Sendable () -> Int) {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            ledger.entries[id]?.used = used
        }

        func release() {
            ledger.lock.lock()
            defer { ledger.lock.unlock() }
            ledger.entries.removeValue(forKey: id)
        }

        deinit { release() }
    }

    private struct Entry {
        var bytes: Int
        var used: (@Sendable () -> Int)?
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    /// Free space on the tmp volume, the figure every claim is sized from. The important-usage key
    /// is unavailable on tvOS; the plain capacity key exists on every platform and is close enough
    /// for a quarter-of-free-space clamp.
    static func tmpVolumeAvailableBytes() -> Int64? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        #if os(tvOS)
        return (try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map(Int64.init)
        #else
        return (try? tmp.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        #endif
    }

    /// Sizes a session with `sizing` over the free space the other claims leave, and records the
    /// result. Unknown capacity is passed through as unknown.
    ///
    /// The `used` closures of the other claims run under this ledger's lock; they must not claim.
    func claim(volumeAvailableBytes: Int64?, sizing: (Int64?) -> Int) -> Claim {
        lock.lock()
        defer { lock.unlock() }
        let heldBack = unwrittenLocked(excluding: nil)
        let left = volumeAvailableBytes.map { max(0, $0 - Int64(heldBack)) }
        return Claim(bytes: max(0, sizing(left)), heldBackBytes: heldBack, ledger: self)
    }

    /// What the claims other than `excluded` have claimed and not yet written. Caller holds `lock`.
    private func unwrittenLocked(excluding excluded: UUID?) -> Int {
        entries.reduce(0) { sum, entry in
            entry.key == excluded ? sum : sum + max(0, entry.value.bytes - (entry.value.used?() ?? 0))
        }
    }
}
