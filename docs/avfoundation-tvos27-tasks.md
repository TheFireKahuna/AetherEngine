# AVFoundation / Core Audio on tvOS 27: open tasks

An audit of the engine (AE) and Sodalite (SO) against the tvOS 27.2 SDK (Xcode 27.2 beta), 2026-10-22.
Each item was checked against the code and the SDK headers. Line numbers are from when the audit was done.

Items 1–5 are implemented and unit-tested, but haven't been tried on the TV yet (2026-10-22).

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
4. **[x] The software route has no Now Playing and no remote commands.** SO `PlayerHostController.swift`
   detaches AVKit's player on that route, so nothing publishes Now Playing, and play/pause/seek from
   Control Center, the iPhone remote or Siri do nothing for Dolby Vision FEL or TrueHD→APAC titles.
5. **[x] Returning to the foreground activates the session directly.** SO `PlayerHostController.swift:1070,1083`
   call `setActive(true)` on the main thread, bypassing the engine's transition queue. On the native path
   this is the activation #24 forbids: it latches an idle HDMI link at stereo.
6. **[ ] A media-services reset leaves the category undeclared.** AE `noteMediaServicesReset` (`AetherEngine.swift:1112`)
   rebuilds the players, but the category, mode, policy and multichannel flag are lost too
   (QA1749). With item 1's per-load declaration this needs a forced re-declare.

   Follow-up: the audio-only FFmpeg host (`AudioPlaybackHost`) uses the same `AudioOutput` but doesn't wire
   `onRendererFailed` yet, so a failure there is only logged.

## Modernise

7. **[ ] Use the tvOS 27 renderer `Receiver` for all renderer I/O.** The renderers are attached with
   `sampleBufferReceiver(adding:)` but still fed with `enqueue`, `flush` and `isReadyForMoreMediaData`,
   which are deprecated for Swift in 27. The receiver offers:
   - an `EnqueueResult` per buffer (`.enqueuedWithSuggestedFlush`, `.cancelledDueToFlush`);
   - `flush(fromSourceTime:)`, so a lip-sync offset change applies at once;
   - an awaitable `enqueue`, in place of the 5 ms back-pressure poll (`SoftwarePlaybackHost.swift:3700`).
   Large change; A/B it on the device.
8. **[ ] Interruptions through `didBecomeInactiveNotification` and `resumptionRecommendationNotification` (27).**
   `interruptionNotification` and its keys are deprecated, and its reason key isn't available on tvOS.
   `DeactivationContext` tells `.routeDisconnected` (an HDMI/eARC drop) apart from Siri or a call.
9. **[ ] `AVMetricEventStream` in place of polling `accessLog()`/`errorLog()`** (deprecated in 27). A synchronous
   `errorLog()` call on the main actor in `NativeAVPlayerHost.swift:1081` (item failed) can block.
10. **[ ] Small items:**
    - `AVPlayerItemVideoOutput` uses the dictionary init and `copyPixelBuffer` (`NativeAVPlayerHost.swift:1850,2323`).
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
