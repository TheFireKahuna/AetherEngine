/// Placement by a stream's own presentation clock: TrueHD's output_timing, the frame each access unit plays
/// at, modulo 2^16 at the stream's rate, which runs through a stream at a constant offset from its start.
///
/// With that offset (`headOffset`, read once off the stream's head) a frame's position is the stream's start
/// plus the offset plus its clock, exactly, whichever run it falls in. Only the clock modulo its wrap is the
/// stream's, so the position is taken in the wrap's window nearest the run's last frame, or for a run's first
/// frame its container timestamp, which may then be off by up to half the wrap (0.68 s at 48 kHz). A run of
/// `SourceGrid.phaseShiftTimestamps` frames whose timestamps sit beyond the noise from it is a splice, the
/// clock no longer continuous with the container's timeline, and the clock parts from the run.
struct StreamClockPlacement {
    /// Where the clock reads zero, counted from the stream's start, in frames at the clock's own rate.
    let headOffset: Int64
    /// The run's last frame placed by the clock: its position and its clock.
    private var anchor: (position: Int64, clock: Int64)?
    /// Frames in a row whose timestamp sits beyond the noise from where the clock places them.
    private var disagreements = 0
    /// The clock and the timestamps parted, a splice: the caller places the rest of the run otherwise.
    private(set) var parted = false

    init(headOffset: Int64) { self.headOffset = headOffset }

    enum Placement: Equatable {
        case position(Int64)
        /// The run's first frame carries no timestamp to choose the window by.
        case unplaced
        /// The clock and the timestamps parted at this frame, the timestamp this far after the clock.
        case parted(byFrames: Int64)
    }

    /// Where the frame whose clock reads `clock` starts, in the placed frames' units. `modulus` is the clock's
    /// wrap and `scale` the clock-rate frames per placed frame (1, or a decimated stream's factor), `origin` the
    /// stream's start and `estimate` the frame's own timestamp, both in placed frames, and `noise` how far a
    /// timestamp may sit from its frame (`SourceGrid.noise`).
    mutating func place(clock: Int64, modulus: Int64, scale: Int64, origin: Int64, estimate: Int64?,
                        noise: Int64) -> Placement {
        let reference: Int64
        if let anchor {
            reference = anchor.position + Self.nearest(clock - anchor.clock, modulus: modulus)
        } else if let estimate {
            reference = estimate
        } else {
            return .unplaced
        }
        let mapped = origin + Self.floorDiv(headOffset, max(scale, 1)) + clock
        let position = reference + Self.nearest(mapped - reference, modulus: modulus)
        if let estimate {
            disagreements = abs(position - estimate) > noise ? disagreements + 1 : 0
            if disagreements >= SourceGrid.phaseShiftTimestamps {
                parted = true
                anchor = nil
                return .parted(byFrames: estimate - position)
            }
        }
        anchor = (position, clock)
        return .position(position)
    }

    /// The decoder started over: the run's last frame says nothing about the gap after it.
    mutating func breakRun() { anchor = nil }

    /// A new run (a seek, a segment's run): nothing carries over but the offset.
    mutating func restart() {
        anchor = nil
        disagreements = 0
        parted = false
    }

    /// `difference` brought into the wrap's window around zero, [-modulus/2, modulus/2).
    static func nearest(_ difference: Int64, modulus: Int64) -> Int64 {
        let r = ((difference % modulus) + modulus) % modulus
        return r >= (modulus + 1) / 2 ? r - modulus : r
    }

    private static func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }
}
