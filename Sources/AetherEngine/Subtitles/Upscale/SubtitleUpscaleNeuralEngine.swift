import CoreML
import CoreVideo
import Foundation
import Metal

/// ArtCNN on the Neural Engine through Core ML (``ArtCNNCoreMLModels``), for ``SubtitleUpscaler``'s
/// `.neuralEngine` backend. The mask, the window gather and the composite stay on the GPU; only the network moves,
/// which leaves the GPU to the video while a subtitle upscales.
///
/// The models have fixed window shapes (``SubtitleUpscaleTilePlan`` covers the kept area with them), each window a
/// core plus the network's 7-pixel reach, transparent beyond the picture, so every core pixel is the network's exact
/// output for the picture on its transparent canvas, as on the GPU. Each window's planes are IOSurface-backed
/// half-float pixel buffers (``Surfaces``) that Metal and Core ML both wrap, so the GPU writes what the Neural Engine
/// reads and reads what it writes, and nothing is copied between them.
enum SubtitleUpscaleNeuralEngine {
    struct Shape: Hashable {
        var height: Int
        var width: Int
        var function: String { "h\(height)w\(width)" }
    }

    static let shapes = ArtCNNCoreMLModels.windowHeights.flatMap { h in ArtCNNCoreMLModels.windowWidths.map { Shape(height: h, width: $0) } }

    private struct Key: Hashable {
        var model: ArtCNNModel
        var shape: Shape
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var models: [Key: Result<MLModel, Error>] = [:]

    /// The model's function for `shape`, materialised and compiled into the caches directory on first use (once per
    /// install: the compiled model is kept), then loaded for the CPU and Neural Engine. Blocks for the load, about
    /// 150 ms for each function the first time in a process; ``prewarm()`` does them all in the background.
    static func model(_ model: ArtCNNModel, _ shape: Shape) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        let key = Key(model: model, shape: shape)
        if let cached = models[key] { return try cached.get() }
        let made = Result { try load(model, shape) }
        models[key] = made
        return try made.get()
    }

    /// Where an app-open prewarm's time went, in wall milliseconds.
    struct PrewarmTimes {
        /// Materialising and compiling the packages (nothing when the compiled models are already on disk).
        var compile = 0.0
        /// Loading every function.
        var load = 0.0
        /// Every function's first prediction, which has the Neural Engine compile its program.
        var firstPrediction = 0.0
        var functions = 0
        var total: Double { compile + load + firstPrediction }
    }

