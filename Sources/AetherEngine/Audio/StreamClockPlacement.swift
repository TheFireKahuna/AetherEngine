import Foundation

/// Where a stream's clock reads zero on the timeline the picture shares, one anchor per stretch of the clock: the
/// one read at load (`HLSVideoEngine.trueHDClockHeadOffset`), and one for each stretch past a splice that a run has
/// learned since. Shared by a session's runs, so a stretch is learned once and every later run places by it.
/// Anchors are in frames at the stream's own rate, counted from its start. Thread-safe.
final class StreamClockAnchors: @unchecked Sendable {
    private let lock = NSLock()
    private var anchors: [Int64]

    init(headOffset: Int64) { anchors = [headOffset] }

    var all: [Int64] { lock.withLock { anchors } }

    /// Keeps `anchor` for a stretch past a splice.
    func learn(_ anchor: Int64) { lock.withLock { if !anchors.contains(anchor) { anchors.append(anchor) } } }
}

/// Placement by a stream's own clock: TrueHD's output_timing, the frame each access unit plays at, modulo 2^16 at the
/// stream's rate, which runs through a stretch of the stream at a constant offset from its start.
///
/// With that offset (the stretch's anchor, from ``StreamClockAnchors``) a frame's position is the stream's start plus
/// the anchor plus its clock, exactly, whichever run it falls in. Only the clock modulo its wrap is the stream's, so
/// the position is taken in the wrap's window nearest the run's last frame, or for a run's first frame its container
/// timestamp, which may then be off by up to half the wrap (0.68 s at 48 kHz). A run starts on the anchor that puts
/// its first frame nearest its timestamp.
///
/// A run of `SourceGrid.phaseShiftTimestamps` frames whose timestamps sit beyond the noise from where the anchor places
/// them is a splice: the clock is on another stretch. Where another anchor places them within the noise, the run
/// carries on by it. Where none does, the stretch is new: the clock parts from the run, which the caller places by its
/// timestamps, and the frames that follow are read for the stretch's anchor (their timestamp less their clock, the
/// value the most of them allow within half a tick, ``mostAllowed(_:halfWidth:)``), kept for the runs after it.
struct StreamClockPlacement {
    let anchors: StreamClockAnchors
    /// The anchor this run places by, chosen at its first frame.
    private var anchor: Int64?
    /// The run's last frame placed by the clock: its position and its clock.
    private var last: (position: Int64, clock: Int64)?
    /// Frames in a row whose timestamp sits beyond the noise from where the clock places them.
    private var disagreements = 0
    /// The clock parted from the run: the caller places the rest of it otherwise.
    private(set) var parted = false
    /// Parted on a stretch no anchor fits: what the frames after it read, in frames at the stream's rate.
    private var readings: [Int64]?

    /// Frames a new stretch's anchor is read from, each with its timestamp: a few hundred of the stretch's first.
    static let learningReadings = 256

    init(anchors: StreamClockAnchors) { self.anchors = anchors }

    enum Placement: Equatable {
        case position(Int64)
        /// The run's first frame carries no timestamp to choose the window by.
        case unplaced
        /// The clock and the timestamps parted at this frame, the timestamp this far after the clock, and no anchor
        /// fits the stretch.
        case parted(byFrames: Int64)
        /// Parted earlier: the caller places by the timestamps.
        case byTimestamps
    }

