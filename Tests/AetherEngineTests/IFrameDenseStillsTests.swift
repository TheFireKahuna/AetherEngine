import Foundation
import Testing
@testable import AetherEngine

/// A source with no keyframe list (a transport stream) lists one SDR still a second, each the picture at its
/// own time: the packets from the keyframe at or before it, decoded to that picture and encoded as an intra
/// frame (`IFrameRenditionEligibility.Timeline.stills`).
@Suite("Dense I-frame stills for a source without a keyframe list", .serialized)
struct IFrameDenseStillsTests {

    /// Six seconds of the fixture's H.264, whose GOPs carry reordered pictures, written to a file.
    private static func writeTransportStream() throws -> (url: URL, written: TransportStreamFixture.Written) {
        let written = TransportStreamFixture.write([.init(frames: 150)], padding: 2_000)
        let url = FileManager.default.temporaryDirectory.appending(path: "dense-\(UUID().uuidString).ts")
        try written.data.write(to: url)
        return (url, written)
    }

    @Test("a picture run opens on the keyframe at or before the time and ends past the first picture at it")
    func pictureRunReachesItsPicture() throws {
        let (url, written) = try Self.writeTransportStream()
        defer { try? FileManager.default.removeItem(at: url) }
        let session = Demuxer()
        try session.open(url: url)
        defer { session.close() }
        let reader = IFrameKeyframeReader(
            resolveIndex: { .notIndexed("transport stream") }, position: { _ in nil },
            open: { dem in
                let source = try #require(AetherEngine.indexReader(url: url, headers: [:], label: "iframe"))
                try dem.open(reader: source, profile: .iFrameSideDemuxer)
                return { source.close() }
            })
        defer { reader.interrupt(); reader.close() }
        let presentations = written.frames.map(\.pts).sorted()
        // Out of order, and between pictures as well as on them.
        for target: Int64 in [900_000 + 3 * 90_000 + 1_000, 900_000 + 45_000, 900_000 + 5 * 90_000] {
            let run = try #require(reader.pictureRun(atPts: target), "no run at \(target)")
            let expected = try #require(presentations.first { $0 >= target })
            #expect(run.targetPts == expected)
            #expect(run.packets.first?.isKeyframe == true)
            let opening = try #require(run.packets.first)
            #expect(opening.dts <= target)
            // It opens on the last keyframe at or before the time, not on an earlier one.
            let keyframes = written.keyframes.map(\.dts)
            #expect(opening.dts == keyframes.last { $0 <= target })
            #expect(run.packets.contains { $0.pts == expected })
            // No packet left unread could present between the target and the picture chosen.
            #expect((run.packets.last?.dts ?? .min) >= expected || run.packets.count == 640)
        }
    }

    @Test("a transport stream session serves one SDR still a second, alone, each at its own time",
          .timeLimit(.minutes(2)))
    func sessionServesDenseStills() throws {
        let (url, _) = try Self.writeTransportStream()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        engine.requestIFramePlaylist()
        _ = try engine.start()
        defer { engine.stop() }
        try #require(!engine.planBoundariesClaimRandomAccess, "a transport stream plans on the uniform grid")
        #expect(engine.iFrameRenditionVerdict == .served(.stills))
        let prov = try #require(engine.provider)
        guard case .stills(let width, _, let codecs, _, _, .sdr) = prov.iFrameRenditionFormat else {
            Issue.record("expected SDR stills, got \(String(describing: prov.iFrameRenditionFormat))")
            return
        }
        #expect(prov.iFrameCompanionFormat == nil)
        #expect(codecs.hasPrefix("hvc1."))
        let master = HLSLocalServer.buildMasterPlaylistText(provider: prov)
        #expect(master.contains("VIDEO-RANGE=SDR,CODECS=\"\(codecs)\",RESOLUTION=\(width)x"))
        #expect(master.contains("URI=\"iframe.m3u8\""))
        #expect(!master.contains("iframe_sdr.m3u8"))

        let timeline = try #require(prov.iFrameTimeline)
        #expect(timeline.count == 6)
        #expect(timeline.dropLast().allSatisfy { abs($0.durationSeconds - 1) < 0.001 })
        let initSegment = try #require(prov.iFrameInitSegment())
        let timescale = Double(try #require(IFrameTestBoxes.timescale(initSegment: initSegment)))
        for index in [timeline.count - 1, 0, 3] {
            let fragment = try #require(prov.iFrameSegment(at: index))
            #expect(IFrameTestBoxes.sampleCount(fragment: fragment) == 1)
            let tfdt = Double(try #require(IFrameTestBoxes.baseDecodeTime(fragment: fragment)))
            #expect(abs(tfdt / timescale - timeline[index].startSeconds) < 0.002)
        }
    }

    @Test("a scrub still past the resident window is the picture read off the source, rendition or not",
          .timeLimit(.minutes(2)))
    func sourceStillWithoutTheRendition() throws {
        let (url, _) = try Self.writeTransportStream()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = HLSVideoEngine(url: url, dvModeAvailable: false)
        _ = try engine.start()
        defer { engine.stop() }
        #expect(engine.iFrameRenditionVerdict == .absent(.notRequested))
        #expect(engine.sourceStillTimeline == .stills)
        #expect(engine.yieldsStills)
        for seconds in [4.5, 0.25, 2.0] {
            let image = try #require(engine.sourceStill(atSeconds: seconds, maxWidth: 320), "no still at \(seconds)")
            #expect(image.width <= 320 && image.width > 0)
        }
    }
}
