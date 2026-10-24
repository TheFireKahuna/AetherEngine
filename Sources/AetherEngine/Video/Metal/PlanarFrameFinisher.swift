import Foundation
import Metal
import CoreVideo
import os
import AetherLibavutil

/// The one pass between a software decoder and the display: a decoded picture, already in GPU-visible memory
/// (``DecodeFrameAllocator``), written by the GPU into a bi-planar display buffer (NV12 / P010 / NV16 / P210 /
/// P216 / NV24 / P410 / P416, the formats `SoftwareVideoDecoder.OutputFormat` names).
///
/// The source is read the way `av_read_image_line2` reads it, from the format's `AVPixFmtDescriptor`, so one
/// reader covers planar, semi-planar and packed YCbCr, grey, planar and packed RGB, palette, bitstream and
/// big-endian layouts. What happens to the samples:
/// - Y'CbCr with the output's chroma subsampling: each sample shifted up to the output depth, chroma
///   interleaved. Exactly the words the decoder's former CPU conversion wrote (swscale's unscaled converters
///   and the planar copy are that shift and interleave).
/// - Y'CbCr with less chroma than the output keeps (4:2:0 into `sv22`, 4:1:1, 4:1:0, 4:4:0): chroma resampled
///   with Catmull-Rom at the stream's chroma siting, in source units, then raised to the output depth.
/// - Grey: luma raised, chroma neutral.
/// - RGB and palette: converted to Y'CbCr with the matrix the buffer is tagged with, at 4:4:4.
/// - A source deeper than the 10 bits the output keeps: the 16-bit word ordered down to 10 bits with the 8x8
///   Bayer threshold (`PF_DITHER`).
///
/// A format the plan cannot describe is refused (``plan(source:output:chromaLocation:matrix:)`` returns nil):
/// hardware formats, Bayer, float and XYZ samples, and grey or Y'CbCr below 8 bits per sample.
final class PlanarFrameFinisher: @unchecked Sendable {

    /// What one source format means for the kernels, decided once per format.
    struct Plan: Equatable {
        static let rgb: UInt32 = 1, bigEndian: UInt32 = 2, bitstream: UInt32 = 4, palette: UInt32 = 8
        static let gray: UInt32 = 16, dither: UInt32 = 32

        var flags: UInt32
        var precision: UInt32
        var containerShift: UInt32
        var sourceLog2: (w: UInt32, h: UInt32)
        var outputLog2: (w: UInt32, h: UInt32)
        var chromaLocation: UInt32
        /// plane, step, offset, shift, depth per component.
        var components: [[UInt32]]
        var rgbRows: [Float]
        var wideOutput: Bool

        static func == (a: Plan, b: Plan) -> Bool {
            a.flags == b.flags && a.precision == b.precision && a.containerShift == b.containerShift
                && a.sourceLog2 == b.sourceLog2 && a.outputLog2 == b.outputLog2 && a.chromaLocation == b.chromaLocation
                && a.components == b.components && a.rgbRows == b.rgbRows && a.wideOutput == b.wideOutput
        }
    }

    /// Byte offsets and linesizes of a picture's planes inside a slab.
    struct Planes {
        var slab: DecodeFrameAllocator.Slab
        var offsets: [UInt32]
        var linesizes: [UInt32]
    }

    /// The plan for `source` written as `output`, or nil when the reader cannot describe the format.
    /// `chromaLocation` is the frame's, UNSPECIFIED already resolved; `matrix` the buffer's tagged Y'CbCr matrix.
    static func plan(source: AVPixelFormat, output: SoftwareVideoDecoder.OutputFormat,
                     chromaLocation: AVChromaLocation, matrix: CFString) -> Plan? {
        guard let desc = av_pix_fmt_desc_get(source)?.pointee, desc.nb_components > 0 else { return nil }
        let refused = UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_BAYER) | UInt64(AV_PIX_FMT_FLAG_FLOAT)
            | UInt64(AV_PIX_FMT_FLAG_XYZ)
        guard desc.flags & refused == 0 else { return nil }
        let comps = withUnsafeBytes(of: desc.comp) { Array($0.bindMemory(to: AVComponentDescriptor.self)) }
        let isPalette = desc.flags & UInt64(AV_PIX_FMT_FLAG_PAL) != 0
        let isRGB = !isPalette && desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        let isGray = !isPalette && !isRGB && desc.nb_components < 3

