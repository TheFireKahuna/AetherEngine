import AVFoundation

/// AVFoundation's legible selection as the one record of what subtitle shows on the native route
/// (docs/source-pipeline.md, layer 3 step 2).
///
/// Whoever makes the selection, the viewer in AVKit's menu, the host through `selectSubtitleTrack`, or
/// tvOS by itself (a forced rendition when the viewer has no subtitles on, SDH under "Closed Captions +
/// SDH", automatic captions), the engine follows it:
///
/// - a text track is drawn by AVKit, from its rendition, in the viewer's caption style;
/// - a track AVKit cannot draw as authored (styled ASS, a bitmap track, forced lines included) is drawn by
///   the host's overlay from the engine's cues, and AVKit is kept from drawing its rendition by the item's
///   legible output (`suppressesPlayerRendering`);
/// - while the rendition is the display (`setNativeSubtitleRendering(true)`: PiP, AirPlay, an external
///   display) nothing is suppressed, and AVKit draws whatever is selected.
///
/// Suppression is armed before the item plays, so a track tvOS selects by itself never shows through.
/// Switching it on while AVKit has a line up leaves that line on screen for good, so the line is cleared
/// first (deselect, a beat, the change, reselect); lifting it needs no such care. Both are device-verified
/// on tvOS 27 (DolbyVisionPulse, https://github.com/TheFireKahuna/DolbyVisionPulse, `SEQ=subs`, 2026-10-25).
extension AetherEngine {

    /// Whether the overlay draws the track at `ordinal` of the rendition table rather than AVKit: every track while a
    /// Picture in Picture window shows the software overlay; a bitmap track; ASS when the host draws its styling
    /// (`LoadOptions.preserveASSMarkup`); and a text track while the subtitle delay differs from the one its rendition
    /// serves, which only the overlay can apply at once.
    func overlayDrawsNativeTrack(ordinal: Int) -> Bool {
        guard ordinal < nativeSubtitleTrackTable.count else { return false }
        // A Picture in Picture window showing the software overlay shows nothing AVKit draws.
        if pictureInPictureActive, softwareOverlay != nil { return true }
        let entry = nativeSubtitleTrackTable[ordinal]
        if entry.needsOCR { return true }
        if loadedOptions.preserveASSMarkup, let id = entry.sourceStreamIndex ?? entry.externalID,
           let codec = subtitleTracks.first(where: { $0.id == id })?.codec.lowercased(),
           codec == "ass" || codec == "ssa" {
            return true
        }
        return currentSubtitleDelaySeconds != servedSubtitleDelaySeconds
    }

