import Foundation
import Metal
import CoreVideo
import os
import AetherLibavutil

/// The one pass between a software decoder and the display: a decoded picture, already in GPU-visible memory
/// (``DecodeFrameAllocator``), written by the GPU into a bi-planar display buffer (NV12 / P010 / NV16 / P210 /
/// P216 / NV24 / P410 / P416, the formats `SoftwareVideoDecoder.OutputFormat` names). The equations are
/// docs/colour-representation.md's, from H.273.
///
/// The source is read the way `av_read_image_line2` reads it, from the format's `AVPixFmtDescriptor`, so one
/// reader covers planar, semi-planar and packed Y'CbCr, grey, planar and packed RGB, palette, bitstream and
/// big-endian layouts. Per path:
/// - Y'CbCr with the output's chroma subsampling: each code taken to the output depth (a shift at video range,
///   H.273's (2^n - 1) scaling at full range).
/// - Y'CbCr with less chroma than the output keeps (4:2:0 into `sv22`, 4:1:1, 4:1:0, 4:4:0): chroma resampled
///   with Catmull-Rom at the stream's chroma siting, in source units, then taken to the output depth.
/// - Grey: luma taken to the output depth, chroma neutral (`1 << (n - 1)`).
/// - RGB and palette: R'G'B' codes decoded at their range (H.273 (27)-(29), (33)-(35)) and encoded as
///   non-constant-luminance Y'CbCr with the matrix the buffer is tagged with, 4:4:4.
/// - A source deeper than the 10 bits the output keeps: the value formed with six fraction bits and ordered
///   down with the 8x8 Bayer threshold.
///
/// Each source format gets its own specialised pipeline (function constants), compiled once per process.
final class PlanarFrameFinisher: @unchecked Sendable {

    enum Mode: UInt32 { case pack = 0, resample = 1, gray = 2, rgb = 3 }

    /// What one source format means for the kernel. Everything but `rgbRows` is a function constant.
    struct Plan: Hashable {
        var mode: Mode
        var outputLog2: [UInt32]
        var sourceLog2: [UInt32]
        /// plane, step, offset, shift, depth of components 0...2.
        var components: [[UInt32]]
        var bigEndian: Bool
        var bitstream: Bool
        var palette: Bool
        var fullRange: Bool
        var targetBits: UInt32
        var fractionBits: UInt32
        var containerShift: UInt32
        var chromaLocation: UInt32
        var wideOutput: Bool
        /// RGB: output code (with the fraction bits) per R, G, B code, then the offset, in 2^-30 fixed point; 12 values.
        var rgbRows: [Int64]
        /// Bytes a component load reads, per plane: plane offsets and linesizes must be multiples of it.
        var planeAlignment: [Int]

        static func == (a: Plan, b: Plan) -> Bool { a.specialisation == b.specialisation && a.rgbRows == b.rgbRows }
        func hash(into hasher: inout Hasher) { hasher.combine(specialisation); hasher.combine(rgbRows) }

        /// The function constants, in index order.
        var specialisation: [UInt32] {
            [mode.rawValue] + outputLog2 + sourceLog2 + components.flatMap { $0 }
                + [bigEndian ? 1 : 0, bitstream ? 1 : 0, palette ? 1 : 0, fullRange ? 1 : 0,
                   targetBits, fractionBits, containerShift, chromaLocation]
        }
    }

    /// Byte offsets and linesizes of a picture's planes inside a slab.
    struct Planes {
        var slab: DecodeFrameAllocator.Slab
        var offsets: [UInt32]
        var linesizes: [UInt32]
    }

