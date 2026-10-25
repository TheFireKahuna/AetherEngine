import Foundation
import AetherLibavutil

/// One entry point of a Blu-ray clip's EP map: a video keyframe's presentation time on the clip's own
/// clock (45 kHz) and the source packet it starts at (192 bytes each in an `.m2ts`).
struct CLPIEntryPoint: Sendable, Equatable {
    let pts45k: UInt64
    let spn: UInt32

    /// The map's time precision, 45 kHz ticks: the fine field drops the low 9 bits of the 90 kHz PTS,
    /// so an entry's picture presents in `pts45k..<pts45k + precision45k`.
    static let precision45k: UInt64 = 256
}

/// Reads the EP map out of a clip information file (`BDMV/CLIPINF/NNNNN.clpi`).
enum CLPIParser {
    /// The primary video PID. A dual-layer Dolby Vision clip maps its enhancement layer on another PID;
    /// seeking only needs the base layer's keyframes.
    static let primaryVideoPID = 0x1011

    /// The primary video stream's entry points, ascending by time, or empty when the file is not a
    /// readable CLPI (the caller keeps seeking by timestamp then).
    ///
    /// Field layout as in libbluray's `clpi_access_point`: a coarse entry is 8 bytes
    /// (ref_to_EP_fine_id 18 bits, PTS_EP_coarse 14, SPN_EP_coarse 32), a fine entry 4 bytes
    /// (angle change 1 bit, I-end offset 3, PTS_EP_fine 11, SPN_EP_fine 17). The full time (45 kHz) is
    /// `((coarse & ~1) << 18) + (fine << 8)`, the full packet number `(coarse & ~0x1FFFF) + fine`.
    static func entryPoints(_ data: [UInt8]) -> [CLPIEntryPoint] {
        func be16(_ at: Int) -> Int { (Int(data[at]) << 8) | Int(data[at + 1]) }
        func be32(_ at: Int) -> UInt32 {
            (UInt32(data[at]) << 24) | (UInt32(data[at + 1]) << 16) | (UInt32(data[at + 2]) << 8) | UInt32(data[at + 3])
        }
        guard data.count >= 20, Array(data[0..<4]) == Array("HDMV".utf8) else { return [] }
        let cpiOffset = Int(be32(16))
        guard cpiOffset > 0, cpiOffset + 4 <= data.count else { return [] }
        let cpiLength = Int(be32(cpiOffset))
        let cpiEnd = cpiOffset + 4 + cpiLength
        guard cpiLength > 0, cpiEnd <= data.count else { return [] }
        // 12 reserved bits and the 4-bit CPI type; the EP map's own addresses count from after them.
        let epMapPos = cpiOffset + 4 + 2
        guard epMapPos + 2 <= cpiEnd else { return [] }
        let streamCount = Int(data[epMapPos + 1])
        var pos = epMapPos + 2
        var chosen: (pid: Int, coarse: Int, fine: Int, start: Int)?
        for _ in 0..<streamCount {
            guard pos + 12 <= cpiEnd else { return [] }
            // PID 16 bits, then 64 bits of reserved 10, stream type 4, coarse count 16, fine count 18
            // and the upper 16 bits of the stream table's start address, then its lower 16 bits.
            let pid = be16(pos)
            let packed = (UInt64(be32(pos + 2)) << 32) | UInt64(be32(pos + 6))
            let coarseCount = Int((packed >> 34) & 0xFFFF)
            let fineCount = Int((packed >> 16) & 0x3FFFF)
            let start = Int((UInt32(truncatingIfNeeded: packed & 0xFFFF) << 16) | UInt32(be16(pos + 10)))
            if chosen == nil || pid == primaryVideoPID || (chosen!.pid != primaryVideoPID && pid < chosen!.pid) {
                chosen = (pid, coarseCount, fineCount, start)
            }
            pos += 12
        }
        guard let table = chosen, table.coarse > 0, table.fine > 0 else { return [] }
        let streamPos = epMapPos + table.start
        guard streamPos + 4 <= cpiEnd else { return [] }
        let fineStart = Int(be32(streamPos))
        let coarsePos = streamPos + 4
        let finePos = streamPos + fineStart
        guard coarsePos + table.coarse * 8 <= cpiEnd, finePos + table.fine * 4 <= cpiEnd else { return [] }
        var fineEntries: [(pts: UInt64, spn: UInt32)] = []
        fineEntries.reserveCapacity(table.fine)
        for i in 0..<table.fine {
            let raw = be32(finePos + i * 4)
            fineEntries.append((UInt64((raw >> 17) & 0x7FF), raw & 0x1FFFF))
        }
        var out: [CLPIEntryPoint] = []
        out.reserveCapacity(table.fine)
        for i in 0..<table.coarse {
            let hi = be32(coarsePos + i * 8)
            let spnCoarse = be32(coarsePos + i * 8 + 4)
            let fineFrom = Int(hi >> 14)
            let ptsCoarse = UInt64(hi & 0x3FFF)
            let fineTo = i + 1 < table.coarse ? Int(be32(coarsePos + (i + 1) * 8) >> 14) : table.fine
            guard fineFrom <= fineTo else { continue }
            for j in fineFrom..<min(fineTo, table.fine) {
                let pts = ((ptsCoarse & ~1) << 18) + (fineEntries[j].pts << 8)
                let spn = (spnCoarse & ~0x1FFFF) + fineEntries[j].spn
                out.append(CLPIEntryPoint(pts45k: pts, spn: spn))
            }
        }
        return out.sorted { $0.pts45k < $1.pts45k }
    }
}

