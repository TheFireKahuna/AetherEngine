import Foundation
import AVFoundation
import CoreMedia
import os

/// What one enqueue learned about the renderer.
struct AudioEnqueueReport {
    /// The renderer refused the buffer, or is failed: its error.
    var failure: String?
    /// The renderer had flushed itself since the enqueue before (route change, rate change). The receiver reports
    /// this here and nowhere else; the buffer just enqueued is the first one after that flush.
    var flushedAutomatically = false
}

/// What an audio renderer tells its output between enqueues, whichever API it is driven through.
enum AudioRendererEvent: Sendable {
    /// The renderer threw its queue away (route change, rate change); `at` is the first sample it dropped, on the
    /// renderer axis, when it says. Before 27 only: the receiver reports it in `AudioEnqueueReport`.
    case flushedAutomatically(at: CMTime?)
    /// The output was configured for another format under the renderer.
    case outputConfigurationChanged
    /// The renderer failed; a description of its error.
    case failed(String)
}

/// One audio renderer joined to a synchronizer, and every call the output makes to it.
///
/// tvOS 27 deprecates the renderer's own queue calls for Swift in favour of the synchronizer's
/// `AVSampleBufferAudioRenderer.Receiver` (`research/renderer-receiver`). The receiver is a wrapper in the AVFoundation
/// overlay over the same renderer: its results and events are the renderer's notifications and status, gathered. So
/// the two forms here are the same renderer behind two front ends, and the output above them does not know which:
///
/// - **Receiver** (27, when `throughReceiver`, which `AudioOutput.usesSampleBufferReceivers` decides): `enqueueImmediately` and `flush`. Each kind of event
///   is taken from where the receiver delivers it (macOS 27.0.1, `research/renderer-receiver` P6, P14, P15):
///   - the automatic flush only through the next enqueue's result (`enqueuedWithSuggestedFlush`, whose flush time
///     comes back invalid), so it is reported in `AudioEnqueueReport` and handled serialized with that enqueue, which
///     is the renderer header's own advice for it. Its `renderingEventsAfterFinishedEnqueuing` event never came;
///     were it to, it is ignored rather than handled twice;
///   - the output reconfiguration through the rendering-events stream, opened before the first enqueue, at once,
///     even while nothing is fed. The same reason comes back on the next result and is not acted on again; a result
///     reason the stream did not deliver is logged, the witness for a system where the stream behaves otherwise;
///   - the failure through `cancelledDueToError` on the next enqueue, and through the stream's `.failed` if it comes
///     (it did not for a real failure on macOS). The output reports it once either way.
/// - **Renderer** (before 27, and the A/B fallback): `enqueue`, `flush`, the two notifications and the `status` KVO.
///
/// The readiness the background audio-only gate paces on is the renderer's in both: the receiver can only wait with a
/// buffer in hand, and that gate waits before it decodes one.
///
/// Calls into one instance are serialized by the caller (`AudioOutput.lock`); `onEvent` runs on an arbitrary thread
/// and must not wait on that lock.
final class AudioRendererIO: @unchecked Sendable {

    let renderer: AVSampleBufferAudioRenderer

    /// The 27 receiver, typed `AnyObject` because its type exists only there. Held for as long as the renderer is
    /// attached.
    private let receiver: AnyObject?
    var usesReceiver: Bool { receiver != nil }

    private var eventTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?

    /// What the receiver has said about the renderer, for the diagnostic line: the renderer's `status` and `error`
    /// are deprecated with it. Guarded by the caller's serialization, read racily by the diagnostic line only.
    private var enqueuedSinceFlush = false
    private var failure: String?
    /// Output reconfigurations the stream delivered and the results did not yet repeat: the stream's task writes it,
    /// the enqueue reads it.
    private let reconfigurationsFromStream = OSAllocatedUnfairLock(initialState: 0)

