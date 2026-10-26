import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Where a TrueHD stream's own clock reads zero on its timeline (`HLSVideoEngine.trueHDClockOffset`): counted from its
/// head where its timestamps allow that, the middle of what they allow where its first packet is stamped apart.
@Suite("TrueHD clock offset")
struct TrueHDClockOffsetTests {

    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/avsync").appendingPathComponent(name)
    }

    /// The offset read from `url`'s TrueHD stream, from `seconds` in (0: the start), counted from the file's start,
    /// and the file's start in frames at 48 kHz.
    static func offset(_ url: URL, from seconds: Double = 0) throws -> (offset: Int64?, readings: Int, start: Int64) {
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let index = try #require((0..<Int32(8)).first {
            demuxer.stream(at: $0)?.pointee.codecpar.pointee.codec_id == AV_CODEC_ID_TRUEHD
        })
        let stream = try #require(demuxer.stream(at: index))
        if seconds > 0 { _ = demuxer.seek(to: Int64(seconds / av_q2d(stream.pointee.time_base)), streamIndex: index, atOrBefore: true) }
        let read = HLSVideoEngine.trueHDClockOffset(audioStream: stream, demuxer: demuxer, streamIndex: index)
        return (read.offset, read.readings,
                av_rescale_q(stream.pointee.start_time, stream.pointee.time_base, AVRational(num: 1, den: 48_000)))
    }

    @Test("a first packet stamped apart from the rest leaves the offset to the rest")
    func firstPacketStampedApart() throws {
        let plain = Self.fixture("truehd.mkv"), apart = Self.fixture("truehd-firststamp.mkv")
        try #require(FileManager.default.fileExists(atPath: apart.path), "run Scripts/fetch-fixtures.sh")
        let base = try #require(try Self.offset(plain).offset)
        let moved = try #require(try Self.offset(apart).offset)
        // Every packet but the first is 5 ms (240 frames at 48 kHz) later; the timestamps allow an eight-frame window,
        // and the offset is its middle.
        #expect(abs(moved - base - 240) <= 4, "offset \(base) on the clip, \(moved) with every packet but the first 5 ms later")
    }

    @Test("timestamps a millisecond off either way leave the count from the head standing")
    func jitterKeepsTheCount() throws {
        let plain = Self.fixture("truehd.mkv"), jitter = Self.fixture("truehd-jitter.mkv")
        try #require(FileManager.default.fileExists(atPath: jitter.path), "run Scripts/fetch-fixtures.sh")
        #expect(try Self.offset(jitter).offset == Self.offset(plain).offset)
    }

    @Test("a second in, the timestamps alone allow the offset counted from the start")
    func timestampsAllowTheCount() throws {
        let plain = Self.fixture("truehd.mkv")
        try #require(FileManager.default.fileExists(atPath: plain.path), "run Scripts/fetch-fixtures.sh")
        let counted = try #require(try Self.offset(plain).offset)
        let later = try #require(try Self.offset(plain, from: 1).offset)
        #expect(abs(later - counted) <= 4)
    }

    /// Library titles' samples, not in the repository: `AE_TRUEHD_OFFSET_SAMPLES` names a directory of `.mka` files cut
    /// from one title's TrueHD track at several points with `ffmpeg [-ss T -t 4] -copyts -i <title> -map 0:a:0 -c copy`.
    @Test("a library title reads one offset from samples across it",
          .enabled(if: ProcessInfo.processInfo.environment["AE_TRUEHD_OFFSET_SAMPLES"] != nil))
    func librarySamplesAgree() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AE_TRUEHD_OFFSET_SAMPLES"]!)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "mka" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(files.count >= 2)
        // Each sample counts from its own start; on the title's timeline, and in the clock's wrap around the first.
        var offsets: [String: Int64] = [:]
        for file in files {
            let read = try Self.offset(file)
            if let offset = read.offset { offsets[file.lastPathComponent] = offset + read.start }
        }
        let first = try #require(offsets.values.first)
        offsets = offsets.mapValues { first + StreamClockPlacement.nearest($0 - first, modulus: 1 << 16) }
        print("[TrueHDClockOffset] \(offsets.sorted { $0.key < $1.key })")
        let values = Array(offsets.values)
        // The samples' timestamps are whole milliseconds, 24 frames either way; their medians agree to within that.
        #expect(values.count == files.count && values.max()! - values.min()! <= 24, "\(offsets)")
    }
}
