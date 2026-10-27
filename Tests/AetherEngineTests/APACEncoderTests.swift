import Testing
import Foundation
@testable import AetherEngine

/// The APAC encoder is Apple's, reached through `AVAudioConverter`. The spatial bridge stamps its
/// packets by count (#731), so the facts it relies on are pinned against the real encoder here:
/// packet length, priming, the cookie being the whole `dapa` box, an Audio Sync Packet on every
/// `syncPacketInterval`-th packet from the first, a rate held to its target, and no multi-second
/// lookahead with dynamic range control off.
@Suite("APAC encoder")
struct APACEncoderTests {

    /// Planar test signal: a different low-level tone per channel.
    private func withPlanes<R>(
        _ layout: SpatialSpeakerLayout, frames: Int, startFrame: Int = 0, _ body: ([UnsafePointer<Float>]) throws -> R
    ) rethrows -> R {
        let planes = (0..<layout.channelCount).map { c -> UnsafeMutablePointer<Float> in
            let p = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            for i in 0..<frames {
                p[i] = 0.1 * sin(Float(startFrame + i) * 2 * .pi * Float(200 + 50 * c) / 48_000)
            }
            return p
        }
        defer { planes.forEach { $0.deallocate() } }
        return try body(planes.map { UnsafePointer($0) })
    }

    @Test("every bed layout opens, with a dapa cookie, 2048 frames of priming and 1024-frame packets",
          arguments: SpatialSpeakerLayout.allCases)
    func opens(layout: SpatialSpeakerLayout) throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        let cookie = [UInt8](encoder.magicCookie)
        #expect(cookie.count > 8)
        #expect(String(bytes: cookie[4..<8], encoding: .ascii) == "dapa")
        #expect(Int(cookie[0]) << 24 | Int(cookie[1]) << 16 | Int(cookie[2]) << 8 | Int(cookie[3]) == cookie.count,
                "the cookie is one complete box")
        #expect(encoder.leadingFrames == 2048)
        #expect(APACEncoder.framesPerPacket == 1024)
    }

    /// An Audio Sync Packet's header has its top bit set, the others not (measured, macOS 27): what the
    /// stream itself says, against what the encoder reports.
    @available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *)
    static func headerSaysSync(_ packet: APACEncoder.Packet) -> Bool { (packet.data.first ?? 0) & 0x80 != 0 }

    @Test("packets come out as fast as frames go in: priming plus input, a packet per 1024 frames, a sync packet every interval")
    func packetCadence() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        let frames = 48_000
        var packets: [APACEncoder.Packet] = []
        var fed = 0
        while fed < frames {
            let n = min(2048, frames - fed)
            packets += try withPlanes(layout, frames: n, startFrame: fed) { try encoder.encode(planes: $0, frameCount: n) }
            fed += n
        }
        // With DRC off the encoder holds only its priming. A lookahead of seconds (DRC on) would leave
        // this one second of input with no packets at all.
        #expect(packets.count >= frames / 1024 - 2, "got \(packets.count) packets for 1 s of input")
        #expect(packets.indices.filter { packets[$0].isSync }
                == Array(stride(from: 0, to: packets.count, by: APACEncoder.syncPacketInterval)))
        #expect(packets.allSatisfy { $0.isSync == Self.headerSaysSync($0) }, "the stream says the same")
        #expect(packets.allSatisfy { !$0.data.isEmpty })
        let tail = try encoder.flush()
        let total = packets.count + tail.count
        let expected = (frames + encoder.leadingFrames + 1023) / 1024
        #expect(abs(total - expected) <= 1, "\(total) packets in total, \(expected) expected")
        #expect(try encoder.flush().isEmpty, "a second flush has nothing left")
    }

    @Test("after a reset the encoder starts over and keeps going")
    func resetStartsOver() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        _ = try withPlanes(layout, frames: 8192) { try encoder.encode(planes: $0, frameCount: 8192) }
        _ = try encoder.flush()
        encoder.reset()
        let frames = (APACEncoder.syncPacketInterval + 4) * 1024
        let again = try withPlanes(layout, frames: frames) { try encoder.encode(planes: $0, frameCount: frames) }
        #expect(again.count > APACEncoder.syncPacketInterval)
        #expect(again.indices.filter { again[$0].isSync } == [0, APACEncoder.syncPacketInterval],
                "the cadence starts over with the run")
    }

    @Test("constant mode holds the target: every six seconds within the declared peak, none far under the target")
    func rateHoldsItsTarget() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let target = layout.channelCount * 320_000
        let encoder = try APACEncoder(layout: layout, bitRate: target)
        // Busy enough to want more than the target: a tone per channel over noise.
        var seed: UInt64 = 7
        let frames = 18 * 48_000
        var packets: [APACEncoder.Packet] = []
        let chunk = 4096
        let planes = (0..<layout.channelCount).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: chunk) }
        defer { planes.forEach { $0.deallocate() } }
        for start in stride(from: 0, to: frames, by: chunk) {
            for (c, p) in planes.enumerated() {
                for i in 0..<chunk {
                    seed = seed &* 6364136223846793005 &+ 1442695040888963407
                    p[i] = 0.2 * sin(Float(start + i) * 2 * .pi * Float(150 + 97 * c) / 48_000)
                        + 0.2 * (Float(seed >> 40) / Float(1 << 24) * 2 - 1)
                }
            }
            packets += try encoder.encode(planes: planes.map { UnsafePointer($0) }, frameCount: chunk)
        }
        let perSegment = 6 * 48_000 / 1024
        for start in stride(from: 0, to: packets.count - perSegment, by: perSegment) {
            let bits = packets[start..<(start + perSegment)].reduce(0) { $0 + $1.data.count * 8 }
            let rate = bits * 48_000 / (perSegment * 1024)
            #expect(rate <= APACEncoder.peakBitRate(target: target), "\(rate) bit/s from packet \(start)")
            #expect(rate >= target * 97 / 100, "\(rate) bit/s from packet \(start)")
        }
    }

    @Test("an input longer than the converter's buffer is fed in slices, nothing dropped")
    func longInputIsSliced() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l714
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000, maxInputFrames: 4096)
        let frames = 4096 * 5 + 300
        let packets = try withPlanes(layout, frames: frames) { try encoder.encode(planes: $0, frameCount: frames) }
        let total = packets.count + (try encoder.flush()).count
        #expect(abs(total - (frames + encoder.leadingFrames + 1023) / 1024) <= 1)
    }

    @Test("encode after flush throws instead of swallowing the input")
    func encodeAfterFlushThrows() throws {
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else { return }
        let layout = SpatialSpeakerLayout.l512
        let encoder = try APACEncoder(layout: layout, bitRate: layout.channelCount * 320_000)
        _ = try withPlanes(layout, frames: 2048) { try encoder.encode(planes: $0, frameCount: 2048) }
        _ = try encoder.flush()
        #expect(throws: APACEncoder.EncoderError.self) {
            try withPlanes(layout, frames: 1000) { try encoder.encode(planes: $0, frameCount: 1000) }
        }
    }
}
