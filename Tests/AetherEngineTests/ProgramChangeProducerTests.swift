import Foundation
import Testing
import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
@testable import AetherEngine

/// The real producer over a transport stream whose PMT changes: a live ad on its own PIDs gets a
/// fresh init and the programme coming back gets the open's again, a VOD recording crossing a
/// programme boundary plays on through it, and a change the one init cannot describe ends the epoch
/// for the software path.
@Suite("Producer across a PMT change")
struct ProgramChangeProducerTests {

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var exit: HLSSegmentProducer.PumpExitReason?
        func finish(_ reason: HLSSegmentProducer.PumpExitReason) { lock.withLock { exit = reason } }
        var reason: HLSSegmentProducer.PumpExitReason? { lock.withLock { exit } }
    }

    /// Runs a producer over `data` to its end and hands back its cache and exit; `startingAt` seeks
    /// the demuxer there first, as a restart after a seek does.
    private static func produce(_ data: Data, live: Bool, withAudio: Bool = false, startingAt: Double? = nil)
        async throws -> (cache: SegmentCache, reason: HLSSegmentProducer.PumpExitReason?) {
        let demuxer = Demuxer()
        try demuxer.open(reader: DataIOReader(data: data), formatHint: "mpegts")
        defer { demuxer.close() }
        if let startingAt { #expect(demuxer.seek(to: startingAt)) }
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        var audio: HLSSegmentProducer.AudioConfig?
        if withAudio, let a = demuxer.stream(at: demuxer.audioStreamIndex) {
            audio = .init(codecpar: UnsafePointer(a.pointee.codecpar), timeBase: a.pointee.time_base,
                          sourceStreamIndex: demuxer.audioStreamIndex, inputTimeBase: a.pointee.time_base,
                          sourceTimeBase: a.pointee.time_base, bridge: nil, stripAacAdts: false)
        }
        let cache = SegmentCache(forwardWindow: 64, backwardWindow: 64)
        let producer = try HLSSegmentProducer(
            demuxer: demuxer, videoStreamIndex: index,
            video: .init(codecpar: UnsafePointer(stream.pointee.codecpar), timeBase: stream.pointee.time_base,
                         codecTagOverride: "avc1"),
            audio: audio, cache: cache, targetSegmentDurationSeconds: 1, videoFallbackDurationPts: 3600,
            desiredFirstVideoTfdtPts: 0,
            // VOD: one-second plan slots on the source's 90 kHz axis, from where the fixture starts.
            segmentBoundaries: live ? [] : (0..<8).map { 900_000 + Int64($0) * 90_000 },
            planAnchorVideoPts: live ? 0 : 900_000, isLive: live, bufferAheadSegments: 64)
        let result = Result()
        producer.onPumpFinished = { result.finish($0) }
        producer.onLiveTimelineRebase = { _, _ in }
        producer.onLiveSegmentFinalized = { _, _, _, _ in }
        producer.start()
        defer { producer.stop(); _ = producer.waitForFinish(timeout: 2) }
        try await waitFor { result.reason != nil }
        return (cache, result.reason)
    }

    private static func initVersions(_ cache: SegmentCache) -> [Int] {
        var versions: [Int] = []
        for k in 0..<cache.count where versions.last != cache.initVersionID(forSegment: k) {
            versions.append(cache.initVersionID(forSegment: k))
        }
        return versions
    }

    @Test("a live ad on its own PIDs gets its own init, and the programme coming back gets one again",
          .timeLimit(.minutes(1)))
    func liveAdAndReturn() async throws {
        let written = TransportStreamFixture.write([
            .init(frames: 75), .init(frames: 75, videoPID: 0x1021, pmtVersion: 1), .init(frames: 75, pmtVersion: 2),
        ])
        let (cache, reason) = try await Self.produce(written.data, live: true)
        defer { cache.close() }
        #expect(reason?.description == "eof")
        // The programme's init, the ad's, the programme's again.
        #expect(Self.initVersions(cache).count == 3)
        #expect(cache.count >= 6)
    }

    @Test("a VOD recording plays on through a programme boundary on the same codec", .timeLimit(.minutes(1)))
    func vodContinuesAcrossTheBoundary() async throws {
        let written = TransportStreamFixture.write([
            .init(frames: 75), .init(frames: 75, videoPID: 0x1021, pmtVersion: 1),
        ])
        let (cache, reason) = try await Self.produce(written.data, live: false)
        defer { cache.close() }
        #expect(reason?.description == "eof")
        // Six seconds of video in one-second plan slots: content past the boundary was cut too.
        #expect(cache.count >= 5)
        #expect(Self.initVersions(cache).count == 1)
    }

    @Test("a VOD video codec change at the boundary ends the epoch for the software path", .timeLimit(.minutes(1)))
    func vodCodecChangeEscalates() async throws {
        let written = TransportStreamFixture.write([
            .init(frames: 75), .init(frames: 75, videoPID: 0x1021, videoStreamType: 0x24, pmtVersion: 1),
        ])
        let (cache, reason) = try await Self.produce(written.data, live: false)
        defer { cache.close() }
        guard case .videoConfigurationChanged = reason else {
            Issue.record("expected the configuration exit, got \(String(describing: reason))"); return
        }
    }

    @Test("live: a new audio PID on the same codec plays on, another codec is left out without stopping",
          .timeLimit(.minutes(1)))
    func liveAudioChange() async throws {
        for streamType: UInt8 in [0x81, 0x84] {
            let written = TransportStreamFixture.write([
                .init(frames: 75, audioPID: 0x1100), .init(frames: 75, pmtVersion: 1, audioPID: 0x1101, audioStreamType: streamType),
            ])
            let (cache, reason) = try await Self.produce(written.data, live: true, withAudio: true)
            defer { cache.close() }
            #expect(reason?.description == "eof", "stream type \(streamType)")
            #expect(cache.count >= 4, "stream type \(streamType)")
            #expect(Self.initVersions(cache).count == 1, "an audio change opens no init of its own")
        }
    }

    @Test("a VOD pump started after a seek past a codec change sees it on its first packet", .timeLimit(.minutes(1)))
    func vodRestartPastTheChange() async throws {
        let written = TransportStreamFixture.write([
            .init(frames: 75), .init(frames: 75, videoPID: 0x1021, videoStreamType: 0x24, pmtVersion: 1),
        ])
        let (cache, reason) = try await Self.produce(written.data, live: false,
                                                     startingAt: Double(written.frames[110].dts) / 90_000)
        defer { cache.close() }
        guard case .videoConfigurationChanged = reason else {
            Issue.record("expected the configuration exit, got \(String(describing: reason))"); return
        }
    }

    @Test("a VOD audio codec change ends the epoch; the same codec on a new PID plays on", .timeLimit(.minutes(1)))
    func vodAudioChange() async throws {
        let same = TransportStreamFixture.write([
            .init(frames: 75, audioPID: 0x1100), .init(frames: 75, pmtVersion: 1, audioPID: 0x1101),
        ])
        let kept = try await Self.produce(same.data, live: false, withAudio: true)
        defer { kept.cache.close() }
        #expect(kept.reason?.description == "eof")
        let other = TransportStreamFixture.write([
            .init(frames: 75, audioPID: 0x1100),
            .init(frames: 75, pmtVersion: 1, audioPID: 0x1101, audioStreamType: 0x84),
        ])
        let changed = try await Self.produce(other.data, live: false, withAudio: true)
        defer { changed.cache.close() }
        guard case .videoConfigurationChanged = changed.reason else {
            Issue.record("expected the configuration exit, got \(String(describing: changed.reason))"); return
        }
    }
}
