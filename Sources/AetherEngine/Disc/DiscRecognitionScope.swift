import Foundation

/// The reading one disc recognition does of its own: the small files (`.mpls`, `.clpi`) it reads from an
/// image, and the readers it opens on a folder's files. `stop()` ends it: no file is read after it, and the
/// folder files being read are cancelled.
///
/// A stop reaches nothing else. The source recognition reads from can be handed on to a successor session
/// (AE#460, `CustomIOReaderBridge.markClosed`), so cancelling it could end the successor's reading; the
/// readers a recognition opens are its own, and cancelling them ends only this one.
final class DiscRecognitionScope: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var reading: [ObjectIdentifier: IOReader] = [:]
    private let stoppedOutside: @Sendable () -> Bool

    /// `stoppedOutside`: a stop this scope does not hear about, polled before each file (a probe's
    /// `ProbeControl`, whose one interruption handler its reader holds).
    init(stoppedOutside: @escaping @Sendable () -> Bool = { false }) {
        self.stoppedOutside = stoppedOutside
    }

    var isStopped: Bool { lock.withLock { stopped } || stoppedOutside() }

    func stop() {
        let readers: [IOReader] = lock.withLock {
            stopped = true
            return Array(reading.values)
        }
        readers.forEach { $0.cancel() }
    }

    /// `body` over a file `open` opens for this recognition, the file closed after it; nil, with `body`
    /// not called, once the scope is stopped. A stop that lands while the file is being read cancels it,
    /// and one that lands while it opens is seen before it is read.
    func withFile<T>(_ open: () -> IOReader?, _ body: (IOReader) -> T) -> T? {
        guard !isStopped, let reader = open() else { return nil }
        let id = ObjectIdentifier(reader)
        defer {
            lock.withLock { _ = reading.removeValue(forKey: id) }
            reader.close()
        }
        let registered = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            reading[id] = reader
            return true
        }
        guard registered else { return nil }
        return body(reader)
    }
}
