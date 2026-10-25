import AVFoundation
import CoreMedia
import Foundation

/// The playhead on the source axis, readable on any thread: what the subtitle walk paces its read-ahead
/// against (layer 3 step 3), read where it parks rather than by a hop to the main actor for `sourceTime`.
///
/// It reads the clock playback runs on, the way Apple's own pull output is meant to be paced ("monitor the
/// item timebase, and pause pulling" once near-term playback is covered, `AVPlayerItemSampleBufferOutput.h`):
///
/// - **The native route:** the item's timebase (`AVPlayerItem.timebase`, readable off the main actor), on
///   the item axis, folded onto the source axis by the seam shift at the playhead, which the engine states
///   as it changes (`noteShift`). The timebase jumps at a seek's landing, not when the picture gets there,
///   so the walk reads ahead of where playback is going.
/// - **The software route:** the render synchronizer's timebase, already on the source axis
///   (`SoftwarePlaybackHost.presentationTimebases`).
///
/// Nil while no clock runs (a load before its item attaches): nothing plays, so there is nothing to pace
/// against, and the walk waits.
final class SourcePlayheadClock: @unchecked Sendable {
    private let lock = NSLock()
    private weak var item: AVPlayerItem?
    private var software: SoftwareTimebases?
    private var shift: Double = 0

    /// The native route's item attached; `shift` folds its time onto the source axis.
    func follow(item: AVPlayerItem, shift: Double) {
        lock.lock(); defer { lock.unlock() }
        self.item = item
        software = nil
        self.shift = shift
    }

    /// The seam shift at the native playhead, as the engine folds `sourceTime` with it.
    func noteShift(_ shift: Double) {
        lock.lock(); defer { lock.unlock() }
        self.shift = shift
    }

    /// The software route's host: its synchronizer reads the source axis itself.
    func follow(software: SoftwareTimebases) {
        lock.lock(); defer { lock.unlock() }
        item = nil
        self.software = software
        shift = 0
    }

    /// A session ended: no clock runs until the next one is followed.
    func stop() {
        lock.lock(); defer { lock.unlock() }
        item = nil
        software = nil
        shift = 0
    }

    /// The playhead on the source axis, or nil while no clock runs.
    var seconds: Double? {
        lock.lock()
        let timebase = item?.timebase ?? software?.current
        let shift = shift
        lock.unlock()
        guard let timebase else { return nil }
        let seconds = CMTimebaseGetTime(timebase).seconds
        return seconds.isFinite ? seconds + shift : nil
    }
}

/// The software host's master clock as it stands, for readers off the main actor: the `AudioOutput` the host
/// holds now, whose source-axis timebase is read per use (it is replaced once the origin latches, AE#395).
final class SoftwareTimebases: @unchecked Sendable {
    private let lock = NSLock()
    private weak var output: AudioOutput?

    func hold(_ output: AudioOutput?) {
        lock.lock(); defer { lock.unlock() }
        self.output = output
    }

    var current: CMTimebase? {
        lock.lock()
        let output = output
        lock.unlock()
        return output?.sourceTimebase
    }
}