/// Where each keyframe of the selected Blu-ray title is, by its clips' EP maps.
///
/// A timestamp seek over a multi-clip title is a binary search over bytes by PTS, and the clips of a
/// title often each run their own clock from the same start (both clips of one title from 11.6 s), so
/// the search cannot tell the clips apart and lands in whichever it meets. The clip's own map does not
/// need to: the folded title time names the clip, the clip's `in_time` turns it back into that clip's
/// clock, and the entry gives the byte, so the seek is one byte reposition.
struct DiscSeekTable: Sendable {
    struct Clip: Sendable {
        /// The clip's first byte in the concatenated title stream.
        let concatByteStart: Int64
        /// Title time before the clip, from the playlist's play items (wrap-free).
        let cumulativeBeforeSec: Double
        /// The play item's `in_time`: where on the clip's own clock the title starts using it.
        let inTimeSec: Double
        /// The play item's `out_time`: where on the clip's own clock the title stops using it.
        let outTimeSec: Double
        let entries: [CLPIEntryPoint]
    }

    let clips: [Clip]

    /// The byte of the last keyframe at or before `seconds` on the demuxer's source axis (the title's
    /// origin plus title time, `ClipFold.titleOriginSeconds`), with the clip it is in and its time on
    /// that clip's clock.
    func keyframe(forSourceSeconds seconds: Double, titleOriginSec: Double) -> (offset: Int64, clip: Int, keyframeSec: Double)? {
        guard titleOriginSec.isFinite else { return nil }
        let titleTime = max(0, seconds - titleOriginSec)
        // Within the map's precision of a clip's start is that clip: its first keyframe usually presents at
        // the play item's `in_time`, and its entry may read up to that much earlier (`titleKeyframes`).
        let tolerance = Double(CLPIEntryPoint.precision45k) / discTickRate
        guard let k = clips.lastIndex(where: { $0.cumulativeBeforeSec <= titleTime + tolerance }) else { return nil }
        let clip = clips[k]
        guard !clip.entries.isEmpty else { return nil }
        // Rounded, not truncated: a plan boundary is an entry's own time (`titleKeyframes`), and the trip
        // through seconds must come back to that entry rather than one tick below it.
        let raw45k = UInt64(max(0, ((clip.inTimeSec + (titleTime - clip.cumulativeBeforeSec)) * discTickRate).rounded()))
        var lo = 0
        var hi = clip.entries.count - 1
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if clip.entries[mid].pts45k <= raw45k {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let entry = clip.entries[best]
        return (clip.concatByteStart + Int64(entry.spn) * 192, k, Double(entry.pts45k) / discTickRate)
    }

    /// Every keyframe the title plays, in title order: each clip's entries whose picture presents inside
    /// its play item's `in_time..<out_time`, placed on the demuxer's source axis in `timeBase` ticks (the
    /// inverse of `keyframe(forSourceSeconds:titleOriginSec:)`), with the byte it starts at.
    ///
    /// An entry's time is its picture's presentation time to the map's precision (5.7 ms) and never later,
    /// which is below any frame interval: the first sync sample at or after it is that picture, and no
    /// other picture presents within that precision of a play item's `in_time` or `out_time`. So a clip's
    /// first keyframe, which usually presents at `in_time` itself, is kept although its entry may read
    /// earlier, and the keyframe that presents at `out_time`, the next item's business, is not.
    func titleKeyframes(titleOriginSec: Double, timeBase: AVRational) -> [(pts: Int64, pos: Int64)] {
        guard titleOriginSec.isFinite, timeBase.num > 0, timeBase.den > 0 else { return [] }
        let ticksPerSecond = Double(timeBase.den) / Double(timeBase.num)
        var out: [(pts: Int64, pos: Int64)] = []
        out.reserveCapacity(clips.reduce(0) { $0 + $1.entries.count })
        for clip in clips {
            let in45k = UInt64((clip.inTimeSec * discTickRate).rounded())
            let out45k = UInt64((clip.outTimeSec * discTickRate).rounded())
            let precision = CLPIEntryPoint.precision45k
            for entry in clip.entries where entry.pts45k + precision > in45k && entry.pts45k + precision <= out45k {
                let titleSec = clip.cumulativeBeforeSec
                    + (Double(entry.pts45k) - Double(in45k)) / discTickRate
                out.append((pts: Int64(((titleOriginSec + titleSec) * ticksPerSecond).rounded()),
                            pos: clip.concatByteStart + Int64(entry.spn) * 192))
            }
        }
        return out
    }
}

extension DiscReader {
    /// Distinct clips whose CLPI a seek table reads at most.
    static let maxSeekTableClips = 256

