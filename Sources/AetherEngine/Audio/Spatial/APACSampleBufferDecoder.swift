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
/// (`SpatialAudioBridge.soundSampleEntryOverride`), and the packets keep the bridge's timestamps, which
/// already account for AVFoundation presenting an APAC packet's audio `leadingFrames` before its stamp.
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
        let encoded: [UnsafeMutablePointer<AVPacket>]
        do {
            encoded = try bridge.feed(packet: packet)
        } catch {
            // The bridge logs and counts its own failures; a packet it refused is a gap in the audio.
            return []
        }
        var buffers: [CMSampleBuffer] = []
        buffers.reserveCapacity(encoded.count)
        for pkt in encoded {
            if let buffer = sampleBuffer(pkt) { buffers.append(buffer) }
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            trackedPacketFree(&p)
        }
        return buffers
    }

    func flush() { bridge.startSegment() }

    func close() { bridge.close() }

    /// One APAC packet as one compressed sample buffer, on the bridge's 48 kHz timestamp.
    private func sampleBuffer(_ pkt: UnsafeMutablePointer<AVPacket>) -> CMSampleBuffer? {
        let size = Int(pkt.pointee.size)
        guard size > 0, let data = pkt.pointee.data else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: size)
                == kCMBlockBufferNoErr
        else { return nil }
        var description = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(size))
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: formatDescription,
            sampleCount: 1, presentationTimeStamp: CMTime(value: pkt.pointee.pts, timescale: timescale),
            packetDescriptions: &description, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { return nil }
        return buffer
    }
}
#endif
