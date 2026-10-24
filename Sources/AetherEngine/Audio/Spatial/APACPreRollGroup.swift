import Foundation

/// The audio pre-roll sample group (`sgpd`/`sbgp` of grouping type `prol`, ISO/IEC 14496-12 10.6) on the APAC
/// track's fragments: how many packets a decoder has to decode before a sample for full output.
///
/// The encoder states it for every packet: `AudioStreamPacketDependencyDescription` reads independently
/// decodable with one packet of pre-roll (macOS 27, DRC on or off). Apple's own HLS writer (AVAssetWriter,
/// `mpeg4AppleHLS`) carries it as a fragment-local `prol` group with roll distance 1, which movenc, writing
/// the ALAC stand-in the APAC track is muxed as (`SpatialAudioBridge`), never writes. Without it a player
/// starting at a fragment has no way to know that the first packet's output wants the one before it.
///
/// As in Apple's writer, whose encoder emits an Audio Sync Packet without pre-roll every 75 packets or so,
/// the group covers the samples that need it and leaves the sync samples out: this encoder makes one on
/// every segment's first packet (`APACEncoder.syncPacketInterval`), which the muxer marks a sync sample.
enum APACPreRollGroup {

    /// Bytes the two boxes add to a `traf`: the one-entry `sgpd`, and the `sbgp` with `runs` runs.
    static func insertedBytes(runs: Int) -> Int { 26 + 20 + 8 * runs }

    /// The track ID of the init segment's `apac` track, or nil when it has none.
    static func apacTrackID(inInit initBytes: Data) -> UInt32? {
        let d = [UInt8](initBytes)
        for moov in children(d, 0, d.count) where moov.type == "moov" {
            for trak in children(d, moov.body, moov.end) where trak.type == "trak" {
                var trackID: UInt32?
                var isAPAC = false
                for box in children(d, trak.body, trak.end) {
                    if box.type == "tkhd", box.body + 4 <= box.end {
                        let version = d[box.body]
                        let at = box.body + (version == 1 ? 20 : 12)
                        if at + 4 <= box.end { trackID = be32(d, at) }
                    } else if box.type == "mdia" {
                        isAPAC = descendant(d, box, path: ["minf", "stbl", "stsd"]).map { stsd in
                            stsd.body + 16 <= stsd.end && String(decoding: d[(stsd.body + 12)..<(stsd.body + 16)], as: UTF8.self) == "apac"
                        } ?? false
                    }
                }
                if isAPAC, let trackID { return trackID }
            }
        }
        return nil
    }

    /// `moof` with the `prol` group added to the `traf` of `trackID`, covering its non-sync samples (the
    /// sample flags movenc writes: `tfhd` defaults, `trun` first-sample and per-sample flags), and every
    /// size and `trun` data offset it moves corrected. Nil when no sample needs it, or the fragment is not
    /// one this can rewrite safely (no such track, a 64-bit size, an explicit base data offset, no default
    /// sample flags), which the caller forwards as is.
    static func addingPreRoll(toMoof moof: Data, trackID: UInt32, rollDistance: Int16 = 1) -> Data? {
        var d = [UInt8](moof)
        guard d.count >= 8, String(decoding: d[4..<8], as: UTF8.self) == "moof", be32(d, 0) == UInt32(d.count) else { return nil }
        var target: (traf: Box, insertAt: Int, sync: [Bool])?
        var truns: [Box] = []
        for traf in children(d, 8, d.count) where traf.type == "traf" {
            var matches = false
            var insertAt = traf.body
            var sync: [Bool] = []
            var defaultFlags: UInt32?
            var alreadyGrouped = false
            for box in children(d, traf.body, traf.end) {
                switch box.type {
                case "tfhd":
                    guard box.body + 8 <= box.end else { return nil }
                    let flags = be32(d, box.body) & 0xFFFFFF
                    if be32(d, box.body + 4) == trackID {
                        // An absolute base offset would have to move too; movenc writes default-base-is-moof.
                        if flags & 0x1 != 0 { return nil }
                        matches = true
                        // default-sample-flags-present, after the optional sample description index,
                        // duration and size.
                        if flags & 0x20 != 0 {
                            var at = box.body + 8
                            for bit: UInt32 in [0x2, 0x8, 0x10] where flags & bit != 0 { at += 4 }
                            guard at + 4 <= box.end else { return nil }
                            defaultFlags = be32(d, at)
                        }
                    }
                    insertAt = box.end
                case "tfdt":
                    insertAt = box.end
                case "trun":
                    truns.append(box)
                    if matches {
                        guard let defaultFlags, let run = sampleSync(d, box, defaultFlags: defaultFlags) else { return nil }
                        sync += run
                    }
                case "sgpd", "sbgp":
                    if box.body + 8 <= box.end, String(decoding: d[(box.body + 4)..<(box.body + 8)], as: UTF8.self) == "prol" {
                        alreadyGrouped = true
                    }
                default:
                    break
                }
            }
            if matches {
                if alreadyGrouped || !sync.contains(false) { return nil }
                target = (traf, insertAt, sync)
            }
        }
        guard let target else { return nil }
        // Runs of samples: index 1 of this fragment's sgpd (0x10001) for those needing the packet
        // before, 0 (no group) for sync samples.
        var runs: [(count: UInt32, index: UInt32)] = []
        for sync in target.sync {
            let index: UInt32 = sync ? 0 : 0x0001_0001
            if let last = runs.last, last.index == index { runs[runs.count - 1].count += 1 } else { runs.append((1, index)) }
        }
        let n = UInt32(Self.insertedBytes(runs: runs.count))
        // Data offsets count from the moof's start, and the mdat follows the moof: every run's data moves.
        for trun in truns where trun.body + 12 <= trun.end && be32(d, trun.body) & 0x1 != 0 {
            put32(&d, trun.body + 8, be32(d, trun.body + 8) &+ n)
        }
        put32(&d, target.traf.start, be32(d, target.traf.start) + n)
        put32(&d, 0, be32(d, 0) + n)
        var sgpd: [UInt8] = []
        sgpd += u32(26) + Array("sgpd".utf8) + [1, 0, 0, 0] + Array("prol".utf8)
        sgpd += u32(2) + u32(1)                                         // default_length, entry_count
        sgpd += [UInt8(truncatingIfNeeded: UInt16(bitPattern: rollDistance) >> 8), UInt8(truncatingIfNeeded: UInt16(bitPattern: rollDistance))]
        var sbgp: [UInt8] = []
        sbgp += u32(UInt32(20 + 8 * runs.count)) + Array("sbgp".utf8) + [0, 0, 0, 0] + Array("prol".utf8)
        sbgp += u32(UInt32(runs.count))
        for run in runs { sbgp += u32(run.count) + u32(run.index) }
        d.insert(contentsOf: sgpd + sbgp, at: target.insertAt)
        return Data(d)
    }

