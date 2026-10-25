import Foundation
import Metal
import os

/// The process's one set of upscaler GPU state: device, queue, the compiled pipelines and each model's weights in the
/// layouts the kernels read. Built once, on first use (``SubtitleUpscaler/prewarm()`` builds it off the caller's
/// thread), and shared by every ``SubtitleUpscaler``.
final class SubtitleUpscaleKernels: @unchecked Sendable {
    enum KernelError: Error, CustomStringConvertible {
        case unavailable(String)
        var description: String {
            switch self { case .unavailable(let why): "subtitle upscaler unavailable: \(why)" }
        }
    }

    /// The layer kernel variant and simdgroups per threadgroup the upscaler uses. On an M4 Pro, C4F32 on a 1400x120
    /// strip: one unit per simdgroup 3.7 ms of GPU time, two 4.6, four 5.7, eight 54 (spilled registers); the kernel
    /// staged in threadgroup memory by persistent threadgroups 4.3; half accumulators 2% faster at eight times the
    /// error (0.011 against 0.0014); 2, 4 or 8 simdgroups within 1%. The layers run at about 90% of the GPU's
    /// measured `simdgroup_matrix` peak (5.9 TFLOPS), so fusing layers to save their device-memory round trips has
    /// little to win here. ``SubtitleUpscaler/benchmark(iterations:batch:neuralEngine:sweep:)`` repeats the sweep on
    /// a device.
    static let defaultVariant = Variant(unitsPerSimdgroup: 1, halfAccumulator: false, threadgroupWeights: false)
    static let defaultSimdgroupsPerGroup = 4
    static let unitsPerSimdgroupVariants = [1, 2, 4]
    /// Threads per threadgroup of layer 0 (one per pixel and 8 output channels).
    static let firstLayerThreads = 256

    struct ModelBuffers {
        let model: ArtCNNModel
        let features: Int
        /// Layer 0: `[channel][10]`, nine taps then the bias, Float32.
        let first: MTLBuffer
        /// Layers 1...6: the kernel as half 8x8 blocks `[tap][input / 8][output / 8][8][8]`.
        let blocks: [MTLBuffer]
        /// Layers 1...6: the bias, Float32.
        let bias: [MTLBuffer]
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let maskBits: MTLComputePipelineState
    let maskRows: MTLComputePipelineState
    let maskColumns: MTLComputePipelineState
    let bandReset: MTLComputePipelineState
    let bandLists: MTLComputePipelineState
    let bandArguments: MTLComputePipelineState
    let planes: MTLComputePipelineState
    let clearPads: MTLComputePipelineState
    let composite: MTLComputePipelineState
    let resample: MTLComputePipelineState
    let clearOutside: MTLComputePipelineState
    let tileGather: MTLComputePipelineState
    let compositeTiles: MTLComputePipelineState
    private let firstLayer: [Int: MTLComputePipelineState]
    private let pipelines = OSAllocatedUnfairLock<[String: MTLComputePipelineState]>(initialState: [:])
    private let models: [ArtCNNModel: ModelBuffers]

    private static let sharedLock = NSLock()
    nonisolated(unsafe) private static var shared: Result<SubtitleUpscaleKernels, Error>?

    /// The shared kernels, compiled on the first call (which blocks for the compile); a failure is kept, so a
    /// device without the GPU features costs one attempt.
    static func get() throws -> SubtitleUpscaleKernels {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let shared { return try shared.get() }
        let made = Result { try SubtitleUpscaleKernels() }
        shared = made
        return try made.get()
    }

    /// The shader with the layer kernels of `variants` instantiated.
    static func source(_ variants: [Variant]) -> String {
        var instances: [String] = []
        for v in variants {
            let (type, tag) = v.halfAccumulator ? ("half", "h") : ("float", "f")
            for c in [16, 32] {
                for (mode, out) in [(0, c), (1, c), (2, 4)] {
                    instances.append(v.threadgroupWeights
                        ? "UP_CONV_TG(\(c), \(out), \(v.unitsPerSimdgroup), \(mode), \(type), \(tag))"
                        : "UP_CONV(up_conv, \(c), \(out), \(v.unitsPerSimdgroup), \(mode), \(type), \(tag))")
                }
            }
        }
        return SubtitleUpscaleShaderSource.source.replacingOccurrences(of: "/*UP_CONV_INSTANCES*/", with: instances.joined(separator: "\n"))
    }

    /// Every layer kernel variant, for the benchmark's sweep on a device; the shipped library holds the default alone.
    static let tuningVariants: [Variant] = unitsPerSimdgroupVariants.flatMap { mb in
        [false, true].flatMap { half in [false, true].map { tg in Variant(unitsPerSimdgroup: mb, halfAccumulator: half, threadgroupWeights: tg) } }
    }

