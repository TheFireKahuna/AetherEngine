import Foundation

/// A source's container index, parsed once for every reader of it.
///
/// The index is what tells a reader where a source's bytes are by time: a Matroska file's Cues name
/// the cluster and offset of every subtitle block and every video keyframe, an MP4's sample tables
/// every sample (`SourceIndex`). Read once, it lets each
/// consumer (the indexed subtitle fill, the subtitle prefetch, the I-frame rendition, seeking) fetch
/// exactly the bytes it needs. Read once per consumer, it is the same tens of megabytes of Cues
/// parsed again for each, and the consumers disagree the moment one of them reads a different
/// version. So there is one index per source, and the readers are reachable only from here:
/// `MatroskaCueIndex.read` and `MP4SampleIndex.read` take a `ParseToken`, which nothing outside this
/// file can make.
///
/// An index is per source and per size, the source cache's identity (`SourceCacheKey`) plus the
/// total, so a body that changes under the same request is a new entry rather than a stale one. The
/// first caller's source is the one read; a caller arriving while the read runs waits for it, and
/// every later caller is handed the result. A container no reader covers, or a file without an index,
/// is a permanent answer and is kept; a read that broke off mid-way (`malformed`, which an origin
/// dropping a range produces as readily as a corrupt file) is not, so the next consumer tries again.
/// The parse reads through whatever source the caller opened, which over HTTP is a cache-backed
/// exact range reader: bytes another reader already fetched cost nothing.
final class SourceIndexRegistry: @unchecked Sendable {

    /// Proof that a read was asked for by the registry. The index readers require one, so a second
    /// read of a source cannot be added anywhere else by accident.
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
        case indexed(any SourceIndex)
        case unavailable(SourceIndexError)

        var index: (any SourceIndex)? {
            if case .indexed(let index) = self { return index }
            return nil
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Task<Outcome, Never>] = [:]
    private var parses = 0

    /// The index of `url` as asked for with `headers`, which `demuxer` opened, read (if it has not
    /// been) through `reader`. The key is derived here, from the request and the reader's own size, so
    /// two consumers of one source cannot name it differently and read it twice. The container is the
    /// one libavformat opened: Matroska's Cues are parsed off `reader`; an MP4's sample tables are the
    /// ones `demuxer` built. `reader` and `demuxer` stay the caller's.
    func index(of url: URL, headers: [String: String], demuxer: Demuxer, through reader: IOReader) async -> Outcome {
        let key = Key(source: SourceCacheKey(url: url, headers: headers),
                      size: reader.seek(offset: 0, whence: 65536))
        let source = IOReaderByteSource(reader, closesReader: false)
        let format = demuxer.containerFormatName ?? ""
        if format.contains("matroska") {
            return await index(for: key) { token in try MatroskaCueIndex.read(from: source, token: token) }
        }
        if format.contains("mp4") {
            let streams = AetherEngine.indexedSubtitleStreams(of: demuxer)
            let videos = AetherEngine.indexedVideoTracks(of: demuxer)
            return await index(for: key) { token in
                try MP4SampleIndex.read(demuxer: demuxer, streams: streams, videoTracks: videos,
                                        source: source, token: token)
            }
        }
        return .unavailable(.unsupportedContainer)
    }

    /// The index of the source at `key`. Read by the first caller, with `read`, and by no caller after
    func index(for key: Key, read: @escaping @Sendable (ParseToken) throws -> any SourceIndex) async -> Outcome {
        let task = parseTask(for: key, read: read)
        let outcome = await task.value
        return outcome
    }

    /// The one parse of `key`: the running or finished one, or a new one started here.
    private func parseTask(for key: Key, read: @escaping @Sendable (ParseToken) throws -> any SourceIndex)
        -> Task<Outcome, Never>
    {
        lock.lock(); defer { lock.unlock() }
        let task = BlockingWork.detached(priority: .utility) { [self] () -> Outcome in
            noteParse()
            do {
                return .indexed(try read(ParseToken()))
            } catch let error as SourceIndexError {
                return .unavailable(error)
            } catch {
                return .unavailable(.malformed("\(error)"))
            }
        }
        entries[key] = task
        return task
    }

    private func forget(_ key: Key, ifStill task: Task<Outcome, Never>) {
        lock.lock(); defer { lock.unlock() }
        guard entries[key] == task else { return }
        entries[key] = nil
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
        parses = 0
    }

    private func noteParse() {
        lock.lock(); parses += 1; lock.unlock()
    }
}
