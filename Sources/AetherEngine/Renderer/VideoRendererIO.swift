import Foundation
import AVFoundation
import CoreMedia
import os

/// What happened to a frame handed to the video renderer.
enum VideoEnqueueOutcome: Equatable {
    /// Taken. `confirmed` when the renderer had already been taking frames since its last flush: what
    /// `AVQueuedSampleBufferRenderingStatus.rendering` said before the 27 SDKs, and what ends a run of failures.
    case enqueued(confirmed: Bool)
    /// Not taken: the renderer is failed, or needs a flush to decode again. Apple's recovery for both is a flush and
    /// the frame again (`AVSampleBufferVideoRenderer.status`, `requiresFlushToResumeDecoding`).
    case failed(String)
}

/// The video renderer's queue: every enqueue, flush and readiness read the software path makes.
///
/// tvOS 27 deprecates the renderer's own queue calls for Swift in favour of the synchronizer's
/// `AVSampleBufferVideoRenderer.Receiver`, which wraps the same renderer (`research/renderer-receiver`). A receiver
/// exists only while the renderer is joined to a synchronizer, so:
///
/// - **Joined, on 27**, when the session's audio output drives its renderers through receivers
///   (`AudioOutput.throughReceivers`): `enqueueImmediately` and the receiver's `flush`.
///   A failed or flush-to-resume result is reported as `.failed`. Decode failures cannot happen: the engine hands the
///   renderer decoded frames.
/// - **Outside a synchronizer (before joining, after leaving), or before 27:** the renderer's own calls, with its
///   `status` read before each frame, as the engine always did. Nothing is enqueued before joining (the demux loop
///   starts after it), so in practice this is the pre-27 path.
///
/// Readiness is the renderer's in both. It is deprecated, and kept: the demux gates wait on it before a compressed
/// packet is decoded, and the receiver can only wait with a decoded frame in hand.
///
/// Thread-safe: frames arrive on the decoder's thread, flushes from the demux loop and the main actor. The receiver
/// and the renderer serialize their own queues; this guards only what it remembers.
final class VideoRendererIO: @unchecked Sendable {

    let renderer: AVSampleBufferVideoRenderer

    private struct State {
        /// The 27 receiver while joined, typed `AnyObject` because its type exists only there.
        var receiver: AnyObject?
        /// Receiver path only: whether a frame was taken since the last flush, and the last refusal.
        var takenSinceFlush = false
        var failure: String?
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    var usesReceiver: Bool { state.withLockUnchecked { $0.receiver != nil } }

    // MARK: - Synchronizer

    /// Joins the renderer to `synchronizer`, through a receiver on 27 when `throughReceiver`.
    func join(_ synchronizer: AVSampleBufferRenderSynchronizer, throughReceiver: Bool) {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *), throughReceiver {
            let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
            state.withLockUnchecked { $0 = State(receiver: receiver) }
        } else {
            synchronizer.addRenderer(renderer)
        }
    }

    /// Takes the renderer out of `synchronizer` and blocks until it is out (at most a second). The synchronizer
    /// detaches asynchronously; a caller that hands the layer to a new session's timebase straight away would
    /// otherwise have it owned by both (Apple-documented undefined behaviour), which failed the first PCM to Atmos
    /// switch after launch with FigVideoQueueRemote -12080 and a picture that stopped while audio went on.
    func leave(_ synchronizer: AVSampleBufferRenderSynchronizer) {
        let joined = state.withLockUnchecked { current -> AnyObject? in
            defer { current = State() }
            return current.receiver
        }
        let removed = DispatchSemaphore(value: 0)
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = joined as? AVSampleBufferVideoRenderer.Receiver {
            Self.remove(receiver, from: synchronizer, at: synchronizer.currentTime()) { removed.signal() }
        } else {
            synchronizer.removeRenderer(renderer, at: synchronizer.currentTime()) { _ in removed.signal() }
        }
        if removed.wait(timeout: .now() + .seconds(1)) == .timedOut {
            EngineLog.emit("[Renderer] leaving the synchronizer: timed out waiting for the removal",
                           category: .swPlayback)
        }
    }

    /// Removes a receiver and calls `done` once the synchronizer has, off the caller's thread. The receiver is handed
    /// over: nothing else holds it once `leave` cleared it.
    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    private static func remove(_ receiver: sending AVSampleBufferVideoRenderer.Receiver,
                               from synchronizer: AVSampleBufferRenderSynchronizer,
                               at time: CMTime, done: @escaping @Sendable () -> Void) {
        // A closure's captures cannot be `sending` (the compiler cannot know it runs once); this one
        // runs once and is the receiver's only holder, which is what the opt-out below asserts.
        nonisolated(unsafe) let handedOver = receiver
        // Off the caller's executor and off the cooperative pool (BlockingWork): the caller (the host's stop(),
        // on the main actor) blocks on `done` for up to a second, as it did on removeRenderer's callback.
        BlockingWork.detached {
            nonisolated(unsafe) let receiver = handedOver
            _ = await synchronizer.removeReceiver(receiver, at: time)
            done()
        }
    }

