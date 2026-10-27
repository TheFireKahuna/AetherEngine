import XCTest
import AudioToolbox
import AVFoundation
import AetherLibavutil
@testable import AetherEngine

/// #401: `AudioDecoder` resamples to `av_channel_layout_default(channels)` and then stamps the
/// format description with a layout of its own. Those are two descriptions of one buffer, and
/// they have to agree channel for channel, or the renderer places the audio somewhere the
/// decoder never put it. They agreed only for 5.0 and 5.1; on 7.1 every channel moved and the
/// LFE landed hard left at full gain.
final class ChannelLayoutOrderTests: XCTestCase {

    /// `av_channel_name` fills a fixed 64-byte buffer, so the tail past the NUL is padding and
    /// has to go before the bytes become a String.
    private static func string(fromNullTerminated buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - What each library says, read from the library itself

    /// The order the resampler writes, read back from the production call that sets it.
    private func resamplerOrder(_ count: Int32) -> [String] {
        var layout = AVChannelLayout()
        makeResamplerOutputLayout(count, into: &layout)
        defer { av_channel_layout_uninit(&layout) }
        return (0..<count).map { index in
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            var name = [CChar](repeating: 0, count: 64)
            _ = av_channel_name(&name, 64, channel)
            return Self.string(fromNullTerminated: name)
        }
    }

    /// The CoreAudio label each channel the resampler writes has to carry, by meaning rather than
    /// by name. CoreAudio's 7.1 is L R C LFE Ls Rs Rls Rrs with Ls/Rs the SIDE pair and Rls/Rrs
    /// the REAR pair (its own WAVE_7_1, FFmpeg's order, expands to L R C LFE Rls Rrs Ls Rs, and
    /// an AVAudioConverter from MPEG_7_1_C to WAVE_7_1 moves channels 5-6 to 7-8). So FFmpeg's
    /// back pair is Rls/Rrs whenever a side pair sits beside it, and Ls/Rs when it is the only
    /// surround pair, as in 5.0/5.1/6.1(back). The old test folded Rls and Lsd into one "SL" and
    /// compared through a stereo downmix, which is blind to a front/back swap: it passed 7.1 with
    /// the back pair labelled as sides and the sides as rears.
    private func expectedLabels(_ count: Int32) -> [AudioChannelLabel] {
        if count == 1 { return [kAudioChannelLabel_Mono] }
        let names = resamplerOrder(count)
        let hasSides = names.contains("SL")
        return names.map { name in
            switch name {
            case "FL": return kAudioChannelLabel_Left
            case "FR": return kAudioChannelLabel_Right
            case "FC": return kAudioChannelLabel_Center
            case "LFE": return kAudioChannelLabel_LFEScreen
            case "BC": return kAudioChannelLabel_CenterSurround
            case "SL": return kAudioChannelLabel_LeftSurround
            case "SR": return kAudioChannelLabel_RightSurround
            case "BL": return hasSides ? kAudioChannelLabel_RearSurroundLeft : kAudioChannelLabel_LeftSurround
            case "BR": return hasSides ? kAudioChannelLabel_RearSurroundRight : kAudioChannelLabel_RightSurround
            default: return kAudioChannelLabel_Unknown
            }
        }
    }

    private func expandTag(_ tag: AudioChannelLayoutTag) -> [AudioChannelLabel] {
        var t = tag
        var size: UInt32 = 0
        let tagSize = UInt32(MemoryLayout<AudioChannelLayoutTag>.size)
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                         tagSize, &t, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                                     tagSize, &t, &size, raw) == noErr else { return [] }
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        let n = Int(layout.pointee.mNumberChannelDescriptions)
        guard n > 0 else { return [] }
        return withUnsafePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeBufferPointer(
                start: UnsafeRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self),
                count: n
            ).map(\.mChannelLabel)
        }
    }

    /// What the format description tells the renderer the buffer contains.
    private func stampedChannelLabels(_ count: Int32) -> [AudioChannelLabel] {
        expandTag(audioChannelLayoutTag(for: count))
    }

    /// FFmpeg's untouched default, which is what the resampler follows for every count but 7.
    private func ffmpegDefaultOrder(_ count: Int32) -> [String] {
        var layout = AVChannelLayout()
        av_channel_layout_default(&layout, count)
        defer { av_channel_layout_uninit(&layout) }
        return (0..<count).map { index in
            let channel = av_channel_layout_channel_from_index(&layout, UInt32(index))
            var name = [CChar](repeating: 0, count: 64)
            _ = av_channel_name(&name, 64, channel)
            return Self.string(fromNullTerminated: name)
        }
    }

    // MARK: - The canary

    /// If an FFmpegBuild bump ever changes what the resampler writes, this fails first and names
    /// the count, instead of the mismatch surfacing as misplaced audio nobody can trace.
    func testResamplerOrderIsWhatTheStampIsBuiltAgainst() {
        let expected: [Int32: [String]] = [
            1: ["FC"],
            2: ["FL", "FR"],
            3: ["FL", "FR", "LFE"],
            4: ["FL", "FR", "FC", "BC"],
            5: ["FL", "FR", "FC", "BL", "BR"],
            6: ["FL", "FR", "FC", "LFE", "BL", "BR"],
            7: ["FL", "FR", "FC", "LFE", "BC", "SL", "SR"],
            8: ["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"],
        ]
        for count in Int32(1)...8 {
            XCTAssertEqual(ffmpegDefaultOrder(count), expected[count],
                           "FFmpeg's \(count)ch default order changed")
        }
        // 6.1's default is the one order no CoreAudio tag describes, so the resampler is pointed
        // somewhere else on purpose. If that stops being true, the redirect is dead weight.
        XCTAssertNotEqual(resamplerOrder(7), ffmpegDefaultOrder(7))
        XCTAssertEqual(resamplerOrder(7), ["FL", "FR", "FC", "LFE", "BL", "BR", "BC"])
        for count in Int32(1)...8 where count != 7 {
            XCTAssertEqual(resamplerOrder(count), ffmpegDefaultOrder(count),
                           "\(count)ch should follow FFmpeg's default untouched")
        }
    }

    // MARK: - The contract

    func testStampedLayoutDescribesTheChannelsTheResamplerActuallyWrote() {
        for count in Int32(1)...8 {
            // A mono track is a mono track, not a centre channel: it keeps the Mono tag, whose
            // up-mix to stereo is full gain where a Centre description would cost 3 dB.
            XCTAssertEqual(stampedChannelLabels(count), expectedLabels(count),
                           "\(count)ch is stamped as something else")
        }
    }

    /// Anchors the mapping against CoreAudio's own layouts wherever a tag with the same order
    /// exists, so the test cannot pass by agreeing with itself.
    func testAgreesWithCoreAudiosOwnLayoutsWhereOneMatches() {
        let anchors: [Int32: AudioChannelLayoutTag] = [
            2: kAudioChannelLayoutTag_Stereo,
            3: kAudioChannelLayoutTag_DVD_4,
            4: kAudioChannelLayoutTag_MPEG_4_0_A,
            5: kAudioChannelLayoutTag_MPEG_5_0_A,
            6: kAudioChannelLayoutTag_MPEG_5_1_A,
            7: kAudioChannelLayoutTag_AudioUnit_6_1,
            // CoreAudio's tag for the WAVEFORMATEXTENSIBLE order, which is FFmpeg's 7.1 order.
            8: kAudioChannelLayoutTag_WAVE_7_1,
        ]
        for (count, tag) in anchors {
            XCTAssertEqual(stampedChannelLabels(count), expandTag(tag),
                           "\(count)ch does not match CoreAudio's own \(tag)")
        }
    }

    // MARK: - The same contract without any naming in it

    /// Names are an argument; placement is the thing that goes wrong. This renders one channel at
    /// a time through a real downmix and asserts the stamped tag puts it exactly where a layout
    /// built from the resampler's own order puts it. It is the measurement that found #401, kept.
    func testStampedTagPlacesEveryChannelWhereTheResamplerPutIt() throws {
        for count in Int32(2)...8 {
            let truth = Self.descriptionsLayout(expectedLabels(count))
            let stamped = try XCTUnwrap(AVAudioChannelLayout(layoutTag: audioChannelLayoutTag(for: count)))
            for channel in 0..<Int(count) {
                let expected = try Self.downmixToStereo(truth, signalAt: channel)
                let actual = try Self.downmixToStereo(stamped, signalAt: channel)
                XCTAssertEqual(actual.0, expected.0, accuracy: 0.01,
                               "\(count)ch: channel \(channel) moved in the left output")
                XCTAssertEqual(actual.1, expected.1, accuracy: 0.01,
                               "\(count)ch: channel \(channel) moved in the right output")
            }
        }
    }

    /// A stereo downmix cannot tell a side from a rear: both fold into the same front channel at
    /// the same gain. This routes one channel at a time from the stamped tag to a layout built
    /// from the expected labels through AVAudioConverter, which maps by label, so a channel that
    /// is labelled as the wrong surround pair lands on another output index.
    func testStampedTagRoutesEveryChannelToItsOwnPosition() throws {
        for count in Int32(2)...8 {
            let truth = Self.descriptionsLayout(expectedLabels(count))
            let stamped = try XCTUnwrap(AVAudioChannelLayout(layoutTag: audioChannelLayoutTag(for: count)))
            XCTAssertEqual(try Self.route(from: stamped, to: truth), Array(0..<Int(count)),
                           "\(count)ch: a channel lands on another position")
        }
    }

    /// For each input channel, the output index an impulse on it reaches at unity gain, -1 if none.
    private static func route(from source: AVAudioChannelLayout,
                              to destination: AVAudioChannelLayout) throws -> [Int] {
        let srcFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: source)
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: destination)
        let converter = try XCTUnwrap(AVAudioConverter(from: srcFormat, to: dstFormat))
        let frames: AVAudioFrameCount = 64
        return try (0..<Int(srcFormat.channelCount)).map { impulse in
            converter.reset()
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frames))
            input.frameLength = frames
            for channel in 0..<Int(srcFormat.channelCount) {
                for frame in 0..<Int(frames) {
                    input.floatChannelData![channel][frame] = channel == impulse ? 1.0 : 0.0
                }
            }
            let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: frames))
            try converter.convert(to: output, from: input)
            return (0..<Int(dstFormat.channelCount)).first {
                abs(output.floatChannelData![$0][Int(frames) / 2] - 1.0) < 0.01
            } ?? -1
        }
    }

    private static func descriptionsLayout(_ labels: [AudioChannelLabel]) -> AVAudioChannelLayout {
        let size = MemoryLayout<AudioChannelLayout>.size
            + (labels.count - 1) * MemoryLayout<AudioChannelDescription>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, size)
        let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
        layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
        layout.pointee.mNumberChannelDescriptions = UInt32(labels.count)
        let descs = withUnsafeMutablePointer(to: &layout.pointee.mChannelDescriptions) {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: AudioChannelDescription.self)
        }
        for (i, label) in labels.enumerated() { descs[i].mChannelLabel = label }
        return AVAudioChannelLayout(layout: layout)
    }

    /// One channel at full scale through AVAudioEngine's mixer, offline so it needs no device.
    private static func downmixToStereo(_ layout: AVAudioChannelLayout,
                                        signalAt: Int) throws -> (Float, Float) {
        let stereo = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let source = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: source)
        defer { engine.stop() }
        let frames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: frames)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames))
        input.frameLength = frames
        for channel in 0..<Int(source.channelCount) {
            for frame in 0..<Int(frames) {
                input.floatChannelData![channel][frame] = channel == signalAt ? 1.0 : 0.0
            }
        }
        try engine.start()
        player.scheduleBuffer(input, completionHandler: nil)
        player.play()
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                    frameCapacity: frames))
        _ = try engine.renderOffline(frames, to: output)
        var left: Float = 0, right: Float = 0
        if let data = output.floatChannelData {
            for i in 0..<Int(output.frameLength) {
                left = max(left, abs(data[0][i]))
                right = max(right, abs(data[1][i]))
            }
        }
        return (left, right)
    }
}
