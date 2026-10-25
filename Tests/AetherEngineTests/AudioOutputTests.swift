import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// One 1024-frame packet at `pts` (48 kHz): LPCM, or one packet of the compressed `format`, whose bytes are never
/// decoded, so an unknown format is a buffer no renderer can play.
func audioPacket(pts: Int64, format id: AudioFormatID = kAudioFormatLinearPCM) throws -> CMSampleBuffer {
    let pcm = id == kAudioFormatLinearPCM
    var asbd = pcm
        ? AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: id, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                      mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
                                      mBitsPerChannel: 32, mReserved: 0)
        : AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: id, mFormatFlags: 0, mBytesPerPacket: 0,
                                      mFramesPerPacket: 1024, mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    let bytes = pcm ? 4096 : 64
    var block: CMBlockBuffer?
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    let time = CMTime(value: pts, timescale: 48_000)
    var out: CMSampleBuffer?
    if pcm {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        CMSampleBufferCreate(allocator: nil, dataBuffer: try #require(block), dataReady: true, makeDataReadyCallback: nil,
                             refcon: nil, formatDescription: try #require(format), sampleCount: 1024, sampleTimingEntryCount: 1,
                             sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &out)
    } else {
        var description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(bytes))
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: try #require(block), formatDescription: try #require(format), sampleCount: 1,
            presentationTimeStamp: time, packetDescriptions: &description, sampleBufferOut: &out)
    }
    return try #require(out)
}

/// What an `AudioOutput` hands its renderer, in order.
final class RendererEnqueues: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []

    init(_ output: AudioOutput) { output.rendererEnqueueObserverForTesting = { [self] b in lock.withLock { buffers.append(b) } } }

    var all: [CMSampleBuffer] { lock.withLock { buffers } }
    var pts: [Int64] { all.map { CMSampleBufferGetPresentationTimeStamp($0).convertScale(48_000, method: .roundTowardZero).value } }
}

@Suite("AudioOutput", .serialized)
struct AudioOutputTests {

    private static let aac = kAudioFormatMPEG4AAC

    private static func packets(_ pts: [Int64], format: AudioFormatID = kAudioFormatLinearPCM) throws -> [CMSampleBuffer] {
        try pts.map { try audioPacket(pts: $0, format: format) }
    }

    private static func pts(_ buffers: [CMSampleBuffer]) -> [Int64] {
        buffers.map { CMSampleBufferGetPresentationTimeStamp($0).convertScale(48_000, method: .roundTowardZero).value }
    }

    // MARK: - Pre-roll after an automatic flush

    // A compressed stream whose packets need the one before them (APAC reports one packet of pre-roll for every
    // packet) restarts its decoder cold when the renderer flushes itself on a route change (AE#549) and the feed
    // carries on mid-stream. The packet before goes in again first, trimmed for its whole duration.

    @Test("after an automatic flush the last compressed packet goes in again, decoded only to prime, then the next",
          arguments: audioOutputPaths)
    func compressedStreamIsPrimed(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = RendererEnqueues(output)
        for b in try Self.packets([0, 1024], format: Self.aac) { output.enqueue(sampleBuffer: b) }
        try await deliverAutomaticFlush(to: output, expecting: 1, then: try audioPacket(pts: 2048, format: Self.aac))
        output.enqueue(sampleBuffer: try audioPacket(pts: 3072, format: Self.aac))

        let all = seen.all
        #expect(seen.pts == [0, 1024, 1024, 2048, 3072])
        #expect(AudioOutput.isTrimmedWhole(all[2]))
        #expect(!AudioOutput.isTrimmedWhole(all[3]))
        #expect(!AudioOutput.isTrimmedWhole(all[1]), "the original keeps its own attachments")
    }

    @Test("LPCM needs no pre-roll and gets none", arguments: audioOutputPaths)
    func pcmIsNotPrimed(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = RendererEnqueues(output)
        output.enqueue(sampleBuffer: try audioPacket(pts: 0))
        try await deliverAutomaticFlush(to: output, expecting: 1, then: try audioPacket(pts: 1024))
        #expect(seen.all.count == 2)
    }

    @Test("a flush the engine makes itself (a seek) restarts the decoder, so it adds nothing", arguments: audioOutputPaths)
    func explicitFlushIsNotPrimed(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = RendererEnqueues(output)
        output.enqueue(sampleBuffer: try audioPacket(pts: 0, format: Self.aac))
        output.flush()
        output.enqueue(sampleBuffer: try audioPacket(pts: 48_000, format: Self.aac))
        #expect(seen.all.count == 2)
    }

    // MARK: - Output reconfiguration

    // The output was configured for another format under the renderer (`…OutputConfigurationDidChange`). The header's
    // remedy is a flush and the buffers again from the playhead, which configures the output for their format; the
    // renderer's own queue is what goes back in, so the gap is its restart rather than the feed's lead.

    private static let inThird = CMTime(value: 2048 + 10, timescale: 48_000)
    private static let four: [Int64] = [0, 1024, 2048, 3072]

    @Test("PCM goes back in from the buffer the clock is in, with no primer")
    func pcmRefeedsFromThePlayhead() throws {
        #expect(Self.pts(AudioOutput.refeed(try Self.packets(Self.four), at: Self.inThird)) == [2048, 3072])
    }

    @Test("a clock past everything queued puts nothing back")
    func nothingAfterTheEnd() throws {
        let queued = try Self.packets(Self.four, format: Self.aac)
        #expect(AudioOutput.refeed(queued, at: CMTime(value: 5000, timescale: 48_000)).isEmpty)
    }

