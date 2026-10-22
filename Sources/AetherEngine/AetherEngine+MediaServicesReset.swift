import Foundation
import AVFoundation

/// AE#597, round 2: what the engine does when the media server restarts underneath it.
///
/// The platform contract (`AVAudioSessionMediaServicesWereResetNotification`, QA1749) is to re-initialize every audio
/// object at once, the session's own category, mode and policy included; while the server is merely lost, nothing is
/// rebuilt against it. Round 1 left the rebuild to the next load, so a session that was open at the reset ran on dead
/// objects until something failed loudly enough for a host to reload it: a native item failing -11819, a software
/// renderer going to failed and climbing `RendererRecoveryLadder` one step at a time, or nothing at all while paused.
///
/// Now the reset declares the session again, unconditionally, and rebuilds an open foreground session at its position
/// (`reloadAtCurrentPosition`, which consumes the reset and so builds fresh native and audio-only players, and keeps
/// the transport state the session was in, so a paused one stays paused). A session in the background, or none, keeps
/// the flag for the next load, which is what the foreground return and the host's own loads already do. A load in
/// flight is rebuilt once it exits rather than under it.
extension AetherEngine {

    enum MediaServicesRecoveryAction: Equatable {
        /// An open session in the foreground with nothing loading: rebuild it now.
        case rebuildNow
        /// A load is running: rebuild when it exits, since what it built before the reset is already dead.
        case rebuildAfterLoad
        /// Nothing open, or in the background: the next load consumes the reset.
        case nextLoad
    }

    nonisolated static func mediaServicesRecoveryAction(
        sessionOpen: Bool, backgrounded: Bool, loadInFlight: Bool
    ) -> MediaServicesRecoveryAction {
        if loadInFlight { return backgrounded ? .nextLoad : .rebuildAfterLoad }
        return sessionOpen && !backgrounded ? .rebuildNow : .nextLoad
    }

    /// `AVErrorMediaServicesWereReset` (AVError.h), spelled out: the Swift case is unavailable on macOS, where this is tested.
    nonisolated static let mediaServicesWereResetErrorCode = -11819

    /// Whether `info` is AVFoundation's "media services were reset".
    nonisolated static func isMediaServicesResetError(_ info: PlaybackErrorInfo) -> Bool {
        info.underlyingDomain == AVFoundationErrorDomain && info.underlyingCode == mediaServicesWereResetErrorCode
    }

    /// How long a -11819 waits for the reset notification before it is published as the failure it was before.
    static let mediaServicesResetErrorGrace: Duration = .seconds(2)

    /// Whether a session is open to rebuild: one with a backend that has not stopped, ended or failed.
    private var sessionIsOpenForMediaServicesRecovery: Bool {
        switch state {
        case .idle, .error, .ended: return false
        default: return playbackBackend != .none
        }
    }

    /// How long a lost server is waited for. The reset is documented to follow, but a failure is never swallowed on
    /// the strength of a promise: past this, failures are handled as if no reset were coming.
    nonisolated static let mediaServicesLostWindow: TimeInterval = 10
    /// How long after a reset a failure is still taken for its symptom.
    nonisolated static let mediaServicesResetEchoWindow: TimeInterval = 5

    /// While the server is lost, or its reset is being recovered from, a failure an object reports is a symptom of
    /// the reset, which the recovery answers as a whole.
    var mediaServicesRecoveryCoversFailures: Bool {
        Self.mediaServicesRecoveryCovers(now: Date(), lostAt: mediaServicesLostAt, lastReset: lastMediaServicesReset,
                                         recoveryPending: mediaServicesRecoveryOwed || mediaServicesRebuildInFlight)
    }

    nonisolated static func mediaServicesRecoveryCovers(now: Date, lostAt: Date?, lastReset: Date?,
                                                        recoveryPending: Bool) -> Bool {
        if recoveryPending { return true }
        if let lostAt, now.timeIntervalSince(lostAt) < mediaServicesLostWindow { return true }
        if let lastReset, now.timeIntervalSince(lastReset) < mediaServicesResetEchoWindow { return true }
        return false
    }

