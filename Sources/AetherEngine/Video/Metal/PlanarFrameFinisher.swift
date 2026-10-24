import Foundation
import Metal
import CoreVideo
import os
import AetherLibavutil
import LibDeinterlace

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
///   with Catmull-Rom at the stream's chroma siting, in exact integers, then taken to the output depth.
/// - Grey: luma taken to the output depth, chroma neutral (`1 << (n - 1)`).
/// - RGB and palette: R'G'B' codes decoded at their range (H.273 (27)-(29), (33)-(35)) and encoded as
///   non-constant-luminance Y'CbCr with the matrix the buffer is tagged with, 4:4:4.
/// - Convert (`ColourRepresentation`): Y'CbCr in a matrix CoreVideo cannot tag (FCC, chromaticity-derived,
///   YCgCo, YCgCo-R, GBR on Y'CbCr-labelled planes, constant luminance), chroma resampled to every pixel and
///   re-encoded 4:4:4 at the source's own depth, then taken to the output like any code of that depth.
///
/// Real-valued stages run in float32 with each value's error bound carried alongside; a code whose value lies that
/// close to a rounding tie is recomputed in double-float (inline for the affine paths, through a second dispatch for
/// constant luminance), so every code is the correctly rounded H.273 value.
/// - A source deeper than the 10 bits the output keeps: the value formed with six fraction bits and ordered
///   down with the 8x8 Bayer threshold.
///
/// Each source format gets its own specialised pipeline (function constants), compiled once per process.
final class PlanarFrameFinisher: @unchecked Sendable {

    enum Mode: UInt32 { case pack = 0, resample = 1, gray = 2, rgb = 3, convert = 4, constantLuminance = 5 }

    /// What one source format means for the kernel. Everything but `rows` is a function constant.
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
        /// Convert: 1 non-constant luminance, 2 YCgCo, 3 YCgCo-R (0 otherwise), and BitDepthRGB for 2 and 3.
        var matrix: UInt32
        var bitDepthRGB: UInt32
        /// Constant luminance: the stream's TransferCharacteristics (0 otherwise), and the luma table's entries (per luma
        /// code: E'Y and its inverse transfer value, double-float, four floats each).
        var transfer: UInt32
        var lumaTable: [Float]
        /// The kernel's affine rows (two maps, double-float: 48 floats), constant-luminance constants (16) and the
        /// transfer function's constants (16), and the near-tie bound of the constant-luminance fast path.
        var rows: [Float]
        var cl: [Float]
        var tp: [Float]
        var tieBound: Float
        /// Bytes a component load reads, per plane: plane offsets and linesizes must be multiples of it.
        var planeAlignment: [Int]

        static func == (a: Plan, b: Plan) -> Bool {
            a.specialisation == b.specialisation && a.rows == b.rows && a.cl == b.cl && a.tp == b.tp && a.tieBound == b.tieBound
                && a.lumaTable == b.lumaTable
        }
        func hash(into hasher: inout Hasher) { hasher.combine(specialisation); hasher.combine(rows) }

