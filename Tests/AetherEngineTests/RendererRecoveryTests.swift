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

    private func pcm(pts: Int64) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                               mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4096, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: 4096,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                        presentationTimeStamp: CMTime(value: pts, timescale: 48_000), decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: try #require(format), sampleCount: 1024, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
        return try #require(out)
    }

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    @Test("the audio output reports a failed renderer once, and again only after a flush")
    func audioReportsOncePerFlush() throws {
        let output = AudioOutput()
        let reports = Count()
        output.onRendererFailed = { _ in reports.bump() }
        output.simulatesRendererFailureForTesting = true
        output.enqueue(sampleBuffer: try pcm(pts: 0))
        output.enqueue(sampleBuffer: try pcm(pts: 1024))
        #expect(reports.value == 1)
        output.flush()
        output.enqueue(sampleBuffer: try pcm(pts: 2048))
        #expect(reports.value == 2)
    }

    /// A buffer no renderer can play: an unknown compressed format. On macOS it fails the renderer for real
    /// (-11800), which `simulatesRendererFailureForTesting` only pretends.
    private func unplayable(pts: Int64) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: 0x7878_7878, mFormatFlags: 0,
                                               mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 512, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: 512,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        var packet = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: 512)
        var out: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format), sampleCount: 1,
            presentationTimeStamp: CMTime(value: pts, timescale: 48_000), packetDescriptions: &packet,
            sampleBufferOut: &out)
        return try #require(out)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    @Test("a flush does not bring a failed audio renderer back, which is why the ladder replaces it")
    func flushDoesNotReviveAudio() async throws {
        let output = AudioOutput()
        let reports = Count()
        output.onRendererFailed = { _ in reports.bump() }
        output.enqueue(sampleBuffer: try unplayable(pts: 0))
        #expect(try await waitUntil { reports.value == 1 })
        output.flush()
        output.enqueue(sampleBuffer: try pcm(pts: 1024))
        #expect(try await waitUntil { reports.value == 2 }, "still failed after a flush and valid PCM")
        #expect(output.renderer.status == .failed)
    }

    @Test("a failed audio renderer is replaced under the clock: a new one attached, fed again, at the old volume")
    func replacesTheFailedRenderer() async throws {
        let output = AudioOutput()
        output.volume = 0.25
        let reports = Count()
        output.onRendererFailed = { _ in reports.bump() }
        // The renderer fails on a buffer it cannot play only when that is its first format.
        output.enqueue(sampleBuffer: try unplayable(pts: 0))
        output.enqueue(sampleBuffer: try pcm(pts: 1024))
        output.enqueue(sampleBuffer: try pcm(pts: 2048))
        #expect(try await waitUntil { reports.value == 1 })
        let failed = output.renderer
        #expect(failed.status == .failed)

        let refed = output.replaceFailedRenderer()
        let fresh = output.renderer
        #expect(fresh !== failed)
        #expect(refed == 3, "everything from the buffer the stopped clock is in on")
        #expect(fresh.volume == 0.25)
        #expect(output.rendererReplacementCount == 1)
        #expect(try await waitUntil { !output.synchronizer.renderers.contains { $0 === failed } },
                "the failed renderer leaves the synchronizer")
        #expect(output.synchronizer.renderers.contains { $0 === fresh })

        // The refeed carried the unplayable buffer too, so the new renderer fails on it and says so: reported afresh.
        #expect(try await waitUntil { reports.value == 2 })
        // The replaced renderer is no longer listened to: its automatic flush would throw away the refeed.
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: failed)
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: failed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(output.automaticFlushCount == 0)
        #expect(output.outputReconfigurationCount == 0)
        // A failure the replaced renderer reports late is not one of the renderer playing now.
        output.flush()
        let replacedAgain = output.replaceFailedRenderer()
        #expect(replacedAgain == 0, "a flush left nothing to give back")
        output.enqueue(sampleBuffer: try pcm(pts: 4096))
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