    /// The selected title's seek table, from the CLPI of each clip the title resolved. `resolved` lists
    /// those clips with their play item index and their first byte in the concatenated stream. nil when
    /// the playlist carries no `in_time`s or `out_time`s or any clip has no readable EP map, so a title is
    /// either sought by its maps throughout or by timestamp throughout.
    static func buildSeekTable(title: DiscTitle,
                               resolved: [(item: Int, clip: String, byteStart: Int64)],
                               readCLPI: (String) -> [UInt8]?) -> DiscSeekTable? {
        guard let inTimes = title.bdClipInTimes, let outTimes = title.bdClipOutTimes,
              inTimes.count == outTimes.count, !resolved.isEmpty else { return nil }
        // One small file per distinct clip. A real title has a handful; a title past this is not worth a
        // request per clip before the first frame, and keeps seeking by timestamp.
        guard Set(resolved.map(\.clip)).count <= maxSeekTableClips else { return nil }
        let cumulativeBefore = title.bdClipCumulativeBeforeTicks ?? []
        var maps: [String: [CLPIEntryPoint]] = [:]
        var clips: [DiscSeekTable.Clip] = []
        for item in resolved {
            guard item.item < inTimes.count else { return nil }
            let entries = maps[item.clip] ?? (readCLPI(item.clip).map(CLPIParser.entryPoints) ?? [])
            maps[item.clip] = entries
            guard !entries.isEmpty else {
                EngineLog.emit("[disc] seek table: clip \(item.clip) has no readable EP map; seeking by timestamp", category: .demux)
                return nil
            }
            clips.append(.init(concatByteStart: item.byteStart,
                               cumulativeBeforeSec: item.item < cumulativeBefore.count
                                   ? Double(cumulativeBefore[item.item]) / discTickRate : 0,
                               inTimeSec: Double(inTimes[item.item]) / discTickRate,
                               outTimeSec: Double(outTimes[item.item]) / discTickRate,
                               entries: entries))
        }
        EngineLog.emit("[disc] seek table: \(clips.count) clip(s), entries=\(clips.map(\.entries.count))", category: .demux)
        return DiscSeekTable(clips: clips)
    }
}
