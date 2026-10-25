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

    /// Steady-state time per picture for each benchmark picture and configuration, median of `iterations` after
    /// warm-up. GPU backend: GPU time from command-buffer timestamps, "single" one picture per command buffer,
    /// "batch" `batch` pictures in one, and "wall" the caller's time for one picture through ``upscale(_:)``. Neural
    /// Engine backend (`neuralEngine`): "wall" only, which covers its two GPU command buffers and the predictions.
    /// With `sweep`, also the GPU time of each layer-kernel variant and threadgroup size on the 1400x120 strip (the
    /// defaults were tuned on an M4 Pro; this says whether they hold on the device). For a probe app to call on a
    /// device; it builds its own upscalers and blocks for some seconds (the first Neural Engine run also compiles the
    /// models, and the sweep compiles every variant).
    public static func benchmark(iterations: Int = 15, batch: Int = 8, neuralEngine: Bool = true, sweep: Bool = false) -> String {
        do {
            let kernels = try SubtitleUpscaleKernels.get()
            var lines = ["SubtitleUpscaler benchmark on \(kernels.device.name), ms per picture (median of \(iterations))"]
            let configurations: [(String, Configuration)] = [("C4F16", .c4f16), ("C4F32", .c4f32), ("balanced", .balanced)]
            if neuralEngine { try SubtitleUpscaleNeuralEngine.prewarm() }
            for c in benchmarkCases() {
                for (name, configuration) in configurations {
                    let upscaler = try SubtitleUpscaler(configuration: configuration)
                    let r = try upscaler.measure(c.picture, iterations: iterations, batch: batch)
                    let wall = try upscaler.measureWall(c.picture, iterations: iterations)
                    var line = String(format: "%@  %-8@  GPU: single %6.2f  batch(%d) %6.2f  wall %6.2f", c.name as NSString,
                                      name as NSString, r.single, batch, r.batched, wall)
                    if neuralEngine {
                        var ane = configuration
                        ane.backend = .neuralEngine
                        let neural = try SubtitleUpscaler(configuration: ane).measureWall(c.picture, iterations: iterations)
                        line += String(format: "  |  Neural Engine: wall %6.2f", neural)
                    }
                    lines.append(line)
                }
            }
            if sweep {
                let strip = benchmarkCases()[0].picture
                lines.append("variants, 1400x120 strip, GPU ms single (default: \(SubtitleUpscaleKernels.defaultVariant), \(SubtitleUpscaleKernels.defaultSimdgroupsPerGroup) simdgroups)")
                for model in [Configuration.c4f32, .c4f16] {
                    for variant in SubtitleUpscaleKernels.tuningVariants {
                        for simdgroups in [2, 4, 8] {
                            let upscaler = try SubtitleUpscaler(configuration: model)
                            upscaler.variant = variant
                            upscaler.simdgroupsPerGroup = simdgroups
                            let r = try upscaler.measure(strip, iterations: max(iterations / 2, 3), batch: 1)
                            lines.append(String(format: "  %@ units %d %@ acc %@ weights, %d simdgroups: %6.2f", model.alphaModel.rawValue,
                                                variant.unitsPerSimdgroup, variant.halfAccumulator ? "half" : "float",
                                                variant.threadgroupWeights ? "threadgroup" : "device", simdgroups, r.single))
                        }
                    }
                }
            }
            return lines.joined(separator: "\n")
        } catch {
            return "SubtitleUpscaler benchmark failed: \(error)"
        }
    }

    /// Median wall-clock milliseconds for one picture through ``upscale(_:)`` (bounded, as ``measure``).
    func measureWall(_ picture: SubtitleUpscaleFixtures.Picture, iterations: Int) throws -> Double {
        guard let source = SubtitleUpscaleFixtures.texture(picture, device: device) else { throw UpscaleError.unavailable("no texture") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2 * picture.width, height: 2 * picture.height,
                                                         mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        guard let destination = device.makeTexture(descriptor: d) else { throw UpscaleError.unavailable("no texture") }
        let bounds = picture.rgba.withUnsafeBytes {
            Self.contentBounds($0.baseAddress!, width: picture.width, height: picture.height, bytesPerRow: picture.width * 4, alphaOffset: 3) ?? .zero
        }
        var samples: [Double] = []
        for i in 0..<(iterations + 3) {
            let start = DispatchTime.now().uptimeNanoseconds
            try upscale([Job(source: source, destination: destination, contentBounds: bounds)])
            if i >= 3 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
        }
        return samples.sorted()[samples.count / 2]
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