    /// Whether the reader can describe `format` at all (checked once, when the decoder opens).
    static func reads(_ format: AVPixelFormat) -> Bool {
        guard let desc = av_pix_fmt_desc_get(format)?.pointee, desc.nb_components > 0 else { return false }
        let refused = UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_BAYER) | UInt64(AV_PIX_FMT_FLAG_FLOAT)
            | UInt64(AV_PIX_FMT_FLAG_XYZ)
        guard desc.flags & refused == 0 else { return false }
        let isPalette = desc.flags & UInt64(AV_PIX_FMT_FLAG_PAL) != 0
        let isRGB = !isPalette && desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        let comps = components(desc)
        if isPalette { return true }
        let used = isRGB || desc.nb_components >= 3 ? 3 : 1
        // Y'CbCr and grey codes are defined from 8 bits up (H.273 (30)-(38) notes 1, 2).
        return comps.prefix(used).allSatisfy { $0.depth >= (isRGB ? 1 : 8) && $0.depth <= 16 }
    }

    /// The plan for `source` written as `output`, or nil when the reader cannot describe the format or the output
    /// cannot hold it. `chromaLocation` is the frame's, UNSPECIFIED already resolved; `sourceFullRange` the
    /// frame's range (for RGB: whether its codes are full range); `matrix` the buffer's tagged Y'CbCr matrix.
    /// An interlaced picture is never resampled vertically: its chroma rows alternate between the two fields.
    static func plan(source: AVPixelFormat, output: SoftwareVideoDecoder.OutputFormat, sourceFullRange: Bool,
                     chromaLocation: AVChromaLocation, matrix: CFString, interlaced: Bool = false) -> Plan? {
        guard reads(source), let desc = av_pix_fmt_desc_get(source)?.pointee else { return nil }
        let comps = components(desc)
        let isPalette = desc.flags & UInt64(AV_PIX_FMT_FLAG_PAL) != 0
        let isRGB = !isPalette && desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0
        let isGray = !isPalette && !isRGB && desc.nb_components < 3

        let (targetBits, fractionBits, containerShift): (UInt32, UInt32, UInt32) = switch output.depth {
        case .eight: (8, 0, 0)
        case .ten: output.dithers ? (10, 6, 0) : (10, 0, 6)
        case .sixteen: (16, 0, 0)
        }
        let outLog2: [UInt32] = switch output.chroma {
        case .yuv420: [1, 1]
        case .yuv422: [1, 0]
        case .yuv444: [0, 0]
        }
        let srcLog2 = [UInt32(desc.log2_chroma_w), UInt32(desc.log2_chroma_h)]

        let mode: Mode
        if isRGB || isPalette {
            guard outLog2 == [0, 0] else { return nil }
            mode = .rgb
        } else if isGray {
            mode = .gray
        } else {
            guard outLog2[0] <= srcLog2[0], outLog2[1] <= srcLog2[1], !interlaced || outLog2[1] == srcLog2[1] else { return nil }
            mode = outLog2 == srcLog2 ? .pack : .resample
        }
        // A code is only ever widened: the output's significant bits plus its fraction bits hold every source bit.
        if mode != .rgb {
            let used = mode == .gray ? 1 : 3
            guard comps.prefix(used).allSatisfy({ UInt32($0.depth) <= targetBits + fractionBits }) else { return nil }
        }

        let rows: [Int64] = mode == .rgb
            ? rgbRows(matrix: matrix, sourceDepths: isPalette ? [8, 8, 8] : comps.prefix(3).map { Int($0.depth) },
                      sourceFullRange: isPalette || sourceFullRange, targetBits: Int(targetBits),
                      fractionBits: Int(fractionBits), outputFullRange: output.fullRange)
            : [Int64](repeating: 0, count: 12)
        var alignment = [1, 1, 1, 1]
        for c in comps.prefix(isPalette ? 1 : 3) where desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) == 0 {
            let bits = Int(c.shift + c.depth)
            alignment[Int(c.plane)] = max(alignment[Int(c.plane)], bits <= 8 ? 1 : (bits <= 16 ? 2 : 4))
        }
        if isPalette { alignment[1] = 4 }

        return Plan(
            mode: mode, outputLog2: outLog2, sourceLog2: mode == .resample || mode == .pack ? srcLog2 : outLog2,
            components: comps.prefix(3).map { [UInt32($0.plane), UInt32($0.step), UInt32($0.offset), UInt32($0.shift), UInt32($0.depth)] },
            bigEndian: desc.flags & UInt64(AV_PIX_FMT_FLAG_BE) != 0,
            bitstream: desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) != 0,
            palette: isPalette, fullRange: mode == .rgb ? (isPalette || sourceFullRange) : sourceFullRange,
            targetBits: targetBits, fractionBits: fractionBits, containerShift: containerShift,
            chromaLocation: UInt32(chromaLocation.rawValue), wideOutput: output.depth != .eight,
            rgbRows: rows, planeAlignment: alignment)
    }

    private static func components(_ desc: AVPixFmtDescriptor) -> [AVComponentDescriptor] {
        withUnsafeBytes(of: desc.comp) { Array($0.bindMemory(to: AVComponentDescriptor.self)) }
    }

    /// K_R, K_B of the CoreVideo matrix tags (H.273 Table 4).
    static func coefficients(_ matrix: CFString) -> (kr: Double, kb: Double) {
        switch matrix {
        case kCVImageBufferYCbCrMatrix_ITU_R_601_4: (0.299, 0.114)
        case kCVImageBufferYCbCrMatrix_ITU_R_2020: (0.2627, 0.0593)
        case kCVImageBufferYCbCrMatrix_SMPTE_240M_1995: (0.212, 0.087)
        default: (0.2126, 0.0722)
        }
    }

    /// R'G'B' codes to Y'CbCr output words, as affine rows (computed in double, handed to the GPU in 2^-30 fixed point):
    /// the codes decode to E'R, E'G, E'B at their range ((27)-(29) or (33)-(35)), then (45)-(47), then (30)-(32)
    /// or (36)-(38) at T bits, times 2^F. Round and Clip are the kernel's.
    static func rgbRows(matrix: CFString, sourceDepths: [Int], sourceFullRange: Bool, targetBits: Int,
                        fractionBits: Int, outputFullRange: Bool) -> [Int64] {
        let (kr, kb) = coefficients(matrix)
        let kg = 1 - kr - kb
        // E' = a * code + b per component.
        let decode: [(a: Double, b: Double)] = sourceDepths.map { d in
            sourceFullRange ? (1 / Double((1 << d) - 1), 0) : (1 / (219 * pow(2, Double(d - 8))), -16.0 / 219)
        }
        let n = Double(targetBits), scale = pow(2, Double(fractionBits))
        let (ySpan, yOff, cSpan, cOff): (Double, Double, Double, Double) = outputFullRange
            ? (pow(2, n) - 1, 0, pow(2, n) - 1, pow(2, n - 1))
            : (219 * pow(2, n - 8), 16 * pow(2, n - 8), 224 * pow(2, n - 8), 128 * pow(2, n - 8))
        // Rows over (E'R, E'G, E'B).
        let y = [kr, kg, kb]
        let cb = [-0.5 * kr / (1 - kb), -0.5 * kg / (1 - kb), 0.5]
        let cr = [0.5, -0.5 * kg / (1 - kr), -0.5 * kb / (1 - kr)]
        func row(_ m: [Double], span: Double, offset: Double) -> [Int64] {
            let coeffs = (0..<3).map { m[$0] * decode[$0].a * span * scale }
            let constant = ((0..<3).reduce(0) { $0 + m[$1] * decode[$1].b } * span + offset) * scale
            return (coeffs + [constant]).map { Int64(($0 * 1_073_741_824).rounded()) }
        }
        return row(y, span: ySpan, offset: yOff) + row(cb, span: cSpan, offset: cOff) + row(cr, span: cSpan, offset: cOff)
    }

    /// The planes of `frame` inside `slab` (one the allocator made, so every plane is in it).
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

    enum FinisherError: Error { case unavailable(String) }

    private static let library = OSAllocatedUnfairLock<[ObjectIdentifier: MTLLibrary]>(initialState: [:])
    private static let pipelines = OSAllocatedUnfairLock<[PipelineKey: MTLComputePipelineState]>(initialState: [:])

    private struct PipelineKey: Hashable {
        let device: ObjectIdentifier
        let constants: [UInt32]
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FinisherError.unavailable("no command queue") }
        self.queue = queue
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw FinisherError.unavailable("no texture cache") }
        textureCache = cache
    }

    /// The pipeline specialised for `plan`, compiled on first use and shared by every finisher in the process.
    func pipeline(for plan: Plan) throws -> MTLComputePipelineState {
        let key = PipelineKey(device: ObjectIdentifier(device), constants: plan.specialisation)
        if let ready = Self.pipelines.withLock({ $0[key] }) { return ready }
        let lib: MTLLibrary
        if let cached = Self.library.withLock({ $0[ObjectIdentifier(device)] }) {
            lib = cached
        } else {
            let options = MTLCompileOptions()
            // IEEE rounding throughout: the rounding steps are H.273's Round.
            if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
            lib = try device.makeLibrary(source: PlanarFrameShaderSource.source, options: options)
            Self.library.withLock { $0[ObjectIdentifier(device)] = lib }
        }
        let values = MTLFunctionConstantValues()
        var boolIndices: Set<Int> = [20, 21, 22, 23]
        for (index, value) in plan.specialisation.enumerated() {
            if boolIndices.remove(index) != nil {
                var flag = value != 0
                values.setConstantValue(&flag, type: .bool, index: index)
            } else {
                var word = value
                values.setConstantValue(&word, type: .uint, index: index)
            }
        }
        let function = try lib.makeFunction(name: "pf_finish", constantValues: values)
        let made = try device.makeComputePipelineState(function: function)
        Self.pipelines.withLock { $0[key] = made }
        return made
    }

    /// Writes the `width` x `height` picture in `planes` into `buffer` (a bi-planar buffer of the plan's output
    /// format) and waits for the GPU. False when the planes break the plan's alignment, a texture cannot be made
    /// for the buffer, or the GPU reports an error.
    func finish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer) -> Bool {
        for p in 0..<4 where plan.planeAlignment[p] > 1 {
            guard planes.offsets[p] % UInt32(plan.planeAlignment[p]) == 0,
                  planes.linesizes[p] % UInt32(plan.planeAlignment[p]) == 0 else { return false }
        }
        let wide = plan.wideOutput
        guard let pipeline = try? pipeline(for: plan),
              let luma = texture(buffer, plane: 0, format: wide ? .r16Uint : .r8Uint),
              let chroma = texture(buffer, plane: 1, format: wide ? .rg16Uint : .rg8Uint),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma),
              let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
        else { return false }

        // PFFrame: twelve 32-bit words, then the 64-bit rows (8-byte aligned at offset 48).
        var frame = Data()
        for word in [UInt32(width), UInt32(height), UInt32(chromaTexture.width), UInt32(chromaTexture.height)]
            + planes.offsets + planes.linesizes { withUnsafeBytes(of: word) { frame.append(contentsOf: $0) } }
        for row in plan.rgbRows { withUnsafeBytes(of: row) { frame.append(contentsOf: $0) } }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(planes.slab.buffer, offset: 0, index: 0)
        frame.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        let w = pipeline.threadExecutionWidth
        encoder.dispatchThreads(MTLSize(width: chromaTexture.width, height: chromaTexture.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
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
}
