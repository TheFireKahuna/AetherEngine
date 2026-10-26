import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

/// The decoder an ``OverlayPacketTap`` drives, on the tap's own thread. It hands each picture it decodes to the
/// `deliver` it was made with, with the picture's item time.
protocol OverlayTapDecoder: AnyObject {
    /// Decodes `packet`, the tap's own copy, freed after the call. `restarting` first drops what the decoder holds
    /// (a seek, a new run, a decoder that fell behind). `clock` is where the player is, in item seconds: a picture
    /// before it is a reference the decode passes through, not a picture anyone will show, so a decoder can spend
    /// as little on it as it is able to.
    func decode(_ packet: UnsafeMutablePointer<AVPacket>, restarting: Bool, clock: Double, timeBase: AVRational)
    func close()
}

/// The video packets the segment producer cuts for AVPlayer, kept for an overlay's own decoder
/// (``SoftwareOverlayRenderer``) and decoded near AVPlayer's clock.
///
/// The producer hands access units over in decode order with output (item-axis) timestamps, one run at a time:
/// decode time going backwards is a restart or a seek, a new run. Each unit keeps the packet to decode and what the
/// overlay needs beside it (`Info`), keyed by its presentation time, which is AVPlayer's item time. The producer cuts
/// ahead of AVPlayer, so a unit exists before AVPlayer can show it, and a seek restarts the producer at the target,
/// so the tap follows seeks with no logic of its own.
///
/// The decoder works from the keyframe at or before the clock, along the run, `decodeAheadSeconds` ahead. A clock
/// outside what has been fed (a seek, a new run) restarts it at the keyframe before the clock, the random-access
/// points the segments are cut on. Units are kept `keepBehindSeconds` behind the clock, so a backward seek into
/// segments the session still has cached (which the producer does not cut again) finds its packets.
final class OverlayPacketTap<Info>: @unchecked Sendable {

    struct Unit: @unchecked Sendable {
        let info: Info
        /// The decoded picture at the unit's time, nil until the decoder reaches it.
        let picture: CVPixelBuffer?
    }

    static var keepBehindSeconds: Double { 60 }
    /// Ceiling on held units, about four minutes at 24p, whatever the producer's window.
    static var maxEntries: Int { 6000 }

    let decodeAheadSeconds: Double
    /// A clock this far behind the decode window has jumped back: the decode is past where it is needed. More than a
    /// reordered GOP's lead, so a stream with B-frames does not read as one.
    static var behindDecodeMs: Int64 { 500 }

    private struct Entry {
        let seq: Int
        let run: Int
        let ptsMs: Int64
        let isKey: Bool
        let info: Info
        var packet: UnsafeMutablePointer<AVPacket>?
    }

    private let state = NSCondition()
    private var entries: [Int: Entry] = [:]            // by arrival sequence
    private var seqByPts: [Int64: Int] = [:]           // the latest cut of each presentation time
    private var decoded: [Int64: CVPixelBuffer] = [:]  // by the picture's own time, ms
    private var timeBase = AVRational(num: 1, den: 1000)
    private var clockMs: Int64 = 0
    private var closed = false
    private var nextSeq = 0

    // Producer side, only touched by the one producer feeding at a time.
    private var lastRecordedDts: Int64?
    private var run = 0

    // Decoder side, only touched from the decode loop (under `state` where it reads entries).
    private var decoder: OverlayTapDecoder?
    private var lastFed: (seq: Int, run: Int)?
    private var runFirstPtsMs: Int64 = .max
    private var runLastPtsMs: Int64 = .min

    /// `makeDecoder` is called once, with the closure the decoder delivers its pictures to.
    init(decodeAheadSeconds: Double,
         makeDecoder: (_ deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) -> OverlayTapDecoder) {
        self.decodeAheadSeconds = decodeAheadSeconds
        decoder = makeDecoder { [weak self] picture, time in self?.store(picture, at: time) }
        BlockingWork.detached(priority: .userInitiated) { [self] in decodeLoop() }
    }

    deinit { close() }

    func close() {
        state.lock()
        guard !closed else { state.unlock(); return }
        closed = true
        for entry in entries.values { var packet = entry.packet; trackedPacketFree(&packet) }
        entries.removeAll()
        seqByPts.removeAll()
        decoded.removeAll()
        state.broadcast()
        state.unlock()
    }

