// Only with the APACObjectOutput trait (personal builds, off by default).
#if APACObjectOutput
import Foundation

/// One object's position, size and gain over time, kept the way `ObjectAudioRenderer` applies
/// metadata: an update moves each value from where it is (mid-ramp included) to its new value over
/// the update's ramp, linearly, and a ramp of 0 (or the first update after a reset) jumps.
///
/// The object encoder needs it twice per 1024-frame packet: per sample, to apply the gain to the
/// audio, and once at the packet's end, to describe its motion as `APACObjectMetadata.Block`s. The
/// renderer moves an object linearly over each block's interpolation length (measured, README
/// §3.20), so a trajectory made of linear pieces is described exactly by a block wherever a piece
/// starts or a ramp ends.
struct APACObjectTrajectory {

    /// The values one update sets.
    struct Values: Equatable {
        var position: SIMD3<Float>
        var size: Float
        var gain: Float

        func lerp(to other: Values, _ t: Float) -> Values {
            Values(position: position + (other.position - position) * t,
                   size: size + (other.size - size) * t,
                   gain: gain + (other.gain - gain) * t)
        }
    }

    /// A linear piece: `from` at `start`, `to` at `start + length` and after.
    private struct Piece {
        var start: Int64
        var length: Int64
        var from: Values
        var to: Values

        func value(at t: Int64) -> Values {
            guard length > 0, t < start + length else { return to }
            guard t > start else { return from }
            return from.lerp(to: to, Float(t - start) / Float(length))
        }
    }

    /// The piece in force now, and the ones it replaced since the last `blocks` call (oldest first),
    /// which the packet being built still needs.
    private var piece: Piece
    private var replaced: [Piece] = []
    private var hasMetadata = false
    /// The renderer has no position for this object yet (stream start, encoder restart), so the next
    /// packet opens with a jump to it rather than a glide from the renderer's default.
    private(set) var needsJump = true

    init(_ initial: Values) {
        piece = Piece(start: 0, length: 0, from: initial, to: initial)
    }

    func value(at t: Int64) -> Values { piece.value(at: t) }

    /// Apply an update at absolute frame `t`. Updates come in time order, none before the start of
    /// the packet `blocks` will describe next.
    mutating func apply(_ values: Values, at t: Int64, rampFrames: Int) {
        let jump = rampFrames <= 0 || !hasMetadata
        hasMetadata = true
        let now = piece.value(at: t)
        replaced.append(piece)
        piece = jump
            ? Piece(start: t, length: 0, from: values, to: values)
            : Piece(start: t, length: Int64(rampFrames), from: now, to: values)
    }

    /// Hold every value where it has got to: the encoder restarted at `t`, and the renderer starts
    /// again from its default.
    mutating func restart(at t: Int64) {
        let now = piece.value(at: t)
        piece = Piece(start: t, length: 0, from: now, to: now)
        replaced.removeAll()
        needsJump = true
    }

    /// The next update describes the far side of a gap in the source: apply it as a jump.
    mutating func markDiscontinuity() { hasMetadata = false }

    /// Blocks describing `[packetStart, packetStart + 1024)`, at most `maxBlocks`. Call after every
    /// update before the packet's end and before any at or after it, then `finishPacket`.
    func blocks(
        packetStart: Int64, maxBlocks: Int, map: (Values) -> (APACObjectMetadata.Point, Float)
    ) -> [APACObjectMetadata.Block] {
        let end = packetStart + 1024
        let pieces = replaced + [piece]
        /// The value just after `t` (the latest piece starting at or before it) or just before it.
        func value(_ t: Int64, justAfter: Bool) -> Values {
            let p = pieces.last(where: { justAfter ? $0.start <= t : $0.start < t }) ?? pieces[0]
            return p.value(at: t)
        }
        // Where something changes inside the packet: a piece starts (jump or new ramp) or a ramp ends.
        var points: Set<Int64> = []
        for p in pieces {
            if p.start > packetStart, p.start < end { points.insert(p.start) }
            let rampEnd = p.start + p.length
            if p.length > 0, rampEnd > packetStart, rampEnd < end { points.insert(rampEnd) }
        }
        var boundaries = [packetStart] + points.sorted()
        // Over budget: evenly spaced boundaries instead (a jump between two of them becomes a glide
        // over at most 1024 / (maxBlocks / 2) frames). Half, since a jump costs two blocks.
        let budget = max(maxBlocks / 2, 1)
        if boundaries.count > budget {
            boundaries = (0..<budget).map { packetStart + Int64($0) * 1024 / Int64(budget) }
        }

        var blocks: [APACObjectMetadata.Block] = []
        func add(_ t: Int64, _ interpolation: Int64, _ v: Values) {
            let (point, size) = map(v)
            blocks.append(.init(start: Int(t - packetStart), interpolation: Int(interpolation), position: point, size: size))
        }
        for (i, t) in boundaries.enumerated() {
            let next = i + 1 < boundaries.count ? boundaries[i + 1] : end
            let after = value(t, justAfter: true)
            let target = value(next, justAfter: false)
            let jumps = (t == packetStart && needsJump) || value(t, justAfter: false) != after
            if jumps {
                add(t, 0, after)
                if target != after { add(t, next - t, target) }
            } else {
                add(t, next - t, target)
            }
        }
        return Array(blocks.prefix(maxBlocks))
    }

    /// The packet `blocks` described has been written: the renderer now knows the object, and the
    /// pieces it replaced are no longer needed.
    mutating func finishPacket() {
        replaced.removeAll()
        needsJump = false
    }
}
#endif