    /// Joins `renderer` to `synchronizer`. `onEvent` gets this instance with each event, so an event from a renderer
    /// that has since been replaced can be told apart.
    init(renderer: AVSampleBufferAudioRenderer, joining synchronizer: AVSampleBufferRenderSynchronizer,
         throughReceiver: Bool, onEvent: @escaping @Sendable (AudioRendererIO, AudioRendererEvent) -> Void) {
        self.renderer = renderer
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *), throughReceiver {
            let receiver = synchronizer.sampleBufferReceiver(adding: renderer)
            self.receiver = receiver
            startEvents(from: receiver, onEvent: onEvent)
        } else {
            self.receiver = nil
            synchronizer.addRenderer(renderer)
            startNotifications(onEvent: onEvent)
        }
    }

    deinit {
        stopEvents()
    }

    // MARK: - Queue

    /// Enqueues without waiting: the output decides its own pacing.
    func enqueue(_ buffer: CMSampleBuffer) -> AudioEnqueueReport {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = receiver as? AVSampleBufferAudioRenderer.Receiver {
            switch receiver.enqueueImmediately(.handingOver(buffer)) {
            case .enqueued:
                enqueuedSinceFlush = true
                return AudioEnqueueReport()
            case .enqueuedWithSuggestedFlush(let reasons):
                enqueuedSinceFlush = true
                var report = AudioEnqueueReport()
                var reconfigurations = 0
                for reason in reasons {
                    switch reason {
                    case .wasFlushedAutomatically: report.flushedAutomatically = true
                    case .outputConfigurationChanged: reconfigurations += 1
                    @unknown default: break
                    }
                }
                noteReconfigurationsInResult(reconfigurations)
                return report
            case .cancelledDueToFlush:
                return AudioEnqueueReport()
            case .cancelledDueToError(let error):
                let described = Self.describe(error)
                failure = described
                return AudioEnqueueReport(failure: described)
            @unknown default:
                return AudioEnqueueReport()
            }
        }
        renderer.enqueue(buffer)
        guard renderer.status == .failed else { return AudioEnqueueReport() }
        return AudioEnqueueReport(failure: Self.describe(renderer.error))
    }

    /// The reconfigurations a result repeated are the stream's, already handled. More than the stream delivered
    /// means the stream missed some, which only a log can show on a device.
    private func noteReconfigurationsInResult(_ count: Int) {
        guard count > 0 else { return }
        let missed = reconfigurationsFromStream.withLock { delivered in
            defer { delivered = max(0, delivered - count) }
            return max(0, count - delivered)
        }
        if missed > 0 {
            EngineLog.emit("[AudioOutput] the receiver reported \(missed) output reconfiguration(s) its event stream "
                           + "did not", category: .swPlayback)
        }
    }

    func flush() {
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = receiver as? AVSampleBufferAudioRenderer.Receiver {
            receiver.flush()
            enqueuedSinceFlush = false
            return
        }
        renderer.flush()
    }

    /// The renderer's own readiness. Deprecated with the rest of its queue calls, and kept: the receiver offers no
    /// way to wait without a buffer in hand.
    var isReadyForMoreMediaData: Bool {
        renderer.isReadyForMoreMediaData
    }

    /// `status/sufficient/error` for the diagnostic line. On the receiver the renderer's `status`, `error` and
    /// `hasSufficientMediaDataForReliablePlaybackStart` are deprecated with no replacement, so it reports what the
    /// receiver said and `-` for sufficiency.
    var diagnosticState: String {
        if receiver != nil {
            let status = failure != nil ? "failed" : enqueuedSinceFlush ? "rendering" : "unknown"
            return "\(status)/-/\(failure ?? "-")"
        }
        let status: String
        switch renderer.status {
        case .rendering: status = "rendering"
        case .failed: status = "failed"
        case .unknown: status = "unknown"
        @unknown default: status = "?"
        }
        let sufficient = renderer.hasSufficientMediaDataForReliablePlaybackStart ? "y" : "n"
        let error = (renderer.error as NSError?).map { "\($0.domain)/\($0.code)" } ?? "-"
        return "\(status)/\(sufficient)/\(error)"
    }

    /// The renderer's error, for a failure report.
    var failureDescription: String {
        receiver != nil ? (failure ?? "no error") : Self.describe(renderer.error)
    }

    // MARK: - Detach

    /// Takes the renderer out of the synchronizer at once and stops listening to it. Nothing waits: a renderer that
    /// replaced this one is already playing, or the output is going away.
    func detach(from synchronizer: AVSampleBufferRenderSynchronizer) {
        stopEvents()
        if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *),
           let receiver = receiver as? AVSampleBufferAudioRenderer.Receiver {
            // Handed over: this instance never touches the receiver again once detached.
            nonisolated(unsafe) let handedOver = receiver
            BlockingWork.detached {
                nonisolated(unsafe) let receiver = handedOver
                _ = await synchronizer.removeReceiver(receiver, at: .invalid)
            }
        } else {
            synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
        }
    }

    // MARK: - Events

    @available(macOS 27, iOS 27, tvOS 27, visionOS 27, *)
    private func startEvents(from receiver: AVSampleBufferAudioRenderer.Receiver,
                             onEvent: @escaping @Sendable (AudioRendererIO, AudioRendererEvent) -> Void) {
        // Opened here, before any enqueue: the stream yields only what happens after it is opened (a renderer that
        // had already failed yields nothing).
        let events = receiver.renderingEventsAfterFinishedEnqueuing
        // Off the cooperative pool, like every engine task that outlives its caller (`BlockingWork`).
        eventTask = BlockingWork.detached { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .wasFlushedAutomatically:
                    // Handled through the result of the enqueue after it (`AudioEnqueueReport`), never twice.
                    break
                case .outputConfigurationChanged:
                    self.reconfigurationsFromStream.withLock { $0 += 1 }
                    onEvent(self, .outputConfigurationChanged)
                case .failed(let error):
                    let described = Self.describe(error)
                    self.failure = described
                    onEvent(self, .failed(described))
                @unknown default:
                    break
                }
            }
        }
    }

    private func startNotifications(onEvent: @escaping @Sendable (AudioRendererIO, AudioRendererEvent) -> Void) {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
                               queue: nil) { [weak self] note in
                guard let self else { return }
                let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
                onEvent(self, .flushedAutomatically(at: time.flatMap { $0.isValid ? $0 : nil }))
            },
            center.addObserver(forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange, object: renderer,
                               queue: nil) { [weak self] _ in
                guard let self else { return }
                onEvent(self, .outputConfigurationChanged)
            },
        ]
        // Key-value observable per its header, so a failure while nothing is being fed is seen when it happens.
        statusObservation = renderer.observe(\.status, options: [.new]) { [weak self] renderer, _ in
            guard let self, renderer.status == .failed else { return }
            onEvent(self, .failed(Self.describe(renderer.error)))
        }
    }

    private func stopEvents() {
        eventTask?.cancel()
        eventTask = nil
        statusObservation?.invalidate()
        statusObservation = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
    }

    static func describe(_ error: (any Error)?) -> String {
        guard let error = error as NSError? else { return "no error" }
        return "\(error.domain)/\(error.code) \(error.localizedDescription)"
    }
}
