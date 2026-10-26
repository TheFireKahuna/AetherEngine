import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
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
/// The decoder works from the keyframe at or before the clock, along the run, until its newest picture is
/// `decodeAheadSeconds` ahead of the clock. The window is measured in pictures out, not units in: everything between
/// holds pictures back by its own amount (B-frame reordering, a deinterlacer's window, inverse telecine's cycle), and a
/// window of units would leave pictures arriving at the last moment, or not at all while the clock stands still. A
/// clock outside what has been fed (a seek, a new run) restarts it at the keyframe before the clock, the random-access
/// points the segments are cut on. Units are kept `keepBehindSeconds` behind the clock, so a backward seek into
/// segments the session still has cached (which the producer does not cut again) finds its packets.
///
/// A unit is kept on disk (``SpilledUnits``), its packet and its `Info` both, and in memory only its place in the
/// stream, so how far ahead the producer cuts costs disk, not memory. The decode thread reads a unit back as it feeds
/// it and keeps its `Info` while the overlay may ask for it. The producer parks while the tap is full
/// (``hasRoomAhead``), so a unit it cuts ahead is never dropped before the clock reaches it.
final class OverlayPacketTap<Info: OverlayUnitInfo>: @unchecked Sendable {

    struct Unit: @unchecked Sendable {
        let info: Info
        /// The decoded picture at the unit's time, nil until the decoder reaches it.
        let picture: CVPixelBuffer?
    }

    /// A decoded picture with its own time, exact, and in whole milliseconds as units are keyed.
    struct Picture: @unchecked Sendable {
        let picture: CVPixelBuffer
        let time: CMTime
        let seconds: Double
    }

    static var keepBehindSeconds: Double { 60 }
    /// Units the tap holds before the producer parks (``hasRoomAhead``): the minute kept behind the clock and about
    /// seven more ahead at 24p, which clears the furthest a subtitle consumer has the producer read
    /// (`AetherEngine.subtitleReadAheadCeilingSeconds`).
    static var maxEntries: Int { 12_000 }
    /// Past this the tap drops units, those furthest from the clock first: only reached while the producer cannot
    /// park, within the forward window AVPlayer is owed.
    static var hardMaxEntries: Int { maxEntries + maxEntries / 4 }

    let decodeAheadSeconds: Double
    /// A clock this far behind the decode window has jumped back: the decode is past where it is needed. More than a
    /// reordered GOP's lead, so a stream with B-frames does not read as one.
    static var behindDecodeMs: Int64 { 500 }
    /// How far past the window units are fed while no picture reaches it: well past what any decoder and filter chain
    /// holds back, so a decoder that puts nothing out stops here rather than run through the stream.
    static var feedPastWindowMs: Int64 { 1000 }

    private struct Entry {
        let seq: Int
        let run: Int
        let ptsMs: Int64
        let isKey: Bool
        let hasPacket: Bool
        let stored: SpilledUnits.Ref
    }

    private let spill = SpilledUnits()
    private let state = NSCondition()
    private var entries: [Int: Entry] = [:]            // by arrival sequence
    private var seqByPts: [Int64: Int] = [:]           // the latest cut of each presentation time
    private var decoded: [Int64: Picture] = [:]  // by the picture's own time, ms
    private var fedInfo: [Int64: Info] = [:]     // the units the decoder has read back, by presentation time, ms
    private var timeBase = AVRational(num: 1, den: 1000)
    private var clockMs: Int64 = 0
    private var closed = false
    private var nextSeq = 0
    /// The bytes the kept units hold on disk.
    private var storedBytes = 0

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
        entries.removeAll()
        seqByPts.removeAll()
        decoded.removeAll()
        fedInfo.removeAll()
        storedBytes = 0
        state.broadcast()
        state.unlock()
        spill.close()
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
    /// replaces the earlier cut. A unit the volume refuses is not kept (``SpilledUnits`` logs it).
    func insert(pts: Int64, timeBase: AVRational, isKey: Bool, info: Info, packet: UnsafeMutablePointer<AVPacket>?) {
        let ptsMs = Int64((Double(pts) * av_q2d(timeBase) * 1000).rounded())
        var packet = packet
        let stored = spill.write(info: info.unitRecord(), packet: packet)
        let hasPacket = packet != nil
        trackedPacketFree(&packet)
        guard let stored else { return }
        state.lock()
        defer { state.unlock() }
        guard !closed else { return }
        self.timeBase = timeBase
        let seq = nextSeq
        nextSeq += 1
        if let stale = seqByPts[ptsMs], let old = entries.removeValue(forKey: stale) { storedBytes -= old.stored.length }
        entries[seq] = Entry(seq: seq, run: run, ptsMs: ptsMs, isKey: isKey, hasPacket: hasPacket, stored: stored)
        fedInfo.removeValue(forKey: ptsMs)
        storedBytes += stored.length
        seqByPts[ptsMs] = seq
        if entries.count > Self.hardMaxEntries { trimLocked() }
        state.broadcast()
    }

