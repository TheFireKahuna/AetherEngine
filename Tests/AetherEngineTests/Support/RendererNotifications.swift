import Foundation
import AVFoundation
import CoreMedia
@testable import AetherEngine

/// Posts `AVSampleBufferAudioRendererWasFlushedAutomatically` for `renderer` the way the renderer does: with the time
/// of the first sample it dropped. The tvOS / macOS 27 receiver reads its event from this notification and ignores
/// one without that time, so a bare post reaches only the pre-27 path.
func postAutomaticFlush(of renderer: AVSampleBufferAudioRenderer, droppedFrom time: CMTime = .zero) {
    NotificationCenter.default.post(name: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
                                    userInfo: [AVSampleBufferAudioRendererFlushTimeKey: NSValue(time: time)])
}

/// The two ways an `AudioOutput` drives its renderer: the renderer's own calls (before 27, and the A/B fallback),
/// and on 27 the synchronizer's receiver. Tests of renderer events run on both.
let audioOutputPaths: [Bool] = {
    var paths = [false]
    if #available(macOS 27, iOS 27, tvOS 27, visionOS 27, *) { paths.append(true) }
    return paths
}()

/// Delivers an automatic flush the way `output`'s path learns of it, then enqueues `next`. The renderer's own path
/// is told by notification, at once, so the flush is waited for before `next`; the receiver reports it only with the
/// enqueue after it, so `next` is what delivers it.
func deliverAutomaticFlush(to output: AudioOutput, expecting count: Int, then next: CMSampleBuffer) async throws {
    postAutomaticFlush(of: output.renderer)
    if output.usesReceiver {
        output.enqueue(sampleBuffer: next)
        try await waitFor { output.automaticFlushCount == count }
    } else {
        try await waitFor { output.automaticFlushCount == count }
        output.enqueue(sampleBuffer: next)
    }
}
