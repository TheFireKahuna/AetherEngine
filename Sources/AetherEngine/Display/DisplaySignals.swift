import Foundation

/// The pure half of the display-signal probe (`DisplaySignalProbe`): what it asks AVFoundation, how it reads the
/// answer, and how it writes a line. Kept apart from the tvOS observers so all of it is testable on any platform.
///
/// The question the probe exists for: which PUBLIC readings of the display (its HDR capability per mode, the mode it
/// is in now, the two halves of Match Content, a mode switch in progress) track what the display is really doing, and
/// which only look like they do. Every public reading is logged beside a private reference (`CADisplay`'s current
/// mode, PineBoard's two matching flags) so a normal viewing session answers that from the log.
enum DisplaySignals {

    /// One log line: a fixed prefix, then `key=value` pairs in the order given. A value with a space, an `=` or a
    /// quote is quoted, so a line splits on spaces back into exactly its pairs.
    static func line(_ head: String, _ fields: KeyValuePairs<String, String>) -> String {
        line(head, Array(fields.map { ($0.key, $0.value) }))
    }

    static func line(_ head: String, _ fields: [(String, String)]) -> String {
        var out = "[DisplaySignals] " + head
        for (key, value) in fields {
            out += " " + key + "=" + quoted(value)
        }
        return out
    }

    static func quoted(_ value: String) -> String {
        let flat = value.replacingOccurrences(of: "\n", with: " ")
        guard flat.isEmpty || flat.contains(where: { $0 == " " || $0 == "=" || $0 == "\"" }) else { return flat }
        return "\"" + flat.replacingOccurrences(of: "\"", with: "'") + "\""
    }

    static func yn(_ value: Bool) -> String { value ? "y" : "n" }

    /// A private object's description, flattened and cut so one line stays one line.
    static func brief(_ value: Any?, limit: Int = 160) -> String {
        guard let value else { return "nil" }
        let text = String(describing: value)
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    // MARK: - Refresh cadence

    /// The output refresh rate, from a display link's tick timestamps. The median interval rather than the mean,
    /// so a dropped tick (a doubled interval) or a late first callback does not move it.
    struct Cadence: Equatable {
        let hz: Double
        /// Spread of the intervals around the median, in milliseconds (median absolute deviation).
        let jitterMs: Double
        let intervals: Int
    }

    static func cadence(timestamps: [Double]) -> Cadence? {
        guard timestamps.count >= 3 else { return nil }
        let intervals = zip(timestamps.dropFirst(), timestamps).map { $0 - $1 }.filter { $0 > 0 }
        guard intervals.count >= 2 else { return nil }
        let median = Self.median(intervals)
        guard median > 0 else { return nil }
        let deviation = Self.median(intervals.map { abs($0 - median) })
        return Cadence(hz: 1 / median, jitterMs: deviation * 1000, intervals: intervals.count)
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    // MARK: - Variant oracle

    /// One HLS variant the oracle offers. Identical apart from what a display decides on: codec and video range.
    enum Candidate: String, CaseIterable, Sendable {
        /// Dolby Vision Profile 5: no backward-compatible base layer, so a player may only pick it for a display
        /// that presents Dolby Vision. The single-variant P5 master is what fails with -11868 on other panels.
        case dolbyVision5 = "dv5"
        case hdr10 = "hdr10"
        case hlg = "hlg"
        case sdr = "sdr"

        var codecs: String {
            switch self {
            case .dolbyVision5: return "dvh1.05.06"
            case .hdr10, .hlg: return "hvc1.2.4.L153.B0"
            case .sdr: return "hvc1.1.6.L153.B0"
            }
        }

        var videoRange: String {
            switch self {
            case .dolbyVision5, .hdr10: return "PQ"
            case .hlg: return "HLG"
            case .sdr: return "SDR"
            }
        }

        var playlistName: String { rawValue + ".m3u8" }
    }

    /// An offer. Each asking ladder lists its candidate first and SDR after it, so it reads the same whichever rule
    /// the player starts by: listed order (the candidate is first) or its own ranking (an eligible HDR variant ranks
    /// above SDR, measured on macOS 27, where the control below starts on HDR10). The control says which rule this
    /// player follows, so a change of rule shows up in the log rather than as a silently different reading.
    ///
    /// Only the FIRST media playlist is a pick: once its segment is refused the player fails over to the next
    /// variant (macOS 27 asks for the SDR playlist next), and that request is failover, not a choice.
    struct Ladder: Equatable, Sendable {
        let name: String
        let variants: [Candidate]

        /// The one candidate this ladder asks about, nil for the control.
        let asks: Candidate?

        static let all: [Ladder] = [
            Ladder(name: "control", variants: [.sdr, .hdr10], asks: nil),
            Ladder(name: "dv5>sdr", variants: [.dolbyVision5, .sdr], asks: .dolbyVision5),
            Ladder(name: "hdr10>sdr", variants: [.hdr10, .sdr], asks: .hdr10),
            Ladder(name: "hlg>sdr", variants: [.hlg, .sdr], asks: .hlg),
            Ladder(name: "dv5-only", variants: [.dolbyVision5], asks: .dolbyVision5),
        ]
    }

    static func masterPlaylist(_ ladder: Ladder) -> String {
        var text = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n"
        for variant in ladder.variants {
            text += "#EXT-X-STREAM-INF:BANDWIDTH=20000000,AVERAGE-BANDWIDTH=15000000,"
                + "CODECS=\"\(variant.codecs)\",RESOLUTION=3840x2160,FRAME-RATE=23.976,"
                + "VIDEO-RANGE=\(variant.videoRange)\n"
                + variant.playlistName + "\n"
        }
        return text
    }

    /// A media playlist whose segments are never served: the oracle has its answer from the request for this file.
    static func mediaPlaylist(_ variant: Candidate) -> String {
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:2\n#EXT-X-PLAYLIST-TYPE:VOD\n"
            + "#EXT-X-MAP:URI=\"\(variant.rawValue)-init.mp4\"\n#EXTINF:2.0,\n\(variant.rawValue)-0.m4s\n#EXT-X-ENDLIST\n"
    }

    /// What a request path asks for.
    enum Requested: Equatable {
        case master
        case mediaPlaylist(Candidate)
        case media(String)
        case unknown(String)
    }

    static func requested(path: String) -> Requested {
        let file = (path as NSString).lastPathComponent
        if file == "master.m3u8" { return .master }
        if let variant = Candidate.allCases.first(where: { $0.playlistName == file }) { return .mediaPlaylist(variant) }
        if file.hasSuffix(".mp4") || file.hasSuffix(".m4s") { return .media(file) }
        return .unknown(file)
    }

    /// What one ladder's run says about its candidate.
    enum Verdict: String, Equatable {
        /// The player started on the asked-about variant (or, alone, loaded it).
        case picked
        /// It started on the fallback instead (or, alone, failed without a pick).
        case passedOver = "passed-over"
        /// Nothing to read: no media playlist was requested and nothing failed, or the control ladder.
        case unknown
    }

    static func verdict(_ ladder: Ladder, firstPick: Candidate?, failed: Bool) -> Verdict {
        guard let asks = ladder.asks else { return .unknown }
        if let firstPick { return firstPick == asks ? .picked : .passedOver }
        return failed ? .passedOver : .unknown
    }

    /// What the control ladder (SDR listed before HDR10) says the player starts by: "order" when it took SDR,
    /// "ranking" when it took HDR10 anyway, nil when it picked nothing.
    static func startRule(controlPick: Candidate?) -> String? {
        controlPick.map { $0 == .sdr ? "order" : "ranking" }
    }
}
