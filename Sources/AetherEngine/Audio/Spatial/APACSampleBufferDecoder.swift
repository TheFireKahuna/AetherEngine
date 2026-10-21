// Only with the TrueHDObjectAudio trait (off by default).
#if TrueHDObjectAudio
import CoreMedia
import Foundation
import AetherLibavcodec

/// TrueHD Atmos in, APAC sample buffers out, for the software host's `AVSampleBufferAudioRenderer`: the
/// object rendering of the HLS route (`SpatialAudioBridge`) without the HLS muxing. It is what gives the
/// Dolby Vision FEL route, which plays on the software host, its Atmos.
///
/// Measured on an Apple TV 4K (tvOS 27.2) into a Samsung HW-Q990B: the renderer decodes and renders APAC,
/// objects and heights included, but sends the HDMI sink multichannel PCM on its own; with the
/// `AtmosOutputActivator`'s silent Atmos player beside it the sink shows Dolby Atmos and the objects
/// still move. So the engine runs the activator for a software session that plays this.
///
/// The format description is the one AVPlayer builds from the HLS route's `apac` sample entry
/// (`SpatialAudioBridge.soundSampleEntryOverride`).
///
/// Timing follows CoreMedia's documented contract rather than any player's inference: a buffer's audio plays
/// from its presentation timestamp, and decoded audio to discard is marked with
/// `kCMSampleBufferAttachmentKey_TrimDurationAtStart` ("the samples are only being decoded to prime the
/// decoder": the whole duration). So every encoder run's priming packets are stamped `leadingFrames` before
/// the run's anchor and trimmed, and its content packets sit exactly on their source position. That is the
/// shape Apple's own APAC takes: written by AVAssetWriter and read back unchanged, the first buffer carries
/// TrimDurationAtStart = 2048 frames and its output time is content time 0. The HLS route keeps the priming
/// unstated on purpose: that is how Apple's own HLS writer writes APAC (AVAssetWriter with mpeg4AppleHLS: no
/// edit list, the first fragment's decode time 0 on the priming packets), the form AVPlayer's HLS path is
/// built for. A sample buffer renderer has no such convention to lean on, so here it is stated.
@available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
final class APACSampleBufferDecoder: SoftwareAudioDecoding, @unchecked Sendable {

    enum DecoderError: Error, CustomStringConvertible {
        case noSampleEntry
        case formatDescription(OSStatus)

        var description: String {
            switch self {
            case .noSampleEntry: return "APACSampleBufferDecoder: the bridge has no sample entry"
            case .formatDescription(let s): return "APACSampleBufferDecoder: format description from the sample entry failed (\(s))"
            }
        }
    }

    let bridge: SpatialAudioBridge
    let formatDescription: CMAudioFormatDescription
    /// Output time base: 48 kHz frames.
    private let timescale = CMTimeScale(SpatialAudioBridge.sampleRate)

    init(bridge: SpatialAudioBridge) throws {
        guard let entry = bridge.soundSampleEntryOverride else { throw DecoderError.noSampleEntry }
        self.bridge = bridge
        formatDescription = try Self.formatDescription(sampleEntry: entry)
    }

    /// The `apac` sample entry as CoreMedia reads it out of an MP4 (ISO family sound description).
    static func formatDescription(sampleEntry: Data) throws -> CMAudioFormatDescription {
        var desc: CMAudioFormatDescription?
        let status = sampleEntry.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreateFromBigEndianSoundDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianSoundDescriptionData: raw.bindMemory(to: UInt8.self).baseAddress!,
                size: raw.count,
                flavor: .isoFamily,
                formatDescriptionOut: &desc)
        }
        guard status == noErr, let desc else { throw DecoderError.formatDescription(status) }
        return desc
    }

    var producesPCM: Bool { false }

    /// The bridge returns nothing until the decoder has met a major sync (up to about 100 access units after
    /// a start mid-stream) and the encoder has finished its first chunks, a few thousand frames later.
    /// Starting the clock off video in the meantime would start it before the audio it then waits for.
    var packetsBeforeClockFallback: Int { SpatialAudioBridge.silentFeedPacketThreshold }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        // The bridge logs and counts its own failures; a packet it refused is a gap in the audio.
        bridge.feedStamped(packet: packet).compactMap(sampleBuffer)
    }

    /// Where packet `indexInRun` of an encoder run plays, and how much of its decoded audio is priming, given
    /// the bridge's stamp (the run's anchor plus k·1024, priming included).
    static func timing(bridgeStamp: Int64, indexInRun: Int64, leadingFrames: Int)
        -> (presentation: Int64, trimAtStart: Int64) {
        let frames = Int64(APACEncoder.framesPerPacket)
        let trim = min(max(Int64(leadingFrames) - indexInRun * frames, 0), frames)
        return (bridgeStamp - Int64(leadingFrames), trim)
    }

    func flush() { bridge.startSegment() }

    func close() { bridge.close() }

    /// One APAC packet as one compressed sample buffer, on its 48 kHz presentation time, its priming trimmed.
    private func sampleBuffer(_ packet: APACEncodePipeline.StampedPacket) -> CMSampleBuffer? {
        let size = packet.data.count
        guard size > 0 else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              packet.data.withUnsafeBytes({ raw in
                  CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
              }) == kCMBlockBufferNoErr
        else { return nil }
        let timing = Self.timing(bridgeStamp: packet.pts, indexInRun: packet.indexInRun, leadingFrames: bridge.leadingFrames)
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, presentationTimeStamp: CMTime(value: timing.presentation, timescale: timescale),
            packetDescriptions: &description, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { return nil }
        if timing.trimAtStart > 0 {
            CMSetAttachment(
                buffer, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart,
                value: CMTimeCopyAsDictionary(CMTime(value: timing.trimAtStart, timescale: timescale), allocator: kCFAllocatorDefault),
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return buffer
    }
}
#endif
