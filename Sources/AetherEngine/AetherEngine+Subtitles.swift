import Foundation
import AVFoundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil
import os

/// Which subtitle output path a reader / apply / cancel call targets.
/// `.primary` maps to the original single-track storage and behavior;
/// `.secondary` maps to the independent companion track (issue #47).
public enum SubtitleChannel: Sendable {
    case primary
    case secondary
}

extension AetherEngine {

    // MARK: - Channel routing


    func isSubtitleActive(for channel: SubtitleChannel) -> Bool {
        switch channel {
        case .primary:   return isSubtitleActive
        case .secondary: return isSecondarySubtitleActive
        }
    }

    /// Activate an embedded subtitle stream. #112 rework: the producer pump keeps every embedded
    /// subtitle stream and harvests its packets into the session's SubtitlePacketStore; a
    /// playhead-paced drainer decodes the selected stream into the overlay. No side demuxer,
    /// no second connection, selection is instant and rides seeks/restarts with the producer.
    /// Supports text codecs (SubRip / ASS / SSA / WebVTT / mov_text) and bitmap codecs (PGS / DVB /
    /// DVD). XSUB is classified as bitmap by the decoder too, but the shipped FFmpeg build compiles
    /// no xsub decoder, so such a track selects and then decodes to nothing; it is deliberately not
    /// claimed anywhere in the documentation.
    public func selectSubtitleTrack(index: Int) {
        forcedSubtitleSelection = false
        selectSubtitleTrackPublicly(index: index)
    }

    /// Show track `index` as FORCED subtitles: what plays when the viewer has chosen no subtitle, the lines
    /// a forced track carries, or only the lines a full track flags as forced. Everything else is
    /// `selectSubtitleTrack(index:)`: the track becomes the active one and feeds `subtitleCues` (a host
    /// drawing its own forced lines filters them by `SubtitleCue.isForced`). What differs is the native
    /// rendition while `setNativeSubtitleRendering(true)` holds: it is the track's forced one, declared
    /// `FORCED=YES` under `LoadOptions.forcedSubtitleTrack`, which AVKit leaves out of its menu, so the menu
    /// keeps saying Off. tvOS normally selects that rendition by itself; this is for a host that has to
    /// make the selection. Like any native pick it is filled before it is selected.
    /// `hasForcedSubtitleRendition(forTrack:)` says whether the track has one.
    public func selectForcedSubtitleTrack(index: Int) {
        forcedSubtitleSelection = true
        selectSubtitleTrackPublicly(index: index)
    }