    /// Arms what the engine keeps on each item the native host attaches (`NativeAVPlayerHost.onDidAttachItem`,
    /// so an in-place swap's item too): the observer of its landings, which the subtitle drain follows
    /// (`subtitleLanded`), and the selection: its suppressing legible output, and the observer that follows
    /// every selection change. A session without native renditions has no legible group, and the overlay
    /// draws its subtitles as before.
    ///
    /// The landings come from `AVPlayerItemTimeJumpedNotification` rather than the legible output's
    /// `outputSequenceWasFlushed:`: both arrive for every seek, on the main queue with the seek's completion
    /// and the item time already at the target, but the flush only on an item with legible media (measured,
    /// macOS 27: a media playlist without subtitles posted every jump and flushed nothing).
    func armNativeItemObservers(on item: AVPlayerItem) {
        disarmNativeSubtitleSelection()
        sourcePlayheadClock.follow(item: item, shift: nativeSourceSeconds(atItemSeconds: 0))
        nativeItemTimeJumpObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.timeJumpedNotification, object: item, queue: .main
        ) { [weak self, weak item] _ in
            MainActor.assumeIsolated {
                guard let item else { return }
                self?.subtitleLanded(atItemSeconds: item.currentTime().seconds)
            }
        }
        guard !nativeSubtitleTrackTable.isEmpty else { return }
        let output = AVPlayerItemLegibleOutput()
        output.suppressesPlayerRendering = !nativeSubtitleRenderingRequested
        item.add(output)
        nativeSubtitleLegibleOutput = output
        nativeSubtitleSelectionItem = item
        nativeSubtitleFollowedKey = nil
        nativeSubtitleSelectionObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.followNativeSubtitleSelection() }
        }
        nativeSubtitleSelectionTask = Task { @MainActor [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.nativeSubtitleSelectionItem === item else { return }
            self.nativeSubtitleSelectionGroup = group
            self.followNativeSubtitleSelection()
        }
    }

    /// Drops the observers, the output and the record of what was followed. Called by the next load, by
    /// `stopInternal`, and by `armNativeItemObservers` itself.
    func disarmNativeSubtitleSelection() {
        if let observer = nativeItemTimeJumpObserver {
            NotificationCenter.default.removeObserver(observer)
            nativeItemTimeJumpObserver = nil
        }
        subtitleLanding = nil
        nativeSubtitleSelectionTask?.cancel()
        nativeSubtitleSelectionTask = nil
        if let observer = nativeSubtitleSelectionObserver {
            NotificationCenter.default.removeObserver(observer)
            nativeSubtitleSelectionObserver = nil
        }
        if let output = nativeSubtitleLegibleOutput, let item = nativeSubtitleSelectionItem {
            item.remove(output)
        }
        nativeSubtitleLegibleOutput = nil
        nativeSubtitleSelectionItem = nil
        nativeSubtitleSelectionGroup = nil
        nativeSubtitleFollowedKey = nil
        primarySubtitleDrawnByAVKit = false
    }

    /// Whether the native route's selection is armed: the active item has a legible output the engine
    /// owns, so a pick goes through AVFoundation's selection rather than straight to the overlay.
    var nativeSubtitleSelectionArmed: Bool {
        nativeSubtitleSelectionItem != nil && nativeSubtitleSelectionItem === currentAVPlayer?.currentItem
    }

    /// Applies the selection AVFoundation holds now. Idempotent: the engine's own selects fire the same
    /// notification.
    func followNativeSubtitleSelection() {
        guard let item = nativeSubtitleSelectionItem, item === currentAVPlayer?.currentItem,
              let group = nativeSubtitleSelectionGroup else { return }
        guard let option = item.currentMediaSelection.selectedMediaOption(in: group),
              let index = group.options.firstIndex(of: option),
              let ordinal = Self.nativeOrdinal(forOptionAt: index,
                                               optionLanguageTags: group.options.map { $0.extendedLanguageTag },
                                               trackLanguages: nativeSubtitleTracks.map { $0.language }),
              ordinal < nativeSubtitleTrackTable.count else {
            guard nativeSubtitleFollowedKey != .nothing else { return }
            nativeSubtitleFollowedKey = .nothing
            primarySubtitleDrawnByAVKit = false
            EngineLog.emit("[NativeSubtitles] no legible option selected", category: .engine)
            if activeSubtitleTrackIndex != nil, Self.nativeSubtitleOrdinal(
                forActiveTrack: activeSubtitleTrackIndex!, in: nativeSubtitleTrackTable,
                forced: forcedSubtitleSelection) != nil {
                endPrimarySubtitleOverlay(reason: .subtitlesCleared)
            }
            return
        }
        let entry = nativeSubtitleTrackTable[ordinal]
        let overlay = overlayDrawsNativeTrack(ordinal: ordinal)
        let key = NativeSubtitleFollowedKey.option(ordinal: ordinal, overlay: overlay)
        guard key != nativeSubtitleFollowedKey else { return }
        nativeSubtitleFollowedKey = key
        let forced = option.hasMediaCharacteristic(.containsOnlyForcedSubtitles) || entry.forcedCuesOnly
        guard let trackID = entry.sourceStreamIndex ?? entry.externalID else { return }
        EngineLog.emit("[NativeSubtitles] following \"\(option.displayName)\": track \(trackID) "
                       + "ordinal \(ordinal), drawn by \(overlay ? "the overlay" : "AVKit")"
                       + (forced ? ", forced lines" : ""), category: .engine)
        Task { @MainActor [weak self] in
            await self?.setNativeSubtitleSuppressed(overlay && self?.nativeSubtitleRenderingRequested == false)
        }
        primarySubtitleDrawnByAVKit = !overlay
        let startAt = pendingNativeSubtitleStartAt ?? sourceTime
        pendingNativeSubtitleStartAt = nil
        if overlay {
            // The overlay's own path, entered as the selection's consequence rather than as a new pick.
            guard !overlayFeedsPrimary(trackID: trackID, forced: forced) else { return }
            forcedSubtitleSelection = forced
            applySubtitleTrack(index: trackID, startAt: startAt)
        } else {
            // AVKit draws it: the engine keeps the track as the active one and feeds the overlay nothing.
            endPrimarySubtitleOverlay(reason: .nativeRenditionDraws, keepingActive: true)
            forcedSubtitleSelection = forced
            isSubtitleActive = true
            activeSubtitleTrackIndex = trackID
            activeEmbeddedSubtitleStreamIndex = entry.sourceStreamIndex.map(Int32.init) ?? -1
        }
    }

    /// What `followNativeSubtitleSelection` last applied, so a repeat of the same selection changes nothing.
    enum NativeSubtitleFollowedKey: Equatable {
        case nothing
        case option(ordinal: Int, overlay: Bool)
    }

    /// Whether the overlay is already fed for `trackID` with that forcedness: an embedded track's drain
    /// target, or an external track's sidecar decode.
    func overlayFeedsPrimary(trackID: Int, forced: Bool) -> Bool {
        guard isSubtitleActive, activeSubtitleTrackIndex == trackID, forcedSubtitleSelection == forced else { return false }
        return subtitleDrainTargets[.primary] == Int32(trackID) || sidecarTask != nil
    }

    /// Ends the overlay's feed for the primary track. `keepingActive`: the track stays the active one
    /// because AVKit draws it.
    func endPrimarySubtitleOverlay(reason: SubtitleDrainStopReason, keepingActive: Bool = false) {
        cancelSidecarTask()
        cancelSubtitleOCRWorker()
        clearSubtitleDrainTarget(channel: .primary, reason: reason)
        subtitleCues = []
        pgsStaleArrivalGates[.primary]?.reset()   // #100
        sidecarASSHeader = nil
        isLoadingSubtitles = false
        guard !keepingActive else { return }
        activeEmbeddedSubtitleStreamIndex = -1
        activeSubtitleTrackIndex = nil
        isSubtitleActive = false
    }

    /// Switches AVKit's drawing of the selected rendition. Switching it off while a line is up would leave
    /// that line on screen, so the line is cleared first.
    func setNativeSubtitleSuppressed(_ suppressed: Bool) async {
        guard let output = nativeSubtitleLegibleOutput, output.suppressesPlayerRendering != suppressed else { return }
        guard suppressed, let item = nativeSubtitleSelectionItem, let group = nativeSubtitleSelectionGroup,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else {
            output.suppressesPlayerRendering = suppressed
            EngineLog.emit("[NativeSubtitles] AVKit \(suppressed ? "suppressed" : "draws the rendition")",
                           category: .engine)
            return
        }
        // The engine's own deselect and reselect fire the selection notification; the followed key keeps
        // them from re-entering the selection's consequences.
        item.select(nil, in: group)
        try? await Task.sleep(nanoseconds: 100_000_000)
        output.suppressesPlayerRendering = true
        if item.currentMediaSelection.selectedMediaOption(in: group) == nil {
            item.select(selected, in: group)
        }
        EngineLog.emit("[NativeSubtitles] AVKit suppressed (its line cleared first)", category: .engine)
    }

    /// A host pick on the native route: the overlay starts at once, as any pick, and the matching option is
    /// selected; the selection then decides who draws. Returns false when the track has no rendition.
    func selectNativeSubtitleOption(forTrack index: Int, startAt: Double) -> Bool {
        guard nativeSubtitleSelectionArmed,
              let ordinal = Self.nativeSubtitleOrdinal(forActiveTrack: index, in: nativeSubtitleTrackTable,
                                                       forced: forcedSubtitleSelection) else { return false }
        pendingNativeSubtitleStartAt = startAt
        applySubtitleTrack(index: index, startAt: startAt)
        setNativeSubtitleSelected(track: ordinal)
        return true
    }

    /// Subtitles off on the native route: the selection goes back to AVFoundation's own, which is where
    /// tvOS shows forced lines when the audio's language calls for them.
    func selectNativeSubtitleAutomatically() {
        guard nativeSubtitleSelectionArmed, let item = nativeSubtitleSelectionItem else { return }
        nativeSubtitleReapplyOrdinal = nil
        subtitleSource?.withdraw(.rendition)
        Task { @MainActor [weak self] in
            guard let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.nativeSubtitleSelectionItem === item else { return }
            self.currentAVPlayer?.appliesMediaSelectionCriteriaAutomatically = true
            item.selectMediaOptionAutomatically(in: group)
            EngineLog.emit("[NativeSubtitles] subtitles off: selection handed back to AVFoundation "
                           + "(now \(item.currentMediaSelection.selectedMediaOption(in: group)?.displayName ?? "none"))",
                           category: .engine)
        }
    }

    /// The subtitle delay the viewer set during the session, in seconds (positive shows lines later). A text
    /// track AVKit draws cannot take it until its rendition serves it, so the overlay draws that track with
    /// it in the meantime (`overlayDrawsNativeTrack`); when the rendition becomes the display the session is
    /// rebuilt in place so the new item serves it (`setNativeSubtitleRendering`). The overlay applies the
    /// delay to what it draws; this tells the engine who draws. A delay back at the served one returns the
    /// track to AVKit, and a session-preserving reload carries it into what the next item serves.
    public func setSubtitleDelay(_ seconds: Double) {
        guard seconds.isFinite, seconds != currentSubtitleDelaySeconds else { return }
        currentSubtitleDelaySeconds = seconds
        EngineLog.emit("[NativeSubtitles] subtitle delay \(String(format: "%.2f", seconds)) s (served "
                       + "\(String(format: "%.2f", servedSubtitleDelaySeconds)) s)", category: .engine)
        nativeSubtitleFollowedKey = nil
        followNativeSubtitleSelection()
        if nativeSubtitleRenderingRequested { rebuildIfServedSubtitleDelayIsStale() }
    }

    /// While the rendition is the display it has to serve the current delay: a session whose rendition
    /// serves another is rebuilt in place (a session-preserving reload serves the viewer's delay), and the
    /// new item serves it from its first fetch.
    func rebuildIfServedSubtitleDelayIsStale() {
        guard currentSubtitleDelaySeconds != servedSubtitleDelaySeconds, !sessionPreservingReloadInFlight,
              nativeVideoSession != nil else { return }
        EngineLog.emit("[NativeSubtitles] the rendition is the display and serves a delay of "
                       + "\(String(format: "%.2f", servedSubtitleDelaySeconds)) s; rebuilding to serve "
                       + "\(String(format: "%.2f", currentSubtitleDelaySeconds)) s", category: .engine)
        Task { @MainActor [weak self] in try? await self?.reloadAtCurrentPosition() }
    }

    /// AVKit fetched rendition `ordinal`'s media playlist: it selected it. A forced rendition is filled from
    /// here (`fillForcedRendition`); a text rendition's reading starts; a full bitmap rendition is already
    /// being recognized, since a bitmap track the overlay draws arms the OCR worker with its selection.
    func nativeRenditionRequested(ordinal: Int) {
        guard ordinal < nativeSubtitleTrackTable.count else { return }
        let entry = nativeSubtitleTrackTable[ordinal]
        if entry.declaresForced {
            fillForcedRendition(ordinal: ordinal)
        } else if !entry.needsOCR, entry.sourceStreamIndex != nil, entry.externalID == nil {
            demandNativeRenditionSubtitles(.rendition, stores: nativeTextRenditionStores)
        }
    }

    /// Every forced bitmap rendition whose stream the container's index reads is recognized whole at load,
    /// before tvOS reaches for it: only the display sets the index's composition headers mark forced are
    /// decoded and recognized, and the rendition is then complete. A forced rendition of a pumped stream is
    /// recognized by the OCR worker once the player asks for it (`fillForcedRendition`).
    func fillIndexedForcedRenditions() {
        guard let source = subtitleSource else { return }
        for (ordinal, entry) in nativeSubtitleTrackTable.enumerated() where entry.declaresForced && entry.needsOCR {
            guard let stream = entry.sourceStreamIndex, let store = nativeStore(atOrdinal: ordinal),
                  indexedForcedFillTasks[ordinal] == nil else { continue }
            let language = entry.language
            indexedForcedFillTasks[ordinal] = Task { @MainActor [weak self] in
                guard case .indexed = await source.routes()[Int32(stream)],
                      let lines = await source.indexedForcedLines(stream: Int32(stream)) else {
                    self?.indexedForcedFillTasks[ordinal] = nil
                    return
                }
                await SubtitleImageOCR.appendRecognized(cues: lines.cues, language: language, to: store)
                guard !Task.isCancelled, let self else { return }
                if lines.unreadable == 0 {
                    store.noteRead(from: 0, through: max(self.duration, lines.cues.map(\.endTime).max() ?? 0))
                    store.markFinished()
                }
                EngineLog.emit("[NativeSubtitles] forced ordinal=\(ordinal) from the index: \(lines.displaySets) "
                               + "display sets, \(lines.forcedDisplaySets) forced, \(lines.cues.count) lines in "
                               + "\(lines.milliseconds) ms"
                               + (lines.unreadable > 0 ? "; \(lines.unreadable) headers unreadable, the rendition stays open" : ""),
                               category: .engine)
            }
        }
    }
}
