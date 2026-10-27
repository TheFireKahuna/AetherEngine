import Foundation
import AudioToolbox
import AetherLibavcodec
import AetherLibavutil

/// Apple Positional Audio packets to planar float frames, for the audio tap's resampler. The loopback carries APAC
/// where the spatial bridge renders TrueHD Atmos or DTS:X, and libavcodec has no APAC decoder (its `apac` is an
/// unrelated codec), so AudioToolbox decodes it, from the `dapa` cookie the init segment carries
/// (`APACSampleEntry.magicCookie(inInit:)`).
///
/// The cookie states the channel count and the bed's layout; the frames come out in libavutil's native order for
/// that layout, so the tap's downmix treats a bed as it treats any multichannel source. Each packet decodes to its
/// 1024 frames with nothing held back, so a frame's time is its packet's.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class APACTapPacketDecoder {

    private let converter: AudioConverterRef
    private let channelCount: Int
    /// For each decoded channel, its plane in the native-order frame.
    private let planeForChannel: [Int]
    private var layout = AVChannelLayout()
    private let sampleRate: Int32

    /// Nil when the cookie does not describe an APAC bed this engine renders.
    init?(magicCookie: Data) {
        var input = AudioStreamBasicDescription()
        input.mFormatID = kAudioFormatAPAC
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let described = magicCookie.withUnsafeBytes {
            AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, UInt32($0.count), $0.baseAddress, &size, &input)
        }
        guard described == noErr, input.mChannelsPerFrame > 0, input.mSampleRate > 0 else { return nil }
        let channels = Int(input.mChannelsPerFrame)
        var output = AudioStreamBasicDescription(
            mSampleRate: input.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32, mReserved: 0)
        var made: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &made) == noErr, let converter = made else { return nil }
        let cookieSet = magicCookie.withUnsafeBytes {
            AudioConverterSetProperty(converter, kAudioConverterDecompressionMagicCookie, UInt32($0.count), $0.baseAddress!)
        }
        guard cookieSet == noErr, let tag = Self.inputLayoutTag(converter),
              let bed = SpatialSpeakerLayout.rendered.first(where: { $0.channelLayoutTag == tag }),
              bed.channelCount == channels else {
            AudioConverterDispose(converter)
            return nil
        }
        let ids = bed.speakers.map(\.avChannel)
        var native = AVChannelLayout()
        guard av_channel_layout_from_mask(&native, ids.reduce(UInt64(0)) { $0 | (1 << UInt64($1.rawValue)) }) == 0,
              Int(native.nb_channels) == channels else {
            AudioConverterDispose(converter)
            return nil
        }
        self.converter = converter
        channelCount = channels
        planeForChannel = ids.map { Int(av_channel_layout_index_from_channel(&native, $0)) }
        layout = native
        sampleRate = Int32(input.mSampleRate)
    }

    deinit {
        AudioConverterDispose(converter)
        av_channel_layout_uninit(&layout)
    }

    /// One packet's frames, stamped with the packet's pts; nil when it does not decode. The caller frees the frame.
    func decode(_ packet: UnsafePointer<AVPacket>) -> UnsafeMutablePointer<AVFrame>? {
        guard packet.pointee.size > 0, let data = packet.pointee.data,
              let frame = av_frame_alloc() else { return nil }
        var owned: UnsafeMutablePointer<AVFrame>? = frame
        frame.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        frame.pointee.sample_rate = sampleRate
        frame.pointee.nb_samples = Int32(APACEncoder.framesPerPacket)
        frame.pointee.pts = packet.pointee.pts
        guard av_channel_layout_copy(&frame.pointee.ch_layout, &layout) == 0,
              av_frame_get_buffer(frame, 0) == 0 else {
            av_frame_free(&owned)
            return nil
        }
        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { list.unsafeMutablePointer.deallocate() }
        let capacity = UInt32(APACEncoder.framesPerPacket * MemoryLayout<Float>.size)
        for c in 0..<channelCount {
            list[c] = AudioBuffer(mNumberChannels: 1, mDataByteSize: capacity,
                                  mData: UnsafeMutableRawPointer(frame.pointee.extended_data[planeForChannel[c]]))
        }
        let input = Input(bytes: UnsafeRawPointer(data), size: Int(packet.pointee.size))
        var frames = UInt32(APACEncoder.framesPerPacket)
        let status = withExtendedLifetime(input) {
            AudioConverterFillComplexBuffer(converter, Self.supply, Unmanaged.passUnretained(input).toOpaque(),
                                            &frames, list.unsafeMutablePointer, nil)
        }
        guard status == noErr || status == Self.inputConsumed, frames > 0 else {
            av_frame_free(&owned)
            return nil
        }
        frame.pointee.nb_samples = Int32(frames)
        return frame
    }

    /// What `supply` reports once the one packet it holds is taken, so the converter returns what it decoded.
    private static let inputConsumed: OSStatus = 1

    private final class Input {
        let bytes: UnsafeRawPointer
        let size: Int
        var taken = false
        /// Handed to the converter by address, so it lives as long as the input.
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        init(bytes: UnsafeRawPointer, size: Int) {
            self.bytes = bytes
            self.size = size
            description.initialize(to: AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                    mDataByteSize: UInt32(size)))
        }
        deinit { description.deallocate() }
    }

    private static let supply: AudioConverterComplexInputDataProc = { _, packets, data, descriptions, user in
        let input = Unmanaged<Input>.fromOpaque(user!).takeUnretainedValue()
        guard !input.taken else {
            packets.pointee = 0
            return inputConsumed
        }
        input.taken = true
        data.pointee.mNumberBuffers = 1
        data.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: input.bytes)
        data.pointee.mBuffers.mDataByteSize = UInt32(input.size)
        data.pointee.mBuffers.mNumberChannels = 0
        packets.pointee = 1
        descriptions?.pointee = input.description
        return noErr
    }

    private static func inputLayoutTag(_ converter: AudioConverterRef) -> AudioChannelLayoutTag? {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterInputChannelLayout, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioConverterGetProperty(converter, kAudioConverterInputChannelLayout, &size, raw) == noErr else { return nil }
        return raw.assumingMemoryBound(to: AudioChannelLayout.self).pointee.mChannelLayoutTag
    }
}