        /// The function constants, in index order.
        var specialisation: [UInt32] {
            [mode.rawValue] + outputLog2 + sourceLog2 + components.flatMap { $0 }
                + [bigEndian ? 1 : 0, bitstream ? 1 : 0, palette ? 1 : 0, fullRange ? 1 : 0,
                   targetBits, fractionBits, containerShift, chromaLocation, matrix, bitDepthRGB, transfer]
        }
    }

    /// Byte offsets and linesizes of a picture's planes inside one buffer (a decoder's slab, or the deinterlacer's
    /// scratch): LibDeinterlace's type, so pictures cross into the deinterlacer as they are.
    typealias Planes = PlaneSet

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
    /// frame's range (for RGB: whether its codes are full range); `matrix` the Y'CbCr matrix the buffer is tagged
    /// with (and an RGB or converted picture encoded with); `representation` what the source's MatrixCoefficients
    /// call for. An interlaced picture is never resampled vertically: its chroma rows alternate between the fields.
    static func plan(source: AVPixelFormat, output: SoftwareVideoDecoder.OutputFormat, sourceFullRange: Bool,
                     chromaLocation: AVChromaLocation, matrix: CFString, interlaced: Bool = false,
                     representation: ColourRepresentation = .tagged) -> Plan? {
        guard reads(source), let desc = av_pix_fmt_desc_get(source)?.pointee else { return nil }
        if case .refused = representation { return nil }
        var comps = components(desc)
        // Identity: the Y'CbCr-labelled planes hold G, B, R; read them as R, G, B.
        if representation == .identity { comps = [comps[2], comps[0], comps[1]] + comps.dropFirst(3) }
        let isPalette = desc.flags & UInt64(AV_PIX_FMT_FLAG_PAL) != 0
        let isRGB = representation == .identity || (!isPalette && desc.flags & UInt64(AV_PIX_FMT_FLAG_RGB) != 0)
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
        } else if representation.converts {
            guard outLog2 == [0, 0], !interlaced || srcLog2[1] == 0 else { return nil }
            if case .constantLuminance = representation { mode = .constantLuminance } else { mode = .convert }
        } else {
            guard outLog2[0] <= srcLog2[0], outLog2[1] <= srcLog2[1], !interlaced || outLog2[1] == srcLog2[1] else { return nil }
            mode = outLog2 == srcLog2 ? .pack : .resample
        }
        // A code is only ever widened: the output's significant bits plus its fraction bits hold every source bit.
        if ![.rgb, .convert, .constantLuminance].contains(mode) {
            let used = mode == .gray ? 1 : 3
            guard comps.prefix(used).allSatisfy({ UInt32($0.depth) <= targetBits + fractionBits }) else { return nil }
        }

        // Output words from E'Y, E'PB, E'PR in the tagged matrix: (45)-(47), then (30)-(32) / (36)-(38).
        let target = coefficients(matrix)
        let encode = ColourAffine.encodeCodes(targetBits: Int(targetBits), fractionBits: Int(fractionBits),
                                              fullRange: output.fullRange)
            .after(ColourAffine.encodeNCL(kr: target.kr, kb: target.kb))
        // A converted picture is encoded at its own depth, as d-bit codes the kernel's depth stage then takes to the
        // output like any code of that depth: the output gains no precision the source lacked, and float32 can round
        // up to 12-bit codes.
        let sourceDepth = Int(comps[0].depth)
        let encodeAtSource = ColourAffine.encodeCodes(targetBits: sourceDepth, fractionBits: 0, fullRange: sourceFullRange)
            .after(ColourAffine.encodeNCL(kr: target.kr, kb: target.kb))
        var matrixMode: UInt32 = 0, bitDepthRGB: UInt32 = 0, transferCode: UInt32 = 0
        var second: ColourAffine?, cl = [Float](repeating: 0, count: 16), tp = [Float](repeating: 0, count: 16)
        var lumaTable: [Float] = []
        func split(_ values: [Double]) -> [Float] {
            values.flatMap { v -> [Float] in let hi = Float(v); return [hi, Float(v - Double(hi))] }
        }
        let rows: ColourAffine?
        switch (mode, representation) {
        case (.rgb, _):
            rows = encode.after(ColourAffine.decodeRGB(depths: isPalette ? [8, 8, 8] : comps.prefix(3).map { Int($0.depth) },
                                                       fullRange: isPalette || sourceFullRange))
        case (.convert, .nonConstantLuminance(let kr, let kb)):
            matrixMode = 1
            rows = encodeAtSource.after(ColourAffine.decodeNCL(kr: kr, kb: kb))
                .after(ColourAffine.decodeYCbCr(depths: comps.prefix(3).map { Int($0.depth) }, fullRange: sourceFullRange))
        case (.convert, .ycgco):
            matrixMode = 2
            bitDepthRGB = UInt32(comps[0].depth)
            rows = encodeAtSource.after(ColourAffine.decodeRGB(depths: Array(repeating: Int(bitDepthRGB), count: 3), fullRange: sourceFullRange))
        case (.convert, .ycgcoR(let depth)):
            matrixMode = 3
            bitDepthRGB = UInt32(depth)
            rows = encodeAtSource.after(ColourAffine.decodeRGB(depths: Array(repeating: depth, count: 3), fullRange: sourceFullRange))
        case (.constantLuminance, .constantLuminance(let kr, let kb, let transfer)):
            // Rows 0-2: codes to E'Y, E'PB, E'PR. Rows 3-5: E'R, E'G, E'B to words.
            transferCode = transfer.code
            rows = ColourAffine.decodeYCbCr(depths: comps.prefix(3).map { Int($0.depth) }, fullRange: sourceFullRange)
            second = encodeAtSource
            cl = split([kr, kb, 1 / (1 - kr - kb), transfer.forward(1 - kb), 1 - transfer.forward(kb),
                        transfer.forward(1 - kr), 1 - transfer.forward(kr), 0])
            tp = split(transfer.constants + Array(repeating: 0, count: 8 - transfer.constants.count))
            // E'Y depends on the luma code alone, so it and its inverse transfer value are one table entry per code.
            let decode = rows!
            lumaTable = (0..<(1 << sourceDepth)).flatMap { code -> [Float] in
                let ey = decode.m[0][0] * Double(code) + decode.b[0]
                return split([ey, transfer.inverse(ey)])
            }
        case (.convert, _), (.constantLuminance, _):
            return nil
        default:
            rows = nil
        }
        var alignment = [1, 1, 1, 1]
        for c in comps.prefix(isPalette ? 1 : 3) where desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) == 0 {
            let bits = Int(c.shift + c.depth)
            alignment[Int(c.plane)] = max(alignment[Int(c.plane)], bits <= 8 ? 1 : (bits <= 16 ? 2 : 4))
        }
        if isPalette { alignment[1] = 4 }

        return Plan(
            mode: mode, outputLog2: outLog2, sourceLog2: [.pack, .resample, .convert, .constantLuminance].contains(mode) ? srcLog2 : outLog2,
            components: comps.prefix(3).map { [UInt32($0.plane), UInt32($0.step), UInt32($0.offset), UInt32($0.shift), UInt32($0.depth)] },
            bigEndian: desc.flags & UInt64(AV_PIX_FMT_FLAG_BE) != 0,
            bitstream: desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) != 0,
            palette: isPalette, fullRange: mode == .rgb ? (isPalette || sourceFullRange) : sourceFullRange,
            targetBits: targetBits, fractionBits: fractionBits, containerShift: containerShift,
            chromaLocation: UInt32(chromaLocation.rawValue), wideOutput: output.depth != .eight,
            matrix: matrixMode, bitDepthRGB: bitDepthRGB, transfer: transferCode, lumaTable: lumaTable,
            rows: (rows?.doubleFloatRows ?? [Float](repeating: 0, count: 24)) + (second?.doubleFloatRows ?? [Float](repeating: 0, count: 24)),
            cl: cl, tp: tp,
            // The fast path bounds each pixel's error itself, from this relative error per float32 transfer evaluation.
            tieBound: mode == .constantLuminance ? Self.transferEvaluationError : 0,
            planeAlignment: alignment)
    }

    /// The relative error of one float32 exp2 / log2 in the constant-luminance fast path: 4 ulp, the maximum the Metal
    /// Shading Language specification guarantees for both with fast math disabled (Table 8.1), on every Apple GPU.
    static let transferEvaluationError: Float = 4 * Float.ulpOfOne

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
        return Planes(buffer: slab.buffer, offsets: offsets, linesizes: linesizes)
    }

    // MARK: - Metal

    enum FinisherError: Error { case unavailable(String) }

    private static let library = OSAllocatedUnfairLock<[ObjectIdentifier: MTLLibrary]>(initialState: [:])
    private static let pipelines = OSAllocatedUnfairLock<[PipelineKey: MTLComputePipelineState]>(initialState: [:])

    private struct PipelineKey: Hashable {
        let device: ObjectIdentifier
        let function: String
        let constants: [UInt32]
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    /// Constant luminance: the counter and coordinates of the pixels the fast path flagged, and the indirect dispatch
    /// arguments for their recompute. Grown to the picture size, kept between frames.
    private var flagged: MTLBuffer?
    private let dispatchArguments: MTLBuffer
    /// The last plan's luma table, uploaded once.
    private var lumaTable: (values: [Float], buffer: MTLBuffer)?

    /// LibDeinterlace's kernels, on this finisher's device.
    let kernels: DeinterlaceKernels

    init(device: MTLDevice) throws {
        self.device = device
        kernels = try DeinterlaceKernels(device: device)
        guard let queue = device.makeCommandQueue() else { throw FinisherError.unavailable("no command queue") }
        self.queue = queue
        guard let arguments = device.makeBuffer(length: 16, options: .storageModePrivate) else {
            throw FinisherError.unavailable("no buffer")
        }
        dispatchArguments = arguments
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw FinisherError.unavailable("no texture cache") }
        textureCache = cache
    }

    private static func library(for device: MTLDevice) throws -> MTLLibrary {
        if let cached = Self.library.withLock({ $0[ObjectIdentifier(device)] }) { return cached }
        let options = MTLCompileOptions()
        // IEEE rounding throughout: the rounding steps are H.273's Round.
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) { options.mathMode = .safe } else { options.fastMathEnabled = false }
        let made = try device.makeLibrary(source: PlanarFrameShaderSource.source, options: options)
        Self.library.withLock { $0[ObjectIdentifier(device)] = made }
        return made
    }

    /// The pipeline specialised for `plan`, compiled on first use and shared by every finisher in the process.
    func pipeline(for plan: Plan, function name: String = "pf_finish") throws -> MTLComputePipelineState {
        let key = PipelineKey(device: ObjectIdentifier(device), function: name, constants: plan.specialisation)
        if let ready = Self.pipelines.withLock({ $0[key] }) { return ready }
        let lib = try Self.library(for: device)
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
        let function = try lib.makeFunction(name: name, constantValues: values)
        let made = try device.makeComputePipelineState(function: function)
        Self.pipelines.withLock { $0[key] = made }
        return made
    }

    /// Writes the `width` x `height` picture in `planes` into `buffer` (a bi-planar buffer of the plan's output
    /// format) and waits for the GPU. False when the planes break the plan's alignment, a texture cannot be made
    /// for the buffer, or the GPU reports an error.
    func finish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer) -> Bool {
        finish([Job(source: .picture(planes), plan: plan, width: width, height: height, buffer: buffer)])
    }

    // MARK: - Deinterlacing

    /// One output field of the deinterlacer (LibDeinterlace's bwdif): three decoded pictures and vf_bwdif's parities,
    /// written at the source's depth into a planar scratch picture the job's plan then reads. LibDeinterlace's
    /// `BwdifWindow` says which pictures and parities each field takes.
    struct Field {
        var bwdif: DeinterlaceKernels.BwdifField
        /// The decoded pictures' layout.
        var layout: PictureLayout
    }

    /// A picture, or a field of three, written into a display buffer with `plan`. A field's plan is the one for its
    /// scratch picture: the source's planar equivalent (``planarEquivalent(of:)``), progressive.
    struct Job {
        enum Source { case picture(Planes), field(Field) }
        var source: Source
        var plan: Plan
        var width: Int
        var height: Int
        var buffer: CVPixelBuffer
    }

    /// The planar little-endian format holding `source`'s components at their depths and subsampling, which is what
    /// the deinterlacer writes (bwdif is defined on planes). Nil when FFmpeg names no such format (4:1:1 above 8 bits)
    /// or the deinterlacer does not read the source.
    static func planarEquivalent(of source: AVPixelFormat) -> AVPixelFormat? {
        guard PictureLayout(format: source) != nil, let want = av_pix_fmt_desc_get(source)?.pointee else { return nil }
        let wantComps = components(want)
        let count = want.nb_components < 3 ? 1 : 3
        let refused = UInt64(AV_PIX_FMT_FLAG_BE) | UInt64(AV_PIX_FMT_FLAG_RGB) | UInt64(AV_PIX_FMT_FLAG_PAL)
            | UInt64(AV_PIX_FMT_FLAG_HWACCEL) | UInt64(AV_PIX_FMT_FLAG_BITSTREAM) | UInt64(AV_PIX_FMT_FLAG_ALPHA)
            | UInt64(AV_PIX_FMT_FLAG_FLOAT) | UInt64(AV_PIX_FMT_FLAG_BAYER) | UInt64(AV_PIX_FMT_FLAG_XYZ)
        var cursor: UnsafePointer<AVPixFmtDescriptor>?
        while let next = av_pix_fmt_desc_next(cursor) {
            cursor = next
            let d = next.pointee
            guard Int(d.nb_components) == count, d.flags & refused == 0,
                  count == 1 || d.flags & UInt64(AV_PIX_FMT_FLAG_PLANAR) != 0,
                  d.log2_chroma_w == want.log2_chroma_w, d.log2_chroma_h == want.log2_chroma_h,
                  // The yuvj formats only restate a range the frame carries anyway.
                  !String(cString: d.name).hasPrefix("yuvj") else { continue }
            let comps = components(d)
            let matches = (0..<count).allSatisfy { i in
                let c = comps[i], w = wantComps[i]
                return c.plane == i && c.offset == 0 && c.shift == 0 && c.depth == w.depth && c.step == (w.depth > 8 ? 2 : 1)
            }
            if matches { return av_pix_fmt_desc_get_id(next) }
        }
        return nil
    }

    /// The scratch picture for a `width` x `height` field of `layout`: planes 0...2 (0 alone for grey), one byte a
    /// sample up to 8 bits and two above, every plane and row 64-byte aligned.
    static func scratchLayout(layout: PictureLayout, width: Int, height: Int) -> (offsets: [UInt32], linesizes: [UInt32], length: Int) {
        var offsets = [UInt32](repeating: 0, count: 4), linesizes = [UInt32](repeating: 0, count: 4)
        var length = 0
        for (c, component) in layout.components.enumerated() {
            let (w, h) = layout.size(component: c, width: width, height: height)
            let bytes = component.depth > 8 ? 2 : 1
            let linesize = (w * bytes + 63) & ~63
            offsets[c] = UInt32(length)
            linesizes[c] = UInt32(linesize)
            length += (linesize * h + 63) & ~63
        }
        return (offsets, linesizes, max(length, 64))
    }

    /// Scratch pictures, one per field of a submission, grown to the largest field seen and kept.
    private var scratch: [MTLBuffer] = []

    private func scratchBuffer(_ index: Int, length: Int) -> MTLBuffer? {
        while scratch.count <= index {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            scratch.append(made)
        }
        if scratch[index].length < length {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            scratch[index] = made
        }
        return scratch[index]
    }

    /// Encodes `field`'s bwdif (LibDeinterlace) into the scratch picture `scratchIndex`, which it returns.
    private func encodeField(_ field: Field, width: Int, height: Int, scratchIndex: Int,
                             encoder: MTLComputeCommandEncoder) -> Planes? {
        let layout = Self.scratchLayout(layout: field.layout, width: width, height: height)
        guard let buffer = scratchBuffer(scratchIndex, length: layout.length) else { return nil }
        let out = Planes(buffer: buffer, offsets: layout.offsets, linesizes: layout.linesizes)
        guard kernels.encodeBwdif(field.bwdif, layout: field.layout, width: width, height: height, into: out, encoder: encoder)
        else { return nil }
        return out
    }

    // MARK: - Submission

    /// Writes every job and waits for the GPU once. The deinterlacer's dispatches of all the fields run together,
    /// then, after one barrier, the finisher's dispatches of all the jobs: one command buffer, one wait, the GPU
    /// filled by the work of both fields of a frame. A constant-luminance job, whose second and third dispatches read
    /// the first's list, gets a command buffer of its own. False when any job fails.
    func finish(_ jobs: [Job]) -> Bool {
        var ok = true
        let together = jobs.filter { !usesList($0.plan) }
        if !together.isEmpty { ok = run(together, concurrent: true) && ok }
        for job in jobs where usesList(job.plan) { ok = run([job], concurrent: false) && ok }
        return ok
    }

    /// Codes above 12 bits go straight to the exact path in the kernel (PF_EXACT_ONLY): no list, no second pass.
    private func usesList(_ plan: Plan) -> Bool { plan.mode == .constantLuminance && plan.components[0][4] <= 12 }

    private func run(_ jobs: [Job], concurrent: Bool) -> Bool {
        guard let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder(dispatchType: concurrent ? .concurrent : .serial)
        else { return false }
        var sources: [Planes] = []
        var fields = 0
        for job in jobs {
            switch job.source {
            case .picture(let planes):
                sources.append(planes)
            case .field(let field):
                guard let planes = encodeField(field, width: job.width, height: job.height, scratchIndex: fields, encoder: encoder) else {
                    encoder.endEncoding()
                    return false
                }
                fields += 1
                sources.append(planes)
            }
        }
        if fields > 0 { encoder.memoryBarrier(scope: .buffers) }
        var textures: [CVMetalTexture] = []
        for (job, planes) in zip(jobs, sources) {
            guard let made = encodeFinish(planes, plan: job.plan, width: job.width, height: job.height, into: job.buffer,
                                          encoder: encoder) else {
                encoder.endEncoding()
                return false
            }
            textures += made
        }
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime((textures, sources.map(\.buffer))) {}
        return commands.status == .completed
    }

    /// Encodes one picture's finishing dispatches; returns the buffer's textures, which must outlive the work.
    private func encodeFinish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer,
                              encoder: MTLComputeCommandEncoder) -> [CVMetalTexture]? {
        for p in 0..<4 where plan.planeAlignment[p] > 1 {
            guard planes.offsets[p] % UInt32(plan.planeAlignment[p]) == 0,
                  planes.linesizes[p] % UInt32(plan.planeAlignment[p]) == 0 else { return nil }
        }
        let wide = plan.wideOutput
        guard let pipeline = try? pipeline(for: plan),
              let luma = texture(buffer, plane: 0, format: wide ? .r16Uint : .r8Uint),
              let chroma = texture(buffer, plane: 1, format: wide ? .rg16Uint : .rg8Uint),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return nil }

        let constantLuminance = usesList(plan)
        let capacity = width * height
        if constantLuminance, (flagged?.length ?? 0) < 4 * (capacity + 1) {
            flagged = device.makeBuffer(length: 4 * (capacity + 1), options: .storageModeShared)
        }
        guard let list = constantLuminance ? flagged : (flagged ?? dispatchArguments) else { return nil }
        if constantLuminance { list.contents().storeBytes(of: UInt32(0), as: UInt32.self) }

        // PFFrame: twelve 32-bit words, then the double-float rows, constant-luminance and transfer constants (float2,
        // 8-byte aligned from offset 48), the near-tie bound and the list capacity.
        var frame = Data()
        for word in [UInt32(width), UInt32(height), UInt32(chromaTexture.width), UInt32(chromaTexture.height)]
            + planes.offsets + planes.linesizes { withUnsafeBytes(of: word) { frame.append(contentsOf: $0) } }
        for value in plan.rows + plan.cl + plan.tp + [plan.tieBound] { withUnsafeBytes(of: value) { frame.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(constantLuminance ? capacity : 0)) { frame.append(contentsOf: $0) }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(planes.buffer, offset: 0, index: 0)
        frame.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 1) }
        encoder.setBuffer(list, offset: 0, index: 2)
        if !plan.lumaTable.isEmpty {
            if lumaTable?.values != plan.lumaTable {
                guard let made = device.makeBuffer(bytes: plan.lumaTable, length: 4 * plan.lumaTable.count, options: .storageModeShared)
                else { return nil }
                lumaTable = (plan.lumaTable, made)
            }
            encoder.setBuffer(lumaTable!.buffer, offset: 0, index: 4)
        } else {
            encoder.setBuffer(list, offset: 0, index: 4)
        }
        encoder.setTexture(lumaTexture, index: 0)
        encoder.setTexture(chromaTexture, index: 1)
        let w = pipeline.threadExecutionWidth
        // Convert and constant luminance run one thread per source chroma sample (its block of pixels).
        let blocks = plan.mode == .convert || plan.mode == .constantLuminance
        let grid = blocks
            ? MTLSize(width: (width + (1 << Int(plan.sourceLog2[0])) - 1) >> Int(plan.sourceLog2[0]),
                      height: (height + (1 << Int(plan.sourceLog2[1])) - 1) >> Int(plan.sourceLog2[1]), depth: 1)
            : MTLSize(width: chromaTexture.width, height: chromaTexture.height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
        if constantLuminance {
            // The flagged pixels, sized on the GPU: one thread turns the count into indirect arguments, then each
            // flagged pixel is recomputed in double-float. This job's encoder is serial, so the dispatches run in order.
            guard let prepare = try? self.pipeline(for: plan, function: "pf_cl_prepare"),
                  let correct = try? self.pipeline(for: plan, function: "pf_cl_correct") else { return nil }
            encoder.setComputePipelineState(prepare)
            encoder.setBuffer(dispatchArguments, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.setComputePipelineState(correct)
            encoder.setBuffer(lumaTable!.buffer, offset: 0, index: 4)
            encoder.dispatchThreadgroups(indirectBuffer: dispatchArguments, indirectBufferOffset: 0,
                                         threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        return [luma, chroma]
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
