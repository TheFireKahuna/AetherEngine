import Foundation

/// A hold of `AudioOutput`'s clock at rate 0 until the decoder has frames from its new position in the
/// layer (#800), and how it ended. Every `.began` is followed by exactly one `.released`.
enum ClockHoldEvent: Sendable, Equatable {
    case began
    case released(ClockHoldRelease)
}

/// How a clock hold ended (`ClockHoldEvent.released`).
enum ClockHoldRelease: Sendable, Equatable {
    /// The frames from the held position on are in the layer.
    case ready(waitedSeconds: Double)
    /// The decoder produced nothing for 2 s, or kept producing without reaching the position for 6 s.
    /// The clock starts anyway, so the first frames after it can arrive late.
    case timedOut(waitedSeconds: Double)
    /// A seek, pause, rate change or the end of the session took over before the hold ended.
    case cancelled
}