    // MARK: - Queue

    func enqueue(_ frame: CMSampleBuffer) -> VideoEnqueueOutcome {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = state.withLockUnchecked({ $0.receiver }) as? AVSampleBufferVideoRenderer.Receiver {
            let result = receiver.enqueueImmediately(.handingOver(frame))
            return state.withLockUnchecked { current in
                switch result {
                case .enqueued, .enqueuedWithDecodeFailures:
                    let confirmed = current.takenSinceFlush
                    current.takenSinceFlush = true
                    current.failure = nil
                    return .enqueued(confirmed: confirmed)
                case .cancelledDueToFlushRequiredToResume(let error), .cancelledDueToError(let error):
                    current.failure = Self.describe(error)
                    return .failed(current.failure ?? "")
                case .cancelledDueToFlush:
                    // An immediate enqueue does not wait, so a flush has nothing of it to cancel.
                    return .enqueued(confirmed: false)
                @unknown default:
                    return .enqueued(confirmed: false)
                }
            }
        }
        switch renderer.status {
        case .failed:
            return .failed(Self.describe(renderer.error))
        case .rendering:
            renderer.enqueue(frame)
            return .enqueued(confirmed: true)
        default:
            renderer.enqueue(frame)
            return .enqueued(confirmed: false)
        }
    }

    /// Discards everything queued; with `removingDisplayedImage`, the picture on screen too. Issued before it
    /// returns, so a frame enqueued after it is never discarded by it.
    ///
    /// The receiver's `flush()` is the renderer's `-flush`, which is `flushWithRemovalOfDisplayedImage:NO`, the call
    /// the engine always made to keep the picture across a seek (seen by swizzling on macOS 27). Its removing form is
    /// async only, and issues its flush after the caller has moved on even from `Task.immediate`, so a frame enqueued
    /// right after it (the foreground return) could be discarded. The picture is removed instead the way the
    /// renderer's header documents for removing images in order: an empty-media marker at the timebase's time.
    func flush(removingDisplayedImage: Bool) {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = state.withLockUnchecked({ $0.receiver }) as? AVSampleBufferVideoRenderer.Receiver {
            receiver.flush()
            state.withLockUnchecked {
                $0.takenSinceFlush = false
                $0.failure = nil
            }
            if removingDisplayedImage, let marker = Self.emptyMediaMarker(at: CMTimebaseGetTime(renderer.timebase)) {
                _ = receiver.enqueueImmediately(.handingOver(marker))
            }
            return
        }
        renderer.flush(removingDisplayedImage: removingDisplayedImage) { }
    }

    /// The renderer's readiness for more frames. See the type's note on why this stays the renderer's.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// `unknown`, `rendering` or `failed`: the renderer's `status` before 27, what the receiver said since.
    var statusName: String {
        if let named = state.withLockUnchecked({ current -> String? in
            guard current.receiver != nil else { return nil }
            return current.failure != nil ? "failed" : current.takenSinceFlush ? "rendering" : "unknown"
        }) {
            return named
        }
        switch renderer.status {
        case .unknown: return "unknown"
        case .rendering: return "rendering"
        case .failed: return "failed"
        @unknown default: return "?"
        }
    }

    /// The renderer's last failure, if it is failed.
    var failureDescription: String? {
        if let failure = state.withLockUnchecked({ current -> String?? in
            current.receiver != nil ? .some(current.failure) : nil
        }) {
            return failure
        }
        return renderer.status == .failed ? Self.describe(renderer.error) : nil
    }

    // MARK: -

    /// A sample buffer with no samples and `kCMSampleBufferAttachmentKey_EmptyMedia`: enqueued, it removes the
    /// images before it at `time`.
    static func emptyMediaMarker(at time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var marker: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true,
                                   makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
                                   sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
                                   sampleSizeArray: nil, sampleBufferOut: &marker) == noErr,
              let marker else { return nil }
        CMSetAttachment(marker, key: kCMSampleBufferAttachmentKey_EmptyMedia, value: kCFBooleanTrue,
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return marker
    }

    static func describe(_ error: (any Error)?) -> String {
        guard let error = error as NSError? else { return "no error" }
        return "\(error.domain)/\(error.code) \(error.localizedDescription)"
    }
}

@available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
extension CMReadySampleBuffer where Content == CMSampleBuffer.DynamicContent {
    /// A receiver's form of a sample buffer the engine keeps a reference to: a video frame tried again after a
    /// flush, audio kept to enqueue again after an output reconfiguration or a renderer replacement. Swift's
    /// `sending` cannot see that sharing is safe, so this says it: the engine never mutates a sample buffer once
    /// it has been handed to a renderer, which is the contract `init(unsafeBuffer:)` asks for and the one the
    /// renderers' own `enqueue` always had.
    static func handingOver(_ buffer: CMSampleBuffer) -> Self {
        nonisolated(unsafe) let handedOver = buffer
        return CMReadySampleBuffer(unsafeBuffer: handedOver)
    }
}
