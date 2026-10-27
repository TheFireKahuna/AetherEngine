import Foundation

/// AE#859: turns an MPD URL into a `DASHVirtualMP4Reader`. Fetches the manifest, picks the
/// representations (`DASHManifest.selectRepresentations`), opens one ranged reader per
/// representation file and reads its initialization segment and segment index, which is all the
/// layout needs: no media byte is fetched before the demuxer asks for one.
///
/// Every request goes out on the engine's one session (`EngineHTTP.session`) with the session's
/// headers, through `BoundedFetch`, so a body is cut off at its bound while it arrives and a request
/// ends at its resource deadline. `cancel()` is safe from any thread and reaches every request in
/// flight and every reader opened so far, which is what lets a teardown that races the open end it
/// instead of waiting out the request timeouts (audit DMX-102's rule for the disc path).
final class DASHSourceOpener: @unchecked Sendable {

    /// A manifest is text; an on-demand one is a few kilobytes. The bound only stops a misrouted
    /// media file from being read whole into memory.
    static let manifestByteLimit = 8 * 1024 * 1024
    /// Init and index further apart than this are read with two requests instead of one.
    static let contiguousHeadSlack: Int64 = 256 * 1024
    /// A whole request's ceiling. A manifest or a representation's head is small, so a minute only
    /// ends an origin that trickles.
    static let resourceTimeoutSeconds: TimeInterval = 60

    private let manifestURL: URL
    private let headers: [String: String]
    private let requestTimeout: TimeInterval
    private let requests = EngineHTTPRequests()

    private let lock = NSLock()
    private var cancelled = false
    private var openedReaders: [IOReader] = []

    init(manifestURL: URL, headers: [String: String], requestTimeout: TimeInterval = 30) {
        self.manifestURL = manifestURL
        self.headers = headers
        self.requestTimeout = requestTimeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let readers = openedReaders
        lock.unlock()
        requests.cancelAll()
        readers.forEach { $0.cancel() }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    func open() throws -> DASHVirtualMP4Reader {
        let (data, baseURL) = try fetchManifest()
        let manifest = try DASHManifest.parse(data, manifestURL: baseURL)
        let selected = try manifest.selectRepresentations()
        if isCancelled { throw DASHSourceError.cancelled }

        // Each representation waits on its head's round trip, so they open side by side.
        let results = BlockingWork.lanes(count: selected.count, isStopped: { [weak self] in self?.isCancelled ?? true }) {
            _, i in Result { try self.openRepresentation(selected[i]) }
        }
        var readers: [IOReader] = []
        var sources: [DASHVirtualLayout.Source] = []
        var failure: Error?
        for result in results {
            switch result {
            case .success(let pair)?:
                readers.append(pair.0)
                sources.append(pair.1)
            case .failure(let error)?:
                failure = failure ?? error
            case nil:
                failure = failure ?? DASHSourceError.cancelled
            }
        }
        if let failure {
            readers.forEach { $0.close() }
            throw failure
        }
        let layout: DASHVirtualLayout
        do {
            layout = try DASHVirtualLayout.build(sources: sources, durationSeconds: manifest.durationSeconds)
        } catch {
            readers.forEach { $0.close() }
            throw error
        }
        lock.withLock { openedReaders = [] }

        let tracks = selected.map { rep in
            "\(rep.kind == .video ? "video" : "audio") id=\(rep.id) codecs=\(rep.codecs ?? "?") "
                + "bandwidth=\(rep.bandwidth)" + (rep.language.map { " lang=\($0)" } ?? "")
        }
        EngineLog.emit(
            "[DASH] AE#859: \(selected.count) representation(s) of "
            + "\(manifest.adaptationSets.reduce(0) { $0 + $1.representations.count }) laid out as one "
            + "fragmented MP4: \(layout.pieces.count) subsegments, \(layout.totalSize) bytes, "
            + "header \(layout.header.count) bytes; " + tracks.joined(separator: "; "),
            category: .demux)
        return DASHVirtualMP4Reader(layout: layout, sources: readers)
    }

    // MARK: - Private

    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<T, Error> = .failure(DASHSourceError.cancelled)
        func set(_ result: Result<T, Error>) { lock.withLock { value = result } }
        func get() throws -> T { try lock.withLock { value }.get() }
    }

    /// Runs one fetch and waits for it. The open runs on a blocking thread (the demuxer's open, or one
    /// of the lanes above); the fetch itself waits on nothing but the session's callbacks.
    private func run<T: Sendable>(_ fetch: @escaping @Sendable () async throws -> T) throws -> T {
        if isCancelled { throw DASHSourceError.cancelled }
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        BlockingWork.detached {
            do { outcome.set(.success(try await fetch())) } catch { outcome.set(.failure(error)) }
            done.signal()
        }
        done.wait()
        if isCancelled { throw DASHSourceError.cancelled }
        return try outcome.get()
    }

    private func request(_ url: URL, range: ClosedRange<Int64>? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return request
    }

    private static func unreachable(_ error: Error) -> DASHSourceError {
        let ns = error as NSError
        return .representationUnreachable("\(ns.domain) \(ns.code)")
    }

