import Foundation

/// #240: whether a seek is in flight, readable off the main actor. A seek owns the link until it lands, so
/// a scrub thumbnail's read (the I-frame rendition) waits it out rather than compete with the landing.
final class SeekInFlightSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var seeking = false

    init() {}

    /// Wired to `AetherEngine.isSeeking` (programmatic + native scrub, both flags).
    func set(_ inFlight: Bool) {
        lock.lock()
        seeking = inFlight
        lock.unlock()
    }

    var isSeeking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return seeking
    }
}
