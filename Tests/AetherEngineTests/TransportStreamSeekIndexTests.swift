import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// A transport stream has no index of its own, and three things followed from treating it as if
/// libavformat had one: the cue prewarm ran a whole-file timestamp search for nothing, the uniform
/// plan anchored segment 0 on what that search left behind (or on a presentation time), and a seek
/// back into what was already played searched the whole file again. Each is checked here on a stream
/// libavformat demuxes itself (`TransportStreamFixture`).
@Suite("Transport stream seeking and planning without an index")
struct TransportStreamSeekIndexTests {

    private static func open(_ data: Data, reader: IOReader? = nil) throws -> Demuxer {
        let demuxer = Demuxer()
        try demuxer.open(reader: reader ?? DataIOReader(data: data))
        return demuxer
    }

    private static func drain(_ demuxer: Demuxer) throws {
        while let packet = try demuxer.readPacket() {
            var p: UnsafeMutablePointer<AVPacket>? = packet
            trackedPacketFree(&p)
        }
    }

    // MARK: - The cue prewarm

    @Test("only a Matroska source prewarms: a TS or MP4 seek loads no index")
    func prewarmOnlyWhereASeekLoadsAnIndex() throws {
        let ts = try Self.open(TransportStreamFixture.write([.init(frames: 50)]).data)
        defer { ts.close() }
        let mp4 = try Self.open(MP4SampleIndexTests.movText)
        defer { mp4.close() }
        let mkv = try Self.open(TransportStreamFixture.matroska)
        defer { mkv.close() }
        #expect(!HLSVideoEngine.cuePrewarmMayRun(ts))
        #expect(!HLSVideoEngine.cuePrewarmMayRun(mp4))
        #expect(HLSVideoEngine.cuePrewarmMayRun(mkv))
    }

    // MARK: - The uniform plan's anchor

    /// The first IRAP, on the plan's decode axis: the frame the cutter has to open segment 0 with.
    @Test("the uniform plan anchors on the first IRAP's decode time, from a clean or a mid-GOP start",
          arguments: [0, 4])
    func uniformPlanAnchorsOnTheFirstIRAP(startingAt start: Int) throws {
        let written = TransportStreamFixture.write([.init(frames: 50)], startingAt: start)
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        let video = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: video))
        let timeBase = stream.pointee.time_base
        let startTime = stream.pointee.start_time
        let scan = HLSVideoEngine.measureKeyframeSpacing(demuxer: demuxer, videoStreamIndex: video,
                                                         videoTimeBase: timeBase)
        let firstIRAP = try #require(written.keyframes.first)
        #expect(scan.firstKeyframe?.dts == firstIRAP.dts)
        #expect(scan.spacing == .measured(0.4))
        let anchor = HLSVideoEngine.uniformPlanAnchor(scan: scan, axis: .decode, provisional: startTime)
        #expect(anchor == firstIRAP.dts)
        // What it used to anchor on: the stream's first presentation time, which is above the IRAP's
        // decode time on a clean start and below the IRAP itself on a mid-GOP one.
        #expect(startTime != firstIRAP.dts)
    }

    @Test("without a scan the anchor is the provisional one")
    func anchorWithoutAScan() {
        #expect(HLSVideoEngine.uniformPlanAnchor(scan: nil, axis: .decode, provisional: 1234) == 1234)
        let none = HLSVideoEngine.KeyframeScan(spacing: .unknown, firstKeyframe: nil)
        #expect(HLSVideoEngine.uniformPlanAnchor(scan: none, axis: .decode, provisional: 1234) == 1234)
    }

    // MARK: - Recorded keyframes

    @Test("every video keyframe read goes into libavformat's index at its PES and decode time")
    func keyframesAreRecorded() throws {
        let written = TransportStreamFixture.write([.init(frames: 120)])
        let demuxer = try Self.open(written.data)
        defer { demuxer.close() }
        try Self.drain(demuxer)
        let recorded = demuxer.indexedKeyframeEntries(streamIndex: demuxer.videoStreamIndex)
        #expect(recorded.map(\.pos) == written.keyframes.map(\.pos))
        #expect(recorded.map(\.pts) == written.keyframes.map(\.dts))
    }

    @Test("a seek back into what was read reads a fraction of what the same seek reads cold")
    func backSeekIsBounded() throws {
        let written = TransportStreamFixture.write([.init(frames: 250)], padding: 60_000)
        func seekCost(afterReadingAll: Bool) throws -> (bytes: Int, landed: Int64?) {
            let reader = CountingDataReader(written.data)
            let demuxer = try Self.open(written.data, reader: reader)
            defer { demuxer.close() }
            if afterReadingAll { try Self.drain(demuxer) }
            let before = reader.bytesRead
            // Absolute source seconds: the stream starts at 10 s.
            #expect(demuxer.seek(to: 16.0))
            let cost = reader.bytesRead - before
            var landed: Int64?
            while landed == nil, let packet = try demuxer.readPacket() {
                if packet.pointee.stream_index == demuxer.videoStreamIndex { landed = packet.pointee.pts }
                var p: UnsafeMutablePointer<AVPacket>? = packet
                trackedPacketFree(&p)
            }
            return (cost, landed)
        }
        let cold = try seekCost(afterReadingAll: false)
        let warm = try seekCost(afterReadingAll: true)
        print("[TSSeekIndex] seek to 16 s: cold \(cold.bytes / 1024) KB read, after reading \(warm.bytes / 1024) KB "
              + "(\(written.data.count / 1_048_576) MB stream)")
        #expect(warm.bytes * 3 < cold.bytes)
        #expect(warm.landed == cold.landed)
    }
}
