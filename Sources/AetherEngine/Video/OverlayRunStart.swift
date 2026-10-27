import Foundation
import QuartzCore
import os

/// Where an overlay's decode should be at the start of a producer run, and the hold that keeps the run's first segment
/// from AVPlayer until the picture AVPlayer starts on is decoded.
///
/// AVPlayer prerolls its own decode and starts its clock as soon as it has a run's first segment, so a decoder it
/// does not own (the software overlay's, the FEL overlay's enhancement layer) is waited for there and only there;
/// after it the decoder only has to keep pace. Shared by ``OverlayDecodeTap`` and ``FelEnhancementTap``.
///
/// The picture AVPlayer starts on is the one on screen at the time it reports (`currentTime()`): a seek's target as
/// soon as the seek is made, before any of its data arrives, while the item's timebase stays where it was until the
/// segment is complete, which the hold itself withholds. AVPlayer seeks with zero tolerance, and when it starts
/// playing its timebase runs from a little before that time so as to reach it at the host time it starts on, while the
/// item's time sits at the target (`setRate(_:time:atHostTime:)`), so nothing earlier is shown. Before AVPlayer exists
/// (a load's first run, cut before the item is made) the session's start position stands in.
final class OverlayRunStart: @unchecked Sendable {
    /// A clock the player moved within this long is AVPlayer's; otherwise the producer's run start stands in for it.
    static let playerClockSeconds = 0.5
    /// A clock this far before a run's start is not in the run: a run cut ahead of a playing clock holds nothing.
    static let runStartNearClockSeconds = 1.0
    /// A clock within this of the run's start is AVPlayer's staging, not a target: while an item gets ready it sets
    /// its clock to the first picture of the segment it asked for, then back to the time it was seeked to.
    static let stagingToleranceSeconds = 0.001
    /// How long the hold waits for AVPlayer to report a time inside the run: AVPlayer asks for a seek's segment
    /// before it reports the seek's target, which a Mac measured 50 to 57 ms after the seek.
    static let reportSeconds = 0.25
    /// How often the hold reads AVPlayer's reported time, a synchronous call into the media server.
    static let reportReadSeconds = 0.02

    private struct State {
        /// Where the current run starts (item seconds), the time of its first unit.
        var runStart: Double?
        /// The latest unit the run has cut.
        var runEnd: Double?
        /// The run's target once AVPlayer has reported it.
        var reported: Double?
        /// The player's clock, staging aside, and the one before it.
        var clock: Double?
        var previousClock: Double?
        var playerMoved = -Double.infinity
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// AVPlayer's reported time (item seconds), nil before there is an item or while it reports none.
    private let reportedTime = OSAllocatedUnfairLock<(@Sendable () -> Double?)?>(initialState: nil)

    /// Where AVPlayer will start, when the session knows it before the player has a clock (a resume's start
    /// position): the same as the player moving there.
    func noteStart(at seconds: Double) {
        state.withLock { s in
            s.previousClock = s.clock
            s.clock = seconds
        }
    }

    /// Reads AVPlayer's reported time for the current item; nil when the overlay's item is gone.
    func follow(reportedTime read: (@Sendable () -> Double?)?) {
        reportedTime.withLock { $0 = read }
    }

    /// AVPlayer's reported time when it lies in the run that starts at `start` and has been cut to `end`, as the
    /// picture it starts on: the run's first when it reports a time just before it.
    private func reportedTarget(start: Double, end: Double) -> Double? {
        guard let read = reportedTime.withLock({ $0 }), let seconds = read(), seconds.isFinite,
              seconds >= start - Self.runStartNearClockSeconds, seconds <= end else { return nil }
        return max(seconds, start)
    }

    /// A unit the producer kept, at `seconds` (item time); `opensRun` for a producer's first. Where the decode should
    /// work toward now, nil to leave it: with a player that has not moved its clock lately (a load), the start position
    /// when it is in the run, else the run's start. A moving player's clock and reported time are left to the hold:
    /// when a seek's run opens, both may still be where the seek left from.
    func noteUnit(at seconds: Double, opensRun: Bool) -> Double? {
        state.withLock { s -> Double? in
            guard opensRun || s.runStart == nil else {
                s.runEnd = max(s.runEnd ?? seconds, seconds)
                return nil
            }
            s.runStart = seconds
            s.runEnd = seconds
            s.reported = nil
            guard CACurrentMediaTime() - s.playerMoved > Self.playerClockSeconds else { return nil }
            return Self.clockTarget(s) ?? seconds
        }
    }

