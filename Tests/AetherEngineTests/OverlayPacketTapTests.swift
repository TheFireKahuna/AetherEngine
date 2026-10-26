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

        /// While stalled, a decode does not return: a decoder that has fallen behind.
        private let stallState = NSCondition()
        private var stalled = false
        func stall() { stallState.withLock { stalled = true } }
        func resume() { stallState.withLock { stalled = false; stallState.broadcast() } }

        func decode(_ packet: UnsafeMutablePointer<AVPacket>, restarting: Bool, clock: Double, timeBase: AVRational) {
            stallState.withLock { while stalled { stallState.wait() } }
            lock.withLock { _fed.append((packet.pointee.pts, restarting)) }
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

    @Test("a jump back inside the run, behind its decode, restarts at the keyframe before the clock")
    func backwardJumpInsideTheRun() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 4)
        defer { tap.close() }
        tap.advance(to: 7)
        #expect(Self.waitUntil(5) { tap.unit(at: 7)?.picture != nil })
        tap.advance(to: 5)
        #expect(Self.waitUntil(5) { tap.unit(at: 5)?.picture != nil })
        #expect(try #require(decoder()).fed.filter(\.restart).last?.pts == 4000)
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

    @Test("a decoder short of the clock holds the picture on screen, then shows the clock's own, never one late")
    func holdsWhileBehind() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 4)
        defer { tap.close() }
        tap.advance(to: 1)
        #expect(Self.waitUntil(5) { tap.picture(atOrBefore: 1)?.seconds == 1 })
        let d = try #require(decoder())
        d.stall()
        tap.advance(to: 1.6)
        // Decoded up to the old decode window, 0.2 s ahead of 1 s: 0.4 s short of the clock, so nothing is shown.
        #expect(tap.picture(atOrBefore: 1.6) == nil)
        d.resume()
        #expect(Self.waitUntil(5) { tap.picture(atOrBefore: 1.6)?.seconds == 1.6 })
    }

    @Test("a picture is late from when the next one fell due: under the hold it shows, past it it is held until on time")
    func holdMeasuresFromTheNextPictureDue() throws {
        let (tap, decoder) = Self.makeTap(seconds: 12, gop: 4)
        defer { tap.close() }
        tap.advance(to: 1)
        #expect(Self.waitUntil(5) { tap.picture(atOrBefore: 1)?.seconds == 1 })
        let d = try #require(decoder())
        d.stall()
        // The newest picture decoded before the stall: the decode window runs ahead of the clock.
        var newestMs = 1000
        while tap.unit(at: Double(newestMs + 40) / 1000)?.picture != nil { newestMs += 40 }
        let newest = Double(newestMs) / 1000
        // 25 fps: the next picture falls due 40 ms after the newest. 20 ms overdue still shows the newest.
        tap.advance(to: newest + 0.06)
        #expect(tap.picture(atOrBefore: newest + 0.06)?.seconds == newest)
        // 60 ms overdue is past the hold.
        tap.advance(to: newest + 0.1)
        #expect(tap.picture(atOrBefore: newest + 0.1) == nil)
        // Once held, 20 ms overdue is still held: nothing shows until no picture is overdue at all.
        tap.advance(to: newest + 0.06)
        #expect(tap.picture(atOrBefore: newest + 0.06) == nil)
        // On the clock again, the newest picture is the clock's own and shows.
        tap.advance(to: newest + 0.03)
        #expect(tap.picture(atOrBefore: newest + 0.03)?.seconds == newest)
        d.resume()
    }

    @Test("past the stream's last picture, with nothing left to decode, that picture is shown however old")
    func showsTheLastPictureAtTheEnd() throws {
        let (tap, _) = Self.makeTap(seconds: 12, gop: 4)
        defer { tap.close() }
        tap.advance(to: 11.9)
        #expect(Self.waitUntil(5) { tap.picture(atOrBefore: 11.9)?.seconds == 11.88 })
        tap.advance(to: 13)
        #expect(Self.waitUntil(5) { tap.picture(atOrBefore: 13)?.seconds == 11.96 })
    }
}

/// What the tap keeps of a unit, and how much of it: the packet on disk, read back as it was cut, and the producer held
/// once the tap is full rather than units ahead of the clock dropped.
@Suite("Overlay packet tap storage")
struct OverlayPacketTapStorageTests {

