// Only with the DualLayerDolbyVision trait (off by default).
#if DualLayerDolbyVision
import Foundation
import CoreVideo
import Metal
import QuartzCore
import Dovi

/// GPU cost of each composition kernel at UHD on the device it runs on, from command-buffer timestamps: the
/// package's `DoviGpuBenchmark` on a Mac, the app's test bundle on an Apple TV, where package tests cannot run.
///
/// The parameters are a real disc RPU (clip A: 8-piece polynomial luma, order-3 MMR chroma, linear NLQ), and the
/// planes carry varied content so piece selection and the residual are exercised as on a film: a luma ramp across
/// the frame with noise, chroma swept around neutral, an EL of +-40 codes around 512.
///
/// Two ways of timing. Batched: each kernel alone, `dispatchesPerBuffer` dispatches to a command buffer, which keeps
/// the GPU busy and clocked up, the median of `iterations` buffers. Paced: one whole composition (luma, chroma and
/// sv22's 4:2:2 step) to a command buffer, one every 24p frame, as playback submits them, which leaves the GPU idle
/// between frames as playback does.
public enum FelComposerBenchmark {

    /// One `[bench]` line per variant and output mode, then the paced compositions, each handed to `emit` as it is
    /// measured and all of them returned. Each composition variant's output is compared with the baseline's, bit for
    /// bit. `allVariants` false times the baseline and the memory floor alone: on an Apple TV every variant's shader
    /// compile costs tens of seconds.
    public static func run(allVariants: Bool = true, sv22Only: Bool = false, emit: (String) -> Void = { print($0) }) -> String {
        var lines: [String] = []
        func say(_ line: String) { lines.append(line); emit(line) }
        do {
            let rig = try Rig()
            say("[bench] device \(rig.device.name), \(rig.gpu.api), \(width)x\(height), median of \(iterations)")
            let base = DoviShaderSource.source
            let quick: [(String, String)] = [("baseline     ", base), ("FLOOR (I/O)  ", try patched(base, floorOnly))]
            let variants: [(String, String)] = !allVariants ? quick : [
                ("baseline     ", base),
                ("device-lut   ", try patched(base, deviceLut)),
                ("lazy-dither  ", try patched(base, lazyDither)),
                ("all          ", try patched(base, deviceLut + lazyDither)),
                ("FLOOR (I/O)  ", try patched(base, floorOnly)),
                ("c: 1-tap luma", try patched(base, chromaOneTap)),
                ("c: no MMR    ", try patched(base, chromaNoMmr)),
                ("c: no resid. ", try patched(base, chromaNoResidual)),
                ("c: no quant. ", try patched(base, chromaNoQuantize)),
                ("l: no resid. ", try patched(base, lumaNoResidual)),
                ("l: no EL h   ", try patched(base, lumaNoHorizontal)),
                ("l: no EL v   ", try patched(base, lumaNoVertical)),
                ("l: no NLQ    ", try patched(base, lumaNoNlq)),
                ("c: no MMR sum", try patched(base, chromaNoMmrSum)),
                ("c: no int sum", try patched(base, chromaNoIntSum)),
                ("c: no fl. sum", try patched(base, chromaNoFloatSum)),
            ]
            var reference: [String: [UInt16]] = [:]
            // Two passes, the first unreported: it brings the GPU to a steady clock and compiles everything.
            for pass in 0..<2 {
                for (label, source) in variants {
                    let reported = try report(label, source: source, rig: rig, reference: &reference, sv22Only: sv22Only)
                    if pass == 1 { reported.forEach(say) }
                }
            }
            for gap in pacedGaps { say(try paced(rig: rig, gapSeconds: gap, perBuffer: 1)) }
            // Playback's batches: two frames every two 24p frames, then three every three.
            say(try paced(rig: rig, gapSeconds: frameSeconds * 2, perBuffer: 2))
            say(try paced(rig: rig, gapSeconds: frameSeconds * 3, perBuffer: 3))
        } catch {
            say("[bench] failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// For a GPU counter recording (Instruments' Metal GPU Counters): each kernel of the sv22 composition, and two
    /// bisection variants, run back to back for `profileSeconds`, one after another in a fixed order with
    /// `profileGapSeconds` of idle GPU between them, so each busy stretch of the recording is one kernel's. Each stretch
    /// is handed to `emit` as it starts.
    public static func profile(emit: (String) -> Void = { print($0); fflush(stdout) }) -> String {
        var lines: [String] = []
        let start = CACurrentMediaTime()
        func say(_ line: String) { lines.append(line); emit(line) }
        func elapsed() -> String { String(format: "%.1f s", CACurrentMediaTime() - start) }
        do {
            let rig = try Rig()
            say("[profile] rig built at \(elapsed())")
            try setMode(rig, dither: .fullPrecision, chroma422: true)
            let base = DoviShaderSource.source
            // name, label, source, luma (else chroma + 4:2:2), the exact MMR pipelines. A pipeline's registers are
            // set when it is compiled, for every path in it, so one stretch covers a kernel's rarer paths too (luma's
            // MMR branch); the exact MMR sums are pipelines of their own.
            // Each stretch's source is patched only when the stretch is asked for.
            let known: [(String, String, () throws -> String, Kind, Bool)] = [
                ("luma", "luma", { base }, .luma, false),
                ("chroma", "chroma + 4:2:2", { base }, .chromaAnd422, false),
                ("chroma-exact", "chroma + 4:2:2, exact MMR pipeline", { base }, .chromaAnd422, true),
                ("chroma-nommr", "chroma + 4:2:2, no MMR", { try patched(base, chromaNoMmr) }, .chromaAnd422, false),
                ("chroma-nocoef", "chroma + 4:2:2, MMR coefficients not loaded",
                 { try patched(base, [("    int c = simd_shuffle(loaded, i);", "    int c = int(i) * 7 + 1;")]) }, .chromaAnd422, false),
                ("chroma-noresid", "chroma + 4:2:2, no EL residual", { try patched(base, chromaNoResidual) }, .chromaAnd422, false),
                ("chroma-1tap", "chroma + 4:2:2, base luma one tap", { try patched(base, chromaOneTap) }, .chromaAnd422, false),
                ("chroma-only", "chroma alone (sv22's 4:2:0 intermediate)", { base }, .chroma, false),
                ("422", "sv22's 4:2:0 -> 4:2:2 step alone", { base }, .step422, false),
                // Chroma alone with code taken out of the source, so the pipeline loses its registers too.
                ("cx-nommr", "chroma alone, no MMR code",
                 { try patched(base, [("    bool pending = need;\n", "    bool pending = need;\n    return;\n")]) }, .chroma, false),
                ("cx-noel", "chroma alone, no EL code",
                 { try patched(base, [("    int2 el_code = int2(0);\n    if (residual) {", "    int2 el_code = int2(0);\n    if (false) {")]) },
                 .chroma, false),
                ("cx-nopoly", "chroma alone, no polynomial code",
                 { try patched(base, [("dovi_eval_curve(params.poly_cb, piece_cb, c1, shift)", "int(c1 >> 4)"),
                                      ("dovi_eval_curve(params.poly_cr, piece_cr, c2, shift)", "int(c2 >> 4)")]) }, .chroma, false),
                ("floor", "luma, memory floor", { try patched(base, floorOnly) }, .luma, false),
            ]
            let wanted = ProcessInfo.processInfo.environment["DOVI_PROFILE_STRETCHES"]?.split(separator: ",").map(String.init)
                ?? ["luma", "chroma", "chroma-nommr", "floor"]
            let stretches = try wanted.map { name in
                let stretch = try require(known.first { $0.0 == name }, "no profile stretch named \(name)")
                return (stretch.1, try stretch.2(), stretch.3, stretch.4)
            }
            let out = try require(makeBuffer(width, height, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange), "no sv22 output")
            let planes = try Planes(rig, out: out)
            // Every pipeline compiled before the first stretch, so a recording started at "ready" holds kernels only.
            let compiled = try stretches.map { stretch -> DoviFelComposer.SharedPipelines.Kernels in
                let kernels = try DoviFelComposer.SharedPipelines.compile(device: rig.device, source: stretch.1)
                    .kernels(.init(blueNoise: false, mmrExact: stretch.3))
                say("[profile] \(stretch.0) compiled at \(elapsed())")
                return kernels
            }
            // With `DOVI_PROFILE_TRIGGER` set, the stretches wait for that file to exist (a recording that has started),
            // for at most `profileTriggerTimeout`, having made `<trigger>.ready` to say they are waiting.
            if let trigger = ProcessInfo.processInfo.environment["DOVI_PROFILE_TRIGGER"] {
                say("[profile] ready: waiting for \(trigger)")
                // The recorder watches for this file: a line on stdout reaches it only when the test runner flushes.
                FileManager.default.createFile(atPath: trigger + ".ready", contents: nil)
                let deadline = CACurrentMediaTime() + profileTriggerTimeout
                while !FileManager.default.fileExists(atPath: trigger), CACurrentMediaTime() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            } else {
                say("[profile] ready: the first stretch starts in \(Int(profileLeadSeconds)) s")
                Thread.sleep(forTimeInterval: profileLeadSeconds)
            }
            for (index, (label, _, kind, _)) in stretches.enumerated() {
                let kernels = compiled[index]
                let pipeline = kind == .luma ? kernels.luma : kind == .step422 ? kernels.chroma422 : kernels.chroma
                say(String(format: "[profile] stretch %d: %@, %.0f s busy, then %.0f s idle; threadgroup limit %d, SIMD width %d",
                           index + 1, label, profileSeconds, profileGapSeconds,
                           pipeline.maxTotalThreadsPerThreadgroup, pipeline.threadExecutionWidth))
                let end = CACurrentMediaTime() + profileSeconds
                while CACurrentMediaTime() < end {
                    let batch = try require(rig.gpu.makeBatch(), "no batch")
                    let pass = try require(batch.makePass(), "no pass")
                    for _ in 0..<dispatchesPerBuffer {
                        switch kind {
                        case .luma: encode(pass, rig, planes, pipeline: pipeline, luma: true, chroma422: nil)
                        case .chromaAnd422: encode(pass, rig, planes, pipeline: pipeline, luma: false, chroma422: kernels.chroma422)
                        case .chroma: encodeChroma420(pass, rig, planes, pipeline: pipeline)
                        case .step422: encode422(pass, planes, pipeline: pipeline)
                        }
                        pass.barrier()
                    }
                    if let error = rig.gpu.commitAndWait(batch).error { throw BenchmarkError(description: error) }
                }
                Thread.sleep(forTimeInterval: profileGapSeconds)
            }
        } catch {
            say("[profile] failed: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    /// What a profile stretch dispatches.
    enum Kind { case luma, chromaAnd422, chroma, step422 }

    /// The chroma kernel alone, writing sv22's 4:2:0 intermediate.
    static func encodeChroma420(_ pass: ComputePass, _ rig: Rig, _ planes: Planes, pipeline: MTLComputePipelineState) {
        pass.setTexture(planes.blY.0, index: 0); pass.setTexture(planes.blUV.0, index: 1)
        pass.setBuffer(rig.params, index: 0)
        pass.setBuffer(rig.nlq, index: 2)
        pass.setBuffer(rig.mmr, index: 3)
        pass.setPipeline(pipeline)
        pass.setTexture(planes.elUV.0, index: 2)
        pass.setTexture(planes.chroma420, index: 3)
        pass.dispatchThreads(MTLSize(width: width / 2, height: height / 2, depth: 1), threadsPerThreadgroup: threadgroup(pipeline))
    }

    /// sv22's 4:2:0 -> 4:2:2 step alone, on the intermediate.
    static func encode422(_ pass: ComputePass, _ planes: Planes, pipeline: MTLComputePipelineState) {
        pass.setPipeline(pipeline)
        pass.setTexture(planes.chroma420, index: 0); pass.setTexture(planes.outUV.0, index: 1)
        pass.dispatchThreads(MTLSize(width: width / 2, height: height, depth: 1), threadsPerThreadgroup: threadgroup(pipeline))
    }

    static let profileSeconds = 0.3
    static let profileGapSeconds = 0.2
    /// Between "ready" and the first stretch, without a trigger file: time to start a recording.
    static let profileLeadSeconds = 2.0
    static let profileTriggerTimeout = 120.0

    struct BenchmarkError: Error, CustomStringConvertible {
        let description: String
    }

    static let iterations = 15
    static let dispatchesPerBuffer = 20
    static let width = 3840, height = 2160
    /// Compositions timed one per frame, after `pacedWarmUp` untimed ones.
    static let pacedFrames = 120
    static let pacedWarmUp = 24
    static let frameSeconds = 1001.0 / 24000.0

    /// The unspec62 RPU NAL of fel-clip-a.mp4, with its 2-byte HEVC NAL header.
    static let clipARpuHex = "7c011908090840613650ae20002008020080200802007f801ffc00ffc001fffa0000030100000300d0000008000006800000400000340000030200000301a000001000000d0000030080000068000004000003034000002000000a800000800000e18618800000800000800000800000800000800000b0c30c800000800000800000800000800000800000986186800000800000800000800000800000540000040000040000070c30c4000004000004000004000004000004000005861864000004000004000004000004000004000004c30c34000004000004000004000004012000010010010000030100480000400400400000401200001001001000001c95980000d7a8959be7f3ac7095991328000004000003002000000300200000030070d8890c06182978c238145000000698f96bfffc00000300000300000300018081f73805463008015faa4900c0282183180081872b94210002020000030008050000030002261140120c1f4000641f2e1276ffb6cfda80"


    static func require<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw BenchmarkError(description: what) }
        return value
    }

    struct Rig {
        let device: MTLDevice
        /// The engine's GPU submission, as the composer uses it.
        let gpu: GPUSubmitter
        let cache: CVMetalTextureCache
        let base: CVPixelBuffer
        let enhancement: CVPixelBuffer
        let params: MTLBuffer
        let lut: MTLBuffer
        /// The inverse-NLQ table the kernels index (`DoviFelComposer.populateNlqLut`), bound at buffer 2.
        let nlq: MTLBuffer
        /// The MMR coefficient table (`DoviFelComposer.populateMmrTable`), bound at buffer 3.
        let mmr: MTLBuffer

        init() throws {
            device = try require(MTLCreateSystemDefaultDevice(), "no Metal device")
            gpu = try require(GPUSubmitter(device: device, label: "FelComposerBenchmark"), "no GPU submitter")
            var cache: CVMetalTextureCache?
            CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
            self.cache = try require(cache, "no texture cache")
            base = try require(makeBuffer(width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), "no base buffer")
            enhancement = try require(makeBuffer(width / 2, height / 2, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
                                      "no enhancement buffer")
            try fill(base, enhancement: false, device: device, gpu: gpu, cache: self.cache)
            try fill(enhancement, enhancement: true, device: device, gpu: gpu, cache: self.cache)
            let params = try clipAParams()
            self.params = try require(device.makeBuffer(length: DoviMetalParams.serializedSize, options: .storageModeShared),
                                      "no parameter buffer")
            params.serialize(into: UnsafeMutableRawBufferPointer(start: self.params.contents(), count: DoviMetalParams.serializedSize))
            lut = try require(device.makeBuffer(length: 1024 * 4, options: .storageModeShared), "no LUT buffer")
            try require(DoviFelComposer(), "no composer")
                .populateLumaLut(into: lut.contents().assumingMemoryBound(to: Int32.self), params: params)
            nlq = try require(device.makeBuffer(length: 3 * DoviFelComposer.nlqLutCodes * 4, options: .storageModeShared),
                              "no NLQ buffer")
            DoviFelComposer.populateNlqLut(into: nlq.contents().assumingMemoryBound(to: Int32.self), params: params)
            mmr = try require(device.makeBuffer(length: DoviFelComposer.mmrTableCount * 4, options: .storageModeShared),
                              "no MMR buffer")
            DoviFelComposer.populateMmrTable(into: mmr.contents().assumingMemoryBound(to: Int32.self), params: params)
        }
    }

    /// Clip A's parameters at the benchmark's size, residual on, in `dither` (and sv22's 4:2:2 flag).
    static func clipAParams(dither: DoviDither? = nil, chroma422: Bool = false) throws -> DoviMetalParams {
        var bytes: [UInt8] = []
        var i = clipARpuHex.startIndex
        while i < clipARpuHex.endIndex {
            let j = clipARpuHex.index(i, offsetBy: 2)
            bytes.append(UInt8(clipARpuHex[i..<j], radix: 16)!)
            i = j
        }
        let rpu = try require(dovi_parse_unspec62_nalu(bytes, bytes.count), "clip A's RPU does not parse")
        defer { dovi_rpu_free(rpu) }
        var p = try require(DoviFelComposer.parseRpuParameters(rpu: rpu), "clip A's parameters")
        p.flags.remove(.disableResidual)
        p.blWidth = UInt32(width); p.blHeight = UInt32(height)
        p.elWidth = UInt32(width / 2); p.elHeight = UInt32(height / 2)
        if let dither { p.ditherMode = dither }
        if chroma422 { p.flags.insert(.chroma422) }
        return p
    }

    static func makeBuffer(_ w: Int, _ h: Int, _ format: OSType) -> CVPixelBuffer? {
        var b: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, w, h, format, attrs as CFDictionary, &b)
        return b
    }

    /// The test planes, written on the GPU (a 4K frame a pixel at a time took a minute in a Debug build): the base
    /// layer a luma ramp across the frame with grain-like noise and chroma swept around neutral, the enhancement layer
    /// +-40 codes of noise around 512, as 10-bit codes in a P010 buffer.
    static let fillSource = """
    #include <metal_stdlib>
    using namespace metal;
    // Cheap deterministic noise, so neighbouring pixels differ like grain does.
    static inline int rig_noise(uint x, uint y) { return int((((x * 73856093u) ^ (y * 19349663u)) >> 7) % 33u) - 16; }
    static inline ushort rig_code(int v) { return ushort(clamp(v, 0, 1023) << 6); }
    kernel void rig_fill(texture2d<ushort, access::write> y_tex [[texture(0)]],
                         texture2d<ushort, access::write> uv_tex [[texture(1)]],
                         constant uint3& dims [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
        uint w = dims.x, h = dims.y;
        bool el = dims.z != 0u;
        if (gid.x >= w || gid.y >= h) { return; }
        int n = rig_noise(gid.x, gid.y);
        y_tex.write(ushort4(rig_code(el ? 512 + n * 40 / 16 : 64 + int(gid.x * 876u / w) + n), 0, 0, 0), gid);
        if (gid.x < w / 2u && gid.y < h / 2u) {
            int cb, cr;
            if (el) {
                cb = cr = 512 + rig_noise(gid.y, gid.x) * 20 / 16;
            } else {
                cb = 512 + int(gid.x * 2u * 300u / w) - 150 + n / 2;
                cr = 512 + int(gid.y * 2u * 300u / h) - 150 + n / 2;
            }
            uv_tex.write(ushort4(rig_code(cb), rig_code(cr), 0, 0), gid);
        }
    }
    """

    static func fill(_ b: CVPixelBuffer, enhancement: Bool, device: MTLDevice, gpu: GPUSubmitter,
                     cache: CVMetalTextureCache) throws {
        let library = try device.makeLibrary(source: fillSource, options: nil)
        let pipeline = try device.makeComputePipelineState(function: try require(library.makeFunction(name: "rig_fill"), "no fill kernel"))
        func plane(_ index: Int, _ format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
            var t: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, b, nil, format, CVPixelBufferGetWidthOfPlane(b, index),
                                                      CVPixelBufferGetHeightOfPlane(b, index), index, &t)
            let cv = try require(t, "no texture for plane \(index)")
            return (try require(CVMetalTextureGetTexture(cv), "no Metal texture for plane \(index)"), cv)
        }
        let y = try plane(0, .r16Uint), uv = try plane(1, .rg16Uint)
        var dims: SIMD3<UInt32> = [UInt32(CVPixelBufferGetWidth(b)), UInt32(CVPixelBufferGetHeight(b)), enhancement ? 1 : 0]
        let dimsBuffer = try require(device.makeBuffer(bytes: &dims, length: MemoryLayout<SIMD3<UInt32>>.size, options: .storageModeShared),
                                     "no fill parameters")
        let batch = try require(gpu.makeBatch(), "no batch")
        let pass = try require(batch.makePass(), "no pass")
        pass.setPipeline(pipeline)
        pass.setTexture(y.0, index: 0)
        pass.setTexture(uv.0, index: 1)
        pass.setBuffer(dimsBuffer, index: 0)
        pass.dispatchThreads(MTLSize(width: Int(dims.x), height: Int(dims.y), depth: 1),
                             threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        if let error = gpu.commitAndWait(batch).error { throw BenchmarkError(description: error) }
        withExtendedLifetime((y.1, uv.1)) {}
    }

    static func texture(_ rig: Rig, _ b: CVPixelBuffer, plane: Int, _ format: MTLPixelFormat) throws -> (MTLTexture, CVMetalTexture) {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, rig.cache, b, nil, format,
                                                  CVPixelBufferGetWidthOfPlane(b, plane), CVPixelBufferGetHeightOfPlane(b, plane), plane, &t)
        let cv = try require(t, "no texture for plane \(plane)")
        return (try require(CVMetalTextureGetTexture(cv), "no Metal texture for plane \(plane)"), cv)
    }

    struct Planes {
        let blY, blUV, elY, elUV, outY, outUV: (MTLTexture, CVMetalTexture)
        let chroma420: MTLTexture

        init(_ rig: Rig, out: CVPixelBuffer) throws {
            blY = try texture(rig, rig.base, plane: 0, .r16Uint)
            blUV = try texture(rig, rig.base, plane: 1, .rg16Uint)
            elY = try texture(rig, rig.enhancement, plane: 0, .r16Uint)
            elUV = try texture(rig, rig.enhancement, plane: 1, .rg16Uint)
            outY = try texture(rig, out, plane: 0, .r16Uint)
            outUV = try texture(rig, out, plane: 1, .rg16Uint)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Uint, width: width / 2,
                                                                      height: height / 2, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.shaderRead, .shaderWrite]
            chroma420 = try require(rig.device.makeTexture(descriptor: descriptor), "no 4:2:0 intermediate")
        }
    }

    static func threadgroup(_ pipeline: MTLComputePipelineState) -> MTLSize {
        let w = pipeline.threadExecutionWidth
        return MTLSize(width: w, height: max(1, min(pipeline.maxTotalThreadsPerThreadgroup / w, 8)), depth: 1)
    }

    /// Encodes one dispatch of `pipeline` (luma, or chroma followed by sv22's 4:2:2 step with `chroma422`, behind a
    /// barrier, as the composer encodes them).
    static func encode(_ pass: ComputePass, _ rig: Rig, _ planes: Planes, pipeline: MTLComputePipelineState,
                       luma: Bool, chroma422: MTLComputePipelineState?) {
        pass.setTexture(planes.blY.0, index: 0); pass.setTexture(planes.blUV.0, index: 1)
        pass.setBuffer(rig.params, index: 0)
        pass.setBuffer(rig.lut, index: 1)
        pass.setBuffer(rig.nlq, index: 2)
        pass.setBuffer(rig.mmr, index: 3)
        pass.setPipeline(pipeline)
        pass.setTexture(luma ? planes.elY.0 : planes.elUV.0, index: 2)
        pass.setTexture(luma ? planes.outY.0 : (chroma422 == nil ? planes.outUV.0 : planes.chroma420), index: 3)
        let grid = luma ? MTLSize(width: width, height: height, depth: 1) : MTLSize(width: width / 2, height: height / 2, depth: 1)
        pass.dispatchThreads(grid, threadsPerThreadgroup: threadgroup(pipeline))
        if let chroma422 {
            pass.barrier()
            pass.setPipeline(chroma422)
            pass.setTexture(planes.chroma420, index: 0); pass.setTexture(planes.outUV.0, index: 1)
            pass.dispatchThreads(MTLSize(width: width / 2, height: height, depth: 1), threadsPerThreadgroup: threadgroup(chroma422))
        }
    }

    /// Median GPU milliseconds per dispatch of one kernel, over `iterations` batches of `dispatchesPerBuffer`
    /// dispatches each, one after another (a barrier between them). With `chroma422`, sv22's step follows each chroma
    /// dispatch, the chroma kernel writing the 4:2:0 intermediate it reads, as the composer encodes them; the time is
    /// the two together.
    static func time(_ rig: Rig, pipeline: MTLComputePipelineState, luma: Bool, chroma422: MTLComputePipelineState? = nil,
                     out: CVPixelBuffer) throws -> Double {
        let planes = try Planes(rig, out: out)
        var samples: [Double] = []
        for i in 0..<(iterations + 3) {
            let batch = try require(rig.gpu.makeBatch(), "no batch")
            let pass = try require(batch.makePass(), "no pass")
            for _ in 0..<dispatchesPerBuffer {
                encode(pass, rig, planes, pipeline: pipeline, luma: luma, chroma422: chroma422)
                pass.barrier()
            }
            let result = rig.gpu.commitAndWait(batch)
            if let error = result.error { throw BenchmarkError(description: error) }
            // 3 warm-up batches
            if i >= 3 { samples.append(result.gpuMs / Double(dispatchesPerBuffer)) }
        }
        return samples.sorted()[samples.count / 2]
    }

    static func setMode(_ rig: Rig, dither: DoviDither, chroma422: Bool) throws {
        let p = try clipAParams(dither: dither, chroma422: chroma422)
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

    static func report(_ label: String, source: String, rig: Rig, reference: inout [String: [UInt16]],
                       sv22Only: Bool = false) throws -> [String] {
        let pipes = try DoviFelComposer.SharedPipelines.compile(device: rig.device, source: source)
        let p010 = try require(makeBuffer(width, height, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange), "no P010 output")
        let sv22 = try require(makeBuffer(width, height, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange), "no sv22 output")
        var lines: [String] = []
        let modes = [("p010", DoviDither.bayer8x8, p010, false), ("p010-bn", DoviDither.blueNoise, p010, false),
                     ("sv22", DoviDither.fullPrecision, sv22, true)]
        for (mode, dither, out, c422) in modes where !sv22Only || mode == "sv22" {
            try setMode(rig, dither: dither, chroma422: c422)
            let kernels = try pipes.kernels(.init(blueNoise: dither == .blueNoise))
            let l = try time(rig, pipeline: kernels.luma, luma: true, out: out)
            let c = try time(rig, pipeline: kernels.chroma, luma: false, chroma422: c422 ? kernels.chroma422 : nil, out: out)
            // The last timed dispatch of each kernel left its output; it must match the baseline's bit for bit.
            let words = planes(out)
            let verdict: String
            if label.hasPrefix("FLOOR") || label.hasPrefix("c: ") || label.hasPrefix("l: ") {
                verdict = "(not a composition)"
            } else if let ref = reference[mode] {
                let diff = zip(words, ref).reduce(0) { $0 + ($1.0 != $1.1 ? 1 : 0) }
                verdict = diff == 0 ? "bit-exact" : "DIFFERS in \(diff) words"
            } else {
                reference[mode] = words
                verdict = "reference"
            }
            lines.append(String(format: "[bench] %@ %@  luma %.3f ms  chroma %.3f ms  total %.3f ms  %@",
                                label, mode, l, c, l + c, verdict))
        }
        return lines
    }

    /// The idle time between paced command buffers: none, then up to a 24p frame. How a composition's cost follows
    /// the gap says whether the GPU's clock falls while it waits.
    static let pacedGaps: [Double] = [0, 0.008, 1.0 / 60, 0.025, frameSeconds]

    /// The sv22 composition as playback submits it: luma, chroma and the 4:2:2 step in one command buffer, the next
    /// buffer `gapSeconds` after this one starts (`perBuffer` compositions in each). Median and maximum GPU time per
    /// composition.
    static func paced(rig: Rig, gapSeconds: Double = frameSeconds, perBuffer: Int = 1) throws -> String {
        try setMode(rig, dither: .fullPrecision, chroma422: true)
        let kernels = try DoviFelComposer.SharedPipelines.compile(device: rig.device, source: DoviShaderSource.source)
            .kernels(.init(blueNoise: false))
        let out = try require(makeBuffer(width, height, kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange), "no sv22 output")
        let planes = try Planes(rig, out: out)
        var samples: [Double] = []
        var next = CACurrentMediaTime()
        let buffers = (pacedWarmUp + pacedFrames) / perBuffer
        for i in 0..<buffers {
            let wait = next - CACurrentMediaTime()
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            next += gapSeconds
            // As the composer encodes a batch: a pass per composition, luma and chroma together in it.
            let batch = try require(rig.gpu.makeBatch(), "no batch")
            for _ in 0..<perBuffer {
                let pass = try require(batch.makePass(), "no pass")
                encode(pass, rig, planes, pipeline: kernels.luma, luma: true, chroma422: nil)
                encode(pass, rig, planes, pipeline: kernels.chroma, luma: false, chroma422: kernels.chroma422)
            }
            let result = rig.gpu.commitAndWait(batch)
            if let error = result.error { throw BenchmarkError(description: error) }
            if i >= pacedWarmUp / perBuffer { samples.append(result.gpuMs / Double(perBuffer)) }
        }
        let sorted = samples.sorted()
        return String(format: "[bench] paced sv22, %d per batch, a batch every %.1f ms: median %.3f ms, max %.3f ms per composition (%d batches)",
                      perBuffer, gapSeconds * 1000, sorted[sorted.count / 2], sorted.last ?? 0, sorted.count)
    }

    // MARK: - Variants

    /// `source` with each (old, new) applied at every occurrence; throws if an `old` does not occur, so a variant
    /// cannot silently measure the baseline. Every occurrence, because the 4:2:0 and 4:2:2 chroma kernels share
    /// some lines (the quantisation, the residual gate) and a variant applies to both.
    static func patched(_ source: String, _ edits: [(String, String)]) throws -> String {
        var s = source
        for (a, b) in edits {
            guard s.contains(a) else { throw BenchmarkError(description: "variant edit not found: \(a.prefix(60))") }
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
    int bl_y = int(bl_y_tex.read(at).r >> 6);

    int h;
""", """
    int bl_y = int(bl_y_tex.read(at).r >> 6);
    if (inside) {
        int e = int(el_y_tex.read(uint2(gid.x >> 1, gid.y >> 1)).r >> 6);
        out_y_tex.write(ushort4(ushort((bl_y + e) << 6), 0, 0, 0), gid);
        return;
    }
    int h;
"""),
        ("""
    ushort4 bl_uv = bl_uv_tex.read(at);
    int bl_cb = int(bl_uv.r >> 6);
""", """
    ushort4 bl_uv = bl_uv_tex.read(at);
    if (inside) {
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
        ("    return piece >= 0 && curve.method[piece] == DOVI_MAPPING_MMR;", "    return false;"),
    ]
    static let lumaNoResidual: [(String, String)] = [
        ("    int el_code = 0;\n    if (residual) {", "    int el_code = 0;\n    if (false) {"),
    ]
    /// Luma's EL upsampling split: the vertical pass alone (no shuffles), the horizontal alone (no gathers), and the
    /// residual's table lookup left out.
    static let lumaNoHorizontal: [(String, String)] = [
        ("    return dovi_el_h(dovi_el_v_luma(tex, dovi_el_column(x0, lane, el_size.x), row), lane);",
         "    return dovi_el_v_luma(tex, dovi_el_column(x0, lane, el_size.x), row);"),
    ]
    static let lumaNoVertical: [(String, String)] = [
        ("    return dovi_el_h(dovi_el_v_luma(tex, dovi_el_column(x0, lane, el_size.x), row), lane);",
         "    return dovi_el_h(dovi_el_column(x0, lane, el_size.x) & 1023, lane);"),
    ]
    static let lumaNoNlq: [(String, String)] = [
        ("        h += dovi_inv_nlq(nlq_lut, 0u, el_code);", "        h += el_code - 512;"),
    ]
    /// MMR split: the terms formed but no coefficient read (each term folded into the sum's low word), and each of
    /// the estimate path's two sums left out.
    static let chromaNoMmrSum: [(String, String)] = [
        ("static inline void dovi_mmr_add(thread DoviMmrSum &s, int c, uint t) {",
         "static inline void dovi_mmr_add(thread DoviMmrSum &s, int c, uint t) {\n    s.acc.lo ^= t;\n    return;"),
    ]
    static let chromaNoIntSum: [(String, String)] = [
        ("        s.acc.lo += uint(c) * t;", "        s.acc.lo += uint(c);"),
    ]
    static let chromaNoFloatSum: [(String, String)] = [
        ("        s.e = fma(float(c), float(t), s.e);", "        s.e += float(c);"),
    ]
    static let chromaNoResidual: [(String, String)] = [
        ("    if (residual && dovi_residual_at(params, gid.x * 2u)) {", "    if (false) {"),
    ]
    static let chromaNoQuantize: [(String, String)] = [
        ("""
    int out_cb = dovi_quantize(h_cb, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 0u)));
    int out_cr = dovi_quantize(h_cr, params.dither_mode, dovi_dither(gid, params.frame_index, uint2(1u, 1u)));
""", """
    int out_cb = h_cb >> 6;
    int out_cr = h_cr >> 6;
"""),
    ]
}
#endif