    /// Each sample's sync status in `trun` (ISO/IEC 14496-12 8.8.8): its per-sample flags, the first
    /// sample's flags, else `defaultFlags`; `sample_is_non_sync_sample` is bit 16. Nil for a box too
    /// short for what its flags say it holds.
    private static func sampleSync(_ d: [UInt8], _ trun: Box, defaultFlags: UInt32) -> [Bool]? {
        guard trun.body + 8 <= trun.end else { return nil }
        let flags = be32(d, trun.body) & 0xFFFFFF
        let count = Int(be32(d, trun.body + 4))
        var at = trun.body + 8
        if flags & 0x1 != 0 { at += 4 }
        var first: UInt32?
        if flags & 0x4 != 0 {
            guard at + 4 <= trun.end else { return nil }
            first = be32(d, at)
            at += 4
        }
        // Per sample: duration, size, flags, composition offset, each present by its bit.
        let fields: [UInt32] = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }
        guard at + count * 4 * fields.count <= trun.end else { return nil }
        var sync: [Bool] = []
        sync.reserveCapacity(count)
        for i in 0..<count {
            var sampleFlags = i == 0 ? (first ?? defaultFlags) : defaultFlags
            for field in fields {
                if field == 0x400 { sampleFlags = be32(d, at) }
                at += 4
            }
            sync.append(sampleFlags & 0x1_0000 == 0)
        }
        return sync
    }

    // MARK: - Boxes

    struct Box { let type: String; let start: Int; let body: Int; let end: Int }

    /// The boxes in `[from, to)`, 32-bit sizes only (a 64-bit or malformed size ends the walk).
    static func children(_ d: [UInt8], _ from: Int, _ to: Int) -> [Box] {
        var out: [Box] = []
        var at = from
        while at + 8 <= to {
            let size = Int(be32(d, at))
            guard size >= 8, at + size <= to else { break }
            out.append(Box(type: String(decoding: d[(at + 4)..<(at + 8)], as: UTF8.self), start: at, body: at + 8, end: at + size))
            at += size
        }
        return out
    }

    private static func descendant(_ d: [UInt8], _ box: Box, path: [String]) -> Box? {
        var current = box
        for name in path {
            // stsd is a full box whose entries follow its header; it is the last step, so no walk into it.
            guard let next = children(d, current.body, current.end).first(where: { $0.type == name }) else { return nil }
            current = next
        }
        return current
    }

    private static func be32(_ d: [UInt8], _ at: Int) -> UInt32 {
        UInt32(d[at]) << 24 | UInt32(d[at + 1]) << 16 | UInt32(d[at + 2]) << 8 | UInt32(d[at + 3])
    }

    private static func put32(_ d: inout [UInt8], _ at: Int, _ v: UInt32) {
        d[at] = UInt8(v >> 24); d[at + 1] = UInt8(truncatingIfNeeded: v >> 16)
        d[at + 2] = UInt8(truncatingIfNeeded: v >> 8); d[at + 3] = UInt8(truncatingIfNeeded: v)
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }
}
