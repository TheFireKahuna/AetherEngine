import CoreML
import Foundation
import Metal

extension SubtitleUpscaler {

    /// A benchmark picture: a cropped strip or a full canvas of subtitle text.
    struct BenchmarkCase {
        let name: String
        let picture: SubtitleUpscaleFixtures.Picture
    }

    static func benchmarkCases() -> [BenchmarkCase] {
        let two = ["I never said she stole the money, and you know it.", "Then who did? Somebody in this house did."]
        return [
            BenchmarkCase(name: "1400x120 strip", picture: SubtitleUpscaleFixtures.glyphs(width: 1400, height: 120, lines: two, fontSize: 44)),
            BenchmarkCase(name: "1920x200 strip", picture: SubtitleUpscaleFixtures.glyphs(width: 1920, height: 200, lines: two, fontSize: 64)),
            BenchmarkCase(name: "1920x1080 canvas", picture: SubtitleUpscaleFixtures.glyphs(width: 1920, height: 1080, lines: two, fontSize: 56,
                                                                                            baselineFromBottom: 70)),
        ]
    }

    /// Percentiles of a set of samples, nearest rank.
    struct Spread {
        var p50 = 0.0
        var p95 = 0.0
        var p99 = 0.0
        var max = 0.0

        init(_ samples: [Double]) {
            guard !samples.isEmpty else { return }
            let s = samples.sorted()
            func rank(_ p: Double) -> Double { s[Swift.min(s.count - 1, Int((p * Double(s.count)).rounded(.up)) - 1)] }
            p50 = rank(0.5); p95 = rank(0.95); p99 = rank(0.99); max = s.last!
        }

        var text: String { String(format: "p50 %6.2f  p95 %6.2f  p99 %6.2f  max %6.2f", p50, p95, p99, max) }
    }