    /// Records every packet it is fed: its timing, bytes and side data.
    final class RecordingDecoder: OverlayTapDecoder, @unchecked Sendable {
        struct Fed: Equatable { let pts: Int64; let dts: Int64; let duration: Int64; let flags: Int32; let bytes: [UInt8]; let side: [UInt8] }
        let deliver: @Sendable (CVPixelBuffer, CMTime) -> Void
        let picture: CVPixelBuffer
        private let lock = NSLock()
        private var _fed: [Fed] = []
        var fed: [Fed] { lock.withLock { _fed } }

        init(deliver: @escaping @Sendable (CVPixelBuffer, CMTime) -> Void) {
            self.deliver = deliver
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
            picture = buffer!
        }

        func decode(_ packet: UnsafeMutablePointer<AVPacket>, restarting: Bool, clock: Double, timeBase: AVRational) {
            let p = packet.pointee
            var sideSize = 0
            let side = av_packet_get_side_data(packet, AV_PKT_DATA_DOVI_CONF, &sideSize)
            lock.withLock {
                _fed.append(Fed(pts: p.pts, dts: p.dts, duration: p.duration, flags: p.flags,
                                bytes: Array(UnsafeBufferPointer(start: p.data, count: Int(p.size))),
                                side: side.map { Array(UnsafeBufferPointer(start: $0, count: sideSize)) } ?? []))
            }
            deliver(picture, CMTime(value: p.pts, timescale: timeBase.den))
        }

        func close() {}
    }

    @Test("a unit is decoded from disk exactly as it was cut, side data included")
    func unitRoundTrips() {
        var decoder: RecordingDecoder?
        let tap = OverlayPacketTap<Int>(decodeAheadSeconds: 0.2) { deliver in
            let d = RecordingDecoder(deliver: deliver)
            decoder = d
            return d
        }
        defer { tap.close() }
        let payload: [UInt8] = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        let side: [UInt8] = [1, 0, 10, 0x35, 0x77]
        let packet = av_packet_alloc()!
        _ = av_new_packet(packet, Int32(payload.count))
        payload.withUnsafeBufferPointer { packet.pointee.data.update(from: $0.baseAddress!, count: $0.count) }
        packet.pointee.pts = 0
        packet.pointee.dts = -40
        packet.pointee.duration = 40
        packet.pointee.flags = AV_PKT_FLAG_KEY
        let target = av_packet_new_side_data(packet, AV_PKT_DATA_DOVI_CONF, side.count)!
        side.withUnsafeBufferPointer { target.update(from: $0.baseAddress!, count: $0.count) }
        _ = tap.beginsRun(dts: -40)
        tap.insert(pts: 0, timeBase: OverlayPacketTapTests.tb, isKey: true, info: 0, packet: packet)
        tap.advance(to: 0)

        #expect(OverlayPacketTapTests.waitUntil(2) { decoder?.fed.count == 1 })
        #expect(decoder?.fed.first == RecordingDecoder.Fed(pts: 0, dts: -40, duration: 40, flags: AV_PKT_FLAG_KEY,
                                                            bytes: payload, side: side))
        #expect(tap.held.bytes > payload.count)
    }

    @Test("a full tap holds the producer and keeps every unit ahead of the clock; the clock moving on makes room")
    func fullTapHoldsTheProducer() {
        let (tap, _) = OverlayPacketTapTests.makeTap(seconds: 0, gop: 2)
        defer { tap.close() }
        let units = OverlayPacketTap<Int>.maxEntries
        for i in 0..<(units + 100) {
            let pts = Int64(i * 40)
            let packet = av_packet_alloc()!
            _ = av_new_packet(packet, 4)
            packet.pointee.pts = pts
            packet.pointee.dts = pts
            _ = tap.beginsRun(dts: pts)
            tap.insert(pts: pts, timeBase: OverlayPacketTapTests.tb, isKey: i % 50 == 0, info: i, packet: packet)
        }
        // Past its ceiling the producer is owed no more room, but nothing it already cut ahead is dropped.
        #expect(tap.hasRoomAhead == false)
        #expect(tap.held.units == units + 100)
        #expect(tap.unit(at: Double(units + 99) * 0.04) != nil)
        // The clock passing the first units by more than the minute kept behind drops them, which makes room.
        tap.advance(to: OverlayPacketTap<Int>.keepBehindSeconds + 10)
        #expect(tap.hasRoomAhead)
        #expect(tap.unit(at: 0) == nil)
    }
}
