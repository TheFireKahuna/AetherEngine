import Foundation
import Metal
import QuartzCore
import os

/// The engine's own compute work on the GPU (the FEL composition, the software decoders' finishing pass), submitted
/// one way whichever Metal the system has: Metal 4 where it is available (`MTL4CommandQueue`, command allocators and
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
    /// A compute pass in this batch; the previous one, if still open, is ended first.
    func makePass() -> ComputePass?
    /// Ends the open pass and commits the batch. `completion` runs once, off the caller's thread, on a serial queue
    /// that must not be blocked: it should only hand off.
    func commit(_ completion: @escaping @Sendable (GPUBatchResult) -> Void)
}

/// A compute pass, encoded the same way on either Metal. Resources bound are made resident for the batch.
protocol ComputePass: AnyObject {
    func setPipeline(_ pipeline: MTLComputePipelineState)
    func setTexture(_ texture: MTLTexture, index: Int)
    func setBuffer(_ buffer: MTLBuffer, offset: Int, index: Int)
    func dispatchThreads(_ grid: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(_ groups: MTLSize, threadsPerThreadgroup: MTLSize)
    func dispatchThreadgroups(indirectBuffer: MTLBuffer, offset: Int, threadsPerThreadgroup: MTLSize)
    /// Every dispatch after this sees every write before it.
    func barrier()
    /// In a timed batch, the GPU time of the work since the last stamp, under `label`; nothing otherwise.
    func timestamp(_ label: String)
}

extension ComputePass {
    func setBuffer(_ buffer: MTLBuffer, index: Int) { setBuffer(buffer, offset: 0, index: index) }
}

protocol GPUBackend: AnyObject, Sendable {
    var api: String { get }
    func makeBatch(timed: Bool, orderedAfterEarlierWork: Bool) -> GPUBatch?
}

/// Bounds of what any of the engine's kernels binds: buffers up to index 8 (LibDeinterlace), textures up to 3.
private enum Bindings {
    static let buffers = 16
    static let textures = 8
    /// Stamps a timed batch can take.
    static let stamps = 16
}

// MARK: - Metal 4

@available(macOS 26, iOS 26, tvOS 26, visionOS 26, *)
private final class Metal4Backend: GPUBackend, @unchecked Sendable {
    let api = "Metal 4"
    private let device: MTLDevice
    private let queue: MTL4CommandQueue
    private let frequency: Double
    /// Command memory, command buffers, bindings and residency, reused: a context goes back to the pool when its
    /// batch has completed, so its allocator is never reset under work the GPU still reads.
    private let pool = OSAllocatedUnfairLock<[Context]>(initialState: [])

    final class Context: @unchecked Sendable {
        let allocator: MTL4CommandAllocator
        let commandBuffer: MTL4CommandBuffer
        let table: MTL4ArgumentTable
        let residency: MTLResidencySet
        let stamps: MTL4CounterHeap?

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
        }
    }

    init?(device: MTLDevice, label: String) {
        // Feedback on Metal's own queue: a queue handed to the descriptor (`feedbackQueue`, declared `assign`) is
        // released by the command queue's dealloc without having been retained (tvOS / macOS 27.2).
        let descriptor = MTL4CommandQueueDescriptor()
        descriptor.label = label
        guard let queue = try? device.makeMTL4CommandQueue(descriptor: descriptor) else { return nil }
        self.device = device
        self.queue = queue
        frequency = Double(device.queryTimestampFrequency())
    }

    func makeBatch(timed: Bool, orderedAfterEarlierWork: Bool) -> GPUBatch? {
        guard let context = pool.withLock({ $0.popLast() }) ?? Context(device: device) else { return nil }
        context.allocator.reset()
        context.residency.removeAllAllocations()
        context.commandBuffer.beginCommandBuffer(allocator: context.allocator)
        context.commandBuffer.useResidencySet(context.residency)
        return Batch(backend: self, context: context, timed: timed && context.stamps != nil, ordered: orderedAfterEarlierWork)
    }

    fileprivate func finish(_ context: Context, completion: @escaping @Sendable (GPUBatchResult) -> Void,
                            labels: [String]) {
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
        queue.commit([context.commandBuffer], options: options)
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

        init(backend: Metal4Backend, context: Context, timed: Bool, ordered: Bool) {
            self.backend = backend
            self.context = context
            self.timed = timed
            self.ordered = ordered
        }

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
            backend.finish(context, completion: completion, labels: labels)
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

        func setPipeline(_ pipeline: MTLComputePipelineState) { encoder.setComputePipelineState(pipeline) }

        func setTexture(_ texture: MTLTexture, index: Int) {
            batch.context.residency.addAllocation(texture)
            batch.context.table.setTexture(texture.gpuResourceID, index: index)
        }

        func setBuffer(_ buffer: MTLBuffer, offset: Int, index: Int) {
            batch.context.residency.addAllocation(buffer)
            batch.context.table.setAddress(buffer.gpuAddress + UInt64(offset), index: index)
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

        func barrier() {
            encoder.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
        }

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

    final class Context: @unchecked Sendable {
        let residency: MTLResidencySet?
        let samples: MTLCounterSampleBuffer?

        init(device: MTLDevice, counters: MTLCounterSet?) {
            if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) {
                residency = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
            } else {
                residency = nil
            }
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
        guard let queue = device.makeCommandQueue() else { return nil }
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
        if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *), let residency = context.residency {
            residency.removeAllAllocations()
            commandBuffer.useResidencySet(residency)
        }
        return Batch(backend: self, commandBuffer: commandBuffer, context: context,
                     timed: timed && context.samples != nil)
    }

    fileprivate func recycle(_ context: Context) { pool.withLock { $0.append(context) } }

    private final class Batch: GPUBatch {
        let backend: Metal3Backend
        let commandBuffer: MTLCommandBuffer
        let context: Context
        let timed: Bool
        var open: Pass?
        /// A timed batch's encoders, each sampled at its start and end: (label of the work it ends with, sample index).
        var labels: [String] = []

        init(backend: Metal3Backend, commandBuffer: MTLCommandBuffer, context: Context, timed: Bool) {
            self.backend = backend
            self.commandBuffer = commandBuffer
            self.context = context
            self.timed = timed
        }

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
            if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) { context.residency?.commit() }
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

        init(batch: Batch) { self.batch = batch }

        func begin() -> Bool {
            encoder = batch.makeEncoder()
            return encoder != nil
        }

        private func resident(_ allocation: MTLAllocation) {
            if #available(macOS 15, iOS 18, tvOS 18, visionOS 2, *) { batch.context.residency?.addAllocation(allocation) }
        }

        func setPipeline(_ pipeline: MTLComputePipelineState) {
            self.pipeline = pipeline
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

        func barrier() { encoder?.memoryBarrier(scope: [.buffers, .textures]) }

        /// Ends the timed encoder, which samples the work since it began, and starts the next with the same bindings.
        func timestamp(_ label: String) {
            guard batch.timed, batch.labels.count < Bindings.stamps else { return }
            batch.labels.append(label)
            encoder?.endEncoding()
            encoder = batch.makeEncoder()
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
