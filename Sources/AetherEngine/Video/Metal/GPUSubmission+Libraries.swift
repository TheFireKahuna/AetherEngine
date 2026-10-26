import Foundation
import Metal
import LibDeinterlace
#if MLSubtitleUpscale
import LibMLSubUpscaler
#endif

// The libraries the engine encodes for declare the submission they need as protocols of their own; these present a
// ``GPUSubmitter`` as each. A pass needs nothing: every ``ComputePass`` is already the libraries' pass.

/// A ``GPUSubmitter`` as LibDeinterlace's submission. Inverse telecine orders its passes with fences of its own, so a
/// batch is not ordered after the work before it.
final class DeinterlaceGPU: DeinterlaceSubmission, @unchecked Sendable {
    let submitter: GPUSubmitter
    var device: MTLDevice { submitter.device }

    init(_ submitter: GPUSubmitter) { self.submitter = submitter }

    func makeBatch() -> (any DeinterlaceBatch)? { submitter.makeBatch().map(Batch.init) }

    /// `batch` as LibDeinterlace's, for the library to encode passes of its own into a batch the engine commits.
    static func batch(_ batch: GPUBatch) -> any DeinterlaceBatch { Batch(batch) }

    private final class Batch: DeinterlaceBatch {
        let batch: GPUBatch
        init(_ batch: GPUBatch) { self.batch = batch }
        func makePass() -> (any DeinterlacePass)? { batch.makePass() }
        func commit(_ completion: @escaping @Sendable (String?) -> Void) { batch.commit { completion($0.error) } }
    }
}

#if MLSubtitleUpscale
/// A ``GPUSubmitter`` as LibMLSubUpscaler's submission: each batch ordered after the work committed before it, as
/// the upscaler's passes read what the one before wrote.
final class SubtitleUpscaleGPU: SubtitleUpscaleSubmission, @unchecked Sendable {
    let submitter: GPUSubmitter
    var device: MTLDevice { submitter.device }

    init(_ submitter: GPUSubmitter) { self.submitter = submitter }

    func makeBatch() -> (any SubtitleUpscaleBatch)? {
        submitter.makeBatch(orderedAfterEarlierWork: true).map(Batch.init)
    }

    private final class Batch: SubtitleUpscaleBatch {
        let batch: GPUBatch
        init(_ batch: GPUBatch) { self.batch = batch }
        func wait(for event: MTLEvent, value: UInt64) { batch.wait(for: event, value: value) }
        func signal(_ event: MTLEvent, value: UInt64) { batch.signal(event, value: value) }
        func makePass() -> (any SubtitleUpscalePass)? { batch.makePass() }
        func commit(_ completion: @escaping @Sendable (String?) -> Void) { batch.commit { completion($0.error) } }
    }
}
#endif
