// Only with the DualLayerDolbyVision trait: the composer is not built without it.
#if DualLayerDolbyVision
import Testing
import Foundation
import CoreVideo
import Metal
import Dovi
@testable import AetherEngine

/// GPU cost of each composition kernel at UHD, from command-buffer timestamps. Not a test: it asserts
/// nothing and only runs with `DOVI_BENCH=1`, printing one `[bench]` line per kernel and variant.
///
/// The parameters are a real disc RPU (clip A: 8-piece polynomial luma, order-3 MMR chroma, linear NLQ),
/// and the planes carry varied content so piece selection and the residual are exercised as on a film:
/// a luma ramp across the frame with noise, chroma swept around neutral, an EL of +-40 codes around 512.
/// Each kernel is timed alone in its own command buffer, repeated, and the median reported.
@Suite(.serialized, .offCooperativePoolOneLane)
struct DoviGpuBenchmark {

    static let enabled = ProcessInfo.processInfo.environment["DOVI_BENCH"] == "1"
    /// Command buffers per measurement, and back-to-back dispatches in each: batching keeps the GPU busy
    /// and clocked up (a single dispatch per buffer measures the clock ramp, not the kernel).
    static let iterations = 15
    static let dispatchesPerBuffer = 20
    static let width = 3840, height = 2160

    struct Rig {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let cache: CVMetalTextureCache
        let base: CVPixelBuffer
        let enhancement: CVPixelBuffer
        let params: MTLBuffer
        let lut: MTLBuffer
        /// The inverse-NLQ table the kernels index (`DoviFelComposer.populateNlqLut`), bound at buffer 2.
        let nlq: MTLBuffer
        /// The MMR coefficient table (`DoviFelComposer.populateMmrTable`), bound at buffer 3.
        let mmr: MTLBuffer
    }

    static func clipAParams() throws -> DoviMetalParams {
        let hex = DoviFelMathTests.clipARpuHex
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            bytes.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        let rpu = try #require(dovi_parse_unspec62_nalu(bytes, bytes.count))
        defer { dovi_rpu_free(rpu) }
        var p = try #require(DoviFelComposer.parseRpuParameters(rpu: rpu))
        p.flags.remove(.disableResidual)
        return p
    }

