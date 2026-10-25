import CoreMedia
import CoreVideo
import Foundation
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The overlay tap's decode schedule, with a decoder that "decodes" a unit into a picture at the unit's own time.
@Suite("Overlay packet tap")
struct OverlayPacketTapTests {

    /// Delivers one picture per unit, at the unit's time, and records what it was fed.
    final class EchoDecoder: OverlayTapDecoder, @unchecked Sendable {
        let deliver: @Sendable (CVPixelBuffer, CMTime) -> Void
        let picture: CVPixelBuffer
        private let lock = NSLock()
        private var _fed: [(pts: Int64, restart: Bool)] = []
        var fed: [(pts: Int64, restart: Bool)] { lock.withLock { _fed } }

        init(deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
            self.deliver = deliver
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            picture = buffer!
        }

        func decode(_ packet: UnsafeMutablePointer<AVPacket>, restart: Bool, timeBase: AVRational) {
            lock.withLock { _fed.append((packet.pointee.pts, restart)) }
            deliver(picture, CMTime(value: packet.pointee.pts, timescale: timeBase.den))
        }

        func close() {}
    }

    static let tb = AVRational(num: 1, den: 1000)

    /// `seconds` of 25 fps units, a keyframe every `gop` seconds, fed as the producer feeds them.
    static func makeTap(seconds: Int, gop: Int) -> (OverlayPacketTap<Int>, () -> EchoDecoder?) {
        var decoder: EchoDecoder?
        let tap = OverlayPacketTap<Int>(decodeAheadSeconds: 0.2) { deliver in
            let d = EchoDecoder(deliver: deliver)
            decoder = d
            return d
        }
        for i in 0..<(seconds * 25) {
            let pts = Int64(i * 40)
            let packet = av_packet_alloc()!
            _ = av_new_packet(packet, 4)
            packet.pointee.pts = pts
            packet.pointee.dts = pts
            let isKey = i % (gop * 25) == 0
            _ = tap.beginsRun(dts: pts)
            tap.insert(pts: pts, timeBase: tb, isKey: isKey, info: i, packet: packet)
        }
        return (tap, { decoder })
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    @Test("a clock more than a second past its keyframe is decoded to from that keyframe, once")
    func longGOPTarget() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 4)
        defer { tap.close() }
        tap.advance(to: 6.52)
        #expect(Self.waitUntil(5) { tap.unit(at: 6.52)?.picture != nil })
        // The decoder may have started at the first keyframe as units arrived (the clock at 0); then it restarted
        // once, at the keyframe before the clock, and carried on from there.
        let restarts = try #require(decoder()).fed.filter(\.restart).map(\.pts)
        #expect(restarts == [4000] || restarts == [0, 4000])
        // Up to the decode window and no further.
        #expect((try #require(decoder()).fed.map(\.pts).max() ?? 0) <= 6520 + 200)
    }

    @Test("a decode short of the clock jumps to a keyframe past everything it fed; one before it carries on")
    func jumpsOnlyForward() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 2)
        defer { tap.close() }
        tap.advance(to: 1)
        #expect(Self.waitUntil(5) { tap.unit(at: 1)?.picture != nil })
        tap.advance(to: 1.52)
        #expect(Self.waitUntil(5) { tap.unit(at: 1.52)?.picture != nil })
        #expect(try #require(decoder()).fed.filter(\.restart).map(\.pts) == [0], "inside the GOP: no restart")
        tap.advance(to: 9)
        #expect(Self.waitUntil(5) { tap.unit(at: 9)?.picture != nil })
        #expect(try #require(decoder()).fed.filter(\.restart).map(\.pts) == [0, 8000])
    }

    @Test("a backward jump restarts at the keyframe before the new clock")
    func backwardJump() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 2)
        defer { tap.close() }
        tap.advance(to: 9)
        #expect(Self.waitUntil(5) { tap.unit(at: 9)?.picture != nil })
        tap.advance(to: 3)
        #expect(Self.waitUntil(5) { tap.unit(at: 3)?.picture != nil })
        #expect(try #require(decoder()).fed.filter(\.restart).last?.pts == 2000)
    }
}
