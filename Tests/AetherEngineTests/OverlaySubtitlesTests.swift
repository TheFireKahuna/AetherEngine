import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

/// The overlay's Picture in Picture subtitles, drawn on the GPU into a copy of each picture: where white lands in each
/// coding (BT.2408 reference white: 203 nits PQ, 75% HLG; nominal peak in SDR), neutral chroma, the picture handed in
/// left as it was, and pictures handed back in order.
@Suite(.serialized)
struct OverlaySubtitlesTests {

    /// A black picture of `format` (codes in the format's own depth, high-aligned in 16-bit words above 8 bits).
    private func blackPicture(format: OSType, bits: Int, transfer: CFString, bt2020: Bool) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                           kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, format, attributes as CFDictionary, &made)
        let picture = try #require(made)
        CVBufferSetAttachment(picture, kCVImageBufferColorPrimariesKey,
                              bt2020 ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(picture, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(picture, kCVImageBufferYCbCrMatrixKey,
                              bt2020 ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        let shift = bits == 8 ? 0 : 16 - bits
        let black = 16 << (bits - 8), neutral = 128 << (bits - 8)
        CVPixelBufferLockBaseAddress(picture, [])
        for (plane, code) in [(0, black), (1, neutral)] {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(picture, plane))
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(picture, plane)
            let rows = CVPixelBufferGetHeightOfPlane(picture, plane)
            if bits == 8 {
                base.assumingMemoryBound(to: UInt8.self).update(repeating: UInt8(code), count: rowBytes * rows)
            } else {
                base.assumingMemoryBound(to: UInt16.self).update(repeating: UInt16(code << shift), count: rowBytes / 2 * rows)
            }
        }
        CVPixelBufferUnlockBaseAddress(picture, [])
        return picture
    }

    /// The codes at the middle of `picture`: luma, Cb, Cr, in the format's own depth.
    private func centreCodes(_ picture: CVPixelBuffer, bits: Int) throws -> (y: Int, cb: Int, cr: Int) {
        CVPixelBufferLockBaseAddress(picture, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(picture, [.readOnly]) }
        func sample(_ plane: Int, _ component: Int, _ count: Int) throws -> Int {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(picture, plane))
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(picture, plane)
            let row = CVPixelBufferGetHeightOfPlane(picture, plane) / 2, column = CVPixelBufferGetWidthOfPlane(picture, plane) / 2
            if bits == 8 { return Int(base.load(fromByteOffset: row * rowBytes + column * count + component, as: UInt8.self)) }
            let word = base.load(fromByteOffset: row * rowBytes + (column * count + component) * 2, as: UInt16.self)
            return Int(word) >> (16 - bits)
        }
        return (try sample(0, 0, 1), try sample(1, 0, 2), try sample(1, 1, 2))
    }

    private func whiteCue() throws -> SubtitleCue {
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let white = SubtitleImage(cgImage: try #require(context.makeImage()), position: CGRect(x: 0, y: 0, width: 1, height: 1))
        return SubtitleCue(id: 1, startTime: 10, endTime: 20, body: .image(white))
    }

    private func drawn(_ subtitles: OverlaySubtitles, on picture: CVPixelBuffer, at seconds: Double) async -> CVPixelBuffer {
        await withCheckedContinuation { continuation in
            let box = Box(picture)
            subtitles.draw(on: box.picture, atItemSeconds: seconds) { continuation.resume(returning: Box($0)) }
        }.picture
    }

    private struct Box: @unchecked Sendable {
        let picture: CVPixelBuffer
        init(_ picture: CVPixelBuffer) { self.picture = picture }
    }

    private func subtitles(cues: [SubtitleCue], shift: Double = 0) -> OverlaySubtitles {
        let subtitles = OverlaySubtitles(bufferAttributes: [:])
        subtitles.update(.init(active: true, cues: cues, delaySeconds: 0, sourceShift: shift))
        return subtitles
    }

    @Test("white over PQ and HLG 10-bit lands at reference white, chroma neutral, the picture handed in untouched",
          arguments: [(false, 573), (true, 721)])
    func hdrWhite(hlg: Bool, expected: Int) async throws {
        let transfer = hlg ? kCVImageBufferTransferFunction_ITU_R_2100_HLG : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        let picture = try blackPicture(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, bits: 10, transfer: transfer, bt2020: true)
        let out = await drawn(subtitles(cues: [try whiteCue()], shift: 5), on: picture, at: 10)
        #expect(out !== picture)
        let codes = try centreCodes(out, bits: 10)
        #expect(abs(codes.y - expected) <= 1, "luma \(codes.y), expected \(expected)")
        #expect(abs(codes.cb - 512) <= 1 && abs(codes.cr - 512) <= 1, "chroma \(codes.cb), \(codes.cr)")
        #expect(try centreCodes(picture, bits: 10).y == 64)
    }

    @Test("white over 16-bit 4:2:2 PQ (the FEL composer's sv22) lands at 203 nits")
    func sv22White() async throws {
        let picture = try blackPicture(format: kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange, bits: 16,
                                       transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, bt2020: true)
        let out = await drawn(subtitles(cues: [try whiteCue()]), on: picture, at: 15)
        let codes = try centreCodes(out, bits: 16)
        #expect(abs(codes.y - 573 * 64) <= 64, "luma \(codes.y)")
    }

    @Test("white over SDR 8-bit stays at nominal peak")
    func sdrWhite() async throws {
        let picture = try blackPicture(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, bits: 8,
                                       transfer: kCVImageBufferTransferFunction_ITU_R_709_2, bt2020: false)
        let out = await drawn(subtitles(cues: [try whiteCue()]), on: picture, at: 15)
        let codes = try centreCodes(out, bits: 8)
        #expect(codes.y == 235 && codes.cb == 128 && codes.cr == 128, "codes \(codes)")
    }

    @Test("a picture with no cue on it, or with the window down, comes back as it is")
    func noCue() async throws {
        let picture = try blackPicture(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, bits: 10,
                                       transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, bt2020: true)
        let active = subtitles(cues: [try whiteCue()])
        #expect(await drawn(active, on: picture, at: 25) === picture)
        let down = OverlaySubtitles(bufferAttributes: [:])
        down.update(.init(active: false, cues: [try whiteCue()], delaySeconds: 0, sourceShift: 0))
        #expect(await drawn(down, on: picture, at: 15) === picture)
    }

    @Test("pictures come back in the order they were handed in")
    func order() async throws {
        let picture = try blackPicture(format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, bits: 10,
                                       transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, bt2020: true)
        let subtitles = subtitles(cues: [try whiteCue()])
        let order = await withCheckedContinuation { (continuation: CheckedContinuation<[Int], Never>) in
            let seen = OrderLog()
            for (index, seconds) in [15.0, 25, 16, 26, 27].enumerated() {
                subtitles.draw(on: picture, atItemSeconds: seconds) { _ in
                    if seen.append(index) == 5 { continuation.resume(returning: seen.all) }
                }
            }
        }
        #expect(order == [0, 1, 2, 3, 4])
    }

    private final class OrderLog: @unchecked Sendable {
        private let lock = NSLock()
        private var indices: [Int] = []
        func append(_ index: Int) -> Int { lock.withLock { indices.append(index); return indices.count } }
        var all: [Int] { lock.withLock { indices } }
    }
}
