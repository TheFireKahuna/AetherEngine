import AVFoundation
import Foundation

/// The source time each VOD segment states about itself, in band, so the engine reads where AVPlayer put
/// it instead of predicting it (docs/segment-axis.md).
///
/// AVPlayer places the first segment of every run it opens at that segment's playlist position whatever
/// `tfdt` it carries, and a segment's content need not begin at its advertised start (a Matroska cue that
/// names an ordinary frame, a uniform grid over a source with no index). So the offset between AVPlayer's
/// item clock and the source is a property of each run, and of what AVPlayer chose to do with it: open a
/// run, append the segment to the one it is playing, rebuild its timeline. None of that can be read
/// from the outside. Each segment therefore opens with an `emsg` box (ISO/IEC 23009-1 event message,
/// version 1) carrying ID3 timed metadata in Apple's scheme, presentation time on the segment's first
/// picture, whose `TXXX` frame states the segment's index and that picture's source time.
/// `AVPlayerItemMetadataOutput` hands it back stamped with the item time AVPlayer played that picture at,
/// so the difference is the axis, measured.
///
/// Measured with `play --picture-probe` against a picture that states its own source time: the reading
/// equalled the picture on a late open (+0.225), an early re-aim (-9.000), a seek burst, and a re-aimed
/// segment AVPlayer appended to the run it was playing (-9.000, where the prediction said -12.167). The
/// output delivers about four seconds ahead with `advanceIntervalForDelegateInvocation` 5, and the segment
/// a seek or the mount lands in at the landing itself, provided it is attached when the item is created.
/// On the Apple TV (tvOS 27.2, 4K HEVC Dolby Vision), every segment of every run and every landing.
enum InBandClock {
    /// The scheme Apple's clients require for ID3 in an `emsg` (Apple's answer for fMP4 HLS; AOMedia's
    /// own is `https://aomedia.org/emsg/ID3`, which they do not read).
    static let scheme = "https://developer.apple.com/streaming/emsg-id3"
    /// The `TXXX` description the stamp is carried under.
    static let owner = "aether"

    /// What a segment states: its index in the plan and the source time of its first picture.
    struct Stamp: Equatable, Sendable {
        let segmentIndex: Int
        let sourceSeconds: Double

        var text: String { String(format: "idx=%d src=%.6f", segmentIndex, sourceSeconds) }

        init(segmentIndex: Int, sourceSeconds: Double) {
            self.segmentIndex = segmentIndex
            self.sourceSeconds = sourceSeconds
        }

        init?(text: String) {
            var index: Int?
            var source: Double?
            for field in text.split(separator: " ") {
                if field.hasPrefix("idx=") { index = Int(field.dropFirst(4)) }
                if field.hasPrefix("src=") { source = Double(field.dropFirst(4)) }
            }
            guard let index, let source, source.isFinite else { return nil }
            self.init(segmentIndex: index, sourceSeconds: source)
        }
    }

    /// The `emsg` that opens a segment: version 1, `presentationTime` in `timescale` units on the
    /// track's own timeline (the first picture's `tfdt`-axis time), no duration, the stamp as an ID3v2.4
    /// `TXXX` frame in UTF-8.
    static func eventMessage(_ stamp: Stamp, presentationTime: Int64, timescale: UInt32) -> Data {
        let frameData = [UInt8(0x03)] + Array(owner.utf8) + [0] + Array(stamp.text.utf8)
        let frame = Array("TXXX".utf8) + syncsafe(frameData.count) + [0, 0] + frameData
        let id3 = Array("ID3".utf8) + [4, 0, 0] + syncsafe(frame.count) + frame
        var payload: [UInt8] = [1, 0, 0, 0]
        payload += be32(timescale) + be64(UInt64(max(0, presentationTime))) + be32(0xFFFF_FFFF)
            + be32(UInt32(truncatingIfNeeded: stamp.segmentIndex))
        payload += Array(scheme.utf8) + [0] + [0] + id3
        return Data(be32(UInt32(8 + payload.count)) + Array("emsg".utf8) + payload)
    }

    /// The ID3 user-text items of a group `AVPlayerItemMetadataOutput` delivered, which a stamp is carried in, with the
    /// item time it places the group at. Nothing changes an item once the output has delivered it, and they are only
    /// read, so they move between threads as they are.
    struct Candidates: @unchecked Sendable {
        let itemSeconds: Double
        let items: [AVMetadataItem]

        /// Nil for a group with no item time or no user-text item.
        init?(_ group: AVTimedMetadataGroup) {
            let start = group.timeRange.start
            let items = group.items.filter { $0.identifier == .id3MetadataUserText }
            guard start.isNumeric, !items.isEmpty else { return nil }
            itemSeconds = start.seconds
            self.items = items
        }

        /// The stamps the items hold, read now: nil when an item's text is not loaded yet (``stamps()`` loads it). An item
        /// the output delivers arrives loaded.
        func loadedStamps() -> [Stamp]? {
            var stamps: [Stamp] = []
            for item in items {
                guard case .loaded(let text) = item.status(of: .stringValue) else { return nil }
                if let text, let stamp = Stamp(text: text) { stamps.append(stamp) }
            }
            return stamps
        }

        /// The stamps the items hold, their text loaded.
        func stamps() async -> [Stamp] {
            var stamps: [Stamp] = []
            for item in items {
                guard let text = try? await item.load(.stringValue), let stamp = Stamp(text: text) else { continue }
                stamps.append(stamp)
            }
            return stamps
        }
    }

    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
    }

    private static func be64(_ v: UInt64) -> [UInt8] { be32(UInt32(v >> 32)) + be32(UInt32(v & 0xFFFF_FFFF)) }

    private static func syncsafe(_ v: Int) -> [UInt8] {
        [UInt8(v >> 21 & 0x7F), UInt8(v >> 14 & 0x7F), UInt8(v >> 7 & 0x7F), UInt8(v & 0x7F)]
    }
}