    // MARK: - Producer

    /// Whether the unit with decode time `dts` starts a new run (decode time going backwards). Only a stated decode
    /// time counts; without one, arrival order is all there is. Call before ``insert``.
    func beginsRun(dts: Int64) -> Bool {
        guard dts != Int64.min else { return false }
        defer { lastRecordedDts = dts }
        guard let last = lastRecordedDts, dts <= last else { return false }
        run += 1
        return true
    }

    /// Keeps one access unit: its presentation time in `timeBase`, and `packet`, which the tap takes ownership of
    /// (nil when the unit has nothing to decode). The same access unit cut again (a producer restart over a region)
    /// replaces the earlier cut.
    func insert(pts: Int64, timeBase: AVRational, isKey: Bool, info: Info, packet: UnsafeMutablePointer<AVPacket>?) {
        let ptsMs = Int64((Double(pts) * av_q2d(timeBase) * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        guard !closed else { var packet = packet; trackedPacketFree(&packet); return }
        self.timeBase = timeBase
        let seq = nextSeq
        nextSeq += 1
        if let stale = seqByPts[ptsMs], var old = entries.removeValue(forKey: stale) { trackedPacketFree(&old.packet) }
        entries[seq] = Entry(seq: seq, run: run, ptsMs: ptsMs, isKey: isKey, info: info, packet: packet)
        seqByPts[ptsMs] = seq
        if entries.count > Self.maxEntries { trimLocked() }
        state.broadcast()
    }

    // MARK: - Overlay

    /// The unit AVPlayer shows at `seconds` (item time), nil when the producer has not cut it.
    func unit(at seconds: Double) -> Unit? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        for key in [ms, ms - 1, ms + 1] {
            if let seq = seqByPts[key], let entry = entries[seq] {
                return Unit(info: entry.info, picture: decoded[key])
            }
        }
        return nil
    }

    /// Where AVPlayer's clock is (item time): what the decoder works toward and what is kept around it.
    func advance(to seconds: Double) {
        state.lock()
        clockMs = Int64((seconds * 1000).rounded())
        trimLocked()
        state.broadcast()
        state.unlock()
    }

    /// The newest decoded picture at or before `seconds` (item time), with its own time: the picture on screen
    /// then, when pictures do not follow the units one for one (a field-rate deinterlace, decimation, a cadence
    /// retimed onto the film grid).
    func picture(atOrBefore seconds: Double) -> (picture: CVPixelBuffer, seconds: Double)? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        return decoded.filter { $0.key <= ms }.max { $0.key < $1.key }.map { ($0.value, Double($0.key) / 1000) }
    }

