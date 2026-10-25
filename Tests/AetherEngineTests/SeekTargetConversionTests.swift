import Foundation
import Testing
import AetherLibavutil
@testable import AetherEngine

/// Audit DMX-113, BIT-105: every seconds-based reposition becomes integer ticks in the Demuxer,
/// and `Int64(_:)` traps on NaN, infinity and anything past `Int64`. Host values (a 0/0 scrub fraction,
/// `.infinity` as "resume at the end") reached it.
@Suite("Seek targets that do not fit a tick count fail instead of trapping")
struct SeekTargetConversionTests {

    private static let microseconds = AVRational(num: 1, den: AV_TIME_BASE)

    private static func fixture() -> Data {
        Data(base64Encoded: AtmosDetectionProbeIntegrationTests.videoOnlyBase64,
             options: .ignoreUnknownCharacters) ?? Data()
    }

    // MARK: - The conversion

    @Test("Non-finite and out-of-range seconds convert to nil", arguments: [
        Double.nan, .infinity, -.infinity, 1e300, 4.7e12, -4.7e12,
    ])
    func unconvertible(seconds: Double) {
        #expect(Demuxer.ticks(forSeconds: seconds, timeBase: Self.microseconds) == nil)
    }

    @Test("Ordinary seconds convert exactly as before")
    func convertible() {
        #expect(Demuxer.ticks(forSeconds: 1.5, timeBase: Self.microseconds) == 1_500_000)
        #expect(Demuxer.ticks(forSeconds: -2, timeBase: Self.microseconds) == -2_000_000)
        #expect(Demuxer.ticks(forSeconds: 7508.9, timeBase: AVRational(num: 1, den: 90_000))
                == Int64(7508.9 * 90_000.0 / 1.0))
        #expect(Demuxer.ticks(forSeconds: 1, timeBase: AVRational(num: 0, den: 1)) == nil)
    }

    // MARK: - The Demuxer's seeks

    @Test("seek(to:) refuses NaN, infinity and a target past Int64", arguments: [
        Double.nan, .infinity, 1e300,
    ])
    func demuxerSeekRefuses(seconds: Double) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.fixture()), formatHint: "mp4")
        #expect(demuxer.seek(to: seconds) == false)
        #expect(demuxer.seek(to: 0))
    }

    @Test("seekBounded refuses NaN, infinity and a target past Int64", arguments: [
        Double.nan, .infinity, 1e300,
    ])
    func demuxerSeekBoundedRefuses(seconds: Double) throws {
        let demuxer = Demuxer()
        defer { demuxer.close() }
        try demuxer.open(reader: DataIOReader(data: Self.fixture()), formatHint: "mp4")
        #expect(demuxer.seekBounded(to: seconds, timeout: 2) == false)
    }

    // MARK: - FrameExtractor boundary

    @Test("A thumbnail at a non-finite or negative time is nil", arguments: [
        Double.infinity, .nan, -1,
    ])
    func thumbnailRefuses(seconds: Double) async {
        let extractor = FrameExtractor(reader: DataIOReader(data: Self.fixture()), formatHint: "mp4")
        #expect(await extractor.thumbnail(at: seconds) == nil)
        #expect(await extractor.snapshot(at: seconds) == nil)
        await extractor.shutdown()
    }

    @Test("A thumbnail far past the end is clamped to the source, not a trap")
    func thumbnailFarPastTheEnd() async {
        let extractor = FrameExtractor(reader: DataIOReader(data: Self.fixture()), formatHint: "mp4")
        _ = await extractor.thumbnail(at: 1e300)
        _ = await extractor.snapshot(at: 1e300)
        await extractor.shutdown()
    }
}
