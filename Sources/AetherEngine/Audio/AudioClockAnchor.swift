import Foundation
import CoreMedia

/// Gapless presentation-clock for the software AudioDecoder output. Container per-packet PTS are
/// quantized to the container timebase (1 ms for MKV). When the decoded frame duration is not an
/// integer number of those ticks -- e.g. a 1536-sample AC-3 frame at 44.1 kHz is 34.83 ms, not an
/// integer ms -- stamping every CMSampleBuffer with its own quantized PTS leaves a +/-0.5 ms
/// gap/overlap between consecutive buffers, and AVSampleBufferAudioRenderer reconciles a
/// discontinuity at each boundary (~29 audible clicks/sec, a continuous crackle). 48 kHz AC-3
/// (1536 samples = exactly 32 ms) is integer-ms so it never showed.
///
/// Fix: anchor to the first frame's PTS, then advance by emitted sample count so consecutive buffers
/// abut to the sample. `reset()` on flush. The clock never decides on its own that the source has
/// moved: `AudioDecoder` holds every decoded frame against it (`AudioContinuity`) and asks for a new
/// anchor exactly where the source breaks. (It used to re-anchor only past 100 ms off, so any smaller
/// gap, a lost packet among them, left the audio early by that much until the next seek.) Mirrors
/// `OutputTimestampSanitizer`'s focused, unit-testable mutating-struct shape (issue #89).
struct AudioClockAnchor {

    private var anchorPTS: CMTime = .invalid
    private var emittedSamplesSinceAnchor: Int64 = 0

    /// Clear the anchor (flush/seek). The next `resolve` re-anchors to its `startPTS`.
    mutating func reset() {
        anchorPTS = .invalid
        emittedSamplesSinceAnchor = 0
    }

    /// Decide the PTS to stamp on a buffer whose container PTS is `startPTS`, without mutating state.
    /// `reanchor` distinguishes a fresh anchor (first buffer or post-discontinuity) from a continued
    /// gapless run; pass it back to `commit` once the buffer is actually emitted.
    /// `reanchor` is the caller's: the source broke here, so the buffer plays at `startPTS`.
    func resolve(startPTS: CMTime, sampleRate: Int32, reanchor: Bool = false) -> (pts: CMTime, reanchor: Bool) {
        guard anchorPTS.isValid, startPTS.isValid, !reanchor else {
            return (startPTS, true)  // first buffer after open/flush, a break, or no source PTS to anchor to
        }
        return (predicted(sampleRate: sampleRate), false)  // gapless: abut to the sample, ignore container rounding
    }

    /// Where the next sample goes, `pending` samples after what has been emitted; nil before the
    /// first anchor.
    func next(after pending: Int, sampleRate: Int32) -> CMTime? {
        guard anchorPTS.isValid else { return nil }
        return CMTimeAdd(predicted(sampleRate: sampleRate), CMTime(value: Int64(pending), timescale: sampleRate))
    }

    private func predicted(sampleRate: Int32) -> CMTime {
        CMTimeAdd(anchorPTS, CMTime(value: emittedSamplesSinceAnchor, timescale: sampleRate))
    }

    /// Advance the clock after a buffer was successfully emitted at `pts`. Only called on success so a
    /// dropped buffer does not inject phantom samples into the running count.
    mutating func commit(pts: CMTime, reanchor: Bool, sampleCount: Int) {
        if reanchor {
            anchorPTS = pts
            emittedSamplesSinceAnchor = Int64(sampleCount)
        } else {
            emittedSamplesSinceAnchor += Int64(sampleCount)
        }
    }
}
