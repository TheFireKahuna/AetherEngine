import Foundation

/// Final-stage fMP4 muxer input guard enforcing `av_interleaved_write_frame` invariants per stream: (1) DTS strictly increases; (2) PTS >= DTS. Needed for SSAI (Pluto/Samsung-TV+ FAST) where ad creatives restart source clock at 2^33 (MPEG-TS modulus) with independently muxed audio -- a single pts<dts audio packet silences the whole ad segment. No-op for healthy content. Operates on muxer-time-base values; AV_NOPTS_VALUE passes through untouched.
///
/// Sound has a third rule: a packet never starts inside the sound already written. An fMP4 track states
/// no time per sample, only durations from one sample's decode time to the next, so a sound packet
/// pushed to "last + 1" by rule (1) still decodes to its full length while its timeline shrinks to a
/// tick. Every such packet puts the track's sound further behind its own timeline, and nothing
/// downstream can tell. A packet that starts more than half its length before the end of the last one
/// kept is a repeat of sound already written, and is dropped instead, so the sound a track holds and
/// the time it spans can never come apart by more than half a packet.
struct OutputTimestampSanitizer {
    private var lastDtsByStream: [Int32: Int64] = [:]
    /// Where the last sound packet kept ends (its pts plus its duration), per stream.
    private var soundEndByStream: [Int32: Int64] = [:]
    /// The furthest a sound packet may start before the sound written and still be read as a repeat of
    /// it. Further back is a source clock that restarted (an ad creative's), which rule (1) carries on
    /// from as before. 0 turns the sound rule off.
    let maxSoundOverlapTicks: Int64
    /// Sound packets dropped as repeats of sound already written, over this sanitizer's life.
    private(set) var droppedSoundRepeats = 0

    init(maxSoundOverlapTicks: Int64 = 0) {
        self.maxSoundOverlapTicks = maxSoundOverlapTicks
    }

    /// nil when the packet is not to be written: no dts after the stream's last one exists (it already
    /// sits at Int64.max, audit SEG-101), or, for sound (`soundDuration` given), it repeats sound
    /// already written. The caller drops it.
    mutating func sanitize(streamIndex: Int32, pts: Int64, dts: Int64,
                           soundDuration: Int64? = nil) -> (pts: Int64, dts: Int64)? {
        guard dts != Int64.min else { return (pts, dts) }  // NOPTS: nothing to enforce

        let start = pts == Int64.min ? dts : pts
        if let duration = soundDuration, duration > 0, maxSoundOverlapTicks > 0,
           let end = soundEndByStream[streamIndex] {
            let overlap = end &- start
            if overlap > duration / 2, overlap <= maxSoundOverlapTicks {
                droppedSoundRepeats += 1
                return nil
            }
        }

        var outDts = dts
        if let last = lastDtsByStream[streamIndex], outDts <= last {
            let (bumped, overflow) = last.addingReportingOverflow(1)
            guard !overflow else { return nil }
            outDts = bumped
        }
        let outPts = pts == Int64.min ? outDts : max(pts, outDts)  // NOPTS pts collapses to dts (safe floor for audio and video)

        lastDtsByStream[streamIndex] = outDts
        if let duration = soundDuration, duration > 0 {
            soundEndByStream[streamIndex] = outPts &+ duration
        }
        return (outPts, outDts)
    }
}
