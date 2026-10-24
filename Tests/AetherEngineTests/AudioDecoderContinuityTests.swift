import AetherLibavcodec
import AetherLibavformat
import AetherLibavutil
import CoreMedia
import Foundation
import Testing
@testable import AetherEngine

/// The software decoder's buffers abut to the sample (#89) until the source breaks, and then the next
/// buffer starts exactly where its source says (`AudioContinuity`), never earlier by what was lost.
@Suite("Software audio decoder continuity")
struct AudioDecoderContinuityTests {

    /// A PCM stream on `timeBase`, at `rate`, and the context that owns it.
    private func makeStream(rate: Int32, timeBase: AVRational)
        -> (UnsafeMutablePointer<AVFormatContext>, UnsafeMutablePointer<AVStream>) {
        let ctx = avformat_alloc_context()!
        let stream = avformat_new_stream(ctx, nil)!
        let par = stream.pointee.codecpar!
        par.pointee.codec_type = AVMEDIA_TYPE_AUDIO
        par.pointee.codec_id = AV_CODEC_ID_PCM_S16LE
        par.pointee.sample_rate = rate
        par.pointee.format = AV_SAMPLE_FMT_S16.rawValue
        av_channel_layout_default(&par.pointee.ch_layout, 2)
        par.pointee.bits_per_coded_sample = 16
        par.pointee.block_align = 4
        stream.pointee.time_base = timeBase
        return (ctx, stream)
    }

    private func packet(pts: Int64, samples: Int, bytes: Int? = nil) -> UnsafeMutablePointer<AVPacket> {
        let size = bytes ?? samples * 4
        let pkt = av_packet_alloc()!
        _ = av_new_packet(pkt, Int32(size))
        for i in 0..<size { pkt.pointee.data[i] = UInt8(truncatingIfNeeded: i &* 5) }
        pkt.pointee.pts = pts
        pkt.pointee.dts = pts
        return pkt
    }

    /// (start, samples) of every buffer the decoder emits for `packets` (pts, samples, rejected).
    private func decode(rate: Int32, timeBase: AVRational, _ packets: [(Int64, Int, Bool)])
        throws -> (buffers: [(CMTime, Int)], decoder: AudioDecoder) {
        let (ctx, stream) = makeStream(rate: rate, timeBase: timeBase)
        defer { var c: UnsafeMutablePointer<AVFormatContext>? = ctx; avformat_free_context(c); c = nil }
        let decoder = AudioDecoder()
        try decoder.open(stream: stream)
        var out: [(CMTime, Int)] = []
        for (pts, samples, rejected) in packets {
            var pkt: UnsafeMutablePointer<AVPacket>? = packet(pts: pts, samples: samples, bytes: rejected ? 3 : nil)
            for buffer in decoder.decode(packet: pkt!) {
                out.append((CMSampleBufferGetPresentationTimeStamp(buffer), CMSampleBufferGetNumSamples(buffer)))
            }
            av_packet_free(&pkt)
        }
        return (out, decoder)
    }

    private func seconds(_ samples: Int, _ rate: Int32) -> Double { Double(samples) / Double(rate) }

    private static let sampleExact = AVRational(num: 1, den: 48_000)
    private var unbroken: [(Int64, Int, Bool)] { (0..<40).map { (Int64($0 * 1024), 1024, false) } }

    @Test("an unbroken source abuts to the sample, with no placement")
    func clean() throws {
        let (buffers, decoder) = try decode(rate: 48_000, timeBase: Self.sampleExact, unbroken)
        defer { decoder.close() }
        #expect(buffers.first?.0.seconds == 0)
        for (a, b) in zip(buffers, buffers.dropFirst()) {
            #expect(abs(a.0.seconds + seconds(a.1, 48_000) - b.0.seconds) < 1e-9)
        }
        #expect(decoder.continuityGaps == 0 && decoder.continuityOverlaps == 0)
    }

    @Test("after a missing or rejected packet the next buffer starts on its own source time", arguments: [false, true])
    func lostPacket(rejected: Bool) throws {
        var packets = unbroken
        if rejected { packets[20].2 = true } else { packets.remove(at: 20) }
        let (buffers, decoder) = try decode(rate: 48_000, timeBase: Self.sampleExact, packets)
        defer { decoder.close() }
        // Packet 21's audio belongs at 21 * 1024 samples, not 1024 earlier.
        let after = try #require(buffers.first { $0.0.seconds >= seconds(20 * 1024, 48_000) - 1e-9 })
        #expect(abs(after.0.seconds - seconds(21 * 1024, 48_000)) < 1e-9, "starts at \(after.0.seconds)")
        #expect(decoder.continuityGaps == 1)
    }

    @Test("a span the source repeats is trimmed: nothing after it plays late")
    func overlap() throws {
        var packets = unbroken
        packets.insert((Int64(19 * 1024), 1024, false), at: 20)
        let (buffers, decoder) = try decode(rate: 48_000, timeBase: Self.sampleExact, packets)
        defer { decoder.close() }
        let end = try #require(buffers.last.map { $0.0.seconds + seconds($0.1, 48_000) })
        #expect(abs(end - seconds(40 * 1024, 48_000)) < 1e-9)
        #expect(decoder.continuityOverlaps == 1)
    }

    @Test("#89: millisecond-rounded timestamps on non-integer frames are rounding, not breaks")
    func roundingIsNotABreak() throws {
        // 1536-sample frames at 44.1 kHz are 34.83 ms; Matroska stores them to the millisecond.
        let packets = (0..<40).map { k -> (Int64, Int, Bool) in
            (Int64((Double(k * 1536) / 44.1).rounded()), 1536, false)
        }
        let (buffers, decoder) = try decode(rate: 44_100, timeBase: AVRational(num: 1, den: 1000), packets)
        defer { decoder.close() }
        for (a, b) in zip(buffers, buffers.dropFirst()) {
            #expect(abs(a.0.seconds + seconds(a.1, 44_100) - b.0.seconds) < 1e-9, "a seam at \(b.0.seconds)")
        }
        #expect(decoder.continuityGaps == 0 && decoder.continuityOverlaps == 0)
    }
}
