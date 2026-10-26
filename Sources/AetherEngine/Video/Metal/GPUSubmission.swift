import Foundation
import Metal
import QuartzCore
import os
import LibDeinterlace
#if MLSubtitleUpscale
import LibMLSubUpscaler
#endif

/// Every compute submission of the engine and the libraries it encodes for (the FEL composition, the software
/// decoders' finishing pass with LibDeinterlace's passes in it, the subtitle compositor, LibMLSubUpscaler's passes),
/// submitted one way whichever Metal the system has: Metal 4 where it is available (`MTL4CommandQueue`, command allocators and
/// argument tables reused frame after frame, residency sets, explicit barriers, one commit for a batch), Metal 3
/// before it (unretained command buffers, residency sets, a concurrent encoder with memory barriers).
///
/// Work is encoded in a ``GPUBatch``: one or more ``ComputePass``es, committed together, with one completion that
/// reports the GPU's start and end and any error. Dispatches in a pass run together unless a ``ComputePass/barrier()``
/// separates them; a batch is ordered after the work committed before it only when it asks to be
/// (`orderedAfterEarlierWork`), since one whose resources nothing earlier writes need not wait for anything.
final class GPUSubmitter: @unchecked Sendable {

    let device: MTLDevice
    private let backend: any GPUBackend

    /// Which Metal submits the work, for the log.
    var api: String { backend.api }

    init?(device: MTLDevice, label: String) {
        self.device = device
        if #available(macOS 26, iOS 26, tvOS 26, visionOS 26, *), device.supportsFamily(.metal4),
           let backend = Metal4Backend(device: device, label: label) {
            self.backend = backend
        } else if let backend = Metal3Backend(device: device, label: label) {
            self.backend = backend
        } else {
            return nil
        }
    }

    /// A new batch. `timed` stamps the GPU's time at every ``ComputePass/timestamp(_:)``, each stamp waiting for the
    /// work before it; `orderedAfterEarlierWork` starts it only once everything committed before it has finished.
    func makeBatch(timed: Bool = false, orderedAfterEarlierWork: Bool = false) -> GPUBatch? {
        backend.makeBatch(timed: timed, orderedAfterEarlierWork: orderedAfterEarlierWork)
    }

    /// `function` of `library`, specialised with `constants` (nil: a function without any), as a compute pipeline: on
    /// Metal 4, made by the
    /// submitter's compiler, which takes it from `archive` (a Metal 4 binary archive built ahead of time for this GPU and
    /// OS release) when it holds it and compiles it otherwise; on Metal 3, compiled by the device.
    func makeComputePipeline(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
                             archive: URL?) throws -> MTLComputePipelineState {
        try backend.makeComputePipeline(library: library, function: function, constants: constants, archive: archive)
    }

    /// A fence, for passes of this submitter's queue that depend on one another without the queue being ordered
    /// (``ComputePass/updateFence(_:)``, ``ComputePass/waitForFence(_:)``).
    func makeFence() -> MTLFence? { device.makeFence() }

    /// Commits `batch` and waits for it: for offline callers (tests, probes, stills), never on a playback path.
    @discardableResult
    func commitAndWait(_ batch: GPUBatch) -> GPUBatchResult {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock(initialState: GPUBatchResult(gpuStart: 0, gpuEnd: 0, error: nil, stamps: []))
        batch.commit { outcome in
            result.withLock { $0 = outcome }
            done.signal()
        }
        done.wait()
        return result.withLock { $0 }
    }
}

/// How a committed batch went.
struct GPUBatchResult: Sendable {
    /// Host time the GPU started and finished the batch, 0 when it did not run.
    let gpuStart: CFTimeInterval
    let gpuEnd: CFTimeInterval
    /// Why the batch failed, nil when it completed.
    let error: String?
    /// A timed batch's stamps: each label with the GPU milliseconds since the stamp before it (or the batch's first).
    let stamps: [(label: String, ms: Double)]

