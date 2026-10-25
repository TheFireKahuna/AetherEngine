import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// Every VOD segment opens with the in-band clock (`InBandClock`): an `emsg` in Apple's ID3 scheme,
/// timed on the segment's first picture, stating the segment's index and that picture's source time.
@Suite("In-band segment clock")
struct InBandClockTests {

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/avsync").appendingPathComponent(name)
    }

    @Test("a stamp reads back as it was written")
    func stampRoundTrip() throws {
        let stamp = InBandClock.Stamp(segmentIndex: 3132, sourceSeconds: 6263.924)
        #expect(InBandClock.Stamp(text: stamp.text) == stamp)
        #expect(InBandClock.Stamp(text: "idx=4") == nil)
        #expect(InBandClock.Stamp(text: "src=1.0") == nil)
    }

    @Test("the box is an emsg v1 in Apple's ID3 scheme, timed on the picture it is given")
    func boxLayout() throws {
        let box = [UInt8](InBandClock.eventMessage(.init(segmentIndex: 7, sourceSeconds: 12.5),
                                                   presentationTime: 90_000, timescale: 1000))
        #expect(Int(UInt32(box[0]) << 24 | UInt32(box[1]) << 16 | UInt32(box[2]) << 8 | UInt32(box[3])) == box.count)
        #expect(String(decoding: box[4..<8], as: UTF8.self) == "emsg")
        #expect(box[8] == 1, "version 1: an absolute presentation time")
        let timescale = UInt32(box[12]) << 24 | UInt32(box[13]) << 16 | UInt32(box[14]) << 8 | UInt32(box[15])
        let time = box[16..<24].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        #expect(timescale == 1000 && time == 90_000)
        let body = String(decoding: box[32...], as: UTF8.self)
        #expect(body.hasPrefix(InBandClock.scheme))
        #expect(body.contains("ID3") && body.contains("TXXX") && body.contains("idx=7 src=12.500000"))
    }

    /// The segment AVPlayer is handed opens with the clock, and its presentation time is the first
    /// picture's `tfdt`, the time AVPlayer reports the stamp at.
    @Test("a served VOD segment opens with its clock, on its first picture", .timeLimit(.minutes(1)))
    func servedSegmentOpensWithItsClock() async throws {
        let url = Self.fixture("aac.mkv")
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/avsync/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        let playbackURL = try engine.start()
        defer { engine.stop() }
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)
        let segment = [UInt8](try Data(contentsOf: base.appendingPathComponent("seg0.mp4")))
        #expect(String(decoding: segment[4..<8], as: UTF8.self) == "emsg")
        let emsgSize = Int(UInt32(segment[0]) << 24 | UInt32(segment[1]) << 16 | UInt32(segment[2]) << 8 | UInt32(segment[3]))
        #expect(String(decoding: segment[(emsgSize + 4)..<(emsgSize + 8)], as: UTF8.self) == "moof")
        let text = String(decoding: segment[0..<emsgSize], as: UTF8.self)
        let stampText = try #require(text.range(of: "idx=").map { String(text[$0.lowerBound...]) })
        let stamp = try #require(InBandClock.Stamp(text: stampText))
        #expect(stamp.segmentIndex == 0)
        // The video tfdt of the first fragment, against the emsg's presentation time.
        let presentation = segment[16..<24].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        let origins = AVSyncTests.firstTfdtSeconds(Data(try Data(contentsOf: base.appendingPathComponent("init.mp4"))) + Data(segment))
        let timescale = Double(UInt32(segment[12]) << 24 | UInt32(segment[13]) << 16 | UInt32(segment[14]) << 8 | UInt32(segment[15]))
        #expect(abs(Double(presentation) / timescale - (origins.video ?? -1)) < 0.05)
    }
}
