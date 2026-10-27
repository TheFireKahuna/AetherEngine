import Foundation

/// Where engine work that blocks its thread runs: a demuxer open, a packet read, a FIFO write
/// under backpressure, a `close()` that joins a pump, a `waitForFinish`.
///
/// `Task.detached` is no background thread. It runs on the Swift cooperative pool, which has one
/// thread per core and never grows, so every blocked job takes a core's worth of async work out
/// of the whole process, the host app's included. On a 3-core CI runner the test suite parked
/// all three for half a minute at a time (a 120 s time limit fired at 151 s, because the
/// watchdog is a task on the same pool), and an Apple TV has few more cores than that.
///
/// A task created here prefers `BlockingExecutor`, which runs its jobs on GCD's global queues.
/// Those add a thread when one blocks in the kernel, which is the whole difference. The task is
/// otherwise an ordinary one: it awaits, hops to the main actor and back, and is cancelled like
/// any other.
enum BlockingWork {
    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async -> Success
    ) -> Task<Success, Never> {
        if #available(visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }

    @discardableResult
    static func detached<Success: Sendable>(
        priority: TaskPriority? = nil,
        operation: sending @escaping @isolated(any) () async throws -> Success
    ) -> Task<Success, any Error> {
        if #available(visionOS 2, *) {
            return Task.detached(executorPreference: BlockingExecutor.shared, priority: priority, operation: operation)
        }
        return Task.detached(priority: priority, operation: operation)
    }
}

extension BlockingWork {
    /// Lanes for reads that wait on the network: a remote range read costs a round trip each (about 40 ms
    /// measured through a reverse proxy), so they go out side by side.
    static let readLanes = 12

    /// `DispatchQueue.concurrentPerform` for blocking work. `body(lane, i)` runs for every `i` in
    /// `0..<count` on `width` lanes, lane `l` taking `l`, `l + width`, ... in turn, so a lane can hold a
    /// resource of its own (a reader) for all of its items. A lane takes no more once `isStopped()`.
    /// Returns the results in the order asked, nil for an item not run or that answered nil, once every
    /// lane has finished; the calling thread waits.
    ///
    /// Each lane is a thread of its own, at `qos` (by default the caller's). Not `concurrentPerform`, which
    /// sizes its width to the CPUs it finds idle: right for CPU work, it ran network reads one at a time on
    /// a loaded machine. Not GCD's global queues either, where `detached` runs: their pool is bounded and
    /// shared by all of the engine's blocking work, and lanes parked on round trips there (a whole-film
    /// subtitle pull is thousands) held it from everything else, which failed tests across the suite.
    static func lanes<T: Sendable>(count: Int, width: Int = readLanes,
                                   qos: QualityOfService = Thread.current.qualityOfService,
                                   isStopped: @escaping @Sendable () -> Bool = { false },
                                   _ body: @escaping @Sendable (_ lane: Int, _ index: Int) -> T?) -> [T?] {
        guard count > 0, width > 0 else { return [] }
        let results = LaneResults<T>(count)
        let lanes = min(width, count)
        let done = DispatchGroup()
        for lane in 0..<lanes {
            done.enter()
            let thread = Thread {
                defer { done.leave() }
                for i in stride(from: lane, to: count, by: lanes) {
                    guard !isStopped() else { break }
                    results.set(i, body(lane, i))
                }
            }
            thread.name = "aether.lane.\(lane)"
            thread.qualityOfService = qos
            thread.start()
        }
        done.wait()
        return results.all
    }
}

/// What `BlockingWork.lanes` collects, written from its lanes.
private final class LaneResults<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T?]
    init(_ count: Int) { items = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ item: T?) { lock.withLock { items[i] = item } }
    var all: [T?] { lock.withLock { items } }
}

/// Runs each job on the GCD global queue that matches its priority. Stateless and shared, so a
/// task's preference never outlives what it points at.
@available(visionOS 2, *)
final class BlockingExecutor: TaskExecutor {
    static let shared = BlockingExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let qos = Self.qos(for: job.priority)
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        DispatchQueue.global(qos: qos).async {
            job.runSynchronously(on: executor)
        }
    }

    static func qos(for priority: JobPriority) -> DispatchQoS.QoSClass {
        switch TaskPriority(rawValue: priority.rawValue) {
        case .high: return .userInitiated
        case .medium: return .default
        case .low: return .utility
        case .background: return .background
        default: return priority.rawValue > TaskPriority.high.rawValue ? .userInteractive : .default
        }
    }
}