    private func fetchManifest() throws -> (Data, URL) {
        let request = request(manifestURL)
        let requests = requests
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try run {
                try await BoundedFetch.data(for: request, session: EngineHTTP.session, limit: Self.manifestByteLimit,
                                            resourceTimeout: Self.resourceTimeoutSeconds, owner: requests)
            }
        } catch is BoundedFetch.Exceeded {
            throw DASHSourceError.manifestTooLarge(Self.manifestByteLimit)
        } catch let error as DASHSourceError {
            throw error
        } catch {
            throw Self.unreachable(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw DASHSourceError.representationUnreachable("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else { throw AVIOReaderError.httpStatus(http.statusCode) }
        guard DASHManifest.bodyBeginsWithManifest([UInt8](data.prefix(4096))) else {
            throw DASHSourceError.notAManifest
        }
        // Relative BaseURLs resolve against where the manifest was finally served from.
        return (data, http.url ?? manifestURL)
    }

    /// The bytes of `range` and the file's total size, from a 206 that starts where it was asked to.
    /// The head requests double as the range probe: a file whose origin answers them with a 200
    /// cannot be addressed by SegmentBase at all. Only the asked bytes are read; an origin that sends
    /// more has its transfer ended there.
    private func fetchRange(_ rep: DASHManifest.Representation, _ range: ClosedRange<Int64>) throws -> ([UInt8], Int64) {
        let count = range.upperBound - range.lowerBound + 1
        guard count > 0, count <= 64 * 1024 * 1024 else {
            throw DASHSourceError.malformedIndex("representation \(rep.id) declares a \(count) byte head")
        }
        let ignoresRange = DASHSourceError.representationUnreachable(
            "representation \(rep.id): the origin ignores Range requests, which SegmentBase addressing needs")
        let request = request(rep.url, range: range)
        let requests = requests
        var attempt = 0
        while true {
            do {
                let (bytes, response): ([UInt8], HTTPURLResponse) = try run {
                    let body = try await BoundedFetch.stream(
                        for: request, session: EngineHTTP.session, limit: Int(count),
                        resourceTimeout: Self.resourceTimeoutSeconds, owner: requests)
                    guard let http = body.response as? HTTPURLResponse else {
                        throw DASHSourceError.representationUnreachable("no HTTP response")
                    }
                    guard (200..<300).contains(http.statusCode) else { throw AVIOReaderError.httpStatus(http.statusCode) }
                    guard http.statusCode == 206 else { throw ignoresRange }
                    var bytes: [UInt8] = []
                    bytes.reserveCapacity(Int(count))
                    for try await chunk in body.chunks {
                        bytes.append(contentsOf: chunk.prefix(Int(count) - bytes.count))
                        if bytes.count >= Int(count) { break }
                    }
                    return (bytes, http)
                }
                let contentRange = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                guard contentRange.hasPrefix("bytes \(range.lowerBound)-"),
                      let total = HTTPDiscIOReader.parseContentRangeTotal(contentRange), total > range.upperBound,
                      Int64(bytes.count) >= count else {
                    throw DASHSourceError.representationUnreachable(
                        "representation \(rep.id) answered \(bytes.count) bytes (\(contentRange)) for bytes \(range.lowerBound)-\(range.upperBound)")
                }
                return (bytes, total)
            } catch is BoundedFetch.Exceeded {
                // A declared body longer than the range asked for: the origin is sending the whole file.
                throw ignoresRange
            } catch let error as DASHSourceError {
                guard attempt == 0, error != .cancelled, error != ignoresRange else { throw error }
                attempt += 1
            } catch let error as AVIOReaderError {
                throw error
            } catch {
                guard attempt == 0, !isCancelled else { throw Self.unreachable(error) }
                attempt += 1
            }
        }
    }

    private func openRepresentation(_ rep: DASHManifest.Representation) throws -> (IOReader, DASHVirtualLayout.Source) {
        guard let segmentBase = rep.segmentBase else {
            throw DASHSourceError.noPlayableRepresentation("representation \(rep.id) has no SegmentBase")
        }
        let initRange = segmentBase.initialization
        let indexRange = segmentBase.index
        let initialization: [UInt8]
        let index: [UInt8]
        let total: Int64
        if indexRange.lowerBound >= initRange.lowerBound,
           indexRange.lowerBound - initRange.upperBound <= Self.contiguousHeadSlack {
            let (head, size) = try fetchRange(rep, initRange.lowerBound...max(initRange.upperBound, indexRange.upperBound))
            initialization = Array(head[0..<Int(initRange.count)])
            let indexStart = Int(indexRange.lowerBound - initRange.lowerBound)
            index = Array(head[indexStart..<(indexStart + Int(indexRange.count))])
            total = size
        } else {
            (initialization, total) = try fetchRange(rep, initRange)
            (index, _) = try fetchRange(rep, indexRange)
        }
        // The size is known from the head's Content-Range, so the reader starts without a probe.
        guard let reader = HTTPDiscIOReader(url: rep.url, extraHeaders: headers,
                                            requestTimeout: requestTimeout, knownSize: total) else {
            throw DASHSourceError.representationUnreachable("representation \(rep.id) did not answer")
        }
        lock.lock()
        let cancelledNow = cancelled
        if !cancelledNow { openedReaders.append(reader) }
        lock.unlock()
        if cancelledNow {
            reader.close()
            throw DASHSourceError.cancelled
        }
        return (reader, .init(initialization: initialization, index: index,
                              indexOffset: indexRange.lowerBound, language: rep.language))
    }
}
