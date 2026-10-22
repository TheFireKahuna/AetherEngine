import Foundation
import AVFoundation
import os

/// An `AVPlayerItem`'s access and error logs, read the way the running system wants them read.
///
/// tvOS / macOS 27 deprecate the synchronous `accessLog()` and `errorLog()` getters for
/// `fetchAccessLogWithCompletionHandler:` and `fetchErrorLogWithCompletionHandler:` (Swift: the async `accessLog()` and
/// `errorLog()`). The getters block their thread on the media server, which is why every engine reader already runs
/// them off the main actor on a thread of its own (`AVFoundationOffMain`, the diagnostic lanes); a stranded server
/// stranded the thread with them. On 27 the fetch answers through a completion instead, so:
///
/// - `access(of:timeout:)` and `errors(of:timeout:)` are for those readers: they keep their thread, wait on the fetch
///   for at most `timeout`, and give up with nil rather than strand it. Before 27 they are the getters, as before.
/// - `errors(of:)` is the async form, for a caller on the main actor, which must not block at all.
enum ItemLogs {

    /// How long a blocking read waits on 27. The fetch answers in milliseconds from a healthy media server; past this
    /// it is not answering, and a diagnostic read is worth less than the thread.
    static let defaultTimeout: DispatchTimeInterval = .seconds(2)

    static func access(of item: AVPlayerItem, timeout: DispatchTimeInterval = defaultTimeout) -> AVPlayerItemAccessLog? {
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            return waitFor(timeout) { done in item.fetchAccessLog { done($0) } }
        }
        return item.accessLog()
    }

    static func errors(of item: AVPlayerItem, timeout: DispatchTimeInterval = defaultTimeout) -> AVPlayerItemErrorLog? {
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            return waitFor(timeout) { done in item.fetchErrorLog { done($0) } }
        }
        return item.errorLog()
    }

    /// The error log without blocking the caller: the fetch on 27, the getter on another thread before it.
    static func errors(of item: AVPlayerItem) async -> AVPlayerItemErrorLog? {
        nonisolated(unsafe) let read = item
        if #available(macOS 27, iOS 27, tvOS 27, watchOS 27, visionOS 27, *) {
            return await withCheckedContinuation { (answer: CheckedContinuation<UncheckedLog<AVPlayerItemErrorLog>, Never>) in
                read.fetchErrorLog { answer.resume(returning: UncheckedLog(value: $0)) }
            }.value
        }
        return await BlockingWork.detached { UncheckedLog(value: read.errorLog()) }.value.value
    }

    /// The HTTP and media error codes the error log carries, newest last; empty when there is no log.
    static func errorStatusCodes(of item: AVPlayerItem) async -> [Int] {
        await errors(of: item)?.events.map(\.errorStatusCode) ?? []
    }

    /// A log handed from AVFoundation's completion to the reader. The logs are immutable snapshots, and each is
    /// handed over once (`NS_SWIFT_SENDING`), which is what the opt-out asserts.
    struct UncheckedLog<Log>: @unchecked Sendable {
        let value: Log?
    }

    /// Runs `fetch` and waits for its answer for at most `timeout`. A late answer is dropped.
    private static func waitFor<Log>(_ timeout: DispatchTimeInterval,
                                     _ fetch: (@escaping @Sendable (Log?) -> Void) -> Void) -> Log? {
        let answered = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<UncheckedLog<Log>>(uncheckedState: UncheckedLog(value: nil))
        fetch { log in
            box.withLockUnchecked { $0 = UncheckedLog(value: log) }
            answered.signal()
        }
        guard answered.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.withLockUnchecked { $0 }.value
    }
}
