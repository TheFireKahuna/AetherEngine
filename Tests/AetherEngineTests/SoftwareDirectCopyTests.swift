import Foundation
import CoreVideo
import Testing
import AetherLibavutil
import AetherLibswscale
@testable import AetherEngine

/// #8: planar 4:2:2 / 4:4:4 into the bi-planar format with the same subsampling is a shift and an
/// interleave, which swscale has no unscaled converter for (it runs its full vertical scaler at the
/// identity size, 5-15 ms per 4K frame). The decoder does that copy itself; it has to produce exactly
/// the words swscale would.
@Suite("Software decoder direct planar to bi-planar copy (#8)")
struct SoftwareDirectCopyTests {

    @Test("only same-subsampling 4:2:2 / 4:4:4 planar YCbCr of the same sample size qualifies")
    func eligibility() {
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV422P, destination: AV_PIX_FMT_NV16) == 0)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV444P, destination: AV_PIX_FMT_NV24) == 0)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV422P10LE, destination: AV_PIX_FMT_P210LE) == 6)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV444P10LE, destination: AV_PIX_FMT_P410LE) == 6)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV422P12LE, destination: AV_PIX_FMT_P216LE) == 4)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUVJ422P, destination: AV_PIX_FMT_NV16) == 0)
        // swscale's own unscaled converters cover 4:2:0.
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV420P, destination: AV_PIX_FMT_NV12) == nil)
        // A real conversion: resampled chroma, RGB, a widened sample, big-endian input.
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV420P12LE, destination: AV_PIX_FMT_P216LE) == nil)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV411P, destination: AV_PIX_FMT_NV16) == nil)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_GBRP, destination: AV_PIX_FMT_NV24) == nil)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV422P, destination: AV_PIX_FMT_P210LE) == nil)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUV422P10BE, destination: AV_PIX_FMT_P210LE) == nil)
        #expect(SoftwareVideoDecoder.directCopyShift(source: AV_PIX_FMT_YUVA444P10LE, destination: AV_PIX_FMT_P410LE) == nil)
    }

    static let pairs: [(AVPixelFormat, AVPixelFormat, OSType)] = [
        (AV_PIX_FMT_YUV422P, AV_PIX_FMT_NV16, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange),
        (AV_PIX_FMT_YUV444P, AV_PIX_FMT_NV24, kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange),
        (AV_PIX_FMT_YUV422P10LE, AV_PIX_FMT_P210LE, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange),
        (AV_PIX_FMT_YUV444P10LE, AV_PIX_FMT_P410LE, kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange),
        (AV_PIX_FMT_YUV422P12LE, AV_PIX_FMT_P216LE, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange),
        (AV_PIX_FMT_YUV444P12LE, AV_PIX_FMT_P416LE, kCVPixelFormatType_444YpCbCr16BiPlanarVideoRange),
    ]

    @Test("the copy is word for word what swscale writes, odd sizes and row tails included",
          arguments: pairs.indices, [(66, 34), (35, 9), (64, 16)])
    func matchesSwscale(_ index: Int, _ size: (Int, Int)) throws {
        let (src, dst, type) = Self.pairs[index]
        let (width, height) = size
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = Int32(width); f.pointee.height = Int32(height); f.pointee.format = src.rawValue
        #expect(av_frame_get_buffer(f, 0) >= 0)
        let desc = try #require(av_pix_fmt_desc_get(src)).pointee
        let depth = Int(desc.comp.0.depth), wide = desc.comp.0.step == 2
        var rng = SystemRandomNumberGenerator()
        let planes = [f.pointee.data.0, f.pointee.data.1, f.pointee.data.2]
        let strides = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2]
        for p in 0..<3 {
            let base = try #require(planes[p])
            for i in 0..<(Int(strides[p]) * height / (wide ? 2 : 1)) {
                let value = Int.random(in: 0..<(1 << depth), using: &rng)
                if wide { UnsafeMutableRawPointer(base).storeBytes(of: UInt16(value), toByteOffset: 2 * i, as: UInt16.self) }
                else { base[i] = UInt8(value) }
            }
        }

        func buffer() throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, type, nil, &pb)
            return try #require(pb)
        }
        let direct = try buffer(), reference = try buffer()
        CVPixelBufferLockBaseAddress(direct, []); CVPixelBufferLockBaseAddress(reference, [])
        defer { CVPixelBufferUnlockBaseAddress(direct, []); CVPixelBufferUnlockBaseAddress(reference, []) }

        let shift = try #require(SoftwareVideoDecoder.directCopyShift(source: src, destination: dst))
        SoftwareVideoDecoder.copyPlanarToBiPlanar(f, into: direct, shift: shift)

        let setup = SoftwareVideoDecoder.SwscaleSetup(
            width: Int32(width), height: Int32(height), source: src, destination: dst,
            sourceFullRange: false, destinationFullRange: false, colorspace: SWS_CS_ITU709)
        let ctx = try #require(setup.makeContext())
        defer { sws_freeContext(ctx) }
        var dstData: [UnsafeMutablePointer<UInt8>?] = [
            CVPixelBufferGetBaseAddressOfPlane(reference, 0)?.assumingMemoryBound(to: UInt8.self),
            CVPixelBufferGetBaseAddressOfPlane(reference, 1)?.assumingMemoryBound(to: UInt8.self), nil, nil]
        var dstStride: [Int32] = [Int32(CVPixelBufferGetBytesPerRowOfPlane(reference, 0)),
                                  Int32(CVPixelBufferGetBytesPerRowOfPlane(reference, 1)), 0, 0]
        withUnsafePointer(to: &f.pointee.data) { sp in
            withUnsafePointer(to: &f.pointee.linesize) { sl in
                _ = sws_scale(ctx, UnsafeRawPointer(sp).assumingMemoryBound(to: UnsafePointer<UInt8>?.self),
                              UnsafeRawPointer(sl).assumingMemoryBound(to: Int32.self), 0, Int32(height),
                              &dstData, &dstStride)
            }
        }

        for plane in 0..<2 {
            let rowBytes = CVPixelBufferGetWidthOfPlane(direct, plane) * (plane == 0 ? 1 : 2) * (wide ? 2 : 1)
            let a = try #require(CVPixelBufferGetBaseAddressOfPlane(direct, plane))
            let b = try #require(CVPixelBufferGetBaseAddressOfPlane(reference, plane))
            var mismatches = 0
            for y in 0..<CVPixelBufferGetHeightOfPlane(direct, plane) {
                let ra = a + y * CVPixelBufferGetBytesPerRowOfPlane(direct, plane)
                let rb = b + y * CVPixelBufferGetBytesPerRowOfPlane(reference, plane)
                if memcmp(ra, rb, rowBytes) != 0 { mismatches += 1 }
            }
            #expect(mismatches == 0, "\(String(cString: av_get_pix_fmt_name(dst))) plane \(plane) \(width)x\(height)")
        }
    }
}
