import Foundation

extension AetherEngine {

    /// A renderer on the software or audio-only path stays failed: take the next step of `RendererRecoveryLadder`.
    ///
    /// Before this, a failed video renderer was flushed on every frame for the rest of the session (black, with the
    /// audio running), and a failed audio renderer was a debug-only log line under a clock that ran on in silence.
    /// Hosts report a failure once per flush, so each report here is one that outlived the step before it.
    func climbRendererRecovery(_ which: FailedRenderer, error: String) {
        switch state {
        case .idle, .error: return
        default: break
        }
        // The rebuild's own teardown and load are not a new failure of the session being rebuilt.
        guard !rendererRebuildInFlight else { return }
        let step = rendererRecoveryLadder.next(at: Date())
        EngineLog.emit(
            "[AetherEngine] \(which.rawValue) renderer failed (\(error)): recovery step \(step.rawValue)",
            category: .engine)
        switch step {
        case .reposition:
            if let softwareHost {
                softwareHost.repositionToResetRenderers()
            } else {
                audioHost?.repositionToResetRenderers()
            }
        case .rebuild:
            if let refusal = sessionReloadRefusal {
                EngineLog.emit(
                    "[AetherEngine] the session cannot be rebuilt in place (\(refusal.rawValue)); failing it instead",
                    category: .engine)
                failSessionForRenderer(which, error: error)
                return
            }
            rendererRebuildInFlight = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.rendererRebuildInFlight = false }
                do {
                    try await self.reloadAtCurrentPosition()
                    EngineLog.emit("[AetherEngine] session rebuilt at the playhead with new renderers", category: .engine)
                } catch is CancellationError {
                    // A newer load took over: whatever it builds has renderers of its own.
                    EngineLog.emit("[AetherEngine] the renderer rebuild was superseded by a newer load", category: .engine)
                } catch {
                    EngineLog.emit("[AetherEngine] the renderer rebuild failed: \(error)", category: .engine)
                    // A load that failed has published its own error; one that threw before loading has not.
                    if case .error = self.state { return }
                    self.failSessionForRenderer(which, error: error.localizedDescription)
                }
            }
        case .fail:
            failSessionForRenderer(which, error: error)
        }
    }

    private func failSessionForRenderer(_ which: FailedRenderer, error: String) {
        let kind: PlaybackErrorKind = if audioHost != nil, softwareHost == nil {
            .audioSessionFailed
        } else if isLive {
            .liveSourceUnavailable
        } else {
            .softwarePipelineFailed
        }
        publishError(kind, "Playback error: the \(which.rawValue) renderer failed and did not recover (\(error))")
    }
}
