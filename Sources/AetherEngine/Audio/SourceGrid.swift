import AetherLibavcodec
import AetherLibavutil

/// Where decoded audio sits on the source timeline, exactly, for audio coded in fixed-length
/// frames (a TrueHD access unit, a DTS frame, an AAC frame).
///
/// Continuous playback puts frame `n` of a stream at `origin + n * step`: the stream's first coded
/// frame, then every frame one step later. That first coded frame is the stream's start less the
/// codec's delay (`origin(...)`): a codec with priming puts its first packets before the start.
/// A run that starts anywhere else (a seek, a decoder reset) knows its own frames exactly relative
/// to each other, by the decoder's clock or its count
/// of what it was given, but only knows where they sit on the stream from container timestamps,
/// and a container rounds them: Matroska to the millisecond, up to 24 frames at 48 kHz either way.
/// Rounded, each timestamp still names a range of grid points one step apart, and every timestamp
/// of the run has to name the same one, so the run is placed on the one grid point all its
/// timestamps allow. Where the step is longer than twice the rounding (a DTS frame, 512) one
/// timestamp decides it; TrueHD's 40-frame access unit can need a second. A timestamp that allows
/// none of the run's points is not rounding: the stream was cut there, and a new run starts. One that
/// allows no point of the lattice at all says the frames after a cut no longer sit on it (an edit at
/// another phase): that run is placed on every frame instead, until a restart lays the lattice again.
///
/// So a run's audio sits where continuous playback puts it, to the frame, whatever the container
/// rounded and wherever the run began.
struct SourceGrid {
    /// Where the stream's first coded frame sits, in frames.
    let origin: Int64
    /// Frames every coded frame of the stream starts on a multiple of (`lattice(codecpar:sampleRate:)`).
    let lattice: Int64
    /// The lattice the run is placed on: the stream's, or every frame once a cut moved the frames off it.
    private var step: Int64
    /// How far a container timestamp may be from the frame it marks: `AudioContinuity.tolerance`.
    let tolerance: Int64
    /// How far it may be from that frame's lattice point: its own rounding and the rounding of the
    /// start the lattice is laid from (`origin`), which the container rounded the same way. Read
    /// against a timestamp's rounding alone, `DTSX Emulator.mkv` (start 53 ms, timestamps up to a
    /// tick either side of their frames) left the lattice about 700 times a minute and was placed
    /// anew each time. On a run placed on every frame the origin cancels out.
    private var latticeTolerance: Int64 { Self.latticeTolerance(step: step, tolerance: tolerance) }

    private static func latticeTolerance(step: Int64, tolerance: Int64) -> Int64 {
        step > 1 ? 2 * tolerance - 1 : tolerance
    }

    /// The run's relative position of its first frame, and the grid offsets (in steps, from the
    /// point `origin` puts that frame on) still consistent with every timestamp the run has seen.
    private var first: Int64?
    private var steps: ClosedRange<Int64>?
    /// The point the run is placed on. It stays while every timestamp allows it and moves only when
    /// one rules it out, to the nearest point still allowed: a run placed right is never moved, so its
    /// buffers abut, and one placed wrong moves once, by the least the timestamps demand.
    private var chosen: Int64?

    init(origin: Int64, step: Int64, tolerance: Int64) {
        self.origin = origin
        self.lattice = max(step, 1)
        self.step = lattice
        self.tolerance = tolerance
    }

    /// Whether the grid places frames yet: a timestamp has been seen since the run started.
    var isPlacing: Bool { steps != nil }

    /// Whether the run is placed exactly: one grid point is left.
    var isResolved: Bool { steps.map { $0.lowerBound == $0.upperBound } ?? false }

    /// The run's frames are no longer relative to the same frame (a decoder reset).
    mutating func restart() {
        first = nil
        steps = nil
        chosen = nil
        step = lattice
    }

    enum Placement: Equatable {
        /// The frame's exact position, or the nearest one the run's timestamps allow so far.
        case position(Int64)
        /// No timestamp yet: nothing says where the run sits.
        case unplaced
    }

