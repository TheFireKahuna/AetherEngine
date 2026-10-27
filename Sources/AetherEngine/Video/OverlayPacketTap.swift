import Foundation
import CoreMedia
import CoreVideo
import QuartzCore
import Synchronization
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

/// The time AVPlayer is served a video access unit at: its presentation and decode times in the time base the session
/// serves video in (`HLSSegmentProducer.servedVideoTime`), the frame grid's where the producer puts video on one.
struct ServedVideoTime: Equatable {
    let pts: Int64
    let dts: Int64
    let timeBase: AVRational

    static func == (a: ServedVideoTime, b: ServedVideoTime) -> Bool {
        a.pts == b.pts && a.dts == b.dts && a.timeBase.num == b.timeBase.num && a.timeBase.den == b.timeBase.den
    }
}

/// The video packets the segment producer cuts for AVPlayer, kept for an overlay's own decoder
/// (``SoftwareOverlayRenderer``) and decoded near AVPlayer's clock.
///
/// The producer hands access units over in decode order, one run at a time: each producer (a load, a seek's restart,
/// either direction) opens a new run with its first unit. A unit is named by the time AVPlayer is served it at, in the
/// time base it is served in (the frame grid where the producer puts video on one, the source's otherwise), exactly:
/// the unit, the decoder's picture of it and AVPlayer's frame share that one time. Each unit keeps the packet to decode and what the
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

    /// A decoded picture with its own time, exact, as units are named.
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
    static var behindDecodeSeconds: Double { 0.5 }
    /// How far past the window units are fed while no picture reaches it: well past what any decoder and filter chain
    /// holds back, so a decoder that puts nothing out stops here rather than run through the stream.
    static var feedPastWindowSeconds: Double { 1 }
    /// How far before its run's first unit a clock still belongs to the run.
    static var runLeadSeconds: Double { 0.05 }

    private struct Entry {
        let seq: Int
        let run: Int
        /// Served time, in `timeBase` ticks.
        let pts: Int64
        let isKey: Bool
        let hasPacket: Bool
        let stored: SpilledUnits.Ref
    }

    private let spill = SpilledUnits()
    private let state = NSCondition()
    private var entries: [Int: Entry] = [:]            // by arrival sequence
    private var seqByPts: [Int64: Int] = [:]           // the latest cut of each served time
    private var decoded: [Int64: Picture] = [:]  // by the picture's own time
    private var fedInfo: [Int64: Info] = [:]     // the units the decoder has read back, by served time
    /// The time base units are served in, one for the session: the first unit's.
    private var timeBase = AVRational(num: 1, den: 1000)
    /// Where the decode works toward, in `timeBase` ticks.
    private var clockTicks: Int64 = 0
    private var closed = false
    private var nextSeq = 0
    /// The bytes the kept units hold on disk.
    private var storedBytes = 0

    /// The run the producer is cutting: counted by the one producer feeding at a time, read under `state`.
    private var run = 0
    /// The newest unit of that run. Guarded by `state`.
    private var runNewestPts = Int64.min

    // Decoder side, only touched from the decode loop (under `state` where it reads entries).
    private var decoder: OverlayTapDecoder?
    private var lastFed: (seq: Int, run: Int)?
    private var runFirstPts: Int64 = .max
    private var runLastPts: Int64 = .min
    /// Units handed to the decoder so far, its progress for a wait on a picture (``unitsDecoded``).
    private let decodedUnits = Atomic<Int>(0)

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

    /// The next unit opens a new run: a producer's first. Call before its ``insert``.
    func beginRun() {
        state.lock()
        run += 1
        runNewestPts = .min
        state.unlock()
    }

    /// Keeps one access unit: the time it is served at, `pts` in `timeBase`, and `packet` with that time on it, which
    /// the tap takes ownership of (nil when the unit has nothing to decode). The same access unit cut again (a producer
    /// restart over a region) replaces the earlier cut. A unit the volume refuses is not kept (``SpilledUnits`` logs it).
    func insert(pts: Int64, timeBase: AVRational, isKey: Bool, info: Info, packet: UnsafeMutablePointer<AVPacket>?) {
        var packet = packet
        let stored = spill.write(info: info.unitRecord(), packet: packet)
        let hasPacket = packet != nil
        trackedPacketFree(&packet)
        guard let stored else { return }
        state.lock()
        defer { state.unlock() }
        guard !closed else { return }
        if entries.isEmpty { self.timeBase = timeBase }
        let key = av_rescale_q(pts, timeBase, self.timeBase)
        let seq = nextSeq
        nextSeq += 1
        if let stale = seqByPts[key], let old = entries.removeValue(forKey: stale) { storedBytes -= old.stored.length }
        entries[seq] = Entry(seq: seq, run: run, pts: key, isKey: isKey, hasPacket: hasPacket, stored: stored)
        runNewestPts = max(runNewestPts, key)
        fedInfo.removeValue(forKey: key)
        storedBytes += stored.length
        seqByPts[key] = seq
        if entries.count > Self.hardMaxEntries { trimLocked() }
        state.broadcast()
    }

    // MARK: - Overlay

    /// The unit AVPlayer shows at `seconds` (item time): the one whose frame interval holds it (``unitKeyLocked(near:)``),
    /// nil when the producer has not cut it. Its `Info` is the one the decoder read back, or read from disk here for a
    /// unit the decoder has not fed.
    func unit(at seconds: Double) -> Unit? {
        state.lock()
        guard let key = unitKeyLocked(near: ticks(seconds)), let entry = seqByPts[key].flatMap({ entries[$0] }) else {
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

    /// The served interval of the unit after the one AVPlayer shows at `seconds` (item time): from its served time to the
    /// next unit's, exact. With no unit holding `seconds`, the first unit cut after it. The last unit cut lasts as long
    /// as the one before it. Nil while no unit after it is cut.
    func frameInterval(after seconds: Double) -> CMTimeRange? {
        state.lock()
        defer { state.unlock() }
        let t = ticks(seconds)
        let from = unitKeyLocked(near: t) ?? t
        guard let next = seqByPts.keys.filter({ $0 > from }).min() else { return nil }
        let end = seqByPts.keys.filter { $0 > next }.min() ?? (next + (next - from))
        return CMTimeRange(start: time(next), end: time(end))
    }

    /// The served time of the unit whose frame interval holds `t`: the unit nearest `t`, when `t` is nearer to it than
    /// to either of its neighbours' frames (less than half the distance to the nearer one). Units are a frame apart, so
    /// AVPlayer's time for a frame, which is its served time plus the run's axis, names its own unit and no other.
    /// Caller holds `state`.
    private func unitKeyLocked(near t: Int64) -> Int64? {
        if seqByPts[t] != nil { return t }
        let below = seqByPts.keys.filter { $0 < t }.max()
        let above = seqByPts.keys.filter { $0 > t }.min()
        let nearest: Int64
        switch (below, above) {
        case let (b?, a?): nearest = t - b <= a - t ? b : a
        case let (b?, nil): nearest = b
        case let (nil, a?): nearest = a
        case (nil, nil): return nil
        }
        let previous = seqByPts.keys.filter { $0 < nearest }.max()
        let following = seqByPts.keys.filter { $0 > nearest }.min()
        guard let spacing = [previous.map { nearest - $0 }, following.map { $0 - nearest }].compactMap({ $0 }).min()
        else { return nil }
        return 2 * abs(t - nearest) < spacing ? nearest : nil
    }

    /// `seconds` in `timeBase` ticks, and back. Caller holds `state`.
    private func ticks(_ seconds: Double) -> Int64 { Int64((seconds / av_q2d(timeBase)).rounded()) }
    private func seconds(_ ticks: Int64) -> Double { Double(ticks) * av_q2d(timeBase) }
    /// A served time as a `CMTime`, exactly, and a picture's time as served ticks. Caller holds `state`.
    private func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks * Int64(timeBase.num), timescale: timeBase.den) }
    private func key(_ time: CMTime) -> Int64 {
        av_rescale_q(time.value, AVRational(num: 1, den: time.timescale), timeBase)
    }

    /// Where AVPlayer's clock is (item time): what the decoder works toward and what is kept around it.
    func advance(to seconds: Double) {
        state.lock()
        clockTicks = ticks(seconds)
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
    static var heldPastSeconds: Double { 0.045 }

    /// The newest decoded picture at or before `seconds` (item time), with its own time: the picture on screen
    /// then, when pictures do not follow the units one for one (a field-rate deinterlace, decimation, a cadence
    /// retimed onto the film grid). Nil while the decoder is short of the clock and the next picture has been due
    /// for more than `heldPastSeconds`, measured from the first unit past the decoder's newest picture (a picture is
    /// late from when the one after it should have replaced it, not from its own time, so the measure holds at
    /// any frame rate): the caller keeps what it shows rather than move the picture on out of sync with the sound.
    /// Once held, nothing is shown until no picture is overdue at all, so a decoder hovering at the limit does not
    /// alternate held and late pictures. Where nothing lies between the decoder's newest picture and the clock (a
    /// gap in the stream, its end) the picture is the one on screen however old, and is shown.
    func picture(atOrBefore seconds: Double) -> Picture? {
        state.lock()
        let t = ticks(seconds)
        guard let candidate = decoded.filter({ $0.key <= t }).max(by: { $0.key < $1.key }) else {
            state.unlock()
            return nil
        }
        let newest = decoded.keys.max() ?? candidate.key
        let overdue = newest < t ? seqByPts.keys.filter({ $0 > newest && $0 <= t }).min().map { t - $0 } : nil
        let behind = (overdue ?? 0) > (catchUp.holding ? 0 : ticks(Self.heldPastSeconds))
        let behindMs = overdue.map { Int64((self.seconds($0) * 1000).rounded()) }
        let note = catchUp.note(behindMs: behind ? behindMs : nil, now: CACurrentMediaTime())
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
        state.lock()
        let currentKey = key(current.time)
        let later = decoded.filter { $0.key > currentKey }.sorted { $0.key < $1.key }.map(\.value)
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

    /// Whether the picture on screen at `seconds` (item time) has been decoded: the newest at or before it, final once
    /// a picture at or after it has been decoded too, since pictures arrive in presentation order.
    func hasPictureShown(at seconds: Double) -> Bool {
        state.lock()
        defer { state.unlock() }
        let t = ticks(seconds)
        guard let newest = decoded.keys.max(), newest >= t else { return false }
        return decoded.keys.contains { $0 <= t }
    }

    /// Where the decode works toward, in item seconds.
    var clockSeconds: Double {
        state.lock(); defer { state.unlock() }
        return seconds(clockTicks)
    }

    /// How many units the decoder has been handed, the ones it passes through as references included: moving while
    /// the decoder works its way to a picture, standing still when it has stalled.
    var unitsDecoded: Int { decodedUnits.load(ordering: .relaxed) }

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
            let clock = seconds(clockTicks)
            state.unlock()
            guard let (stored, pts, restart) = next, let read = SpilledUnits.read(stored) else { continue }
            if let info = Info(unitRecord: read.info) {
                state.lock()
                fedInfo[pts] = info
                state.unlock()
            }
            var packet = read.packet
            guard let unit = packet else { continue }
            // A pool per unit: this thread's own drains only when it exits, and a picture's buffers and Metal objects
            // would otherwise stay alive for the whole playback.
            autoreleasepool { decoder?.decode(unit, restarting: restart, clock: clock, timeBase: tb) }
            trackedPacketFree(&packet)
            decodedUnits.add(1, ordering: .relaxed)
        }
    }

    /// Where the next access unit to decode is kept, and whether it starts a new decode. Nil when the decoder is far
    /// enough ahead, or the producer has not cut what comes next. Caller holds `state`.
    private func nextPacketLocked() -> (SpilledUnits.Ref, Int64, Bool)? {
        let ahead = ticks(decodeAheadSeconds)
        let newestPicture = decoded.keys.max()
        let entry: Entry
        let restart: Bool
        if let fed = lastFed, clockTicks >= runFirstPts - ticks(Self.runLeadSeconds),
           clockTicks >= (newestPicture ?? runLastPts) - ahead - ticks(Self.behindDecodeSeconds),
           !keyframePastDecodeLocked() {
            // What was fed leads to the clock: carry on along the run until the pictures reach the decode window. A
            // decode still short of the clock carries on too, unless a keyframe past everything fed is nearer to it.
            guard (newestPicture ?? .min) < clockTicks + ahead,
                  runLastPts < clockTicks + ahead + ticks(Self.feedPastWindowSeconds) else { return nil }
            let following = entries[fed.seq + 1]
            if following == nil, fed.seq + 1 >= nextSeq { return nil }   // not cut yet
            if let following, following.run == fed.run {
                entry = following; restart = false
            } else {
                guard let key = keyframeLocked(beforeOrAt: clockTicks) else { return nil }
                entry = key; restart = true
            }
        } else {
            // A backward seek (before the run, or behind its decode), the first unit, or a keyframe nearer the clock
            // than the decode: start there.
            guard let key = keyframeLocked(beforeOrAt: clockTicks) else { return nil }
            entry = key; restart = true
        }
        guard entry.hasPacket else {
            lastFed = (entry.seq, entry.run)   // nothing to decode for this unit; step past it
            return nil
        }
        if restart {
            decoded.removeAll()
            catchUp = CatchUp()
            runFirstPts = entry.pts
            runLastPts = entry.pts
        }
        lastFed = (entry.seq, entry.run)
        runLastPts = max(runLastPts, entry.pts)
        return (entry.stored, entry.pts, restart)
    }

    /// Whether the decode is short of the clock and a keyframe at or before the clock lies past everything fed:
    /// starting there skips the rest of the way. Caller holds `state`.
    private func keyframePastDecodeLocked() -> Bool {
        guard runLastPts < clockTicks, let key = keyframeLocked(beforeOrAt: clockTicks) else { return false }
        return key.pts > runLastPts
    }

    /// The keyframe the decoder starts from for `t`: in the run that cut `t` (or the closest unit before it), the
    /// last keyframe at or before it both in decode order and in time. A picture that follows its GOP's keyframe in
    /// decode order but precedes it in time (an open GOP's leading pictures) references the GOP before, and decoded
    /// from its own keyframe it never comes out: the decode starts at the previous GOP's keyframe instead. Caller holds
    /// `state`.
    private func keyframeLocked(beforeOrAt t: Int64) -> Entry? {
        let seq = seqByPts[t] ?? seqByPts.filter { $0.key <= t }.max { $0.key < $1.key }?.value
        guard let seq, let clockEntry = entries[seq] else { return nil }
        return entries.values
            .filter { $0.isKey && $0.run == clockEntry.run && $0.seq <= seq && $0.pts <= t }
            .max { $0.seq < $1.seq }
    }

    private func store(_ picture: CVPixelBuffer, at time: CMTime) {
        state.lock()
        let t = key(time)
        decoded[t] = Picture(picture: picture, time: time, seconds: seconds(t))
        trimDecodedLocked()
        // The decode window is counted in pictures: a new one can close it, or leave it open for the next unit.
        state.broadcast()
        state.unlock()
    }

    /// Keeps the decoded pictures from the one on screen at the clock (the newest at or before it) on. Caller holds
    /// `state`.
    private func trimDecodedLocked() {
        fedInfo = fedInfo.filter { $0.key >= clockTicks - ticks(Self.fedInfoBehindSeconds) }
        guard let shown = decoded.keys.filter({ $0 <= clockTicks }).max() else { return }
        decoded = decoded.filter { $0.key >= shown }
    }

    /// How long behind the clock a fed unit's `Info` stays in memory: past any frame the overlay is still asked to make.
    static var fedInfoBehindSeconds: Double { 2 }

    /// Drops decoded pictures the clock has passed, units further behind than `keepBehindSeconds`, and past
    /// ``hardMaxEntries`` those furthest from the clock. The run being cut is kept while the clock is further past
    /// its newest unit than that: a backward seek's run is cut while the clock still reads where the seek left from,
    /// and it is what AVPlayer plays next. Caller holds `state`.
    private func trimLocked() {
        trimDecodedLocked()
        let keepBehind = ticks(Self.keepBehindSeconds)
        let floor = clockTicks - keepBehind
        let clockLeftRun = runNewestPts != .min && clockTicks > runNewestPts + keepBehind
        var drop = entries.values.filter { $0.pts < floor && !(clockLeftRun && $0.run == run) }.map(\.seq)
        let excess = entries.count - drop.count - Self.hardMaxEntries
        if excess > 0 {
            let dropped = Set(drop)
            drop += entries.values.filter { !dropped.contains($0.seq) }
                .sorted { a, b in
                    // Other runs first, then the furthest from the clock.
                    if (a.run == run) != (b.run == run) { return a.run != run }
                    return abs(a.pts - clockTicks) > abs(b.pts - clockTicks)
                }
                .prefix(excess).map(\.seq)
        }
        for seq in drop {
            guard let entry = entries.removeValue(forKey: seq) else { continue }
            if seqByPts[entry.pts] == seq { seqByPts.removeValue(forKey: entry.pts) }
            storedBytes -= entry.stored.length
        }
    }
}