    /// The reset itself (the lost half only stamps `mediaServicesLostAt`).
    func recoverFromMediaServicesReset() {
        mediaServicesLostAt = nil
        lastMediaServicesReset = Date()
        #if os(iOS) || os(tvOS)
        // Declared again unconditionally, on the transition queue, ahead of anything the rebuild activates.
        let mode = Self.audioSessionMode(audioOnly: loadedOptions.audioOnly)
        _ = enqueueAudioSessionTransition {
            AetherEngine.applyAudioSessionCategory(mode: mode, force: true)
        }
        #endif
        let action = Self.mediaServicesRecoveryAction(
            sessionOpen: sessionIsOpenForMediaServicesRecovery,
            backgrounded: appIsBackgrounded,
            loadInFlight: loadIsInFlight)
        EngineLog.emit("[AetherEngine] #597 media services recovery: \(action)", category: .engine)
        switch action {
        case .rebuildNow:
            rebuildAfterMediaServicesReset()
        case .rebuildAfterLoad:
            mediaServicesRecoveryOwed = true
        case .nextLoad:
            break
        }
    }

    /// Called from a load's exit: the rebuild a reset during that load was owed.
    func runOwedMediaServicesRecovery() {
        guard mediaServicesRecoveryOwed else { return }
        mediaServicesRecoveryOwed = false
        guard sessionIsOpenForMediaServicesRecovery, !appIsBackgrounded else {
            EngineLog.emit("[AetherEngine] #597 the load the reset landed in left no open foreground session; the "
                           + "next load consumes the reset", category: .engine)
            return
        }
        rebuildAfterMediaServicesReset()
    }

    private func rebuildAfterMediaServicesReset() {
        guard !mediaServicesRebuildInFlight else { return }
        if let refusal = sessionReloadRefusal {
            EngineLog.emit("[AetherEngine] #597 the session cannot be rebuilt in place after the reset "
                           + "(\(refusal.rawValue)); failing it so the host can start it again", category: .engine)
            publishError(isLive ? .liveSourceUnavailable : .reloadFailed,
                         "Media services were reset and this session cannot be rebuilt in place.")
            return
        }
        mediaServicesRebuildInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.mediaServicesRebuildInFlight = false }
            do {
                try await self.reloadAtCurrentPosition()
                EngineLog.emit("[AetherEngine] #597 session rebuilt at the playhead after the media services reset",
                               category: .engine)
            } catch is CancellationError {
                EngineLog.emit("[AetherEngine] #597 the rebuild after the reset was superseded by a newer load, "
                               + "which consumed the reset", category: .engine)
            } catch {
                EngineLog.emit("[AetherEngine] #597 the rebuild after the reset failed: \(error)", category: .engine)
                if case .error = self.state { return }
                self.publishError(.reloadFailed, "Media services were reset and the session could not be rebuilt.",
                                  underlying: error)
            }
        }
    }

    /// A host failure on its way to `state`. AVFoundation's -11819 is the per-object face of a media services reset:
    /// when the reset has been seen (or is seen within `mediaServicesResetErrorGrace`), the recovery answers it and the
    /// failure is not published. One that no reset accompanies is published as before, and logged, since the startup
    /// gate has long read a bare -11819 as a cold Dolby Vision handshake and only device logs can say how often it is.
    /// Returns true when the failure was taken over.
    func takeOverMediaServicesResetFailure(_ info: PlaybackErrorInfo, publish: @escaping @MainActor (PlaybackErrorInfo) -> Void) -> Bool {
        guard Self.isMediaServicesResetError(info) else { return false }
        let failedAt = Date()
        // A reset already in hand is being answered; a lost server is waited for, but only so long.
        let recovering = mediaServicesRecoveryOwed || mediaServicesRebuildInFlight
            || lastMediaServicesReset.map { failedAt.timeIntervalSince($0) < Self.mediaServicesResetEchoWindow } == true
        if recovering {
            EngineLog.emit("[AetherEngine] #597 -11819 from the session after the media services reset: left to the "
                           + "recovery", category: .engine)
            return true
        }
        let wait: Duration = mediaServicesLostAt != nil
            ? .seconds(Self.mediaServicesLostWindow) : Self.mediaServicesResetErrorGrace
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard let self else { return }
            if let reset = self.lastMediaServicesReset, reset >= failedAt.addingTimeInterval(-1) {
                EngineLog.emit("[AetherEngine] #597 -11819 was followed by the media services reset: left to the "
                               + "recovery", category: .engine)
                return
            }
            EngineLog.emit("[AetherEngine] #597 -11819 with no media services reset notification: published as the "
                           + "failure it is", category: .engine)
            publish(info)
        }
        return true
    }
}