    /// AVPlayer's clock reads `seconds`. False for a reading the decode does not follow: once AVPlayer has reported a
    /// target in the current run, a clock outside the run is still where the seek left from (the timebase moves only
    /// when the seek's segment is complete, which the hold withholds), and a clock at the run's start is its staging.
    func notePlayerMoved(to seconds: Double) -> Bool {
        state.withLock { s -> Bool in
            s.playerMoved = CACurrentMediaTime()
            if s.reported != nil, let start = s.runStart, let end = s.runEnd,
               seconds < start - Self.runStartNearClockSeconds || seconds > end {
                return false
            }
            if let start = s.runStart, abs(seconds - start) <= Self.stagingToleranceSeconds,
               let target = s.reported ?? Self.clockTarget(s), abs(target - start) > Self.stagingToleranceSeconds {
                return false
            }
            s.previousClock = s.clock
            s.clock = seconds
            return true
        }
    }

    /// The picture AVPlayer starts the current run on, from the player's clock or the start position: nil when it is
    /// not in the run. A clock at the run's start may be AVPlayer's staging, set before the run was seen, so the one
    /// before it is taken when that one is in the run.
    private static func clockTarget(_ s: State) -> Double? {
        guard let start = s.runStart else { return nil }
        func inRun(_ clock: Double?) -> Double? {
            guard let clock, clock >= start - runStartNearClockSeconds else { return nil }
            return max(clock, start)
        }
        if let clock = s.clock, abs(clock - start) <= stagingToleranceSeconds,
           let earlier = inRun(s.previousClock), abs(earlier - start) > stagingToleranceSeconds {
            return earlier
        }
        return inRun(s.clock)
    }

    /// How long a decoder that has started working toward the picture may go without decoding another unit before
    /// the wait gives up on it. Before its first unit (a session opening, pipelines warming) only the overall
    /// timeout applies.
    static let stalledDecodeSeconds = 2.0

    /// Blocks until `hasPicture(target)` holds, where the target is the picture AVPlayer starts the current run on:
    /// at its reported time when that is in the part of the run cut so far, waited for up to ``reportSeconds``; then
    /// at the player's clock or the start position when that is in the run; then at the run's start when the decode
    /// was put there (`decodeClock`, the clock it works toward). `decodeTo` moves the decode to a target AVPlayer
    /// reports. True when the picture is there or nothing needs to wait; false after `timeout`, after
    /// ``stalledDecodeSeconds`` in which `progress` (the decoder's units so far) stood still once it had moved, or once
    /// `shouldStop` says so.
    func awaitPicture(decodeClock: () -> Double, decodeTo: (Double) -> Void, timeout: TimeInterval,
                      progress: () -> Int, hasPicture: (Double) -> Bool, shouldStop: () -> Bool) -> Bool {
        let began = CACurrentMediaTime()
        var last = progress()
        var movedAt: CFTimeInterval?
        var readAt = -Double.infinity
        while true {
            let now = CACurrentMediaTime()
            let run = state.withLock { s in (s.runStart, s.runEnd, s.reported) }
            guard let start = run.0, let end = run.1 else { return true }
            var reported = run.2
            if reported == nil, now - readAt >= Self.reportReadSeconds {
                readAt = now
                if let target = reportedTarget(start: start, end: end) {
                    reported = target
                    state.withLock { $0.reported = target }
                    decodeTo(target)
                }
            }
            let target: Double?
            if let reported {
                target = reported
            } else if now - began < Self.reportSeconds, reportedTime.withLock({ $0 != nil }) {
                target = .nan
            } else {
                let decodeAt = decodeClock()
                target = state.withLock { s -> Double? in
                    if let target = Self.clockTarget(s) { return target <= end ? target : nil }
                    return abs(decodeAt - start) < Self.runStartNearClockSeconds ? start : nil
                }
            }
            guard let target else { return true }
            if !target.isNaN, hasPicture(target) { return true }
            if shouldStop() { return false }
            let count = progress()
            if count != last { last = count; movedAt = now }
            if now - began > timeout { return false }
            if let movedAt, now - movedAt > Self.stalledDecodeSeconds { return false }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}
