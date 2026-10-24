import Foundation

/// How much a read beyond the bytes in hand fetches: what the read asks for (at least `floor`),
/// doubled while reads keep continuing exactly where the last fetch ended, up to `ceiling`, and back
/// to the read's own size the moment one does not. A parse that hops about fetches what it reads; a
/// walk that streams fetches in growing steps rather than one request per read.
///
/// The floor is a request-count bound, not a read-ahead: a read of a few bytes costs a request's
/// worth of overhead either way. The ceiling is what one fetch may hold in memory.
package struct ReadAhead: Sendable, Equatable {
    package let floor: Int
    package let ceiling: Int
    package private(set) var current: Int
    /// Where the last fetch ended; -1 before the first.
    package private(set) var lastFetchEnd: Int64 = -1

    package init(floor: Int, ceiling: Int) {
        self.floor = max(1, min(floor, ceiling))
        self.ceiling = max(1, ceiling)
        current = self.floor
    }

    /// The size to fetch for a read of `requested` bytes at `position`.
    package mutating func size(forReadAt position: Int64, requested: Int) -> Int {
        let base = min(ceiling, max(floor, requested))
        if position == lastFetchEnd, lastFetchEnd >= 0 {
            current = min(ceiling, max(base, current * 2))
        } else {
            current = base
        }
        return current
    }

    /// Records a fetch (or a serve from held bytes) of `count` bytes at `position`.
    package mutating func fetched(at position: Int64, count: Int) {
        lastFetchEnd = position + Int64(count)
    }
}
