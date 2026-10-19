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
        try #require(DoviFelComposer()).populateLumaLut(into: lut.contents().assumingMemoryBound(to: Float.self), params: params)
        let nlq = try #require(device.makeBuffer(length: 3 * 1024 * 4, options: .storageModeShared))
        DoviFelComposer.populateNlqLut(into: nlq.contents().assumingMemoryBound(to: Int32.self), params: params)
        return Rig(device: device, queue: queue, cache: try #require(cache), base: base, enhancement: el, params: pbuf, lut: lut, nlq: nlq)
    }

    static func texture(_ rig: Rig, _ b: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, rig.cache, b, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
        let cv = try #require(t)
        return (try #require(CVMetalTextureGetTexture(cv)), cv)
    }

    /// Median GPU milliseconds per dispatch of one kernel, over `iterations` command buffers of
    /// `dispatchesPerBuffer` dispatches each.
    static func time(_ rig: Rig, pipeline: MTLComputePipelineState, luma: Bool, out: CVPixelBuffer,
                     extraBuffers: [(MTLBuffer, Int)] = [], tgShape: (Int, Int)? = nil, pixelsPerThread: Int = 1) throws -> Double {
        let blY = try texture(rig, rig.base, plane: 0, .r16Uint), blUV = try texture(rig, rig.base, plane: 1, .rg16Uint)
        let elY = try texture(rig, rig.enhancement, plane: 0, .r16Uint), elUV = try texture(rig, rig.enhancement, plane: 1, .rg16Uint)
        let oY = try texture(rig, out, plane: 0, .r16Uint), oUV = try texture(rig, out, plane: 1, .rg16Uint)
        let w = pipeline.threadExecutionWidth
        let tg = tgShape.map { MTLSize(width: $0.0, height: $0.1, depth: 1) }
            ?? MTLSize(width: w, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, 8)), depth: 1)
        var samples: [Double] = []
        for i in 0..<(iterations + 3) {
            let cb = try #require(rig.queue.makeCommandBuffer())
            let enc = try #require(cb.makeComputeCommandEncoder())
            enc.setComputePipelineState(pipeline)
            enc.setTexture(blY.0, index: 0); enc.setTexture(blUV.0, index: 1)
            enc.setTexture(luma ? elY.0 : elUV.0, index: 2); enc.setTexture(luma ? oY.0 : oUV.0, index: 3)
            enc.setBuffer(rig.params, offset: 0, index: 0)
            enc.setBuffer(rig.lut, offset: 0, index: 1)
            enc.setBuffer(rig.nlq, offset: 0, index: 2)
            for (b, idx) in extraBuffers { enc.setBuffer(b, offset: 0, index: idx) }
            let grid = luma ? MTLSize(width: width / pixelsPerThread, height: height, depth: 1)
                            : MTLSize(width: width / 2 / pixelsPerThread, height: height / 2, depth: 1)
            for _ in 0..<dispatchesPerBuffer { enc.dispatchThreads(grid, threadsPerThreadgroup: tg) }
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
                       tgShape: (Int, Int)? = nil, pixelsPerThread: Int = 1) throws {
        let pipes = try DoviFelComposer.SharedPipelines.compile(device: rig.device, source: source)
        let p010 = try #require(makeBuffer(width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange))
        let sv22 = try #require(makeBuffer(width, height, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange))
        for (mode, dither, out, c422) in [("p010", DoviDither.bayer8x8, p010, false),
                                          ("sv22", DoviDither.fullPrecision, sv22, true)] {
            try setMode(rig, dither: dither, chroma422: c422)
            let l = try time(rig, pipeline: pipes.lumaPipeline, luma: true, out: out, extraBuffers: extra,
                             tgShape: tgShape, pixelsPerThread: pixelsPerThread)
            let c = try time(rig, pipeline: pipes.chromaPipeline, luma: false, out: out, extraBuffers: extra,
                             tgShape: tgShape, pixelsPerThread: pixelsPerThread)
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

    /// `source` with each (old, new) applied; fails if an `old` does not occur exactly once, so a variant
    /// cannot silently measure the baseline.
    static func patched(_ source: String, _ edits: [(String, String)]) throws -> String {
        var s = source
        for (a, b) in edits {
            #expect(s.components(separatedBy: a).count == 2, "variant edit not found exactly once: \(a.prefix(60))")
            s = s.replacingOccurrences(of: a, with: b)
        }
        return s
    }

    /// LUT in device memory: per-thread indices into `constant` memory serialise on Apple GPUs.
    static let deviceLut: [(String, String)] = [
        ("constant float*                        luma_lut      [[buffer(1)]],",
         "device const float*                    luma_lut      [[buffer(1)]],"),
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

    /// The full-precision word by shift: vdr_scale is a power of two and vdr_val is clamped >= 0.
    static let shiftFullPrecision: [(String, String)] = [
        ("    int v = (vdr_val * 64 + int(vdr_scale >> 1)) / int(vdr_scale);",
         "    int v = (vdr_val * 64 + int(vdr_scale >> 1)) >> ctz(vdr_scale);"),
    ]

    /// Each thread composes `n` horizontally adjacent sites (luma pixels / chroma samples) instead of one:
    /// the kernel body becomes a loop with `gid` rebound per site, its early `return`s turned into `continue`.
    static func multiPixel(_ source: String, n: Int) throws -> String {
        var s = source
        for name in ["dovi_compose_luma", "dovi_compose_chroma"] {
            let start = try #require(s.range(of: "kernel void \(name)("))
            let open = try #require(s.range(of: "{", range: start.upperBound..<s.endIndex))
            // The body ends at the first line that is exactly "}" after the opening brace.
            let close = try #require(s.range(of: "\n}\n", range: open.upperBound..<s.endIndex))
            var body = String(s[open.upperBound..<close.lowerBound])
            body = body.replacingOccurrences(of: "return;", with: "continue;")
            let header = String(s[start.lowerBound..<open.lowerBound])
                .replacingOccurrences(of: "uint2                                  gid           [[thread_position_in_grid]])",
                                      with: "uint2                                  gid0          [[thread_position_in_grid]])")
            let looped = header + "{\n    for (uint px = 0u; px < \(n)u; ++px) {\n    uint2 gid = uint2(gid0.x * \(n)u + px, gid0.y);\n" + body + "\n    }\n}\n"
            s.replaceSubrange(start.lowerBound..<close.upperBound, with: looped)
        }
        return s
    }

    /// The memory floor: each kernel reduced to its own input fetches and output write, no arithmetic.
    /// Luma: BL luma + one EL texel -> write. Chroma: the six BL luma taps, BL chroma, one EL texel -> write.
    static let floorOnly: [(String, String)] = [
        ("""
    int bl_y = int(bl_y_tex.read(gid).r >> 6);

    float pred;
""", """
    int bl_y = int(bl_y_tex.read(gid).r >> 6);
    {
        int e = int(el_y_tex.read(uint2(gid.x >> 1, gid.y >> 1)).r >> 6);
        out_y_tex.write(ushort4(ushort((bl_y + e) << 6), 0, 0, 0), gid);
        return;
    }
    float pred;
"""),
        ("""
    ushort4 bl_uv = bl_uv_tex.read(gid);
    int bl_cb = int(bl_uv.r >> 6);
""", """
    ushort4 bl_uv = bl_uv_tex.read(gid);
    {
        ushort e = el_uv_tex.read(uint2(gid.x >> 1, gid.y >> 1)).r;
        dovi_write_chroma(out_uv_tex, ushort4(ushort(bl_uv.r + ushort(bl_y) + e), bl_uv.g, 0, 0), gid, params.flags);
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
        ("        if (cb_active || cr_active) {", "        if (false) {"),
    ]
    static let chromaNoQuantize: [(String, String)] = [
        ("""
    int out_cb = dovi_quantize(vdr_cb, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 0u)), 64, 960);
    int out_cr = dovi_quantize(vdr_cr, params.vdr_scale, params.dither_mode,
                               dovi_dither(gid, params.frame_index, uint2(1u, 1u)), 64, 960);
""", """
    int out_cb = vdr_cb >> 2;
    int out_cr = vdr_cr >> 2;
"""),
    ]

    /// MMR coefficients converted and scaled once per frame on the CPU (float(coef) * 2^-shift, exact on
    /// both sides), read as floats from a device buffer: [component Cb, Cr][piece 0..7][constant, 21 terms].
    static let mmrFloat: [(String, String)] = [
        ("""
// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
""", """
static inline float dovi_eval_mmr_f(constant struct DoviPolynomialParams &curve, device const float* k,
                                    int piece, float y_norm, float u_norm, float v_norm) {
    device const float* c = k + piece * 22;
    float s = c[0];
    float base[7] = { y_norm, u_norm, v_norm, y_norm * u_norm, y_norm * v_norm, u_norm * v_norm,
                      y_norm * u_norm * v_norm };
    float t[7];
    for (int j = 0; j < 7; ++j) { t[j] = base[j]; }
    uint order = min(curve.order[piece], 3u);
    for (uint o = 0u; o < order; ++o) {
        for (int j = 0; j < 7; ++j) { s = fma(c[1u + o * 7u + uint(j)], t[j], s); }
        if (o + 1u < order) { for (int j = 0; j < 7; ++j) { t[j] *= base[j]; } }
    }
    return s;
}

static inline float dovi_eval_curve_f(
    constant struct DoviPolynomialParams &curve, device const float* k,
    constant struct DoviPolynomialParams &poly_y, constant struct DoviPolynomialParams &poly_cb,
    constant struct DoviPolynomialParams &poly_cr, int bl_val, float y_norm, float u_norm, float v_norm, uint bl_max)
{
    if (curve.num_pivots < 2u) { return float(bl_val) / float(bl_max); }
    int piece = dovi_select_piece(curve, bl_val);
    if (curve.method[piece] == DOVI_MAPPING_MMR) {
        float scale = float(bl_max);
        return dovi_eval_mmr_f(curve, k, piece, dovi_clamp_mmr_input(poly_y, y_norm, scale),
                               dovi_clamp_mmr_input(poly_cb, u_norm, scale), dovi_clamp_mmr_input(poly_cr, v_norm, scale));
    }
    return dovi_eval_poly(curve, piece, bl_val, bl_max);
}

// Chroma: both chroma planes in one pass, since an MMR curve for Cb and for Cr
"""),
        ("""
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width
""", """
    device const float*                    mmr_f         [[buffer(3)]],
    uint2                                  gid           [[thread_position_in_grid]])
{
    uint uv_width
"""),
        ("""
    float pred_cb = dovi_eval_curve(params.poly_cb, params.mmr_cb,
""", """
    float pred_cb = dovi_eval_curve_f(params.poly_cb, mmr_f,
"""),
        ("""
    float pred_cr = dovi_eval_curve(params.poly_cr, params.mmr_cr,
""", """
    float pred_cr = dovi_eval_curve_f(params.poly_cr, mmr_f + 8 * 22,
"""),
    ]

    static func mmrTable(_ rig: Rig) throws -> MTLBuffer {
        let p = try clipAParams()
        let buf = try #require(rig.device.makeBuffer(length: 2 * 8 * 22 * 4, options: .storageModeShared))
        let out = buf.contents().assumingMemoryBound(to: Float.self)
        for (c, mmr) in [p.mmrCb, p.mmrCr].enumerated() {
            let inv = ldexpf(1, -Int32(mmr.coefShift))
            for piece in 0..<8 {
                out[(c * 8 + piece) * 22] = Float(mmr.constant[piece]) * inv
                for t in 0..<21 { out[(c * 8 + piece) * 22 + 1 + t] = Float(mmr.coef[piece][t]) * inv }
            }
        }
        return buf
    }

    @Test("UHD composition GPU time per kernel", .enabled(if: enabled, "set DOVI_BENCH=1"))
    func uhdKernelTimes() throws {
        let rig = try Self.rig()
        let mmrT = try Self.mmrTable(rig)
        print("[bench] device \(rig.device.name), \(Self.width)x\(Self.height), median of \(Self.iterations)")
        let base = DoviShaderSource.source
        let all = Self.deviceLut + Self.lazyDither + Self.shiftFullPrecision
        let variants: [(String, String, [(MTLBuffer, Int)])] = [
            ("baseline     ", base, []),
            ("device-lut   ", try Self.patched(base, Self.deviceLut), []),
            ("lazy-dither  ", try Self.patched(base, Self.lazyDither), []),
            ("shift-fullp  ", try Self.patched(base, Self.shiftFullPrecision), []),
            ("all          ", try Self.patched(base, all), []),
            ("mmr-float    ", try Self.patched(base, Self.mmrFloat), [(mmrT, 3)]),
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
            for shape in [(32, 4), (32, 16), (64, 4), (16, 16), (128, 2)] where ProcessInfo.processInfo.environment["DOVI_BENCH_ALL"] == "1" {
                try Self.report("tg \(shape.0)x\(shape.1)     ", source: base, rig: rig, tgShape: shape)
            }
            for n in [2, 4] where ProcessInfo.processInfo.environment["DOVI_BENCH_ALL"] == "1" {
                try Self.report("\(n) px/thread  ", source: try Self.multiPixel(base, n: n), rig: rig, pixelsPerThread: n)
            }
        }
    }
}
#endif
