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
///
/// A container timestamp is not always good to its tick: a remux can carry timestamps that drift from
/// their frames and snap back, measured up to 112 frames (2.3 ms) off at 48 kHz on a millisecond base
/// with the audio continuous underneath. `noise` bounds that at three ticks. A lattice longer than twice
/// the noise (a DTS, AAC, AC-3 or MP3 frame on Matroska; any lattice on a sample-exact container) is a
/// long one, and there a timestamp only picks the frame: it rounds to the nearest lattice point, and a
/// run moves only when a timestamp names a different frame (a cut) or sits beyond the noise for
/// `phaseShiftTimestamps` timestamps in a row without doing so (the frames moved off the lattice by
/// less than a frame). Noise within the bound never moves a run; a shift within it is absorbed. A
/// shorter lattice (a TrueHD access unit, an E-AC-3 block, an Opus frame) keeps the narrowing above.
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

    /// How far a container timestamp may sit from its frame and still be read as that frame's: three
    /// ticks (`tolerance` is one tick and a sample).
    static func noise(tolerance: Int64) -> Int64 { 3 * tolerance }

    /// Whether a lattice is longer than twice the noise, so a timestamp's nearest point is its frame.
    static func isLong(lattice: Int64, tolerance: Int64) -> Bool { lattice > 2 * noise(tolerance: tolerance) }

    /// Consecutive timestamps beyond the noise from a long-lattice run's point, all naming its frames, that
    /// say the frames moved off the lattice by less than a frame.
    static let phaseShiftTimestamps = 8

    /// A long lattice's run: how far its frames sit off the stream's lattice (zero until an edit moves
    /// them), and the timestamps in a row beyond the noise from it.
    private var phase: Int64 = 0
    private var offPhase: [Int64] = []

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
        phase = 0
        offPhase.removeAll()
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
        if Self.isLong(lattice: lattice, tolerance: tolerance) {
            return placeOnLongLattice(relative: relative, estimate: estimate)
        }
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

    /// `place` on a long lattice: the run's first frame is lattice point `chosen` (counted from `origin`
    /// plus the run's `phase`), every timestamp rounds to the frame it names, and only a timestamp naming
    /// another frame, or a stretch of them beyond the noise, moves the run.
    private mutating func placeOnLongLattice(relative: Int64, estimate: Int64?) -> (Placement, restarted: Bool) {
        var restarted = false
        if let estimate {
            let offset = relative - (first ?? relative)
            if offset % lattice == 0 {
                let noise = Self.noise(tolerance: tolerance)
                // The lattice point this timestamp names for the run's first frame, and how far off it it sits.
                let named = Self.floorDiv(estimate - origin - phase + lattice / 2, lattice) - offset / lattice
                let residual = estimate - (origin + phase + (named + offset / lattice) * lattice)
                if chosen == nil || named != chosen {
                    // The run's first timestamp, or a cut: the run starts here, on the lattice unless this
                    // timestamp sits beyond the noise from it, which only an edit at another phase puts it.
                    restarted = chosen != nil || abs(residual) > noise
                    if abs(residual) > noise { phase += residual }
                    first = relative
                    chosen = Self.floorDiv(estimate - origin - phase + lattice / 2, lattice)
                    offPhase.removeAll()
                } else if abs(residual) > noise {
                    offPhase.append(residual)
                    if offPhase.count >= Self.phaseShiftTimestamps {
                        // Every timestamp of the stretch names the run's frames from beyond the noise: the
                        // frames moved off the lattice, by their mean.
                        restarted = true
                        phase += offPhase.reduce(0, +) / Int64(offPhase.count)
                        first = relative
                        chosen = Self.floorDiv(estimate - origin - phase + lattice / 2, lattice)
                        offPhase.removeAll()
                    }
                } else {
                    offPhase.removeAll()
                }
                steps = chosen.map { $0...$0 }
            }
        }
        guard let first, let chosen else { return (.unplaced, restarted) }
        return (.position(origin + phase + chosen * lattice + (relative - first)), restarted)
    }

    /// Where a coded frame whose own container timestamp is `estimate` starts, for a stream whose
    /// every frame carries one (a stream-copied packet): the lattice point that timestamp names. A
    /// lattice longer than the span a timestamp can name leaves one point in it, so the timestamp alone
    /// decides, and every packet is placed by itself, the same way whichever packet a run began at. The
    /// span is the noise either side on a long lattice, a rounded timestamp's (`latticeTolerance`) on a
    /// shorter one. Where the lattice is no longer than that span or is every frame, the timestamp names
    /// no single point and is the position; so is one with no point in its span, a frame cut off the
    /// lattice (`place`'s rule for the same).
    static func position(estimate: Int64, origin: Int64, lattice: Int64, tolerance: Int64) -> Int64 {
        let window = isLong(lattice: lattice, tolerance: tolerance)
            ? noise(tolerance: tolerance) : latticeTolerance(step: lattice, tolerance: tolerance)
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
    /// frame (TrueHD). `decodedFrameSamples` is the length of the stream's first decoded frame, for a codec
    /// whose frame length the container need not state: Matroska leaves a DTS stream's `frame_size` unset,
    /// and a DTS frame's length is in its own header (32 × (NBLKS+1) samples, the same on every normal frame).
    static func lattice(codecpar: UnsafePointer<AVCodecParameters>, sampleRate: Int32,
                        decodedFrameSamples: Int64? = nil) -> Int64 {
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
            return par.frame_size > 0 ? Int64(par.frame_size) : max(decodedFrameSamples ?? 1, 1)
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
