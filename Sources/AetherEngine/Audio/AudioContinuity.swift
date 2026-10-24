import AetherLibavutil

/// Deterministic audio continuity, shared by the audio bridge and the software decoder.
///
/// Both stamp their output by counting samples from an anchor, because a container's per-packet
/// timestamps are rounded (1 ms in Matroska) and stamping every buffer from them leaves seams the
/// renderer hears (#89). The count is exact for as long as no audio goes missing, so it is the
/// timeline. What can break it is known: a packet the decoder rejects, a frame dropped before
/// output, a resampler rebuilt with samples still inside, and a source whose own timestamps jump
/// (an edit, a splice, a recording that lost packets), which only the container records: an audio
/// bitstream carries no clock, so a decoder hands on whatever timestamp it was given.
///
/// So every decoded frame's own source timestamp is held against where the count says it starts,
/// cumulatively from the anchor. Within what the container can state (half its tick, plus a sample)
/// they agree by definition and the count stands; beyond it the frame is placed exactly where its
/// timestamp says: the gap before it filled with silence, an overlap trimmed off its start, and a
/// jump of more than `maxFillSeconds` taken as a new anchor. Rounding never moves anything, and
/// every move has a cause that can be logged and tested.
enum AudioContinuity {

    enum Decision: Equatable {
        /// Where the count says: carry on.
        case `continue`
        /// The frame starts this many samples after the count: fill them with silence.
        case gap(Int64)
        /// The frame starts this many samples before the count: drop them from its start.
        case overlap(Int64)
        /// Further off than any fill or trim should cover: re-anchor on the frame (signed samples).
        case jump(Int64)
    }

    /// The longest gap filled with silence, and the longest overlap trimmed, before re-anchoring.
    static let maxFillSeconds: Int64 = 5

    /// The disagreement, in output samples, that is still the container's rounding: half a tick of
    /// `sourceTimeBase`, rounded up, plus one sample for the conversion between the two.
    static func tolerance(sourceTimeBase: AVRational, sampleRate: Int32) -> Int64 {
        guard sourceTimeBase.num > 0, sourceTimeBase.den > 0, sampleRate > 0 else { return 1 }
        let halfTick = (Int64(sourceTimeBase.num) * Int64(sampleRate) + 2 * Int64(sourceTimeBase.den) - 1)
            / (2 * Int64(sourceTimeBase.den))
        return halfTick + 1
    }

    static func decide(expected: Int64, actual: Int64, tolerance: Int64, sampleRate: Int32) -> Decision {
        let difference = actual - expected
        guard abs(difference) > tolerance else { return .continue }
        let limit = maxFillSeconds * Int64(max(sampleRate, 1))
        if difference > 0 { return difference <= limit ? .gap(difference) : .jump(difference) }
        return -difference <= limit ? .overlap(-difference) : .jump(difference)
    }
}
