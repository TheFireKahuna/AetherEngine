import AVFoundation
import AetherLibavcodec
import AetherLibavformat
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
        let ffmpeg = try #require(Self.ffmpegClickSample(file), "FFmpeg decoded no click")
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

    /// The click's first sample in FFmpeg's decode of `file`'s audio, counted from the stream's first
    /// decoded sample: nothing trimmed that the stream does not state.
    static func ffmpegClickSample(_ file: URL) -> Int? {
        var fmt: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&fmt, file.path, nil, nil) == 0, let ctx = fmt else { return nil }
        defer { avformat_close_input(&fmt) }
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return nil }
        let index = av_find_best_stream(ctx, AVMEDIA_TYPE_AUDIO, -1, -1, nil, 0)
        guard index >= 0, let par = ctx.pointee.streams[Int(index)]?.pointee.codecpar,
              let codec = avcodec_find_decoder(par.pointee.codec_id), var dec = avcodec_alloc_context3(codec) else { return nil }
        defer { var d: UnsafeMutablePointer<AVCodecContext>? = dec; avcodec_free_context(&d) }
        guard avcodec_parameters_to_context(dec, par) >= 0, avcodec_open2(dec, codec, nil) >= 0 else { return nil }
        var mono: [Float] = []
        var packet = av_packet_alloc(), frame = av_frame_alloc()
        defer { av_packet_free(&packet); av_frame_free(&frame) }
        func drain() {
            while avcodec_receive_frame(dec, frame) >= 0 {
                let n = Int(frame!.pointee.nb_samples)
                guard frame!.pointee.format == AV_SAMPLE_FMT_FLTP.rawValue,
                      let plane = frame!.pointee.extended_data[0] else { continue }
                mono.append(contentsOf: UnsafeBufferPointer(start: UnsafeRawPointer(plane).assumingMemoryBound(to: Float.self), count: n))
            }
        }
        while av_read_frame(ctx, packet) >= 0 {
            if packet!.pointee.stream_index == index { avcodec_send_packet(dec, packet); drain() }
            av_packet_unref(packet)
        }
        avcodec_send_packet(dec, nil)
        drain()
        _ = dec
        let burst = (0..<144).map { 0.8 * sinf(2 * .pi * 1000 * Float($0) / 48_000) }
        guard mono.count > 60_000 else { return nil }
        var best = 40_000, bestValue: Float = -.infinity
        for lag in 40_000..<(min(mono.count, 60_000) - 144) {
            var acc: Float = 0
            for k in 0..<144 { acc += mono[lag + k] * burst[k] }
            if acc > bestValue { bestValue = acc; best = lag }
        }
        return best
    }
}