    /// Compiles both models, loads every function and runs each once, so nothing is left for the first subtitle
    /// but the prediction itself.
    @discardableResult
    static func prewarm() throws -> PrewarmTimes {
        var times = PrewarmTimes()
        func lap(_ t0: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
        for m in ArtCNNModel.allCases {
            var t0 = DispatchTime.now().uptimeNanoseconds
            _ = try compiledURL(m)
            times.compile += lap(t0)
            for shape in shapes {
                t0 = DispatchTime.now().uptimeNanoseconds
                let loaded = try model(m, shape)
                times.load += lap(t0)
                let input = try MLMultiArray(shape: [1, 1, shape.height, shape.width].map { NSNumber(value: $0) }, dataType: .float16)
                let features = try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)])
                t0 = DispatchTime.now().uptimeNanoseconds
                _ = try loaded.prediction(from: features)
                times.firstPrediction += lap(t0)
                times.functions += 1
            }
        }
        return times
    }

    /// Drops the loaded functions, as a new process starts (the compiled models stay on disk). For the benchmark.
    static func unloadModels() {
        lock.withLock { models.removeAll() }
    }

    /// Deletes the compiled models, as a fresh install or a purged cache leaves them. For the benchmark.
    static func removeCompiledModels() throws {
        unloadModels()
        let root = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AetherEngine-ArtCNN", isDirectory: true)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    private static func files(_ model: ArtCNNModel) -> [(path: String, base64: String)] {
        switch model {
        case .c4f16: ArtCNNCoreMLModels.c4f16
        case .c4f32: ArtCNNCoreMLModels.c4f32
        }
    }

    private static func load(_ model: ArtCNNModel, _ shape: Shape) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        configuration.functionName = shape.function
        return try MLModel(contentsOf: try compiledURL(model), configuration: configuration)
    }

    /// The compiled model in the caches directory, compiled from ``ArtCNNCoreMLModels`` when it is not there yet.
    static func compiledURL(_ model: ArtCNNModel) throws -> URL {
        let files = files(model)
        // FNV-1a over the package, so a changed model never reuses a stale compile.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for f in files { for b in f.base64.utf8 { hash = (hash ^ UInt64(b)) &* 0x100_0000_01b3 } }
        let fm = FileManager.default
        let root = try fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("AetherEngine-ArtCNN", isDirectory: true)
        let name = "ArtCNN_\(model.rawValue)_\(String(hash, radix: 16))"
        let compiled = root.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
        if !fm.fileExists(atPath: compiled.path) {
            let package = root.appendingPathComponent(name + ".mlpackage", isDirectory: true)
            for f in files {
                guard let data = Data(base64Encoded: f.base64, options: .ignoreUnknownCharacters) else {
                    throw SubtitleUpscaler.UpscaleError.unavailable("ArtCNN Core ML package is not base64")
                }
                let url = package.appendingPathComponent(f.path)
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
            let made = try MLModel.compileModel(at: package)
            try? fm.removeItem(at: compiled)
            try fm.moveItem(at: made, to: compiled)
            try? fm.removeItem(at: package)
        }
        return compiled
    }

    /// Runs `model` on one window's input plane into its output plane (``Surfaces``). Core ML writes the output
    /// into the backing; an output anywhere else is an error, not a copy.
    static func predict(_ model: MLModel, input: Surfaces.Plane, output: Surfaces.Plane) throws {
        let options = MLPredictionOptions()
        options.outputBackings = ["y": output.array]
        let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input.array)]),
                                          options: options)
        guard let written = result.featureValue(for: "y")?.multiArrayValue?.pixelBuffer, written === output.pixelBuffer else {
            throw SubtitleUpscaler.UpscaleError.unavailable("Core ML did not write the output backing")
        }
    }

    /// The window planes of one shape: alpha and premultiplied luma in, their four sub-pixel channels out, each an
    /// IOSurface-backed `OneComponent16Half` pixel buffer wrapped once as an `r16Float` texture and once as a Core ML
    /// array. The input is `(1, 1, height, width)` over `height` rows; the output `(1, 4, height, width)` over
    /// `4 * height` rows, channel k from row `k * height`. IOSurface rows are padded to the Neural Engine's
    /// alignment.
    final class Surfaces {
        struct Plane {
            let pixelBuffer: CVPixelBuffer
            let texture: MTLTexture
            let array: MLMultiArray
        }

        let shape: Shape
        let alphaIn: Plane
        let lumaIn: Plane
        let alphaOut: Plane
        let lumaOut: Plane

        init(shape: Shape, device: MTLDevice) throws {
            self.shape = shape
            let h = shape.height, w = shape.width
            alphaIn = try Self.plane(device, width: w, rows: h, shape: [1, 1, h, w])
            lumaIn = try Self.plane(device, width: w, rows: h, shape: [1, 1, h, w])
            alphaOut = try Self.plane(device, width: w, rows: 4 * h, shape: [1, 4, h, w])
            lumaOut = try Self.plane(device, width: w, rows: 4 * h, shape: [1, 4, h, w])
        }

        private static func plane(_ device: MTLDevice, width: Int, rows: Int, shape: [Int]) throws -> Plane {
            var made: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
                                               kCVPixelBufferMetalCompatibilityKey: true]
            guard CVPixelBufferCreate(nil, width, rows, kCVPixelFormatType_OneComponent16Half, attributes as CFDictionary, &made) == kCVReturnSuccess,
                  let pixelBuffer = made, let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else {
                throw SubtitleUpscaler.UpscaleError.unavailable("no \(width)x\(rows) half-float surface")
            }
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width, height: rows, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: d, iosurface: surface, plane: 0) else {
                throw SubtitleUpscaler.UpscaleError.unavailable("no texture over a \(width)x\(rows) surface")
            }
            return Plane(pixelBuffer: pixelBuffer, texture: texture, array: MLMultiArray(pixelBuffer: pixelBuffer, shape: shape.map { NSNumber(value: $0) }))
        }

        /// The surfaces a plan's windows use, in window order: the k-th window of a shape takes that shape's k-th
        /// surfaces, made on first use and kept.
        final class Pool {
            let device: MTLDevice
            private var byShape: [Shape: [Surfaces]] = [:]

            init(device: MTLDevice) { self.device = device }

            func surfaces(for windows: [SubtitleUpscaleTilePlan.Window]) throws -> [Surfaces] {
                var used: [Shape: Int] = [:]
                return try windows.map { w in
                    let shape = Shape(height: w.height, width: w.width)
                    let k = used[shape, default: 0]
                    used[shape] = k + 1
                    if byShape[shape, default: []].count == k { byShape[shape, default: []].append(try Surfaces(shape: shape, device: device)) }
                    return byShape[shape]![k]
                }
            }
        }
    }
}
