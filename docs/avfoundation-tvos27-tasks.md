# AVFoundation / Core Audio on tvOS 27: open tasks

An audit of the engine (AE) and Sodalite (SO) against the tvOS 27.2 SDK (Xcode 27.2 beta), 2026-10-22.
Each item was checked against the code and the SDK headers. Line numbers are from when the audit was done.

Items 1–6 are implemented and unit-tested, but haven't been tried on the TV yet (2026-10-22).

## Fix

1. **[x] Music overwrites the video session.** SO `MusicPlaybackCoordinator.swift:291` runs
   `setCategory(.playback, mode: .default)` before every track. The engine declares
   `.moviePlayback` with the `.longFormAudio` policy (#24) only once, at init (AE `AetherEngine.swift:3874`).
   So every video after music ran in mode `.default`, and most likely with the default policy as well.
   Fix: the engine declares the category on every load (`.default` for `audioOnly`, `.moviePlayback`
   otherwise) on the session transition queue; Sodalite no longer touches the category.
2. **[x] The audio renderer's output configuration changes are ignored.** AE `Audio/AudioOutput.swift`
   observes only `…WasFlushedAutomatically`. The header for `AVSampleBufferAudioRendererOutputConfigurationDidChangeNotification`
   says to flush and re-enqueue from the playhead, so that the hardware is set up again for the enqueued format.
   Triggers include an HDMI input switch, a soundbar power cycle, and the Atmos keep-alive player starting
   next to the renderer.
3. **[x] A failed renderer is never escalated.** A failed video renderer gets flushed on every enqueue
   (AE `Renderer/SampleBufferRenderer.swift:794`). A failed audio renderer is only logged, and only in DEBUG
   builds. Both should go through the reload-at-position recovery.
   Done as each renderer's header intends (`RendererRecoveryLadder`):
   - video: flush in place, then reposition, then rebuild, then fail;
   - audio: replace the failed renderer under the running synchronizer (`AudioOutput.replaceFailedRenderer`), then
     rebuild, then fail. Its header calls the failed status terminal and names no reset, and a flush does not
     revive one (macOS 27, `research/renderer-receiver`).
4. **[x] The software route has no Now Playing and no remote commands.** SO `PlayerHostController.swift`
   detaches AVKit's player on that route, so nothing publishes Now Playing, and play/pause/seek from
   Control Center, the iPhone remote or Siri do nothing for Dolby Vision FEL or TrueHD→APAC titles.
5. **[x] Returning to the foreground activates the session directly.** SO `PlayerHostController.swift:1070,1083`
   call `setActive(true)` on the main thread, bypassing the engine's transition queue. On the native path
   this is the activation #24 forbids: it latches an idle HDMI link at stereo.
6. **[x] A media-services reset leaves the category undeclared.** AE `noteMediaServicesReset` (`AetherEngine.swift:1112`)
   rebuilds the players, but the category, mode, policy and multichannel flag are lost too
   (QA1749). With item 1's per-load declaration this needs a forced re-declare.

   The recovery climbs `RendererRecoveryLadder`: reposition, then a rebuild with new renderers, then the session's
   failure. It covers the software host and the audio-only FFmpeg host.

## Modernise

7. **[x] Move renderer I/O onto the tvOS 27 `Receiver`, where it is a drop-in.** Researched 2026-10-22: the SDK,
   the overlay and AVFCore decompiled from macOS 27.0.1, and a probe. Full notes:
   `research/renderer-receiver/README.md`.
   - The receiver is a Swift wrapper in the overlay over the same renderer, Fig callbacks and notifications.
     It adds no capability. `flush(fromSourceTime:)` is `flushFromSourceTime:` (tvOS 11), so the lip-sync
     offset can apply at once with or without it.
   - The awaitable `enqueue` cannot replace the 5 ms polls (`SoftwarePlaybackHost.swift:3062,3707,3752`).
     Those gates wait before a compressed packet is decoded, and the receiver can only wait with a decoded
     buffer in hand. Keep the deprecated readiness check there unless the demux loop is redesigned.
   - Video decode results don't apply: the engine enqueues decoded pixel buffers.
   - Done 2026-10-22: the audio renderer (`AudioRendererIO`), the video renderer (`VideoRendererIO`) and the
     held still frame go through receivers on 27; the renderer's own calls remain only in their pre-27 branches
     and in the readiness reads. A/B through `usesSampleBufferReceivers`, per session.
     - Events come from where the receiver delivers them (macOS 27.0.1): the automatic flush and the failure
       only with the next enqueue's result, so the automatic flush is handled inside that enqueue; the output
       reconfiguration through the event stream at once (its repeat in the result is ignored, and a result the
       stream missed is logged).
     - The receiver's removing flush is async only and lands after the next line even from `Task.immediate`,
       so the picture is removed in order with `flush()` and an empty-media marker. Not seen on screen: the
       terminal has no screen-recording permission.
     - The held still frame gets its own synchronizer and a timed frame: the header advises against
       `DisplayImmediately` with a synchronizer.
   - The lip-sync offset applies at once (done 2026-10-22): a change on the software path is in force a
     quarter-second past the playhead through the renderer's partial flush, with no seek; a renderer that
     declines the flush falls back to the seek.
   - Gotcha: a cancelled waiting enqueue reports `.cancelledDueToFlush` without flushing or enqueueing.
   - Finding for item 3, since acted on: on macOS a flush does not revive a failed audio renderer, so the ladder
     now replaces it instead of repositioning. Not yet seen on tvOS.
8. **[ ] Interruptions through `didBecomeInactiveNotification` and `resumptionRecommendationNotification` (27).**
   `interruptionNotification` and its keys are deprecated, and its reason key isn't available on tvOS.
   `DeactivationContext` tells `.routeDisconnected` (an HDMI/eARC drop) apart from Siri or a call.
9. **[x] The item logs through tvOS 27's fetch.** Done 2026-10-22 (`ItemLogs`). The SDK deprecates `accessLog()`
   and `errorLog()` for `fetchAccessLogWithCompletionHandler:` / `fetchErrorLogWithCompletionHandler:` (Swift:
   async `accessLog()` / `errorLog()`), not for `AVMetricEventStream`, whose events carry neither the byte and
   dropped-frame counters nor the HTTP status codes the engine reads.
   - The item-failure handler no longer reads the error log on the main actor: it awaits it, and only when the
     item's own error reads as a master rejection, the one case the log can still overrule (a -12642).
   - The telemetry sampler and the diagnostic lanes wait on the fetch for at most 2 s on 27, so a stranded media
     server costs a reading instead of the thread.
10. **[ ] Small items:**
    - Done: `AVPlayerItemVideoOutput` goes through `ItemVideoOutput`, which uses the typed `CVPixelBufferAttributes` init and `pixelBufferAndDisplayTime(forItemTime:)` from 26 on.
    - `AVDisplayManagerModeSwitchSettingsChangedNotification` and `eligibleForHDRPlaybackDidChangeNotification` aren't observed.
    - The stats overlay shows the source's "Atmos", not the output's `renderingMode` or channel count.

## Experiments

- Display criteria are built from a synthetic 3840x2160 format description with no `dvcC`, mastering or light-level data (`DisplayCriteriaController.swift:816`). Try the stream's real description and judge the result by eye on the G5.
- APAC on the software route without `setPreferredOutputNumberOfChannels`: does MAT come up without the keep-alive player?
- Control Center skip buttons on the AVKit path through its private `_nowPlayingSession` `remoteCommandCenter`.

## Not applicable, or already done

- Unchanged since tvOS 18:
  - No new Dolby Vision or Atmos API since tvOS 18.
  - `availableHDRModes` is deprecated, but there is still no per-mode replacement.
- Already used:
  - `sampleBufferRenderer`
  - `presentationTimeExpectation`
  - the public `AVDisplayCriteria` init
  - `appliesPerFrameHDRDisplayMetadata`
  - `audioTimePitchAlgorithm`
  - follows `renderingModeChangeNotification`
  - APAC `contentSource`/DRC settings
- Not available on tvOS: `audioOutputDeviceUniqueID`, `intendedSpatialAudioExperience`, `.longFormVideo`.
