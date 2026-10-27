import AVFoundation
import CoreMedia
import Foundation

/// The playhead on the source axis, readable on any thread: what the pump measures its subtitle read-ahead
/// from (layer 3 step 5), read where it parks rather than by a hop to the main actor for `sourceTime`.
///
/// It reads the clock playback runs on, the way Apple's own pull output is meant to be paced ("monitor the
/// item timebase, and pause pulling" once near-term playback is covered, `AVPlayerItemSampleBufferOutput.h`):
///
/// - **The native route:** the item's timebase (`AVPlayerItem.timebase`, readable off the main actor), on
///   the item axis, folded onto the source axis by the seam shift at the playhead, which the engine states
///   as it changes (`noteShift`). The timebase jumps at a seek's landing, not when the picture gets there,
///   so the pump reads ahead of where playback is going.
///
/// Nil while no clock runs (a load before its item attaches): nothing plays, so there is nothing to read
/// ahead of, and the pump keeps to its own forward window.
final class SourcePlayheadClock: @unchecked Sendable {
    private let lock = NSLock()
    private weak var item: AVPlayerItem?
    private var shift: Double = 0

    /// The native route's item attached; `shift` folds its time onto the source axis.
    func follow(item: AVPlayerItem, shift: Double) {
        lock.lock(); defer { lock.unlock() }
        self.item = item
        self.shift = shift
    }

    /// The seam shift at the native playhead, as the engine folds `sourceTime` with it.
    func noteShift(_ shift: Double) {
        lock.lock(); defer { lock.unlock() }
        self.shift = shift
    }

    /// A session ended: no clock runs until the next one is followed.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        item = nil
        shift = 0
    }

    /// The playhead on the source axis, or nil while no clock runs.
    var seconds: Double? {
        lock.lock()
        let timebase = item?.timebase
        let shift = shift
        lock.unlock()
        guard let timebase else { return nil }
        let seconds = CMTimebaseGetTime(timebase).seconds
        return seconds.isFinite ? seconds + shift : nil
    }
}