        let precision: UInt32
        let containerShift: UInt32
        switch output.depth {
        case .eight: precision = 8; containerShift = 0
        case .ten: precision = output.dithers ? 16 : 10; containerShift = output.dithers ? 0 : 6
        case .sixteen: precision = 16; containerShift = 0
        }
        let used = isPalette ? 1 : (isRGB ? 3 : (isGray ? 1 : 3))
        for c in comps.prefix(used) {
            // Y'CbCr and grey are scaled by shifting, which needs at least 8 bits to mean the same code values.
            guard c.depth >= 1, c.depth <= 16, isRGB || isPalette || (c.depth >= 8 && UInt32(c.depth) <= precision)
            else { return nil }
        }

        let outLog2: (w: UInt32, h: UInt32) = switch output.chroma {
        case .yuv420: (1, 1)
        case .yuv422: (1, 0)
        case .yuv444: (0, 0)
        }
        let srcLog2 = (w: UInt32(desc.log2_chroma_w), h: UInt32(desc.log2_chroma_h))
        if isRGB || isPalette {
            guard outLog2 == (0, 0) else { return nil }
        } else if !isGray {
            // Only ever upsampled: the output keeps at least the source's chroma on each axis.
            guard outLog2.w <= srcLog2.w, outLog2.h <= srcLog2.h else { return nil }
        }

