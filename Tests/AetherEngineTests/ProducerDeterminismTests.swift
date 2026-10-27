import AetherLibavcodec
import Foundation
import Testing
@testable import AetherEngine

/// HLS takes a presentation to be one continuous encode cut into segments, so segment N must be the same
/// bytes however playback reached it. The parts are held to that below the producer (`AudioSegmentRunsTests`,
/// `SpatialSegmentRunsTests`, `CopiedAudioTimingTests`); this holds the whole of it, a real session's
/// producer, gate and muxer: every segment a seeking session serves is the one a session playing straight
/// through served, per audio route. When one differs, the failure names the segment, the track and the
/// first sample that differs, and how.
@Suite("The producer's segments are the same however playback reached them", .serialized)
struct ProducerDeterminismTests {

    struct Route: CustomTestStringConvertible, Sendable {
        let clip: String
        var mode: AudioBridgeMode = .surroundCompat
        var delay: Double = 0
        var testDescription: String {
            clip + (["opus.mkv", "dts.mkv", "dts-drift.mkv", "truehd.mkv", "truehd-jitter.mkv"].contains(clip) ? " \(mode)" : "")
                + (delay == 0 ? "" : " delay \(delay)")
        }
    }

    /// Copied from Matroska (Cues), MPEG-TS (the uniform grid) and MP4; bridged from Opus, DTS and TrueHD
    /// in both bridge modes; an audio delay either way.
    static let routes: [Route] = [
        .init(clip: "aac.mkv"), .init(clip: "ac3.ts"), .init(clip: "eac3.mp4"), .init(clip: "flac.mkv"),
        .init(clip: "opus.mkv"), .init(clip: "dts.mkv"), .init(clip: "dts.mkv", mode: .lossless),
        .init(clip: "truehd.mkv"), .init(clip: "truehd.mkv", mode: .lossless),
        .init(clip: "truehd.mkv", delay: 0.15), .init(clip: "aac.mkv", delay: -0.15),
        // Timestamps up to 112 frames off their frames, drifting and snapping back (fetch-fixtures.sh).
        .init(clip: "dts-drift.mkv"), .init(clip: "truehd-jitter.mkv"),
    ]

    private static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/determinism").appendingPathComponent(name)
    }


    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.systemFileNumber] as? NSNumber }?.uint64Value
    }
}

/// The samples of a segment's fragments, read for a diff that says where two segments part.