    var gpuMs: Double { gpuEnd > gpuStart ? (gpuEnd - gpuStart) * 1000 : 0 }
}

/// Work for one commit. Not thread-safe: one caller encodes it, then commits it once.
protocol GPUBatch: AnyObject {
    /// Before the first pass: the batch's work waits on the GPU until `event` reaches `value`.
    func wait(for event: MTLEvent, value: UInt64)
    /// `event` set to `value` once the batch's work has completed on the GPU.
    func signal(_ event: MTLEvent, value: UInt64)
    /// A compute pass in this batch; the previous one, if still open, is ended first.
    func makePass() -> ComputePass?
    /// Ends the open pass and commits the batch. `completion` runs once, off the caller's thread, on a serial queue
    /// that must not be blocked: it should only hand off.
    func commit(_ completion: @escaping @Sendable (GPUBatchResult) -> Void)
}

/// The libraries' pass protocols, which every ``ComputePass`` is, so a library encodes straight into an engine pass.
#if MLSubtitleUpscale
typealias LibraryPasses = DeinterlacePass & SubtitleUpscalePass
#else
typealias LibraryPasses = DeinterlacePass
#endif

/// A compute pass, encoded the same way on either Metal. Resources bound are made resident for the batch.
protocol ComputePass: LibraryPasses {
    func setPipeline(_ pipeline: MTLComputePipelineState)
    func setTexture(_ texture: MTLTexture, index: Int)
    func setBuffer(_ buffer: MTLBuffer, offset: Int, index: Int)
    /// `bytes` copied into the batch and bound at `index`, as a small constant argument (Metal 4 has no `setBytes`).
    func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int)
    func dispatchThreads(_ grid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(_ groups: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, offset: Int, threadsPerThreadgroup: MTLSize)
    /// Every byte of `range` (offset and length multiples of 4) set to `value`, ordered by ``barrier()`` and fences as a
    /// dispatch is: the encoder's own fill on Metal 4, a fill kernel in the same encoder on Metal 3.
    func fill(_ buffer: MTLBuffer, range: Range<Int>, value: UInt8)
    /// Every dispatch after this sees every write before it.
    func barrier()
    /// The dispatches after this wait until `fence` has been updated, by the last pass committed to this queue before
    /// this one that updates it (none: no wait), and see its writes.
    func waitForFence(_ fence: MTLFence)
    /// `fence` updated once every dispatch encoded in this pass so far has completed.
    func updateFence(_ fence: MTLFence)
    /// In a timed batch, the GPU time of the work since the last stamp, under `label`; nothing otherwise.
    func timestamp(_ label: String)
}

extension ComputePass {
    func setBuffer(_ buffer: MTLBuffer, index: Int) { setBuffer(buffer, offset: 0, index: index) }
    func setValue<T>(_ value: T, index: Int) { withUnsafeBytes(of: value) { setBytes($0, index: index) } }
}

protocol GPUBackend: AnyObject, Sendable {
    var api: String { get }
    func makeBatch(timed: Bool, orderedAfterEarlierWork: Bool) -> GPUBatch?
    func makeComputePipeline(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
                             archive: URL?) throws -> MTLComputePipelineState
}

/// Bounds of what any of the engine's kernels binds: buffers up to index 8 (LibDeinterlace), textures up to 3.
private enum Bindings {
    static let buffers = 16
    static let textures = 8
    /// Stamps a timed batch can take.
    static let stamps = 16
}

/// A batch's small constant arguments (``ComputePass/setBytes(_:index:)``): copied into a shared buffer the batch's
/// context keeps until its work has completed, at 16-byte steps. Grows by a new buffer when one fills; the largest is
/// kept for the next batch.
private final class Uploads {
    private let device: MTLDevice
    private var buffers: [MTLBuffer] = []
    private var cursor = 0

    init(device: MTLDevice) { self.device = device }

    func reset() {
        if buffers.count > 1 { buffers = [buffers.last!] }
        cursor = 0
    }

