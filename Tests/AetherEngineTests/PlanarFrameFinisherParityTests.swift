import Foundation
import CoreVideo
import Metal
import Testing
import AetherLibavutil
import AetherLibswscale
@testable import AetherEngine

/// The GPU finisher against the CPU conversion it replaces, on random pictures: every format the decoder used to
/// convert with a plain shift and interleave (swscale's unscaled converters, the planar copy) plus the ordered
/// dither, word for word.
@Suite("Planar frame finisher matches the CPU conversion word for word")
struct PlanarFrameFinisherParityTests {

    /// Source format, colour range, whether the stream was declared 10-bit.
    static let cases: [(AVPixelFormat, AVColorRange, Bool)] = [
        (AV_PIX_FMT_YUV420P, AVCOL_RANGE_MPEG, false),
        (AV_PIX_FMT_YUV420P, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUVJ420P, AVCOL_RANGE_JPEG, false),
        (AV_PIX_FMT_YUV420P10LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV420P12LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV422P, AVCOL_RANGE_MPEG, false),
        (AV_PIX_FMT_YUV444P, AVCOL_RANGE_MPEG, false),
        (AV_PIX_FMT_YUV422P10LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV444P10LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV422P12LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV444P12LE, AVCOL_RANGE_MPEG, true),
        (AV_PIX_FMT_YUV422P12LE, AVCOL_RANGE_JPEG, true),
    ]

    @Test("GPU output equals the CPU conversion", arguments: cases.indices, [(66, 34), (35, 9), (64, 16), (1920, 1080)])
    func parity(_ index: Int, _ size: (Int, Int)) throws {
        let (src, range, declared10) = Self.cases[index]
        let (width, height) = size
        let device = try #require(MTLCreateSystemDefaultDevice())
        let allocator = try #require(DecodeFrameAllocator(device: device))
        let finisher = try PlanarFrameFinisher(device: device)

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = Int32(width); f.pointee.height = Int32(height); f.pointee.format = src.rawValue
        f.pointee.color_range = range
        #expect(av_frame_get_buffer(f, 0) >= 0)
        let desc = try #require(av_pix_fmt_desc_get(src)).pointee
        let depth = Int(desc.comp.0.depth), wide = desc.comp.0.step == 2
        var rng = SystemRandomNumberGenerator()
        let planes = [f.pointee.data.0, f.pointee.data.1, f.pointee.data.2]
        let strides = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2]
        for p in 0..<3 {
            let base = try #require(planes[p])
            let rows = p == 0 ? height : (height + (1 << Int(desc.log2_chroma_h)) - 1) >> Int(desc.log2_chroma_h)
            for i in 0..<(Int(strides[p]) * rows / (wide ? 2 : 1)) {
                let value = Int.random(in: 0..<(1 << depth), using: &rng)
                if wide { UnsafeMutableRawPointer(base).storeBytes(of: UInt16(value), toByteOffset: 2 * i, as: UInt16.self) }
                else { base[i] = UInt8(value) }
            }
        }

        let format = SoftwareVideoDecoder.outputFormat(pixelFormat: src.rawValue, colorRange: range, streamIs10Bit: declared10)
        func buffer() throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let attrs: NSDictionary = [kCVPixelBufferMetalCompatibilityKey: true,
                                       kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()]
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, format.pixelFormatType, attrs, &pb)
            return try #require(pb)
        }

        // CPU: what convertFrameToPixelBuffer runs.
        let reference = try buffer()
        CVPixelBufferLockBaseAddress(reference, [])
        let dst = format.swscaleFormat
        if let shift = SoftwareVideoDecoder.directCopyShift(source: src, destination: dst) {
            SoftwareVideoDecoder.copyPlanarToBiPlanar(f, into: reference, shift: shift)
        } else {
            let setup = SoftwareVideoDecoder.SwscaleSetup(
                width: Int32(width), height: Int32(height), source: src, destination: dst,
                sourceFullRange: range == AVCOL_RANGE_JPEG || SoftwareVideoDecoder.isJPEGFormat(src),
                destinationFullRange: format.fullRange, colorspace: SWS_CS_ITU709)
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
        }
        if format.dithers { SoftwareVideoDecoder.ditherTo10Bit(reference) }
        CVPixelBufferUnlockBaseAddress(reference, [])

        // GPU.
        let gpu = try buffer()
        let copied = try #require(allocator.copy(f))
        defer { allocator.release(copied.slab) }
        let plan = try #require(PlanarFrameFinisher.plan(source: src, output: format, chromaLocation: AVCHROMA_LOC_LEFT,
                                                         matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        #expect(finisher.finish(copied, plan: plan, width: width, height: height, into: gpu))

        CVPixelBufferLockBaseAddress(gpu, .readOnly); CVPixelBufferLockBaseAddress(reference, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(gpu, .readOnly); CVPixelBufferUnlockBaseAddress(reference, .readOnly) }
        let sampleBytes = format.depth == .eight ? 1 : 2
        // swscale's 4:2:0 16-bit writers stop at width / 2 chroma samples (planarToP01xWrapper), one short of the
        // plane on an odd width; the GPU writes the whole plane. Compared where both write.
        let swscaleShortChroma = desc.log2_chroma_w == 1 && desc.log2_chroma_h == 1 && sampleBytes == 2 && width % 2 == 1
        for plane in 0..<2 {
            var samples = CVPixelBufferGetWidthOfPlane(gpu, plane)
            if plane == 1, swscaleShortChroma { samples = width / 2 }
            let rowBytes = samples * (plane == 0 ? 1 : 2) * sampleBytes
            let a = try #require(CVPixelBufferGetBaseAddressOfPlane(gpu, plane))
            let b = try #require(CVPixelBufferGetBaseAddressOfPlane(reference, plane))
            var mismatches = 0
            for y in 0..<CVPixelBufferGetHeightOfPlane(gpu, plane) {
                let ra = a + y * CVPixelBufferGetBytesPerRowOfPlane(gpu, plane)
                let rb = b + y * CVPixelBufferGetBytesPerRowOfPlane(reference, plane)
                if memcmp(ra, rb, rowBytes) != 0 { mismatches += 1 }
            }
            #expect(mismatches == 0, "\(String(cString: av_get_pix_fmt_name(src))) -> \(format.logDescription) plane \(plane) \(width)x\(height): \(mismatches) rows differ")
        }
    }
}
