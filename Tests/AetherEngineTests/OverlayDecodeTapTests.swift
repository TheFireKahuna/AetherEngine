import CoreMedia
import CoreVideo
import Foundation
import os
import Testing
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// The software overlay's decode (`OverlayDecodeTap`) on real streams, AV1 on libavcodec and HEVC on VideoToolbox:
/// the picture it gives for a clock is the one a plain decode by the same decoder shows at that time, through jumps
/// either way, with only a few pictures held. Needs `Fixtures/av1.mp4` and `Fixtures/hdr10-hevc.mp4`
/// (Scripts/fetch-fixtures.sh).
@Suite("Overlay decode tap", .serialized)
struct OverlayDecodeTapTests {
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
    static var hasFixtures: Bool {
        ["av1.mp4", "hdr10-hevc.mp4"].allSatisfy { FileManager.default.fileExists(atPath: fixture($0).path) }
    }

    static func waitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return condition()
    }

    /// Every plane's bytes, row by row up to the visible width (a bi-planar 4:2:0 buffer: one luma sample, or one
    /// pair of chroma samples, of one or two bytes each).
    static func planes(_ buffer: CVPixelBuffer) -> [[UInt8]] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<max(1, CVPixelBufferGetPlaneCount(buffer))).map { plane in
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let sampleBytes = CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 2
            let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * sampleBytes * (plane == 0 ? 1 : 2)
            return (0..<rows).flatMap { Array(UnsafeBufferPointer(start: base + $0 * stride, count: rowBytes)) }
        }
    }

    @Test("the picture for a clock is a plain decode's at that time, forward and back", .enabled(if: hasFixtures),
          arguments: [("av1.mp4", false), ("hdr10-hevc.mp4", true)])
    func picturesMatchAPlainDecode(clip: String, hardware: Bool) throws {
        let demuxer = Demuxer()
        try demuxer.open(url: Self.fixture(clip))
        defer { demuxer.close() }
        let index = demuxer.videoStreamIndex
        let stream = try #require(demuxer.stream(at: index))
        let tb = stream.pointee.time_base

        let reference: any VideoDecodingPipeline = hardware ? HardwareVideoDecoder() : SoftwareVideoDecoder()
        let referencePictures = OSAllocatedUnfairLock(initialState: [Int64: [[UInt8]]]())
        try reference.open(stream: stream) { buffer, pts, _ in
            let ms = Int64((pts.seconds * 1000).rounded())
            guard [500, 2000, 4000].contains(where: { abs($0 - ms) <= 21 }) else { return }
            let bytes = Self.planes(buffer)
            referencePictures.withLock { $0[ms] = bytes }
        }
        defer { reference.close() }

        let tap = OverlayDecodeTap(parameters: stream.pointee.codecpar, timeBase: tb,
                                   containerSAR: stream.pointee.sample_aspect_ratio, deinterlace: DeinterlaceConfig()) { _, _ in }
        defer { tap.close() }
        #expect(tap.decodesInHardware == hardware)
        var opensRun = true
        while let packet = try demuxer.readPacket() {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            defer { trackedPacketFree(&owned) }
            guard packet.pointee.stream_index == index else { continue }
            tap.keep(packet, opensRun: opensRun,
                     served: ServedVideoTime(pts: packet.pointee.pts, dts: packet.pointee.dts, timeBase: tb), shiftSeconds: 0)
            opensRun = false
            reference.decode(packet: packet, epoch: nil)
        }
        reference.drainForEndOfStream()

        for clock in [2.0, 4.0, 0.5] {
            tap.advance(to: clock)
            // The picture at the clock itself, within the window the reference keeps: one a frame earlier is the
            // right picture while the decoder is still a frame short, and has no reference to compare with.
            #expect(Self.waitUntil(10) { (tap.picture(atOrBefore: clock)?.seconds ?? -1) >= clock - 0.021 }, "clock \(clock)")
            let shown = try #require(tap.picture(atOrBefore: clock))
            let (picture, seconds) = (shown.picture, shown.seconds)
            let ms = Int64((seconds * 1000).rounded())
            let expected = try #require(referencePictures.withLock { $0.first { abs($0.key - ms) <= 1 }?.value },
                                        "a plain decode's picture at \(seconds)")
            #expect(Self.planes(picture) == expected, "clock \(clock)")
            // The decoder works a few pictures ahead of the clock and keeps no more behind it than the one shown: the
            // window, and the pictures still inside the decoder when its pictures reach the window (4 for dav1d, 5 for
            // VideoToolbox, measured on these clips), which come out after it.
            #expect(tap.held.decoded <= Int(OverlayDecodeTap.decodeAheadSeconds * 24) + 3 + 5,
                    "\(tap.held.decoded) pictures held")
        }
    }

    @Test("decoded pictures follow the clock; scanning shows AVPlayer's own frames")
    func pacing() throws {
        let par = try #require(avcodec_parameters_alloc())
        var owned: UnsafeMutablePointer<AVCodecParameters>? = par
        defer { avcodec_parameters_free(&owned) }
        par.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        par.pointee.codec_id = AV_CODEC_ID_AV1
        let tap = OverlayDecodeTap(parameters: par, timeBase: AVRational(num: 1, den: 1000),
                                   containerSAR: AVRational(num: 1, den: 1), deinterlace: DeinterlaceConfig()) { _, _ in }
        defer { tap.close() }
        let source = DecodedPictureSource(tap: tap)
        #expect(source.pacing(atRate: 0) == .clock)
        #expect(source.pacing(atRate: 1) == .clock)
        #expect(source.pacing(atRate: 2) == .clock)
        #expect(source.pacing(atRate: 8) == .showOutput)
        #expect(source.pacing(atRate: -1) == .showOutput)
    }
}
