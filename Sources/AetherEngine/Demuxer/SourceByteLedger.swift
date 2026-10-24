import Foundation

/// How many of the bytes fetched for a source were bytes already fetched for it.
///
/// Several readers fetch one source at once: the pump, the subtitle and I-frame side readers, the
/// still extractor, open-time probes, a prewarm that ran before the session did. Each counts its own
/// transfer (`AVIOReader.cumulativeBytesFetched`), and no counter says how much of the sum was the
/// same bytes twice, which is the number a reduction in traffic has to be measured against. So every
/// delivery records the span it covers here, the ledger keeps the union of those spans per source,
/// and fetched minus unique is the duplicate. Bytes that crossed the wire and were thrown away (a
/// stale connection generation, an origin that sent past the range) are counted apart as discarded:
/// they are waste too, but they cover nothing.
///
/// A line when a reader closes with something new on the books since the last line (the disc reader
/// clones itself a dozen at a time, and a burst of closes over unchanged books is one line, not twelve),
/// and a final one when the last reader of a source closes, after which
/// the source is forgotten: a replay of the same item is a new session with its own books. The
/// source is the URL without its credential query items, so a re-minted token is the same source
/// and the line never carries one.
final class SourceByteLedger: @unchecked Sendable {
    static let shared = SourceByteLedger()

    /// Sources kept at once. A prewarm that never became a session leaves its books open with no
    /// reader to close them, so the least recently touched closed source goes first.
    static let maxSources = 32

    struct Tally: Equatable, Sendable {
        var fetched: Int64 = 0
        var duplicate: Int64 = 0
        var discarded: Int64 = 0
        /// Bytes this reader was handed by `SourceByteCache` instead of the network. Not fetched,
        /// so outside every other figure: they are the duplicates that did not happen.
        var fromCache: Int64 = 0
    }

    struct Snapshot: Equatable, Sendable {
        let fetched: Int64
        let unique: Int64
        let discarded: Int64
        let fromCache: Int64
        let byReader: [String: Tally]
        var duplicate: Int64 { fetched - unique - discarded }
    }

    private struct Source {
        var spans = ByteSpanSet()
        var unique: Int64 = 0
        var byReader: [String: Tally] = [:]
        var openReaders = 0
        var touched: UInt64 = 0
        /// Fetched total at the last line, so a close over unchanged books stays quiet.
        var reportedFetched: Int64 = -1
    }

    private let lock = NSLock()
    private var sources: [String: Source] = [:]
    private var clock: UInt64 = 0

    func readerOpened(_ url: URL) {
        let key = Self.sourceKey(url)
        lock.lock()
        mutate(key) { $0.openReaders += 1 }
        lock.unlock()
    }

    /// Bytes `reader` received for `url` at `offset`, kept or not by the reader itself.
    func record(_ url: URL, reader: String, offset: Int64, count: Int) {
        guard count > 0, offset >= 0 else { return }
        let key = Self.sourceKey(url)
        lock.lock()
        mutate(key) { source in
            let added = source.spans.insert(start: offset, end: offset + Int64(count))
            source.unique += added
            source.byReader[reader, default: Tally()].fetched += Int64(count)
            source.byReader[reader, default: Tally()].duplicate += Int64(count) - added
        }
        lock.unlock()
    }

    /// Bytes that crossed the wire for `url` and were dropped without being served.
    func discard(_ url: URL, reader: String, count: Int) {
        guard count > 0 else { return }
        let key = Self.sourceKey(url)
        lock.lock()
        mutate(key) { source in
            source.byReader[reader, default: Tally()].fetched += Int64(count)
            source.byReader[reader, default: Tally()].discarded += Int64(count)
        }
        lock.unlock()
    }

    /// Bytes `reader` was served from `SourceByteCache` for `url`.
    func servedFromCache(_ url: URL, reader: String, count: Int) {
        guard count > 0 else { return }
        let key = Self.sourceKey(url)
        lock.lock()
        mutate(key) { $0.byReader[reader, default: Tally()].fromCache += Int64(count) }
        lock.unlock()
    }

    func readerClosed(_ url: URL, reader: String) {
        let key = Self.sourceKey(url)
        lock.lock()
        guard var source = sources[key] else { lock.unlock(); return }
        source.openReaders = max(0, source.openReaders - 1)
        let last = source.openReaders == 0
        let snapshot = Self.snapshot(of: source)
        let changed = snapshot.fetched + snapshot.fromCache != source.reportedFetched
        source.reportedFetched = snapshot.fetched + snapshot.fromCache
        if last { sources[key] = nil } else { sources[key] = source }
        lock.unlock()
        guard snapshot.fetched + snapshot.fromCache > 0, last || changed else { return }
        EngineLog.emit(
            "[SourceLedger] \(Self.display(url)) \(reader) closed"
            + (last ? ", source done" : ", \(source.openReaders) reader(s) still open")
            + ": \(Self.describe(snapshot))",
            category: .demux)
    }

    func snapshot(_ url: URL) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return sources[Self.sourceKey(url)].map(Self.snapshot(of:))
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        sources.removeAll()
    }

    // MARK: - Books

    /// Caller holds `lock`.
    private func mutate(_ key: String, _ body: (inout Source) -> Void) {
        clock &+= 1
        var source = sources[key] ?? Source()
        body(&source)
        source.touched = clock
        sources[key] = source
        guard sources.count > Self.maxSources,
              let evict = sources.filter({ $0.value.openReaders == 0 && $0.key != key })
                .min(by: { $0.value.touched < $1.value.touched })?.key
        else { return }
        sources[evict] = nil
    }

    private static func snapshot(of source: Source) -> Snapshot {
        let fetched = source.byReader.values.reduce(0) { $0 + $1.fetched }
        let discarded = source.byReader.values.reduce(0) { $0 + $1.discarded }
        let fromCache = source.byReader.values.reduce(0) { $0 + $1.fromCache }
        return Snapshot(fetched: fetched, unique: source.unique, discarded: discarded,
                        fromCache: fromCache, byReader: source.byReader)
    }

    // MARK: - Naming

    static func sourceKey(_ url: URL) -> String { SourceIdentity.key(url) }

    static func display(_ url: URL) -> String { SourceIdentity.display(url) }

    static func describe(_ snapshot: Snapshot) -> String {
        let percent = snapshot.fetched > 0
            ? Double(snapshot.duplicate) / Double(snapshot.fetched) * 100 : 0
        var line = "fetched \(mb(snapshot.fetched)), unique \(mb(snapshot.unique)), "
            + "duplicate \(mb(snapshot.duplicate)) (\(String(format: "%.1f", percent))%)"
        if snapshot.discarded > 0 { line += ", discarded \(mb(snapshot.discarded))" }
        if snapshot.fromCache > 0 { line += ", served from cache \(mb(snapshot.fromCache))" }
        let readers = snapshot.byReader.sorted { $0.value.fetched > $1.value.fetched }.map { name, tally in
            var part = "\(name) \(mb(tally.fetched))"
            if tally.duplicate > 0 { part += " dup \(mb(tally.duplicate))" }
            if tally.discarded > 0 { part += " discarded \(mb(tally.discarded))" }
            if tally.fromCache > 0 { part += " cache \(mb(tally.fromCache))" }
            return part
        }
        return line + "; " + readers.joined(separator: ", ")
    }

    private static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }
}
