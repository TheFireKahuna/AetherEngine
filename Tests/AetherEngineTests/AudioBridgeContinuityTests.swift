import AetherLibavcodec
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// The bridge's sample count is its timeline until something breaks it, and then the next frame is
/// placed by its own source timestamp (`AudioContinuity`). Fed 48 kHz stereo PCM in 1024-sample
/// packets on a sample-exact time base, through the FLAC bridge: whatever happens to the input, the
/// output has to run seamlessly from the first sample to the source's last, and every placement has to
/// be counted under the event that caused it.
@Suite("Audio bridge continuity")
struct AudioBridgeContinuityTests {

    static let packetSamples = 1024
    static let timeBase = AVRational(num: 1, den: 48_000)

    private func makeBridge(followsSourceContinuity: Bool = true) throws -> (AudioBridge, UnsafeMutablePointer<AVCodecParameters>) {
        let par = avcodec_parameters_alloc()!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.sample_rate = 48_000
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = 4
        let bridge = try AudioBridge(srcCodecpar: par, srcTimeBase: Self.timeBase, mode: .lossless,
                                     followsSourceContinuity: followsSourceContinuity)
        bridge.setSourceStart(0)
        return (bridge, par)
    }

    /// A packet of `samples` frames stamped `pts` (sample units); `bytes` overrides the size, for a
    /// packet the decoder rejects.
    private func packet(pts: Int64, samples: Int = packetSamples, bytes: Int? = nil) -> UnsafeMutablePointer<AVPacket> {
        let size = bytes ?? samples * 4
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(size))
        for i in 0..<size { pkt.pointee.data[i] = UInt8(truncatingIfNeeded: i &* 7 &+ Int(pts)) }
        pkt.pointee.pts = pts
        pkt.pointee.dts = pts
        pkt.pointee.duration = Int64(samples)
        return pkt
    }

    /// Feeds `pts` in order (nil = a rejected packet) and returns the output's (pts, duration) list.
    private func run(_ bridge: AudioBridge, _ stamps: [(pts: Int64, rejected: Bool)]) throws -> [(Int64, Int64)] {
        var out: [(Int64, Int64)] = []
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for p in packets {
                out.append((p.pointee.pts, p.pointee.duration))
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
        }
        for stamp in stamps {
            var pkt: UnsafeMutablePointer<AVPacket>? = packet(pts: stamp.pts, bytes: stamp.rejected ? 3 : nil)
            take(try bridge.feed(packet: pkt!))
            av_packet_free(&pkt)
        }
        take(bridge.flush())
        return out
    }

    /// Output that runs seamlessly from `start` and ends at `end`.
    private func expectSeamless(_ out: [(Int64, Int64)], from start: Int64, to end: Int64,
                                sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(out.first?.0 == start, sourceLocation: sourceLocation)
        for (a, b) in zip(out, out.dropFirst()) {
            #expect(a.0 + a.1 == b.0, "seam at \(a.0)", sourceLocation: sourceLocation)
        }
        #expect(out.last.map { $0.0 + $0.1 } == end, sourceLocation: sourceLocation)
    }

    private var unbroken: [(pts: Int64, rejected: Bool)] { (0..<100).map { (Int64($0 * Self.packetSamples), false) } }

    @Test("an unbroken source is the count: no placement at all")
    func clean() throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        expectSeamless(try run(bridge, unbroken), from: 0, to: 100 * 1024)
        let s = bridge.feedStats
        #expect(s.continuityGaps == 0 && s.continuityOverlaps == 0 && s.continuityJumps == 0)
    }

    @Test("a packet missing from the source becomes silence of its length, and everything after stays put")
    func missingPacket() throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        var stamps = unbroken
        stamps.remove(at: 50)
        expectSeamless(try run(bridge, stamps), from: 0, to: 100 * 1024)
        #expect(bridge.feedStats.continuityGaps == 1)
    }

    @Test("a packet the decoder rejects becomes silence of its length")
    func rejectedPacket() throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        var stamps = unbroken
        stamps[50].rejected = true
        expectSeamless(try run(bridge, stamps), from: 0, to: 100 * 1024)
        #expect(bridge.feedStats.packetsRejected == 1)
        #expect(bridge.feedStats.continuityGaps == 1)
    }

    @Test("a span the source repeats is trimmed, so nothing after it plays late")
    func overlap() throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        var stamps = unbroken
        stamps.insert((Int64(49 * 1024), false), at: 50)
        expectSeamless(try run(bridge, stamps), from: 0, to: 100 * 1024)
        #expect(bridge.feedStats.continuityOverlaps == 1)
    }

    @Test("a jump past the fill limit re-anchors: the audio after it plays where its timestamps say")
    func jump() throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        let jump = Int64(10 * 48_000)
        let stamps = unbroken.enumerated().map { i, s in (i >= 50 ? s.pts + jump : s.pts, s.rejected) }
        let out = try run(bridge, stamps)
        #expect(bridge.feedStats.continuityJumps == 1)
        #expect(out.first?.0 == 0)
        #expect(out.last.map { $0.0 + $0.1 } == 100 * 1024 + jump)
        // Packet 50's audio starts exactly at its jumped timestamp.
        #expect(out.contains { $0.0 == 50 * 1024 + jump } || out.contains { $0.0 <= 50 * 1024 + jump && $0.0 + $0.1 > 50 * 1024 + jump })
    }

    /// AE#464: the delay is in the output's timestamps, and what a negative one puts before zero comes
    /// off at the exact sample: the output starts on zero and is shorter by exactly the cut.
    @Test("an output offset moves the timeline exactly, and a negative one is cut at the sample",
          arguments: [Int64(-7200), 9600])
    func outputOffset(samples: Int64) throws {
        let (bridge, par) = try makeBridge()
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        bridge.setOutputOffset(seconds: Double(samples) / 48_000)
        expectSeamless(try run(bridge, unbroken), from: max(samples, 0), to: 100 * 1024 + samples)
        let s = bridge.feedStats
        #expect(s.continuityGaps == 0 && s.continuityOverlaps == 0 && s.continuityJumps == 0)
    }

    @Test("a live splice overlap comes off the audio that follows: one seamless track, never stamped back over itself")
    func liveSpliceOverlapIsTrimmed() throws {
        let (bridge, par) = try makeBridge(followsSourceContinuity: false)
        defer { bridge.close(); var p: UnsafeMutablePointer<AVCodecParameters>? = par; avcodec_parameters_free(&p) }
        var out: [(Int64, Int64)] = []
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for p in packets {
                out.append((p.pointee.pts, p.pointee.duration))
                var pp: UnsafeMutablePointer<AVPacket>? = p
                trackedPacketFree(&pp)
            }
        }
        for (i, stamp) in unbroken.enumerated() {
            if i == 50 { bridge.noteTimelineJump(deltaSeconds: -0.1) }
            var pkt: UnsafeMutablePointer<AVPacket>? = packet(pts: stamp.pts)
            take(try bridge.feed(packet: pkt!))
            av_packet_free(&pkt)
        }
        take(bridge.flush())
        expectSeamless(out, from: 0, to: 100 * 1024 - 4800)
    }

    @Test("the rule: within a source tick and a sample it is rounding; past it, the frame is placed")
    func rule() {
        let ms = AudioContinuity.tolerance(sourceTimeBase: AVRational(num: 1, den: 1000), sampleRate: 48_000)
        #expect(ms == 49)
        #expect(AudioContinuity.tolerance(sourceTimeBase: AVRational(num: 1, den: 90_000), sampleRate: 48_000) == 2)
        #expect(AudioContinuity.decide(expected: 1000, actual: 1048, tolerance: ms, sampleRate: 48_000) == .continue)
        #expect(AudioContinuity.decide(expected: 1000, actual: 1050, tolerance: ms, sampleRate: 48_000) == .gap(50))
        #expect(AudioContinuity.decide(expected: 1000, actual: 900, tolerance: ms, sampleRate: 48_000) == .overlap(100))
        #expect(AudioContinuity.decide(expected: 0, actual: 6 * 48_000, tolerance: ms, sampleRate: 48_000) == .jump(6 * 48_000))
    }
}
