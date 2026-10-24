/// Where decoded audio sits on the source timeline, exactly, for audio coded in fixed-length
/// frames (a TrueHD access unit, a DTS frame).
///
/// Continuous playback puts frame `n` of a stream at `origin + n * step`: the stream's first
/// timestamp, then every frame one step later. A run that starts anywhere else (a seek, a decoder
/// reset) knows its own frames exactly relative to each other, by the decoder's clock or its count
/// of what it was given, but only knows where they sit on the stream from container timestamps,
/// and a container rounds them: Matroska to the millisecond, up to 24 frames at 48 kHz either way.
/// Rounded, each timestamp still names a range of grid points one step apart, and every timestamp
/// of the run has to name the same one, so the run is placed on the one grid point all its
/// timestamps allow. Where the step is longer than twice the rounding (a DTS frame, 512) one
/// timestamp decides it; TrueHD's 40-frame access unit can need a second. A timestamp that allows
/// none of the run's points is not rounding: the stream was cut there, and a new run starts.
///
/// So a run's audio sits where continuous playback puts it, to the frame, whatever the container
/// rounded and wherever the run began.
struct SourceGrid {
    /// Where the stream's first frame sits, in output frames.
    let origin: Int64
    /// Frames per coded frame.
    let step: Int64
    /// How far a container timestamp may be from the frame it marks: `AudioContinuity.tolerance`.
    let tolerance: Int64

    /// The run's relative position of its first frame, and the grid offsets (in steps, from the
    /// point `origin` puts that frame on) still consistent with every timestamp the run has seen.
    private var first: Int64?
    private var steps: ClosedRange<Int64>?

    init(origin: Int64, step: Int64, tolerance: Int64) {
        self.origin = origin
        self.step = max(step, 1)
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
                let low = Self.ceilDiv(estimate - tolerance - origin, step) - offset / step
                let high = Self.floorDiv(estimate + tolerance - origin, step) - offset / step
                if low <= high {
                    if let steps = self.steps {
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
        }
        guard let first = self.first, let steps else { return (.unplaced, restarted) }
        // Until one point is left, the one nearest the middle of what the timestamps allow.
        let k = steps.lowerBound + (steps.upperBound - steps.lowerBound) / 2
        return (.position(origin + k * step + (relative - first)), restarted)
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    private static func ceilDiv(_ a: Int64, _ b: Int64) -> Int64 { -floorDiv(-a, b) }
}
