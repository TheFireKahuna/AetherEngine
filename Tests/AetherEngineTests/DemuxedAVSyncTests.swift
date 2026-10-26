import AVFoundation
import Foundation
import Testing
@testable import AetherEngine

/// `AVSyncTests` for the demuxed shape (docs/demuxed-audio.md): the white frame read from the video rendition and
/// the click from the audio rendition, each placed at its own first `tfdt`, as AVPlayer synchronises renditions by
/// their media timestamps (RFC 8216 6.2.4).
@Suite("Audio against video, the audio a rendition of its own", .serialized)
struct DemuxedAVSyncTests {

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/avsync").appendingPathComponent(name)
    }

    @Test("the click plays on the white frame", .timeLimit(.minutes(2)), arguments: AVSyncTests.clips)
    func clickOnFrame(_ clip: AVSyncTests.Clip) async throws {
        try await check(clip, delay: 0)
    }

    @Test("an audio delay lands exactly", .timeLimit(.minutes(4)),
          arguments: ["aac.mp4", "eac3.mp4", "aac.mkv", "flac.mkv", "pcm.mkv", "truehd.mkv"], [-0.15, 0.2])
    func audioDelay(_ name: String, _ seconds: Double) async throws {
        try await check(AVSyncTests.Clip(name: name), delay: seconds)
    }

    private func check(_ clip: AVSyncTests.Clip, delay: Double) async throws {
        let url = Self.fixture(clip.name)
        try #require(FileManager.default.fileExists(atPath: url.path),
                     "run Scripts/fetch-fixtures.sh to generate Fixtures/avsync/")
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.audioDelaySeconds = delay
        // A planned master: these SDR clips with audio are served it, and so demuxed.
        engine.plannedPanelIsInHDRMode = false
        let playbackURL = try engine.start()
        defer { engine.stop() }
        try #require(engine.outputShape == .demuxed, "served \(engine.outputShape)")
        var comps = try #require(URLComponents(url: playbackURL.deletingLastPathComponent(), resolvingAgainstBaseURL: false))
        comps.query = nil
        let base = try #require(comps.url)
        let video = try Data(contentsOf: base.appendingPathComponent("init.mp4"))
            + Data(contentsOf: base.appendingPathComponent("seg0.mp4"))
        let audio = try Data(contentsOf: base.appendingPathComponent("audio-init.mp4"))
            + Data(contentsOf: base.appendingPathComponent("audio0.mp4"))
        let master = try String(contentsOf: playbackURL, encoding: .utf8)
        #expect(master.contains("URI=\"audio.m3u8\""), "the master names the audio rendition")

        let dir = FileManager.default.temporaryDirectory
        let videoFile = dir.appendingPathComponent("demuxed-video-\(UUID().uuidString).mp4")
        let audioFile = dir.appendingPathComponent("demuxed-audio-\(UUID().uuidString).mp4")
        try video.write(to: videoFile)
        try audio.write(to: audioFile)
        defer {
            try? FileManager.default.removeItem(at: videoFile)
            try? FileManager.default.removeItem(at: audioFile)
        }
        let measured = await withCheckedContinuation { (continuation: CheckedContinuation<(Double?, Double?), Never>) in
            Thread.detachNewThread {
                continuation.resume(returning: (AVSyncTests.measure(videoFile).0, AVSyncTests.measure(audioFile).1))
            }
        }
        let flash = try #require(measured.0, "no white frame decoded")
        let click = try #require(measured.1, "no click decoded")
        let videoOrigin = AVSyncTests.firstTfdtSeconds(video).video ?? 0
        let audioOrigin = try #require(AVSyncTests.firstTfdtSeconds(audio).audio)
        #expect(audioOrigin >= 0 && audioOrigin < 1e6, "the first audio fragment starts at \(audioOrigin) s")
        let offset = ((click + audioOrigin) - (flash + videoOrigin)) * 48_000
        #expect(abs(offset - delay * 48_000) <= clip.toleranceSamples,
                "audio is \(offset) samples off the picture, asked \(delay * 48_000)")

        // The joined view, the playlist that plays without a master: the same click on the same frame, read from one
        // file whose one moof carries both tracks.
        let joined = try Data(contentsOf: base.appendingPathComponent("muxed-init.mp4"))
            + Data(contentsOf: base.appendingPathComponent("muxed0.mp4"))
        let joinedFile = dir.appendingPathComponent("demuxed-joined-\(UUID().uuidString).mp4")
        try joined.write(to: joinedFile)
        defer { try? FileManager.default.removeItem(at: joinedFile) }
        let both = await withCheckedContinuation { (continuation: CheckedContinuation<(Double?, Double?), Never>) in
            Thread.detachNewThread { continuation.resume(returning: AVSyncTests.measure(joinedFile)) }
        }
        let joinedFlash = try #require(both.0, "no white frame decoded from the joined view")
        let joinedClick = try #require(both.1, "no click decoded from the joined view")
        let origins = AVSyncTests.firstTfdtSeconds(joined)
        let joinedOffset = ((joinedClick + (origins.audio ?? 0)) - (joinedFlash + (origins.video ?? 0))) * 48_000
        #expect(abs(joinedOffset - offset) <= 0.5, "the joined view plays \(joinedOffset) samples, the renditions \(offset)")
    }
}
