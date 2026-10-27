import CoreMedia
import CoreVideo
import Foundation

/// The overlay picture of a stream AVPlayer is served a placeholder of (`OverlayPlaceholder`): the session's own
/// decode of the source (``OverlayDecodeTap``), each picture at its own item time. Its pictures do not follow the
/// placeholder's frames one for one (a field-rate deinterlace doubles them, decimation drops one in five, soft
/// telecine retimes them), so they are queued by their own times, and AVPlayer's frames are dropped.
///
/// Scanning (reverse, or faster than twice real time) AVPlayer plays the I-frame tier, whose stills an overlay
/// session encodes from the source's keyframes in the source's range: those frames are shown as they are.
final class DecodedPictureSource: OverlayFrameSource, @unchecked Sendable {
    let tap: OverlayDecodeTap

    init(tap: OverlayDecodeTap) { self.tap = tap }

    /// The placeholder's frames are dropped and the scan tier's shown as they are: any format AVPlayer decodes to.
    var outputAttributes: [String: any Sendable] { [:] }

    /// The decoder's buffers come from the GPU finisher's own pool (`DisplayBufferWriter`).
    func followRenderer(_ attributes: [String: Any]) {}

    func advance(to itemSeconds: Double) { tap.advance(to: itemSeconds) }

    func pacing(atRate rate: Double) -> OverlayPacing { rate < 0 || rate > 2 ? .showOutput : .clock }

    func frameInterval(after itemSeconds: Double) -> CMTimeRange? { nil }

    func makePicture(from output: CVPixelBuffer, at frameTime: CMTime,
                     done: @escaping @Sendable (CVPixelBuffer?) -> Void) -> Bool { false }

    func pictures(after last: CMTime?, at itemSeconds: Double) -> [(picture: CVPixelBuffer, time: CMTime)] {
        tap.pictures(after: last, atOrBefore: itemSeconds).map { ($0.picture, $0.time) }
    }

    func logSummary() -> String {
        let held = tap.held
        return "held \(held.units) units (\(held.bytes >> 20) MB on disk) / \(held.decoded) decoded"
    }
    func drainStageTimes() -> String? { nil }
}
