// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreMedia
import CoreVideo
import AetherLibavcodec
import AetherLibavutil

/// The enhancement half of a Profile 7 FEL whose base layer AVPlayer plays (`LoadOptions.felOverlay`),
/// taken from the session's own read of the source.
///
/// The segment producer already splits every video packet into its layers to serve the base layer
/// (`separateDualLayers`); with a tap it keeps the rest instead of dropping it: the compressed enhancement
/// layer, the composer parameters and the composed-form Profile 8.1 RPU, keyed by the packet's output
/// presentation time, which is AVPlayer's item time. The producer cuts ahead of AVPlayer, so a frame's
/// parameters exist before AVPlayer can show it, and a seek restarts the producer at the target, so the tap
/// follows seeks with no logic of its own.
///
/// The producer hands access units over in decode order, one run at a time (a restart or a seek starts a
/// new run), so the arrival sequence is the decode order. The enhancement layer is decoded near the clock:
/// from the keyframe at or before it, along that sequence, `decodeAheadSeconds` ahead. A clock outside what
/// has been fed (a seek, a new run) restarts the decoder at the keyframe before it, the random-access points
/// the segments are cut on. A frame whose enhancement picture is not decoded yet is still composed, with the
/// residual off; nothing here can hold up playback.
final class FelEnhancementTap: @unchecked Sendable {

    struct Frame: @unchecked Sendable {
        let enhancement: CVPixelBuffer?
        let params: DoviMetalParams
        /// Profile 8.1 with both curves set to no-op: describes a picture the composer has already reshaped.
        let composedRpu: [UInt8]?
    }

    static let decodeAheadSeconds = 0.75
    /// Kept behind the clock so a backward seek into segments the session still has cached (which the
    /// producer does not cut again) finds its enhancement layer.
    static let keepBehindSeconds = 60.0
    /// Ceiling on held access units, about four minutes at 24p, whatever the producer's window.
    static let maxEntries = 6000

    private struct Entry {
        let seq: Int
        let run: Int
        let ptsMs: Int64
        let isKey: Bool
        let params: DoviMetalParams
        let rpu: [UInt8]?
        var el: UnsafeMutablePointer<AVPacket>?
    }

    private let state = NSCondition()
    private var entries: [Int: Entry] = [:]            // by arrival sequence
    private var seqByPts: [Int64: Int] = [:]           // the latest cut of each presentation time
    private var decoded: [Int64: CVPixelBuffer] = [:]  // by pts ms
    private var timeBase = AVRational(num: 1, den: 1000)
    private var clockMs: Int64 = 0
    private var closed = false

    // Producer side, only touched from `rewrite` (one producer feeds at a time).
    private var alignment = DualLayerVideoDecoder.makeAlignment()
    private var lastParams: DoviMetalParams?
    private var lastRpu: [UInt8]?
    private var borrowedRun = 0
    private var lastRecordedDts: Int64?
    private var nextSeq = 0
    private var run = 0

    // Decoder side, only touched from the decode loop (under `state` where it reads entries).
    private var decoder: HardwareVideoDecoder?
    private var lastFed: (seq: Int, run: Int)?
    private var runFirstPtsMs: Int64 = .max
    private var runLastPtsMs: Int64 = .min

    init() {
        BlockingWork.detached(priority: .userInitiated) { [self] in decodeLoop() }
    }

    deinit { close() }

    func close() {
        state.lock()
        guard !closed else { state.unlock(); return }
        closed = true
        for entry in entries.values { var el = entry.el; trackedPacketFree(&el) }
        entries.removeAll()
        seqByPts.removeAll()
        decoded.removeAll()
        state.broadcast()
        state.unlock()
    }

    // MARK: - Producer

    /// Rewrites `packet` to its Profile 8.1 base layer, the way `convertPacketToProfile81` does, and keeps the
    /// enhancement layer and parameters. `packet` carries output (item-axis) timestamps, in decode order.
    func rewrite(_ packet: UnsafeMutablePointer<AVPacket>, framing: VideoNALFraming, timeBase: AVRational,
                 chromaLocation: UInt32) -> Bool {
        let pts = packet.pointee.pts
        let dts = packet.pointee.dts == Int64.min ? pts : packet.pointee.dts
        let isKey = packet.pointee.flags & AV_PKT_FLAG_KEY != 0
        // Decode time going backwards is a restart or a seek: a new run, read for picture order afresh. Only a
        // stated decode time counts; without one, arrival order is all there is.
        if packet.pointee.dts != Int64.min {
            if let last = lastRecordedDts, dts <= last {
                run += 1
                alignment = DualLayerVideoDecoder.makeAlignment()
            }
            lastRecordedDts = dts
        }
        var elPTS = pts
        if let data = packet.pointee.data, pts != Int64.min {
            elPTS = alignment.enhancementPTS(data, Int(packet.pointee.size), framing: framing, pts: pts)
        }
        let layers = DoviRpuConverter.separateDualLayers(packet, framing: framing)

        // The resolution `DualLayerVideoDecoder.recordSideData` applies.
        var params = layers.rpuParams
        var rpu = layers.convertedRpu
        if params != nil {
            lastParams = params; lastRpu = rpu; borrowedRun = 0
        } else if var last = lastParams {
            if layers.usesPreviousMapping {
                if layers.disableResidual { last.flags.insert(.disableResidual) } else { last.flags.remove(.disableResidual) }
                params = last; rpu = rpu ?? lastRpu
            } else if borrowedRun < DualLayerVideoDecoder.maxBorrowedParamsRun {
                borrowedRun += 1
                params = last; rpu = rpu ?? lastRpu
            }
        }
        guard pts != Int64.min, var params else {
            var el = layers.elPacket; trackedPacketFree(&el)
            return layers.success
        }
        params.blChromaLocation = chromaLocation
        if let el = layers.elPacket {
            el.pointee.pts = elPTS
            el.pointee.dts = dts
            if isKey { el.pointee.flags |= AV_PKT_FLAG_KEY }
        }

        let ptsMs = Int64((Double(pts) * av_q2d(timeBase) * 1000).rounded())
        state.lock()
        self.timeBase = timeBase
        let seq = nextSeq
        nextSeq += 1
        // The same access unit cut again (a producer restart over a region): the new cut replaces it.
        if let stale = seqByPts[ptsMs], var old = entries.removeValue(forKey: stale) { trackedPacketFree(&old.el) }
        entries[seq] = Entry(seq: seq, run: run, ptsMs: ptsMs, isKey: isKey, params: params, rpu: rpu, el: layers.elPacket)
        seqByPts[ptsMs] = seq
        if entries.count > Self.maxEntries { trimLocked() }
        state.broadcast()
        state.unlock()
        return layers.success
    }