    @Test("the queue keeps the buffer the clock is in, the one before it, and what follows, within its limit")
    func pruning() throws {
        let queued = try Self.packets(Self.four, format: Self.aac)
        #expect(Self.pts(AudioOutput.pruned(queued, at: Self.inThird, limit: 100)) == [1024, 2048, 3072])
        #expect(Self.pts(AudioOutput.pruned(queued, at: .zero, limit: 100)) == Self.four)
        #expect(Self.pts(AudioOutput.pruned(queued, at: .zero, limit: 2)) == [2048, 3072])
    }

    @Test("the notification flushes and enqueues the renderer's queue again from the clock, a compressed stream primed",
          arguments: audioOutputPaths)
    func notificationRefeeds(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let seen = RendererEnqueues(output)
        for b in try Self.packets(Self.four, format: Self.aac) { output.enqueue(sampleBuffer: b) }
        output.synchronizer.setRate(0, time: Self.inThird)
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: output.renderer)
        try await waitFor { output.outputReconfigurationCount == 1 }

        let all = seen.all
        #expect(seen.pts == [0, 1024, 2048, 3072, 1024, 2048, 3072])
        #expect(AudioOutput.isTrimmedWhole(all[4]))
        #expect(!AudioOutput.isTrimmedWhole(all[5]))
    }

    @Test("a reconfiguration both the stream and the next enqueue report is refed once", arguments: audioOutputPaths)
    func reportedTwiceRefeedsOnce(throughReceivers: Bool) async throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        let buffers = try Self.packets(Self.four)
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
        let seen = RendererEnqueues(output)
        for b in try Self.packets(Self.four) { output.enqueue(sampleBuffer: b) }
        output.flush()
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: output.renderer)
        try await waitFor { output.outputReconfigurationCount == 1 }
        #expect(seen.all.count == 4)
    }

    // MARK: - Offset change

    // AE#464 follow-up: an audio delay change takes effect a quarter of a second past the clock, not after the
    // seconds of audio already queued. The renderer's partial flush replaces what is scheduled from there on.

    private static func ms(_ b: CMSampleBuffer) -> Int { Int((CMSampleBufferGetPresentationTimeStamp(b).seconds * 1000).rounded()) }
    private static func ms(index: Int64) -> Int { Int((Double(index * 1024) / 48.0).rounded()) }
    private static func indexed(_ range: Range<Int64>, format: AudioFormatID = kAudioFormatLinearPCM) throws -> [CMSampleBuffer] {
        try Self.packets(range.map { $0 * 1024 }, format: format)
    }
    /// The first packet at or past the quarter second the partial flush starts from, the clock standing at zero.
    private static let firstFlushed = Int64((0.25 * 48_000 / 1024).rounded(.up))

    @Test("an earlier offset drops what would land on audio still queued, and a compressed stream gets a primer")
    func earlierDropsTheOverlap() throws {
        let tail = try Self.indexed(20..<30, format: Self.aac)
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
        let tail = try Self.indexed(20..<30)
        let shifted = AudioOutput.shiftedTail(tail, by: CMTime(value: -100, timescale: 1000),
                                              notBefore: CMSampleBufferGetPresentationTimeStamp(tail[0]))
        #expect(shifted.count == 5)
        #expect(shifted.allSatisfy { !AudioOutput.isTrimmedWhole($0) })
    }

    /// The renderer's own answer to the partial flush, however long it takes. Production waits
    /// `AudioRendererIO.partialFlushTimeout`, and a loaded machine answers after it.
    private static func rendererAnswers(_ io: AudioRendererIO, _ time: CMTime) -> AudioRendererIO.PartialFlush {
        io.flush(fromSourceTime: time, timeout: .seconds(60))
    }

    @Test("a change flushes from a quarter-second past the clock and enqueues that tail again, shifted",
          arguments: audioOutputPaths)
    func appliesAtOnce(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = Self.rendererAnswers
        for b in try Self.indexed(0..<60) { output.enqueue(sampleBuffer: b) }
        let seen = RendererEnqueues(output)
        output.setPresentationOffset(seconds: 0.1)
        #expect(seen.all.map(Self.ms) == (Self.firstFlushed..<60).map { Self.ms(index: $0) + 100 })

        // The feed carries on with the new offset, right after the shifted tail.
        output.enqueue(sampleBuffer: try audioPacket(pts: 60 * 1024))
        #expect(seen.all.last.map(Self.ms) == Self.ms(index: 60) + 100)
    }

    @Test("what an offset change put back is what a later reconfiguration puts back", arguments: audioOutputPaths)
    func theQueueRecordFollows(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        output.partialFlushForTesting = Self.rendererAnswers
        for b in try Self.indexed(0..<30) { output.enqueue(sampleBuffer: b) }
        output.setPresentationOffset(seconds: 0.1)
        let seen = RendererEnqueues(output)
        output.reenqueueAfterOutputConfigurationChange()
        let expected = (0..<Self.firstFlushed).map { Self.ms(index: $0) } + (Self.firstFlushed..<30).map { Self.ms(index: $0) + 100 }
        #expect(seen.all.map(Self.ms) == expected)
    }

    @Test("nothing queued past the lead: the change waits for the next buffer", arguments: audioOutputPaths)
    func nothingPastTheLead(throughReceivers: Bool) throws {
        let output = AudioOutput(throughReceivers: throughReceivers)
        for b in try Self.indexed(0..<5) { output.enqueue(sampleBuffer: b) }
        let seen = RendererEnqueues(output)
        output.setPresentationOffset(seconds: 0.1)
        #expect(seen.all.isEmpty)
        output.enqueue(sampleBuffer: try audioPacket(pts: 5 * 1024))
        #expect(seen.all.map(Self.ms) == [Self.ms(index: 5) + 100])
    }
}