    private static func compileOptions() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) { options.mathMode = .fast } else { options.fastMathEnabled = true }
        return options
    }

    /// A fresh set: ``get()`` makes the shared one; the benchmark makes its own to time the compile.
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw KernelError.unavailable("no Metal device") }
        // simdgroup_matrix needs Apple7 (A14) or later.
        guard device.supportsFamily(.apple7) else { throw KernelError.unavailable("GPU lacks simdgroup_matrix (needs Apple7)") }
        guard let queue = device.makeCommandQueue() else { throw KernelError.unavailable("no command queue") }
        queue.label = "SubtitleUpscaler"
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: Self.source([Self.defaultVariant]), options: Self.compileOptions())
        self.library = library
        func make(_ name: String) throws -> MTLComputePipelineState {
            guard let f = library.makeFunction(name: name) else { throw KernelError.unavailable("no kernel \(name)") }
            return try device.makeComputePipelineState(function: f)
        }
        maskBits = try make("up_mask_bits")
        maskRows = try make("up_mask_rows")
        maskColumns = try make("up_mask_columns")
        bandReset = try make("up_band_reset")
        bandLists = try make("up_band_lists")
        bandArguments = try make("up_band_arguments")
        planes = try make("up_planes")
        clearPads = try make("up_clear_pads")
        composite = try make("up_composite")
        resample = try make("up_resample")
        clearOutside = try make("up_clear_outside")
        tileGather = try make("up_tile_gather")
        compositeTiles = try make("up_composite_tiles")
        firstLayer = [16: try make("up_conv_first_16"), 32: try make("up_conv_first_32")]
        var models: [ArtCNNModel: ModelBuffers] = [:]
        for model in ArtCNNModel.allCases {
            models[model] = try Self.upload(ArtCNNNetwork.network(model), device: device)
        }
        self.models = models
        // The default variant of every layer, so the first picture compiles nothing.
        for c in [16, 32] {
            for mode in 0...2 { _ = try convolution(features: c, mode: mode, variant: Self.defaultVariant) }
        }
    }

    func buffers(_ model: ArtCNNModel) -> ModelBuffers { models[model]! }

    func first(features: Int) -> MTLComputePipelineState { firstLayer[features]! }

    /// How a layer kernel is built: units per simdgroup, accumulator precision, and whether the kernel's weights are
    /// staged in threadgroup memory by persistent threadgroups (else read from device memory, one batch per simdgroup).
    struct Variant: Hashable, Sendable {
        var unitsPerSimdgroup: Int
        var halfAccumulator: Bool
        var threadgroupWeights: Bool
    }

    /// Layer kernel for `features` channels: mode 0 ReLU (layers 1...4), 1 residual (layer 5), 2 last (layer 6).
    func convolution(features: Int, mode: Int, variant v: Variant) throws -> MTLComputePipelineState {
        let name = "up_conv_\(v.threadgroupWeights ? "tg_" : "")\(features)_\(mode == 2 ? 4 : features)_m\(v.unitsPerSimdgroup)_\(mode)_\(v.halfAccumulator ? "h" : "f")"
        if let ready = pipelines.withLock({ $0[name] }) { return ready }
        let lib = v == Self.defaultVariant ? library : try tuningLibrary()
        guard let f = lib.makeFunction(name: name) else { throw KernelError.unavailable("no kernel \(name)") }
        let made = try device.makeComputePipelineState(function: f)
        pipelines.withLock { $0[name] = made }
        return made
    }

    private let tuning = OSAllocatedUnfairLock<MTLLibrary?>(initialState: nil)

    /// The library of every variant, compiled on first use (most of a second, more on a small GPU).
    private func tuningLibrary() throws -> MTLLibrary {
        if let made = tuning.withLock({ $0 }) { return made }
        let made = try device.makeLibrary(source: Self.source(Self.tuningVariants), options: Self.compileOptions())
        tuning.withLock { $0 = made }
        return made
    }

    private static func upload(_ network: ArtCNNNetwork, device: MTLDevice) throws -> ModelBuffers {
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let b = values.withUnsafeBytes({ device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
            else { throw KernelError.unavailable("no buffer") }
            return b
        }
        let l0 = network.layers[0]
        var first: [Float] = []
        for o in 0..<l0.outputs {
            for ky in 0..<3 { for kx in 0..<3 { first.append(l0.weight(output: o, input: 0, row: ky, column: kx)) } }
            first.append(l0.bias[o])
        }
        var blocks: [MTLBuffer] = []
        var biases: [MTLBuffer] = []
        for layer in network.layers[1...] {
            let cb = layer.inputs / 8
            let ob = (layer.outputs + 7) / 8
            var b = [Float16](repeating: 0, count: 9 * cb * ob * 64)
            for ky in 0..<3 {
                for kx in 0..<3 {
                    for i in 0..<layer.inputs {
                        for o in 0..<layer.outputs {
                            let block = ((ky * 3 + kx) * cb + i / 8) * ob + o / 8
                            b[block * 64 + (i % 8) * 8 + o % 8] = Float16(layer.weight(output: o, input: i, row: ky, column: kx))
                        }
                    }
                }
            }
            blocks.append(try buffer(b))
            biases.append(try buffer(layer.bias))
        }
        return ModelBuffers(model: network.model, features: network.features, first: try buffer(first), blocks: blocks, bias: biases)
    }
}