        var flags: UInt32 = 0
        if isRGB { flags |= Plan.rgb }
        if isPalette { flags |= Plan.palette }
        if isGray { flags |= Plan.gray }
        if desc.flags & UInt64(AV_PIX_FMT_FLAG_BE) != 0 { flags |= Plan.bigEndian }
        if desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) != 0 { flags |= Plan.bitstream }
        if output.dithers { flags |= Plan.dither }

        return Plan(
            flags: flags, precision: precision, containerShift: containerShift,
            sourceLog2: isGray || isRGB || isPalette ? outLog2 : srcLog2, outputLog2: outLog2,
            chromaLocation: UInt32(chromaLocation.rawValue),
            components: (0..<4).map { i in
                let c = comps[i]
                return [UInt32(c.plane), UInt32(c.step), UInt32(c.offset), UInt32(c.shift), UInt32(c.depth)]
            },
            rgbRows: isRGB || isPalette ? rgbRows(matrix: matrix, precision: precision, fullRange: output.fullRange) : [Float](repeating: 0, count: 12),
            wideOutput: output.depth != .eight)
    }

    /// Y', Cb, Cr rows (coefficients for R, G, B in [0, 1], then the offset) at `precision` bits.
    static func rgbRows(matrix: CFString, precision: UInt32, fullRange: Bool) -> [Float] {
        let (kr, kb): (Float, Float) = switch matrix {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: (0.299, 0.114)
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: (0.2627, 0.0593)
        case kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: (0.212, 0.087)
        default: (0.2126, 0.0722)
        }
        let kg = 1 - kr - kb
        let scale = Float(1 << precision) / 256
        let (ySpan, yFloor, cSpan): (Float, Float, Float) = fullRange
            ? (Float((1 << precision) - 1), 0, Float((1 << precision) - 1))
            : (219 * scale, 16 * scale, 224 * scale)
        let cMid = Float(1 << (precision - 1))
        let cb = [-kr / (2 * (1 - kb)), -kg / (2 * (1 - kb)), 0.5]
        let cr = [0.5, -kg / (2 * (1 - kr)), -kb / (2 * (1 - kr))]
        return [kr * ySpan, kg * ySpan, kb * ySpan, yFloor]
            + cb.map { $0 * cSpan } + [cMid]
            + cr.map { $0 * cSpan } + [cMid]
    }

    /// The planes of `frame` inside `slab` (one this allocator made, so every plane is in it).
    static func planes(of frame: UnsafePointer<AVFrame>, in slab: DecodeFrameAllocator.Slab) -> Planes? {
        var offsets = [UInt32](repeating: 0, count: 4), linesizes = [UInt32](repeating: 0, count: 4)
        let data = withUnsafeBytes(of: frame.pointee.data) { Array($0.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).prefix(4)) }
        let sizes = withUnsafeBytes(of: frame.pointee.linesize) { Array($0.bindMemory(to: Int32.self).prefix(4)) }
        for i in 0..<4 {
            guard let pointer = data[i] else { continue }
            guard sizes[i] > 0, let offset = slab.offset(of: pointer) else { return nil }
            offsets[i] = UInt32(offset)
            linesizes[i] = UInt32(sizes[i])
        }
        return Planes(slab: slab, offsets: offsets, linesizes: linesizes)
    }

    // MARK: - Metal

    private struct Pipelines {
        let luma: MTLComputePipelineState
        let chroma: MTLComputePipelineState
    }

    private static let compiled = OSAllocatedUnfairLock<[ObjectIdentifier: Pipelines]>(initialState: [:])

    private static func pipelines(for device: MTLDevice) throws -> Pipelines {
        let key = ObjectIdentifier(device)
        if let ready = compiled.withLock({ $0[key] }) { return ready }
        let library = try device.makeLibrary(source: PlanarFrameShaderSource.source, options: nil)
        guard let luma = library.makeFunction(name: "pf_luma"), let chroma = library.makeFunction(name: "pf_chroma_kernel")
        else { throw FinisherError.missingKernel }
        let made = Pipelines(luma: try device.makeComputePipelineState(function: luma),
                             chroma: try device.makeComputePipelineState(function: chroma))
        compiled.withLock { $0[key] = made }
        return made
    }

    enum FinisherError: Error { case missingKernel }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FinisherError.missingKernel }
        self.queue = queue
        pipelines = try Self.pipelines(for: device)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw FinisherError.missingKernel }
        textureCache = cache
    }

    /// Writes the `width` x `height` picture in `planes` into `buffer` (a bi-planar buffer of `plan`'s output format)
    /// and waits for the GPU. False when a texture cannot be made for the buffer or the GPU reports an error.
    func finish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer) -> Bool {
        let wide = plan.wideOutput
        guard let luma = texture(buffer, plane: 0, format: wide ? .r16Uint : .r8Uint),
              let chroma = texture(buffer, plane: 1, format: wide ? .rg16Uint : .rg8Uint),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else { return false }

        var words: [UInt32] = [
            UInt32(width), UInt32(height), UInt32(chromaTexture.width), UInt32(chromaTexture.height),
            plan.sourceLog2.w, plan.sourceLog2.h, plan.outputLog2.w, plan.outputLog2.h,
            plan.flags, plan.precision, plan.containerShift, plan.chromaLocation,
        ]
        words += plan.components.flatMap { $0 }
        words += planes.offsets + planes.linesizes
        words += plan.rgbRows.map(\.bitPattern)

        encoder.setBuffer(planes.slab.buffer, offset: 0, index: 0)
        words.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setComputePipelineState(pipelines.luma)
        encoder.setTexture(lumaTexture, index: 0)
        dispatch(encoder, pipelines.luma, width: width, height: height)
        encoder.setComputePipelineState(pipelines.chroma)
        encoder.setTexture(chromaTexture, index: 0)
        dispatch(encoder, pipelines.chroma, width: chromaTexture.width, height: chromaTexture.height)
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((luma, chroma, planes.slab)) {}
        return commands.status == .completed
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane), CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture
        ) == kCVReturnSuccess else { return nil }
        return texture
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
