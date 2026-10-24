import CoreGraphics
import CoreVideo
import Metal
import Testing
import AetherLibavutil
@testable import AetherEngine

/// A still is the display buffer playback shows, scaled and mapped on the GPU (docs/software-route-gpu.md Part 7):
/// a software picture through ``DisplayBufferWriter`` and ``StillRenderer``, read back as the image's own codes.
struct StillColorspaceTests {

    /// One flat picture of `format` with the given code values and colour tags.
    private func picture(_ format: AVPixelFormat, width: Int32, height: Int32, y: UInt8, cb: UInt8, cr: UInt8,
                         primaries: AVColorPrimaries = AVCOL_PRI_UNSPECIFIED,
                         transfer: AVColorTransferCharacteristic = AVCOL_TRC_UNSPECIFIED,
                         matrix: AVColorSpace = AVCOL_SPC_UNSPECIFIED,
                         range: AVColorRange = AVCOL_RANGE_MPEG) throws -> UnsafeMutablePointer<AVFrame> {
        let f = try #require(av_frame_alloc())
        f.pointee.format = format.rawValue
        f.pointee.width = width
        f.pointee.height = height
        f.pointee.color_primaries = primaries
        f.pointee.color_trc = transfer
        f.pointee.colorspace = matrix
        f.pointee.color_range = range
        #expect(av_frame_get_buffer(f, 0) == 0)
        let planes = [(f.pointee.data.0, f.pointee.linesize.0, y), (f.pointee.data.1, f.pointee.linesize.1, cb),
                      (f.pointee.data.2, f.pointee.linesize.2, cr)]
        for (index, (data, linesize, value)) in planes.enumerated() {
            let rows = index == 0 ? Int(height) : Int(height + 1) / 2
            memset(try #require(data), Int32(value), Int(linesize) * rows)
        }
        return f
    }

    /// The still's code values at its centre, read in the image's own colour space (no conversion).
    private func centre(of frame: UnsafeMutablePointer<AVFrame>, width: Int = 64, height: Int = 36) throws
        -> (r: Int, g: Int, b: Int, space: CGColorSpace?) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let writer = try DisplayBufferWriter(device: device, streamIs10Bit: false, twelveBit420: .p010Dithered,
                                             containerHDRStatic: .none, logTag: "test")
        let buffer = try #require(writer.finish(frame))
        let image = try #require(StillRenderer().image(buffer, width: width, height: height))
        let space = try #require(image.colorSpace)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let at = ((height / 2) * width + width / 2) * 4
        return (Int(pixels[at]), Int(pixels[at + 1]), Int(pixels[at + 2]), image.colorSpace)
    }

    private func expectRed(_ c: (r: Int, g: Int, b: Int, space: CGColorSpace?), _ comment: Comment) {
        #expect(c.r >= 250 && c.g <= 6 && c.b <= 6, "\(comment): \(c.r),\(c.g),\(c.b)")
    }

    @Test("A BT.709 still is converted with the BT.709 matrix")
    func bt709() throws {
        var f: UnsafeMutablePointer<AVFrame>? = try picture(AV_PIX_FMT_YUV420P, width: 1920, height: 1080,
                                                            y: 63, cb: 102, cr: 240, primaries: AVCOL_PRI_BT709,
                                                            transfer: AVCOL_TRC_BT709, matrix: AVCOL_SPC_BT709)
        defer { av_frame_free(&f) }
        expectRed(try centre(of: f!), "BT.709 red")
    }

    @Test("An untagged still takes playback's guess: BT.709 for HD, BT.601 for SD (#6, AE#654)")
    func untaggedFollowsPlayback() throws {
        var hd: UnsafeMutablePointer<AVFrame>? = try picture(AV_PIX_FMT_YUV420P, width: 1920, height: 1080,
                                                             y: 63, cb: 102, cr: 240)
        defer { av_frame_free(&hd) }
        expectRed(try centre(of: hd!), "untagged HD, BT.709 red")
        var sd: UnsafeMutablePointer<AVFrame>? = try picture(AV_PIX_FMT_YUV420P, width: 720, height: 480,
                                                             y: 81, cb: 90, cr: 240)
        defer { av_frame_free(&sd) }
        expectRed(try centre(of: sd!, width: 64, height: 48), "untagged SD, BT.601 red")
    }

    @Test("Full range is read from the JPEG pixel formats")
    func fullRange() throws {
        var f: UnsafeMutablePointer<AVFrame>? = try picture(AV_PIX_FMT_YUVJ420P, width: 720, height: 480,
                                                            y: 76, cb: 85, cr: 255, range: AVCOL_RANGE_UNSPECIFIED)
        defer { av_frame_free(&f) }
        expectRed(try centre(of: f!, width: 64, height: 48), "full-range BT.601 red")
    }

    @Test("An HDR still is BT.709 SDR")
    func hdrToSDR() throws {
        var f: UnsafeMutablePointer<AVFrame>? = try picture(AV_PIX_FMT_YUV420P, width: 1920, height: 1080,
                                                            y: 128, cb: 128, cr: 128, primaries: AVCOL_PRI_BT2020,
                                                            transfer: AVCOL_TRC_SMPTE2084, matrix: AVCOL_SPC_BT2020_NCL)
        defer { av_frame_free(&f) }
        let c = try centre(of: f!)
        // BT.709 (CoreVideo's buffers map to CoreMedia's own BT.709 space), not PQ.
        #expect((c.space?.name as String?)?.contains("709") == true, "\(String(describing: c.space?.name))")
        // Neutral grey stays neutral through the tone map.
        #expect(abs(c.r - c.g) <= 2 && abs(c.g - c.b) <= 2 && c.r > 0, "\(c.r),\(c.g),\(c.b)")
    }
}
