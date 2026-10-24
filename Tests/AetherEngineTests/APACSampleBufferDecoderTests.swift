import Testing
import Foundation
import AVFoundation
import AetherLibavcodec
@testable import AetherEngine

/// The software host's TrueHD Atmos path (the Dolby Vision FEL route): the spatial bridge's APAC packets as
/// compressed sample buffers for `AVSampleBufferAudioRenderer`. What has to hold is what AVPlayer gets on the
/// HLS route: the same format, the bridge's timestamps one packet per buffer, and packets that decode.
@Suite("APAC sample buffers for the software host", .timeLimit(.minutes(2)))
struct APACSampleBufferDecoderTests {
    #if TrueHDObjectAudio

    /// `count` packets of 24 synthetic access units (20 ms) from `startMs`, through the decoder.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func decode(_ decoder: APACSampleBufferDecoder, startMs: Int64, count: Int) -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        for i in 0..<count {
            guard let pkt = av_packet_alloc() else { continue }
            defer { var p: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&p) }
            _ = av_new_packet(pkt, 24)
            pkt.pointee.data.update(repeating: 0, count: 24)
            pkt.pointee.pts = startMs + Int64(i) * 20
            pkt.pointee.dts = pkt.pointee.pts
            out += decoder.decode(packet: pkt)
        }
        return out
    }

    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func makeDecoder() throws -> APACSampleBufferDecoder {
        let bridge = try SpatialAudioBridge(
            srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
            decoder: SpatialAudioBridgeTests.SyntheticDecoder(skipAfterReset: 5))
        bridge.setSourceStart(0)
        return try APACSampleBufferDecoder(bridge: bridge)
    }

    @Test("the format is the HLS route's APAC sample entry as CoreMedia reads it")
    func formatDescription() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let decoder = try makeDecoder()
        defer { decoder.close() }
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(decoder.formatDescription)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatAPAC)
        #expect(asbd.mSampleRate == 48_000)
        var cookieSize = 0
        _ = CMAudioFormatDescriptionGetMagicCookie(decoder.formatDescription, sizeOut: &cookieSize)
        #expect(cookieSize > 0)
        #expect(!decoder.producesPCM)
    }

    private static func trimAtStart(_ buffer: CMSampleBuffer) -> Int64 {
        guard let d = CMGetAttachment(buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart, attachmentModeOut: nil) as? NSDictionary
        else { return 0 }
        return CMTimeMakeFromDictionary(d).convertScale(48_000, method: .roundTowardZero).value
    }

    @Test("priming is stated, not inferred: priming packets before the anchor and fully trimmed, content on its source position")
    func primingIsTrimmedAndContentIsOnTime() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let decoder = try makeDecoder()
        defer { decoder.close() }
        #expect(decoder.bridge.leadingFrames == 2048)
        let buffers = decode(decoder, startMs: 1000, count: 100)
        #expect(buffers.count > 40)
        // As `SpatialAudioBridgeTests.anchorsOnSource`: the first content frame belongs at 1000 ms plus five
        // skipped access units, 48 200. The two priming packets come before it and play nothing.
        let pts = buffers.map { CMSampleBufferGetPresentationTimeStamp($0).value }
        let firstThree: [Int64] = Array(pts.prefix(3))
        let expectedThree: [Int64] = [46_152, 47_176, 48_200]
        #expect(firstThree == expectedThree)
        let trims: [Int64] = buffers.prefix(3).map { Self.trimAtStart($0) }
        let expectedTrims: [Int64] = [1024, 1024, 0]
        #expect(trims == expectedTrims)
        #expect(buffers.dropFirst(2).allSatisfy { Self.trimAtStart($0) == 0 })
        // Output time (what the renderer plays from) of the first content buffer: its source position.
        #expect(CMSampleBufferGetOutputPresentationTimeStamp(buffers[2]) == CMTime(value: 48_200, timescale: 48_000))
        #expect(zip(pts, pts.dropFirst()).allSatisfy { $1 - $0 == 1024 })
        for buffer in buffers {
            #expect(CMSampleBufferGetNumSamples(buffer) == 1)
            var descriptions: UnsafePointer<AudioStreamPacketDescription>?
            var count = 0
            CMSampleBufferGetAudioStreamPacketDescriptionsPtr(buffer, packetDescriptionsPointerOut: &descriptions, sizeOut: &count)
            let total = CMSampleBufferGetTotalSampleSize(buffer)
            #expect(descriptions.map { Int($0.pointee.mDataByteSize) } == total)
            #expect(total > 0)
        }
    }

    @Test("the buffers decode, through the format they carry, to the bridge's audio")
    func buffersDecode() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let decoder = try makeDecoder()
        defer { decoder.close() }
        let buffers = decode(decoder, startMs: 0, count: 150)
        // Decoded the way the system does it: an AudioConverter from the format the buffers carry, its
        // cookie, and a 7.1.4 output.
        var inFormat = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(decoder.formatDescription)?.pointee)
        var outFormat = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 12, mBitsPerChannel: 32, mReserved: 0)
        var converterRef: AudioConverterRef?
        #expect(AudioConverterNew(&inFormat, &outFormat, &converterRef) == noErr)
        let converter = try #require(converterRef)
        defer { AudioConverterDispose(converter) }
        var cookieSize = 0
        let cookie = try #require(CMAudioFormatDescriptionGetMagicCookie(decoder.formatDescription, sizeOut: &cookieSize))
        #expect(AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32(cookieSize), cookie) == noErr)
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Atmos_7_1_4
        AudioConverterSetProperty(converter, kAudioConverterOutputChannelLayout, UInt32(MemoryLayout<AudioChannelLayout>.size), &layout)

        final class Feed {
            let buffers: [CMSampleBuffer]
            var next = 0
            var bytes: [UInt8] = []
            var description = AudioStreamPacketDescription()
            init(_ buffers: [CMSampleBuffer]) { self.buffers = buffers }
        }
        let feed = Feed(buffers)
        let proc: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, user in
            let feed = Unmanaged<Feed>.fromOpaque(user!).takeUnretainedValue()
            guard feed.next < feed.buffers.count else { packets.pointee = 0; return noErr }
            let buffer = feed.buffers[feed.next]
            feed.next += 1
            let size = CMSampleBufferGetTotalSampleSize(buffer)
            feed.bytes = [UInt8](repeating: 0, count: size)
            _ = feed.bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(CMSampleBufferGetDataBuffer(buffer)!, atOffset: 0, dataLength: size, destination: $0.baseAddress!)
            }
            feed.description = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
            data.pointee.mNumberBuffers = 1
            data.pointee.mBuffers.mData = feed.bytes.withUnsafeMutableBytes { $0.baseAddress }
            data.pointee.mBuffers.mDataByteSize = UInt32(size)
            data.pointee.mBuffers.mNumberChannels = 0
            packets.pointee = 1
            if let descriptions { descriptions.pointee = withUnsafeMutablePointer(to: &feed.description) { $0 } }
            return noErr
        }
        let list = AudioBufferList.allocate(maximumBuffers: 12)
        defer { list.unsafeMutablePointer.deallocate() }
        let planes = (0..<12).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: 1024) }
        defer { planes.forEach { $0.deallocate() } }
        var energy = 0.0
        while true {
            for c in 0..<12 { list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 4096, mData: planes[c]) }
            var frames: UInt32 = 1024
            let status = AudioConverterFillComplexBuffer(converter, proc, Unmanaged.passUnretained(feed).toOpaque(), &frames, list.unsafeMutablePointer, nil)
            if status != noErr || frames == 0 { break }
            for c in 0..<12 { for i in 0..<Int(frames) { energy += Double(planes[c][i] * planes[c][i]) } }
        }
        let next = feed.next
        #expect(next == buffers.count)
        #expect(energy > 1)
    }

    @Test("priming that is not a whole number of packets is trimmed to the frame")
    func partialPrimingTrim() {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        var t: [(presentation: Int64, trimAtStart: Int64)] = []
        for k in Int64(0)..<4 {
            t.append(APACSampleBufferDecoder.timing(bridgeStamp: 10_000 + k * 1024, indexInRun: k, leadingFrames: 1500))
        }
        let presentations: [Int64] = t.map { $0.presentation }
        let trims: [Int64] = t.map { $0.trimAtStart }
        #expect(presentations == [8_500, 9_524, 10_548, 11_572])
        #expect(trims == [1024, 476, 0, 0])
        // Content frame 0 (decoded frame 1500) plays at the anchor: packet 1 starts at 9524, trims 476.
        #expect(t[1].presentation + t[1].trimAtStart == 10_000)
    }

    @Test("a flush starts the bridge over: the next buffer anchors on the next packet")
    func flushReanchors() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let decoder = try makeDecoder()
        defer { decoder.close() }
        _ = decode(decoder, startMs: 0, count: 60)
        decoder.flush()
        let after = decode(decoder, startMs: 30_000, count: 60)
        // 30 s = 1 440 000 frames, plus the five access units skipped after the reset; the new run primes again.
        let firstPTS: Int64? = after.first.map { CMSampleBufferGetPresentationTimeStamp($0).value }
        #expect(firstPTS == 1_438_152)
        let firstTrim: Int64? = after.first.map { Self.trimAtStart($0) }
        #expect(firstTrim == 1024)
        let content: CMSampleBuffer? = after.first { Self.trimAtStart($0) == 0 }
        let contentOutput: Int64? = content.map { CMSampleBufferGetOutputPresentationTimeStamp($0).value }
        #expect(contentOutput == 1_440_200)
    }
    #endif
}