    // MARK: - Renderer

    /// The frame AVPlayer shows at `seconds` (item time), nil when the producer has not cut it.
    func frame(at seconds: Double) -> Frame? {
        let ms = Int64((seconds * 1000).rounded())
        state.lock()
        defer { state.unlock() }
        for key in [ms, ms - 1, ms + 1] {
            if let seq = seqByPts[key], let entry = entries[seq] {
                return Frame(enhancement: decoded[key], params: entry.params, composedRpu: entry.rpu)
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

    var held: (accessUnits: Int, decoded: Int) {
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
            state.unlock()
            guard let (packet, restart) = next else { continue }
            if restart { decoder?.flush() }
            if decoder == nil { openDecoder(from: packet) }
            decoder?.decode(packet: packet)
            var copy: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&copy)
        }
    }

    /// The next access unit to decode (a copy), and whether it starts a new decode. Nil when the decoder is
    /// far enough ahead, or the producer has not cut what comes next. Caller holds `state`.
    private func nextPacketLocked() -> (UnsafeMutablePointer<AVPacket>, Bool)? {
        let aheadMs = Int64(Self.decodeAheadSeconds * 1000)
        let entry: Entry
        let restart: Bool
        if let fed = lastFed, clockMs >= runFirstPtsMs - 50, clockMs <= runLastPtsMs + 1000 {
            // What was fed covers the clock: carry on along the run, up to the decode window.
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
            // A seek, a new run, or a decoder that fell behind: the keyframe at or before the clock.
            guard let key = keyframeLocked(beforeOrAt: clockMs) else { return nil }
            entry = key; restart = true
        }
        guard let el = entry.el, let copy = av_packet_clone(el) else {
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
        return (copy, restart || decoder == nil)
    }

    /// The keyframe the decoder starts from for `ms`: in the run that cut `ms` (or the closest frame before
    /// it), the last keyframe at or before it in decode order. Caller holds `state`.
    private func keyframeLocked(beforeOrAt ms: Int64) -> Entry? {
        let seq = seqByPts[ms] ?? seqByPts.filter { $0.key <= ms }.max { $0.key < $1.key }?.value
        guard let seq, let clockEntry = entries[seq] else { return nil }
        return entries.values
            .filter { $0.isKey && $0.run == clockEntry.run && $0.seq <= seq }
            .max { $0.seq < $1.seq }
    }

    private func openDecoder(from packet: UnsafeMutablePointer<AVPacket>) {
        guard let data = packet.pointee.data else { return }
        var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
        A53SEIParser.forEachNAL(data, Int(packet.pointee.size), .lengthPrefixed(size: 4)) { nal, len in
            let bytes = [UInt8](UnsafeBufferPointer(start: nal, count: len))
            switch (nal[0] >> 1) & 0x3F {
            case 32: vps = bytes
            case 33: sps = bytes
            case 34: pps = bytes
            default: break
            }
        }
        guard let vps, let sps, let pps else { return }
        let d = HardwareVideoDecoder()
        state.lock(); let tb = timeBase; state.unlock()
        do {
            try d.open(parameterSets: [vps, sps, pps], timeBase: tb) { [weak self] buffer, pts, _ in
                self?.storeDecoded(buffer, ptsMs: Int64((pts.seconds * 1000).rounded()))
            }
            decoder = d
        } catch {
            EngineLog.emit("[FelEnhancementTap] enhancement decoder failed to open: \(error)", category: .swPlayback)
        }
    }

    private func storeDecoded(_ buffer: CVPixelBuffer, ptsMs: Int64) {
        state.lock()
        if seqByPts[ptsMs] != nil, ptsMs >= clockMs - 250 { decoded[ptsMs] = buffer }
        state.unlock()
    }

    /// Drops decoded pictures the clock has passed, access units further behind than `keepBehindSeconds`, and
    /// over the ceiling those furthest from the clock. Caller holds `state`.
    private func trimLocked() {
        decoded = decoded.filter { $0.key >= clockMs - 250 }
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
            trackedPacketFree(&entry.el)
        }
    }
}
#endif
