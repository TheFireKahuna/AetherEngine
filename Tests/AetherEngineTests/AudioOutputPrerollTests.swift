import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import AetherEngine

/// A compressed stream whose packets need the one before them (APAC reports one packet of pre-roll for every
/// packet) restarts its decoder cold when the renderer flushes itself on a route change (AE#549) and the feed
/// carries on mid-stream. The packet before goes in again first, trimmed for its whole duration.
@Suite("AudioOutput pre-roll after an automatic flush", .serialized)
struct AudioOutputPrerollTests {

    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers: [CMSampleBuffer] = []
        func add(_ b: CMSampleBuffer) { lock.withLock { buffers.append(b) } }
        var all: [CMSampleBuffer] { lock.withLock { buffers } }
    }

    /// One 1024-frame packet of a compressed format (the bytes are never decoded here), or LPCM.
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

    private static func trimAtStart(_ b: CMSampleBuffer) -> CMTime? {
        (CMGetAttachment(b, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) as? NSDictionary)
            .map { CMTimeMakeFromDictionary($0) }
    }

    private func flushAutomatically(_ output: AudioOutput, expecting count: Int) async throws {
        NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: output.renderer)
        try await waitFor { output.automaticFlushCount == count }
    }

    @Test("after an automatic flush the last compressed packet goes in again, decoded only to prime, then the next")
    func compressedStreamIsPrimed() async throws {
        let output = AudioOutput()
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        output.enqueue(sampleBuffer: try #require(buffer(pts: 0, compressed: true)))
        output.enqueue(sampleBuffer: try #require(buffer(pts: 1024, compressed: true)))
        try await flushAutomatically(output, expecting: 1)
        output.enqueue(sampleBuffer: try #require(buffer(pts: 2048, compressed: true)))
        output.enqueue(sampleBuffer: try #require(buffer(pts: 3072, compressed: true)))

        let all = seen.all
        let stamps: [Int64] = all.map { CMSampleBufferGetPresentationTimeStamp($0).convertScale(48_000, method: .roundTowardZero).value }
        let expected: [Int64] = [0, 1024, 1024, 2048, 3072]
        #expect(stamps == expected)
        #expect(Self.trimAtStart(all[2]) == CMSampleBufferGetDuration(all[2]))
        #expect(Self.trimAtStart(all[3]) == nil)
        #expect(Self.trimAtStart(all[1]) == nil, "the original keeps its own attachments")
    }

    @Test("LPCM needs no pre-roll and gets none")
    func pcmIsNotPrimed() async throws {
        let output = AudioOutput()
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        output.enqueue(sampleBuffer: try #require(buffer(pts: 0, compressed: false)))
        try await flushAutomatically(output, expecting: 1)
        output.enqueue(sampleBuffer: try #require(buffer(pts: 1024, compressed: false)))
        #expect(seen.all.count == 2)
    }

    @Test("a flush the engine makes itself (a seek) restarts the decoder, so it adds nothing")
    func explicitFlushIsNotPrimed() throws {
        let output = AudioOutput()
        let seen = Seen()
        output.rendererEnqueueObserverForTesting = { seen.add($0) }
        output.enqueue(sampleBuffer: try #require(buffer(pts: 0, compressed: true)))
        output.flush()
        output.enqueue(sampleBuffer: try #require(buffer(pts: 48_000, compressed: true)))
        #expect(seen.all.count == 2)
    }
}
