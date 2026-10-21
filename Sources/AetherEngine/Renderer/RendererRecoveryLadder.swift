import Foundation

/// Which renderer of a sample-buffer session failed.
enum FailedRenderer: String, Sendable {
    case video, audio
}

/// What the engine does about a renderer that stays failed, one step further each time the step before it did not hold.
///
/// 1. **Reposition** to the playhead. The seek flushes both renderers, which is the documented reset of a failed one
///    (`AVSampleBufferVideoRenderer.status`); the picture comes back on the frame the audio is at.
/// 2. **Rebuild** the session at its position (`reloadAtCurrentPosition`): a new host, so new renderers and a new
///    synchronizer. A failed audio renderer is terminal "from which recovery is not always possible" (its header), and
///    a flush does not always bring one back; a renderer that was never used has no state to fail from.
/// 3. **Fail** the session, where the host app sees it, rather than run on black or silent.
///
/// A step counts as not holding when the next failure comes within `window` of it. Steps expire after the window, so
/// a session that recovered and played on starts from the bottom again the next time. Owned by the engine rather than
/// a host, because the rebuild replaces the host and the ladder has to remember that it happened.
struct RendererRecoveryLadder {
    enum Step: String, Equatable, Sendable {
        case reposition, rebuild, fail
    }

    static let window: TimeInterval = 60

    private var taken: [(step: Step, at: Date)] = []

    /// The step for a failure at `now`, recorded as taken.
    mutating func next(at now: Date) -> Step {
        taken.removeAll { now.timeIntervalSince($0.at) >= Self.window }
        let step: Step = switch taken.last?.step {
        case nil: .reposition
        case .reposition: .rebuild
        case .rebuild, .fail: .fail
        }
        taken.append((step, now))
        return step
    }

    mutating func reset() {
        taken.removeAll()
    }
}
