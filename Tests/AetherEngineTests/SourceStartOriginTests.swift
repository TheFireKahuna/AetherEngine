import Foundation
import Testing
@testable import AetherEngine

/// #112 round 10 (ijuniorfu, 0.9.19, remote Blu-ray ISO): a Blu-ray title's bytes cover source times
/// [startOrigin, startOrigin + duration], with startOrigin = 600 s on the reporter's disc, and its
/// format.start_time reads NOPTS while the video stream carries the start. The origin is resolved from
/// both, and the software clock's session zero is predicted from it (`SWClockAnchorPolicy`).
struct SourceStartOriginTests {

    // MARK: start-origin resolution from stream metadata

    @Test("origin prefers a valid format start time")
    func originFromFormatStart() {
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: 600_740_000, videoStreamStart: 54_000_000,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(abs(origin - 600.74) < 0.001)
    }

    @Test("origin falls back to the video stream start when the format start is NOPTS")
    func originFromVideoStream() {
        // The device log's exact metadata: format.start_time NOPTS, videoStart 54000000 in 1/90000.
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: Int64.min, videoStreamStart: 54_000_000,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(abs(origin - 600.0) < 0.001)
    }

    @Test("origin is zero when neither format nor video stream declare a start")
    func originZeroWhenUnknown() {
        let origin = Demuxer.sourceStartOrigin(
            formatStartUs: Int64.min, videoStreamStart: Int64.min,
            videoTimeBaseNum: 1, videoTimeBaseDen: 90_000)
        #expect(origin == 0)
    }
}