    /// Whether a picture within `toleranceSeconds` of `seconds` (item time) has been decoded.
    func hasPicture(near seconds: Double, toleranceSeconds: Double) -> Bool {
        let ms = Int64((seconds * 1000).rounded()), tolerance = Int64((toleranceSeconds * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        return decoded.keys.contains { abs($0 - ms) <= tolerance }
    }

    /// Where the decode works toward, in item seconds.
    var clockSeconds: Double {
        state.lock(); defer { state.unlock() }
        return Double(clockMs) / 1000
    }

    var held: (units: Int, decoded: Int) {
        state.lock(); defer { state.unlock() }
        return (entries.count, decoded.count)
    }

    // MARK: - Decoder

    private func decodeLoop() {
        while true {
            state.lock()
            if closed { state.unlock(); decoder?.close(); return }
            let next = nextPacketLocked()
            if next == nil { state.wait(until: Date().addingTimeInterval(0.05)) }
            let tb = timeBase
            let clock = Double(clockMs) / 1000
            state.unlock()
            guard let (packet, restart) = next else { continue }
            decoder?.decode(packet, restarting: restart, clock: clock, timeBase: tb)
            var copy: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&copy)
        }
    }

    /// The next access unit to decode (a copy), and whether it starts a new decode. Nil when the decoder is far
    /// enough ahead, or the producer has not cut what comes next. Caller holds `state`.
    private func nextPacketLocked() -> (UnsafeMutablePointer<AVPacket>, Bool)? {
        let aheadMs = Int64(decodeAheadSeconds * 1000)
        let entry: Entry
        let restart: Bool
        if let fed = lastFed, clockMs >= runFirstPtsMs - 50, clockMs >= runLastPtsMs - aheadMs - Self.behindDecodeMs,
           !keyframePastDecodeLocked() {
            // What was fed leads to the clock: carry on along the run, up to the decode window. A decode still
            // short of the clock carries on too, unless a keyframe past everything fed is nearer to it.
            guard runLastPtsMs < clockMs + aheadMs else { return nil }
            let following = entries[fed.seq + 1]
            if following == nil, fed.seq + 1 >= nextSeq { return nil }   // not cut yet
            if let following, following.run == fed.run {
                entry = following; restart = false
            } else {
                guard let key = keyframeLocked(beforeOrAt: clockMs) else { return nil }
                entry = key; restart = true
            }
        } else {
            // A backward seek (before the run, or behind its decode), the first unit, or a keyframe nearer the clock
            // than the decode: start there.
            guard let key = keyframeLocked(beforeOrAt: clockMs) else { return nil }
            entry = key; restart = true
        }
        guard let packet = entry.packet, let copy = av_packet_clone(packet) else {
            lastFed = (entry.seq, entry.run)   // nothing to decode for this unit; step past it
            return nil
        }
        if restart {
            decoded.removeAll()
            runFirstPtsMs = entry.ptsMs
            runLastPtsMs = entry.ptsMs
        }
        lastFed = (entry.seq, entry.run)
        runLastPtsMs = max(runLastPtsMs, entry.ptsMs)
        return (copy, restart)
    }

    /// Whether the decode is short of the clock and a keyframe at or before the clock lies past everything fed:
    /// starting there skips the rest of the way. Caller holds `state`.
    private func keyframePastDecodeLocked() -> Bool {
        guard runLastPtsMs < clockMs, let key = keyframeLocked(beforeOrAt: clockMs) else { return false }
        return key.ptsMs > runLastPtsMs
    }

    /// The keyframe the decoder starts from for `ms`: in the run that cut `ms` (or the closest unit before it), the
    /// last keyframe at or before it in decode order. Caller holds `state`.
    private func keyframeLocked(beforeOrAt ms: Int64) -> Entry? {
        let seq = seqByPts[ms] ?? seqByPts.filter { $0.key <= ms }.max { $0.key < $1.key }?.value
        guard let seq, let clockEntry = entries[seq] else { return nil }
        return entries.values
            .filter { $0.isKey && $0.run == clockEntry.run && $0.seq <= seq }
            .max { $0.seq < $1.seq }
    }

    private func store(_ picture: CVPixelBuffer, at time: CMTime) {
        let ms = Int64((time.seconds * 1000).rounded())
        state.lock()
        decoded[ms] = picture
        trimDecodedLocked()
        state.unlock()
    }

    /// Keeps the decoded pictures from the one on screen at the clock (the newest at or before it) on. Caller holds
    /// `state`.
    private func trimDecodedLocked() {
        guard let shown = decoded.keys.filter({ $0 <= clockMs }).max() else { return }
        decoded = decoded.filter { $0.key >= shown }
    }

    /// Drops decoded pictures the clock has passed, units further behind than `keepBehindSeconds`, and over the
    /// ceiling those furthest from the clock. Caller holds `state`.
    private func trimLocked() {
        trimDecodedLocked()
        let floor = clockMs - Int64(Self.keepBehindSeconds * 1000)
        var drop = entries.values.filter { $0.ptsMs < floor }.map(\.seq)
        let excess = entries.count - drop.count - Self.maxEntries
        if excess > 0 {
            let dropped = Set(drop)
            drop += entries.values.filter { !dropped.contains($0.seq) }
                .sorted { abs($0.ptsMs - clockMs) > abs($1.ptsMs - clockMs) }
                .prefix(excess).map(\.seq)
        }
        for seq in drop {
            guard var entry = entries.removeValue(forKey: seq) else { continue }
            if seqByPts[entry.ptsMs] == seq { seqByPts.removeValue(forKey: entry.ptsMs) }
            trackedPacketFree(&entry.packet)
        }
    }
}
