import Foundation
import AetherLibavutil

/// Soft telecine (docs/software-route-gpu.md 6.1): film coded as progressive pictures that ask the display to repeat
/// fields, H.262 `repeat_first_field` / `top_field_first`, H.264 `pic_struct`, VC-1 `RFF` / `RPTFRM`. FFmpeg's decoders
/// report each picture's display duration as (2 + `repeat_pict`) half carriage frames; a run of progressive pictures
/// whose durations alternate between x and 3x/2 half frames (2 and 3 fields, or 2 and 3 frames in a progressive
/// sequence) is film at 4/5 of the carriage rate.
///
/// Inside such a run the pictures are re-timed onto a uniform grid of one film period, 5x/8 carriage frames, anchored
/// at the run's first picture and computed per index, so it never drifts. Shown on its own field timeline, film puts
/// two pictures 2 fields apart and the next 3 fields apart; on a panel at the film rate two of them can fall on one
/// refresh, depending on the refresh phase, and one is lost. On the grid each picture has a refresh of its own. The
/// grid and the field timeline agree at every cycle (4 pictures, 10 fields) and lie at most half a field apart inside
/// it. Container timestamps are not that exact (x264's pulldown places the pictures of a cycle at 0, 4, 6 and 8 fields),
/// so a run ends on an interlaced picture, a duration that breaks the alternation, or a timestamp further than one
/// carriage frame from its slot (an edit, a splice), and detection starts over.
///
/// Not thread-safe; the owning decoder serialises access with its lock.
final class FilmCadence {

    private struct Seen {
        var halves: Int
        var progressive: Bool
        var pts: Int64
    }

    private struct Run {
        var anchor: Int64
        var index: Int64
        /// The shorter of the two durations, in half carriage frames: 2 (fields) or 4 (frames of a progressive sequence).
        var short: Int
        var lastHalves: Int
        var carriage: AVRational
    }

    let timeBase: AVRational
    private var seen: [Seen] = []
    private var run: Run?

    init(timeBase: AVRational) {
        self.timeBase = timeBase
    }

    /// Pictures needed to recognise a run: two full alternations.
    static let confirmation = 4

    /// Whether the last pictures' film run is in force.
    var isActive: Bool { run != nil }

    /// The shorter duration of an alternation x, 3x/2, x, ... of at least two pictures, or nil.
    static func alternation(_ halves: [Int]) -> Int? {
        guard halves.count >= 2 else { return nil }
        let short = halves.min()!
        guard short == 2 || short == 4 else { return nil }
        let long = short * 3 / 2
        for (i, h) in halves.enumerated() {
            guard h == short || h == long else { return nil }
            if i > 0, h == halves[i - 1] { return nil }
        }
        return short
    }

    /// The timestamp to present a decoded picture at: on the film grid inside a run, its own otherwise. `carriage` is
    /// the decoder's frame rate (the sequence's, not the film's); `repeatPict` is `AVFrame.repeat_pict`.
    func retime(pts: Int64, interlaced: Bool, repeatPict: Int32, carriage: AVRational) -> Int64 {
        let halves = 2 + Int(max(repeatPict, 0))
        let noPTS = Int64.min
        guard carriage.num > 0, carriage.den > 0 else {
            reset()
            return pts
        }
        if var r = run {
            r.index += 1
            let slot = grid(r, index: r.index)
            if !interlaced, r.carriage.num == carriage.num, r.carriage.den == carriage.den,
               halves != r.lastHalves, halves == r.short || halves == r.short * 3 / 2,
               pts == noPTS || abs(pts - slot) <= tolerance(carriage) {
                r.lastHalves = halves
                run = r
                return slot
            }
            reset()
        }
        seen.append(Seen(halves: halves, progressive: !interlaced, pts: pts))
        if seen.count > Self.confirmation { seen.removeFirst(seen.count - Self.confirmation) }
        guard seen.count == Self.confirmation, seen.allSatisfy(\.progressive), seen[0].pts != noPTS,
              let short = Self.alternation(seen.map(\.halves)) else { return pts }
        let candidate = Run(anchor: seen[0].pts, index: Int64(Self.confirmation - 1), short: short,
                            lastHalves: halves, carriage: carriage)
        // The pictures that confirmed the run must already sit on its grid.
        for (i, s) in seen.enumerated() where s.pts != noPTS {
            guard abs(s.pts - grid(candidate, index: Int64(i))) <= tolerance(carriage) else { return pts }
        }
        run = candidate
        seen.removeAll()
        return grid(candidate, index: candidate.index)
    }

    /// Forgets the run and the pictures seen (a seek, the end of the stream).
    func reset() {
        run = nil
        seen.removeAll()
    }

    /// The film period is 5x/8 carriage frames: 1.25 frames from 2-3 fields, 2.5 frames from 2-3 frames.
    private func grid(_ r: Run, index: Int64) -> Int64 {
        r.anchor + av_rescale_q(index * 5 * Int64(r.short), AVRational(num: r.carriage.den, den: 8 * r.carriage.num), timeBase)
    }

    private func tolerance(_ carriage: AVRational) -> Int64 {
        av_rescale_q(1, AVRational(num: carriage.den, den: carriage.num), timeBase)
    }
}
