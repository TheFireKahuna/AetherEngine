import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// A renderer that stays failed climbs a ladder: a reposition (whose flush is the documented reset), then a rebuild with
/// new renderers, then the session's failure, each step taken only when the one before it did not hold.
@Suite("Renderer recovery")
struct RendererRecoveryTests {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    @Test("video failures inside the window climb reposition, rebuild, fail, and stay at fail")
    func climbs() {
        var ladder = RendererRecoveryLadder()
        #expect(ladder.next(for: .video, at: t0) == .reposition)
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(5)) == .rebuild)
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(30)) == .fail)
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(31)) == .fail)
    }

    @Test("a failed audio renderer is replaced first, as its header implies, never flushed")
    func audioStartsByReplacing() {
        var ladder = RendererRecoveryLadder()
        #expect(ladder.next(for: .audio, at: t0) == .replace)
        #expect(ladder.next(for: .audio, at: t0.addingTimeInterval(5)) == .rebuild)
        #expect(ladder.next(for: .audio, at: t0.addingTimeInterval(6)) == .fail)
        // One ladder per session: a video failure after an audio replacement that did not hold is the next step.
        var mixed = RendererRecoveryLadder()
        #expect(mixed.next(for: .audio, at: t0) == .replace)
        #expect(mixed.next(for: .video, at: t0.addingTimeInterval(1)) == .rebuild)
    }

    @Test("a step that held for the window is forgotten, so the next failure starts from the bottom")
    func expires() {
        var ladder = RendererRecoveryLadder()
        #expect(ladder.next(for: .video, at: t0) == .reposition)
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(RendererRecoveryLadder.window + 1)) == .reposition)
        // The rebuild is what the window is measured from once it has been taken.
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(RendererRecoveryLadder.window + 2)) == .rebuild)
        #expect(ladder.next(for: .video, at: t0.addingTimeInterval(2 * RendererRecoveryLadder.window + 1)) == .fail)
        ladder.reset()
        #expect(ladder.next(for: .audio, at: t0.addingTimeInterval(2 * RendererRecoveryLadder.window + 2)) == .replace)
    }

    @Test("the video renderer reports after three failed enqueues, then every 120 while no flush ends the run")
    func videoReportCadence() {
        let reported = (1...300).filter { SampleBufferRenderer.reportsFailure(afterConsecutiveFailedEnqueues: $0) }
        #expect(reported == [3, 123, 243])
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    /// Feeds PCM the way a playing session does, from `pts` on, until `reports` reaches `count`. The renderer's own
    /// path sees a failure through its status at once; the receiver reports it with the enqueue after it, so the
    /// feed carrying on is what delivers it on that path. Returns the next free timestamp.
    private func feed(_ output: AudioOutput, from pts: Int64, until reports: Count, reach count: Int) async throws -> Int64 {
        var next = pts
        for _ in 0..<100 where reports.value < count {
            output.enqueue(sampleBuffer: try audioPacket(pts: next))
            next += 1024
            try await Task.sleep(for: .milliseconds(20))
        }
        return next
    }

    @Test("a flush does not bring a failed audio renderer back, which is why the ladder replaces it",
          arguments: audioOutputPaths)
    func flushDoesNotReviveAudio(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let reports = Count()
        output.onRendererFailed = { _ in reports.bump() }
        // A format no renderer can play fails it for real.
        output.enqueue(sampleBuffer: try audioPacket(pts: 0, format: 0x7878_7878))
        let next = try await feed(output, from: 1024, until: reports, reach: 1)
        #expect(reports.value == 1)
        output.flush()
        _ = try await feed(output, from: next, until: reports, reach: 2)
        #expect(reports.value == 2, "still failed after a flush and valid PCM")
        #expect(output.renderer.status == .failed)
    }

    @Test("a failed audio renderer is replaced under the clock: a new one attached, fed again, at the old volume",
          arguments: audioOutputPaths)
    func replacesTheFailedRenderer(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.volume = 0.25
        let reports = Count()
        output.onRendererFailed = { _ in reports.bump() }
        // The renderer fails on a buffer it cannot play only when that is its first format.
        output.enqueue(sampleBuffer: try audioPacket(pts: 0, format: 0x7878_7878))
        let next = try await feed(output, from: 1024, until: reports, reach: 1)
        #expect(reports.value == 1)
        let failed = output.renderer
        #expect(failed.status == .failed)

        let refed = output.replaceFailedRenderer()
        let fresh = output.renderer
        #expect(fresh !== failed)
        #expect(refed == Int(next / 1024), "everything from the buffer the stopped clock is in on")
        #expect(fresh.volume == 0.25)
        #expect(output.usesReceiver == throughReceivers, "the replacement goes the way the first renderer went")
        #expect(output.rendererReplacementCount == 1)
        try await waitFor { !output.synchronizer.renderers.contains { $0 === failed } }
        #expect(output.synchronizer.renderers.contains { $0 === fresh })

        // The refeed carried the unplayable buffer too, so the new renderer fails on it and says so: reported afresh.
        let after = try await feed(output, from: next, until: reports, reach: 2)
        #expect(reports.value == 2)
        // The replaced renderer is no longer listened to: its automatic flush would throw away the refeed.
        postAutomaticFlush(of: failed)
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: failed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(output.automaticFlushCount == 0)
        #expect(output.outputReconfigurationCount == 0)
        // A failure the replaced renderer reports late is not one of the renderer playing now.
        output.flush()
        let replacedAgain = output.replaceFailedRenderer()
        #expect(replacedAgain == 0, "a flush left nothing to give back")
        for i in 0..<5 { output.enqueue(sampleBuffer: try audioPacket(pts: after + Int64(i) * 1024)) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(reports.value == 2)
        #expect(output.renderer.status != .failed)
    }

    @MainActor
    @Test("a session that cannot be rebuilt fails at the rebuild step, where the host app sees it")
    func refusedRebuildFails() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.climbRendererRecovery(.video, error: "test")
        #expect(engine.errorInfo == nil, "the first step repositions")
        engine.climbRendererRecovery(.video, error: "test")
        #expect(engine.errorInfo?.kind == .softwarePipelineFailed)
        if case .error = engine.state {} else { Issue.record("state is \(engine.state), not .error") }
    }

    @MainActor
    @Test("a failed audio renderer with no output to replace it in goes straight to the rebuild")
    func audioWithNothingToReplaceRebuilds() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.climbRendererRecovery(.audio, error: "test")
        #expect(engine.errorInfo?.kind == .softwarePipelineFailed, "no host: the rebuild is refused, so it fails")
    }

    @MainActor
    @Test("a stopped or failed session takes no step")
    func idleTakesNoStep() throws {
        let engine = try AetherEngine()
        engine.climbRendererRecovery(.video, error: "test")
        engine.climbRendererRecovery(.video, error: "test")
        #expect(engine.errorInfo == nil)
        #expect(engine.rendererRecoveryLadder.next(for: .video, at: Date()) == .reposition)
    }
}