    /// The upscaler's costs on this device, in wall milliseconds unless marked, for a probe app to call (it blocks
    /// for some seconds). Three phases kept apart, because only the last is paid per subtitle:
    ///
    /// 1. App open: what ``prewarm(neuralEngine:)`` does, timed as it does it. The GPU pipelines' compile; then the
    ///    Neural Engine models cold (compiled models deleted, as after an install, an OS update or a purged cache)
    ///    and warm (compiled models on disk, nothing loaded, as on a later launch), each split into the package
    ///    compile, the function loads and the first predictions.
    /// 2. The first picture on a new upscaler after the prewarm: its surfaces and buffers, made on first use.
    /// 3. Steady state: `iterations` pictures on that upscaler, as percentiles, per backend; for the Neural Engine
    ///    also per stage (GPU gather, predictions, GPU composite).
    ///
    /// Then each window shape's prediction time (``SubtitleUpscaleTilePlan``'s estimates come from it) and, with
    /// `sweep`, the GPU time of each layer-kernel variant on the 1400x120 strip (the defaults were tuned on an M4 Pro).
    public static func benchmark(iterations: Int = 40, sweep: Bool = false) -> String {
        func ms(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        var lines: [String] = []
        do {
            // 1. App open.
            var t0 = DispatchTime.now().uptimeNanoseconds
            let fresh = try SubtitleUpscaleKernels()
            let kernelCompile = ms(t0)
            lines.append("SubtitleUpscaler benchmark on \(fresh.device.name), wall ms")
            lines.append("1. app open (prewarm)")
            lines.append(String(format: "  GPU pipelines: %.1f", kernelCompile))
            try SubtitleUpscaleNeuralEngine.removeCompiledModels()
            let cold = try SubtitleUpscaleNeuralEngine.prewarm()
            SubtitleUpscaleNeuralEngine.unloadModels()
            let warm = try SubtitleUpscaleNeuralEngine.prewarm()
            for (name, t) in [("cold", cold), ("warm", warm)] {
                lines.append(String(format: "  Neural Engine %@: total %.1f = package compile %.1f + %d function loads %.1f + first predictions %.1f",
                                    name as NSString, t.total, t.compile, t.functions, t.load, t.firstPrediction))
            }

            // 2 and 3. Per picture, after the prewarm.
            _ = try SubtitleUpscaleKernels.get()
            lines.append("2. first picture on a new upscaler | 3. steady state over \(iterations) pictures")
            let configurations: [(String, Configuration)] = [("C4F16", .c4f16), ("C4F32", .c4f32), ("balanced", .balanced)]
            for c in benchmarkCases() {
                for (name, configuration) in configurations {
                    for backend in [Backend.gpu, .neuralEngine] {
                        var config = configuration
                        config.backend = backend
                        let upscaler = try SubtitleUpscaler(configuration: config)
                        let run = try upscaler.measureRun(c.picture, iterations: iterations)
                        lines.append(String(format: "  %@ %-8@ %@: first %6.2f | %@", c.name as NSString, name as NSString,
                                            backend == .gpu ? "GPU          " : "Neural Engine", run.first, run.wall.text))
                        if backend == .neuralEngine {
                            lines.append("      gather    \(run.gather.text)")
                            lines.append("      predict   \(run.predict.text)   (\(run.windows) windows, 2 planes)")
                            lines.append("      composite \(run.composite.text)")
                        } else {
                            lines.append(String(format: "      GPU time p50 %6.2f", try upscaler.measure(c.picture, iterations: iterations / 2, batch: 1).single))
                        }
                    }
                }
            }

            lines.append("4. one prediction per window shape, p50 (ns per window pixel)")
            for m in ArtCNNModel.allCases { lines.append(try SubtitleUpscaleNeuralEngine.calibrationLine(m, iterations: iterations / 2)) }

            if sweep {
                let strip = benchmarkCases()[0].picture
                lines.append("variants, 1400x120 strip, GPU ms single (default: \(SubtitleUpscaleKernels.defaultVariant), \(SubtitleUpscaleKernels.defaultSimdgroupsPerGroup) simdgroups)")
                for model in [Configuration.c4f32, .c4f16] {
                    for variant in SubtitleUpscaleKernels.tuningVariants {
                        for simdgroups in [2, 4, 8] {
                            let upscaler = try SubtitleUpscaler(configuration: model)
                            upscaler.variant = variant
                            upscaler.simdgroupsPerGroup = simdgroups
                            let r = try upscaler.measure(strip, iterations: max(iterations / 4, 3), batch: 1)
                            lines.append(String(format: "  %@ units %d %@ acc %@ weights, %d simdgroups: %6.2f", model.alphaModel.rawValue,
                                                variant.unitsPerSimdgroup, variant.halfAccumulator ? "half" : "float",
                                                variant.threadgroupWeights ? "threadgroup" : "device", simdgroups, r.single))
                        }
                    }
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            lines.append("SubtitleUpscaler benchmark failed: \(error)")
            return lines.joined(separator: "\n")
        }
    }

    /// One picture through ``upscale(_:)`` (bounded, as a caller with its display set's object rectangles passes
    /// them): the first call on this upscaler, then `iterations` more, wall time and, on the Neural Engine, stages.
    func measureRun(_ picture: SubtitleUpscaleFixtures.Picture, iterations: Int)
        throws -> (first: Double, wall: Spread, gather: Spread, predict: Spread, composite: Spread, windows: Int) {
        guard let source = SubtitleUpscaleFixtures.texture(picture, device: device) else { throw UpscaleError.unavailable("no texture") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2 * picture.width, height: 2 * picture.height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let destination = device.makeTexture(descriptor: d) else { throw UpscaleError.unavailable("no texture") }
        let bounds = picture.rgba.withUnsafeBytes {
            Self.contentBounds($0.baseAddress!, width: picture.width, height: picture.height, bytesPerRow: picture.width * 4, alphaOffset: 3) ?? .zero
        }
        let job = Job(source: source, destination: destination, contentBounds: bounds)
        var t0 = DispatchTime.now().uptimeNanoseconds
        try upscale([job])
        let first = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        var wall: [Double] = [], gather: [Double] = [], predict: [Double] = [], composite: [Double] = []
        for _ in 0..<iterations {
            t0 = DispatchTime.now().uptimeNanoseconds
            try upscale([job])
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
            let s = lastNeuralEngineStages
            gather.append(s.gather); predict.append(s.predict); composite.append(s.composite)
        }
        return (first, Spread(wall), Spread(gather), Spread(predict), Spread(composite), lastNeuralEngineStages.tiles)
    }

    /// Median GPU milliseconds per picture, alone and batched.
    /// With `bounded`, each job carries the picture's content bounds, as a caller that knows its display set's object
    /// rectangles passes them.
    func measure(_ picture: SubtitleUpscaleFixtures.Picture, iterations: Int, batch: Int, bounded: Bool = true) throws -> (single: Double, batched: Double) {
        let bounds = bounded ? picture.rgba.withUnsafeBytes {
            Self.contentBounds($0.baseAddress!, width: picture.width, height: picture.height, bytesPerRow: picture.width * 4, alphaOffset: 3) ?? .zero
        } : nil
        guard let source = SubtitleUpscaleFixtures.texture(picture, device: device) else { throw UpscaleError.unavailable("no texture") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2 * picture.width, height: 2 * picture.height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        let destinations = try (0..<max(batch, 1)).map { _ in
            guard let t = device.makeTexture(descriptor: d) else { throw UpscaleError.unavailable("no texture") }
            return t
        }
        func time(_ count: Int) throws -> Double {
            var samples: [Double] = []
            for i in 0..<(iterations + 3) {
                guard let commandBuffer = commandQueue.makeCommandBuffer() else { throw UpscaleError.gpu("no command buffer") }
                try encode(destinations.prefix(count).map { Job(source: source, destination: $0, contentBounds: bounds) }, into: commandBuffer)
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                if let error = commandBuffer.error { throw UpscaleError.gpu("\(error)") }
                if i >= 3 { samples.append((commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1000 / Double(count)) }
            }
            return samples.sorted()[samples.count / 2]
        }
        return (try time(1), try time(max(batch, 1)))
    }
}

extension SubtitleUpscaleNeuralEngine {
    /// Each window shape's synchronous prediction time for `m`, median, with the time per window pixel.
    static func calibrationLine(_ m: ArtCNNModel, iterations: Int) throws -> String {
        var line = "  \(m.rawValue)"
        for shape in shapes {
            let model = try model(m, shape)
            let x = try MLMultiArray(shape: [1, 1, shape.height, shape.width].map { NSNumber(value: $0) }, dataType: .float16)
            let p = x.dataPointer.assumingMemoryBound(to: Float16.self)
            // A subtitle-like input: sparse strokes, so a value-dependent path would show.
            for i in 0..<(shape.height * shape.width) { p[i] = (i * 7919) % 97 > 80 ? 1 : 0 }
            let features = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)])
            var samples: [Double] = []
            for i in 0..<(iterations + 3) {
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = try model.prediction(from: features)
                if i >= 3 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
            }
            let t = SubtitleUpscaler.Spread(samples).p50
            line += String(format: "  %@ %5.2f (%4.1f)", shape.function as NSString, t, t * 1e6 / Double(shape.height * shape.width))
        }
        return line
    }
}
