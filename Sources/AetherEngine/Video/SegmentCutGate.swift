import Foundation

/// When a VOD producer's muxer may move on to the next segment. Each packet belongs to the segment its own
/// time says (the keyframe-gated cutter for video, `AudioRunPlan` for audio), but the tracks arrive in the
/// source's interleave: a Matroska keyframe is read at its decode time, before the last audio of the
/// segment it closes, and audio can as well lead the picture. Cutting on whichever track reaches a boundary
/// first puts the other track's packets on the wrong side of it, by an amount that depends on where reading
/// began, so a segment cut by a seek's run differs from the same segment cut by continuous playback.
///
/// The gate holds the packets of the track that is ahead until every track has reached their segment, then
/// hands them on in segment order, keeping their arrival order within a segment. A track that is a whole
/// segment behind the one ahead has nothing at that boundary (a gap in its stream), so it holds nothing up.
struct SegmentCutGate<Item> {
    enum Track: Hashable { case video, audio }

    private var reached: [Track: Int]
    private var held: [(segment: Int, item: Item)] = []

    /// `tracks`: those the producer muxes; `segment`: the segment its muxer opens on.
    init(tracks: Set<Track>, segment: Int) {
        reached = Dictionary(uniqueKeysWithValues: tracks.map { ($0, segment) })
    }

    /// Packets waiting for another track.
    var heldCount: Int { held.count }

    /// The furthest segment every track has reached, or the one a segment short of the furthest any has.
    private var ready: Int {
        let values = reached.values
        guard let low = values.min(), let high = values.max() else { return Int.max }
        return max(low, high - 1)
    }

    /// `item` of `track`, in `segment`; what can be muxed now, in order.
    mutating func submit(_ item: Item, track: Track, segment: Int) -> [(segment: Int, item: Item)] {
        if let r = reached[track], segment > r { reached[track] = segment }
        held.append((segment, item))
        return release(through: ready)
    }

    /// Everything held, in order: the source has ended, or the producer stops.
    mutating func drain() -> [(segment: Int, item: Item)] {
        release(through: Int.max)
    }

    private mutating func release(through limit: Int) -> [(segment: Int, item: Item)] {
        guard held.contains(where: { $0.segment <= limit }) else { return [] }
        var out: [(segment: Int, item: Item)] = []
        var keep: [(segment: Int, item: Item)] = []
        for entry in held {
            if entry.segment <= limit { out.append(entry) } else { keep.append(entry) }
        }
        held = keep
        // Stable: within a segment the source's own interleave stands.
        return out.enumerated().sorted { ($0.element.segment, $0.offset) < ($1.element.segment, $1.offset) }
            .map(\.element)
    }
}
