import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// AE#464 follow-up: an audio delay change takes effect a quarter of a second past the clock, not after the
/// seconds of audio already queued. The renderer's partial flush replaces what is scheduled from there on.
@Suite("AudioOutput applies an offset change at once", .serialized)
struct AudioOutputOffsetChangeTests {

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CMSampleBuffer] = []
        func add(_ b: CMSampleBuffer) { lock.withLock { buffers.append(b) } }
        var all: [CMSampleBuffer] { lock.withLock { buffers } }
    }

    private static let frames: Int64 = 1024

    /// One 1024-frame packet at `index` packets in, compressed (never decoded here) or LPCM.
    private func buffer(index: Int64, compressed: Bool = false) throws -> CMSampleBuffer {
        var asbd = compressed
            ? AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0, mBytesPerPacket: 0,
                                          mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
            : AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                          mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
                                          mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let bytes = compressed ? 64 : 4096
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        let pts = CMTime(value: index * Self.frames, timescale: 48_000)
        var out: CMSampleBuffer?
        if compressed {
            var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes))
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format), sampleCount: 1,
                presentationTimeStamp: pts, packetDescriptions: &description, sampleBufferOut: &out)
        } else {
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts,
                                            decodeTimeStamp: .invalid)
            CMSampleBufferCreate(allocator: nil, dataBuffer: try #require(block), dataReady: true, makeDataReadyCallback: nil,
                                 refcon: nil, formatDescription: try #require(format), sampleCount: Int(Self.frames),
                                 sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                 sampleSizeArray: nil, sampleBufferOut: &out)
        }
        return try #require(out)
    }

    private static func ms(_ b: CMSampleBuffer) -> Int {
        Int((CMSampleBufferGetPresentationTimeStamp(b).seconds * 1000).rounded())
    }

    private static func ms(index: Int64) -> Int { Int((Double(index * frames) / 48.0).rounded()) }

    // MARK: - The tail, pure

    @Test("a later offset moves the whole tail and drops nothing")
    func laterShiftsAll() throws {
        let tail = try (20..<25).map { try buffer(index: $0) }
        let from = CMSampleBufferGetPresentationTimeStamp(tail[0])
        let shifted = AudioOutput.shiftedTail(tail, by: CMTime(value: 100, timescale: 1000), notBefore: from)
        #expect(shifted.map(Self.ms) == (20..<25).map { Self.ms(index: $0) + 100 })
    }

    @Test("an earlier offset drops what would land on audio still queued, and a compressed stream gets a primer")
    func earlierDropsTheOverlap() throws {
        let tail = try (20..<30).map { try buffer(index: $0, compressed: true) }
        let from = CMSampleBufferGetPresentationTimeStamp(tail[0])
        // 100 ms is 4.7 packets of 21.3 ms: the first five shifted packets would start before `from`.
        let shifted = AudioOutput.shiftedTail(tail, by: CMTime(value: -100, timescale: 1000), notBefore: from)
        #expect(shifted.count == 6, "five dropped, a primer for the first kept")
        #expect(AudioOutput.isTrimmedWhole(shifted[0]))
        #expect(Self.ms(shifted[0]) == Self.ms(index: 24) - 100, "the primer is the last dropped packet")
        #expect(shifted.dropFirst().map(Self.ms) == (25..<30).map { Self.ms(index: $0) - 100 })
        #expect(shifted.dropFirst().allSatisfy { !AudioOutput.isTrimmedWhole($0) })
    }

    @Test("LPCM needs no primer when its head is dropped")
    func pcmGetsNoPrimer() throws {
        let tail = try (20..<30).map { try buffer(index: $0) }
        let from = CMSampleBufferGetPresentationTimeStamp(tail[0])
        let shifted = AudioOutput.shiftedTail(tail, by: CMTime(value: -100, timescale: 1000), notBefore: from)
        #expect(shifted.count == 5)
        #expect(shifted.allSatisfy { !AudioOutput.isTrimmedWhole($0) })
    }

    // MARK: - On a renderer

    /// The renderer's own answer to the partial flush, however long it takes. Production waits
    /// `AudioRendererIO.partialFlushTimeout` and a loaded machine answers after it, which is the `.unanswered`
    /// branch, tested on its own below; what is tested here is that the renderer takes a flush a quarter of a
    /// second out, and what the output does with that.
    private static func rendererAnswers(_ io: AudioRendererIO, _ time: CMTime) -> AudioRendererIO.PartialFlush {
        io.flush(fromSourceTime: time, timeout: .seconds(60))
    }

    @Test("a change flushes from a quarter-second past the clock and enqueues that tail again, shifted",
          arguments: audioOutputPaths)
    func appliesAtOnce(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = Self.rendererAnswers
        for i in Int64(0)..<60 { output.enqueue(sampleBuffer: try buffer(index: i)) }
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        // The clock stands at zero: everything from the first packet at or past 250 ms goes back in, 100 ms later.
        output.setPresentationOffset(seconds: 0.1)
        let first = Int64((0.25 * 48_000 / Double(Self.frames)).rounded(.up))
        #expect(seen.all.map(Self.ms) == (first..<60).map { Self.ms(index: $0) + 100 })

        // The feed carries on with the new offset, right after the shifted tail.
        output.enqueue(sampleBuffer: try buffer(index: 60))
        #expect(seen.all.last.map(Self.ms) == Self.ms(index: 60) + 100)
    }

    @Test("what an offset change put back is what a later reconfiguration puts back", arguments: audioOutputPaths)
    func theQueueRecordFollows(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = Self.rendererAnswers
        for i in Int64(0)..<30 { output.enqueue(sampleBuffer: try buffer(index: i)) }
        output.setPresentationOffset(seconds: 0.1)
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        output.reenqueueAfterOutputConfigurationChange()
        let first = Int64((0.25 * 48_000 / Double(Self.frames)).rounded(.up))
        let expected = (0..<first).map { Self.ms(index: $0) } + (first..<30).map { Self.ms(index: $0) + 100 }
        #expect(seen.all.map(Self.ms) == expected)
    }

    @Test("an unanswered partial flush flushes whole and enqueues everything from the clock again, shifted",
          arguments: audioOutputPaths)
    func unansweredFlushesWhole(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = { _, _ in .unanswered }
        for i in Int64(0)..<60 { output.enqueue(sampleBuffer: try buffer(index: i)) }
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        // The flush may yet land, so nothing queued is trusted: from the clock (zero) on, all of it, 100 ms later.
        #expect(output.setPresentationOffset(seconds: 0.1))
        #expect(seen.all.map(Self.ms) == (0..<60).map { Self.ms(index: $0) + 100 })
    }

    @Test("a refused partial flush leaves the queue alone and the change waits for the next buffer",
          arguments: audioOutputPaths)
    func refusedWaits(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = { _, _ in .refused }
        for i in Int64(0)..<60 { output.enqueue(sampleBuffer: try buffer(index: i)) }
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        #expect(!output.setPresentationOffset(seconds: 0.1))
        #expect(seen.all.isEmpty)
        output.enqueue(sampleBuffer: try buffer(index: 60))
        #expect(seen.all.map(Self.ms) == [Self.ms(index: 60) + 100])
    }

    @Test("nothing queued past the lead: the change waits for the next buffer", arguments: audioOutputPaths)
    func nothingPastTheLead(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        for i in Int64(0)..<5 { output.enqueue(sampleBuffer: try buffer(index: i)) }
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        output.setPresentationOffset(seconds: 0.1)
        #expect(seen.all.isEmpty)
        output.enqueue(sampleBuffer: try buffer(index: 5))
        #expect(seen.all.map(Self.ms) == [Self.ms(index: 5) + 100])
    }
}
