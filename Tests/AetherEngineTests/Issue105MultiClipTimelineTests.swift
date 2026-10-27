import XCTest
@testable import AetherEngine

/// AE#105: a multi-clip Blu-ray title concatenates m2ts clips that each carry their own STC, so the raw
/// source PTS leaps at every clip boundary. The demuxer folds each clip onto one contiguous presentation
/// timeline by subtracting a per-clip offset, attributing packets to clips by byte position. These cover
/// the pure pieces of that transform; `BluRayEPMapSeekTests` reads packets through it.
final class Issue105MultiClipTimelineTests: XCTestCase {

    // MARK: - Byte-position -> clip attribution (ClipSpan.index)

    private func span(_ byteStart: Int64, cumBefore: Double = 0, predicted: Double = 0) -> ClipSpan {
        ClipSpan(concatByteStart: byteStart, cumulativeBeforeSec: cumBefore, predictedShiftSec: predicted)
    }

    func test_indexAttributesByByteBoundary() {
        let spans = [span(0), span(1_000), span(2_000)]
        XCTAssertEqual(ClipSpan.index(forPos: 0, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 999, in: spans, fallback: 0), 0)
        XCTAssertEqual(ClipSpan.index(forPos: 1_000, in: spans, fallback: 0), 1)   // boundary belongs to the new clip
        XCTAssertEqual(ClipSpan.index(forPos: 1_500, in: spans, fallback: 0), 1)
        XCTAssertEqual(ClipSpan.index(forPos: 2_000, in: spans, fallback: 0), 2)
        XCTAssertEqual(ClipSpan.index(forPos: 9_999, in: spans, fallback: 0), 2)
    }

    func test_indexNegativePosUsesFallback() {
        // A packet / index entry that reports no byte position keeps the last clip (reads are sequential).
        let spans = [span(0), span(1_000)]
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 1), 1)
        XCTAssertEqual(ClipSpan.index(forPos: -1, in: spans, fallback: 9), 1)   // clamped into range
    }

    func test_indexEmptyReturnsFallback() {
        XCTAssertEqual(ClipSpan.index(forPos: 500, in: [], fallback: 3), 3)
    }

    // MARK: - Playlist fold offset

    /// Real disc geometry from the #105 log: clip 0 raw base 4199.917 s, clip 1 raw base 96043 s (already
    /// past 2^33 ticks, i.e. FFmpeg-unwrapped past the 33-bit PTS wrap), clip 0 presentation 40.083 s.
    private let base0 = 4_199.917, clip1RawBase = 96_043.0, clip0DurationSec = 40.083

    /// The MPLS `in_time` is a 32-bit 45 kHz field: clip 1's (96043 s) is past 2^32 ticks and reads wrapped,
    /// so the playlist's own offset, `inTime[1] - inTime[0] - cumulativeBefore[1]`, is a whole wrap short.
    private var predictedSec: Double {
        let discTick = 45_000.0
        let inTime0 = UInt64(base0 * discTick)
        let inTime1Wrapped = UInt64((clip1RawBase * discTick).truncatingRemainder(dividingBy: 4_294_967_296))
        return (Double(inTime1Wrapped) - Double(inTime0) - (clip0DurationSec * discTick).rounded()) / discTick
    }

    /// Clip 1 is pulled back to continue right where clip 0 ended, the wrap the playlist cannot state read
    /// off the clip's own packets, instead of leaping to ~96043 s or being pushed further out.
    func test_playlistFoldYieldsContiguousTimelineAcrossTheWrap() {
        XCTAssertLessThan(predictedSec, 0)  // the bare prediction: wrong sign, a wrap short
        let origin = ClipFold.titleOriginSeconds(inTime0Sec: base0, nearRawSec: base0)
        let shift = ClipFold.playlistOffsetSeconds(predictedSec: predictedSec, rawSec: clip1RawBase,
                                                   titleOriginSec: origin, cumulativeBeforeSec: clip0DurationSec)
        XCTAssertEqual(shift, 91_803.0, accuracy: 0.1)
        XCTAssertEqual(clip1RawBase - shift, base0 + clip0DurationSec, accuracy: 0.01)
    }

    /// Any packet of the clip resolves it to the same offset: the first one read on a crossing, one a seek
    /// lands on mid-clip, or a lead audio packet a little before the play item's `in_time`.
    func test_playlistFoldDoesNotDependOnWhichPacketIsRead() {
        let origin = ClipFold.titleOriginSeconds(inTime0Sec: base0, nearRawSec: base0)
        let offsets = [clip1RawBase - 0.7, clip1RawBase, clip1RawBase + 1_800].map {
            ClipFold.playlistOffsetSeconds(predictedSec: predictedSec, rawSec: $0, titleOriginSec: origin,
                                           cumulativeBeforeSec: clip0DurationSec)
        }
        XCTAssertEqual(Set(offsets).count, 1)
    }

    /// The title's origin is play item 0's `in_time` in the clock span clip 0 is read in.
    func test_titleOriginFollowsClipZerosClockSpan() {
        XCTAssertEqual(ClipFold.titleOriginSeconds(inTime0Sec: 11.6, nearRawSec: 11.5), 11.6, accuracy: 1e-9)
        XCTAssertEqual(ClipFold.titleOriginSeconds(inTime0Sec: 11.6, nearRawSec: 11.5 + ClipFold.wrapSeconds),
                       11.6 + ClipFold.wrapSeconds, accuracy: 1e-6)
    }
}
