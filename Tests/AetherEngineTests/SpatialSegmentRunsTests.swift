#if TrueHDObjectAudio || DTSXObjectAudio
import AetherLibavcodec
import AetherLibavutil
import Foundation
import Testing
@testable import AetherEngine

/// The spatial bridge's segments come out the same however playback reached them, as the channel
/// bridge's do (`AudioSegmentRunsTests`): every stage from the decoder to the APAC encoder runs per
/// segment, from the pre-roll before it.
@Suite("Segment runs: a seek makes continuous playback's APAC segments")
struct SpatialSegmentRunsTests {

    /// Every pushed byte is a 40-frame access unit; what a frame carries depends only on where it
    /// sits in the source, as a real decoder's output does: a bed, an LFE and an object moving
    /// round the room.
    final class PositionalDecoder: ObjectAudioDecoding {
        let span = AudioStageSpan.instant
        private var inputFrames: Int64 = 0
        private var blocks: [(offset: Int64, frames: Int, stamp: (Int64, Int64)?)] = []
        private var stamp: (Int64, Int64)?
        private let planes: [UnsafeMutablePointer<Float>] = (0..<3).map { _ in .allocate(capacity: 1 << 16) }

        deinit { planes.forEach { $0.deallocate() } }

        func push(_ bytes: UnsafeRawBufferPointer, pts: Int64) throws {
            if pts != Int64.min { stamp = (pts, inputFrames) }
            blocks.append((inputFrames, bytes.count * 40, stamp))
            inputFrames += Int64(bytes.count * 40)
        }

        func nextBlock() throws -> ObjectAudioDecodedBlock? {
            guard !blocks.isEmpty else { return nil }
            let b = blocks.removeFirst()
            // Milliseconds on a 1/1000 time base, 48 frames each.
            let first = (b.stamp?.0 ?? 0) * 48 + b.offset - (b.stamp?.1 ?? 0)
            for i in 0..<b.frames {
                let n = Float(first + Int64(i))
                planes[0][i] = 0.2 * sinf(n * 0.031) * (0.6 + 0.4 * sinf(n * 0.0007))
                planes[1][i] = 0.3 * sinf(n * 0.004)
                planes[2][i] = 0.25 * sinf(n * 0.067 + 0.5 * sinf(n * 0.0011))
            }
            let x = Float(first % 96_000) / 96_000
            return ObjectAudioDecodedBlock(
                sampleRate: 48_000, frameCount: b.frames, inputFrameOffset: b.offset,
                configurationGeneration: 0, roles: [.bed(.left), .lfe, .object],
                planes: planes.map { UnsafePointer($0) },
                updates: [.init(frameOffset: 0, rampFrames: b.frames,
                                states: [.init(), .init(), .init(position: SIMD3(x, 0.5, 1))])],
                sourcePts: b.stamp?.0, sourcePtsInputFrame: b.stamp?.1 ?? 0,
                clockFrame: nil, gridFrames: 40)
        }

        func reset() { inputFrames = 0; blocks = []; stamp = nil }
    }

    private struct Out: Equatable {
        let pts: Int64
        let bytes: [UInt8]
        let sync: Bool
    }

    /// 20 ms packets from `fromMs` to `toMs`, through segment runs whose segments are two seconds
    /// long from `base`; every packet handed on, by segment.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    private func produce(fromMs: Int64, toMs: Int64, base: Int) throws -> (segments: [Int: [Out]], preRoll: Double) {
        let make = {
            try SpatialAudioBridge(srcTimeBase: AVRational(num: 1, den: 1000), layout: .l714,
                                   decoder: PositionalDecoder()) as any AudioTranscodingBridge
        }
        let par = try #require(avcodec_parameters_alloc())
        var p: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&p) }
        par.pointee.codec_id = AV_CODEC_ID_TRUEHD
        par.pointee.sample_rate = 48_000
        let runs = try #require(AudioSegmentRuns(template: try make(), sourceCodecpar: par,
                                                 sourceTimeBase: AVRational(num: 1, den: 1000), makeRun: make))
        defer { runs.close() }
        runs.setSourceStart(0)
        let plan = AudioRunPlan(baseIndex: base, boundaries: stride(from: base * 2, through: 14, by: 2).map { Int64($0) * 90_000 },
                                planAnchor: 0, videoTimeBase: AVRational(num: 1, den: 90_000),
                                outputTimeBase: runs.encoderTimeBase, delayTicks: 0)
        runs.setRunPlan(plan)
        var segments: [Int: [Out]] = [:]
        func take(_ packets: [UnsafeMutablePointer<AVPacket>]) {
            for fp in packets {
                segments[plan.segment(ofOutputPts: fp.pointee.pts, duration: fp.pointee.duration), default: []]
                    .append(Out(pts: fp.pointee.pts, bytes: Array(UnsafeBufferPointer(start: fp.pointee.data, count: Int(fp.pointee.size))),
                                sync: fp.pointee.flags & AV_PKT_FLAG_KEY != 0))
                var q: UnsafeMutablePointer<AVPacket>? = fp
                trackedPacketFree(&q)
            }
        }
        let payload = [UInt8](repeating: 0, count: 24)
        for ms in stride(from: fromMs, to: toMs, by: 20) {
            let pkt = try #require(av_packet_alloc())
            defer { var q: UnsafeMutablePointer<AVPacket>? = pkt; av_packet_free(&q) }
            _ = av_new_packet(pkt, 24)
            pkt.pointee.data.update(from: payload, count: 24)
            pkt.pointee.pts = ms
            pkt.pointee.dts = ms
            pkt.pointee.duration = 20
            take(try runs.feed(packet: pkt))
        }
        take(runs.settle())
        take(runs.flush())
        return (segments, runs.preRollSeconds)
    }

    @Test("a seek makes the APAC segments continuous playback made")
    func seekMatchesContinuous() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let continuous = try produce(fromMs: 0, toMs: 12_000, base: 0)
        let all = continuous.segments.keys.sorted().flatMap { continuous.segments[$0]! }
        try #require(all.count > 400)
        for (a, b) in zip(all, all.dropFirst()) { #expect(b.pts - a.pts == 1024, "\(a.pts) then \(b.pts)") }
        // Every segment starts on a sync packet, so it decodes on its own after a seek.
        for (segment, packets) in continuous.segments { #expect(packets.first?.sync == true, "segment \(segment)") }
        for k in [2, 4] {
            let fromMs = (Int64(k * 2_000) - Int64((continuous.preRoll * 1000).rounded(.up))) / 20 * 20
            let seek = try produce(fromMs: fromMs, toMs: 12_000, base: k)
            for segment in k...(k + 1) {
                let want = continuous.segments[segment] ?? []
                let got = seek.segments[segment] ?? []
                #expect(!want.isEmpty)
                #expect(got.map(\.pts) == want.map(\.pts), "segment \(segment)'s timestamps after a seek to \(k)")
                #expect(got == want, "segment \(segment)'s bytes after a seek to \(k)")
            }
        }
    }
}
#endif