    /// Whether track `index` has the session's forced native rendition (`LoadOptions.forcedSubtitleTrack`):
    /// its own, declared forced, or one made from its flagged lines. False for every other track.
    public func hasForcedSubtitleRendition(forTrack index: Int) -> Bool {
        guard let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: index, in: nativeSubtitleTrackTable,
                                                       forced: true) else { return false }
        return nativeSubtitleTrackTable[ordinal].declaresForced
    }

    /// Fill the session's forced rendition (`LoadOptions.forcedSubtitleTrack`): the player asked for it,
    /// which on tvOS it does by itself when the audio's language and the viewer's subtitle settings call
    /// for forced subtitles. A forced-only rendition is OCR'd from the packet store, which its demand on
    /// the subtitle source keeps ahead; a forced text track's own demand reads it ahead. A bitmap track the
    /// host has selected keeps the OCR worker: the forced rendition resumes when it is released
    /// (`resumeForcedRenditionFill`).
    func fillForcedRendition(ordinal: Int) {
        guard ordinal < nativeSubtitleTrackTable.count, nativeSubtitleTrackTable[ordinal].declaresForced,
              let store = nativeStore(atOrdinal: ordinal) else { return }
        forcedRenditionRequestedOrdinal = ordinal
        let entry = nativeSubtitleTrackTable[ordinal]
        if entry.needsOCR, let stream = entry.sourceStreamIndex {
            // Filled whole from the index at load (`fillIndexedForcedRenditions`), or being filled.
            guard !store.isFinished, indexedForcedFillTasks[ordinal] == nil else { return }
            if let armed = subtitleOCRArmedOrdinal {
                guard armed != ordinal else { return }
                EngineLog.emit("[AetherEngine] forced rendition ordinal=\(ordinal) requested; the OCR worker "
                               + "serves the selected ordinal=\(armed) until it is released", category: .engine)
                return
            }
            startSubtitleOCRWorker(ordinal: ordinal, streamIndex: Int32(stream))
        } else {
            demandNativeRenditionSubtitles(.forcedRendition, stores: [store])
        }
        EngineLog.emit("[AetherEngine] forced rendition ordinal=\(ordinal) requested by the player: filling "
                       + "(\(entry.needsOCR ? "OCR, forced lines only" : "its text"))", category: .engine)
    }

    /// After a selection change released the OCR worker, give it back to the forced rendition the player
    /// asked for, if any.
    func resumeForcedRenditionFill() {
        guard let ordinal = forcedRenditionRequestedOrdinal, subtitleOCRArmedOrdinal == nil else { return }
        fillForcedRendition(ordinal: ordinal)
    }

    private func selectSubtitleTrackPublicly(index: Int) {
        externalSubtitleIntentGeneration &+= 1
        hostExplicitSubtitleAction = true
        selectSubtitleTrack(index: index, startAt: sourceTime)
        // Sodalite#156: while the picture is off this device the RENDITION is the display, so a pick
        // has to reach it. Selecting a track alone never did: the rendition only ever moved through
        // the readers' re-anchor path, which is tied to coverage and not to the host's choice. That
        // went unnoticed because nothing deselected it either, so a pick made while one was already
        // standing looked like it had been followed. `setNativeSubtitleRendering` is the whole job,
        // mapping included, and it latches correctly if this lands mid-reload.
        if nativeSubtitleRenderingRequested {
            // Sodalite#156: which pick this was. A silent forced-subtitle fallback reaches here through
            // the same call as a viewer's own choice, and the two want different answers on a
            // receiver, so the line has to name them apart before anything acts on the difference.
            EngineLog.emit("[AetherEngine] #156 native rendition re-asserted for track \(index) "
                           + "(hostExplicit=\(hostExplicitSubtitleAction) forced=\(forcedSubtitleSelection))", category: .engine)
            setNativeSubtitleRendering(true)
        }
        // A pick that left the OCR worker free (a text track) hands it back to the forced rendition.
        resumeForcedRenditionFill()
    }

    /// `selectSubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the live
    /// `sourceTime`; the preferred-subtitle-language auto-select at load passes the resume position so the side
    /// demuxer seeks to the playhead instead of burst-reading from byte 0 on a resumed mid-file load (#73).
    /// On the native route a track with a rendition is selected in AVFoundation, and the selection decides who
    /// draws it (`AetherEngine+NativeSubtitleSelection`).
    func selectSubtitleTrack(index: Int, startAt: Double) {
        if selectNativeSubtitleOption(forTrack: index, startAt: startAt) { return }
        applySubtitleTrack(index: index, startAt: startAt)
    }

    /// The overlay's side of a selection: the track becomes the active one and feeds `subtitleCues`.
    func applySubtitleTrack(index: Int, startAt: Double) {
        // Phase D: every selection change disarms the OCR worker first; the embedded bitmap
        // branch below re-arms it (cursors persist, so a reselect resumes coverage).
        cancelSubtitleOCRWorker()
        // #316: an external track the remote-HLS proxy declared as a rendition is rendered by AVPlayer
        // itself, so it must NOT also start a sidecar decode; the overlay would draw the same cues a
        // second time, and only the rendition survives PiP / AirPlay / an external display.
        if let renditionName = injectedSubtitleRenditionNames[index] {
            selectInjectedSubtitleRendition(id: index, name: renditionName)
            return
        }
        // #88: external ids route onto the sidecar decode path; no side demuxer, no loadedURL needed.
        if let external = externalSubtitleRegistry[index] {
            selectExternalSubtitleTrack(id: index, track: external)
            return
        }
        // AE#154: remote-HLS bypass ids drive AVMediaSelection; AVPlayer renders the cues itself.
        if RemoteHLSMediaSelection.ordinal(forTrackID: index) != nil {
            selectRemoteHLSSubtitleTrack(id: index)
            return
        }
        // AE#359: a live SUBTITLES rendition carries no packets in this demuxer; its cues come from the
        // rendition's own WebVTT playlist, fetched only now that the host has actually asked for it.
        if Self.isLiveSubtitleRenditionTrackID(index) {
            selectLiveSubtitleRendition(id: index)
            return
        }
        guard index < Self.externalSubtitleTrackIDBase else { return }  // unknown external id: no-op
        guard loadedURL != nil else { return }

        // #77: in-band CEA-608/708 is fed by the always-on producer CC tap (set up at load), not a side
        // demuxer. Selecting it just makes it the active track and mirrors the tap's cue snapshot. Tear down
        // any running embedded reader first (no reuse: CC won't touch the side demuxer, so don't pin a remote
        // connection open while it plays).
        if let codec = subtitleTracks.first(where: { $0.id == index })?.codec,
           Self.isEmbeddedClosedCaptionCodec(codec) {
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary, reason: .closedCaptionsSelected)   // #112 rework: CC is tap-fed, not drained
            isSubtitleActive = true
            activeEmbeddedSubtitleStreamIndex = Int32(index)
            activeSubtitleTrackIndex = index
            isLoadingSubtitles = false
            subtitleCues = ccCueSnapshot
            return
        }

        // #112 rework: every embedded track (text and bitmap, VOD and live) is served by the
        // playhead-paced drainer from the session's packet store. The producer keeps all subtitle
        // streams from init, so selection needs no side demuxer, no positioning, and no recovery:
        // the immediate drainer tick backfills the window around the playhead (off the MainActor, AE#628).
        cancelSidecarTask()
        isSubtitleActive = true
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        activeEmbeddedSubtitleStreamIndex = Int32(index)
        activeSubtitleTrackIndex = index
        subtitleDrainTargets[.primary] = Int32(index)
        subtitleDrainDecoders[.primary] = nil
        subtitleDrainCursors[.primary] = nil
        // Phase D: a bitmap track additionally arms the OCR worker feeding its native rendition, which
        // states its own, longer demand on the subtitle source.
        if let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: index, in: nativeSubtitleTrackTable,
                                                    forced: forcedSubtitleSelection),
           nativeSubtitleTrackTable[ordinal].needsOCR {
            startSubtitleOCRWorker(ordinal: ordinal, streamIndex: Int32(index))
        }
        startSubtitleDrainer()
        demandOverlaySubtitles()   // #151
        isLoadingSubtitles = false
        EngineLog.emit(
            "[AetherEngine] overlay fed by packet-store drainer for stream=\(index) "
            + "(backfill requested)",
            category: .engine
        )
    }

    /// Apply `LoadOptions.preferredSubtitleLanguages` at the end of a successful load: activate the best-ranked
    /// subtitle track whose language matches a preference (scanned in order; see `selectSubtitleIndex`), else
    /// leave subtitles off (the default). Uses the host-overlay path (equivalent to a `selectSubtitleTrack`
    /// call); `startAnchor` is the
    /// load's resume position so a mid-file resume seeks the side demuxer to the playhead instead of byte 0.
    /// A no-op when the list is empty, no track matches, or the host already activated a subtitle. The resolved
    /// index is published via `activeSubtitleTrackIndex`. Independent of `prepareNativeSubtitles`. (#73)
    func applyPreferredSubtitleSelection(startAnchor: Double?, sourceDuration: Double?) {
        guard !loadedOptions.preferredSubtitleLanguages.isEmpty, !isSubtitleActive,
              !hostExplicitSubtitleAction else { return }
        guard let index = Self.selectSubtitleIndex(
            tracks: subtitleTracks,
            preferredLanguages: loadedOptions.preferredSubtitleLanguages
        ) else { return }
        EngineLog.emit(
            "[AetherEngine] preferred-subtitle auto-select stream=\(index) langs=\(loadedOptions.preferredSubtitleLanguages)",
            category: .engine
        )
        // Bound the anchor to the probe duration (synchronously known here; the published `duration` is set
        // asynchronously and is still 0 at this point). A stale resume > duration would otherwise seek the
        // side demuxer past EOF and the auto-selected subtitle would silently never appear. Unknown duration
        // (probe failure / live) leaves the anchor unclamped. Mirrors seek()'s clamp.
        var anchor = max(0, startAnchor ?? 0)
        if let duration = sourceDuration, duration > 0 { anchor = min(anchor, duration) }
        selectSubtitleTrack(index: Int(index), startAt: anchor > 0 ? anchor : sourceTime)
    }

    /// Activate an embedded subtitle stream as the secondary companion track (issue #47).
    /// Text and supported bitmap codecs use an independent decoder and cursor over the shared
    /// packet store. External ids (#88) route onto the secondary sidecar decode.
    public func selectSecondarySubtitleTrack(index: Int) {
        externalSubtitleIntentGeneration &+= 1
        selectSecondarySubtitleTrack(index: index, startAt: sourceTime)
    }

    /// `selectSecondarySubtitleTrack(index:)` with an explicit source-PTS start anchor. The public form passes the
    /// live `sourceTime`; the audio-switch reload passes the pre-stopInternal snapshot, because a sourceTime read
    /// mid-reload has collapsed to the playlist axis and would re-arm the side demuxer ~producer-shift seconds
    /// behind the playhead (#112, matching the primary `selectSubtitleTrack(index:startAt:)` split).
    func selectSecondarySubtitleTrack(index: Int, startAt: Double) {
        hostExplicitSubtitleAction = true
        if let external = externalSubtitleRegistry[index] {
            cancelSidecarTask(channel: .secondary)
            clearSubtitleDrainTarget(channel: .secondary, reason: .secondarySidecarSelected)   // #112 rework
            activeSecondaryEmbeddedSubtitleStreamIndex = -1
            activeSecondaryExternalSubtitleTrackID = index
            startSecondarySidecarDecode(url: external.url, httpHeaders: external.httpHeaders,
                                        sourceStreamIndex: external.sourceStreamIndex)
            return
        }
        guard index < Self.externalSubtitleTrackIDBase else { return }
        activeSecondaryExternalSubtitleTrackID = nil
        guard loadedURL != nil else { return }
        cancelSidecarTask(channel: .secondary)
        loadedSecondarySidecarURL = nil

        // #112 rework: secondary embedded tracks ride the same packet-store drainer on their
        // own channel; the immediate tick backfills it.
        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        secondarySidecarASSHeader = nil
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        activeSecondaryEmbeddedSubtitleStreamIndex = Int32(index)
        subtitleDrainTargets[.secondary] = Int32(index)
        subtitleDrainDecoders[.secondary] = nil
        subtitleDrainCursors[.secondary] = nil
        startSubtitleDrainer()
        demandOverlaySubtitles()   // #151
        isLoadingSecondarySubtitles = false
    }








    /// #112 full umbau: the bitmap (image) cues visible at `playhead` - those whose window covers it. An audio-track
    /// switch does not move the playhead, so the engine snapshots these before the pipeline reload and restores them
    /// after, keeping the on-screen PGS line up instead of tearing it down and reconstructing it from a back-scan.
    /// Image-only: text tracks re-decode from their index cheaply and need no preservation.
    nonisolated static func activeImageCues(in cues: [SubtitleCue], at playhead: Double) -> [SubtitleCue] {
        cues.filter { cue in
            guard case .image = cue.body else { return false }
            return cue.startTime <= playhead && playhead < cue.endTime
        }
    }


    // MARK: - #112 rework: playhead-paced overlay drainer

    /// The native item stated a landing (`armNativeItemObservers`): a seek of any origin, the engine's,
    /// AVKit's scrubbing, a PiP skip, a step of a reverse scan. Counted for the drain and the OCR worker,
    /// which reset on it once (`SubtitleRepositioning.signalled`), and held as their playhead until the
    /// picture reports a time of its own: `sourceTime` follows the presented frame (#49), which is still
    /// the old one while AVPlayer buffers towards the target (#123), so it cannot place the landing.
    func subtitleLanded(atItemSeconds itemSeconds: Double) {
        guard itemSeconds.isFinite else { return }
        subtitleLandingGeneration &+= 1
        subtitleLanding = SubtitleLanding(seconds: nativeSourceSeconds(atItemSeconds: itemSeconds),
                                          heldWhileSourceTimeIs: sourceTime)
        if !subtitleDrainTargets.isEmpty { requestSubtitleDrainTick() }
        scheduleNativeSubtitleReanchor()   // #93
    }

    /// Where the drain and the OCR worker stand: the latest landing until the picture reports a time of
    /// its own after it, then `sourceTime`.
    func subtitleDrainPlayhead() -> Double {
        if let landing = subtitleLanding {
            if sourceTime == landing.heldWhileSourceTimeIs { return landing.seconds }
            subtitleLanding = nil
        }
        return sourceTime
    }

    /// How the drain and the OCR worker learn of a landing: stated by the native item, inferred from the
    /// playhead's steps on the software route, which has no AVPlayer.
    func subtitleRepositioning(elapsedSinceLastPlan: Double) -> SubtitleRepositioning {
        nativeVideoSession != nil
            ? .signalled(generation: subtitleLandingGeneration)
            : .inferred(jumpThreshold: Self.subtitleDrainJumpThresholdSeconds,
                        elapsedSinceLastPlan: elapsedSinceLastPlan)
    }

    /// The active session's packet store: the HLS producer tap or the SW-host tap.
    /// nil when no session is loaded.
    var activeSubtitlePacketStore: SubtitlePacketStore? {
        nativeVideoSession?.subtitlePacketStore ?? softwareSubtitlePacketStore
    }

    /// Build a fresh overlay decoder for the stream on whichever host owns the session demuxer.
    func makeSubtitleDrainDecoder(streamIndex: Int32) -> EmbeddedSubtitleDecoder? {
        #if DEBUG
        if let factory = subtitleDrainDecoderFactoryForTesting { return factory(streamIndex) }
        #endif
        return nativeVideoSession?.makeOverlayDecoder(streamIndex: streamIndex)
            ?? softwareHost?.makeOverlayDecoder(streamIndex: streamIndex)
    }

    /// Start (or keep) the 500ms drain loop. Requests an immediate tick so a fresh selection
    /// backfills from the packet store without waiting out the first interval (#32 tap-overlay UX).
    func startSubtitleDrainer() {
        requestSubtitleDrainTick()
        guard subtitleDrainerTask == nil else { return }
        subtitleDrainerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: AetherEngine.subtitleDrainTickNanoseconds)
                guard let self, !Task.isCancelled else { return }
                self.requestSubtitleDrainTick()
            }
        }
    }

    /// AE#628: the drain loop's tick. Plans on the MainActor, decodes the batch off it, and applies
    /// the result back on it. A bitmap decode expands a full-canvas indexed plane per display set,
    /// and a selection or seek backfills a whole window of them at once; on the MainActor that was
    /// the top frame of the report's profile. A tick asked for while one is in flight is queued,
    /// not run beside it: the decoders are not reentrant.
    func requestSubtitleDrainTick() {
        guard subtitleDrainTickInFlight == nil else {
            subtitleDrainTickRequested = true
            return
        }
        guard let work = prepareSubtitleDrainTick() else { return }
        let handoff = work.decodeHandoff
        guard !handoff.isEmpty else {
            finishSubtitleDrainTick(work, events: handoff.decode())
            return
        }
        subtitleDrainTickSerial &+= 1
        let serial = subtitleDrainTickSerial
        subtitleDrainTickInFlight = Task { [weak self] in
            let events = await BlockingWork.detached(priority: .userInitiated) { handoff.decode() }.value
            guard let self, self.subtitleDrainTickSerial == serial else { return }
            self.subtitleDrainTickInFlight = nil
            self.finishSubtitleDrainTick(work, events: events)
            if self.subtitleDrainTickRequested {
                self.subtitleDrainTickRequested = false
                self.requestSubtitleDrainTick()
            }
        }
    }

    func stopSubtitleDrainer(reason: SubtitleDrainStopReason) {
        subtitleDrainerTask?.cancel()
        subtitleDrainerTask = nil
        subtitleDrainTickInFlight = nil   // AE#628: its batch lands on a stale serial and is dropped
        subtitleDrainTickRequested = false
        subtitleDrainTickSerial &+= 1
        subtitleDrainDecoders.removeAll()
        subtitleDrainCursors.removeAll()
        subtitleDrainLastTickUptime = nil   // #271
        subtitleResolutionLastFrontier.removeAll()   // #250
        subtitleResolutionCoverageStated.removeAll()   // #318
        subtitleDeliveryLastOutcome.removeAll()   // #357
        withdrawOverlaySubtitles(reason: reason)   // #151
    }

    /// Clear one channel's drain target; stops the loop when no channel remains active.
    func clearSubtitleDrainTarget(channel: SubtitleChannel, reason: SubtitleDrainStopReason) {
        subtitleDrainTargets[channel] = nil
        subtitleDrainDecoders[channel] = nil
        subtitleDrainCursors[channel] = nil
        subtitleResolutionLastFrontier[channel] = nil   // #250
        subtitleResolutionCoverageStated.remove(channel)   // #318
        subtitleDeliveryLastOutcome[channel] = nil   // #357
        refreshSubtitleStoreProtection()   // #166
        if subtitleDrainTargets.isEmpty {
            stopSubtitleDrainer(reason: reason)
        } else {
            demandOverlaySubtitles()   // the remaining channel's stream only
        }
    }

    /// #166: keep the store's aggregate-eviction protected set in sync with the active drain
    /// targets, so the coldest non-selected streams evict first and the window the drainer reads
    /// is never dropped. Called on every drain-target change and re-asserted each drain tick.
    func refreshSubtitleStoreProtection() {
        activeSubtitlePacketStore?.setProtectedStreams(Set(subtitleDrainTargets.values))
    }

    /// The synchronous tick: plan, decode and apply in one go on the MainActor. Kept for the
    /// teletext page change and for tests; the drain loop goes through `requestSubtitleDrainTick`,
    /// which decodes off the MainActor (AE#628). Queued rather than run while that one is in flight.
    func subtitleDrainTick() {
        guard subtitleDrainTickInFlight == nil else {
            subtitleDrainTickRequested = true
            return
        }
        guard let work = prepareSubtitleDrainTick() else { return }
        finishSubtitleDrainTick(work, events: work.decodeHandoff.decode())
    }

    /// AE#628: the MainActor half before the decode. Plans every channel, states the ticks that
    /// decode nothing (idle, no decoder), and hands back what the decode needs.
    func prepareSubtitleDrainTick() -> SubtitleDrainTickWork? {
        guard !subtitleDrainTargets.isEmpty, let store = activeSubtitlePacketStore else { return nil }
        store.setProtectedStreams(Set(subtitleDrainTargets.values))   // #166: re-assert protection
        let playhead = subtitleDrainPlayhead()
        // #416: the pump is rendering the frame at the playhead, so it has necessarily read from
        // wherever it opened up to here. That is what the pump can state without a hook in its read
        // loop, and it is exactly the stretch a landing claim rests on: the ground between a set
        // decoded behind the playhead and the playhead itself. Its lookahead beyond the playhead
        // comes from the packets it harvests, which the store notes as it takes them. The presented
        // frame's time, not a landing the picture has not reached: only the frame proves the reading.
        store.noteHarvestReach(through: sourceTime)
        // #271: wall time since the previous tick, so a tick that itself ran long cannot be read as
        // a seek by the next one. See SubtitleOverlayDrainer.drainPlan.
        let tickUptime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let elapsed = subtitleDrainLastTickUptime.map { tickUptime - $0 } ?? 0
        subtitleDrainLastTickUptime = tickUptime
        var work = SubtitleDrainTickWork(store: store, playhead: playhead,
                                         landingGeneration: subtitleLandingGeneration)
        let upscale = bitmapSubtitleUpscaleRequest(playhead: playhead)
        // In the background the GPU is refused, so nothing is upscaled; what decodes there is owed.
        work.upscale = isBackgrounded ? nil : upscale
        for (channel, streamIndex) in subtitleDrainTargets {
            let plan = SubtitleOverlayDrainer.drainPlan(
                cursor: subtitleDrainCursors[channel],
                playhead: playhead,
                lead: Self.subtitleDrainLeadSeconds,
                backscan: Self.subtitleDrainBackscanSeconds,
                repositioning: subtitleRepositioning(elapsedSinceLastPlan: elapsed),
                relanding: bitmapSubtitleRelanding.remove(channel) != nil)
            let window: (from: Double, through: Double)
            // #250: a reset starts a fresh contiguous decoded run; a steady tick extends the one
            // already running.
            var coverageStart = subtitleDrainCursors[channel]?.coverageStart
            // #276: the run retained across seeks. Folded here, banked after the decode.
            var retained = subtitleDrainCursors[channel]?.retained
            let isReset: Bool
            switch plan {
            case .idle:
                subtitleDrainCursors[channel]?.lastPlayhead = playhead
                // #276: an idle tick decoded nothing, so it banks nothing into the retained run.
                // The frontier may well have moved under it; folding that in would claim
                // determination the drainer never performed.
                emitSubtitleResolutionStatementIfTransitioned(channel: channel,
                                                              streamIndex: streamIndex,
                                                              playhead: playhead)
                continue
            case .decode(let from, let through):
                isReset = false
                window = (from, through)
            case .resetAndDecode(let from, let through):
                isReset = true
                coverageStart = from
                retained = SubtitleResolutionStatement.fold(retained, windowFrom: from)
                subtitleDrainDecoders[channel] = nil
                // Fresh selection or seek: the backscan decodes compositions BEHIND the
                // playhead. Run them through the gate's reconstruction admission so the
                // currently-active line is emitted once at the playhead instead of being
                // held as a stale arrival until the next composition trims it (the old
                // reader's lead-in behavior; without this, enabling subs mid-sentence
                // shows nothing until the next line).
                // #357: the gate's hold and candidate belong to the position this tick is leaving.
                // A held cue keeps its open-ended placeholder end, so the first post-seek trim
                // (`resolveHeld`) closes it at a successor start AHEAD of the new playhead and
                // republishes pre-seek history as the active line, the same defect the store-side
                // close below prevents. Nothing is lost by dropping it: the backscan re-decodes the
                // window from the packet store, so anything that can still claim this landing comes
                // back through `admitDuringReconstruction`.
                var gate = pgsStaleArrivalGates[channel] ?? PGSStaleArrivalGate()
                gate.reset()
                gate.reconstructing = true
                pgsStaleArrivalGates[channel] = gate
                window = (from, through)
            }
            if subtitleDrainDecoders[channel] == nil {
                subtitleDrainDecoders[channel] = makeSubtitleDrainDecoder(streamIndex: streamIndex)
            }
            guard let decoder = subtitleDrainDecoders[channel] else {
                // #357: a channel holding a drain target whose decoder cannot be built delivers
                // nothing for the rest of the session, and the tick used to skip it in silence.
                var tally = SubtitleDeliveryStatement.Tally()
                tally.decoderMissing = true
                emitSubtitleDeliveryStatementIfTransitioned(
                    channel: channel, streamIndex: streamIndex, playhead: playhead,
                    tally: tally, isReset: isReset)
                continue
            }
            // Layer 3 step 3: an indexed stream pulls the window and decodes what the pulls have brought,
            // so a stretch not yet pulled waits for its pull instead of reading as silence.
            let pulls = subtitleStreamIsPulled(streamIndex)
            var decodableThrough = window.through
            if pulls {
                subtitleSource?.pull(streamIndex, from: window.from, through: window.through, focus: playhead)
                decodableThrough = min(window.through,
                                       store.pulledReach(streamIndex: streamIndex, from: window.from) ?? -.infinity)
            }
            let entries = decodableThrough >= window.from
                ? store.entries(streamIndex: streamIndex, from: window.from, through: decodableThrough) : []
            // #271: bound the batch, on a PTS boundary. The window is bounded in seconds of
            // content, so on a dense track it is thousands of packets and this loop has no
            // suspension point.
            let batchEnd = SubtitleOverlayDrainer.batchEnd(
                count: entries.count,
                cap: Self.subtitleDrainMaxPacketsPerTick,
                ptsAt: { entries[$0].ptsSeconds })
            // #362: stop at a hole the harvest is still filling instead of decoding across it and
            // moving the cursor to its far side, which is how a stretch of the film loses its
            // subtitles entirely: after a seek the pump refills from behind the landing while an
            // island the previous run harvested sits further ahead, and the cursor never comes back.
            // The hold is anchored on the near side and budgeted in ticks, so a boundary the harvest
            // never closes costs a bounded delay and then decodes exactly as before.
            var decodeEnd = batchEnd
            var gapHoldAt: Double? = nil
            var gapHoldSequence: UInt64 = 0
            var gapHoldTicksLeft = 0
            let held = subtitleDrainCursors[channel]
            // The playhead catching up to the hold ends it whatever the budget says: from there on
            // the island is what the viewer is about to need, and waiting would dark the overlay
            // for content that IS stored. That, not the tick budget, is the real bound.
            // A pulled span has no holes; the hold is the pump's.
            if !pulls, let heldAt = held?.harvestGapAt, heldAt >= playhead,
               (held?.harvestGapTicksLeft ?? 0) > 0, !isReset,
               !SubtitleOverlayDrainer.harvestGapHoldResumes(
                firstSequence: entries.first?.sequence,
                heldSequence: held?.harvestGapSequence ?? 0) {
                // Still waiting: the window past the hold begins with the same island as before.
                decodeEnd = 0
                gapHoldAt = heldAt
                gapHoldSequence = held?.harvestGapSequence ?? 0
                gapHoldTicksLeft = (held?.harvestGapTicksLeft ?? 0) - 1
            } else if !pulls, let cut = SubtitleOverlayDrainer.harvestGapCut(
                count: batchEnd,
                ptsAt: { entries[$0].ptsSeconds },
                sequenceAt: { entries[$0].sequence },
                resumeFrom: isReset ? nil : held.map { ($0.lastDecodedPts, $0.lastDecodedSequence) },
                notBefore: playhead), held?.harvestGapAt != cut.at || (held?.harvestGapTicksLeft ?? 0) > 0 {
                decodeEnd = cut.index
                gapHoldAt = cut.at
                gapHoldSequence = cut.sequence
                gapHoldTicksLeft = held?.harvestGapAt == cut.at
                    ? (held?.harvestGapTicksLeft ?? 0) - 1 : Self.subtitleDrainHarvestGapTicks
            }
            // An upscaling landing decodes to just past the playhead: the tick publishes only once its cues are
            // upscaled, so the landing line waits for one upscale rather than the whole lead's. The rest follows
            // in the next ticks, the first asked for at once.
            var landingCut = false
            if isReset, work.upscale != nil,
               let cut = entries[..<decodeEnd].firstIndex(where: { $0.ptsSeconds > playhead + Self.subtitleUpscaleLandingSeconds }) {
                decodeEnd = cut
                landingCut = true
            }
            if upscale != nil, work.upscale == nil, decodeEnd > 0, EmbeddedSubtitleDecoder.isBitmapCodec(decoder.codecID) {
                bitmapSubtitleUpscaleOwed.insert(channel)
            }
            work.channels.append(SubtitleDrainChannelWork(
                channel: channel, streamIndex: streamIndex, plan: plan, isReset: isReset,
                window: window, coverageStart: coverageStart, retained: retained,
                decoder: decoder, entries: entries, batchEnd: batchEnd, decodeEnd: decodeEnd,
                gapHoldAt: gapHoldAt, gapHoldSequence: gapHoldSequence,
                gapHoldTicksLeft: gapHoldTicksLeft, pulled: pulls, landingCut: landingCut))
        }
        return work
    }

    /// AE#628: the MainActor half after the decode. `events` holds one decoded result per packet
    /// the prepare half handed out, channel by channel. A channel re-selected, cleared or rebuilt
    /// while its batch decoded is skipped: its cursor did not move, so the next tick redoes it.
    func finishSubtitleDrainTick(_ work: SubtitleDrainTickWork,
                                 events decodedByChannel: [[EmbeddedSubtitleDecoder.SubtitleEvent?]]) {
        let store = work.store
        let playhead = work.playhead
        if work.upscale != nil, BitmapSubtitleUpscaling.shared.takeFailures() {
            bitmapSubtitleUpscaleOwed.formUnion(work.channels.map(\.channel))
        }
        guard activeSubtitlePacketStore === store else { return }
        for (job, events) in zip(work.channels, decodedByChannel) {
            let channel = job.channel
            let streamIndex = job.streamIndex
            guard subtitleDrainTargets[channel] == streamIndex,
                  subtitleDrainDecoders[channel] === job.decoder else { continue }
            let plan = job.plan
            let isReset = job.isReset
            let window = job.window
            let coverageStart = job.coverageStart
            let retained = job.retained
            let entries = job.entries
            let batchEnd = job.batchEnd
            let decodeEnd = job.decodeEnd
            let gapHoldAt = job.gapHoldAt
            let gapHoldSequence = job.gapHoldSequence
            let gapHoldTicksLeft = job.gapHoldTicksLeft
            // #271: bind the channel's cue array ONCE for the whole batch. `subtitleCues` is
            // `@Published`, whose wrapper exposes get/set and no `_modify`, so passing it inout per
            // event both copy-on-writes the array and publishes it: every consumer then walks a
            // cumulative snapshot once per decoded packet, O(n) each, for a batch that added a
            // handful of cues. One bind, one publish, and only when the batch changed something.
            var cues = retainedSubtitleCues(for: channel)
            var didMutate = false
            // #357: a cue still carrying its open-ended placeholder end cannot claim this landing.
            // Its successor's trim is what closes it, and a jump past it outran that successor; see
            // alignCueEnds.
            if isReset, Self.closeOpenEndedCues(&cues, startingBefore: window.from) {
                didMutate = true
            }
            // #357: what this tick did, counted as it happens. The cursor below advances over every
            // packet whether or not the decoder built anything from it, so without these counts a
            // window of undecodable packets is indistinguishable in the log from a window that
            // delivered normally.
            var tally = SubtitleDeliveryStatement.Tally()
            tally.packets = decodeEnd
            // The cursor only advances to an actually-decoded packet's PTS: a window that is
            // empty because the producer has not reached it yet must be rescanned next tick.
            var lastDecoded = subtitleDrainCursors[channel]?.lastDecodedPts
            // #362: the cursor's own harvest sequence rides with it, so the next tick can tell
            // whether its first entry was read by the same run or is the far side of a hole.
            var lastDecodedSequence = subtitleDrainCursors[channel]?.lastDecodedSequence ?? 0
            for (entry, decoded) in zip(entries[..<decodeEnd], events) {
                if let event = decoded {
                    tally.events += 1
                    tally.cues += event.cues.count
                    // A cue-less event still matters: a PGS clear composition carries only
                    // pgsTrimAt and is what removes the line during silence.
                    if !event.cues.isEmpty || event.pgsTrimAt != nil {
                        let applied = applySubtitleEvent(event, to: &cues, channel: channel, playhead: playhead,
                                                         groundIsPulled: job.pulled)
                        tally.admitted += applied.admitted
                        tally.published += applied.published
                        tally.landingWithheld += applied.landingWithheld   // #416
                        if applied.changed { didMutate = true }
                    }
                }
                lastDecoded = entry.ptsSeconds
                lastDecodedSequence = entry.sequence
            }
            if case .resetAndDecode = plan, batchEnd == 0 {
                // Fresh window with nothing stored yet: anchor just behind the window start so
                // steady ticks rescan it without re-triggering the discontinuity path.
                lastDecoded = window.from
                lastDecodedSequence = 0
            }
            // #276: floor now, ceiling after the statement below states it.
            let runRetained = retained ?? .init(from: coverageStart ?? window.from, through: nil)
            subtitleDrainCursors[channel] = SubtitleDrainCursor(
                lastDecodedPts: lastDecoded ?? window.from,
                lastDecodedSequence: lastDecoded == nil ? 0 : lastDecodedSequence,
                lastPlayhead: playhead,
                coverageStart: coverageStart ?? window.from,
                retained: runRetained,
                harvestGapAt: gapHoldAt,
                harvestGapSequence: gapHoldSequence,
                harvestGapTicksLeft: gapHoldTicksLeft,
                landingGeneration: work.landingGeneration)
            // #143/#204: a renderable composition at/after the playhead ends reconstruction while
            // decoding above. If the pass remains active with a candidate after the whole window,
            // finalize it. Raw packet presence cannot answer this: the landing line's own zero-object
            // CLEAR is stored ahead and trims the candidate, but carries no cues that can end the pass.
            //
            // #271: "after the whole window" is now literal. A capped batch leaves the rest of the
            // window undecoded, and its successor composition may sit in the remainder, so the pass
            // carries into the next tick instead of finalizing on a partial view.
            // #362: a hole hold is not a partial view of the landing. Holes are honoured only at or
            // after the playhead, so everything that can seed the candidate has decoded, and the
            // remainder sits beyond a gap the harvest has not closed. Waiting for that would keep
            // the overlay dark for the whole hold budget, which is the one thing #143 exists to
            // prevent; the successor trims the published line when the hole does fill.
            // An upscaling landing's cut is past the playhead too, so it is no partial view either.
            if job.landingCut { subtitleDrainTickRequested = true }
            if decodeEnd == entries.count || gapHoldAt != nil || job.landingCut,
               SubtitleOverlayDrainer.shouldFinalizeReconstruction(
                reconstructing: pgsStaleArrivalGates[channel]?.reconstructing ?? false,
                hasCandidate: pgsStaleArrivalGates[channel]?.hasReconstructionCandidate ?? false) {
                // The candidate is the genuinely active line at the seek target, so it bypasses
                // `admit`, whose steady-state stale check would re-hold a landing line sitting more
                // than the epsilon behind the playhead and re-dark the overlay this fix exists to light.
                for cue in pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
                    .finalizeReconstruction(playhead: playhead) {
                    // #357: a finalized candidate is a delivery like any other, and counting it as
                    // one is what keeps a landing that published only through this path from
                    // reading as `held`.
                    tally.admitted += 1
                    if insertSorted(cue, into: &cues) {
                        didMutate = true
                        tally.published += 1
                    }
                }
            }
            tally.reconstructing = pgsStaleArrivalGates[channel]?.reconstructing ?? false
            tally.harvestGapAt = gapHoldAt
            // #362: every bitmap cue takes its end from the next packet the store holds on this
            // stream. Run over the whole retained array rather than this batch's cues: a set left
            // open by an earlier tick (its successor not harvested yet, the batch cap, the window's
            // forward edge) is closed by the first tick that finds the answer stored, without waiting
            // for the drain window to reach it. Runs before the boundary close can launder it and
            // before the publish below, so the host never sees the placeholder at all.
            // Round 2: this is also the only correction an end derived across a hole ever gets. The
            // drain cursor moves forward only, so the packets that fill the hole land BEHIND it and
            // are never decoded; their `pgsTrimAt` never runs, and the too-late end stood until the
            // session ended. Re-deriving from the store each tick needs no decode and no revisit.
            // Round 2: and it may look exactly as far as the harvest is designed to lead, no
            // further. The pump reads a margin PAST the drain window precisely so the set at
            // the window's forward edge has its own clear stored (round 1), so inside that horizon
            // a stored packet is evidence the harvest was here and found this. Beyond it the store
            // holds whatever earlier runs left behind, and the first thing after a set can be the
            // far side of a stretch nobody read: a real packet, not this set's successor (report:
            // 145.187 closed at 223.306, its own clear at 150.192, 18 s past the window's edge).
            // Refusing there costs a tick or two of an open cue, which the next answer closes,
            // against an end that is wrong by a minute and that nothing downstream can tell from an
            // authored one.
            let derivationHorizon = window.through + Self.subtitleReadAheadMarginSeconds
            if Self.alignCueEnds(&cues, toNextPacket: {
                // An indexed set ends where the index places the stream's next frame: known, not inferred.
                if job.pulled { return self.subtitleSource?.nextFrameSeconds(streamIndex, after: $0) }
                guard let pts = store.firstPTS(streamIndex: streamIndex, after: $0) else { return nil }
                guard pts <= derivationHorizon else {
                    tally.endsWithheld += 1
                    return nil
                }
                return pts
            }) {
                didMutate = true
            }
            // Retention prune, once per batch instead of once per event: it depends only on the
            // playhead, which the batch does not move.
            if isSubtitleActive(for: channel),
               Self.pruneCues(&cues, before: playhead - subtitleCueRetentionSeconds) {
                didMutate = true
            }
            if didMutate { publishRetainedSubtitleCues(cues, for: channel) }
            // #357: state what the tick did before the resolution line states how far it reached.
            // The two answer different questions and a report needs both: determination can keep
            // pace with every landing while delivery is empty, and that pairing is the whole
            // ambiguity this line removes.
            emitSubtitleDeliveryStatementIfTransitioned(
                channel: channel, streamIndex: streamIndex, playhead: playhead,
                tally: tally, isReset: isReset)
            // #250: the post-seek window has decoded, so state how far determination reaches.
            // #276: one statement value per decoding tick, built whether or not it is printed. Its
            // `resolvedThrough` is this run's determined end under the fence that is live RIGHT
            // NOW, and banking it here is the only place it can be had: by the next reset tick the
            // seek generation has moved on and the outgoing run's frontier no longer passes its
            // own fence.
            var statement = subtitleResolutionStatement(
                channel: channel, streamIndex: streamIndex,
                reason: isReset ? .reconstruction : .frontier, playhead: playhead)
            subtitleDrainCursors[channel]?.retained = SubtitleResolutionStatement.extend(
                runRetained, with: statement.resolvedThrough)
            // #318: a reset starts a fresh run, and whether THAT run reaches the playhead is a
            // fresh question. Cleared before the decision below so a reconstruction line that
            // already states coverage can latch it again on the way out.
            if isReset { subtitleResolutionCoverageStated.remove(channel) }
            if let reason = SubtitleResolutionStatement.transitionReason(
                statement, playhead: playhead, isReset: isReset,
                coverageStated: subtitleResolutionCoverageStated.contains(channel),
                lastFrontier: subtitleResolutionLastFrontier[channel]) {
                statement.reason = reason
                emitSubtitleResolutionStatement(statement, channel: channel, playhead: playhead)
            }
        }
        // #125: the packet store is NOT time-pruned here. A trailing playhead-relative prune
        // (was: playhead - retentionSeconds) evicted packets a backward seek could still land on:
        // a backward jump into segment-cache-resident content is served without a producer restart,
        // and the pump (the store's only writer) stays parked forward, so that region is never
        // re-harvested. Once pruned, the drain window landed permanently empty and cues starved
        // (every re-arm logged "backfilled 0 cues"). Retention is byte-bounded instead, via
        // SubtitlePacketStore.perStreamByteCap (evict-oldest per stream): text tracks keep the whole
        // session, bitmap tracks keep a wide trailing window. Mirrors the segment cache retaining
        // history for backward seeks rather than clamping to a time window ahead of the playhead.
    }

    // MARK: - The session's subtitle source

    /// #151: the overlay's packets are read ahead for VOD sessions only (live content past the edge does
    /// not exist and the pump already rides it), and only for an embedded drain target (external/sidecar
    /// tracks hold whole files, CC is tap-fed) on a loaded source.
    nonisolated static func shouldReadOverlaySubtitlesAhead(
        isLive: Bool, hasEmbeddedDrainTargets: Bool, hasSource: Bool
    ) -> Bool {
        !isLive && hasEmbeddedDrainTargets && hasSource
    }

    /// The session's one subtitle reader (`SubtitleSource`), built once the session's packet store, cue
    /// stores and demuxer exist. Nothing is read until a consumer asks, except the text renditions the
    /// container's index lists in full, which are filled whole at once.
    func startSubtitleSource() {
        subtitleSource?.close()
        subtitleSource = nil
        guard let url = loadedURL, let packetStore = activeSubtitlePacketStore else { return }
        if isCustomSource, customReader == nil { return }
        var cueStores: [Int32: NativeSubtitleCueStore] = [:]
        let stores = nativeVideoSession?.nativeSubtitleCueStoresForSession ?? []
        for (ordinal, entry) in nativeSubtitleTrackTable.enumerated() where ordinal < stores.count {
            guard let stream = entry.sourceStreamIndex, !entry.needsOCR, entry.externalID == nil else { continue }
            cueStores[Int32(stream)] = stores[ordinal]
        }
        var customReader: (@MainActor @Sendable () -> IOReader?)?
        if isCustomSource {
            customReader = { @MainActor [weak self] in self?.customReader?.makeIndependentReader() }
        }
        subtitleSource = SubtitleSource(host: .init(
            url: url, headers: loadedOptions.httpHeaders, headerStore: sessionRequestHeaders,
            customReader: customReader, discTitleID: activeDiscTitleID, isLive: isLive,
            packetStore: packetStore, cueStores: cueStores,
            demuxer: nativeVideoSession?.demuxer ?? softwareHost?.subtitleSourceDemuxer,
            makeDecoder: { [weak self] in self?.makeSubtitleDrainDecoder(streamIndex: $0) },
            duration: { [weak self] in self?.duration ?? 0 },
            cuesArrived: { [weak self] in self?.nativeSubtitleRenditionAvailable = true },
            stopped: { [weak self] reason in
                // #496: the stop says why, so a field capture tells a track switch from a teardown.
                if let reason { self?.lastSubtitleDrainStopReason = reason }
                EngineLog.emit("[SubtitleSource] the pump's read-ahead lapsed "
                               + "(reason=\(reason?.rawValue ?? "no consumer left"))", category: .engine)
            },
            routesSettled: { [weak self] routes in self?.subtitleRoutesSettled(routes) },
            pulled: { [weak self] stream in self?.subtitleStreamPulled(stream) }),
            leads: subtitleReadAheadLeads)
    }

    /// The source's routes are in. The pump's decode tap leaves the indexed text streams, whose renditions
    /// the index fills whole, and a drain waiting on the routes runs.
    func subtitleRoutesSettled(_ routes: [Int32: SubtitleSource.Route]) {
        let indexed = Set(routes.compactMap { stream, route -> Int32? in
            if case .indexed = route { return stream }
            return nil
        })
        nativeVideoSession?.excludeFromSubtitleTap(indexed)
        if !subtitleDrainTargets.isEmpty { requestSubtitleDrainTick() }
    }

    /// A pull of `stream` landed: a channel draining it decodes what it brought.
    func subtitleStreamPulled(_ stream: Int32) {
        if subtitleDrainTargets.values.contains(stream) { requestSubtitleDrainTick() }
    }

    /// Whether `stream` is read from the index on request, so the store holds what was pulled and nothing
    /// else: no harvest holes, ends from the index, ground read by construction.
    func subtitleStreamIsPulled(_ stream: Int32) -> Bool {
        if case .indexed = subtitleSource?.route(of: stream) { return true }
        return false
    }

    /// The overlay drainer's demand on the pump, for the drain targets it harvests: its window plus a margin
    /// (#362: the set at the window's forward edge has its own clear stored and can be closed where the
    /// author closed it). An indexed target is pulled by the drain tick instead.
    func demandOverlaySubtitles() {
        guard Self.shouldReadOverlaySubtitlesAhead(
            isLive: isLive, hasEmbeddedDrainTargets: !subtitleDrainTargets.isEmpty, hasSource: loadedURL != nil)
        else { return }
        let lead = Self.subtitleDrainLeadSeconds + Self.subtitleReadAheadMarginSeconds
        subtitleSource?.demand(.overlay, streams: Set(subtitleDrainTargets.values), lead: { _ in lead })
    }

    /// The overlay no longer drains. Another consumer still asking keeps the reading, and then nothing
    /// is claimed (#496).
    func withdrawOverlaySubtitles(reason: SubtitleDrainStopReason) {
        subtitleSource?.withdraw(.overlay, reason: reason)
    }

    /// A native text rendition's demand: the renditions' read-ahead, or further when the player asks the
    /// rendition for windows beyond it (AVKit reads one about four minutes ahead).
    func demandNativeRenditionSubtitles(_ consumer: SubtitleSource.Consumer, stores: [NativeSubtitleCueStore]) {
        let streams = Set(nativeSubtitleTrackTable.indices.compactMap { ordinal -> Int32? in
            guard let store = nativeStore(atOrdinal: ordinal), stores.contains(where: { $0 === store }),
                  let stream = nativeSubtitleTrackTable[ordinal].sourceStreamIndex else { return nil }
            return Int32(stream)
        })
        subtitleSource?.demand(consumer, streams: streams, lead: { playhead in
            Self.subtitleReadAhead(base: Self.nativeSubtitleReadAheadSeconds, playhead: playhead,
                                   requested: stores.compactMap { $0.furthestRequestedSourceSeconds() }.max())
        })
    }

    /// The text stores the native renditions read, in table order.
    var nativeTextRenditionStores: [NativeSubtitleCueStore] {
        nativeSubtitleTrackTable.indices.compactMap { ordinal in
            let entry = nativeSubtitleTrackTable[ordinal]
            guard entry.sourceStreamIndex != nil, !entry.needsOCR, entry.externalID == nil else { return nil }
            return nativeStore(atOrdinal: ordinal)
        }
    }

    /// Rebuild an AVPacket from a stored entry and decode it. PTS/duration ride a 1/1000
    /// time base carrying the harvested seconds; flags are restored for bitmap acquisition
    /// points. Runs on the MainActor tick; subtitle decode is a parse plus, for bitmap, a
    /// bounded blit.
    nonisolated static func decodeStoredSubtitlePacket(
        _ entry: StoredSubtitlePacket,
        with decoder: EmbeddedSubtitleDecoder
    ) -> EmbeddedSubtitleDecoder.SubtitleEvent? {
        let size = entry.payload.count
        guard size > 0, let pkt = av_packet_alloc() else { return nil }
        defer {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        guard av_new_packet(pkt, Int32(size)) >= 0 else { return nil }
        entry.payload.withUnsafeBytes { raw in
            if let base = raw.baseAddress, let dst = pkt.pointee.data {
                memcpy(dst, base, size)
            }
        }
        // Audit FEA-101: the store bounds these, but an entry is a plain value and the conversion traps.
        pkt.pointee.pts = SourceTimestampBounds.roundedTicks(entry.ptsSeconds * 1000) ?? Int64.min
        pkt.pointee.dts = pkt.pointee.pts
        pkt.pointee.duration = max(0, SourceTimestampBounds.roundedTicks(entry.durationSeconds * 1000) ?? 0)
        pkt.pointee.flags = entry.flags
        // #233: WebVTT placement lives in side data, not in the payload, so it has to be put back.
        if let settings = entry.webvttSettings {
            WebVTTCueSettings.attach(settings: settings, to: pkt)
        }
        return decoder.decode(packet: pkt, streamTimeBase: AVRational(num: 1, den: 1000))
    }

    /// #271: the channel's retained array, bound once per drain tick. Reading it here and writing it
    /// back once at the end of the batch is what keeps `$subtitleCues` to one publication per tick.
    private func retainedSubtitleCues(for channel: SubtitleChannel) -> [SubtitleCue] {
        switch channel {
        case .primary:   return subtitleCues
        case .secondary: return secondarySubtitleCues
        }
    }

    private func publishRetainedSubtitleCues(_ cues: [SubtitleCue], for channel: SubtitleChannel) {
        switch channel {
        case .primary:   subtitleCues = cues
        case .secondary: secondarySubtitleCues = cues
        }
    }

    /// Returns what the event did to the array (#357). An event that decodes but resolves to nothing
    /// new (a re-decoded cue the store already holds, a trim matching no open window) must not cost a
    /// publication: on a dense track that is the common case, and each publication makes every
    /// consumer walk the whole cumulative snapshot (#271).
    @discardableResult
    private func applySubtitleEvent(_ event: EmbeddedSubtitleDecoder.SubtitleEvent,
                                    to cues: inout [SubtitleCue],
                                    channel: SubtitleChannel,
                                    playhead: Double,
                                    groundIsPulled: Bool) -> SubtitleDeliveryStatement.Application {
        guard isSubtitleActive(for: channel) else { return .init() }

        // #357: primary-only, and budgeted per seek generation rather than per load, so a seek
        // sequence stays observable to its end. The playhead is `sourceTime`, the axis cue
        // timestamps are on; `currentTime` rides beside it because their difference is the playlist
        // shift, and reading the two as one clock has cost a round of diagnosis before.
        if channel == .primary, let firstCue = event.cues.first,
           subtitleCueDiagnosticBudget.claim(generation: currentSeekGeneration) {
            // #407: a PGS composition carries no end of its own, so the decoder stamps it with
            // `end_display_time = UINT32_MAX` and the successor's `pgsTrimAt` closes it. Printed
            // raw, that placeholder reads as a 49.7-day cue and has already been reported as an
            // unsigned-32-bit overflow. Name it for what it is.
            let openEnded = firstCue.endTime - firstCue.startTime >= Self.subtitleOpenEndedWindowSeconds
            EngineLog.emit(
                "[applySubtitleEvent] " +
                "cueStart=\(String(format: "%.3f", firstCue.startTime))s " +
                "cueEnd=\(openEnded ? "open-ended (closed by the successor)" : String(format: "%.3fs", firstCue.endTime)) " +
                "sourceTime=\(String(format: "%.3f", sourceTime))s " +
                "engine.currentTime=\(String(format: "%.3f", currentTime))s " +
                "seekGen=\(currentSeekGeneration)",
                category: .engine
            )
        }

        return applyEventMutations(event, to: &cues, channel: channel, playhead: playhead,
                                   groundIsPulled: groundIsPulled)
    }

    /// PGS clear-event trim + sorted insert. Native mov_text stores (#55) are NOT fed here; those are owned by the multi-decode reader.
    /// #271: retention pruning moved to the drain tick (once per batch, not once per event) and the
    /// return value reports whether `cues` actually changed.
    @MainActor
    @discardableResult
    private func applyEventMutations(_ event: EmbeddedSubtitleDecoder.SubtitleEvent, to cues: inout [SubtitleCue],
                                     channel: SubtitleChannel, playhead: Double,
                                     groundIsPulled: Bool) -> SubtitleDeliveryStatement.Application {
        var applied = SubtitleDeliveryStatement.Application()
        if let trimAt = event.pgsTrimAt {
            for i in 0..<cues.count {
                guard case .image = cues[i].body else { continue }
                let cue = cues[i]
                if cue.startTime < trimAt && cue.endTime > trimAt {
                    cues[i] = cue.with(endTime: trimAt)
                    applied.changed = true
                }
            }
            // #100: this event is the held stale arrival's successor; its start closes the held
            // cue's true window. Publish it only if that window covers the playhead (it is the
            // genuinely active cue), drop replayed history silently.
            for cue in pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
                .resolveHeld(trimAt: trimAt, playhead: playhead) {
                applied.admitted += 1
                if insertSorted(cue, into: &cues) {
                    applied.changed = true
                    applied.published += 1
                }
            }
        }
        // #107: teletext page-state semantics; every event (content or erase) closes earlier
        // open text cues at its start, since libzvbi emits pages open-ended ("until replaced").
        if let trimAt = event.textTrimAt, Self.trimTextCues(&cues, at: trimAt) {
            applied.changed = true
        }
        // #100: a PGS event whose cues start well behind the playhead is a catch-up replay; its
        // open-ended placeholder window would cover the playhead the instant it inserts and flash
        // stale history through the overlay until the successor trims it. Hold it instead.
        // #112/#143: during a reconstruction pass any decoded composition at/behind the playhead becomes the
        // held active-line candidate, emitted once when the decode reaches the playhead (see
        // PGSStaleArrivalGate.admitDuringReconstruction).
        // #416: a bitmap set decoded behind the playhead claims to be the line still on screen
        // there, and that claim rests on the store being empty between the two. Ask the harvest
        // whether it ever read that stretch before reading its silence as an answer.
        // Asked for bitmap events only: a text cue carries its own duration, so it claims nothing
        // about the ground behind it, and a dense text track would pay the lookup per packet.
        // A pulled stream's store holds every frame of what was pulled, so its silence is an answer.
        let groundIsRead = event.isPGS && !groundIsPulled
            ? subtitleLandingGroundIsRead(cues: event.cues, playhead: playhead)
            : true
        // A false answer here means an actual refusal: the helper returns true when the event
        // carries no cue behind the playhead, so there is nothing that could have been refused.
        if !groundIsRead { applied.landingWithheld += 1 }
        let admitted = pgsStaleArrivalGates[channel, default: PGSStaleArrivalGate()]
            .admit(cues: event.cues, isPGS: event.isPGS,
                   isSelfContained: event.isSelfContainedPGS, playhead: playhead,
                   groundIsRead: groundIsRead)
        applied.admitted += admitted.count
        for cue in admitted {
            if insertSorted(cue, into: &cues) {
                applied.changed = true
                applied.published += 1
            }
        }
        return applied
    }


    @MainActor
    @discardableResult
    private func insertSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) -> Bool {
        Self.insertCueSorted(cue, into: &cues, nextID: &nextRetainedSubtitleCueID)
    }

    /// #416: was the source between the newest of these cues that lies behind `playhead` and the
    /// playhead itself actually read by some harvest run?
    ///
    /// Only that one cue matters: it is the one the gate would make the landing's active line, and
    /// the only stretch its claim depends on is the one between it and the playhead. Cues at or
    /// after the playhead need no ground, and an event carrying none behind it asks nothing here.
    ///
    /// Coverage is a property of the SOURCE, not of a stream: a reader demuxes every stream it
    /// passes over, so a span one of them read is read for all of them.
    private func subtitleLandingGroundIsRead(cues: [SubtitleCue], playhead: Double) -> Bool {
        guard let store = activeSubtitlePacketStore else { return true }
        guard let newestBehind = cues.lazy.map(\.startTime).filter({ $0 <= playhead }).max()
        else { return true }
        return store.hasReadSpan(from: newestBehind, through: playhead)
    }

    /// #107: close every non-image cue (text or rich text) whose window covers `trimAt` (teletext
    /// page-state semantics: each page transmission or erase replaces what came before it). Image
    /// cues are untouched; they have their own PGS trim. Static and pure for unit tests.
    /// Returns whether any cue was actually closed (#271).
    @discardableResult
    nonisolated static func trimTextCues(_ cues: inout [SubtitleCue], at trimAt: Double) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            if case .image = cues[i].body { continue }
            let cue = cues[i]
            if cue.startTime < trimAt && cue.endTime > trimAt {
                cues[i] = cue.with(endTime: trimAt)
                changed = true
            }
        }
        return changed
    }

    /// #112 full umbau: sorted insert of a decoded cue into the retained store, keeping ascending start order. An
    /// image cue sharing a start AND geometry with an existing image cue REPLACES it: a PGS composition has a
    /// unique start PTS, so a same-start same-geometry image cue is the same object re-decoded (the audio-switch
    /// preserved placeholder vs its reconstruction), and a duplicate would render the bitmap twice until the next
    /// composition trims it. #146: the start PTS is unique per COMPOSITION, not per composition OBJECT; N objects
    /// of one display set (forced sign + dialogue) legitimately share a start and differ in geometry (the position,
    /// the alpha-bounding-box crop's rect on the canvas, deterministic across re-decodes), so geometry is part of
    /// the replacement key and sibling objects are all kept. The bitmap's pixel size is not: the position fixes the
    /// source's, and an upscaled copy (`bitmapSubtitlePixelSize`) differs from its decoded self in pixels alone.
    /// Text cues at the same start are distinct simultaneous speakers and are both kept.
    ///
    /// #121: `nextID` stamps every materialized cue with a session-monotonic id and de-dupes a non-image cue
    /// (text or rich text) already present with the same window + content. On a seek the overlay decoder is
    /// rebuilt (`.resetAndDecode`) with an empty `seenKeys` and a `nextCueID` reset to zero, so its backscan
    /// re-decodes cues still retained here; without a store-level guard the cues accumulate (report: 4 -> 7 -> 11)
    /// and the reset ids collide with retained ids (`ForEach(id:)` "occurs multiple times"). The retained store
    /// is the session-wide source of truth, so the invariant lives here, not on the ephemeral decoder.
    ///
    /// #271: both same-start lookups below run over the equal-start RUN found by binary search, not
    /// over the whole array. The store is kept sorted by startTime by the insert at the bottom, and
    /// both keys require an exact startTime match, so the run is the only place a match can live. On
    /// a dense typeset track the retained array is thousands of cues and every decoded packet used
    /// to walk all of them. Returns whether a cue was actually inserted or replaced.
    @discardableResult
    nonisolated static func insertCueSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue], nextID: inout Int) -> Bool {
        // Index range, deliberately not an ArraySlice: a live slice keeps a second reference to the
        // array's buffer, so the insert below would copy-on-write the whole store on every call.
        let lower = lowerBoundByStartTime(cue.startTime, in: cues)
        var upper = lower
        while upper < cues.count, cues[upper].startTime == cue.startTime { upper += 1 }

        // A non-image cue already present with the same start and flattened text is a re-decode of a retained
        // line, not a new one. `cue.text` flattens both `.text` and `.richText` (#107 coloured teletext pages)
        // and is nil for `.image`, so image cues correctly skip this guard and use their own same-start replace
        // below. Content (not id) is compared: two simultaneous speakers differ in text and both survive; a
        // genuine repeat at a new time has a different start and is inserted. endTime is deliberately NOT part
        // of the key: a retained teletext cue may have been trimmed by its successor (#107) while the re-decode
        // emits the original open-ended window; the retained (trimmed) cue stays authoritative. Deduped cues
        // consume no id.
        if let text = cue.text {
            for i in lower..<upper where cues[i].text == text { return false }
        }

        let stamped = cue.with(id: nextID)
        nextID += 1

        if case .image(let stampedImage) = stamped.body {
            for i in lower..<upper {
                guard case .image(let otherImage) = cues[i].body else { continue }
                if otherImage.position == stampedImage.position {
                    cues[i] = stamped
                    return true
                }
            }
        }
        cues.insert(stamped, at: lower)
        return true
    }

    /// First index of the start-sorted retained array whose cue starts at or after `startTime`.
    /// Also the insert position for a cue with that start: a new cue goes in front of the cues
    /// already sharing it, which is where the pre-#271 linear insert put it too.
    nonisolated static func lowerBoundByStartTime(_ startTime: Double, in cues: [SubtitleCue]) -> Int {
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].startTime < startTime { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Legacy 2-arg entry that preserves the caller's cue id (test / utility use). The engine path uses the `nextID`
    /// overload so ids stay session-monotonic across decoder rebuilds (#121).
    @discardableResult
    nonisolated static func insertCueSorted(_ cue: SubtitleCue, into cues: inout [SubtitleCue]) -> Bool {
        var id = cue.id
        return insertCueSorted(cue, into: &cues, nextID: &id)
    }

    /// #357: close every cue still carrying its open-ended placeholder window that began before
    /// `boundary`, at `boundary`. Called on a reset tick, where `boundary` is the start of the
    /// window the reconstruction is about to decode (playhead minus backscan).
    ///
    /// Two mechanisms bound an open PGS cue in steady state and neither one survives a seek past it.
    /// The trim needs a SUCCESSOR (`applySubtitleEvent`, `pgsTrimAt`), which after a jump arrives
    /// only when the new landing point's first composition does, seconds or tens of seconds later.
    /// `pruneCues` filters on `endTime`, and a placeholder end is by construction never older than
    /// the retention window, however far the playhead moved. So the pre-seek cue stays in the
    /// published window with a window that covers the new playhead, and every host that asks which
    /// cue is active renders it (report: a cue from 2549.8 s shown at 2855.15 s for 24.5 s).
    ///
    /// The reconstruction window is the right boundary because it is the one the engine already
    /// defines as how far it looks back at a landing: nothing before it is re-decoded, so nothing
    /// before it can be confirmed as still open. Cues stay in the retained store for a backward
    /// seek, only their unconfirmed end is retired. An authored duration is untouched, which is what
    /// separates this from a blanket "drop the pre-seek set": a long ASS sign keeps its own end.
    /// Returns whether any cue was closed.
    ///
    /// #362: this is the LAST resort, not the first. `alignCueEnds(_:toNextPacket:)` closes an
    /// open set at the packet the author put there; only a set with no stored successor at all
    /// reaches this boundary, and its end is then owned by the seek rather than by the author.
    @discardableResult
    nonisolated static func closeOpenEndedCues(_ cues: inout [SubtitleCue],
                                               startingBefore boundary: Double) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            let cue = cues[i]
            guard cue.startTime < boundary, cue.endTime > boundary,
                  cue.endTime - cue.startTime > subtitleOpenEndedWindowSeconds else { continue }
            cues[i] = cue.with(endTime: boundary)
            changed = true
        }
        return changed
    }

    /// #362: close every cue still carrying the placeholder window at the PTS of the next packet
    /// stored on its stream, which for a bitmap set is its authored end (its own clear composition,
    /// or the successor that replaces it, whichever the author put there first).
    ///
    /// The drain decodes a window bounded at `playhead + lead`, and that forward edge falls wherever
    /// it falls. When it lands between a set and the clear a few seconds later, the set publishes
    /// open, the cursor moves on, and nothing goes back for the clear: the next reset starts at a new
    /// landing, so the set is closed by whatever composition turns up next, tens or hundreds of
    /// seconds away (report: 3.55 s authored, 76.7 s delivered, and 817 s in the same session).
    ///
    /// The answer was already in the store. The pump harvests packets far ahead of the drain window,
    /// so the clear is retained at the moment the set publishes and no decode is needed to read its
    /// PTS: the successor's own `pgsTrimAt` would set exactly this end when the window eventually
    /// reaches it. Where the store has nothing after the set (the harvest frontier, a cut file) the
    /// cue stays open, because there is no authored answer there and the alternatives are all
    /// laundered ends. Returns whether any cue was changed.
    ///
    /// #362 round 2: for a bitmap set this holds whether or not the cue still carries the
    /// placeholder, and gating it on that was the defect. A burst leaves the store holding an island
    /// an earlier run harvested, so the first packet after a set can be the far side of a stretch
    /// nobody has read: a real packet, but not this set's successor (report: 75.117 closed at
    /// 144.978, its own clear at 78.579). Publishing it is still right, because the true successor
    /// can only be NEARER, so the answer is an upper bound and the alternative is a placeholder that
    /// renders until something else closes it. Keeping it was not: the clear that lands a second
    /// later, whose entire job is to trim that set, found a cue no longer eligible. A bitmap set has
    /// no end of its own, so every stored packet after it is a bound on its end and taking the
    /// nearest is monotone, it can only ever shorten. That is what makes the bound self-correcting
    /// rather than merely bounded, which is what the first round claimed and did not deliver.
    ///
    /// The rule stays PGS-shaped on purpose. A text event carries its own duration and a packet
    /// following it says nothing about it, so text cues keep the placeholder gate: only an
    /// unconfirmed end is anyone else's to set.
    @discardableResult
    nonisolated static func alignCueEnds(_ cues: inout [SubtitleCue],
                                         toNextPacket nextPacketPTS: (Double) -> Double?) -> Bool {
        var changed = false
        for i in 0..<cues.count {
            let cue = cues[i]
            var isBitmap = false
            if case .image = cue.body { isBitmap = true }
            guard isBitmap || cue.endTime - cue.startTime > subtitleOpenEndedWindowSeconds,
                  let end = nextPacketPTS(cue.startTime),
                  end > cue.startTime, end < cue.endTime else { continue }
            cues[i] = cue.with(endTime: end)
            changed = true
        }
        return changed
    }

    /// Prune cues whose `endTime` is older than the retention window. The caller passes
    /// `sourceTime - subtitleCueRetentionSeconds` because cue.startTime/endTime are absolute source
    /// PTS seconds (see EmbeddedSubtitleDecoder.decode). Returns whether anything was dropped (#271).
    nonisolated static func pruneCues(_ cues: inout [SubtitleCue], before cutoff: Double) -> Bool {
        guard !cues.isEmpty, cutoff > 0 else { return false }
        let before = cues.count
        cues.removeAll { $0.endTime < cutoff }
        return cues.count != before
    }


    // MARK: - External subtitle tracks (#88)

    /// Implicit media headers belong only to the media's exact HTTP origin. Explicit
    /// sidecar headers (including an empty dictionary) are the host's own decision.
    nonisolated static func resolvedSubtitleHeaders(
        for url: URL, explicit: [String: String]?, mediaURL: URL?,
        mediaHeaders: [String: String]
    ) -> [String: String] {
        if let explicit { return explicit }
        guard let mediaURL, let scheme = mediaURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.scheme?.lowercased() == scheme,
              RedirectHeaderPolicy.credentialsAllowed(from: mediaURL, to: url)
        else { return [:] }
        return mediaHeaders
    }

    /// Register an external subtitle file as a first-class track (AetherEngine#88): it appears in
    /// `subtitleTracks` with a synthetic id and `isExternal == true` and is selectable via
    /// `selectSubtitleTrack(index:)`. Overlay-only (no native WebVTT rendition / PiP); declare via
    /// `LoadOptions.externalSubtitles` for rendition eligibility. If `preferredSubtitleLanguages`
    /// is set, nothing is active, and the host made no explicit choice yet, the preference re-runs
    /// so a late-added matching track auto-activates.
    @discardableResult
    public func addExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let info = registerExternalSubtitleTrack(track)
        applyPreferredSubtitleSelection(startAnchor: sourceTime,
                                        sourceDuration: duration > 0 ? duration : nil)
        return info
    }

    /// #88: seat the load-declared external tracks in `subtitleTracks`. On the probe path this runs
    /// BEFORE preferred-language selection and the native rendition table are built from the list.
    ///
    /// #170: a session-preserving reload seeds the previous session's registry verbatim instead:
    /// mid-session adds survive with their ids (and, registered pre-table, become rendition-eligible on
    /// the reloaded item); mid-session removals stay removed; the host's subtitle authority carries over
    /// so the load-end auto-selection cannot override it.
    ///
    /// #316: the nativeRemoteHLS bypass and the AE#154 reroute return long before the probe path reaches
    /// this point, so both call it themselves. Without that a host declaring sidecars on a remote-HLS
    /// source got nothing back and no diagnostic: the option was read, then dropped at the branch.
    func registerDeclaredExternalSubtitles(_ options: LoadOptions) {
        if let carryover = options.subtitleSessionCarryover {
            applySubtitleSessionCarryoverRegistrations(carryover)
        } else {
            for track in options.externalSubtitles { registerExternalSubtitleTrack(track) }
        }
    }

    /// Registration without the preference re-run; the load path runs its own selection at load end.
    @discardableResult
    func registerExternalSubtitleTrack(_ track: ExternalSubtitleTrack) -> TrackInfo {
        let id = Self.externalSubtitleTrackIDBase + nextExternalSubtitleOrdinal
        nextExternalSubtitleOrdinal += 1
        externalSubtitleRegistry[id] = track
        let info = track.makeTrackInfo(id: id, fallbackNumber: nextExternalSubtitleOrdinal)
        subtitleTracks.append(info)
        return info
    }

    /// #88: activate a registered external track. A finished native store holds the whole file's
    /// cues (decoded plain-text at load), so the overlay backfills instantly with no re-download.
    /// Styled ASS wants raw markup, which the store strips, so it re-decodes via the sidecar path.
    private func selectExternalSubtitleTrack(id: Int, track: ExternalSubtitleTrack) {
        let codec = ExternalSubtitleTrack.codecName(url: track.url, formatHint: track.formatHint)
        let wantsStyledASS = loadedOptions.preserveASSMarkup && codec == "ass"
        if !wantsStyledASS,
           let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
           // Phase D: an OCR store holds recognized TEXT; the bitmap overlay must re-decode
           // the sidecar for its images, never backfill from that store.
           !nativeSubtitleTrackTable[ordinal].needsOCR,
           let store = nativeStore(atOrdinal: ordinal),
           store.isFinished, store.cueCount > 0 {
            cancelSidecarTask()
            clearSubtitleDrainTarget(channel: .primary, reason: .externalStoreBackfill)   // #112 rework
            activeEmbeddedSubtitleStreamIndex = -1
            loadedSidecarURL = track.url
            sidecarASSHeader = nil
            isSubtitleActive = true
            activeSubtitleTrackIndex = id
            subtitleCues = store.snapshotCues()
            isLoadingSubtitles = false
            EngineLog.emit("[AetherEngine] external subtitle backfilled from finished store: id=\(id) cues=\(subtitleCues.count)", category: .engine)
            return
        }
        startSidecarDecode(url: track.url, httpHeaders: track.httpHeaders, externalTrackID: id,
                           sourceStreamIndex: track.sourceStreamIndex)
    }

    /// Store lookup for the external backfill: test-hook override first, else the live session's stores.
    func nativeStore(atOrdinal ordinal: Int) -> NativeSubtitleCueStore? {
        #if DEBUG
        if let hooked = testHookNativeStores, ordinal < hooked.count { return hooked[ordinal] }
        #endif
        guard let stores = nativeVideoSession?.nativeSubtitleCueStoresForSession,
              ordinal < stores.count else { return nil }
        return stores[ordinal]
    }

    /// #88: fill the native stores of load-declared external tracks with one whole-file decode each
    /// (plain text, matching the WebVTT rendition), then markFinished so the .vtt handler can serve
    /// complete files and the overlay select can backfill instantly. No side demuxer, no pacing.
    func startExternalNativeStoreFill(session: HLSVideoEngine) {
        externalNativeStoreFillTask?.cancel()
        externalNativeStoreFillTask = nil
        let jobs = Self.externalSubtitleFillJobs(
            table: nativeSubtitleTrackTable,
            registry: externalSubtitleRegistry,
            stores: session.nativeSubtitleCueStoresForSession,
            defaultHeaders: loadedOptions.httpHeaders, mediaURL: loadedURL)
        guard !jobs.isEmpty else { return }
        externalNativeStoreFillTask = BlockingWork.detached(priority: .utility) { [jobs] in
            for job in jobs {
                if Task.isCancelled { return }
                await AetherEngine.runExternalSubtitleFill(job: job)
            }
        }
    }

    /// #266: fill one container's stores from a single decode pass. A pass covering several streams
    /// fails as a whole (an out-of-range index throws), so on failure the targets are retried
    /// individually: one host-side index mistake must not blank the container's other tracks. A
    /// store that could not be filled stays UNfinished, or the rendition would serve a complete but
    /// blank .vtt.
    nonisolated static func runExternalSubtitleFill(job: ExternalSubtitleFillJob) async {
        if let results = try? await SubtitleDecoder.decodeFile(
            url: job.url, httpHeaders: job.headers,
            sourceStreamIndices: job.targets.map(\.streamIndex)
        ) {
            for (target, result) in zip(job.targets, results) {
                target.store.appendCues(result.cues)
                target.store.markFinished()
            }
            return
        }
        guard job.targets.count > 1 else {
            EngineLog.emit("[AetherEngine] external native store fill failed: \(job.url.lastPathComponent)", category: .engine)
            return
        }
        EngineLog.emit("[AetherEngine] external native store fill: shared pass over \(job.url.lastPathComponent) failed, retrying \(job.targets.count) targets individually", category: .engine)
        for target in job.targets {
            if Task.isCancelled { return }
            guard let result = try? await SubtitleDecoder.decodeFile(
                url: job.url, httpHeaders: job.headers, sourceStreamIndex: target.streamIndex
            ) else {
                EngineLog.emit("[AetherEngine] external native store fill failed: \(job.url.lastPathComponent) stream=\(target.streamIndex.map(String.init) ?? "auto")", category: .engine)
                continue
            }
            target.store.appendCues(result.cues)
            target.store.markFinished()
        }
    }

    /// Unregister an external track: delist + drop the registry entry; an active selection
    /// (primary or secondary) is cleared. Embedded ids no-op.
    public func removeExternalSubtitleTrack(id: Int) {
        externalSubtitleIntentGeneration &+= 1
        guard externalSubtitleRegistry.removeValue(forKey: id) != nil else { return }
        subtitleTracks.removeAll { $0.id == id }
        if activeSubtitleTrackIndex == id { clearSubtitle() }
        if activeSecondaryExternalSubtitleTrackID == id { clearSecondarySubtitle() }
    }

    /// Fetch and decode a sidecar subtitle file (.srt / .ass / .vtt / .ssa) via `SubtitleDecoder.decodeFile`, replacing `subtitleCues` atomically. `httpHeaders` nil inherits `LoadOptions.httpHeaders` only for the same HTTP scheme, host and effective port as the media; cross-origin sidecars need explicit headers. Prefer registering via `addExternalSubtitleTrack` + `selectSubtitleTrack` (#88), which keeps the track listed and `activeSubtitleTrackIndex` populated; this API stays for compatibility and one-shot use.
    public func selectSidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        externalSubtitleIntentGeneration &+= 1
        hostExplicitSubtitleAction = true
        startSidecarDecode(url: url, httpHeaders: httpHeaders, externalTrackID: nil)
    }

    /// Shared sidecar-decode start: the pre-#88 selectSidecarSubtitle body, parameterized on which
    /// track id (if any) to publish as active. Also clears the pump-tap overlay stream so a prior
    /// tap-fed selection stops forwarding into the sidecar's cues (latent pre-#88 bug: the tap
    /// forward-guard matched the stale index and kept appending).
    func startSidecarDecode(url: URL, httpHeaders: [String: String]?, externalTrackID: Int?,
                            sourceStreamIndex: Int32? = nil) {
        cancelSidecarTask()
        // #496: say what is taking over before it takes over. A sidecar replacing a running
        // embedded selection ends the drainer and its subtitle reading with it, and until this line the
        // takeover itself logged nothing at all: a decode that starts and never publishes left the
        // session with no drain target, no cues and no trace of who emptied it.
        EngineLog.emit(
            "[AetherEngine] sidecar decode start: id=\(externalTrackID.map(String.init) ?? "-") "
            + "stream=\(sourceStreamIndex.map(String.init) ?? "auto") "
            + "replacing embedded stream=\(activeEmbeddedSubtitleStreamIndex)",
            category: .engine)
        // Sidecar replaces any active embedded stream.
        clearSubtitleDrainTarget(channel: .primary, reason: .sidecarSelected)   // #112 rework
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = externalTrackID

        loadedSidecarURL = url
        isSubtitleActive = true
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        sidecarASSHeader = nil
        isLoadingSubtitles = true

        let effectiveHeaders = Self.resolvedSubtitleHeaders(
            for: url, explicit: httpHeaders, mediaURL: loadedURL,
            mediaHeaders: loadedOptions.httpHeaders)
        // ASS/SSA sidecars honour preserveASSMarkup so hosts can drive a styled renderer. SRT/VTT fall back to plain text regardless.
        let preparationPolicy = externalTrackID.flatMap { externalSubtitleRegistry[$0] }?.preparationPolicy
        let preserveASS = loadedOptions.preserveASSMarkup
        sidecarTask = Task { [weak self] in
            let result: SidecarDecodeResult
            do {
                result = try await SubtitleDecoder.decodeFile(
                    url: url, httpHeaders: effectiveHeaders,
                    preserveASSMarkup: preserveASS,
                    sourceStreamIndex: sourceStreamIndex, preparationPolicy: preparationPolicy
                )
            } catch {
                EngineLog.emit("[AetherEngine] sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    // Stale-task guard: A->B switch; isSubtitleActive alone doesn't catch it (true again for B by the time A's error lands).
                    guard !Task.isCancelled, let self = self else { return }
                    if self.isSubtitleActive { self.isLoadingSubtitles = false }
                }
                return
            }

            await MainActor.run {
                // Stale-task guard: superseded load A must not overwrite B's cues (isSubtitleActive is true again for B).
                guard !Task.isCancelled, let self = self else { return }
                guard self.isSubtitleActive else { return }
                // Sidecar cues are in source PTS; host renders against engine.sourceTime (which folds playlistShiftSeconds).
                self.subtitleCues = result.cues
                self.sidecarASSHeader = result.assHeader
                self.isLoadingSubtitles = false
                // #496: the counterpart to the drainer's "overlay fed by packet-store drainer"
                // line. Without it a whole-file publish is invisible, and a static `subCues` in
                // the memprobe reads as a drainer that stopped filling rather than as a complete
                // track that needs no filling.
                EngineLog.emit(
                    "[AetherEngine] overlay fed by sidecar decode: id="
                    + "\(externalTrackID.map(String.init) ?? "-") "
                    + "stream=\(sourceStreamIndex.map(String.init) ?? "auto") "
                    + "(\(result.cues.count) cues)",
                    category: .engine)
                // Native mov_text moov is declared at load; runtime sidecars drive only the host overlay (#55).
                // Phase D: an external bitmap sidecar fills its OCR rendition store from THIS
                // decode's image cues (no second download).
                self.startSidecarOCRFillIfNeeded(externalTrackID: externalTrackID, cues: result.cues)
            }
        }
    }

    /// Decode a sidecar as the secondary companion track (issue #47), independent of the primary.
    public func selectSecondarySidecarSubtitle(url: URL, httpHeaders: [String: String]? = nil) {
        externalSubtitleIntentGeneration &+= 1
        hostExplicitSubtitleAction = true
        cancelSidecarTask(channel: .secondary)
        clearSubtitleDrainTarget(channel: .secondary, reason: .secondarySidecarSelected)   // #112 rework
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        activeSecondaryExternalSubtitleTrackID = nil
        startSecondarySidecarDecode(url: url, httpHeaders: httpHeaders)
    }

    /// Audio rebuilds keep the registry. Restore through its id so headers and a container's
    /// selected subtitle stream survive; the URL-only route is only for one-shot sidecars.
    func restoreSecondarySubtitleAfterRebuild(externalID: Int?, sidecarURL: URL?,
                                              embeddedIndex: Int32, startAt: Double) {
        if let sidecarURL {
            if let externalID, externalSubtitleRegistry[externalID] != nil {
                selectSecondarySubtitleTrack(index: externalID, startAt: startAt)
            } else {
                selectSecondarySidecarSubtitle(url: sidecarURL)
            }
        } else if embeddedIndex >= 0 {
            selectSecondarySubtitleTrack(index: Int(embeddedIndex), startAt: startAt)
        }
    }

    /// Shared secondary sidecar-decode start (#88): the pre-#88 selectSecondarySidecarSubtitle body.
    func startSecondarySidecarDecode(url: URL, httpHeaders: [String: String]?,
                                     sourceStreamIndex: Int32? = nil) {
        loadedSecondarySidecarURL = url
        isSecondarySubtitleActive = true
        secondarySubtitleCues = []
        secondarySidecarASSHeader = nil
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        isLoadingSecondarySubtitles = true

        let effectiveHeaders = Self.resolvedSubtitleHeaders(
            for: url, explicit: httpHeaders, mediaURL: loadedURL,
            mediaHeaders: loadedOptions.httpHeaders)
        let preserveASS = loadedOptions.preserveASSMarkup
        let sessionGeneration = loadGeneration
        let preparationPolicy = activeSecondaryExternalSubtitleTrackID.flatMap { externalSubtitleRegistry[$0] }?.preparationPolicy
        secondarySidecarTask = Task { [weak self] in
            let result: SidecarDecodeResult
            do {
                result = try await SubtitleDecoder.decodeFile(
                    url: url, httpHeaders: effectiveHeaders, preserveASSMarkup: preserveASS,
                    sourceStreamIndex: sourceStreamIndex, preparationPolicy: preparationPolicy)
            } catch {
                EngineLog.emit("[AetherEngine] secondary sidecar decode failed: \(error)", category: .engine)
                await MainActor.run {
                    guard !Task.isCancelled, let self = self,
                          self.loadGeneration == sessionGeneration else { return }
                    if self.isSecondarySubtitleActive { self.isLoadingSecondarySubtitles = false }
                }
                return
            }
            await MainActor.run {
                guard !Task.isCancelled, let self = self,
                          self.loadGeneration == sessionGeneration else { return }
                guard self.isSecondarySubtitleActive else { return }
                self.secondarySidecarASSHeader = result.assHeader
                self.secondarySubtitleCues = result.cues
                self.isLoadingSecondarySubtitles = false
            }
        }
    }

    /// Disable primary subtitles, clear cues, cancel sidecar task + side demuxer, cancel multi-decode reader, clear native mov_text stores (#55, all-tracks). `nativeSubtitleTracks` is NOT cleared: the host needs the list to re-select after an audio/subtitle switch; only `stop()` / `load()` reset it.
    public func clearSubtitle() {
        externalSubtitleIntentGeneration &+= 1
        hostExplicitSubtitleAction = true
        forcedSubtitleSelection = false
        // AE#359: subtitles off ends the rendition poll. The renditions themselves stay listed, only
        // the fetching stops, so re-selecting the track starts fresh from the current window.
        liveSubtitleFetchTask?.cancel()
        liveSubtitleFetchTask = nil
        // AE#154: a remote-HLS legible selection lives in AVMediaSelection, not the overlay
        // pipeline; deselect it on the item (criteria pinned manual so system caption prefs
        // don't immediately re-select).
        // #316: an injected external rendition is the same kind of selection, under an external id.
        //
        if let active = activeSubtitleTrackIndex,
           RemoteHLSMediaSelection.ordinal(forTrackID: active) != nil
            || injectedSubtitleRenditionNames[active] != nil,
           let item = currentAVPlayer?.currentItem {
            Task { @MainActor in
                self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
                guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
                item.select(nil, in: group)
                EngineLog.emit("[AetherEngine] subtitles off: legible selection cleared", category: .engine)
            }
        }
        cancelSidecarTask()
        cancelSubtitleOCRWorker()   // Phase D: subtitles off = worker off (cursors persist)
        clearSubtitleDrainTarget(channel: .primary, reason: .subtitlesCleared)   // #112 rework
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        loadedSidecarURL = nil
        isSubtitleActive = false
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        subtitleSource?.withdraw(.rendition)
        // Sodalite#32 Phase 2: with the pump tap active the stores are the session's cue source of
        // truth (the tap's decoder dedup would never refill a cleared store), so subtitles-off keeps
        // them; only the reader-driven path tears them down.
        if nativeVideoSession?.subtitleTapActive != true {
            nativeVideoSession?.nativeSubtitleCueStoresForSession.forEach { $0.clear() }
            nativeVideoSession?.nativeSubtitleCueStoresForSession = []
            nativeVideoSession?.nativeSubtitleLanguagesForSession = []
            nativeSubtitleRenditionAvailable = false
        }
        // Subtitles off is exactly when tvOS shows the forced rendition, so it keeps being filled, and on the
        // native route the selection goes back to AVFoundation's own, which shows it.
        resumeForcedRenditionFill()
        selectNativeSubtitleAutomatically()
    }

    func cancelSidecarTask(channel: SubtitleChannel = .primary) {
        switch channel {
        case .primary:
            sidecarTask?.cancel()
            sidecarTask = nil
        case .secondary:
            secondarySidecarTask?.cancel()
            secondarySidecarTask = nil
        }
    }

    /// Turn the secondary subtitle off and clear its cues. Tears down
    /// the secondary sidecar decode task and its packet-store drain target.
    public func clearSecondarySubtitle() {
        externalSubtitleIntentGeneration &+= 1
        hostExplicitSubtitleAction = true
        cancelSidecarTask(channel: .secondary)
        clearSubtitleDrainTarget(channel: .secondary, reason: .subtitlesCleared)   // #112 rework
        activeSecondaryEmbeddedSubtitleStreamIndex = -1
        activeSecondaryExternalSubtitleTrackID = nil
        loadedSecondarySidecarURL = nil
        isSecondarySubtitleActive = false
        secondarySubtitleCues = []
        secondarySidecarASSHeader = nil
        pgsStaleArrivalGates[.secondary]?.reset()   // #100
        isLoadingSecondarySubtitles = false
    }

    // MARK: - Native renditions (#55, all-tracks)

    /// #93 PiP skips: debounced re-anchor after a far rendered-time jump. Waits for the skip storm to
    /// settle, then, if the selected rendition's reading does not cover the playhead, replays the
    /// remembered selection: its demand moves the subtitle source to the playhead, and its pre-fill +
    /// deselect/reselect busts AVKit's cached empty .vtt windows (#32).
    func scheduleNativeSubtitleReanchor() {
        guard nativeSubtitleReapplyOrdinal != nil, nativeVideoSession != nil else { return }
        nativeSubtitleReanchorTask?.cancel()
        nativeSubtitleReanchorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AetherEngine.subtitleReanchorSettleNanos)
            guard !Task.isCancelled, let self else { return }
            guard let ordinal = self.nativeSubtitleReapplyOrdinal, self.nativeVideoSession != nil,
                  let store = self.nativeStore(atOrdinal: ordinal), !store.isFinished else { return }
            let position = self.sourceTime
            let span = store.readingSpan
            let readMax = store.readThrough(at: position)
            if Self.nativeSubtitleReadersCover(position: position, coverageStart: span?.from, readMax: readMax) {
                return
            }
            EngineLog.emit(
                "[AetherEngine] native subtitle rendition re-anchoring: playhead "
                + "\(String(format: "%.2f", position))s outside its reading "
                + "(start=\(span.map { String(format: "%.2f", $0.from) } ?? "none") "
                + "readMax=\(String(format: "%.2f", readMax))); replaying selection ordinal=\(ordinal)",
                category: .engine
            )
            self.setNativeSubtitleSelected(track: ordinal)
        }
    }


    /// Select or deselect the native mov_text track by ordinal (#55). nil deselects all. Matches by `extendedLanguageTag` first (language-rank-aware for same-language duplicates), falls back to positional index. No-op when no legible group or ordinal out of range.
    public func setNativeSubtitleSelected(track ordinal: Int?) {
        // Remembered before any guard: the #93 recovery reload replays the host's last request
        // onto the fresh item even when this call raced a not-yet-current player.
        nativeSubtitleReapplyOrdinal = ordinal
        // #15: the renditions are read ahead only while one is selected (PiP), from the playhead.
        if ordinal != nil {
            demandNativeRenditionSubtitles(.rendition, stores: nativeTextRenditionStores)
        } else {
            subtitleSource?.withdraw(.rendition)
        }
        guard let item = currentAVPlayer?.currentItem else { return }
        // Capture track list; avoid capturing self to keep MainActor re-entrancy to one hop.
        let tracks = nativeSubtitleTracks
        Task { @MainActor in
            // #15: with automatic media-selection criteria on (the default), AVKit can override/not-render an
            // explicit legible selection until a view refresh. Pin manual selection so the explicit choice
            // renders immediately and survives.
            currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            guard !group.options.isEmpty else { return }
            guard let ordinal else {
                item.select(nil, in: group)
                return
            }
            // Rank-based selection through the ISO-synonym matcher: AVFoundation normalizes HLS
            // LANGUAGE tags (matroska "ger" reads back as extendedLanguageTag "de"), so the old
            // prefix compare found nothing and its positional fallback selected a WRONG-LANGUAGE
            // option (device: the second German track rendered the English rendition in PiP).
            // Language-tagged tracks now select nothing on a failed match; only language-less
            // tracks keep the positional fallback.
            var selected: AVMediaSelectionOption?
            if ordinal < tracks.count, let lang = tracks[ordinal].language {
                let rank = NativeSubtitleTrack.sameLanguageRank(of: ordinal, in: tracks)
                let tags = group.options.map { $0.extendedLanguageTag }
                if let idx = Self.nativeOptionIndex(forLanguage: lang, rank: rank, optionLanguageTags: tags) {
                    selected = group.options[idx]
                }
            } else if ordinal < group.options.count {
                selected = group.options[ordinal]
            }
            guard let option = selected else {
                EngineLog.emit("[AetherEngine] native subtitle select: no matching option for ordinal=\(ordinal) lang=\(ordinal < tracks.count ? (tracks[ordinal].language ?? "nil") : "?") groupOpts=\(group.options.count)", category: .engine)
                return
            }
            // #15: pre-fill BEFORE selecting, so AVPlayer fetches a populated rendition instead of racing the
            // reader (empty .vtt). Done here (off the loopback connection) rather than blocking the .vtt handler,
            // which serializes the connection and stalls the legible pipeline.
            // Sodalite#32: AVKit prefetches the ENTIRE forward subtitle window (~3 min observed) in ONE burst at
            // selection and caches whatever it gets, never re-fetching a segment it already pulled. A +5s pre-fill
            // left ~45/46 segments empty (device-confirmed). Pre-fill far enough ahead to cover that burst; break
            // early when the reader stops making progress (EOF / read-ahead parked) so we never wait the full
            // deadline for content with little remaining.
            var prefilledCues: Int?
            var readPastPlayhead = false
            if let store = nativeStore(atOrdinal: ordinal) {
                let from = currentTime
                let target = from + 240.0
                let deadline = Date().addingTimeInterval(15.0)
                var lastMax = 0.0
                var stall = 0
                // Sodalite#156: WHY the pre-fill stopped, which the line below could not say. An empty
                // one reads the same whether the reader never started, parked, or ran out of time, and
                // those are three different defects: the select that follows caches whatever the
                // rendition holds at that instant, forever, so an empty exit here is a caption box
                // with no text in it for the rest of the session.
                //
                // Waited on how far the track has been READ, not on its last cue's end: a forced
                // track's cues can sit minutes behind its reading, so the cues cannot tell a track
                // read to the target with nothing to say there from one not read yet.
                let began = Date()
                var exit = "target"
                while store.readThrough(at: from) < target, !store.isFinished, Date() < deadline {
                    let m = store.readThrough(at: from)
                    if m > lastMax {
                        lastMax = m
                        stall = 0
                    } else if lastMax > 0 {
                        // Only treat a flat reading as "reader done/parked" AFTER it has started producing;
                        // before the first note lands (seek + demux latency) it is legitimately 0, and an
                        // early break would skip the pre-fill entirely (Sodalite#32 regression).
                        stall += 1
                    }
                    if stall >= 6 { exit = "stall"; break }   // ~900ms with no progress => EOF / read-ahead parked
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
                let read = store.readThrough(at: from)
                if exit == "target", read < target, !store.isFinished { exit = "deadline" }
                let waited = Int(Date().timeIntervalSince(began) * 1000)
                EngineLog.emit("[AetherEngine] native subtitle pre-fill done: read=\(String(format: "%.1f", read)) readMax=\(String(format: "%.1f", store.readMaxCueEnd())) target=\(String(format: "%.1f", target)) cues=\(store.cueCount) exit=\(exit) waited=\(waited)ms readingAhead=\(subtitleSource?.isReadingAhead == true)", category: .engine)
                prefilledCues = store.cueCount
                readPastPlayhead = store.isFinished || read > from
            }
            // Sodalite#156: never hand AVKit an EMPTY rendition. The comment above says why the
            // pre-fill exists; this is the half that was missing, and without it the pre-fill is
            // advice rather than a gate. AVKit fetches the whole forward window in one burst at
            // selection and never re-fetches a segment it already has, so selecting an empty
            // rendition is not a slow start, it is a caption box with no text in it for the rest of
            // the session (device log 2026-09-19: `cues=0 exit=deadline waited=15146ms`, then
            // `selected=Deutsch`, then an empty `subs_0_392.vtt` the receiver kept).
            //
            // Empty is not always a race. The store can be legitimately empty because the track has
            // nothing to say here: a FORCED subtitle covers foreign dialogue only. That case is told
            // apart by the reading: a track read past the playhead that holds no line there is
            // truthfully empty, and selecting it is right (its later lines arrive as the reading
            // does). Only a track nobody has read yet is refused.
            //
            // Refusing costs nothing that selecting would have bought: nothing is drawn either way,
            // and only the refusal can be retried. `nativeSubtitleReapplyOrdinal` is set before this
            // runs, so the rendition's re-anchor re-selects once the reading reaches the playhead.
            if prefilledCues == 0, !readPastPlayhead {
                EngineLog.emit("[AetherEngine] native subtitle select refused: rendition ordinal=\(ordinal) "
                               + "is unread at the playhead, and AVKit caches what it is handed. "
                               + "Leaving it deselected; the rendition's re-anchor retries once it is read",
                               category: .engine)
                return
            }
            // #15: AVKit attaches the legible renderer to whatever selection is active when the rendering
            // pipeline is established; a selection made mid-playback updates state + downloads cues but is not
            // drawn until re-asserted. Deselect, hop one runloop, then reselect to force the renderer to attach
            // (documented workaround; the same effect a PiP round-trip had). Needs the manual-criteria pin above.
            let itemID = String(UInt(bitPattern: ObjectIdentifier(item).hashValue) & 0xffff, radix: 16)
            EngineLog.emit("[AetherEngine] native subtitle select: item=\(itemID) opt=\(option.displayName) groupOpts=\(group.options.count) criteriaAuto=\(currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically ?? true) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
            item.select(nil, in: group)
            try? await Task.sleep(nanoseconds: 100_000_000)
            item.select(option, in: group)
            let after = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
            EngineLog.emit("[AetherEngine] native subtitle select done: selected=\(after) itemIsCurrent=\(currentAVPlayer?.currentItem === item)", category: .engine)
            // Sodalite#32: a select landing inside a stall recovery gets dropped outright by AVFoundation
            // (device: PiP entry 0.1s after waitingToPlay -> playing read back nil and STAYED nil; the same
            // select succeeded on the previous entry). Re-assert briefly until it sticks or the item changes.
            var retries = 0
            while item.currentMediaSelection.selectedMediaOption(in: group) == nil,
                  retries < 4,
                  currentAVPlayer?.currentItem === item {
                retries += 1
                try? await Task.sleep(nanoseconds: 700_000_000)
                item.select(option, in: group)
                let retried = item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "nil"
                EngineLog.emit("[AetherEngine] native subtitle select retry #\(retries): selected=\(retried)", category: .engine)
            }
        }
    }

    /// The subtitle track (the id `selectSubtitleTrack(index:)` takes) behind a legible option of the current
    /// item, for a host that lets AVKit's own subtitle menu pick (`setNativeSubtitleRendering(true)`), told of
    /// the pick by `playerViewController(_:didSelect:in:)`. Nil for an option no served rendition backs.
    /// Inverse of the match `setNativeSubtitleSelected` makes: the n-th option in a language is the n-th
    /// rendition in that language; a language-less option is matched by position.
    public func subtitleTrackID(forNativeOption option: AVMediaSelectionOption, in group: AVMediaSelectionGroup) -> Int? {
        guard let index = group.options.firstIndex(of: option),
              let ordinal = Self.nativeOrdinal(forOptionAt: index,
                                               optionLanguageTags: group.options.map { $0.extendedLanguageTag },
                                               trackLanguages: nativeSubtitleTracks.map { $0.language }),
              ordinal < nativeSubtitleTrackTable.count else { return nil }
        let entry = nativeSubtitleTrackTable[ordinal]
        // A forced-only rendition is not a track the viewer picks; it is what shows when they pick none.
        guard !entry.forcedCuesOnly else { return nil }
        return entry.sourceStreamIndex ?? entry.externalID
    }

    /// The rendition ordinal behind option `index`; see `subtitleTrackID(forNativeOption:in:)`.
    nonisolated static func nativeOrdinal(forOptionAt index: Int, optionLanguageTags: [String?],
                                          trackLanguages: [String?]) -> Int? {
        guard index >= 0, index < optionLanguageTags.count else { return nil }
        guard let tag = optionLanguageTags[index] else {
            return index < trackLanguages.count ? index : nil
        }
        let rank = optionLanguageTags[0..<index].filter { languageMatches($0, tag) }.count
        let matching = trackLanguages.indices.filter { trackLanguages[$0].map { languageMatches(tag, $0) } ?? false }
        return rank < matching.count ? matching[rank] : nil
    }

    /// #88: ordinal of the table entry backing an active track id: embedded ids match
    /// sourceStreamIndex, external ids match externalID.
    /// `forced`: the track is shown as forced subtitles (`selectForcedSubtitleTrack`), so the rendition is
    /// its forced one: the track's own when the track is forced, else the forced-only rendition made from
    /// its flagged lines; nil when it has neither.
    nonisolated static func nativeSubtitleOrdinal(forActiveTrack id: Int, in table: [NativeSubtitleTrackEntry],
                                                  forced: Bool = false) -> Int? {
        guard let ordinal = table.firstIndex(where: { $0.sourceStreamIndex == id || $0.externalID == id }) else {
            return nil
        }
        guard forced, !table[ordinal].isForced else { return ordinal }
        return table.firstIndex { $0.forcedCuesOnly && $0.sourceStreamIndex == id }
    }

    /// #266: group the load-declared external tracks into one fill job per container, so a URL
    /// backing several tracks (an MKV with three subtitle streams) is read once instead of once per
    /// track. Headers are part of the grouping key: differing auth means differing requests.
    /// Duplicate registrations of one stream stay separate targets, both stores get the cues.
    /// Ordering is by first appearance in the table, so the jobs are deterministic.
    nonisolated static func externalSubtitleFillJobs(
        table: [NativeSubtitleTrackEntry],
        registry: [Int: ExternalSubtitleTrack],
        stores: [NativeSubtitleCueStore],
        defaultHeaders: [String: String], mediaURL: URL?
    ) -> [ExternalSubtitleFillJob] {
        struct Key: Hashable {
            let url: URL
            let headers: [String: String]
        }
        var order: [Key] = []
        var targetsByKey: [Key: [ExternalSubtitleFillJob.Target]] = [:]
        for (ordinal, entry) in table.enumerated() {
            // Phase D: OCR entries defer to the selection-time sidecar decode (OCR of a whole
            // .sup at load would violate the selection gating).
            guard !entry.needsOCR, let extID = entry.externalID,
                  let track = registry[extID], ordinal < stores.count else { continue }
            let key = Key(url: track.url, headers: resolvedSubtitleHeaders(
                for: track.url, explicit: track.httpHeaders, mediaURL: mediaURL,
                mediaHeaders: defaultHeaders))
            if targetsByKey[key] == nil { order.append(key) }
            targetsByKey[key, default: []].append(
                .init(streamIndex: track.sourceStreamIndex, store: stores[ordinal]))
        }
        return order.map {
            ExternalSubtitleFillJob(url: $0.url, headers: $0.headers, targets: targetsByKey[$0] ?? [])
        }
    }

    /// Phase D: bitmap tracks eligible for an OCR-fed rendition. VOD only; embedded entries carry
    /// their source stream index (the worker's packet-store key), external .sup entries their
    /// synthetic id (the sidecar OCR fill key).
    nonisolated static func bitmapOCRSubtitleEntries(
        from tracks: [TrackInfo], isLive: Bool
    ) -> [NativeSubtitleTrackEntry] {
        guard !isLive else { return [] }
        return tracks.filter { isBitmapSubtitleCodec($0.codec) }.map { track in
            NativeSubtitleTrackEntry(sourceStreamIndex: track.isExternal ? nil : track.id,
                                     externalID: track.isExternal ? track.id : nil,
                                     language: track.language,
                                     isForced: track.isForced,
                                     isHearingImpaired: track.isHearingImpaired,
                                     needsOCR: true)
        }
    }

    /// Rendition metadata for the master's EXT-X-MEDIA tags. HLS requires NAME to be unique within
    /// a group; duplicate names made AVFoundation collapse same-language renditions into ONE
    /// legible option (device: three declared, groupOpts=2, and the second German track ended up
    /// selecting the English option through the old positional fallback). Same-language duplicates
    /// get a numbered suffix. An entry marked `declaresForced` (`LoadOptions.forcedSubtitleTrack`) carries
    /// FORCED=YES into the master; nothing else is declared forced (Sodalite#38).
    nonisolated static func nativeSubtitleRenditionInfos(
        for entries: [NativeSubtitleTrackEntry]
    ) -> [NativeSubtitleRenditionInfo] {
        var counts: [String: Int] = [:]
        return entries.enumerated().map { i, entry in
            var base = entry.language.flatMap { Locale.current.localizedString(forIdentifier: $0) }
                ?? "Subtitle \(i + 1)"
            if entry.forcedCuesOnly { base += " (Forced)" }
            let n = (counts[base] ?? 0) + 1
            counts[base] = n
            return NativeSubtitleRenditionInfo(
                language: entry.language,
                name: n == 1 ? base : "\(base) \(n)",
                isForced: entry.declaresForced,
                isSDH: entry.isHearingImpaired
            )
        }
    }

    /// How `LoadOptions.forcedSubtitleTrack` was declared, for the session log.
    enum ForcedSubtitleDeclaration: Equatable {
        /// The named track is a forced track: its own rendition is declared forced.
        case ownRendition
        /// The named track is a full embedded bitmap track: a forced-only rendition of its flagged lines
        /// was appended to `bitmap`.
        case flaggedLines
        /// Nothing to declare: no such track, or one whose forced lines cannot be told apart (a full text
        /// track carries forcedness only per track; an external .sup is filled from the overlay's
        /// whole-file decode, not by the worker).
        case none
    }

    /// Marks the one rendition to declare forced for `source` (`LoadOptions.forcedSubtitleTrack`): the
    /// track's own when it is a forced track, else, for an embedded bitmap track, a forced-only entry
    /// appended to `bitmap`, holding just the lines the track flags as forced (the OCR worker drops the
    /// rest). Appended after every other entry so the other ordinals do not move.
    nonisolated static func declareForcedSubtitleSource(
        _ source: Int, text: inout [NativeSubtitleTrackEntry], bitmap: inout [NativeSubtitleTrackEntry]
    ) -> ForcedSubtitleDeclaration {
        func isSource(_ entry: NativeSubtitleTrackEntry) -> Bool {
            entry.sourceStreamIndex == source || entry.externalID == source
        }
        if let i = text.firstIndex(where: isSource) {
            guard text[i].isForced else { return .none }
            text[i].declaresForced = true
            return .ownRendition
        }
        guard let i = bitmap.firstIndex(where: isSource) else { return .none }
        if bitmap[i].isForced {
            bitmap[i].declaresForced = true
            return .ownRendition
        }
        guard let stream = bitmap[i].sourceStreamIndex else { return .none }
        bitmap.append(NativeSubtitleTrackEntry(sourceStreamIndex: stream,
                                               language: bitmap[i].language,
                                               isForced: true,
                                               needsOCR: true,
                                               forcedCuesOnly: true,
                                               declaresForced: true))
        return .flaggedLines
    }

    /// `LoadOptions.declaresForcedSubtitles`: every track the container flags forced is declared a forced
    /// rendition, beside whatever `declareForcedSubtitleSource` declared.
    nonisolated static func declareTrackForcedness(_ entries: inout [NativeSubtitleTrackEntry]) {
        for i in entries.indices where entries[i].isForced { entries[i].declaresForced = true }
    }

    /// Index of the legible option backing (track language, same-language rank). AVFoundation
    /// normalizes HLS LANGUAGE tags (matroska "ger" reads back as extendedLanguageTag "de", often
    /// with a region subtag), so matching goes through `languageMatches`, which spans the ISO
    /// forms and ignores a region or script subtag on either side (#590: it used to be handed a
    /// hand-split primary subtag, because the matcher could not see past one itself). Deliberately
    /// NO cross-language fallback: selecting a wrong-language option is worse than selecting
    /// nothing (device: German pick rendered the English rendition in PiP).
    nonisolated static func nativeOptionIndex(
        forLanguage language: String?, rank: Int, optionLanguageTags: [String?]
    ) -> Int? {
        guard let language, rank >= 0 else { return nil }
        let matching = optionLanguageTags.indices.filter { languageMatches(optionLanguageTags[$0], language) }
        guard rank < matching.count else { return nil }
        return matching[rank]
    }

    /// #15 / Sodalite#34: the rendition is the display while the picture is off the host's own view hierarchy
    /// (a PiP window, an AirPlay receiver, or a wired external display), where the host's overlay cannot draw.
    /// `true` lets AVKit draw whatever is selected, the tracks the overlay draws included (their WebVTT
    /// renditions: OCR'd bitmaps, ASS reduced to emphasis and alignment), and rebuilds the session first when
    /// its renditions serve another subtitle delay than the viewer's (`setSubtitleDelay(_:)`). `false` (the
    /// picture is back) suppresses AVKit again for a track the overlay draws. The selection itself is
    /// AVFoundation's (`AetherEngine+NativeSubtitleSelection`); this moves no option.
    public func setNativeSubtitleRendering(_ active: Bool) {
        // Sodalite#156: the host's request is a STANDING one, not a one-shot. It says where the
        // picture is, and it holds until the picture comes back or the session ends, which is what
        // lets a later track pick or a subtitles-off know that the rendition is the display.
        nativeSubtitleRenderingRequested = active
        // #170: the AirPlay flip triggers both the engine's LAN-swap reload and the host's
        // documented rendering call; latch the newest request across a reload, which arms the new
        // item's selection with it.
        if sessionPreservingReloadInFlight {
            pendingNativeRenderingRequest = active
            return
        }
        if active { rebuildIfServedSubtitleDelayIsStale() }
        let suppress = !active && !primarySubtitleDrawnByAVKit
        Task { @MainActor [weak self] in await self?.setNativeSubtitleSuppressed(suppress) }
    }

    // MARK: - Session-preserving reload carryover (#170)

    /// True when `nativeSubtitleReapplyOrdinal` equals the active track's mapping through the
    /// current rendition table, i.e. the ordinal came from `setNativeSubtitleRendering` rather
    /// than a host-positional `setNativeSubtitleSelected`. Decides recompute-vs-positional replay.
    func currentReapplyOrdinalMatchesActiveTrack() -> Bool {
        guard let ordinal = nativeSubtitleReapplyOrdinal,
              let active = activeSubtitleTrackIndex else { return false }
        return Self.nativeSubtitleOrdinal(forActiveTrack: active, in: nativeSubtitleTrackTable,
                                          forced: forcedSubtitleSelection) == ordinal
    }

    /// #170: snapshot the subtitle session state a from-scratch `load()` would wipe. Taken by
    /// `reloadAtCurrentPosition` before the reload; seeded back via
    /// `LoadOptions.subtitleSessionCarryover` and `restoreSubtitleSelection`.
    func captureSubtitleSessionCarryover() -> SubtitleSessionCarryover {
        var carryover = SubtitleSessionCarryover()
        carryover.externalTracks = externalSubtitleRegistry
            .sorted { $0.key < $1.key }
            .map { .init(id: $0.key, track: $0.value) }
        carryover.nextExternalOrdinal = nextExternalSubtitleOrdinal
        carryover.hostExplicitSubtitleAction = hostExplicitSubtitleAction
        carryover.activeSubtitleTrackIndex = activeSubtitleTrackIndex
        carryover.primarySidecarURL = (isSubtitleActive && activeSubtitleTrackIndex == nil
            && activeEmbeddedSubtitleStreamIndex < 0) ? loadedSidecarURL : nil
        carryover.secondaryTrackIndex = activeSecondaryExternalSubtitleTrackID
            ?? (activeSecondaryEmbeddedSubtitleStreamIndex >= 0
                ? Int(activeSecondaryEmbeddedSubtitleStreamIndex) : nil)
        carryover.secondarySidecarURL = (isSecondarySubtitleActive && carryover.secondaryTrackIndex == nil)
            ? loadedSecondarySidecarURL : nil
        carryover.nativeReapplyOrdinal = nativeSubtitleReapplyOrdinal
        carryover.reapplyOrdinalMatchesActiveTrack = currentReapplyOrdinalMatchesActiveTrack()
        carryover.forcedSubtitleSelection = forcedSubtitleSelection
        return carryover
    }

    /// #170: seed the fresh session's external registry from the carryover, id-exactly (removal
    /// gaps preserved), and restore the host's subtitle authority so the load-end
    /// preferred-language auto-selection cannot override an explicit pick. Called by `load()` at
    /// the #88 registration point, BEFORE the native rendition table is built, so mid-session
    /// tracks become rendition-eligible on the reloaded item.
    func applySubtitleSessionCarryoverRegistrations(_ carryover: SubtitleSessionCarryover) {
        for entry in carryover.externalTracks {
            externalSubtitleRegistry[entry.id] = entry.track
            subtitleTracks.append(entry.track.makeTrackInfo(
                id: entry.id,
                fallbackNumber: entry.id - Self.externalSubtitleTrackIDBase + 1))
        }
        nextExternalSubtitleOrdinal = max(nextExternalSubtitleOrdinal, carryover.nextExternalOrdinal)
        if carryover.hostExplicitSubtitleAction { hostExplicitSubtitleAction = true }
    }

    /// #170: re-establish the pre-reload subtitle selection on the reloaded session instead of
    /// leaving the re-run auto-selection in charge, then replay the native-rendition pick the way
    /// the #65 recovery does (a latched mid-reload `setNativeSubtitleRendering` is newer intent
    /// and wins over the snapshot).
    func restoreSubtitleSelection(from carryover: SubtitleSessionCarryover, resumeAnchor: Double?) {
        // Anchor mirrors applyPreferredSubtitleSelection: the reload's resume position (clamped
        // when the duration is already known) so the drainer arms at the playhead, else
        // the live sourceTime.
        var anchor = max(0, resumeAnchor ?? 0)
        if duration > 0 { anchor = min(anchor, duration) }
        let startAt = anchor > 0 ? anchor : sourceTime
        switch Self.subtitleSelectionRestoreAction(
            previousActiveIndex: carryover.activeSubtitleTrackIndex,
            previousSidecarURL: carryover.primarySidecarURL,
            hostHadExplicitAction: carryover.hostExplicitSubtitleAction,
            postLoadActiveIndex: activeSubtitleTrackIndex,
            postLoadSubtitleActive: isSubtitleActive
        ) {
        case .reselect(let index):
            forcedSubtitleSelection = carryover.forcedSubtitleSelection
                && index == carryover.activeSubtitleTrackIndex
            selectSubtitleTrack(index: index, startAt: startAt)
        case .sidecar(let url):
            startSidecarDecode(url: url, httpHeaders: nil, externalTrackID: nil)
        case .clear:
            clearSubtitle()
        case .none:
            break
        }
        if let secondary = carryover.secondaryTrackIndex {
            selectSecondarySubtitleTrack(index: secondary, startAt: startAt)
        } else if let url = carryover.secondarySidecarURL {
            selectSecondarySidecarSubtitle(url: url)
        }
        if let pending = pendingNativeRenderingRequest {
            pendingNativeRenderingRequest = nil
            setNativeSubtitleRendering(pending)
        } else if let ordinal = Self.nativeOrdinalToReplay(
            previousOrdinal: carryover.nativeReapplyOrdinal,
            matchesActiveTrack: carryover.reapplyOrdinalMatchesActiveTrack,
            previousActiveTrack: carryover.activeSubtitleTrackIndex,
            currentOrdinal: nativeSubtitleReapplyOrdinal,
            table: nativeSubtitleTrackTable,
            forced: forcedSubtitleSelection
        ) {
            EngineLog.emit(
                "[AetherEngine] #170 re-applying native subtitle ordinal=\(ordinal) after session-preserving reload",
                category: .engine
            )
            setNativeSubtitleSelected(track: ordinal)
        }
    }

    // MARK: - Remote-HLS bypass legible selection (AE#154)

    /// Surface the bypass item's legible AVMediaSelectionGroup as `subtitleTracks` (synthetic ids,
    /// see `RemoteHLSMediaSelection`). Runs once per load; after readiness it mirrors a selection
    /// AVKit or system caption preferences already made so host pickers start truthful. Deliberately
    /// no force-deselect here (unlike Sodalite#38 on the loopback path): this bypass has no on-frame
    /// overlay, AVPlayer's own legible renderer IS the subtitle output, so system prefs stay honored.
    ///
    /// AE#154 follow-up (jihongboo, macOS 27 beta): the legible group is usually populated once the
    /// master playlist is parsed, well before readyToPlay (device: macOS 26 surfaces all renditions at
    /// ~0.5 s). But on some OS versions `loadMediaSelectionGroup(for:)` returns an empty group until the
    /// item reaches readyToPlay, and a one-shot load then silently dropped every rendition. Retry once
    /// after readiness before giving up, so an early-empty group no longer leaves `subtitleTracks` empty.
    func publishRemoteHLSSubtitleTracks(host: NativeAVPlayerHost) {
        remoteHLSSubtitleDiscoveryTask?.cancel()
        guard let item = host.avPlayer.currentItem else { return }
        remoteHLSSubtitleDiscoveryTask = Task { @MainActor [weak self] in
            var group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            if group?.options.isEmpty ?? true {
                // Early-empty group: wait for readyToPlay (AVFoundation's guarantee point for HLS
                // media selection) and load once more. Cancelled by the next load()/stop().
                for await ready in host.$isReady.values where ready { break }
                guard !Task.isCancelled else { return }
                group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
            }
            guard let group, !group.options.isEmpty else { return }
            guard let self, !Task.isCancelled,
                  self.currentAVPlayer?.currentItem === item else { return }
            var snapshots: [RemoteHLSMediaSelection.LegibleOption] = []
            for option in group.options {
                snapshots.append(RemoteHLSMediaSelection.LegibleOption(
                    displayName: option.displayName,
                    extendedLanguageTag: option.extendedLanguageTag,
                    isDefault: group.defaultOption == option,
                    isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
                    isSDH: option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
                        && option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility),
                    playlistName: await RemoteHLSMediaSelection.playlistName(of: option)))
            }
            // #316: merge, don't assign; the host's load-declared external tracks must survive. The
            // renditions the proxy injected for those same tracks are dropped here: they are already
            // listed under their external ids, and a second entry would offer one file as two tracks.
            let injected = Set(self.injectedSubtitleRenditionNames.values)
            self.subtitleTracks = RemoteHLSMediaSelection.mergedSubtitleTracks(
                existing: self.subtitleTracks, legible: snapshots, injectedNames: injected)
            EngineLog.emit(
                "[AetherEngine] AE#154: remote-HLS legible group surfaced \(group.options.count) subtitle "
                + "rendition(s)\(injected.isEmpty ? "" : ", \(injected.count) of them engine-injected (#316)")",
                category: .engine)
            // Selection mirror after readiness: AVKit / caption-pref auto-select runs at readyToPlay,
            // later than the group load above.
            for await ready in host.$isReady.values where ready { break }
            guard !Task.isCancelled, self.currentAVPlayer?.currentItem === item,
                  !self.hostExplicitSubtitleAction else { return }
            if let selected = item.currentMediaSelection.selectedMediaOption(in: group),
               let ordinal = group.options.firstIndex(of: selected) {
                // #316: an auto-selected injected rendition mirrors back as the EXTERNAL id it was
                // declared under, not as a second identity in the legible id range.
                let selectedName = await RemoteHLSMediaSelection.playlistName(of: selected)
                    ?? selected.displayName
                self.activeSubtitleTrackIndex = self.injectedSubtitleRenditionNames
                    .first { $0.value == selectedName }?.key
                    ?? RemoteHLSMediaSelection.subtitleTrackIDBase + ordinal
                self.isSubtitleActive = true
                EngineLog.emit(
                    "[AetherEngine] AE#154: mirrored auto-selected legible option ordinal=\(ordinal)",
                    category: .engine)
            }
        }
    }

    /// #316: activate a sidecar the proxy declared in the served master. The track keeps the external id
    /// the host registered it under, but the selection is an `AVMediaSelection` one, so AVPlayer renders
    /// it and it survives leaving the view hierarchy.
    ///
    /// Matched by NAME: `name` is the one the served master declares (`RemoteHLSMasterRewrite`
    /// disambiguates it against the origin's names and every other sidecar, and escapes it), and
    /// `AVMediaSelectionOption.displayName` is the rendition's NAME attribute.
    /// A miss leaves the previous selection alone and says so rather than silently reporting success.
    func selectInjectedSubtitleRendition(id: Int, name: String) {
        guard let item = currentAVPlayer?.currentItem else { return }
        cancelSidecarTask()
        clearSubtitleDrainTarget(channel: .primary, reason: .injectedRenditionSelected)
        activeEmbeddedSubtitleStreamIndex = -1
        // AVPlayer owns the drawing here; leaving overlay cues behind would double up.
        subtitleCues = []
        loadedSidecarURL = nil
        isSubtitleActive = true
        activeSubtitleTrackIndex = id
        isLoadingSubtitles = false
        Task { @MainActor in
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) else { return }
            var snapshots: [RemoteHLSMediaSelection.LegibleOption] = []
            for option in group.options {
                snapshots.append(RemoteHLSMediaSelection.LegibleOption(
                    displayName: option.displayName, extendedLanguageTag: nil,
                    isDefault: false, isForced: false, isSDH: false,
                    playlistName: await RemoteHLSMediaSelection.playlistName(of: option)))
            }
            let seen = snapshots.map(RemoteHLSMediaSelection.injectionKey)
            guard let index = RemoteHLSMediaSelection.injectedRenditionIndex(named: name, in: snapshots) else {
                EngineLog.emit(
                    "[AetherEngine] #316: injected rendition \"\(name)\" is not in the item's legible "
                    + "group (\(seen.joined(separator: ", ")))",
                    category: .engine)
                return
            }
            item.select(group.options[index], in: group)
            EngineLog.emit("[AetherEngine] #316: selected injected rendition \"\(name)\" for external id=\(id)",
                           category: .engine)
        }
    }

    /// Select a remote-HLS legible option by synthetic track id (AE#154). AVPlayer renders the cues
    /// itself on this bypass; there is no overlay pipeline, so activation only drives
    /// AVMediaSelection (criteria pinned manual so the explicit choice sticks, #15).
    func selectRemoteHLSSubtitleTrack(id: Int) {
        guard let ordinal = RemoteHLSMediaSelection.ordinal(forTrackID: id),
              let item = currentAVPlayer?.currentItem else { return }
        cancelSidecarTask()
        subtitleCues = []
        isSubtitleActive = true
        activeSubtitleTrackIndex = id
        isLoadingSubtitles = false
        Task { @MainActor in
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = false
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  ordinal < group.options.count else { return }
            item.select(group.options[ordinal], in: group)
            EngineLog.emit(
                "[AetherEngine] AE#154: remote-HLS legible select ordinal=\(ordinal) (\(group.options[ordinal].displayName))",
                category: .engine)
        }
    }
}

