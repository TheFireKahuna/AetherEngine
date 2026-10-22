import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// The output was configured for another format under the renderer (`…OutputConfigurationDidChange`). The header's
/// remedy is a flush and the buffers again from the playhead, which configures the output for their format; the
/// renderer's own queue is what goes back in, so the gap is its restart rather than the feed's lead.
@Suite("AudioOutput after an output reconfiguration", .serialized)
struct AudioOutputReconfigurationTests {

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CMSampleBuffer] = []
        func add(_ b: CMSampleBuffer) { lock.withLock { buffers.append(b) } }
        var all: [CMSampleBuffer] { lock.withLock { buffers } }
    }

    /// One 1024-frame packet at `pts`, compressed (never decoded here) or LPCM.
    private func buffer(pts: Int64, compressed: Bool) -> CMSampleBuffer? {
        var asbd = compressed
            ? AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                          mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            : AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                          mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        let bytes = compressed ? 64 : 4096
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        var out: CMSampleBuffer?
        if compressed {
            var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes))
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                presentationTimeStamp: CMTime(value: pts, timescale: 48_000), packetDescriptions: &description,
                sampleBufferOut: &out) == noErr else { return nil }
        } else {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                            presentationTimeStamp: CMTime(value: pts, timescale: 48_000), decodeTimeStamp: .invalid)
            guard CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                                       formatDescription: format, sampleCount: 1024, sampleTimingEntryCount: 1,
                                       sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                       sampleBufferOut: &out) == noErr else { return nil }
        }
        return out
    }

    private func run(compressed: Bool) throws -> [CMSampleBuffer] {
        try [0, 1024, 2048, 3072].map { try #require(buffer(pts: $0, compressed: compressed)) }
    }

    private static func pts(_ buffers: [CMSampleBuffer]) -> [Int64] {
        buffers.map { CMSampleBufferGetPresentationTimeStamp($0).convertScale(48_000, method: .roundTowardZero).value }
    }

    private static func trimmedWhole(_ b: CMSampleBuffer) -> Bool {
        (CMGetAttachment(b, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) as? NSDictionary)
            .map { CMTimeMakeFromDictionary($0) } == CMSampleBufferGetDuration(b)
    }

    private let inThird = CMTime(value: 2048 + 10, timescale: 48_000)

    @Test("PCM goes back in from the buffer the clock is in")
    func pcmRefeedsFromThePlayhead() throws {
        let out = AudioOutput.refeed(try run(compressed: false), at: inThird)
        #expect(Self.pts(out) == [2048, 3072])
    }

    @Test("a compressed stream gets the buffer before as a decode-only primer")
    func compressedRefeedIsPrimed() throws {
        let out = AudioOutput.refeed(try run(compressed: true), at: inThird)
        #expect(Self.pts(out) == [1024, 2048, 3072])
        #expect(Self.trimmedWhole(out[0]))
        #expect(!Self.trimmedWhole(out[1]))
    }

    @Test("a clock past everything queued puts nothing back")
    func nothingAfterTheEnd() throws {
        #expect(AudioOutput.refeed(try run(compressed: true), at: CMTime(value: 5000, timescale: 48_000)).isEmpty)
    }

    @Test("the queue keeps the buffer the clock is in, the one before it, and what follows, within its limit")
    func pruning() throws {
        let queued = try run(compressed: true)
        #expect(Self.pts(AudioOutput.pruned(queued, at: inThird, limit: 100)) == [1024, 2048, 3072])
        #expect(Self.pts(AudioOutput.pruned(queued, at: .zero, limit: 100)) == [0, 1024, 2048, 3072])
        #expect(Self.pts(AudioOutput.pruned(queued, at: .zero, limit: 2)) == [2048, 3072])
    }

    @Test("the notification flushes and enqueues the renderer's queue again from the clock", arguments: audioOutputPaths)
    func notificationRefeeds(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        for b in try run(compressed: true) { output.enqueue(sampleBuffer: b) }
        output.synchronizer.setRate(0, time: inThird)
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: output.renderer)
        try await waitFor { output.outputReconfigurationCount == 1 }

        let all = seen.all
        #expect(Self.pts(all) == [0, 1024, 2048, 3072, 1024, 2048, 3072])
        #expect(Self.trimmedWhole(all[4]))
    }

    @Test("a reconfiguration both the stream and the next enqueue report is refed once", arguments: audioOutputPaths)
    func reportedTwiceRefeedsOnce(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let buffers = try run(compressed: false)
        for b in buffers.dropLast() { output.enqueue(sampleBuffer: b) }
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: output.renderer)
        try await waitFor { output.outputReconfigurationCount == 1 }
        // On the receiver this enqueue's result carries the same change again.
        output.enqueue(sampleBuffer: try #require(buffers.last))
        try await Task.sleep(for: .milliseconds(200))
        #expect(output.outputReconfigurationCount == 1)
    }

    @Test("the ledger hands each change to whichever source reports it first, and drops the other's report")
    func ledger() {
        var ledger = ReconfigurationLedger()
        var handled = ledger.reportedByStream()
        #expect(handled)
        var fresh = ledger.reportedByResult(1)
        #expect(fresh == 0, "the stream had it")
        fresh = ledger.reportedByResult(1)
        #expect(fresh == 1, "a change only a result has seen")
        handled = ledger.reportedByStream()
        #expect(!handled, "the result had it")
        #expect(ledger == ReconfigurationLedger())
        // Two in a row from the stream, one result carrying both, then one more on the result alone.
        _ = ledger.reportedByStream()
        _ = ledger.reportedByStream()
        fresh = ledger.reportedByResult(3)
        #expect(fresh == 1)
        handled = ledger.reportedByStream()
        #expect(!handled)
        #expect(ledger == ReconfigurationLedger())
    }

    @Test("a flush (a seek) empties what a reconfiguration would put back", arguments: audioOutputPaths)
    func flushEmptiesTheQueue(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        for b in try run(compressed: false) { output.enqueue(sampleBuffer: b) }
        output.flush()
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: output.renderer)
        try await waitFor { output.outputReconfigurationCount == 1 }
        #expect(seen.all.count == 4)
    }
}
