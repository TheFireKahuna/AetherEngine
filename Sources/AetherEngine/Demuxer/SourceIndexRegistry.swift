import Foundation

/// A source's container index, parsed once for every reader of it.
///
/// The index is what tells a reader where a source's bytes are by time: a Matroska file's Cues name
/// the cluster and offset of every subtitle block and every video keyframe. Read once, it lets each
/// consumer (the indexed subtitle fill, the subtitle prefetch, the I-frame rendition, seeking) fetch
/// exactly the bytes it needs. Read once per consumer, it is the same tens of megabytes of Cues
/// parsed again for each, and the consumers disagree the moment one of them reads a different
/// version. So there is one index per source, and the parser is reachable only from here:
/// `MatroskaCueIndex.read` takes a `ParseToken`, which nothing outside this file can make.
///
/// An index is per source and per size, the source cache's identity (`SourceCacheKey`) plus the
/// total, so a body that changes under the same request is a new entry rather than a stale one. The
/// first caller's byte source is the one parsed; a caller arriving while the parse runs waits for
/// it, and every later caller is handed the result. A source that is not Matroska or carries no Cues
/// is a permanent answer and is kept; a read that broke off mid-way (`malformed`, which an origin
/// dropping a range produces as readily as a corrupt file) is not, so the next consumer tries again.
/// The parse reads through whatever source the caller opened, which over HTTP is a cache-backed
/// exact range reader: bytes another reader already fetched cost nothing.
final class SourceIndexRegistry: @unchecked Sendable {
    static let shared = SourceIndexRegistry()

    /// Indexes kept at once, least recently asked for first out. A Matroska index is a few hundred
    /// kilobytes of block positions, and a session reads one source at a time.
    static let capacity = 8

    /// Proof that a parse was asked for by the registry. The parser requires one, so a second parse
    /// of a source cannot be added anywhere else by accident.
    struct ParseToken: Sendable {
        fileprivate init() {}

        #if DEBUG
        /// The parser's own unit tests, which read fixtures directly. Debug builds only: a production
        /// call site that reached for it would not build in release.
        static let forParserTests = ParseToken()
        #endif
    }

    struct Key: Hashable, Sendable {
        let source: SourceCacheKey
        let size: Int64
    }

    enum Outcome: Sendable {
        case matroska(MatroskaCueIndex)
        case unavailable(MatroskaCueIndex.ReadError)

        var index: MatroskaCueIndex? {
            if case .matroska(let index) = self { return index }
            return nil
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Task<Outcome, Never>] = [:]
    private var order: [Key] = []
    private var parses = 0

    /// The Matroska index of `url` as asked for with `headers`, parsed (if it has not been) through
    /// `reader`. The key is derived here, from the request and the reader's own size, so two consumers
    /// of one source cannot name it differently and parse it twice. `reader` stays the caller's.
    func matroskaIndex(of url: URL, headers: [String: String], through reader: IOReader) async -> Outcome {
        let key = Key(source: SourceCacheKey(url: url, headers: headers),
                      size: reader.seek(offset: 0, whence: 65536))
        let source = IOReaderByteSource(reader, closesReader: false)
        return await matroskaIndex(for: key, open: { source })
    }

    /// The Matroska index of the source at `key`. Parsed by the first caller, from the byte source
    /// `open` hands over (nil reads as not readable and is not remembered), and by no caller after it.
    /// The parse runs on its own task, so a caller that is cancelled while waiting leaves it to finish
    /// for the others.
    func matroskaIndex(for key: Key, open: @escaping @Sendable () -> RandomAccessByteSource?) async -> Outcome {
        let task = parseTask(for: key, open: open)
        let outcome = await task.value
        if case .unavailable(.malformed) = outcome { forget(key, ifStill: task) }
        return outcome
    }

    /// The one parse of `key`: the running or finished one, or a new one started here.
    private func parseTask(for key: Key, open: @escaping @Sendable () -> RandomAccessByteSource?)
        -> Task<Outcome, Never>
    {
        lock.lock(); defer { lock.unlock() }
        if let existing = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return existing
        }
        let task = BlockingWork.detached(priority: .utility) { [self] () -> Outcome in
            guard let source = open() else { return .unavailable(.malformed("source not range-readable")) }
            noteParse()
            do {
                return .matroska(try MatroskaCueIndex.read(from: source, token: ParseToken()))
            } catch let error as MatroskaCueIndex.ReadError {
                return .unavailable(error)
            } catch {
                return .unavailable(.malformed("\(error)"))
            }
        }
        entries[key] = task
        order.append(key)
        while order.count > Self.capacity {
            entries[order.removeFirst()] = nil
        }
        return task
    }

    private func forget(_ key: Key, ifStill task: Task<Outcome, Never>) {
        lock.lock(); defer { lock.unlock() }
        guard entries[key] == task else { return }
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// How many parses have run since the process started (or the last reset). Diagnostics and the
    /// tests that pin "once".
    var parseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return parses
    }

    func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
        parses = 0
    }

    private func noteParse() {
        lock.lock(); parses += 1; lock.unlock()
    }
}
