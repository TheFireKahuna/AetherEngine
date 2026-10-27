import Foundation

// Phase D: selection-armed worker feeding a bitmap track's native WebVTT rendition with
// OCR-recognized text cues, so PGS/DVB/DVD subtitles survive PiP / AirPlay / external display
// on the native path. Packet source is the session SubtitlePacketStore: an indexed stream's window is
// pulled by the tick itself, a pumped one's kept ahead by the worker's demand on the pump; the tick
// plans and resolves on the MainActor, decodes off it (AE#628), and Vision runs on a dedicated thread.
extension AetherEngine {

    /// Arm for the selected embedded bitmap track. The per-ordinal cursor survives re-arming.
    func startSubtitleOCRWorker(ordinal: Int, streamIndex: Int32) {
        cancelSubtitleOCRWorker()
        guard let store = nativeStore(atOrdinal: ordinal) else { return }
        subtitleOCRArmedOrdinal = ordinal
        // A pumped stream has to be in the packet store before the worker gets there: the pump reads a
        // margin past the window, as far as the player asks the rendition. An indexed one is pulled by each
        // tick.
        subtitleSource?.demand(.ocr, streams: [streamIndex], lead: { playhead in
            Self.subtitleReadAhead(base: Self.subtitleOCRReadAheadSeconds, playhead: playhead,
                                   requested: store.furthestRequestedSourceSeconds())
        })
        let language = ordinal < nativeSubtitleTrackTable.count
            ? nativeSubtitleTrackTable[ordinal].language : nil
        // A forced-only rendition (`LoadOptions.forcedSubtitleTrack`) keeps just the compositions the
        // track flags as forced, dropped before recognition so the rest costs no OCR.
        let forcedOnly = ordinal < nativeSubtitleTrackTable.count && nativeSubtitleTrackTable[ordinal].forcedCuesOnly
        EngineLog.emit("[SubtitleOCR] worker armed: ordinal=\(ordinal) stream=\(streamIndex) forcedOnly=\(forcedOnly)", category: .engine)
        subtitleOCRWorkerTask = BlockingWork.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                // AE#628: plan on the MainActor, decode here, off it, then resolve ends back on it.
                // The decode is the bitmap blit, the heaviest frame of the report's profile.
                let planned = await MainActor.run { [weak self] () -> SubtitleOCRTickPlan? in
                    guard !Task.isCancelled, let self else { return nil }
                    return self.subtitleOCRPlanTick(ordinal: ordinal, streamIndex: streamIndex)
                }
                let decoded = planned?.decodeHandoff.decode().first ?? []
                let (batch, read) = await MainActor.run { [weak self] () -> ([SubtitleCue], (from: Double, through: Double)?) in
                    guard !Task.isCancelled, let self, let planned else { return ([], nil) }
                    var batch = self.subtitleOCRFinishTick(planned, events: decoded)
                    if forcedOnly { batch = batch.filter(\.isForced) }
                    self.subtitleOCRBatchInFlight = !batch.isEmpty
                    return (batch, self.subtitleOCRReadSpan(planned))
                }
                if !batch.isEmpty {
                    await SubtitleImageOCR.appendRecognized(cues: batch, language: language, to: store)
                    await MainActor.run {
                        if !Task.isCancelled { self.subtitleOCRBatchInFlight = false }
                    }
                }
                // Only once its lines are in the store: the reading is what the pre-fill and the segment
                // server take as proof that a stretch with no line in it truly has none.
                if let read, !Task.isCancelled { store.noteRead(from: read.from, through: read.through) }
                try? await Task.sleep(nanoseconds: AetherEngine.subtitleDrainTickNanoseconds)
            }
        }
    }

    /// Whether AVKit draws the rendition: only while the host says the picture is off its own view hierarchy (PiP,
    /// AirPlay, an external display), and never while a Picture in Picture window shows the software overlay, whose
    /// pictures carry their own subtitles.
    var nativeRenditionIsDisplayed: Bool {
        nativeSubtitleRenderingRequested && !(pictureInPictureActive && softwareOverlay != nil)
    }

    /// The selected bitmap track's OCR rendition only matters while AVKit draws it, so the worker follows where the
    /// picture is instead of the selection alone. Armed, it raises the subtitle source's demand to
    /// `subtitleOCRReadAheadSeconds`, and on Matroska that read pulls every cluster: measured upstream on a 4K remux,
    /// 434 MB of prefetch in 90 s against 17 MB without it, which a viewer who never left fullscreen paid for nothing.
    /// A worker a forced rendition armed (`fillForcedRendition`) is the player's request and is left to it.
    func syncSubtitleOCRWithNativeRendition() {
        let selected: Int? = activeEmbeddedSubtitleStreamIndex >= 0
            ? Self.nativeSubtitleOrdinal(forActiveTrack: Int(activeEmbeddedSubtitleStreamIndex),
                                         in: nativeSubtitleTrackTable, forced: forcedSubtitleSelection)
            : nil
        let ocrOrdinal = selected.flatMap { $0 < nativeSubtitleTrackTable.count && nativeSubtitleTrackTable[$0].needsOCR ? $0 : nil }
        if let ocrOrdinal, nativeRenditionIsDisplayed {
            guard subtitleOCRArmedOrdinal != ocrOrdinal else { return }
            startSubtitleOCRWorker(ordinal: ocrOrdinal, streamIndex: activeEmbeddedSubtitleStreamIndex)
        } else if let ocrOrdinal, subtitleOCRArmedOrdinal == ocrOrdinal {
            cancelSubtitleOCRWorker()
            resumeForcedRenditionFill()
        }
    }

    /// `base`, or further when the player has asked the armed rendition for windows beyond it.
    func subtitleOCRDemandLead(base: Double, playhead: Double) -> Double {
        let requested = subtitleOCRArmedOrdinal.flatMap { nativeStore(atOrdinal: $0)?.furthestRequestedSourceSeconds() }
        return Self.subtitleReadAhead(base: base, playhead: playhead, requested: requested)
    }

    /// Completed coverage survives a re-arm; an abandoned batch must be collected again.
    func cancelSubtitleOCRWorker() {
        if subtitleOCRBatchInFlight, let ordinal = subtitleOCRArmedOrdinal {
            subtitleOCRCursors.removeValue(forKey: ordinal)
            subtitleOCRPendingStates.removeValue(forKey: ordinal)
            subtitleOCRReadStarts.removeValue(forKey: ordinal)
        }
        subtitleOCRBatchInFlight = false
        subtitleOCRArmedOrdinal = nil
        subtitleSource?.withdraw(.ocr)
        subtitleOCRWorkerTask?.cancel()
        subtitleOCRWorkerTask = nil
        subtitleOCRSidecarFillTask?.cancel()
        subtitleOCRSidecarFillTask = nil
        subtitleOCRDecoder = nil
        subtitleOCRLastTickUptime = nil   // #271
    }

    /// Load/stop teardown: forget covered-region state too (new session, new axis).
    func resetSubtitleOCRState() {
        cancelSubtitleOCRWorker()
        subtitleOCRCursors.removeAll()
        subtitleOCRPendingStates.removeAll()
        subtitleOCRReadStarts.removeAll()
    }

    /// MainActor half before the decode: plan the window (drainer pacing, larger lead) and pick the
    /// stored packets (bounded per tick). The decode runs off the MainActor (AE#628) and
    /// `subtitleOCRFinishTick` resolves composition ends into CLOSED cues for off-main OCR.
    fileprivate func subtitleOCRPlanTick(ordinal: Int, streamIndex: Int32) -> SubtitleOCRTickPlan? {
        guard let packetStore = activeSubtitlePacketStore else { return nil }
        let playhead = subtitleDrainPlayhead()
        let landingGeneration = subtitleLandingGeneration
        // #271: same rule as the overlay drainer, a tick that ran long is not a seek.
        let tickUptime = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let elapsed = subtitleOCRLastTickUptime.map { tickUptime - $0 } ?? 0
        subtitleOCRLastTickUptime = tickUptime
        let plan = SubtitleOverlayDrainer.drainPlan(
            cursor: subtitleOCRCursors[ordinal], playhead: playhead,
            lead: subtitleOCRDemandLead(base: Self.subtitleOCRLeadSeconds, playhead: playhead),
            backscan: Self.subtitleDrainBackscanSeconds,
            repositioning: subtitleRepositioning(elapsedSinceLastPlan: elapsed))
        let window: (from: Double, through: Double)
        switch plan {
        case .idle:
            subtitleOCRCursors[ordinal]?.lastPlayhead = playhead
            return SubtitleOCRTickPlan(ordinal: ordinal, streamIndex: streamIndex, pulled: false,
                                       playhead: playhead, landingGeneration: landingGeneration,
                                       plan: plan, window: (playhead, playhead), decoder: nil, batch: [])
        case .decode(let from, let through):
            window = (from, through)
        case .resetAndDecode(let from, let through):
            subtitleOCRDecoder = nil
            window = (from, through)
        }
        if subtitleOCRDecoder == nil {
            subtitleOCRDecoder = makeSubtitleDrainDecoder(streamIndex: streamIndex)
        }
        guard let decoder = subtitleOCRDecoder else {
            return SubtitleOCRTickPlan(ordinal: ordinal, streamIndex: streamIndex, pulled: false,
                                       playhead: playhead, landingGeneration: landingGeneration,
                                       plan: .idle, window: window, decoder: nil, batch: [])
        }
        // Layer 3 step 3: an indexed stream is pulled, and decodes what the pulls have brought.
        let pulls = subtitleStreamIsPulled(streamIndex)
        var decodableThrough = window.through
        if pulls {
            subtitleSource?.pull(streamIndex, from: window.from, through: window.through, focus: playhead)
            decodableThrough = min(window.through,
                                   packetStore.pulledReach(streamIndex: streamIndex, from: window.from) ?? -.infinity)
        }
        let entries = decodableThrough >= window.from
            ? packetStore.entries(streamIndex: streamIndex, from: window.from, through: decodableThrough) : []
        // #271: the cap has to fall on a PTS boundary. The cursor is a bare PTS advanced by
        // `lastDecodedPts.nextUp`, so a cut inside a same-PTS run skips its remainder instead of
        // resuming it next tick. One composition per PTS is the norm on a bitmap track, but a
        // container that splits a display set across packets (see splitDisplaySetSubtitleStreamIndices)
        // shares one, and half a display set OCRs to nothing.
        let batchEnd = SubtitleOverlayDrainer.batchEnd(
            count: entries.count, cap: Self.subtitleOCRMaxPacketsPerTick,
            ptsAt: { entries[$0].ptsSeconds })
        return SubtitleOCRTickPlan(ordinal: ordinal, streamIndex: streamIndex, pulled: pulls,
                                   playhead: playhead, landingGeneration: landingGeneration,
                                   plan: plan, window: window, decoder: decoder, batch: entries[..<batchEnd],
                                   windowComplete: batchEnd == entries.count)
    }

    /// The stretch a finished tick has read for its rendition: from where this run of the worker began
    /// through the end of what it decoded, cut back to where the reading stops, the pulls' or the harvest's (a packet
    /// not yet harvested is a line not yet seen) and to the earliest composition still open (its line
    /// reaches the store only when its end is known). Nil for a tick that read nothing or was dropped.
    fileprivate func subtitleOCRReadSpan(_ tick: SubtitleOCRTickPlan) -> (from: Double, through: Double)? {
        let ordinal = tick.ordinal
        guard let decoder = tick.decoder, subtitleOCRArmedOrdinal == ordinal, subtitleOCRDecoder === decoder,
              let packetStore = activeSubtitlePacketStore else { return nil }
        let isReset: Bool
        switch tick.plan {
        case .idle: return nil
        case .decode: isReset = false
        case .resetAndDecode: isReset = true
        }
        if isReset || subtitleOCRReadStarts[ordinal] == nil { subtitleOCRReadStarts[ordinal] = tick.window.from }
        // What was read: for a pulled stream the pulls themselves, for a pumped one the harvest's reading.
        let reach = tick.pulled
            ? packetStore.pulledReach(streamIndex: tick.streamIndex, from: tick.window.from)
            : packetStore.harvestReach(from: tick.window.from)
        guard let start = subtitleOCRReadStarts[ordinal], let reach else { return nil }
        var through = min(tick.window.through, reach)
        if !tick.windowComplete, let last = tick.batch.last?.ptsSeconds { through = min(through, last) }
        if let open = subtitleOCRPendingStates[ordinal]?.earliestPendingStart { through = min(through, open) }
        return through > start ? (start, through) : nil
    }

    /// MainActor half after the decode: resolve composition ends and return the CLOSED cues. A
    /// batch whose decoder was replaced while it decoded (seek, re-arm) is dropped with its cursor
    /// unmoved, so the next tick plans that window again.
    fileprivate func subtitleOCRFinishTick(_ tick: SubtitleOCRTickPlan,
                                           events: [EmbeddedSubtitleDecoder.SubtitleEvent?]) -> [SubtitleCue] {
        let ordinal = tick.ordinal
        var pending = subtitleOCRPendingStates[ordinal] ?? SubtitleOCRPendingState()
        var closed: [SubtitleCue] = []
        defer {
            closed.append(contentsOf: pending.expired(asOf: tick.playhead))
            subtitleOCRPendingStates[ordinal] = pending
        }
        guard let decoder = tick.decoder else { return closed }
        guard subtitleOCRArmedOrdinal == ordinal, subtitleOCRDecoder === decoder else { return closed }
        if case .resetAndDecode = tick.plan { pending = SubtitleOCRPendingState() }
        var lastDecoded = subtitleOCRCursors[ordinal]?.lastDecodedPts
        for (entry, decoded) in zip(tick.batch, events) {
            if let event = decoded {
                closed.append(contentsOf: pending.consume(
                    eventPts: entry.ptsSeconds, cues: event.cues, trimAt: event.pgsTrimAt))
            }
            lastDecoded = entry.ptsSeconds
        }
        if case .resetAndDecode = tick.plan, tick.batch.isEmpty {
            lastDecoded = tick.window.from
        }
        subtitleOCRCursors[ordinal] = SubtitleDrainCursor(
            lastDecodedPts: lastDecoded ?? tick.window.from, lastPlayhead: tick.playhead,
            landingGeneration: tick.landingGeneration)
        return closed
    }

    /// #88 external .sup path: fill the needsOCR ordinal's store from the overlay sidecar
    /// decode's OWN image cues (no second download); markFinished so the PiP pre-fill and the
    /// whole-file .vtt handler see complete coverage.
    func startSidecarOCRFillIfNeeded(externalTrackID: Int?, cues: [SubtitleCue]) {
        guard let id = externalTrackID,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: id, in: nativeSubtitleTrackTable),
              nativeSubtitleTrackTable[ordinal].needsOCR,
              let store = nativeStore(atOrdinal: ordinal),
              !store.isFinished else { return }
        let language = nativeSubtitleTrackTable[ordinal].language
        subtitleOCRSidecarFillTask?.cancel()
        EngineLog.emit("[SubtitleOCR] sidecar fill starting: track=\(id) cues=\(cues.count)", category: .engine)
        subtitleOCRSidecarFillTask = BlockingWork.detached(priority: .utility) {
            await SubtitleImageOCR.appendRecognized(cues: cues, language: language, to: store)
            if !Task.isCancelled { store.markFinished() }
        }
    }
}

/// AE#628: one OCR worker tick between its MainActor halves. `decoder` is nil for a tick that
/// decodes nothing (idle, or no decoder could be built), which still expires pending cues.
fileprivate struct SubtitleOCRTickPlan: @unchecked Sendable {
    let ordinal: Int
    let streamIndex: Int32
    /// The stream is pulled from the index (layer 3 step 3).
    let pulled: Bool
    let playhead: Double
    /// The landing count the tick planned against (`SubtitleRepositioning.signalled`).
    let landingGeneration: UInt64
    let plan: SubtitleDrainPlan
    let window: (from: Double, through: Double)
    let decoder: EmbeddedSubtitleDecoder?
    let batch: ArraySlice<StoredSubtitlePacket>
    /// The batch is every stored packet in the window (the per-tick cap did not cut it).
    var windowComplete = false

    var decodeHandoff: SubtitleDrainDecodeHandoff {
        SubtitleDrainDecodeHandoff(jobs: decoder.map { [($0, batch)] } ?? [])
    }
}