    func copy(_ bytes: UnsafeRawBufferPointer) -> (buffer: MTLBuffer, offset: Int)? {
        let length = max(16, (bytes.count + 15) & ~15)
        if buffers.last.map({ cursor + length > $0.length }) ?? true {
            guard let made = device.makeBuffer(length: max(64 * 1024, length), options: .storageModeShared) else { return nil }
            buffers.append(made)
            cursor = 0
        }
        let buffer = buffers.last!
        if let base = bytes.baseAddress { (buffer.contents() + cursor).copyMemory(from: base, byteCount: bytes.count) }
        defer { cursor += length }
        return (buffer, cursor)
    }
}

// MARK: - Metal 4

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private final class Metal4Backend: GPUBackend, @unchecked Sendable {
    let api = "Metal 4"
    private let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let frequency: Double
    /// Holds a batch's queue-level event waits, its commit and its event signals together, so another batch's commit
    /// never falls between them.
    private let commitOrder = NSLock()
    /// Command memory, command buffers, bindings and residency, reused: a context goes back to the pool when its
    /// batch has completed, so its allocator is never reset under work the GPU still reads.
    private let pool = OSAllocatedUnfairLock<[Context]>(initialState: [])

    final class Context: @unchecked Sendable {
        let allocator: MTL4CommandAllocator
        let commandBuffer: MTL4CommandBuffer
        let table: MTL4ArgumentTable
        let residency: MTLResidencySet
        let stamps: MTL4CounterHeap?
        let uploads: Uploads
        /// The pipelines the batch's passes set, held until it completes: a command buffer holds them without retaining
        /// them.
        var pipelines: [MTLComputePipelineState] = []

        init?(device: MTLDevice) {
            let tableDescriptor = MTL4ArgumentTableDescriptor()
            tableDescriptor.maxBufferBindCount = Bindings.buffers
            tableDescriptor.maxTextureBindCount = Bindings.textures
            let heapDescriptor = MTL4CounterHeapDescriptor()
            heapDescriptor.type = .timestamp
            heapDescriptor.count = Bindings.stamps
            guard let allocator = device.makeCommandAllocator(), let commandBuffer = device.makeCommandBuffer(),
                  let table = try? device.makeArgumentTable(descriptor: tableDescriptor),
                  let residency = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor()) else { return nil }
            self.allocator = allocator
            self.commandBuffer = commandBuffer
            self.table = table
            self.residency = residency
            stamps = try? device.makeCounterHeap(descriptor: heapDescriptor)
            uploads = Uploads(device: device)
        }
    }

    /// Makes every pipeline, looking in the archives it is given first.
    private let compiler: MTL4Compiler
    /// The archives loaded so far, by file; nil for one Metal refused (built for another OS release or GPU), logged once.
    private let archives = OSAllocatedUnfairLock<[URL: Archive?]>(initialState: [:])
    /// Only read once loaded (pipelines taken from it), which Metal allows from any thread.
    private struct Archive: @unchecked Sendable { let archive: MTL4Archive }

    func makeComputePipeline(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
                             archive: URL?) throws -> MTLComputePipelineState {
        let named = MTL4LibraryFunctionDescriptor()
        named.name = function
        named.library = library
        let descriptor = MTL4ComputePipelineDescriptor()
        // As the library's build recorded it for the archive: a specialisation only where there are constants.
        if let constants {
            let specialised = MTL4SpecializedFunctionDescriptor()
            specialised.functionDescriptor = named
            specialised.constantValues = constants
            descriptor.computeFunctionDescriptor = specialised
        } else {
            descriptor.computeFunctionDescriptor = named
        }
        let options = MTL4CompilerTaskOptions()
        if let archive, let loaded = loadArchive(archive) { options.lookupArchives = [loaded] }
        return try compiler.makeComputePipelineState(descriptor: descriptor, compilerTaskOptions: options)
    }

    private func loadArchive(_ url: URL) -> MTL4Archive? {
        if let known = archives.withLock({ $0[url] }) { return known?.archive }
        let loaded: Archive?
        do {
            loaded = Archive(archive: try device.makeArchive(url: url))
        } catch {
            loaded = nil
            EngineLog.emit("[GPUSubmitter] pipeline archive \(url.lastPathComponent) not used: \(error.localizedDescription)",
                           category: .engine)
        }
        archives.withLock { $0[url] = loaded }
        return loaded?.archive
    }

    init?(device: MTLDevice, label: String) {
        // Feedback on Metal's own queue: a queue handed to the descriptor (`feedbackQueue`, declared `assign`) is
        // released by the command queue's dealloc without having been retained (tvOS / macOS 27.2).
        let descriptor = MTL4CommandQueueDescriptor()
        descriptor.label = label
        guard let queue = try? device.makeMTL4CommandQueue(descriptor: descriptor),
              let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor()) else { return nil }
        self.device = device
        self.queue = queue
        self.compiler = compiler
        frequency = Double(device.queryTimestampFrequency())
    }

    func makeBatch(timed: Bool, orderedAfterEarlierWork: Bool) -> GPUBatch? {
        guard let context = pool.withLock({ $0.popLast() }) ?? Context(device: device) else { return nil }
        context.allocator.reset()
        context.residency.removeAllAllocations()
        context.uploads.reset()
        context.pipelines.removeAll(keepingCapacity: true)
        context.commandBuffer.beginCommandBuffer(allocator: context.allocator)
        context.commandBuffer.useResidencySet(context.residency)
        return Batch(backend: self, context: context, timed: timed && context.stamps != nil, ordered: orderedAfterEarlierWork)
    }

    fileprivate func finish(_ context: Context, completion: @escaping @Sendable (GPUBatchResult) -> Void,
                            labels: [String], waits: [(MTLEvent, UInt64)], signals: [(MTLEvent, UInt64)]) {
        context.commandBuffer.endCommandBuffer()
        context.residency.commit()
        let options = MTL4CommitOptions()
        let frequency = frequency
        options.addFeedbackHandler { [weak self] feedback in
            let stamps = labels.isEmpty ? [] : Self.stamps(context.stamps, labels: labels, frequency: frequency)
            self?.pool.withLock { $0.append(context) }
            completion(GPUBatchResult(gpuStart: feedback.gpuStartTime, gpuEnd: feedback.gpuEndTime,
                                      error: feedback.error?.localizedDescription, stamps: stamps))
        }
        // Events are queue operations on Metal 4: a wait holds back the work committed after it, a signal fires once
        // the work committed before it has completed.
        commitOrder.withLock {
            for (event, value) in waits { queue.waitForEvent(event, value: value) }
            queue.commit([context.commandBuffer], options: options)
            for (event, value) in signals { queue.signalEvent(event, value: value) }
        }
    }

    private static func stamps(_ heap: MTL4CounterHeap?, labels: [String], frequency: Double) -> [(label: String, ms: Double)] {
        guard let heap, frequency > 0, let data = try? heap.resolveCounterRange(0..<(labels.count + 1)) else { return [] }
        return data.withUnsafeBytes { raw in
            let entries = raw.bindMemory(to: MTL4TimestampHeapEntry.self)
            return labels.indices.map { i in
                let start = entries[i].timestamp, end = entries[i + 1].timestamp
                return (labels[i], end > start ? Double(end - start) / frequency * 1000 : .nan)
            }
        }
    }

    private final class Batch: GPUBatch {
        let backend: Metal4Backend
        let context: Context
        let timed: Bool
        var ordered: Bool
        var open: Pass?
        var labels: [String] = []
        var waits: [(MTLEvent, UInt64)] = []
        var signals: [(MTLEvent, UInt64)] = []

        init(backend: Metal4Backend, context: Context, timed: Bool, ordered: Bool) {
            self.backend = backend
            self.context = context
            self.timed = timed
            self.ordered = ordered
        }

        func wait(for event: MTLEvent, value: UInt64) { waits.append((event, value)) }
        func signal(_ event: MTLEvent, value: UInt64) { signals.append((event, value)) }

        func makePass() -> ComputePass? {
            open?.end()
            guard let encoder = context.commandBuffer.makeComputeCommandEncoder() else { return nil }
            encoder.setArgumentTable(context.table)
            if ordered {
                encoder.barrier(afterQueueStages: .dispatch, beforeStages: .dispatch, visibilityOptions: .device)
                ordered = false
            }
            let pass = Pass(batch: self, encoder: encoder)
            if timed, labels.isEmpty, let heap = context.stamps {
                encoder.writeTimestamp(granularity: .precise, counterHeap: heap, index: 0)
            }
            open = pass
            return pass
        }

        func commit(_ completion: @escaping @Sendable (GPUBatchResult) -> Void) {
            open?.end()
            open = nil
            backend.finish(context, completion: completion, labels: labels, waits: waits, signals: signals)
        }
    }

    private final class Pass: ComputePass {
        unowned let batch: Batch
        let encoder: MTL4ComputeCommandEncoder
        private var ended = false

        init(batch: Batch, encoder: MTL4ComputeCommandEncoder) {
            self.batch = batch
            self.encoder = encoder
        }

        func setPipeline(_ pipeline: MTLComputePipelineState) {
            batch.context.pipelines.append(pipeline)
            encoder.setComputePipelineState(pipeline)
        }

        func setTexture(_ texture: MTLTexture, index: Int) {
            batch.context.residency.addAllocation(texture)
            batch.context.table.setTexture(texture.gpuResourceID, index: index)
        }

        func setBuffer(_ buffer: MTLBuffer, offset: Int, index: Int) {
            batch.context.residency.addAllocation(buffer)
            batch.context.table.setAddress(buffer.gpuAddress + UInt64(offset), index: index)
        }

        func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {
            guard let upload = batch.context.uploads.copy(bytes) else { return }
            setBuffer(upload.buffer, offset: upload.offset, index: index)
        }

        func dispatchThreads(_ grid: MTLSize, threadsPerThreadgroup: MTLSize) {
            encoder.dispatchThreads(threadsPerGrid: grid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func dispatchThreadgroups(_ groups: MTLSize, threadsPerThreadgroup: MTLSize) {
            encoder.dispatchThreadgroups(threadgroupsPerGrid: groups, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func dispatchThreadgroups(indirectBuffer: MTLBuffer, offset: Int, threadsPerThreadgroup: MTLSize) {
            batch.context.residency.addAllocation(indirectBuffer)
            encoder.dispatchThreadgroups(indirectBuffer: indirectBuffer.gpuAddress + UInt64(offset),
                                         threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func fill(_ buffer: MTLBuffer, range: Range<Int>, value: UInt8) {
            guard !range.isEmpty else { return }
            batch.context.residency.addAllocation(buffer)
            encoder.fill(buffer: buffer, range: range, value: value)
        }

        // The pass's work is dispatches and fills (the blit stage).
        private static let stages: MTLStages = [.dispatch, .blit]

        func barrier() {
            encoder.barrier(afterEncoderStages: Self.stages, beforeEncoderStages: Self.stages, visibilityOptions: .device)
        }

        func waitForFence(_ fence: MTLFence) { encoder.waitForFence(fence, beforeEncoderStages: Self.stages) }

        func updateFence(_ fence: MTLFence) { encoder.updateFence(fence, afterEncoderStages: Self.stages) }

        func timestamp(_ label: String) {
            guard batch.timed, let heap = batch.context.stamps, batch.labels.count + 1 < Bindings.stamps else { return }
            batch.labels.append(label)
            encoder.writeTimestamp(granularity: .precise, counterHeap: heap, index: batch.labels.count)
        }

        func end() {
            guard !ended else { return }
            ended = true
            encoder.endEncoding()
        }
    }
}

// MARK: - Metal 3

private final class Metal3Backend: GPUBackend, @unchecked Sendable {
    let api = "Metal 3"
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    /// Residency sets and timestamp buffers, reused once their batch has completed.
    private let pool = OSAllocatedUnfairLock<[Context]>(initialState: [])
    private let timestampCounters: MTLCounterSet?
    private let stageBoundaryStamps: Bool
    /// A CPU and a GPU timestamp read together at start-up: with a later pair, the GPU tick's length.
    fileprivate let origin: (cpu: MTLTimestamp, gpu: MTLTimestamp)
    /// ComputePass.fill as a dispatch: Metal 3 fills only in a blit encoder, which would end the pass.
    fileprivate let fillPipeline: MTLComputePipelineState

    private static let fillSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void gpu_fill(device uint* words [[buffer(0)]], constant uint2& fill [[buffer(1)]],
                         uint gid [[thread_position_in_grid]]) {
        if (gid < fill.x) { words[gid] = fill.y; }
    }
    """

    final class Context: @unchecked Sendable {
        let residency: MTLResidencySet?
        let samples: MTLCounterSampleBuffer?
        let uploads: Uploads
        /// The pipelines the batch's passes set, held until it completes: an unretained command buffer holds them
        /// without retaining them.
        var pipelines: [MTLComputePipelineState] = []

        init(device: MTLDevice, counters: MTLCounterSet?) {
            uploads = Uploads(device: device)
            residency = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            if let counters {
                let descriptor = MTLCounterSampleBufferDescriptor()
                descriptor.counterSet = counters
                descriptor.storageMode = .shared
                descriptor.sampleCount = Bindings.stamps * 2
                samples = try? device.makeCounterSampleBuffer(descriptor: descriptor)
            } else {
                samples = nil
            }
        }
    }

    init?(device: MTLDevice, label: String) {
        guard let queue = device.makeCommandQueue(),
              let function = (try? device.makeLibrary(source: Self.fillSource, options: nil))?.makeFunction(name: "gpu_fill"),
              let fillPipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.fillPipeline = fillPipeline
        queue.label = label
        self.device = device
        self.queue = queue
        stageBoundaryStamps = device.supportsCounterSampling(.atStageBoundary)
        timestampCounters = stageBoundaryStamps
            ? device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue } : nil
        origin = device.sampleTimestamps()
    }

    func makeBatch(timed: Bool, orderedAfterEarlierWork: Bool) -> GPUBatch? {
        // Unretained: every caller keeps its resources alive until the completion has run.
        guard let commandBuffer = queue.makeCommandBufferWithUnretainedReferences() else { return nil }
        let context = pool.withLock { $0.popLast() } ?? Context(device: device, counters: timestampCounters)
        context.uploads.reset()
        context.pipelines.removeAll(keepingCapacity: true)
        if let residency = context.residency {
            residency.removeAllAllocations()
            commandBuffer.useResidencySet(residency)
        }
        return Batch(backend: self, commandBuffer: commandBuffer, context: context,
                     timed: timed && context.samples != nil)
    }

    fileprivate func recycle(_ context: Context) { pool.withLock { $0.append(context) } }

    /// Metal 3 takes no Metal 4 archive: the device compiles.
    func makeComputePipeline(library: MTLLibrary, function: String, constants: MTLFunctionConstantValues?,
                             archive: URL?) throws -> MTLComputePipelineState {
        let made: MTLFunction?
        if let constants {
            made = try library.makeFunction(name: function, constantValues: constants)
        } else {
            made = library.makeFunction(name: function)
        }
        guard let made else { throw MTLLibraryError(.functionNotFound, userInfo: [NSLocalizedDescriptionKey: "no function \(function)"]) }
        return try device.makeComputePipelineState(function: made)
    }

    private final class Batch: GPUBatch {
        let backend: Metal3Backend
        let commandBuffer: MTLCommandBuffer
        let context: Context
        let timed: Bool
        var open: Pass?
        /// A timed batch's encoders, each sampled at its start and end: (label of the work it ends with, sample index).
        var labels: [String] = []
        var signals: [(MTLEvent, UInt64)] = []

        init(backend: Metal3Backend, commandBuffer: MTLCommandBuffer, context: Context, timed: Bool) {
            self.backend = backend
            self.commandBuffer = commandBuffer
            self.context = context
            self.timed = timed
        }

        func wait(for event: MTLEvent, value: UInt64) { commandBuffer.encodeWaitForEvent(event, value: value) }
        func signal(_ event: MTLEvent, value: UInt64) { signals.append((event, value)) }

        func makePass() -> ComputePass? {
            open?.end()
            let pass = Pass(batch: self)
            guard pass.begin() else { return nil }
            open = pass
            return pass
        }

        /// A concurrent encoder, or in a timed batch a serial one sampled at its start and end.
        func makeEncoder() -> MTLComputeCommandEncoder? {
            guard timed, let samples = context.samples, labels.count < Bindings.stamps else {
                return commandBuffer.makeComputeCommandEncoder(dispatchType: .concurrent)
            }
            let descriptor = MTLComputePassDescriptor()
            descriptor.dispatchType = .serial
            let attachment = descriptor.sampleBufferAttachments[0]!
            attachment.sampleBuffer = samples
            attachment.startOfEncoderSampleIndex = labels.count * 2
            attachment.endOfEncoderSampleIndex = labels.count * 2 + 1
            return commandBuffer.makeComputeCommandEncoder(descriptor: descriptor)
        }

        func commit(_ completion: @escaping @Sendable (GPUBatchResult) -> Void) {
            open?.end()
            open = nil
            for (event, value) in signals { commandBuffer.encodeSignalEvent(event, value: value) }
            context.residency?.commit()
            let labels = labels
            let context = context
            let backend = backend
            let device = backend.device
            let origin = backend.origin
            commandBuffer.addCompletedHandler { buffer in
                let stamps = labels.isEmpty ? [] : Self.stamps(context.samples, labels: labels, device: device, origin: origin)
                backend.recycle(context)
                completion(GPUBatchResult(gpuStart: buffer.gpuStartTime, gpuEnd: buffer.gpuEndTime,
                                          error: buffer.error?.localizedDescription, stamps: stamps))
            }
            commandBuffer.commit()
        }

        private static func stamps(_ samples: MTLCounterSampleBuffer?, labels: [String], device: MTLDevice,
                                   origin: (cpu: MTLTimestamp, gpu: MTLTimestamp)) -> [(label: String, ms: Double)] {
            guard let samples, let data = try? samples.resolveCounterRange(0..<(labels.count * 2)) else { return [] }
            // CPU timestamps are nanoseconds; GPU timestamps are the GPU's ticks, related by this reading and the
            // start-up one.
            let now = device.sampleTimestamps()
            guard now.gpu > origin.gpu, now.cpu > origin.cpu else { return [] }
            let nsPerTick = Double(now.cpu - origin.cpu) / Double(now.gpu - origin.gpu)
            return data.withUnsafeBytes { raw in
                let entries = raw.bindMemory(to: MTLCounterResultTimestamp.self)
                return labels.indices.map { i in
                    let start = entries[i * 2].timestamp, end = entries[i * 2 + 1].timestamp
                    guard end > start, start != MTLCounterErrorValue, end != MTLCounterErrorValue else { return (labels[i], .nan) }
                    return (labels[i], Double(end - start) * nsPerTick / 1_000_000)
                }
            }
        }
    }

    private final class Pass: ComputePass {
        unowned let batch: Batch
        private var encoder: MTLComputeCommandEncoder?
        /// What the current encoder has bound, for the encoder a timestamp starts.
        private var pipeline: MTLComputePipelineState?
        private var textures: [Int: MTLTexture] = [:]
        private var buffers: [Int: (MTLBuffer, Int)] = [:]
        /// The fences this pass waits on, waited on again by the encoder a timestamp starts.
        private var waits: [MTLFence] = []

        init(batch: Batch) { self.batch = batch }

        func begin() -> Bool {
            encoder = batch.makeEncoder()
            return encoder != nil
        }

        private func resident(_ allocation: MTLAllocation) {
            batch.context.residency?.addAllocation(allocation)
        }

        func setPipeline(_ pipeline: MTLComputePipelineState) {
            self.pipeline = pipeline
            batch.context.pipelines.append(pipeline)
            encoder?.setComputePipelineState(pipeline)
        }

        func setTexture(_ texture: MTLTexture, index: Int) {
            resident(texture)
            textures[index] = texture
            encoder?.setTexture(texture, index: index)
        }

        func setBuffer(_ buffer: MTLBuffer, offset: Int, index: Int) {
            resident(buffer)
            buffers[index] = (buffer, offset)
            encoder?.setBuffer(buffer, offset: offset, index: index)
        }

        func setBytes(_ bytes: UnsafeRawBufferPointer, index: Int) {
            guard let upload = batch.context.uploads.copy(bytes) else { return }
            setBuffer(upload.buffer, offset: upload.offset, index: index)
        }

        func dispatchThreads(_ grid: MTLSize, threadsPerThreadgroup: MTLSize) {
            encoder?.dispatchThreads(grid, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func dispatchThreadgroups(_ groups: MTLSize, threadsPerThreadgroup: MTLSize) {
            encoder?.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func dispatchThreadgroups(indirectBuffer: MTLBuffer, offset: Int, threadsPerThreadgroup: MTLSize) {
            resident(indirectBuffer)
            encoder?.dispatchThreadgroups(indirectBuffer: indirectBuffer, indirectBufferOffset: offset,
                                          threadsPerThreadgroup: threadsPerThreadgroup)
        }

        func fill(_ buffer: MTLBuffer, range: Range<Int>, value: UInt8) {
            guard !range.isEmpty, let encoder else { return }
            resident(buffer)
            let words = UInt32(range.count / 4), word = UInt32(value) * 0x0101_0101
            encoder.setComputePipelineState(batch.backend.fillPipeline)
            encoder.setBuffer(buffer, offset: range.lowerBound, index: 0)
            var arguments = (words, word)
            encoder.setBytes(&arguments, length: 8, index: 1)
            encoder.dispatchThreads(MTLSize(width: Int(words), height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: min(256, batch.backend.fillPipeline.maxTotalThreadsPerThreadgroup),
                                                                   height: 1, depth: 1))
            // The caller's state as it was.
            if let pipeline { encoder.setComputePipelineState(pipeline) }
            for index in 0...1 { if let (buffer, offset) = buffers[index] { encoder.setBuffer(buffer, offset: offset, index: index) } }
        }

        func barrier() { encoder?.memoryBarrier(scope: [.buffers, .textures]) }

        func waitForFence(_ fence: MTLFence) {
            waits.append(fence)
            encoder?.waitForFence(fence)
        }

        func updateFence(_ fence: MTLFence) { encoder?.updateFence(fence) }

        /// Ends the timed encoder, which samples the work since it began, and starts the next with the same bindings.
        func timestamp(_ label: String) {
            guard batch.timed, batch.labels.count < Bindings.stamps else { return }
            batch.labels.append(label)
            encoder?.endEncoding()
            encoder = batch.makeEncoder()
            for fence in waits { encoder?.waitForFence(fence) }
            if let pipeline { encoder?.setComputePipelineState(pipeline) }
            for (index, texture) in textures { encoder?.setTexture(texture, index: index) }
            for (index, (buffer, offset)) in buffers { encoder?.setBuffer(buffer, offset: offset, index: index) }
        }

        func end() {
            encoder?.endEncoding()
            encoder = nil
        }
    }
}