    /// Where the frame whose clock reads `clock` starts, in the placed frames' units. `modulus` is the clock's wrap
    /// and `scale` the clock-rate frames per placed frame (1, or a decimated stream's factor), `origin` the stream's
    /// start and `estimate` the frame's own timestamp, both in placed frames, `noise` how far a timestamp may sit
    /// from its frame (`SourceGrid.noise`) and `tick` the timestamps' tick, in placed frames.
    mutating func place(clock: Int64, modulus: Int64, scale: Int64, origin: Int64, estimate: Int64?,
                        noise: Int64, tick: Int64) -> Placement {
        let scale = max(scale, 1)
        if parted {
            learn(clock: clock, modulus: modulus, scale: scale, origin: origin, estimate: estimate, tick: tick)
            return .byTimestamps
        }
        let reference: Int64
        if let last {
            reference = last.position + Self.nearest(clock - last.clock, modulus: modulus)
        } else if let estimate {
            reference = estimate
        } else {
            return .unplaced
        }
        // Where an anchor puts this frame, in the wrap's window around the reference.
        func position(by anchor: Int64) -> Int64 {
            let mapped = origin + Self.floorDiv(anchor, scale) + clock
            return reference + Self.nearest(mapped - reference, modulus: modulus)
        }
        if anchor == nil {
            anchor = anchors.all.min { abs(position(by: $0) - reference) < abs(position(by: $1) - reference) }
        }
        guard let current = anchor else { return .unplaced }
        var placed = position(by: current)
        if let estimate {
            disagreements = abs(placed - estimate) > noise ? disagreements + 1 : 0
            if disagreements >= SourceGrid.phaseShiftTimestamps {
                disagreements = 0
                // A splice: another stretch's anchor, or a new stretch.
                let fitting = anchors.all.first { $0 != current && abs(position(by: $0) - estimate) <= noise }
                if let fitting {
                    anchor = fitting
                    placed = position(by: fitting)
                } else {
                    parted = true
                    last = nil
                    readings = []
                    learn(clock: clock, modulus: modulus, scale: scale, origin: origin, estimate: estimate, tick: tick)
                    return .parted(byFrames: estimate - placed)
                }
            }
        }
        last = (placed, clock)
        return .position(placed)
    }

    /// Parted on a new stretch: one more frame's reading of its anchor; with enough of them, the anchor is kept.
    private mutating func learn(clock: Int64, modulus: Int64, scale: Int64, origin: Int64, estimate: Int64?, tick: Int64) {
        guard var read = readings, let estimate else { return }
        let reading = estimate - origin - clock
        read.append(read.first.map { $0 + Self.nearest(reading - $0, modulus: modulus) } ?? reading)
        readings = read
        guard read.count >= Self.learningReadings else { return }
        readings = nil
        // Only the anchor modulo the clock's wrap is the stream's: kept in the wrap's window around the load's.
        let learned = Self.middle(of: Self.mostAllowed(read, halfWidth: max(1, tick / 2))) * scale
        let reference = anchors.all.first ?? learned
        anchors.learn(reference + Self.nearest(learned - reference, modulus: modulus * scale))
    }

    /// The decoder started over: the run's last frame says nothing about the gap after it.
    mutating func breakRun() { last = nil }

    /// A new run (a seek, a segment's run): nothing carries over but the anchors.
    mutating func restart() {
        anchor = nil
        last = nil
        disagreements = 0
        parted = false
        readings = nil
    }

    /// The values the most readings allow: a closed range. A reading is a timestamp rounded to the nearest tick, a
    /// tie upward, less its exact place, so it lies in (x - halfWidth, x + halfWidth] of the true value x, and allows
    /// x in [r - halfWidth, r + halfWidth). A reading off by a whole tick then allows none of the true window, where a
    /// closed allowance would let late ones pull it a lattice step.
    static func mostAllowed(_ readings: [Int64], halfWidth: Int64) -> ClosedRange<Int64> {
        // Each reading's allowance opens at r - halfWidth and closes at r + halfWidth. Every change at a value is
        // applied before the stretch from it to the next change is counted; the best stretch is where most are open.
        var changes: [Int64: Int] = [:]
        for r in readings {
            changes[r - halfWidth, default: 0] += 1
            changes[r + halfWidth, default: 0] -= 1
        }
        let at = changes.keys.sorted()
        var open = 0, best = 0
        var range = (readings.first ?? 0)...(readings.first ?? 0)
        for (i, value) in at.enumerated() where i + 1 < at.count {
            open += changes[value]!
            if open > best {
                best = open
                range = value...(at[i + 1] - 1)
            }
        }
        return range
    }

    /// The middle of what the readings allow: readings exactly on a value allow [x - halfWidth, x + halfWidth), whose
    /// middle is x.
    static func middle(of allowed: ClosedRange<Int64>) -> Int64 {
        allowed.lowerBound + (allowed.upperBound - allowed.lowerBound + 1) / 2
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
