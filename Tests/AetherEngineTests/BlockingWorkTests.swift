import Foundation
import Testing
@testable import AetherEngine

@Suite(.timeLimit(.minutes(1)))
struct BlockingWorkTests {
    private static func currentQueueLabel() -> String {
        String(cString: __dispatch_queue_get_label(nil))
    }

    @Test("Blocking work runs off the cooperative pool, before and after an await")
    func runsOffThePool() async {
        let labels = await BlockingWork.detached(priority: .userInitiated) { () async -> [String] in
            let before = Self.currentQueueLabel()
            await Task.yield()
            return [before, Self.currentQueueLabel()]
        }.value
        #expect(labels.allSatisfy { !$0.contains("cooperative") }, "ran on \(labels)")
    }

    // More blocked jobs than the pool has threads: on the pool the last waiter could never
    // start, here every one of them is parked at once.
    @Test("Blocked jobs do not hold the cooperative pool")
    func blockedJobsLeaveThePoolFree() async throws {
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let gate = ProbeTestGate()
        let parked = ProbeTestBox(0)
        let tasks = (0..<count).map { _ in
            BlockingWork.detached { gate.wait { parked.update { $0 += 1 } } }
        }
        try await waitFor { parked.value == count }
        gate.open()
        for task in tasks { await task.value }
    }

    @Test("The off-pool trait moves a synchronous test body off the cooperative pool", .offCooperativePool)
    func traitMovesASyncBody() {
        let label = Self.currentQueueLabel()
        #expect(!label.contains("cooperative"), "ran on \(label)")
    }

    @Test("A throwing operation reports its error")
    func throwsThrough() async {
        struct Refused: Error {}
        let task = BlockingWork.detached { () async throws -> Int in throw Refused() }
        await #expect(throws: Refused.self) { try await task.value }
    }

    /// Every `Sources/AetherEngine` line whose code (not its comment) contains `text`, outside
    /// `BlockingWork.swift`, the one place that may.
    private static func sourceLines(containing text: String) throws -> [String] {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" && url.lastPathComponent != "BlockingWork.swift" {
            let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let code = line.components(separatedBy: "//").first ?? ""
                if code.contains(text) { offenders.append("\(url.lastPathComponent):\(index + 1)") }
            }
        }
        return offenders
    }

    @Test("No engine source creates a detached task on the cooperative pool")
    func noBareDetachedTasks() throws {
        let offenders = try Self.sourceLines(containing: "Task.detached")
        #expect(offenders.isEmpty, "use BlockingWork.detached: \(offenders)")
    }

    @Test("No engine source fans blocking work out with concurrentPerform")
    func noConcurrentPerform() throws {
        let offenders = try Self.sourceLines(containing: "concurrentPerform")
        #expect(offenders.isEmpty, "use BlockingWork.lanes: \(offenders)")
    }

    // MARK: - Lanes

    @Test("Lanes run every item once, results in the order asked, each lane striding by the width")
    func lanesCoverEveryItem() {
        let results = BlockingWork.lanes(count: 100, width: 7) { lane, i in [lane, i] }
        #expect(results.count == 100)
        for (i, result) in results.enumerated() {
            #expect(result == [i % 7, i])
        }
        #expect(BlockingWork.lanes(count: 0) { _, i in i }.isEmpty)
        #expect(BlockingWork.lanes(count: 3, width: 12) { lane, _ in lane } == [0, 1, 2])
    }

    @Test("Lanes that wait run side by side, never more at once than the width, on a busy machine too")
    func lanesOverlapBlockingWork() {
        final class Gauge: @unchecked Sendable {
            private let lock = NSLock()
            private var inFlight = 0
            private(set) var peak = 0
            func enter() { lock.withLock { inFlight += 1; peak = max(peak, inFlight) } }
            func leave() { lock.withLock { inFlight -= 1 } }
        }
        let gauge = Gauge()
        _ = BlockingWork.lanes(count: 120, width: 12) { _, i -> Int? in
            gauge.enter()
            defer { gauge.leave() }
            Thread.sleep(forTimeInterval: 0.005)
            return i
        }
        #expect(gauge.peak > 1)
        #expect(gauge.peak <= 12)
    }

    @Test("A stopped run takes no more items")
    func lanesStop() {
        final class Count: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func bump() -> Int { lock.withLock { n += 1; return n } }
            var value: Int { lock.withLock { n } }
        }
        let count = Count()
        let results = BlockingWork.lanes(count: 1000, width: 4, isStopped: { count.value >= 10 }) { _, i -> Int? in
            _ = count.bump()
            return i
        }
        #expect(results.count == 1000)
        // Each lane may be partway through one item when the tenth lands.
        #expect(count.value < 10 + 4)
        #expect(results.compactMap { $0 }.count == count.value)
    }

    @Test("Job priorities map onto the matching GCD class")
    @available(visionOS 2, *)
    func priorityMapping() {
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.userInitiated.rawValue)) == .userInitiated)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.utility.rawValue)) == .utility)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: TaskPriority.background.rawValue)) == .background)
        #expect(BlockingExecutor.qos(for: JobPriority(rawValue: 0)) == .default)
    }
}