/// AE#628: one channel's share of a drain tick, everything the decode needs and everything the
/// apply half reads back. Built and consumed on the MainActor; only `decodeHandoff` leaves it.
struct SubtitleDrainChannelWork {
    let channel: SubtitleChannel
    let streamIndex: Int32
    let plan: SubtitleDrainPlan
    let isReset: Bool
    let window: (from: Double, through: Double)
    let coverageStart: Double?
    let retained: SubtitleResolutionStatement.Retention?
    let decoder: EmbeddedSubtitleDecoder
    let entries: [StoredSubtitlePacket]
    let batchEnd: Int
    let decodeEnd: Int
    let gapHoldAt: Double?
    let gapHoldSequence: UInt64
    let gapHoldTicksLeft: Int
    /// The stream is pulled from the index (layer 3 step 3).
    let pulled: Bool
    /// An upscaling landing stopped the batch just past the playhead (`subtitleUpscaleLandingSeconds`).
    var landingCut = false
}

struct SubtitleDrainTickWork {
    let store: SubtitlePacketStore
    let playhead: Double
    /// The landing count the tick planned against; the cursors it writes have followed that many.
    let landingGeneration: UInt64
    var channels: [SubtitleDrainChannelWork] = []
    /// The bitmap upscale the decode half applies, nil when none is asked for.
    var upscale: BitmapSubtitleUpscaling.Request?