    /// Where the frame `relative` (on the run's own axis) sits, with the source timestamp of that
    /// frame (`estimate`, output frames) if the container gave one. Returns whether the timestamp
    /// started a new run because the old one allowed it nowhere.
    mutating func place(relative: Int64, estimate: Int64?) -> (Placement, restarted: Bool) {
        var restarted = false
        if let estimate {
            let first = self.first ?? relative
            // The run's first frame sits at origin + k * step; this frame whole steps after it, as a
            // decoder's frames are, constrains k by its own timestamp.
            let offset = relative - first
            if offset % step == 0 {
                // origin + (k + offset / step) * step must lie within tolerance of the estimate.
                let tolerance = latticeTolerance
                let low = Self.ceilDiv(estimate - tolerance - origin, step) - offset / step
                let high = Self.floorDiv(estimate + tolerance - origin, step) - offset / step
                if low > high {
                    // No point of the lattice within the timestamp's rounding: the frames left it.
                    restarted = true
                    step = 1
                    self.first = relative
                    self.steps = (estimate - self.tolerance - origin)...(estimate + self.tolerance - origin)
                } else if let steps = self.steps {
                    let lo = max(steps.lowerBound, low), hi = min(steps.upperBound, high)
                    if lo <= hi {
                        self.steps = lo...hi
                    } else {
                        restarted = true
                        self.first = relative
                        self.steps = Self.ceilDiv(estimate - tolerance - origin, step)...Self.floorDiv(estimate + tolerance - origin, step)
                    }
                } else {
                    self.first = first
                    self.steps = low...high
                }
            }
        }
        guard let first = self.first, let steps else { return (.unplaced, restarted) }
        // A new run starts in the middle of what its first timestamp allows.
        let k = restarted ? nil : chosen
        let placed = k.map { min(max($0, steps.lowerBound), steps.upperBound) }
            ?? steps.lowerBound + (steps.upperBound - steps.lowerBound) / 2
        chosen = placed
        return (.position(origin + placed * step + (relative - first)), restarted)
    }

    /// Where a coded frame whose own container timestamp is `estimate` starts, for a stream whose
    /// every frame carries one (a stream-copied packet): the lattice point that timestamp names. A
    /// lattice longer than the span a rounded timestamp can name (`latticeTolerance` either side)
    /// leaves one point in it, so the timestamp alone decides, and every packet is placed by itself,
    /// the same way whichever packet a run began at. Where the lattice is no longer than that span
    /// (none of the codecs stream-copied: they are 256 frames or more, the Matroska span 194 at
    /// 48 kHz) or is every frame, the timestamp names no single point and is the position; so is one
    /// with no point in its span, a frame cut off the lattice (`place`'s rule for the same).
    static func position(estimate: Int64, origin: Int64, lattice: Int64, tolerance: Int64) -> Int64 {
        let window = latticeTolerance(step: lattice, tolerance: tolerance)
        guard lattice > 2 * window else { return estimate }
        let point = origin + floorDiv(estimate - origin + lattice / 2, lattice) * lattice
        return abs(point - estimate) <= window ? point : estimate
    }

    /// The first coded frame, in frames at `sampleRate`: the stream's start (`AVStream.start_time`)
    /// less the codec's delay (`initial_padding`), which a decoder then trims off the front of its first
    /// frame. Measured on every fixture: Matroska and MP4 put the first packet exactly there (AAC
    /// 1024 frames early, AC-3 256, MP3 1105, Opus 312).
    static func origin(start: Int64, timeBase: AVRational, sampleRate: Int32, initialPadding: Int32) -> Int64 {
        av_rescale_q(start, timeBase, AVRational(num: 1, den: sampleRate)) - Int64(initialPadding)
    }

    /// Frames every coded frame of the stream starts on a multiple of: the codec's frame length where
    /// it is fixed (an E-AC-3 frame is 1 to 6 blocks of 256, an Opus one a multiple of 2.5 ms, a
    /// FLAC stream's block size when its STREAMINFO says min = max), and 1, every frame, where frames
    /// can start on any sample (PCM, Vorbis, a variable-block FLAC stream) or the length is not stated.
    /// `sampleRate` is the decoded stream's, which a container can leave unstated until the first
    /// frame (TrueHD).
    static func lattice(codecpar: UnsafePointer<AVCodecParameters>, sampleRate: Int32) -> Int64 {
        let par = codecpar.pointee
        switch par.codec_id {
        case AV_CODEC_ID_AAC: return 1024
        case AV_CODEC_ID_AC3: return 1536
        case AV_CODEC_ID_EAC3: return 256
        case AV_CODEC_ID_OPUS: return max(Int64(sampleRate) / 400, 1)
        case AV_CODEC_ID_TRUEHD, AV_CODEC_ID_MLP:
            let base: Int32 = sampleRate % 44_100 == 0 ? 44_100 : 48_000
            return max(40 * Int64(sampleRate / base), 1)
        case AV_CODEC_ID_MP3, AV_CODEC_ID_MP2, AV_CODEC_ID_DTS:
            return max(Int64(par.frame_size), 1)
        case AV_CODEC_ID_FLAC:
            // STREAMINFO: min and max block size, 16 bits each, first.
            guard par.extradata_size >= 4, let e = par.extradata else { return 1 }
            let minimum = Int64(e[0]) << 8 | Int64(e[1]), maximum = Int64(e[2]) << 8 | Int64(e[3])
            return minimum == maximum && minimum > 0 ? minimum : 1
        default: return 1
        }
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }
}