    static func makeBuffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &b)
        return b
    }

    /// Fills a P010 buffer: plane 0 from `y(x, row)`, plane 1 from `uv(x, row, component)`, as 10-bit codes.
    static func fill(_ b: CVPixelBuffer, y: (Int, Int) -> Int, uv: (Int, Int, Int) -> Int) {
        CVPixelBufferLockBaseAddress(b, []); defer { CVPixelBufferUnlockBaseAddress(b, []) }
        for plane in 0..<2 {
            let base = CVPixelBufferGetBaseAddressOfPlane(b, plane)!
            let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane) / 2
            let w = CVPixelBufferGetWidthOfPlane(b, plane), h = CVPixelBufferGetHeightOfPlane(b, plane)
            let p = base.assumingMemoryBound(to: UInt16.self)
            for row in 0..<h {
                for x in 0..<w {
                    if plane == 0 {
                        p[row * stride + x] = UInt16(min(max(y(x, row), 0), 1023) << 6)
                    } else {
                        p[row * stride + 2 * x] = UInt16(min(max(uv(x, row, 0), 0), 1023) << 6)
                        p[row * stride + 2 * x + 1] = UInt16(min(max(uv(x, row, 1), 0), 1023) << 6)
                    }
                }
            }
        }
    }

    static func rig() throws -> Rig {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let queue = try #require(device.makeCommandQueue())
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let base = try #require(makeBuffer(width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        let el = try #require(makeBuffer(width / 2, height / 2, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        // Cheap deterministic noise, so neighbouring pixels differ like grain does.
        func n(_ x: Int, _ y: Int) -> Int { Int((UInt32(truncatingIfNeeded: x &* 73_856_093 ^ y &* 19_349_663) >> 7) % 33) - 16 }
        fill(base, y: { x, r in 64 + x * 876 / width + n(x, r) },
             uv: { x, r, c in 512 + (c == 0 ? (x * 2 * 300 / width) - 150 : (r * 2 * 300 / height) - 150) + n(x, r) / 2 })
        fill(el, y: { x, r in 512 + n(x, r) * 40 / 16 }, uv: { x, r, _ in 512 + n(r, x) * 20 / 16 })
        var params = try clipAParams()
        params.blWidth = UInt32(width); params.blHeight = UInt32(height)
        params.elWidth = UInt32(width / 2); params.elHeight = UInt32(height / 2)
        let pbuf = try #require(device.makeBuffer(length: DoviMetalParams.serializedSize, options: .storageModeShared))
        params.serialize(into: UnsafeMutableRawBufferPointer(start: pbuf.contents(), count: DoviMetalParams.serializedSize))
        let lut = try #require(device.makeBuffer(length: 1024 * 4, options: .storageModeShared))
        try #require(DoviFelComposer()).populateLumaLut(into: lut.contents().assumingMemoryBound(to: Int32.self), params: params)
        let nlq = try #require(device.makeBuffer(length: 3 * DoviFelComposer.nlqLutCodes * 4, options: .storageModeShared))
        DoviFelComposer.populateNlqLut(into: nlq.contents().assumingMemoryBound(to: Int32.self), params: params)
        let mmr = try #require(device.makeBuffer(length: DoviFelComposer.mmrTableCount * 4, options: .storageModeShared))
        DoviFelComposer.populateMmrTable(into: mmr.contents().assumingMemoryBound(to: Int32.self), params: params)
        return Rig(device: device, queue: queue, cache: try #require(cache), base: base, enhancement: el, params: pbuf, lut: lut, nlq: nlq, mmr: mmr)
    }

    static func texture(_ rig: Rig, _ b: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, rig.cache, b, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
        let cv = try #require(t)
        return (try #require(CVMetalTextureGetTexture(cv)), cv)
    }

    /// Median GPU milliseconds per dispatch of one kernel, over `iterations` command buffers of
    /// `dispatchesPerBuffer` dispatches each. With `chroma422`, sv22's step (`dovi_chroma_420_to_422`) follows each
    /// chroma dispatch, the chroma kernel writing the 4:2:0 intermediate it reads, as the composer encodes them; the
    /// time is the two together. The UHD planes are whole multiples of the 32-wide threadgroups the composition kernels
    /// need, so `dispatchThreads` launches whole threadgroups.
    static func time(_ rig: Rig, pipeline: MTLComputePipelineState, luma: Bool, chroma422: MTLComputePipelineState? = nil,
                     out: CVPixelBuffer, extraBuffers: [(MTLBuffer, Int)] = [], tgShape: (Int, Int)? = nil) throws -> Double {
        let blY = try texture(rig, rig.base, plane: 0, .r16Uint), blUV = try texture(rig, rig.base, plane: 1, .rg16Uint)
        let elY = try texture(rig, rig.enhancement, plane: 0, .r16Uint), elUV = try texture(rig, rig.enhancement, plane: 1, .rg16Uint)
        let oY = try texture(rig, out, plane: 0, .r16Uint), oUV = try texture(rig, out, plane: 1, .rg16Uint)
        let w = pipeline.threadExecutionWidth
        let tg = tgShape.map { MTLSize(width: $0.0, height: $0.1, depth: 1) }
            ?? MTLSize(width: w, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, 8)), depth: 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Uint, width: width / 2, height: height / 2, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let chroma420 = try #require(rig.device.makeTexture(descriptor: descriptor))
        var samples: [Double] = []
        for i in 0..<(iterations + 3) {
            let cb = try #require(rig.queue.makeCommandBuffer())
            let enc = try #require(cb.makeComputeCommandEncoder())
            enc.setTexture(blY.0, index: 0); enc.setTexture(blUV.0, index: 1)
            enc.setBuffer(rig.params, offset: 0, index: 0)
            enc.setBuffer(rig.lut, offset: 0, index: 1)
            enc.setBuffer(rig.nlq, offset: 0, index: 2)
            enc.setBuffer(rig.mmr, offset: 0, index: 3)
            for (b, idx) in extraBuffers { enc.setBuffer(b, offset: 0, index: idx) }
            let grid = luma ? MTLSize(width: width, height: height, depth: 1) : MTLSize(width: width / 2, height: height / 2, depth: 1)
            for _ in 0..<dispatchesPerBuffer {
                enc.setComputePipelineState(pipeline)
                enc.setTexture(luma ? elY.0 : elUV.0, index: 2)
                enc.setTexture(luma ? oY.0 : (chroma422 == nil ? oUV.0 : chroma420), index: 3)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
                if let chroma422 {
                    // A serial encoder: the step sees what the chroma dispatch wrote.
                    enc.setComputePipelineState(chroma422)
                    enc.setTexture(chroma420, index: 0); enc.setTexture(oUV.0, index: 1)
                    enc.dispatchThreads(MTLSize(width: width / 2, height: height, depth: 1), threadsPerThreadgroup: tg)
                    enc.setTexture(blY.0, index: 0); enc.setTexture(blUV.0, index: 1)
                }
            }
            enc.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            // 3 warm-up buffers
            if i >= 3 { samples.append((cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(dispatchesPerBuffer)) }
        }
        _ = (blY.1, blUV.1, elY.1, elUV.1, oY.1, oUV.1)
        return samples.sorted()[samples.count / 2]
    }

    /// Patches the dither and flag words of the uploaded parameter block for one output mode.
    static func setMode(_ rig: Rig, dither: DoviDither, chroma422: Bool) throws {
        var p = try clipAParams()
        p.blWidth = UInt32(width); p.blHeight = UInt32(height)
        p.elWidth = UInt32(width / 2); p.elHeight = UInt32(height / 2)
        p.ditherMode = dither
        if chroma422 { p.flags.insert(.chroma422) }
        p.serialize(into: UnsafeMutableRawBufferPointer(start: rig.params.contents(), count: DoviMetalParams.serializedSize))
    }

    /// Both planes of `b`, raw 16-bit words, row by row without padding.
    static func planes(_ b: CVPixelBuffer) -> [UInt16] {
        CVPixelBufferLockBaseAddress(b, .readOnly); defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        var out: [UInt16] = []
        for plane in 0..<2 {
            let p = CVPixelBufferGetBaseAddressOfPlane(b, plane)!.assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane) / 2
            let words = CVPixelBufferGetWidthOfPlane(b, plane) * (plane == 0 ? 1 : 2)
            for row in 0..<CVPixelBufferGetHeightOfPlane(b, plane) {
                out.append(contentsOf: UnsafeBufferPointer(start: p + row * stride, count: words))
            }
        }
        return out
    }

    nonisolated(unsafe) static var reference: [String: [UInt16]] = [:]
    nonisolated(unsafe) static var quiet = false

    static func report(_ label: String, source: String, rig: Rig, extra: [(MTLBuffer, Int)] = [],
                       tgShape: (Int, Int)? = nil) throws {
        let pipes = try DoviFelComposer.SharedPipelines.compile(device: rig.device, source: source)
        let p010 = try #require(makeBuffer(width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        let sv22 = try #require(makeBuffer(width, height, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange))
        for (mode, dither, out, c422) in [("p010", DoviDither.bayer8x8, p010, false),
                                          ("p010-bn", DoviDither.blueNoise, p010, false),
                                          ("sv22", DoviDither.fullPrecision, sv22, true)] {
            try setMode(rig, dither: dither, chroma422: c422)
            let kernels = try pipes.kernels(.init(blueNoise: dither == .blueNoise))
            let l = try time(rig, pipeline: kernels.luma, luma: true, out: out, extraBuffers: extra, tgShape: tgShape)
            let c = try time(rig, pipeline: kernels.chroma, luma: false, chroma422: c422 ? kernels.chroma422 : nil, out: out,
                             extraBuffers: extra, tgShape: tgShape)
            // The last timed dispatch of each kernel left its output; it must match the baseline's bit for bit.
            let words = planes(out)
            let verdict: String
            if label.hasPrefix("FLOOR") || label.hasPrefix("c: ") {
                verdict = "(not a composition)"
            } else if let ref = reference[mode] {
                let diff = zip(words, ref).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                verdict = diff == 0 ? "bit-exact" : "DIFFERS in \(diff) words"
                #expect(diff == 0, "\(label) \(mode) differs from the baseline in \(diff) words")
            } else {
                reference[mode] = words
                verdict = "reference"
            }
            if !quiet { print(String(format: "[bench] %@ %@  luma %.3f ms  chroma %.3f ms  total %.3f ms  %@", label, mode, l, c, l + c, verdict)) }
        }
    }

    // MARK: - Variants

    /// `source` with each (old, new) applied at every occurrence; fails if an `old` does not occur, so a variant
    /// cannot silently measure the baseline. Every occurrence, because the 4:2:0 and 4:2:2 chroma kernels share
    /// some lines (the quantisation, the residual gate) and a variant applies to both.
    static func patched(_ source: String, _ edits: [(String, String)]) throws -> String {
        var s = source
        for (a, b) in edits {
            #expect(s.components(separatedBy: a).count >= 2, "variant edit not found: \(a.prefix(60))")
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    /// LUT in device memory: per-thread indices into `constant` memory serialise on Apple GPUs.
    static let deviceLut: [(String, String)] = [
        ("constant int*                          luma_lut      [[buffer(1)]],",
         "device const int*                      luma_lut      [[buffer(1)]],"),
    ]

    /// Dither only where it is used, and its table addressed arithmetically instead of a constant array:
    /// the Bayer value at (x, y) is the bit-reversed interleave of (x ^ y, y) over three bits.
    static let lazyDither: [(String, String)] = [
        ("""
    uint dx = (gid.x + phase.x) % 8u;
    uint dy = (gid.y + phase.y) % 8u;
    float d = dovi_bayer_8x8[dy * 8u + dx];
""", """
    uint dx = (gid.x + phase.x) & 7u;
    uint dy = (gid.y + phase.y) & 7u;
    uint xy = dx ^ dy;
    uint k = ((xy & 1u) << 5) | ((dy & 1u) << 4) | ((xy & 2u) << 2) | ((dy & 2u) << 1) | ((xy & 4u) >> 1) | ((dy & 4u) >> 2);
    float d = float(k) * (1.0f / 64.0f);
"""),
    ]

    /// The memory floor: each kernel reduced to its own input fetches and output write, no arithmetic.
    /// Luma: BL luma + one EL texel -> write. Chroma: the six BL luma taps, BL chroma, one EL texel -> write.
    static let floorOnly: [(String, String)] = [
        ("""
    int bl_y = int(bl_y_tex.read(gid).r >> 6);

    int h;
""", """
    int bl_y = int(bl_y_tex.read(gid).r >> 6);
    {
        int e = int(el_y_tex.read(uint2(gid.x >> 1, gid.y >> 1)).r >> 6);
        out_y_tex.write(ushort4(ushort((bl_y + e) << 6), 0, 0, 0), gid);
        return;
    }
    int h;
"""),
        ("""
    ushort4 bl_uv = bl_uv_tex.read(gid);
    int bl_cb = int(bl_uv.r >> 6);
""", """
    ushort4 bl_uv = bl_uv_tex.read(gid);
    {
        ushort e = el_uv_tex.read(uint2(gid.x >> 1, gid.y >> 1)).r;
        out_uv_tex.write(ushort4(ushort(bl_uv.r + ushort(bl_y) + e), bl_uv.g, 0, 0), gid);
        return;
    }
    int bl_cb = int(bl_uv.r >> 6);
"""),
    ]

    /// Bisection of the chroma kernel's cost (timing only, not compositions).
    static let chromaOneTap: [(String, String)] = [
        ("""
        int row = int(bl_y_tex.read(uint2(lxl, ly)).r >> 6)
                + 2 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6)
                + int(bl_y_tex.read(uint2(lxr, ly)).r >> 6);
""", """
        int row = 4 * int(bl_y_tex.read(uint2(lx, ly)).r >> 6);
"""),
    ]
    static let chromaNoMmr: [(String, String)] = [
        ("    if (curve.method[piece] == DOVI_MAPPING_MMR) {", "    if (false) {"),
    ]
    static let chromaNoResidual: [(String, String)] = [
        ("    if (residual && dovi_residual_at(params, gid.x * 2u)) {", "    if (false) {"),
    ]
    static let chromaNoQuantize: [(String, String)] = [
        ("""
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);
""", """
    int out_cb = h_cb >> 6;
    int out_cr = h_cr >> 6;
"""),
    ]

    @Test("UHD composition GPU time per kernel", .enabled(if: enabled, "set DOVI_BENCH=1"))
    func uhdKernelTimes() throws {
        let rig = try Self.rig()
        print("[bench] device \(rig.device.name), \(Self.width)x\(Self.height), median of \(Self.iterations)")
        let base = DoviShaderSource.source
        let all = Self.deviceLut + Self.lazyDither
        let variants: [(String, String, [(MTLBuffer, Int)])] = [
            ("baseline     ", base, []),
            ("device-lut   ", try Self.patched(base, Self.deviceLut), []),
            ("lazy-dither  ", try Self.patched(base, Self.lazyDither), []),
            ("all          ", try Self.patched(base, all), []),
            ("FLOOR (I/O)  ", try Self.patched(base, Self.floorOnly), []),
            ("c: 1-tap luma", try Self.patched(base, Self.chromaOneTap), []),
            ("c: no MMR    ", try Self.patched(base, Self.chromaNoMmr), []),
            ("c: no resid. ", try Self.patched(base, Self.chromaNoResidual), []),
            ("c: no quant. ", try Self.patched(base, Self.chromaNoQuantize), []),
        ]
        // Two passes, the first unreported: it brings the GPU to a steady clock and compiles everything.
        for pass in 0..<2 {
            Self.quiet = pass == 0
            for (label, source, extra) in variants { try Self.report(label, source: source, rig: rig, extra: extra) }
            // Widths that are multiples of 32, so each SIMD-group is one row's 32 consecutive columns (the EL shuffles).
            for shape in [(32, 4), (32, 16), (64, 4), (128, 2)] where ProcessInfo.processInfo.environment["DOVI_BENCH_ALL"] == "1" {
                try Self.report("tg \(shape.0)x\(shape.1)     ", source: base, rig: rig, tgShape: shape)
            }
        }
    }
}
#endif
