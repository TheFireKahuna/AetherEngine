import Foundation
import AVFoundation
import Combine

extension AetherEngine {

    /// The longest a held picture stays up when the next item never reports a first frame. The
    /// rebuild has its own failure paths; this only keeps a frozen frame from outliving them.
    static let heldPictureTimeoutSeconds: Double = 8

    /// The longest an audio switch waits for a Dolby Vision frame from the compositor before it rebuilds without
    /// one. The outgoing picture stays on screen, paused, for as long as the decode runs.
    static let heldPictureDolbyVisionBudgetSeconds: Double = 3

    /// AE#711 follow-up: hold the picture on screen across the rebuild of an audio switch.
    ///
    /// Native: #711 keeps the old item mounted while the source reopens, but `replaceCurrentItem`
    /// still drops the player layer to black until the next item decodes its first frame. The frame
    /// is read from the paused old item (about 20 ms paused; a playing one needs ~300 ms before a
    /// fresh output sees anything, which is why the caller pauses first). Dolby Vision without a
    /// displayable base layer (Profile 5, AV1 Profile 10) cannot be taken from that output, which
    /// vends the base layer; its frame is played out of the resident segment through the system
    /// compositor instead, which colours it as it colours playback.
    ///
    /// The picture is laid over the video until the next host reports one. Call before
    /// `stopInternal`.
    func holdPictureAcrossItemSwap() async {
        releaseHeldPicture(reason: nil)
        // A bound still view first: a host that binds one renders the native path through AVKit, and
        // its `AetherPlayerView`, if any, is not what is on screen.
        let surface: (any HeldStillSurface)? = boundStillView ?? boundView
        let nativeSource = nativeHost
        if let skip = surface == nil ? "no surface bound"
            : nativeSource == nil ? "no video host"
            : Self.heldPictureSkipReason(
                pictureInPictureActive: pictureInPictureActive,
                externalPlaybackActive: Self.externalPlaybackActive(nativeSource)) {
            heldPictureLastSkip = skip
            EngineLog.emit("[AetherEngine] held picture: skipped (\(skip))", category: .engine)
            return
        }
        guard let view = surface else { return }
        heldPictureLastSkip = nil
        let generation = loadGeneration
        let started = ContinuousClock.now

        if let host = nativeSource,
           Self.heldPictureNeedsCompositor(videoFormat: videoFormat, dolbyVisionProfile: sourceDVProfile) {
            await holdThroughCompositor(host: host, view: view, generation: generation, started: started)
            return
        }

        let held: (frame: CVPixelBuffer, isHDR: Bool, route: String)?
        if let host = nativeSource {
            held = await host.captureDisplayedFrame()
                .map { ($0, Self.heldPictureIsHDR(videoFormat), "native output") }
        } else {
            held = nil
        }
        guard let held else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] held picture: no frame from the outgoing picture", category: .engine)
            return
        }
        guard loadGeneration == generation, nativeHost === nativeSource,
              (boundStillView ?? boundView) === view else {
            heldPictureLastSkip = "superseded while the frame was read"
            EngineLog.emit("[AetherEngine] held picture: superseded while the frame was read", category: .engine)
            return
        }
        guard view.showStill(held.frame, gravity: videoGravity, isHDR: held.isHDR) else {
            heldPictureLastSkip = "frame could not be wrapped for display"
            EngineLog.emit("[AetherEngine] held picture: frame could not be wrapped for display", category: .engine)
            return
        }
        armHeldPicture(on: view, route: held.route, nativeSource: nativeSource)
        EngineLog.emit(
            "[AetherEngine] held picture: up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(\(held.route), \(CVPixelBufferGetWidth(held.frame))x\(CVPixelBufferGetHeight(held.frame)), "
            + "hdr=\(held.isHDR))",
            category: .engine)
    }

    /// Dolby Vision without a displayable base layer: the frame under
    /// the playhead, played out of the resident segment by a player of the surface's own, so the
    /// system compositor colours it as it colours playback. Waits at most
    /// `heldPictureDolbyVisionBudgetSeconds`, the outgoing picture paused meanwhile.
    private func holdThroughCompositor(host: NativeAVPlayerHost, view: any HeldStillSurface,
                                       generation: UInt64, started: ContinuousClock.Instant) async {
        let itemSeconds = host.avPlayer.currentTime().seconds
        guard let session = nativeVideoSession else { return }
        let built = await BlockingWork.detached(priority: .userInitiated) { [session] in
            session.compositorHoldFile(atSeconds: itemSeconds)
        }.value
        guard let hold = built else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] held picture: no resident segment for the compositor hold", category: .engine)
            return
        }
        let spent = Double((ContinuousClock.now - started).components.seconds)
            + Double((ContinuousClock.now - started).components.attoseconds) / 1e18
        let budget = max(0.2, Self.heldPictureDolbyVisionBudgetSeconds - spent)
        let shown = await view.showCompositorStill(file: hold.url, pastFirstFrameBy: hold.offsetSeconds,
                                                   gravity: videoGravity, budgetSeconds: budget)
        guard shown else {
            heldPictureLastSkip = "no frame from the outgoing picture"
            EngineLog.emit("[AetherEngine] held picture: the compositor hold did not become displayable", category: .engine)
            return
        }
        guard loadGeneration == generation, nativeHost === host, (boundStillView ?? boundView) === view else {
            view.clearStill()
            heldPictureLastSkip = "superseded while the frame was read"
            EngineLog.emit("[AetherEngine] held picture: superseded while the frame was read", category: .engine)
            return
        }
        armHeldPicture(on: view, route: "Dolby Vision compositor", nativeSource: host)
        EngineLog.emit(
            "[AetherEngine] held picture: up after \(Self.milliseconds(ContinuousClock.now - started))ms "
            + "(Dolby Vision compositor, item \(String(format: "%.3f", itemSeconds))s)",
            category: .engine)
    }

    /// Records the hold and arms its release: the next item's first frame, or `heldPictureTimeoutSeconds`.
    private func armHeldPicture(on view: any HeldStillSurface, route: String, nativeSource: NativeAVPlayerHost?) {
        heldPictureView = view
        heldPictureLastRoute = route
        heldPictureShownAt = .now
        heldPictureToken &+= 1
        let token = heldPictureToken
        if let host = nativeSource {
            let heldSession = host.sessionID
            heldPictureRelease = host.$isVideoReadyForDisplay
                .filter { [weak host] ready in ready && (host?.sessionID ?? heldSession) != heldSession }
                .first()
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.releaseHeldPicture(reason: "first frame of the next item") }
                }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.heldPictureTimeoutSeconds))
            guard let self, self.heldPictureToken == token, self.heldPictureView != nil else { return }
            self.releaseHeldPicture(reason: "timeout")
        }
    }

    /// visionOS has no external playback, and no `isExternalPlaybackActive` to ask.
    private static func externalPlaybackActive(_ host: NativeAVPlayerHost?) -> Bool {
        #if os(visionOS)
        return false
        #else
        return host?.avPlayer.isExternalPlaybackActive ?? false
        #endif
    }

    /// Dolby Vision whose base layer has no displayable colour of its own: Profile 5, and AV1
    /// Profile 10, whose compatibility id is not known here. Every other profile's base layer is HDR10,
    /// HLG or SDR and is held as the output vends it.
    nonisolated static func heldPictureNeedsCompositor(videoFormat: VideoFormat, dolbyVisionProfile: Int?) -> Bool {
        videoFormat == .dolbyVision && (dolbyVisionProfile == 5 || dolbyVisionProfile == 10)
    }

    nonisolated static func heldPictureIsHDR(_ format: VideoFormat) -> Bool {
        format != .sdr
    }

    /// Takes the held picture down. `reason` nil is a silent clear (nothing was up, or a new hold
    /// replaces it); every other release is logged with how long the picture stood.
    func releaseHeldPicture(reason: String?) {
        heldPictureRelease?.cancel()
        heldPictureRelease = nil
        guard let view = heldPictureView else { return }
        view.clearStill()
        heldPictureView = nil
        heldPictureLastRelease = reason
        if let reason, let shownAt = heldPictureShownAt {
            EngineLog.emit(
                "[AetherEngine] held picture: released after \(Self.milliseconds(ContinuousClock.now - shownAt))ms (\(reason))",
                category: .engine)
        }
        heldPictureShownAt = nil
    }

    /// Why no picture is held. PiP and external playback: the picture is not in this view.
    nonisolated static func heldPictureSkipReason(
        pictureInPictureActive: Bool, externalPlaybackActive: Bool
    ) -> String? {
        if pictureInPictureActive { return "picture in picture" }
        if externalPlaybackActive { return "external playback" }
        return nil
    }

    private nonisolated static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
