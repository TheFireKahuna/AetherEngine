import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import AetherEngine

/// The PiP compositor draws subtitles as an SDR overlay and lets CoreImage encode it into the
/// frame's own PQ or HLG space. Where SDR white lands is CoreImage's convention, not ours, so it
/// is read back here: BT.2408 reference white (203 nits PQ, 75% HLG), the level mpv uses for HDR
/// subtitles. Full-scale white would be 10,000 nits on PQ.
struct HDRSubtitleWhiteLevelTests {

    /// 10-bit video-range luma code of a white cue covering the whole frame, over black.
    private func compositedWhiteLuma(transfer: CFString) throws -> Int {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                            attrs as CFDictionary, &pb)
        let frame = try #require(pb)
        CVBufferSetAttachment(frame, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVBufferSetAttachment(frame, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        // Video-range black: luma 64, chroma 512, MSB-aligned in 16-bit words.
        CVPixelBufferLockBaseAddress(frame, [])
        for (plane, value) in [(0, UInt16(64 << 6)), (1, UInt16(512 << 6))] {
            let base = try #require(CVPixelBufferGetBaseAddressOfPlane(frame, plane)).assumingMemoryBound(to: UInt16.self)
            let count = CVPixelBufferGetBytesPerRowOfPlane(frame, plane) / 2 * CVPixelBufferGetHeightOfPlane(frame, plane)
            for i in 0..<count { base[i] = value }
        }
        CVPixelBufferUnlockBaseAddress(frame, [])

        let ctx = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let white = SubtitleImage(cgImage: try #require(ctx.makeImage()), position: CGRect(x: 0, y: 0, width: 1, height: 1))

        let compositor = SubtitleFrameCompositor()
        compositor.update(cues: [SubtitleCue(id: 1, startTime: 0, endTime: 10, body: .image(white))],
                          enabled: true, delaySeconds: 0)
        let out = compositor.composite(frame, ptsSeconds: 5)
        #expect(out !== frame)
        CVPixelBufferLockBaseAddress(out, [.readOnly])
        defer { CVPixelBufferUnlockBaseAddress(out, [.readOnly]) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(out, 0)).assumingMemoryBound(to: UInt16.self)
        return Int(luma[32 * CVPixelBufferGetBytesPerRowOfPlane(out, 0) / 2 + 32] >> 6)
    }

    /// SMPTE ST 2084 inverse EOTF: nits to a [0, 1] signal.
    private func pqSignal(nits: Double) -> Double {
        let m1 = 2610.0 / 16384, m2 = 2523.0 / 4096 * 128
        let c1 = 3424.0 / 4096, c2 = 2413.0 / 4096 * 32, c3 = 2392.0 / 4096 * 32
        let y = pow(nits / 10_000, m1)
        return pow((c1 + c2 * y) / (1 + c3 * y), m2)
    }

    private func videoRangeCode(_ signal: Double) -> Int {
        Int((64 + 876 * signal).rounded())
    }

    @Test("subtitle white on a PQ frame lands at BT.2408 reference white, 203 nits")
    func pqWhiteIsReferenceWhite() throws {
        let expected = videoRangeCode(pqSignal(nits: SubtitleFrameCompositor.hdrSubtitleWhitePQNits))
        #expect(expected == 573)
        let code = try compositedWhiteLuma(transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        #expect(abs(code - expected) <= 1, "PQ white luma code \(code), expected \(expected)")
    }

    @Test("subtitle white on an HLG frame lands at BT.2408's 75% signal")
    func hlgWhiteIsSeventyFivePercent() throws {
        let expected = videoRangeCode(SubtitleFrameCompositor.hdrSubtitleWhiteHLGSignal)
        #expect(expected == 721)
        let code = try compositedWhiteLuma(transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        #expect(abs(code - expected) <= 1, "HLG white luma code \(code), expected \(expected)")
    }

    @Test("subtitle white on an SDR frame stays at nominal peak")
    func sdrWhiteIsPeak() throws {
        let code = try compositedWhiteLuma(transfer: kCVImageBufferTransferFunction_ITU_R_709_2)
        #expect(abs(code - 940) <= 1, "SDR white luma code \(code)")
    }
}
