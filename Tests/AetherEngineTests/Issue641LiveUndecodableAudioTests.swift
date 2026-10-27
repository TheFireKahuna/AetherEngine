import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// AE#641: a live bridge that decodes nothing has to reach the engine, which rebuilds the session
/// video-only. A FLAC sample entry is built from the encoder's extradata, so on live there is no
/// muxer death to learn it from and AVPlayer would wait on the empty audio track forever.
struct Issue641LiveUndecodableAudioTests {

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var stats: [AudioBridge.FeedStats] = []
        func append(_ s: AudioBridge.FeedStats) { lock.withLock { stats.append(s) } }
        var all: [AudioBridge.FeedStats] { lock.withLock { stats } }
    }

    private func freeAll(_ packets: inout [UnsafeMutablePointer<AVPacket>]) {
        for p in packets {
            var pp: UnsafeMutablePointer<AVPacket>? = p
            trackedPacketFree(&pp)
        }
        packets.removeAll()
    }

    private func makeCodecpar(_ id: AVCodecID) -> UnsafeMutablePointer<AVCodecParameters> {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = id
        par.pointee.sample_rate = 48_000
        if id == AV_CODEC_ID_PCM_S16LE {
            par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
            par.pointee.bits_per_coded_sample = 16
            par.pointee.block_align = 4
        } else {
            par.pointee.format = AV_SAMPLE_FMT_FLTP.rawValue
        }
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        return par
    }

    /// Bytes the mp3 decoder cannot make a frame of, the shape a mislabelled PID hands the bridge.
    private func makeUndecodablePackets(count: Int) -> [UnsafeMutablePointer<AVPacket>] {
        (0..<count).compactMap { i in
            guard let pkt = trackedPacketAlloc(), av_new_packet(pkt, 130) >= 0 else { return nil }
            memset(pkt.pointee.data, 0xFF, 130)
            pkt.pointee.pts = Int64(i) * 26
            pkt.pointee.dts = pkt.pointee.pts
            return pkt
        }
    }

    /// Stereo S16 PCM, 1152 samples a packet: decodes, and fills FLAC's 4608-sample frame every fourth.
    private func makePCMPackets(count: Int) -> [UnsafeMutablePointer<AVPacket>] {
        let samples = 1152
        return (0..<count).compactMap { i in
            guard let pkt = trackedPacketAlloc(), av_new_packet(pkt, Int32(samples * 4)) >= 0 else { return nil }
            memset(pkt.pointee.data, 0, samples * 4)
            pkt.pointee.pts = Int64(i * samples)
            pkt.pointee.dts = pkt.pointee.pts
            return pkt
        }
    }

    private func feed(_ codec: AVCodecID, packets: [UnsafeMutablePointer<AVPacket>],
                      timeBase: AVRational) throws -> (Calls, AudioBridge.FeedStats) {
        let codecpar = makeCodecpar(codec)
        defer {
            var p: UnsafeMutablePointer<AVCodecParameters>? = codecpar
            avcodec_parameters_free(&p)
        }
        let bridge = try AudioBridge(srcCodecpar: codecpar, srcTimeBase: timeBase, mode: .surroundCompat)
        bridge.setSourceStart(0)
        defer { bridge.close() }
        let calls = Calls()
        bridge.onDecoderProducedNothing = { calls.append($0) }
        var outputs: [UnsafeMutablePointer<AVPacket>] = []
        defer { freeAll(&outputs) }
        for p in packets { outputs.append(contentsOf: (try? bridge.feed(packet: p)) ?? []) }
        return (calls, bridge.feedStats)
    }

    @Test("a bridge that decodes nothing tells the session once, with its counters")
    func undecodableFeedReportsOnce() throws {
        var packets = makeUndecodablePackets(count: 200)
        defer { freeAll(&packets) }
        let (calls, stats) = try feed(AV_CODEC_ID_MP3, packets: packets,
                                      timeBase: AVRational(num: 1, den: 1000))
        #expect(stats.decodedNothing)
        #expect(calls.all.count == 1, "one rebuild per session, not one per packet past the threshold")
        #expect(calls.all.first?.framesDecoded == 0)
    }

    @Test("a bridge that decodes and emits never asks for the video-only rebuild")
    func healthyFeedNeverReports() throws {
        var packets = makePCMPackets(count: 200)
        defer { freeAll(&packets) }
        let (calls, stats) = try feed(AV_CODEC_ID_PCM_S16LE, packets: packets,
                                      timeBase: AVRational(num: 1, den: 48_000))
        #expect(stats.packetsEmitted > 0)
        #expect(calls.all.isEmpty)
    }

    @Test("the session's own rebuild keeps every marked stream, a host load starts clean")
    func markSurvivesOnlyTheSessionsOwnRebuild() {
        #expect(AetherEngine.undecodableAudioStreamIndicesAcrossLoad([1, 2], sessionPreservingReload: true) == [1, 2])
        #expect(AetherEngine.undecodableAudioStreamIndicesAcrossLoad([1, 2], sessionPreservingReload: false).isEmpty)
        #expect(AetherEngine.undecodableAudioStreamIndicesAcrossLoad([], sessionPreservingReload: true).isEmpty)
    }

    /// Audit FEA-103: the mark was a single slot, so a second undecodable stream was refused silently
    /// and its pick left the session serving a bridge that never carries a sample.
    @Test("a second undecodable stream is marked as well, and a repeat report changes nothing")
    @MainActor
    func secondUndecodableStreamIsMarked() async throws {
        let engine = try AetherEngine()
        await engine.dropUndecodableLiveAudio(streamIndex: 1, bridgeSummary: "fed=64 decoded=0")
        #expect(engine.undecodableLiveAudioStreamIndices == [1])
        await engine.dropUndecodableLiveAudio(streamIndex: 2, bridgeSummary: "fed=64 decoded=0")
        #expect(engine.undecodableLiveAudioStreamIndices == [1, 2])
        await engine.dropUndecodableLiveAudio(streamIndex: 2, bridgeSummary: "fed=128 decoded=0")
        #expect(engine.undecodableLiveAudioStreamIndices == [1, 2])
    }

    @Test("the cascade skips every marked stream and only those")
    func cascadeSkipsEveryMarkedStream() {
        #expect(HLSVideoEngine.isKnownUndecodable([1, 2], sourceAudioStreamIndex: 1))
        #expect(HLSVideoEngine.isKnownUndecodable([1, 2], sourceAudioStreamIndex: 2))
        #expect(!HLSVideoEngine.isKnownUndecodable([1, 2], sourceAudioStreamIndex: 3))
        #expect(!HLSVideoEngine.isKnownUndecodable([], sourceAudioStreamIndex: 1))
        #expect(!HLSVideoEngine.isKnownUndecodable([0], sourceAudioStreamIndex: -1))
    }

    // MARK: - Where the verdict goes

    private final class Surfaced: @unchecked Sendable {
        private let lock = NSLock()
        private var kinds: [PlaybackErrorKind] = []
        private var live: [Int32] = []
        func surface(_ kind: PlaybackErrorKind) { lock.withLock { kinds.append(kind) } }
        func forward(_ index: Int32) { lock.withLock { live.append(index) } }
        var surfacedKinds: [PlaybackErrorKind] { lock.withLock { kinds } }
        var forwarded: [Int32] { lock.withLock { live } }
    }

    private func makeSession(live: Bool) -> (HLSVideoEngine, Surfaced) {
        let session = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/ae641.mkv"),
                                     dvModeAvailable: false, isLiveSession: live)
        let surfaced = Surfaced()
        session.onVODSourceFailed = { _, _, kind in surfaced.surface(kind) }
        session.onLiveAudioDecodesNothing = { index, _ in surfaced.forward(index) }
        return (session, surfaced)
    }

    @Test("a VOD bridge that decodes nothing surfaces the same verdict as the E-AC-3 route")
    func vodSurfacesTheTypedFailure() {
        let (session, surfaced) = makeSession(live: false)
        session.handleBridgeDecodedNothing(streamIndex: 1, summary: "fed=64 decoded=0")
        #expect(surfaced.surfacedKinds == [.audioBridgeProducedNoOutput],
                "a FLAC bridge has no failed cut to report it, so it played silently as .bridged")
        #expect(surfaced.forwarded.isEmpty)
    }

    @Test("a live bridge that decodes nothing goes to the engine's video-only rebuild, not to an error")
    func liveForwardsInsteadOfFailing() {
        let (session, surfaced) = makeSession(live: true)
        session.handleBridgeDecodedNothing(streamIndex: 2, summary: "fed=64 decoded=0")
        #expect(surfaced.forwarded == [2])
        #expect(surfaced.surfacedKinds.isEmpty)
    }

    @Test("the silent-bridge verdict reaches the host once, every other failure as often as it happens")
    func silentBridgeVerdictIsSurfacedOnce() {
        let (session, surfaced) = makeSession(live: false)
        // The detector, then the E-AC-3 route's failed cut, then its exhausted revive.
        session.handleBridgeDecodedNothing(streamIndex: 1, summary: "fed=64 decoded=0")
        session.surfaceVODSourceFailure(FFmpegErr.einval, "Audio track could not be decoded",
                                        kind: .audioBridgeProducedNoOutput)
        session.surfaceVODSourceFailure(FFmpegErr.einval, "Audio could not be transcoded for playback",
                                        kind: .audioBridgeProducedNoOutput)
        session.surfaceVODSourceFailure(FFmpegErr.einval, "Source audio cannot be muxed")
        session.surfaceVODSourceFailure(FFmpegErr.einval, "Source audio cannot be muxed")
        #expect(surfaced.surfacedKinds == [.audioBridgeProducedNoOutput, .vodSourceFailed, .vodSourceFailed])
    }
}
