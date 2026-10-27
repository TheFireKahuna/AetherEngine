import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil

/// Where a stream-copied audio packet sits, in samples: the one place its container timestamps
/// become the producer's.
///
/// A container rounds (Matroska to the millisecond, up to 24 samples at 48 kHz either way), so the
/// timestamps a packet arrives with are not where its frame is. Each copied packet is one coded
/// frame on its stream's lattice (`SourceGrid`), and its timestamp names that lattice point, so the
/// packet is placed there, by itself, the same in every run. Apple's decoder delay
/// (`AppleAudioDecoderDelay`) is added in whole samples on the way, which puts the packet on the
/// axis AVFoundation presents it on.
///
/// Everything the producer does with the packet after this (the gate, pre-roll, timeline jumps,
/// timestamp repair, routing, the muxer) works in `timeBase`; only what reads the source as
/// demuxed (the merge of two demuxers, the live replay guard, the recording) keeps `demuxTimeBase`.
struct CopiedAudioTiming {
    /// The time base the demuxer hands the packets over in.
    let demuxTimeBase: AVRational
    /// One sample: what a placed packet's timestamps and duration are in.
    let timeBase: AVRational
    /// The stream's first coded frame, in samples (`SourceGrid.origin`); nil where the container
    /// states no start, which leaves the lattice's phase unknown, so timestamps place themselves.
    private let origin: Int64?
    private let lattice: Int64
    private let tolerance: Int64
    /// AVFoundation's decoder delay for this codec, in samples; nil where it has not been measured
    /// (`AppleAudioDecoderDelay.samples`), and then nothing is added.
    let decoderDelay: Int?

    /// `codecpar` is what the muxer is given (an LATM stream's AAC, a Blu-ray LPCM stream's PCM), so
    /// the lattice and the rate are the muxed frames'; `stream` gives the demuxer's time base and start.
    init(stream: UnsafePointer<AVStream>, codecpar: UnsafePointer<AVCodecParameters>) {
        let par = codecpar.pointee
        let rate = max(par.sample_rate, 1)
        demuxTimeBase = stream.pointee.time_base
        timeBase = AVRational(num: 1, den: rate)
        let start = stream.pointee.start_time
        origin = start == Int64.min ? nil
            : SourceGrid.origin(start: start, timeBase: demuxTimeBase, sampleRate: rate,
                                initialPadding: par.initial_padding)
        lattice = SourceGrid.lattice(codecpar: codecpar, sampleRate: rate)
        tolerance = AudioContinuity.tolerance(sourceTimeBase: demuxTimeBase, sampleRate: rate)
        decoderDelay = AppleAudioDecoderDelay.samples(codecID: par.codec_id, profile: par.profile)
    }

    /// Moves `packet` from `demuxTimeBase` onto its frame, in `timeBase`. An unset timestamp stays
    /// unset for the producer's repair, which then works in samples too.
    func place(_ packet: UnsafeMutablePointer<AVPacket>) {
        let delay = Int64(decoderDelay ?? 0)
        if packet.pointee.pts != Int64.min { packet.pointee.pts = position(packet.pointee.pts) + delay }
        if packet.pointee.dts != Int64.min { packet.pointee.dts = position(packet.pointee.dts) + delay }
        if packet.pointee.duration > 0 {
            // A duration is a whole number of frames, rounded by the container like a timestamp.
            packet.pointee.duration = SourceGrid.position(
                estimate: av_rescale_q(packet.pointee.duration, demuxTimeBase, timeBase),
                origin: 0, lattice: lattice, tolerance: tolerance)
        }
    }

    private func position(_ ticks: Int64) -> Int64 {
        let estimate = av_rescale_q(ticks, demuxTimeBase, timeBase)
        guard let origin else { return estimate }
        return SourceGrid.position(estimate: estimate, origin: origin, lattice: lattice, tolerance: tolerance)
    }
}
