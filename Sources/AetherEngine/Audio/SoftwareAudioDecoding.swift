import CoreMedia
import AetherLibavcodec

/// What `SoftwarePlaybackHost` decodes its audio track with: compressed `AVPacket`s in, sample buffers for
/// its `AVSampleBufferAudioRenderer` out. `AudioDecoder` (FFmpeg to LPCM) for every codec;
/// `APACSampleBufferDecoder` for TrueHD Atmos with object rendering on, whose buffers are APAC.
protocol SoftwareAudioDecoding: AnyObject, Sendable {
    /// The buffers this packet completes, possibly none.
    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer]
    /// Drop all state: a seek, a timeline seam or the end of the stream.
    func flush()
    func close()
    /// Whether the buffers are LPCM, which the host's PCM consumers (the audio tap) can read.
    var producesPCM: Bool { get }
    /// Audio packets the host reads without any output before it stops waiting for one to start its clock
    /// and starts it off a video packet instead.
    var packetsBeforeClockFallback: Int { get }
}

extension AudioDecoder: SoftwareAudioDecoding {
    var producesPCM: Bool { true }
    var packetsBeforeClockFallback: Int { 50 }
}
