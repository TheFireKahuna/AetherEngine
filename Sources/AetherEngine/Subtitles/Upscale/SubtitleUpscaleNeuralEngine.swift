import CoreML
import Foundation
import Metal

/// ArtCNN on the Neural Engine through Core ML (``ArtCNNCoreMLModels``), for ``SubtitleUpscaler``'s
/// `.neuralEngine` backend. The mask and composite stay on the GPU; only the network moves, which leaves the GPU to
/// the video while a subtitle upscales.
///
/// The model has a fixed tile (Core ML keeps a flexible shape off the Neural Engine): the kept area is cut into
/// 128 x 704 cores, each read through a 142 x 718 window (the core plus the network's 7-pixel reach, transparent
/// beyond the picture), two to a prediction, so every core pixel is the network's exact output for
/// the picture on its transparent canvas, as on the GPU.
enum SubtitleUpscaleNeuralEngine {
    static let coreWidth = ArtCNNCoreMLModels.tileWidth - 14
    static let coreHeight = ArtCNNCoreMLModels.tileHeight - 14

    private static let lock = NSLock()
    nonisolated(unsafe) private static var models: [ArtCNNModel: Result<MLModel, Error>] = [:]

    /// The model, materialised and compiled into the caches directory on first use (once per install: the compiled
    /// model is kept), then loaded for the CPU and Neural Engine. Blocks for the load, a few hundred milliseconds the
    /// first time in a process; ``prewarm()`` does it in the background.
    static func model(_ model: ArtCNNModel) throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let cached = models[model] { return try cached.get() }
        let made = Result { try load(model) }
        models[model] = made
        return try made.get()
    }

    /// Loads both models and runs each once, so the Neural Engine has compiled them before the first subtitle
    /// needs them.
    static func prewarm() throws {
        for m in ArtCNNModel.allCases {
            let shape = [ArtCNNCoreMLModels.batch, 1, ArtCNNCoreMLModels.tileHeight, ArtCNNCoreMLModels.tileWidth].map { NSNumber(value: $0) }
            let input = try MLMultiArray(shape: shape, dataType: .float16)
            _ = try model(m).prediction(from: try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: input)]))
        }
    }

    private static func files(_ model: ArtCNNModel) -> [(path: String, base64: String)] {
        switch model {
        case .c4f16: ArtCNNCoreMLModels.c4f16
        case .c4f32: ArtCNNCoreMLModels.c4f32
        }
    }

    private static func load(_ model: ArtCNNModel) throws -> MLModel {
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
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    /// Runs `model` on `count` consecutive tiles of `input` into `output` (both shared buffers in the model's
    /// layout), `first` tiles in, a batch at a time: a last partial batch runs whole, so the buffers must hold
    /// `count` rounded up to the batch.
    static func predict(_ model: MLModel, input: MTLBuffer, output: MTLBuffer, first: Int, count: Int) throws {
        let th = ArtCNNCoreMLModels.tileHeight, tw = ArtCNNCoreMLModels.tileWidth
        let inTile = th * tw, outTile = 4 * th * tw
        let n = ArtCNNCoreMLModels.batch
        var at = first
        let end = first + count
        while at < end {
            let inPointer = input.contents().advanced(by: at * inTile * 2)
            let outPointer = output.contents().advanced(by: at * outTile * 2)
            let x = try MLMultiArray(dataPointer: inPointer, shape: [n, 1, th, tw].map { NSNumber(value: $0) }, dataType: .float16,
                                     strides: [inTile, inTile, tw, 1].map { NSNumber(value: $0) })
            let y = try MLMultiArray(dataPointer: outPointer, shape: [n, 1, 2 * th, 2 * tw].map { NSNumber(value: $0) }, dataType: .float16,
                                     strides: [outTile, outTile, 2 * tw, 1].map { NSNumber(value: $0) })
            let options = MLPredictionOptions()
            options.outputBackings = ["y": y]
            let result = try model.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["x": MLFeatureValue(multiArray: x)]),
                                              options: options)
            // Core ML writes into the backing; should it hand back its own array instead, copy it in.
            if let got = result.featureValue(for: "y")?.multiArrayValue, got.dataPointer != outPointer {
                got.withUnsafeBytes { outPointer.copyMemory(from: $0.baseAddress!, byteCount: min($0.count, n * outTile * 2)) }
            }
            at += n
        }
    }
}
