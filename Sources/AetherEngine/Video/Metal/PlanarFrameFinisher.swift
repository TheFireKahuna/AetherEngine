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
        /// AV1 film grain on every sample read (the job carries the frame's parameters).
        var grain: Bool = false
        /// The source is one of two pictures chosen on the GPU (``Job/passthrough``); set by the finisher per job.
        var choosesSource: Bool = false

        static func == (a: Plan, b: Plan) -> Bool {
            a.specialisation == b.specialisation && a.rows == b.rows && a.cl == b.cl && a.tp == b.tp && a.tieBound == b.tieBound
                && a.lumaTable == b.lumaTable
        }
        func hash(into hasher: inout Hasher) { hasher.combine(specialisation); hasher.combine(rows) }

        /// The function constants, in index order.
        var specialisation: [UInt32] {
            [mode.rawValue] + outputLog2 + sourceLog2 + components.flatMap { $0 }
                + [bigEndian ? 1 : 0, bitstream ? 1 : 0, palette ? 1 : 0, fullRange ? 1 : 0,
                   targetBits, fractionBits, containerShift, chromaLocation, matrix, bitDepthRGB, transfer, grain ? 1 : 0,
                   choosesSource ? 1 : 0]
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
    /// `grain`: the picture carries AV1 film grain, applied to every sample as it is read (planar 8, 10 and 12-bit
    /// formats, progressive: what libdav1d writes).
    static func plan(source: AVPixelFormat, output: SoftwareVideoDecoder.OutputFormat, sourceFullRange: Bool,
                     chromaLocation: AVChromaLocation, matrix: CFString, interlaced: Bool = false,
                     representation: ColourRepresentation = .tagged, grain: Bool = false) -> Plan? {
        guard reads(source), let desc = av_pix_fmt_desc_get(source)?.pointee else { return nil }
        if grain { guard FilmGrainParameters.supports(source), !interlaced else { return nil } }
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
        // Constants the kernel never reads take one value, so plans it cannot tell apart share a pipeline: the chroma
        // siting only on an axis it resamples, big-endian only where a component spans more than a byte.
        let resampled = [.resample, .convert, .constantLuminance].contains(mode)
            ? (srcLog2[0] != outLog2[0], srcLog2[1] != outLog2[1]) : (false, false)
        let siting = Self.siting(chromaLocation, horizontal: resampled.0, vertical: resampled.1)
        let multiByte = comps.prefix(isPalette ? 1 : 3).contains { $0.shift + $0.depth > 8 }

        var alignment = [1, 1, 1, 1]
        for c in comps.prefix(isPalette ? 1 : 3) where desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) == 0 {
            let bits = Int(c.shift + c.depth)
            alignment[Int(c.plane)] = max(alignment[Int(c.plane)], bits <= 8 ? 1 : (bits <= 16 ? 2 : 4))
        }
        if isPalette { alignment[1] = 4 }

        return Plan(
            mode: mode, outputLog2: outLog2, sourceLog2: [.pack, .resample, .convert, .constantLuminance].contains(mode) ? srcLog2 : outLog2,
            components: comps.prefix(3).map { [UInt32($0.plane), UInt32($0.step), UInt32($0.offset), UInt32($0.shift), UInt32($0.depth)] },
            bigEndian: multiByte && desc.flags & UInt64(AV_PIX_FMT_FLAG_BE) != 0,
            bitstream: desc.flags & UInt64(AV_PIX_FMT_FLAG_BITSTREAM) != 0,
            palette: isPalette, fullRange: mode == .rgb ? (isPalette || sourceFullRange) : sourceFullRange,
            targetBits: targetBits, fractionBits: fractionBits, containerShift: containerShift,
            chromaLocation: siting, wideOutput: output.depth != .eight,
            matrix: matrixMode, bitDepthRGB: bitDepthRGB, transfer: transferCode, lumaTable: lumaTable,
            rows: (rows?.doubleFloatRows ?? [Float](repeating: 0, count: 24)) + (second?.doubleFloatRows ?? [Float](repeating: 0, count: 24)),
            cl: cl, tp: tp,
            // The fast path bounds each pixel's error itself, from this relative error per float32 transfer evaluation.
            tieBound: mode == .constantLuminance ? Self.transferEvaluationError : 0,
            planeAlignment: alignment, grain: grain)
    }

    /// The relative error of one float32 exp2 / log2 in the constant-luminance fast path: 4 ulp, the maximum the Metal
    /// Shading Language specification guarantees for both with fast math disabled (Table 8.1), on every Apple GPU.
    static let transferEvaluationError: Float = 4 * Float.ulpOfOne

    /// The chroma location as the kernel's siting reads it (pf_site2), on the axes it resamples: left-sited or centred
    /// horizontally; on the top row, centred or on the bottom row vertically. An axis it does not resample takes the
    /// centred class, so locations that differ only there share a pipeline.
    static func siting(_ location: AVChromaLocation, horizontal: Bool, vertical: Bool) -> UInt32 {
        let l = location.rawValue
        let left = horizontal && [AVCHROMA_LOC_LEFT, AVCHROMA_LOC_TOPLEFT, AVCHROMA_LOC_BOTTOMLEFT].map(\.rawValue).contains(l)
        let row: Int = !vertical ? 0
            : ([AVCHROMA_LOC_TOPLEFT, AVCHROMA_LOC_TOP].map(\.rawValue).contains(l) ? -1
               : ([AVCHROMA_LOC_BOTTOMLEFT, AVCHROMA_LOC_BOTTOM].map(\.rawValue).contains(l) ? 1 : 0))
        let code: AVChromaLocation = switch (left, row) {
        case (true, -1): AVCHROMA_LOC_TOPLEFT
        case (false, -1): AVCHROMA_LOC_TOP
        case (true, 1): AVCHROMA_LOC_BOTTOMLEFT
        case (false, 1): AVCHROMA_LOC_BOTTOM
        case (true, _): AVCHROMA_LOC_LEFT
        default: AVCHROMA_LOC_CENTER
        }
        return UInt32(code.rawValue)
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
    /// Every submission of this finisher, LibDeinterlace's included.
    let submitter: GPUSubmitter
    private let textureCache: CVMetalTextureCache
    /// Bound where a kernel declares a buffer the plan does not use (the film grain tables without grain, the
    /// constant-luminance list outside that mode). Never written.
    private let placeholder: MTLBuffer
    /// The last plan's luma table, uploaded once. Never written after it is made: a new table is a new buffer, and a
    /// submission keeps the one it read (``Slot/retained``).
    private var lumaTable: (values: [Float], buffer: MTLBuffer)?

    /// What a submission's GPU work reads after its commit, the CPU's writes into it included. The slots are a ring
    /// taken in submission order, each handed back by its own submission's completion (`free`), so the next frame never
    /// writes what an earlier one's work still reads, and nothing but that handoff is shared between the encoding thread
    /// and the completion. Up to ``slotCount`` submissions are in flight; a further one waits for the oldest.
    private final class Slot: @unchecked Sendable {
        /// Signalled when the slot's last submission has completed.
        let free = DispatchSemaphore(value: 1)
        /// Scratch pictures, one per field, grown to the largest field seen.
        var scratch: [MTLBuffer] = []
        /// Film grain tables, one per job, with what each holds: a repeated set (`show_existing_frame`) is not written
        /// again.
        var grain: [(buffer: MTLBuffer, holds: GrainKey?)] = []
        /// Constant luminance, one per such job: the counter and coordinates of the pixels the fast path flagged, and
        /// the indirect dispatch arguments for their recompute.
        var lists: [MTLBuffer] = []
        var arguments: [MTLBuffer] = []
        /// Indirect threadgroup counts, one per job whose dispatch the GPU decides (``Job/kept``).
        var gates: [MTLBuffer] = []
        /// What the work reads that its caller does not hold: the display buffers' textures, the luma table.
        var retained: [AnyObject] = []
    }

    static let slotCount = 3
    private let slots: [Slot]
    /// The next slot of the ring; the encoding thread's alone.
    private var nextSlot = 0
    private let inFlight = DispatchGroup()

    /// LibDeinterlace's kernels, submitting through this finisher's submitter.
    let kernels: DeinterlaceKernels

    init(device: MTLDevice) throws {
        self.device = device
        guard let submitter = GPUSubmitter(device: device, label: "PlanarFrameFinisher") else {
            throw FinisherError.unavailable("no GPU submission")
        }
        self.submitter = submitter
        kernels = DeinterlaceKernels(submission: DeinterlaceGPU(submitter))
        guard let placeholder = device.makeBuffer(length: 16, options: .storageModePrivate) else {
            throw FinisherError.unavailable("no buffer")
        }
        self.placeholder = placeholder
        slots = (0..<Self.slotCount).map { _ in Slot() }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw FinisherError.unavailable("no texture cache") }
        textureCache = cache
    }

    private static func library(for device: MTLDevice) throws -> MTLLibrary {
        if let cached = Self.library.withLock({ $0[ObjectIdentifier(device)] }) { return cached }
        let options = MTLCompileOptions()
        // IEEE rounding throughout: the rounding steps are H.273's Round.
        options.mathMode = .safe
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
        var boolIndices: Set<Int> = [20, 21, 22, 23, 31, 32]
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
    /// format): ``finish(_:completion:)`` for one job.
    func finish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer,
                grain: FilmGrainParameters? = nil, completion: @escaping @Sendable (_ failure: String?) -> Void) {
        finish([Job(source: .picture(planes), plan: plan, width: width, height: height, buffer: buffer, grain: grain)],
               completion: completion)
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
        /// The frame's AV1 film grain, for a plan with `grain`.
        var grain: FilmGrainParameters? = nil
        /// A 64-bit word written earlier in the batch (inverse telecine's decimate): the job is written when it is
        /// nonzero and dispatches nothing when it is zero, decided on the GPU.
        var kept: (buffer: MTLBuffer, offset: Int)? = nil
        /// A second picture of the source's layout and a 32-bit word written earlier in the batch: the job reads this
        /// picture in place of its source when the word is nonzero (inverse telecine's window passing its weave through).
        var passthrough: (planes: Planes, chosen: (buffer: MTLBuffer, offset: Int))? = nil
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

    private func scratchBuffer(_ slot: Slot, _ index: Int, length: Int) -> MTLBuffer? {
        while slot.scratch.count <= index {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            slot.scratch.append(made)
        }
        if slot.scratch[index].length < length {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            slot.scratch[index] = made
        }
        return slot.scratch[index]
    }

    /// Encodes `field`'s bwdif (LibDeinterlace) into the slot's scratch picture `scratchIndex`, which it returns.
    private func encodeField(_ field: Field, width: Int, height: Int, slot: Slot, scratchIndex: Int,
                             pass: ComputePass) -> Planes? {
        let layout = Self.scratchLayout(layout: field.layout, width: width, height: height)
        guard let buffer = scratchBuffer(slot, scratchIndex, length: layout.length) else { return nil }
        let out = Planes(buffer: buffer, offsets: layout.offsets, linesizes: layout.linesizes)
        guard kernels.encodeBwdif(field.bwdif, layout: field.layout, width: width, height: height, into: out, pass: pass)
        else { return nil }
        return out
    }

    // MARK: - Submission

    /// Writes every job in one batch and calls `completion` once, with nil when every job was written or why not: from
    /// the GPU's completion (on its queue, which must not be blocked: hand off), or on the caller's thread when a job
    /// cannot be encoded. The deinterlacer's dispatches of all the fields run together, then, after one barrier, the finisher's
    /// dispatches of all the jobs, the GPU filled by the work of both fields of a frame; a constant-luminance job, whose
    /// second and third dispatches read the first's list, comes last behind barriers of its own. Waits for a slot
    /// when ``slotCount`` submissions are in flight. The caller keeps the jobs' sources and buffers alive until
    /// `completion`.
    func finish(_ jobs: [Job], completion: @escaping @Sendable (_ failure: String?) -> Void) {
        guard !jobs.isEmpty else { return completion(nil) }
        if !finish({ _ in (jobs, nil, completion) }) { completion("no batch could be made") }
    }

    /// ``finish(_:completion:)`` behind work of the caller's own: `encode` encodes passes of its own into the batch
    /// first (inverse telecine) and returns the jobs to write after them, the fence the finish's pass waits on before
    /// reading what they wrote, and the completion. False, with `encode` never called, when no batch could be made.
    @discardableResult
    func finish(_ encode: (GPUBatch) -> (jobs: [Job], after: MTLFence?,
                                         completion: @Sendable (_ failure: String?) -> Void)) -> Bool {
        let slot = slots[nextSlot]
        nextSlot = (nextSlot + 1) % slots.count
        slot.free.wait()
        slot.retained.removeAll()
        let giveBack: @Sendable () -> Void = { slot.free.signal() }
        guard let batch = submitter.makeBatch() else {
            giveBack()
            return false
        }
        let (jobs, after, completion) = encode(batch)
        let encoded: Bool
        if jobs.isEmpty {
            encoded = true
        } else if let pass = batch.makePass() {
            if let after { pass.waitForFence(after) }
            encoded = self.encode(jobs, slot: slot, pass: pass)
        } else {
            encoded = false
        }
        inFlight.enter()
        batch.commit { [inFlight] result in
            let failure = encoded ? result.error : "a job could not be encoded"
            // Tables whose synthesis did not complete hold nothing a later job may reuse.
            if failure != nil { for index in slot.grain.indices { slot.grain[index].holds = nil } }
            giveBack()
            // After the hand-off: waitUntilIdle's caller (the end of a stream) then waits on what the completion handed on.
            completion(failure)
            inFlight.leave()
        }
        return true
    }

    /// Blocks until every submission made so far has completed: for the end of a stream, never per frame.
    func waitUntilIdle() { inFlight.wait() }

    /// Codes above 12 bits go straight to the exact path in the kernel (PF_EXACT_ONLY): no list, no second pass.
    private func usesList(_ plan: Plan) -> Bool { plan.mode == .constantLuminance && plan.components[0][4] <= 12 }

    private func encode(_ jobs: [Job], slot: Slot, pass: ComputePass) -> Bool {
        let jobs = jobs.map { job in
            var chosen = job
            chosen.plan.choosesSource = job.passthrough != nil
            return chosen
        }
        var sources: [Planes] = []
        var fields = 0
        for job in jobs {
            switch job.source {
            case .picture(let planes):
                sources.append(planes)
            case .field(let field):
                guard let planes = encodeField(field, width: job.width, height: job.height, slot: slot, scratchIndex: fields,
                                               pass: pass) else { return false }
                fields += 1
                sources.append(planes)
            }
        }
        // Each grained job's tables, synthesised on the GPU (when its parameters changed) alongside the fields: one
        // barrier for both before the finishes read them.
        var grains: [MTLBuffer] = []
        var synthesised = false
        for (index, job) in jobs.enumerated() {
            guard let tables = grainTables(job.grain, plan: job.plan, width: job.width, height: job.height, slot: slot, index: index)
            else { return false }
            if let grain = job.grain, tables.synthesise {
                guard let synthesize = try? pipeline(for: job.plan, function: "fg_synthesize") else { return false }
                pass.setPipeline(synthesize)
                pass.setBuffer(tables.buffer, offset: 0, index: 0)
                FilmGrainSynthesis.synthesisArguments(grain, width: job.width, height: job.height).withUnsafeBytes {
                    pass.setBytes($0, index: 1)
                }
                pass.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                synthesised = true
            }
            grains.append(tables.buffer)
        }
        // Each gated job's threadgroups from its word, beside the fields and the synthesis, behind the same barrier.
        var gates: [MTLBuffer?] = []
        for job in jobs {
            guard let kept = job.kept else { gates.append(nil); continue }
            guard let gate = try? pipeline(for: job.plan, function: "pf_gate"),
                  let shape = finishDispatch(job.plan, width: job.width, height: job.height, into: job.buffer),
                  let arguments = gateBuffer(slot, gates.compactMap { $0 }.count) else { return false }
            var groups: [UInt32] = [UInt32((shape.grid.width + shape.group.width - 1) / shape.group.width),
                                    UInt32((shape.grid.height + shape.group.height - 1) / shape.group.height), 1, 0]
            pass.setPipeline(gate)
            pass.setBuffer(kept.buffer, offset: kept.offset, index: 0)
            groups.withUnsafeMutableBytes { pass.setBytes(UnsafeRawBufferPointer($0), index: 1) }
            pass.setBuffer(arguments, offset: 0, index: 3)
            pass.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            gates.append(arguments)
        }
        if fields > 0 || synthesised || gates.contains(where: { $0 != nil }) { pass.barrier() }
        var lists = 0
        let order = jobs.indices.filter { !usesList(jobs[$0].plan) } + jobs.indices.filter { usesList(jobs[$0].plan) }
        for index in order {
            let job = jobs[index]
            let grain = grains[index]
            var list: (counter: MTLBuffer, arguments: MTLBuffer)?
            if usesList(job.plan) {
                guard let made = listBuffers(slot, lists, capacity: job.width * job.height) else { return false }
                list = made
                lists += 1
            }
            guard encodeFinish(sources[index], plan: job.plan, width: job.width, height: job.height, into: job.buffer,
                               grain: grain, list: list, gate: gates[index], passthrough: job.passthrough, slot: slot,
                               pass: pass) else { return false }
        }
        return true
    }

    /// The slot's list `index` for a constant-luminance job of `capacity` pixels, its counter zeroed.
    private func listBuffers(_ slot: Slot, _ index: Int, capacity: Int) -> (counter: MTLBuffer, arguments: MTLBuffer)? {
        while slot.lists.count <= index {
            guard let list = device.makeBuffer(length: 4 * (capacity + 1), options: .storageModeShared),
                  let arguments = device.makeBuffer(length: 16, options: .storageModePrivate) else { return nil }
            slot.lists.append(list)
            slot.arguments.append(arguments)
        }
        if slot.lists[index].length < 4 * (capacity + 1) {
            guard let list = device.makeBuffer(length: 4 * (capacity + 1), options: .storageModeShared) else { return nil }
            slot.lists[index] = list
        }
        slot.lists[index].contents().storeBytes(of: UInt32(0), as: UInt32.self)
        return (slot.lists[index], slot.arguments[index])
    }

    /// The slot's gate `index`: three threadgroup counts for one gated job.
    private func gateBuffer(_ slot: Slot, _ index: Int) -> MTLBuffer? {
        while slot.gates.count <= index {
            guard let made = device.makeBuffer(length: 16, options: .storageModePrivate) else { return nil }
            slot.gates.append(made)
        }
        return slot.gates[index]
    }

    /// The finish's grid and threadgroup: convert and constant luminance run one thread per source chroma sample (its
    /// block of pixels), the others one per sample of the buffer's chroma plane.
    private func finishDispatch(_ plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer) -> (grid: MTLSize, group: MTLSize)? {
        guard let pipeline = try? pipeline(for: plan) else { return nil }
        let w = pipeline.threadExecutionWidth
        let blocks = plan.mode == .convert || plan.mode == .constantLuminance
        let grid = blocks
            ? MTLSize(width: (width + (1 << Int(plan.sourceLog2[0])) - 1) >> Int(plan.sourceLog2[0]),
                      height: (height + (1 << Int(plan.sourceLog2[1])) - 1) >> Int(plan.sourceLog2[1]), depth: 1)
            : MTLSize(width: CVPixelBufferGetWidthOfPlane(buffer, 1), height: CVPixelBufferGetHeightOfPlane(buffer, 1), depth: 1)
        return (grid, MTLSize(width: w, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / w), depth: 1))
    }

    /// Encodes one picture's finishing dispatches, the buffer's textures kept in the slot until the work completes.
    /// `list` is a constant-luminance job's; `gate` the GPU's threadgroup counts for a gated job; `passthrough` the
    /// picture a job with a chosen source reads instead when its word says so.
    private func encodeFinish(_ planes: Planes, plan: Plan, width: Int, height: Int, into buffer: CVPixelBuffer,
                              grain: MTLBuffer, list: (counter: MTLBuffer, arguments: MTLBuffer)?, gate: MTLBuffer?,
                              passthrough: (planes: Planes, chosen: (buffer: MTLBuffer, offset: Int))?, slot: Slot,
                              pass: ComputePass) -> Bool {
        // One layout for both pictures: the frame's offsets and linesizes serve either.
        if let passthrough, passthrough.planes.offsets != planes.offsets || passthrough.planes.linesizes != planes.linesizes {
            return false
        }
        for p in 0..<4 where plan.planeAlignment[p] > 1 {
            guard planes.offsets[p] % UInt32(plan.planeAlignment[p]) == 0,
                  planes.linesizes[p] % UInt32(plan.planeAlignment[p]) == 0 else { return false }
        }
        let wide = plan.wideOutput
        guard let pipeline = try? pipeline(for: plan),
              let shape = finishDispatch(plan, width: width, height: height, into: buffer),
              let luma = texture(buffer, plane: 0, format: wide ? .r16Uint : .r8Uint),
              let chroma = texture(buffer, plane: 1, format: wide ? .rg16Uint : .rg8Uint),
              let lumaTexture = CVMetalTextureGetTexture(luma), let chromaTexture = CVMetalTextureGetTexture(chroma)
        else { return false }
        slot.retained += [luma, chroma]

        let constantLuminance = list != nil
        let capacity = width * height

        // PFFrame: twelve 32-bit words, then the double-float rows, constant-luminance and transfer constants (float2,
        // 8-byte aligned from offset 48), the near-tie bound and the list capacity.
        var frame = Data()
        for word in [UInt32(width), UInt32(height), UInt32(chromaTexture.width), UInt32(chromaTexture.height)]
            + planes.offsets + planes.linesizes { withUnsafeBytes(of: word) { frame.append(contentsOf: $0) } }
        for value in plan.rows + plan.cl + plan.tp + [plan.tieBound] { withUnsafeBytes(of: value) { frame.append(contentsOf: $0) } }
        withUnsafeBytes(of: UInt32(constantLuminance ? capacity : 0)) { frame.append(contentsOf: $0) }

        pass.setPipeline(pipeline)
        pass.setBuffer(planes.buffer, offset: 0, index: 0)
        frame.withUnsafeBytes { pass.setBytes($0, index: 1) }
        pass.setBuffer(list?.counter ?? placeholder, offset: 0, index: 2)
        pass.setBuffer(grain, offset: 0, index: 5)
        pass.setBuffer(passthrough?.planes.buffer ?? placeholder, offset: 0, index: 6)
        pass.setBuffer(passthrough?.chosen.buffer ?? placeholder, offset: passthrough?.chosen.offset ?? 0, index: 7)
        if !plan.lumaTable.isEmpty {
            if lumaTable?.values != plan.lumaTable {
                guard let made = device.makeBuffer(bytes: plan.lumaTable, length: 4 * plan.lumaTable.count, options: .storageModeShared)
                else { return false }
                lumaTable = (plan.lumaTable, made)
            }
            slot.retained.append(lumaTable!.buffer)
            pass.setBuffer(lumaTable!.buffer, offset: 0, index: 4)
        } else {
            pass.setBuffer(placeholder, offset: 0, index: 4)
        }
        pass.setTexture(lumaTexture, index: 0)
        pass.setTexture(chromaTexture, index: 1)
        if let gate {
            pass.dispatchThreadgroups(indirectBuffer: gate, offset: 0, threadsPerThreadgroup: shape.group)
        } else {
            pass.dispatchThreads(shape.grid, threadsPerThreadgroup: shape.group)
        }
        if let list {
            // The flagged pixels, sized on the GPU: one thread turns the count into indirect arguments, then each
            // flagged pixel is recomputed in double-float, each step behind a barrier on the one before.
            guard let prepare = try? self.pipeline(for: plan, function: "pf_cl_prepare"),
                  let correct = try? self.pipeline(for: plan, function: "pf_cl_correct") else { return false }
            pass.barrier()
            pass.setPipeline(prepare)
            pass.setBuffer(list.arguments, offset: 0, index: 3)
            pass.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            pass.barrier()
            pass.setPipeline(correct)
            pass.setBuffer(lumaTable!.buffer, offset: 0, index: 4)
            pass.dispatchThreadgroups(indirectBuffer: list.arguments, offset: 0,
                                      threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        return true
    }

    // MARK: - Film grain

    fileprivate struct GrainKey: Equatable {
        var parameters: FilmGrainParameters
        var width: Int
        var height: Int
    }

    /// Job `index`'s grain tables in `slot` (``FilmGrainSynthesis``) for `grain` at `width` x `height`: its header
    /// written, and `synthesise` when the GPU has to make the templates, scaling tables and offsets (a set the slot does
    /// not already hold; `show_existing_frame` repeats one). For a plan without grain, a placeholder the kernel never
    /// reads. Nil when the plan wants grain and the job carries none, or no buffer can be made.
    private func grainTables(_ grain: FilmGrainParameters?, plan: Plan, width: Int, height: Int, slot: Slot,
                             index: Int) -> (buffer: MTLBuffer, synthesise: Bool)? {
        guard plan.grain else { return (placeholder, false) }
        guard let grain else { return nil }
        let length = FilmGrainSynthesis.bufferLength(width: width, height: height)
        while slot.grain.count <= index {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            slot.grain.append((made, nil))
        }
        if slot.grain[index].buffer.length < length {
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            slot.grain[index] = (made, nil)
        }
        let key = GrainKey(parameters: grain, width: width, height: height)
        guard slot.grain[index].holds != key else { return (slot.grain[index].buffer, false) }
        FilmGrainSynthesis.writeHeader(grain, width: width, height: height, into: slot.grain[index].buffer.contents())
        slot.grain[index].holds = key
        return (slot.grain[index].buffer, true)
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
