import AVFoundation
import AetherLibavcodec
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// `AppleAudioDecoderDelay` holds the delay AVFoundation trims from an audio track that states none.
/// These tests take it from Apple's own packaging: `AVAssetWriter` (`mpeg4AppleHLS`) writes a click
/// at exactly 1 s; FFmpeg, which trims nothing it is not told to, finds the click that many samples
/// late, and AVFoundation finds it on time. A system that changes either side fails here, instead of
/// moving every copied track's sound. (AC-3 and E-AC-3 are pinned end to end by `AVSyncTests`.)
@Suite("Apple's implicit audio decoder delay")
struct AppleAudioDecoderDelayTests {

    @Test("codecs without priming move nothing; unmeasured ones are not guessed")
    func table() {
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_FLAC, profile: -99) == 0)
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_PCM_S24LE, profile: -99) == 0)
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_AC3, profile: -99) == 256)
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_EAC3, profile: -99) == 256)
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_AAC, profile: 0) == nil, "AAC Main: not measured")
        #expect(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_DTS, profile: -99) == nil)
    }

    struct Profile: CustomTestStringConvertible, Sendable {
        let name: String, formatID: AudioFormatID, bitRate: Int, ffmpegProfile: Int32
        var testDescription: String { name }
    }

    @Test("Apple's HLS writer puts AAC that far ahead of its sound, and AVFoundation takes exactly that out",
          .timeLimit(.minutes(1)),
          arguments: [Profile(name: "AAC-LC", formatID: kAudioFormatMPEG4AAC, bitRate: 192_000, ffmpegProfile: 1),
                      Profile(name: "HE-AAC", formatID: kAudioFormatMPEG4AAC_HE, bitRate: 64_000, ffmpegProfile: 4),
                      Profile(name: "HE-AAC v2", formatID: kAudioFormatMPEG4AAC_HE_V2, bitRate: 48_000, ffmpegProfile: 28)])
    func appleAAC(_ profile: Profile) throws {
        let file = try Self.appleHLS(formatID: profile.formatID, bitRate: profile.bitRate)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = try #require(AppleAudioDecoderDelay.samples(codecID: AV_CODEC_ID_AAC, profile: profile.ffmpegProfile))
        let ffmpeg = try #require(try Self.ffmpegClickSample(file), "FFmpeg decoded no click")
        #expect(ffmpeg - 48_000 == expected, "FFmpeg hears Apple's \(profile.name) \(ffmpeg - 48_000) samples late")
        let avf = try #require(AVSyncTests.measure(file).1, "AVFoundation decoded no click")
        #expect(abs(avf - 1) * 48_000 <= 1, "AVFoundation plays it \((avf - 1) * 48_000) samples off")
    }

    // MARK: - Helpers

    /// A click at sample 48000 of 3 s of stereo, through `AVAssetWriter`'s HLS profile: init plus
    /// segments, joined into one file.
    static func appleHLS(formatID: AudioFormatID, bitRate: Int) throws -> URL {
        final class Collector: NSObject, AVAssetWriterDelegate {
            var data = Data()
            func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                             segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
                data.append(segmentData)
            }
        }
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: 2, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        let collector = Collector()
        writer.delegate = collector
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: formatID, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: bitRate])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let chunk = 1024
        for start in stride(from: 0, to: 48_000 * 3, by: chunk) {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var samples = [Float](repeating: 0, count: chunk * 2)
            for i in 0..<chunk where (48_000..<48_144).contains(start + i) {
                let v = 0.8 * sinf(2 * .pi * 1000 * Float(start + i - 48_000) / 48_000)
                samples[2 * i] = v
                samples[2 * i + 1] = v
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 8, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: chunk * 8, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: chunk * 8) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: 48_000), packetDescriptions: nil, sampleBufferOut: &buffer)
            input.append(buffer!)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("apple-aac-\(UUID().uuidString).mp4")
        try collector.data.write(to: url)
        return url
    }

    /// The click's first sample in the engine's decode of `file`'s audio (FFmpeg's decoders, which trim nothing the
    /// stream does not state), counted from the first decoded sample.
    static func ffmpegClickSample(_ file: URL) throws -> Int? {
        let demuxer = Demuxer()
        try demuxer.open(url: file)
        defer { demuxer.close() }
        let decoder = AudioDecoder()
        try decoder.open(stream: try #require(demuxer.stream(at: demuxer.audioStreamIndex)))
        defer { decoder.close() }
        var buffers: [CMSampleBuffer] = []
        while let pkt = try demuxer.readPacket() {
            if pkt.pointee.stream_index == demuxer.audioStreamIndex { buffers += decoder.decode(packet: pkt) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        buffers += decoder.drain()
        return AVSyncTests.clickLag(buffers).map { Int($0.rounded()) }
    }
}
