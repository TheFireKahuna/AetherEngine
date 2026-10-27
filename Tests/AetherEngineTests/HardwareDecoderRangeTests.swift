import Testing
import Foundation
import CoreVideo
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The hardware decoder hands over the bitstream's own codes: it asks VideoToolbox for the format whose range the
/// SPS states, since asking for the other range converts every sample. The Dolby Vision composer reads its layers
/// through this decoder and takes what it reads as coded values.
///
/// The pictures are one 64x64 libx265 Main10 IDR, a black left half and a white right half, encoded once with
/// `video_full_range_flag` 1 (codes 0 / 1022) and once with 0 (codes 64 / 940); the parameter sets differ in that
/// bit only.
@Suite("Hardware decoder keeps the SPS's codes")
struct HardwareDecoderRangeTests {

    static let vps = BitstreamVideoRangeTests.bytes("40010c01ffff02200000030090000003000003001e959809")
    static let pps = BitstreamVideoRangeTests.bytes("4401c172b42240")
    static func sps(fullRange: Bool) -> [UInt8] {
        BitstreamVideoRangeTests.bytes("42010102200000030090000003000003001ea0208104d96566924caf01"
                                       + (fullRange ? "6e" : "6a") + "04041208000003000800000300c840")
    }
    static func slice(fullRange: Bool) -> [UInt8] {
        BitstreamVideoRangeTests.bytes(fullRange ? "2801af1d80f7015bfff4f6f776f73d3cdb80"
                                                 : "2801af1d80f7015bfff24ef776f4cc2cdb80")
    }

    private final class Slot: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: CVPixelBuffer?
        func set(_ b: CVPixelBuffer) { lock.lock(); if buffer == nil { buffer = b }; lock.unlock() }
        var value: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    /// The first decoded picture of the test card and its luma codes at the black and the white half.
    private static func decode(fullRange: Bool) throws -> (format: OSType, black: Int, white: Int) {
        let decoder = HardwareVideoDecoder()
        defer { decoder.close() }
        let slot = Slot()
        try decoder.open(parameterSets: [vps, sps(fullRange: fullRange), pps], timeBase: AVRational(num: 1, den: 25)) {
            buffer, _, _ in slot.set(buffer)
        }
        let nal = slice(fullRange: fullRange)
        let packet = try #require(av_packet_alloc())
        var owned: UnsafeMutablePointer<AVPacket>? = packet
        defer { av_packet_free(&owned) }
        #expect(av_new_packet(packet, Int32(nal.count + 4)) == 0)
        let data = try #require(packet.pointee.data)
        let length = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: length) { data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: 4) }
        nal.withUnsafeBufferPointer { (data + 4).update(from: $0.baseAddress!, count: nal.count) }
        packet.pointee.pts = 0
        packet.pointee.dts = 0
        packet.pointee.duration = 1
        packet.pointee.flags = AV_PKT_FLAG_KEY
        decoder.decode(packet: packet)
        decoder.flush()
        let deadline = Date().addingTimeInterval(5)
        while slot.value == nil, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        let buffer = try #require(slot.value, "no picture decoded")
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let y = 32 * stride
        return (CVPixelBufferGetPixelFormatType(buffer), Int(row[y + 8] >> 6), Int(row[y + 56] >> 6))
    }

    @Test("a full-range SPS decodes into xf20 with its codes as coded")
    func fullRange() throws {
        let picture = try Self.decode(fullRange: true)
        #expect(picture.format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(picture.black == 0)
        #expect(picture.white == 1022)
    }

    @Test("a limited-range SPS decodes into x420 with its codes as coded")
    func limitedRange() throws {
        let picture = try Self.decode(fullRange: false)
        #expect(picture.format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(picture.black == 64)
        #expect(picture.white == 940)
    }

    @Test("each format and depth pairs with its range")
    func formats() {
        #expect(HardwareVideoDecoder.pixelFormat(tenBit: true, fullRange: false) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        #expect(HardwareVideoDecoder.pixelFormat(tenBit: true, fullRange: true) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        #expect(HardwareVideoDecoder.pixelFormat(tenBit: false, fullRange: false) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(HardwareVideoDecoder.pixelFormat(tenBit: false, fullRange: true) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
    }
}