private extension SpatialSpeakerLayout {
    /// Every layout the spatial bridge renders into, so every bed an APAC track of this engine's can carry.
    static var rendered: [SpatialSpeakerLayout] { allCases + [.l20, .l51, .l71] }
}

private extension SpatialSpeaker {
    /// The speaker as libavutil names it, for a native-order layout.
    var avChannel: AVChannel {
        switch self {
        case .left: AV_CHAN_FRONT_LEFT
        case .right: AV_CHAN_FRONT_RIGHT
        case .center: AV_CHAN_FRONT_CENTER
        case .lfe: AV_CHAN_LOW_FREQUENCY
        case .surroundLeft, .sideLeft: AV_CHAN_SIDE_LEFT
        case .surroundRight, .sideRight: AV_CHAN_SIDE_RIGHT
        case .rearLeft: AV_CHAN_BACK_LEFT
        case .rearRight: AV_CHAN_BACK_RIGHT
        case .wideLeft: AV_CHAN_WIDE_LEFT
        case .wideRight: AV_CHAN_WIDE_RIGHT
        case .topFrontLeft: AV_CHAN_TOP_FRONT_LEFT
        case .topFrontRight: AV_CHAN_TOP_FRONT_RIGHT
        case .topMiddleLeft: AV_CHAN_TOP_SIDE_LEFT
        case .topMiddleRight: AV_CHAN_TOP_SIDE_RIGHT
        case .topRearLeft: AV_CHAN_TOP_BACK_LEFT
        case .topRearRight: AV_CHAN_TOP_BACK_RIGHT
        }
    }
}
