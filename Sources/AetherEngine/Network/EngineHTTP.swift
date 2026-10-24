import Foundation

/// The engine's one connection pool.
///
/// A `URLSession` keeps a connection pool of its own, so every session the engine made was its own
/// handshake and its own connection to the same origin: about a dozen per playing source (the pump's
/// ranges, detour blocks, probes, the prewarm, the indexed subtitle lanes, the HLS ingest and relay
/// paths). Over HTTP/3 one connection multiplexes all of them, which is only true when they share a
/// session. So every engine fetch runs here, and what used to be configured per session is carried
/// by the request or the task instead:
///
/// - The idle timeout is `URLRequest.timeoutInterval`, set where the request is built.
/// - The resource ceiling (`timeoutIntervalForResource`, the cap that keeps a trickling origin from
///   holding a fetch open for days, audit NET-10) is a per-task deadline, `armResourceDeadline`.
/// - Teardown that used to be `invalidateAndCancel()` on an owned session is `EngineHTTPRequests`:
///   an owner ends its own requests, never another reader's.
/// - Trust and redirects stay on per-task delegates over `EngineTLS`, as they already were.
///
/// Two kinds of fetch stay on sessions of their own, on purpose: the system-trust probe
/// (`HLSOriginRelay.systemTrustRefuses`), which must not ride a connection the host's evaluator has
/// already accepted, and the HTTP/1.1 stream transports (`HeldSourceConnection`,
/// `PersistentHTTP1Transport`), whose point is a connection of their own. A session a test injects is
/// also left as it is.
enum EngineHTTP {
    /// Connections the pool may hold to one host. Over HTTP/3 or HTTP/2 there is one whatever this
    /// says; it binds only an HTTP/1.1 origin, and there it must not bind (#450). The pool carries
    /// open-ended requests (a live pump holds its connection for the whole session), so a request on
    /// top of a cap is not slowed but parked behind connections that are not going to end, with no
    /// callback, no error and no metrics: four live tiles against one origin left tiles 3 and 4 at
    /// zero bytes while `curl` pulled the same endpoints at full rate. So it sits above any plausible
    /// reader count, and what the engine asks of an origin is bounded by `OriginRequestBudget`
    /// (#377) instead, which counts requests (what an origin meters), waits with a budget, says that
    /// it waited, and lowers itself when the origin answers 429/503/509.
    static let connectionsPerHost = 64

    /// One serial queue for every callback: per-task ordering needs a serial queue, and each callback
    /// is a copy into a buffer and a signal, never work. User-initiated, because these callbacks
    /// deliver foreground playback bytes and return origin slots to blocked demux threads, and
    /// URLSession's implicit queue can run at utility QoS with no way to donate priority through a
    /// semaphore.
    static let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "aether.http.callbacks"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = connectionsPerHost
        // The ceiling is per task now (`armResourceDeadline`); the session imposes none of its own.
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration, delegate: EngineTLS.sessionDelegate,
                          delegateQueue: delegateQueue)
    }()

    private static let deadlineQueue = DispatchQueue(label: "aether.http.deadline", qos: .utility)

    /// Ends `task` once `seconds` have passed since now, whatever it is doing: the per-task form of
    /// `timeoutIntervalForResource`. Nil arms nothing (a long-lived connection). `onExpiry` runs first,
    /// so a caller can report the end as the timeout it is rather than as a cancel.
    static func armResourceDeadline(_ task: URLSessionTask, seconds: TimeInterval?,
                                    onExpiry: (@Sendable () -> Void)? = nil) {
        guard let seconds, seconds.isFinite, seconds > 0 else { return }
        deadlineQueue.asyncAfter(deadline: .now() + seconds) { [weak task] in
            guard let task, task.state == .running || task.state == .suspended else { return }
            onExpiry?()
            task.cancel()
        }
    }
}

/// The requests one owner has on `EngineHTTP.session`, so the owner can end its own at teardown.
/// Holds them weakly: a finished task drops out by itself.
final class EngineHTTPRequests: @unchecked Sendable {
    private let lock = NSLock()
    private let tasks = NSHashTable<URLSessionTask>.weakObjects()
    private var cancelled = false

    /// Records `task`; a task tracked after `cancelAll` is cancelled on the spot.
    func track(_ task: URLSessionTask) {
        lock.lock()
        let late = cancelled
        if !late { tasks.add(task) }
        lock.unlock()
        if late { task.cancel() }
    }

    func cancelAll() {
        lock.lock()
        cancelled = true
        let live = tasks.allObjects
        tasks.removeAllObjects()
        lock.unlock()
        live.forEach { $0.cancel() }
    }

    /// Ends what is in flight and keeps accepting new requests (an unblocking cancel, `IOReader.cancel`).
    func cancelInFlight() {
        lock.lock()
        let live = tasks.allObjects
        tasks.removeAllObjects()
        lock.unlock()
        live.forEach { $0.cancel() }
    }
}
