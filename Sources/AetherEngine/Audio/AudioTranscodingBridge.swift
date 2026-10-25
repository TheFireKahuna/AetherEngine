import Foundation
import AetherLibavcodec
import AetherLibavutil

/// What the segment producer and the engine need from an audio bridge: source packets in,
/// fMP4-legal packets out, plus the restart/EOF/diagnostic surface the producer lifecycle drives.
///
/// Two implementations. `AudioBridge` is libavcodec end to end (decode, resample, E-AC-3 or FLAC).
/// `SpatialAudioBridge` renders TrueHD Atmos objects into a speaker bed and encodes it as APAC,
/// which libavcodec cannot encode or mux, so it also supplies the sample entry the muxer writes.
protocol AudioTranscodingBridge: AnyObject, Sendable {
    /// Parameters of the stream the muxer's audio track is built from. For a bridge that sets
    /// `soundSampleEntryOverride`, these describe a stand-in movenc can write, not the real codec.
    var encoderCodecpar: UnsafeMutablePointer<AVCodecParameters>? { get }
    var encoderTimeBase: AVRational { get }

    /// A complete sample entry box that replaces the one movenc writes for the audio track, or nil
    /// to keep movenc's.
    var soundSampleEntryOverride: Data? { get }

    /// Channels the delivered track really carries, for the master's `CHANNELS`, when the muxer's
    /// codec parameters describe a stand-in instead (the APAC bed behind a 2-channel ALAC stand-in).
    /// Nil reads the count off `encoderCodecpar`.
    var servedChannelCount: Int? { get }

    /// AE#783: the most bits per second the delivered track can carry, which the master's
    /// `BANDWIDTH` has to cover.
    var peakOutputBitRate: Int64 { get }

    /// Decode, transcode and return 0+ packets in `encoderTimeBase`. The caller owns them and frees
    /// them with `trackedPacketFree` after muxing.
    func feed(packet: UnsafePointer<AVPacket>) throws -> [UnsafeMutablePointer<AVPacket>]
    /// Packets for audio already fed that the bridge is still encoding, waited for. The producer
    /// calls it before cutting a segment, so a cut splits the audio where a synchronous encode would.
    func settle() -> [UnsafeMutablePointer<AVPacket>]
    /// Drain at source EOF. The bridge is unusable afterwards until `startSegment`.
    func flush() -> [UnsafeMutablePointer<AVPacket>]
    /// A producer restart boundary: drop buffered audio and rebase timestamps off the next packet.
    func startSegment()
    /// AE#464's audio delay, built into the output's timestamps. The bridge encodes, so audio a
    /// negative delay puts before the timeline's start comes off at the exact sample, where a muxer
    /// could only drop whole packets. Taken on the next anchor (the first since construction or
    /// `startSegment`), so the producer sets it before it feeds.
    func setOutputOffset(seconds: Double)
    /// The stream's start (`AVStream.start_time`) on the time base and axis the packets fed to this
    /// bridge are on (the producer's shift applied), from which the grid its frames sit on is laid
    /// (`SourceGrid`). The producer sets it before it feeds a run.
    func setSourceStart(_ pts: Int64?)
    /// Live splice gap correction, in seconds.
    func noteTimelineJump(deltaSeconds: Double)
    /// The producer's segments, for a bridge that makes each segment's audio in a run of its own
    /// (`AudioSegmentRuns`); every other bridge ignores it. Set when the audio gate opens, before the
    /// first feed.
    func setRunPlan(_ plan: AudioRunPlan)
    /// What a producer feeds: this bridge, or one of its own made from it (`AudioSegmentRuns`),
    /// which the producer ends when its pump does (`producerFinished`).
    func producerBridge() -> any AudioTranscodingBridge
    func producerFinished()
    /// How far before a segment's start the bridge reads the source to make it: a restart seeks that
    /// much earlier, and the producer feeds from there. Zero for a bridge that makes the session in
    /// one run.
    var preRollSeconds: Double { get }

    /// A segment's run (`AudioSegmentRuns`): the run's anchor puts the encoder's first input frame at
    /// `frame` on the output timeline, encoder ticks with the output offset in (an encoder's padding
    /// goes in front of it). Audio decoded before it settles the stages ahead of the encoder and
    /// comes off, as does audio the offset puts before it; a stream that begins after it is preceded
    /// by silence. `segment` is the run's own part of the output timeline, which it reports on
    /// (`SessionLevelMeter`). Set before the run's first feed.
    func startRun(atFrame frame: Int64, segment: Range<Int64>)
    /// What a run's output at a position takes from its input, decoder to encoder; nil where a
    /// stage's memory is not known.
    var runSpan: AudioStageSpan? { get }
    /// The encoder's part of `runSpan`'s memory: a run starts that far before its segment's first
    /// packet at least.
    var runEncoderMemory: Int { get }
    /// Frames per output packet: the grid every run starts on.
    var runPacketFrames: Int { get }
    /// How far before its timestamp AVFoundation presents an output packet's audio, encoder ticks:
    /// the encoder's padding, which AVFoundation trims on decode (`AppleAudioDecoderDelay`; APAC's
    /// priming, which it counts as part of the stream). The first sound a segment plays is its first
    /// packet's timestamp less this.
    var presentationDelay: Int64 { get }
    func close()

    var feedStats: AudioBridge.FeedStats { get }
    var liveBytes: AudioBridge.LiveBytes { get }
    var fifoSampleCount: Int { get }
    var outputBytesLifetime: Int64 { get }

    /// What the object renderer is doing, for `LiveTelemetry.objectAudio`; nil for a bridge without
    /// one. Read off the pump thread, like `outputBytesLifetime`.
    var objectAudioActivity: ObjectAudioActivity? { get }
}

extension AudioBridge: AudioTranscodingBridge {
    var soundSampleEntryOverride: Data? { nil }
    var servedChannelCount: Int? { nil }
    var runSpan: AudioStageSpan? { span }
    var runEncoderMemory: Int { encoderSpan.memory }
    var runPacketFrames: Int { Int(packetFrames) }
    var presentationDelay: Int64 { Int64(encoderCodecpar?.pointee.initial_padding ?? 0) }
    var peakOutputBitRate: Int64 {
        guard let cp = encoderCodecpar else { return 0 }
        return Self.peakBitRate(bitRate: cp.pointee.bit_rate,
                                channels: cp.pointee.ch_layout.nb_channels,
                                sampleRate: cp.pointee.sample_rate,
                                bitsPerRawSample: cp.pointee.bits_per_raw_sample)
    }

    /// A constant-rate encoder (E-AC-3) states its rate. FLAC is variable and never exceeds the PCM
    /// it encodes by more than its frame headers, so its ceiling is the PCM rate.
    static func peakBitRate(bitRate: Int64, channels: Int32, sampleRate: Int32, bitsPerRawSample: Int32) -> Int64 {
        if bitRate > 0 { return bitRate }
        let bits = bitsPerRawSample > 0 ? Int64(bitsPerRawSample) : 32
        return Int64(max(0, channels)) * Int64(max(0, sampleRate)) * bits
    }
    func settle() -> [UnsafeMutablePointer<AVPacket>] { [] }
}

extension AudioTranscodingBridge {
    var objectAudioActivity: ObjectAudioActivity? { nil }
    func setRunPlan(_ plan: AudioRunPlan) {}
    func producerBridge() -> any AudioTranscodingBridge { self }
    func producerFinished() {}
    var preRollSeconds: Double { 0 }
}
