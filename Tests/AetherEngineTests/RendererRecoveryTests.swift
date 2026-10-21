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

    @Test("failures inside the window climb reposition, rebuild, fail, and stay at fail")
    func climbs() {
        var ladder = RendererRecoveryLadder()
        #expect(ladder.next(at: t0) == .reposition)
        #expect(ladder.next(at: t0.addingTimeInterval(5)) == .rebuild)
        #expect(ladder.next(at: t0.addingTimeInterval(30)) == .fail)
        #expect(ladder.next(at: t0.addingTimeInterval(31)) == .fail)
    }

    @Test("a step that held for the window is forgotten, so the next failure starts from the bottom")
    func expires() {
        var ladder = RendererRecoveryLadder()
        #expect(ladder.next(at: t0) == .reposition)
        #expect(ladder.next(at: t0.addingTimeInterval(RendererRecoveryLadder.window + 1)) == .reposition)
        // The rebuild is what the window is measured from once it has been taken.
        #expect(ladder.next(at: t0.addingTimeInterval(RendererRecoveryLadder.window + 2)) == .rebuild)
        #expect(ladder.next(at: t0.addingTimeInterval(2 * RendererRecoveryLadder.window + 1)) == .fail)
        ladder.reset()
        #expect(ladder.next(at: t0.addingTimeInterval(2 * RendererRecoveryLadder.window + 2)) == .reposition)
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

    @MainActor
    @Test("a session that cannot be rebuilt fails at the rebuild step, where the host app sees it")
    func refusedRebuildFails() throws {
        let engine = try AetherEngine()
        engine.state = .playing
        engine.climbRendererRecovery(.audio, error: "test")
        #expect(engine.errorInfo == nil, "the first step repositions")
        engine.climbRendererRecovery(.audio, error: "test")
        #expect(engine.errorInfo?.kind == .softwarePipelineFailed)
        if case .error = engine.state {} else { Issue.record("state is \(engine.state), not .error") }
    }

    @MainActor
    @Test("a stopped or failed session takes no step")
    func idleTakesNoStep() throws {
        let engine = try AetherEngine()
        engine.climbRendererRecovery(.video, error: "test")
        engine.climbRendererRecovery(.video, error: "test")
        #expect(engine.errorInfo == nil)
        #expect(engine.rendererRecoveryLadder.next(at: Date()) == .reposition)
    }
}