    // MARK: - Overlay

    /// The unit AVPlayer shows at `seconds` (item time), nil when the producer has not cut it. Its `Info` is the one the
    /// decoder read back, or read from disk here for a unit the decoder has not fed.
    func unit(at seconds: Double) -> Unit? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        guard let (key, entry) = [ms, ms - 1, ms + 1].lazy
            .compactMap({ key in self.seqByPts[key].flatMap { self.entries[$0] }.map { (key, $0) } }).first
        else {
            state.unlock()
            return nil
        }
        let picture = decoded[key]?.picture
        let fed = fedInfo[key]
        state.unlock()
        if let fed { return Unit(info: fed, picture: picture) }
        guard let record = SpilledUnits.readInfo(entry.stored), let info = Info(unitRecord: record) else { return nil }
        return Unit(info: info, picture: picture)
    }

    /// The time of the first unit cut after `seconds` (item time), in whole milliseconds as units are keyed; nil
    /// while none is cut.
    func unitTime(after seconds: Double) -> Double? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        return seqByPts.keys.filter { $0 > ms }.min().map { Double($0) / 1000 }
    }

    /// Where AVPlayer's clock is (item time): what the decoder works toward and what is kept around it.
    func advance(to seconds: Double) {
        state.lock()
        clockMs = Int64((seconds * 1000).rounded())
        trimLocked()
        state.broadcast()
        state.unlock()
    }

    /// How long the next picture may be overdue and the one before it still be shown while the decoder works
    /// toward the clock: where a viewer starts to see picture behind sound, which is a time whatever the frame
    /// rate. Further behind, the picture on screen is held until the decoder is back on the clock, and the next
    /// one shown is the clock's own.
    ///
    /// The whole budget is the overlay's to spend: it is asked for the picture at the item time of the refresh
    /// that will show it, the clock AVPlayer keeps against the audio output's own latency, so in step it is on
    /// time to the refresh. The same timing makes the comparison exact in whole refreshes, at any display rate.
    static var heldPastMs: Int64 { 45 }

    /// The newest decoded picture at or before `seconds` (item time), with its own time: the picture on screen
    /// then, when pictures do not follow the units one for one (a field-rate deinterlace, decimation, a cadence
    /// retimed onto the film grid). Nil while the decoder is short of the clock and the next picture has been due
    /// for more than `heldPastMs`, measured from the first unit past the decoder's newest picture (a picture is
    /// late from when the one after it should have replaced it, not from its own time, so the measure holds at
    /// any frame rate): the caller keeps what it shows rather than move the picture on out of sync with the sound.
    /// Once held, nothing is shown until no picture is overdue at all, so a decoder hovering at the limit does not
    /// alternate held and late pictures. Where nothing lies between the decoder's newest picture and the clock (a
    /// gap in the stream, its end) the picture is the one on screen however old, and is shown.
    func picture(atOrBefore seconds: Double) -> Picture? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        guard let candidate = decoded.filter({ $0.key <= ms }).max(by: { $0.key < $1.key }) else {
            state.unlock()
            return nil
        }
        let newest = decoded.keys.max() ?? candidate.key
        let overdueMs = newest < ms ? seqByPts.keys.filter({ $0 > newest && $0 <= ms }).min().map { ms - $0 } : nil
        let behind = (overdueMs ?? 0) > (catchUp.holding ? 0 : Self.heldPastMs)
        let note = catchUp.note(behindMs: behind ? overdueMs : nil, now: CACurrentMediaTime())
        state.unlock()
        if let note { EngineLog.emit("[OverlayPacketTap] \(note)", category: .swPlayback) }
        return behind ? nil : candidate.value
    }

    /// The pictures to queue for display after `last` (the newest queued, nil when none is), in order: the one on
    /// screen at `seconds` (item time) by ``picture(atOrBefore:)``'s rule, when it is newer than `last`, and every
    /// picture decoded after it. Empty while that rule holds the picture on screen. A picture whose successor is
    /// already due is never on screen, so none before the one at `seconds` is offered.
    func pictures(after last: CMTime?, atOrBefore seconds: Double) -> [Picture] {
        guard let current = picture(atOrBefore: seconds) else { return [] }
        let currentMs = Int64((current.seconds * 1000).rounded())
        state.lock()
        let later = decoded.filter { $0.key > currentMs }.sorted { $0.key < $1.key }.map(\.value)
        state.unlock()
        guard let last else { return [current] + later }
        return ([current] + later).filter { CMTimeCompare($0.time, last) > 0 }
    }

    /// One stretch of the decoder behind the clock, from the refreshes that asked for a picture: how long the
    /// picture was held and how far behind it got, logged when it ends.
    private struct CatchUp {
        var since: CFTimeInterval?
        var peakMs: Int64 = 0
        var holding: Bool { since != nil }

        mutating func note(behindMs: Int64?, now: CFTimeInterval) -> String? {
            if let behindMs {
                if since == nil { since = now }
                peakMs = Swift.max(peakMs, behindMs)
                return nil
            }
            guard let start = since else { return nil }
            defer { since = nil; peakMs = 0 }
            return String(format: "decoder behind the clock: next picture overdue by up to %lld ms; picture held %.0f ms, then shown on the clock",
                          peakMs, (now - start) * 1000)
        }
    }
    /// Guarded by `state`.
    private var catchUp = CatchUp()

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

    var held: (units: Int, decoded: Int, bytes: Int) {
        state.lock(); defer { state.unlock() }
        return (entries.count, decoded.count, storedBytes)
    }

    /// Whether the producer may cut another unit: false once the tap holds ``maxEntries``, until the clock moves
    /// on and the units it passes are dropped.
    var hasRoomAhead: Bool {
        state.lock(); defer { state.unlock() }
        return entries.count < Self.maxEntries
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
            guard let (stored, ptsMs, restart) = next, let read = SpilledUnits.read(stored) else { continue }
            if let info = Info(unitRecord: read.info) {
                state.lock()
                fedInfo[ptsMs] = info
                state.unlock()
            }
            var packet = read.packet
            guard let unit = packet else { continue }
            // A pool per unit: this thread's own drains only when it exits, and a picture's buffers and Metal objects
            // would otherwise stay alive for the whole playback.
            autoreleasepool { decoder?.decode(unit, restarting: restart, clock: clock, timeBase: tb) }
            trackedPacketFree(&packet)
        }
    }

    /// Where the next access unit to decode is kept, and whether it starts a new decode. Nil when the decoder is far
    /// enough ahead, or the producer has not cut what comes next. Caller holds `state`.
    private func nextPacketLocked() -> (SpilledUnits.Ref, Int64, Bool)? {
        let aheadMs = Int64(decodeAheadSeconds * 1000)
        let newestPictureMs = decoded.keys.max()
        let entry: Entry
        let restart: Bool
        if let fed = lastFed, clockMs >= runFirstPtsMs - 50,
           clockMs >= (newestPictureMs ?? runLastPtsMs) - aheadMs - Self.behindDecodeMs, !keyframePastDecodeLocked() {
            // What was fed leads to the clock: carry on along the run until the pictures reach the decode window. A
            // decode still short of the clock carries on too, unless a keyframe past everything fed is nearer to it.
            guard (newestPictureMs ?? .min) < clockMs + aheadMs,
                  runLastPtsMs < clockMs + aheadMs + Self.feedPastWindowMs else { return nil }
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
        guard entry.hasPacket else {
            lastFed = (entry.seq, entry.run)   // nothing to decode for this unit; step past it
            return nil
        }
        if restart {
            decoded.removeAll()
            catchUp = CatchUp()
            runFirstPtsMs = entry.ptsMs
            runLastPtsMs = entry.ptsMs
        }
        lastFed = (entry.seq, entry.run)
        runLastPtsMs = max(runLastPtsMs, entry.ptsMs)
        return (entry.stored, entry.ptsMs, restart)
    }

    /// Whether the decode is short of the clock and a keyframe at or before the clock lies past everything fed:
    /// starting there skips the rest of the way. Caller holds `state`.
    private func keyframePastDecodeLocked() -> Bool {
        guard runLastPtsMs < clockMs, let key = keyframeLocked(beforeOrAt: clockMs) else { return false }
        return key.ptsMs > runLastPtsMs
    }

    /// The keyframe the decoder starts from for `ms`: in the run that cut `ms` (or the closest unit before it), the
    /// last keyframe at or before it both in decode order and in time. A picture that follows its GOP's keyframe in
    /// decode order but precedes it in time (an open GOP's leading pictures) references the GOP before, and decoded
    /// from its own keyframe it never comes out: the decode starts at the previous GOP's keyframe instead. Caller holds
    /// `state`.
    private func keyframeLocked(beforeOrAt ms: Int64) -> Entry? {
        let seq = seqByPts[ms] ?? seqByPts.filter { $0.key <= ms }.max { $0.key < $1.key }?.value
        guard let seq, let clockEntry = entries[seq] else { return nil }
        return entries.values
            .filter { $0.isKey && $0.run == clockEntry.run && $0.seq <= seq && $0.ptsMs <= ms }
            .max { $0.seq < $1.seq }
    }

    private func store(_ picture: CVPixelBuffer, at time: CMTime) {
        let ms = Int64((time.seconds * 1000).rounded())
        state.lock()
        decoded[ms] = Picture(picture: picture, time: time, seconds: Double(ms) / 1000)
        trimDecodedLocked()
        // The decode window is counted in pictures: a new one can close it, or leave it open for the next unit.
        state.broadcast()
        state.unlock()
    }

    /// Keeps the decoded pictures from the one on screen at the clock (the newest at or before it) on. Caller holds
    /// `state`.
    private func trimDecodedLocked() {
        fedInfo = fedInfo.filter { $0.key >= clockMs - Self.fedInfoBehindMs }
        guard let shown = decoded.keys.filter({ $0 <= clockMs }).max() else { return }
        decoded = decoded.filter { $0.key >= shown }
    }

    /// How long behind the clock a fed unit's `Info` stays in memory: past any frame the overlay is still asked to make.
    static var fedInfoBehindMs: Int64 { 2000 }

    /// Drops decoded pictures the clock has passed, units further behind than `keepBehindSeconds`, and past
    /// ``hardMaxEntries`` those furthest from the clock. Caller holds `state`.
    private func trimLocked() {
        trimDecodedLocked()
        let floor = clockMs - Int64(Self.keepBehindSeconds * 1000)
        var drop = entries.values.filter { $0.ptsMs < floor }.map(\.seq)
        let excess = entries.count - drop.count - Self.hardMaxEntries
        if excess > 0 {
            let dropped = Set(drop)
            drop += entries.values.filter { !dropped.contains($0.seq) }
                .sorted { abs($0.ptsMs - clockMs) > abs($1.ptsMs - clockMs) }
                .prefix(excess).map(\.seq)
        }
        for seq in drop {
            guard let entry = entries.removeValue(forKey: seq) else { continue }
            if seqByPts[entry.ptsMs] == seq { seqByPts.removeValue(forKey: entry.ptsMs) }
            storedBytes -= entry.stored.length
        }
    }
}
