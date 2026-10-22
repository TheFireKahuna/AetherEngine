import Foundation

/// Which renderer of a sample-buffer session failed.
enum FailedRenderer: String, Sendable {
    case video, audio
}

/// What the engine does about a renderer that stays failed, one step further each time the step before it did not hold.
///
/// 1. The first step is what the renderer's own header names as its recovery:
///    - **Reposition** to the playhead, for video. The seek flushes the renderer, which is the documented reset of a
///      failed one (`AVSampleBufferVideoRenderer.status`: "This can be achieved by invoking -flush"), and the picture
///      comes back on the frame the audio is at.
///    - **Replace** the renderer, for audio. A failed audio renderer is terminal "from which recovery is not always
///      possible" and its header names no reset; a flush does not bring one back. A new renderer takes its place
///      under the running synchronizer (`AudioOutput.replaceFailedRenderer`), so the clock and the picture carry on.
/// 2. **Rebuild** the session at its position (`reloadAtCurrentPosition`): a new host, so new renderers and a new
///    synchronizer, for whatever the first step could not reach.
/// 3. **Fail** the session, where the host app sees it, rather than run on black or silent.
///
/// A step counts as not holding when the next failure comes within `window` of it. Steps expire after the window, so
/// a session that recovered and played on starts from the bottom again the next time. Owned by the engine rather than
/// a host, because the rebuild replaces the host and the ladder has to remember that it happened.
struct RendererRecoveryLadder {
    enum Step: String, Equatable, Sendable {
        case reposition, replace, rebuild, fail
    }

    static let window: TimeInterval = 60

    private var taken: [(step: Step, at: Date)] = []

    /// The step for `renderer` failing at `now`, recorded as taken.
    mutating func next(for renderer: FailedRenderer, at now: Date) -> Step {
        taken.removeAll { now.timeIntervalSince($0.at) >= Self.window }
        let step: Step = switch taken.last?.step {
        case nil: Self.firstStep(for: renderer)
        case .reposition, .replace: .rebuild
        case .rebuild, .fail: .fail
        }
        taken.append((step, now))
        return step
    }

    static func firstStep(for renderer: FailedRenderer) -> Step {
        switch renderer {
        case .video: .reposition
        case .audio: .replace
        }
    }

    mutating func reset() {
        taken.removeAll()
    }
}
