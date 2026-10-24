// Tests/AetherEngineTests/IFrameStillBuilderTests.swift
import Foundation
import Testing
@testable import AetherEngine

private func fixtureExists(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name)").path)
}

@Suite("I-frame SDR still builder", .serialized)
struct IFrameStillBuilderTests {
    private func sampleEntryType(_ initSegment: Data) -> String? {
        guard let stsd = IFrameTestBoxes.find(["moov", "trak", "mdia", "minf", "stbl", "stsd"], in: initSegment)
        else { return nil }
        let at = stsd.lowerBound + 12
        return String(bytes: initSegment[at..<(at + 4)], encoding: .isoLatin1)
    }

    private func builder(_ fx: IFrameFixture) throws -> IFrameStillBuilder {
        try #require(IFrameStillBuilder(
            decoder: FrameDecodeContext(streamParameters: fx.config.codecpar, timeBase: fx.config.timeBase),
            width: 800, height: 450))
    }

    @Test("the still keeps the display aspect, at most the requested width, even on both axes")
    func size() {
        #expect(IFrameStillBuilder.size(codedWidth: 3840, codedHeight: 2160, sarNum: 1, sarDen: 1)! == (800, 450))
        #expect(IFrameStillBuilder.size(codedWidth: 3840, codedHeight: 1608, sarNum: 0, sarDen: 0)! == (800, 336))
        // Anamorphic DVD: 720x576 at 64:45 displays 1024 wide.
        #expect(IFrameStillBuilder.size(codedWidth: 720, codedHeight: 576, sarNum: 64, sarDen: 45)! == (800, 450))
        #expect(IFrameStillBuilder.size(codedWidth: 320, codedHeight: 180, sarNum: 1, sarDen: 1)! == (320, 180))
        #expect(IFrameStillBuilder.size(codedWidth: 0, codedHeight: 180, sarNum: 1, sarDen: 1) == nil)
    }

    @Test("BANDWIDTH covers the largest still over the shortest segment, AVERAGE-BANDWIDTH sits below it")
    func bandwidth() {
        let declared = IFrameStillBuilder.bandwidth(shortestSegmentSeconds: 2.0)
        #expect(Double(declared) >= Double(IFrameStillBuilder.maxFrameBytes) * 8 / 2.0)
        #expect(IFrameStillBuilder.bandwidth(shortestSegmentSeconds: 0) > declared)
        #expect(IFrameStillBuilder.averageBandwidth(meanSegmentSeconds: 4) < IFrameStillBuilder.bandwidth(shortestSegmentSeconds: 4))
    }

    @Test("an HDR10 keyframe becomes an SDR HEVC Main10 still whose init states the declared codec",
          .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func hdrKeyframe() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let builder = try builder(fx)
        #expect(builder.codecs.hasPrefix("hvc1.2."))
        #expect(IFrameTestBoxes.topLevelTypes(builder.initSegment) == ["ftyp", "moov"])
        #expect(sampleEntryType(builder.initSegment) == "hvc1")
        #expect(IFrameTestBoxes.timescale(initSegment: builder.initSegment) == 90_000)
        let tkhd = try #require(IFrameTestBoxes.find(["moov", "trak", "tkhd"], in: builder.initSegment))
        #expect(IFrameTestBoxes.u32(builder.initSegment, tkhd.upperBound - 8) == 800 << 16)
        #expect(IFrameTestBoxes.u32(builder.initSegment, tkhd.upperBound - 4) == 450 << 16)

        let out = try #require(builder.build(payload: fx.keyframe, index: 3, startSeconds: 12, durationSeconds: 4))
        #expect(out.initSegment == builder.initSegment)
        #expect(IFrameTestBoxes.topLevelTypes(out.fragment) == ["moof", "mdat"])
        #expect(IFrameTestBoxes.sampleCount(fragment: out.fragment) == 1)
        #expect(IFrameTestBoxes.baseDecodeTime(fragment: out.fragment) == 1_080_000)
        #expect(out.fragment.count <= IFrameStillBuilder.maxFrameBytes)
    }

    @Test("a still asked for again is answered from memory without the payload",
          .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func repeatsFromMemory() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let builder = try builder(fx)
        let first = try #require(builder.build(payload: fx.keyframe, index: 5, startSeconds: 20, durationSeconds: 4))
        let again = try #require(builder.build(payload: Data([0, 0, 0, 1]), index: 5, startSeconds: 20,
                                               durationSeconds: 4))
        #expect(again.fragment == first.fragment)
    }

    @Test("a payload that does not decode builds nothing", .enabled(if: fixtureExists("hdr10-hevc.mp4")))
    func undecodable() throws {
        let fx = try IFrameFixture("hdr10-hevc.mp4", codecTag: "hvc1")
        defer { fx.demuxer.close() }
        let builder = try builder(fx)
        #expect(builder.build(payload: Data([0, 0, 0, 4, 1, 2, 3, 4]), index: 0, startSeconds: 0,
                              durationSeconds: 4) == nil)
    }
}