    var decodeHandoff: SubtitleDrainDecodeHandoff {
        SubtitleDrainDecodeHandoff(jobs: channels.map { ($0.decoder, $0.entries[..<$0.decodeEnd]) },
                                   upscaling: upscale.map { ($0, channels.map(\.streamIndex)) })
    }
}

/// AE#628: the decode half of a drain tick, the only part that runs off the MainActor. Unchecked
/// because a decoder wraps an AVCodecContext; sound because a decoder is only ever driven by the
/// one tick in flight (`subtitleDrainTickInFlight`), and a decoder the channel dropped meanwhile is
/// never read again once its batch lands.
struct SubtitleDrainDecodeHandoff: @unchecked Sendable {
    let jobs: [(decoder: EmbeddedSubtitleDecoder, packets: ArraySlice<StoredSubtitlePacket>)]
    /// The overlay's upscale and each job's stream (`BitmapSubtitleUpscaling`); nil leaves the events as decoded,
    /// as the OCR worker reads them.
    var upscaling: (request: BitmapSubtitleUpscaling.Request, streams: [Int32])? = nil

    var isEmpty: Bool { jobs.allSatisfy { $0.packets.isEmpty } }

    func decode() -> [[EmbeddedSubtitleDecoder.SubtitleEvent?]] {
        var decoded = jobs.map { job in
            job.packets.map { AetherEngine.decodeStoredSubtitlePacket($0, with: job.decoder) }
        }
        if let upscaling {
            for k in decoded.indices {
                BitmapSubtitleUpscaling.shared.upscale(&decoded[k], stream: upscaling.streams[k], request: upscaling.request)
            }
        }
        return decoded
    }
}
