import AVFoundation
import Foundation

/// AVFoundation's own account of an item's playback (`AVMetricEvent`): stalls, seeks and whether they landed in
/// the buffer, rate changes, the time to keep up, variant switches, errors, and the session summary, each logged as
/// AVFoundation reports it, with the item time it happened at.
///
/// Requests for playlists, segments and keys are left out: the engine serves the item's HLS itself, one request per
/// segment, and logs its own side of those.
@available(macOS 15, iOS 18, tvOS 18, *)
final class AVPlayerItemMetricsLog {
    private let task: Task<Void, Never>

    init(item: AVPlayerItem, sid: Int) {
        let metrics = item.allMetrics()
        task = Task.detached(priority: .utility) {
            do {
                for try await event in metrics {
                    guard let line = Self.describe(event) else { continue }
                    EngineLog.emit("[NativeAVPlayerHost] #\(sid) metrics: \(line)", category: .engine)
                }
            } catch {
                EngineLog.emit("[NativeAVPlayerHost] #\(sid) metrics ended: \(error)", category: .engine)
            }
        }
    }

    deinit { task.cancel() }

    /// One event as a log fragment, nil for the request events.
    static func describe(_ event: AVMetricEvent) -> String? {
        let at = String(format: "at %.3f s", event.mediaTime.seconds)
        switch event {
        case is AVMetricMediaResourceRequestEvent, is AVMetricHLSPlaylistRequestEvent,
             is AVMetricHLSMediaSegmentRequestEvent, is AVMetricContentKeyRequestEvent:
            return nil
        case let e as AVMetricPlayerItemStallEvent:
            return "stall \(at), rate \(e.previousRate) -> \(e.rate)"
        case let e as AVMetricPlayerItemSeekDidCompleteEvent:
            return "seek done \(at), in the buffer \(e.didSeekInBuffer), rate \(e.previousRate) -> \(e.rate)"
        case let e as AVMetricPlayerItemSeekEvent:
            return "seek \(at), rate \(e.previousRate) -> \(e.rate)"
        case let e as AVMetricPlayerItemRateChangeEvent:
            return "rate \(e.previousRate) -> \(e.rate) \(at)"
        case let e as AVMetricPlayerItemInitialLikelyToKeepUpEvent:
            return String(format: "first likely to keep up %@ after %.3f s (%d playlist, %d segment requests)",
                          at, e.timeTaken, e.playlistRequestEvents.count, e.mediaSegmentRequestEvents.count)
        case let e as AVMetricPlayerItemLikelyToKeepUpEvent:
            return String(format: "likely to keep up %@ after %.3f s", at, e.timeTaken)
        case let e as AVMetricPlayerItemVariantSwitchEvent:
            return "variant switch \(at), succeeded \(e.didSucceed)"
        case is AVMetricPlayerItemVariantSwitchStartEvent:
            return "variant switch starts \(at)"
        case let e as AVMetricPlayerItemPlaybackSummaryEvent:
            return String(format: "summary: played %d s, %d stalls (%.3f s recovering), startup %.3f s, "
                          + "%d recoverable errors, %d requests, bitrate %d average / %d peak%@",
                          e.playbackDuration, e.stallCount, e.timeSpentRecoveringFromStall, e.timeSpentInInitialStartup,
                          e.recoverableErrorCount, e.mediaResourceRequestCount, e.timeWeightedAverageBitrate,
                          e.timeWeightedPeakBitrate, e.errorEvent.map { ", error " + describeError($0.error) } ?? "")
        case let e as AVMetricErrorEvent:
            return "error \(at), recovered \(e.didRecover): \(describeError(e.error))"
        default:
            return "\(type(of: event)) \(at)"
        }
    }

    private static func describeError(_ error: Error) -> String {
        let error = error as NSError
        return "\(error.domain)/\(error.code) \(error.localizedDescription)"
    }
}
