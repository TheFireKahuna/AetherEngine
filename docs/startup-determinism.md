# Deterministic startup

Status: proposal, revised 2026-10-24 against the code on `feat/fel-apac` and the tvOS 27.2 SDK
(Xcode 27.2, 27B5038j). The readiness gate change (step 7 of the order of work) and part of step 1 are done.

## Why

The same title, on the same Apple TV, starts differently from one load to the next. Three loads of
*Gladiator* (Dolby Vision P7 FEL, DTS:X rendered to an APAC 7.1.4 bed) on 2026-10-24:

| Load | Display switch ends | Programme playing | Gap after switch | Outcome |
|---|---|---|---|---|
| 04:34 | ~2.9 s | ~13 s | ~10 s | readiness gate reloaded the master twice, fell back to the media playlist, Dolby Vision dropped, display re-switched to HDR10, HDMI audio dropped to 2 ch, sound back after ~30 s |
| 06:01 | 3.04 s | 4.70 s | 1.66 s | started first time; LG banner showed Dolby Vision and Atmos |
| 06:14 | 3.08 s | 3.57 s | 0.49 s | started first time; LG banner showed Dolby Vision only; soundbar played Atmos |

The work was the same each time. The outcome changed because unrelated things changed speed, and the safety
timers turned "slow" into a different route. A step should begin when its inputs exist, each input should be
produced before the step that needs it, and timers should only detect failure.

## Today's startup, as the code runs it

Paths are under `Sources/AetherEngine/`. Times are from the 06:14 load, seconds from `load()`.

| When | What | Where |
|---|---|---|
| 0.00 | `dispatched`; previous session torn down | `AetherEngine.swift:4362`, `:4386` |
| 0.03 to 0.10 | `sourceOpened`, `containerOpened`, `streamsProbed` from the probe's open progress | `AetherEngine.swift:4659` |
| 0.10 | P5 RPU audit, display capabilities composed once, `effectiveFormat` clamped to them | `:4615`, `:4716`, `:4748` |
| 0.12 | Atmos activator started in programme mode (plays while `state == .loading`) for TrueHD Atmos and DTS-HD MA labelled DTS:X | `:5110`, `AtmosOutputActivator.swift:217` |
| 0.12 | criteria written: `effectiveFormat`, `snappedRate`, `dvh1` if Dolby Vision. Nothing about the route, the variant or the refusal latch goes in | `:5116`, `DisplayCriteriaController.swift:752` |
| 0.12 | pre-flight gate started beside the load (`preflightGateRunsBesideLoad`, VOD) | `:5130` |
| 0.1 to 2.2 | routing: interlace and SPS checks, MVC, dual-layer/FEL decision (reads up to 256 packets for the EL type), VideoToolbox capability probe (a throwaway hardware `VTDecompressionSession`) | `:5313` to `:5561` |
| 2.21 | `displayPrepared`: `settlePanelRouting` waits for the pre-flight gate, which releases at the **2 s cap** (`stage2CapMs`) mid-switch, then reads the panel (`currentPanelIsHDR`) | `:5188`, `DisplayCriteriaController.swift:134`, `:1167` |
| 2.30 | `routed` | `:5643` |
| 2.3 | `HLSVideoEngine.start()` / `prepare()` builds the plan and the server and starts the producer, which cuts ahead (default 10 segments); `serve(panelIsInHDRMode:)` picks master or media playlist | `AetherEngine+Loading.swift:1372`, `HLSVideoEngine.swift:2406`, `:2420` |
| 2.3 | indexed subtitle fill and sidecar fill start (12 lanes through `HTTPDiscIOReader`, outside `OriginRequestBudget`) | `Loading.swift:1445`, `:1447` |
| 2.3 | `currentAVPlayer` assigned: the activator re-attaches to the AVPlayer and, since the player is paused, **pauses the silent Atmos stream** | `Loading.swift:1497`, `AtmosOutputActivator.swift:139`, `:154` |
| 2.39 | `sessionConstructed`; `AVPlayerItem` created, `replaceCurrentItem`, mount seek | `Loading.swift:1943`, `NativeAVPlayerHost.swift:582`, `:921`, `:974` |
| ~3.0 | item `readyToPlay`, layer `isReadyForDisplay` (about 0.6 s after the item, **without `play()`**) | 2026-10-22 logs |
| 3.08 | `modeSwitchEnd`; the play gate (`waitForSwitch(.awaitObservedEnd)`, 6 s budget) releases; `play()`; the activator resumes | `AetherEngine.swift:5801`, `:5833` |
| 3.56 | `ready`, `presenting` | `Loading.swift:241`, `:124` |

Three different gates touch the switch: the pre-flight (2 s cap), the #667 wait for an unproven HDR master, and the
play gate. A P7 FEL with `LoadOptions.felOverlay` (the 06:14 load) is on this native route: AVPlayer plays the base
layer and APAC audio, and `FelOverlayRenderer` composes the enhancement layer over it (`AetherEngine.swift:5450`).
The software route (FEL without the overlay, interlaced H.264, MPEG-2, VC-1, VP9, AV1 on tvOS, forward-only
sources) has no play gate at all: it plays as soon as `loadSoftware` returns (`AetherEngine.swift:5736`).

The checkpoint order above (displayPrepared before routed) is the P7 dual-layer and FEL order. On other HDR loads
`routed` is recorded first and the routing read moves into `loadNative` via `resolvePanelRouting`; the late
`displayPrepared` is then dropped by `StartupProgress.advanced` as out of order.

## Where the variability comes from

1. **The criteria are written before the plan exists.** They ignore the master or media choice, the
   `panelRefusedHDRMaster` latch and the software route. When the route then differs (a media fallback), a second
   switch follows, which is what took the HDMI audio route down at 04:34.
2. **The load continues on a cap, not on the event.** The pre-flight gate releases at 2 s mid-switch. For P7 FEL
   titles the producer only starts after that release (`start()` at `Loading.swift:1392`), so AE#348's overlap is
   lost exactly on the titles that need it most.
3. **The Atmos activator is off when the switch ends.** Started at 0.12 s, it is paused at 2.3 s when it follows
   the paused AVPlayer, and resumes at `play()`, the moment the switch ends and the sink reads the link. Programme
   audio then followed 1.66 s after the switch at 06:01 and 0.49 s at 06:14. On a reused native host
   (`currentAVPlayer` unchanged, so its `didSet` never fires), the programme-mode activator releases when the state
   becomes `.playing` and nothing re-attaches it for the rest of the session.
4. **Readiness waits on renditions AVPlayer selects itself.** A FORCED=YES subtitle is resolved by readyToPlay
   (`appliesMediaSelectionCriteriaAutomatically`), and a forced OCR rendition still fills progressively, so its
   requests can be held up to `subtitleRequestWaitSeconds` (1 s) while the reading advances.
5. **Load-time background reads compete with the producer.** The indexed subtitle fill (12 lanes, over-fetching
   about 500 MB per load through the adaptive chunk growth) and the sidecar fill start before the item exists.
   Atmos confirmation (after `play()`, opt-in) and the I-frame reader (lazy) are not on the startup path.
6. **The panel proof does not survive a relaunch.** `panelProvenToEngageHDR` lives in memory on the engine's
   `DisplayCriteriaController`, so every cold launch routes an unproven panel.

## What the platform gives us (tvOS 27.2 SDK)

Checked in `AppleTVOS27.2.sdk` headers and Apple's documentation. Nothing about display switching has changed
since tvOS 17; the newer pieces are concurrency, Observation and metrics.

**Display**
- `AVDisplayManager` (`UIWindow.avDisplayManager`): `preferredDisplayCriteria`, `isDisplayModeSwitchInProgress`
  (KVO; header: "accuracy … dependent on the hardware … may last several seconds longer"),
  `isDisplayCriteriaMatchingEnabled`, and the start, end and settings-changed notifications. One combined Match
  Content flag; no API separates range from rate matching.
- `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17) is what the engine uses already.
- Tech Talk 503: write the criteria *before* assigning the item to the player, "so that AVPlayer configures itself
  based on the targeted display mode". The order of the two assignments is the requirement, not a finished switch.
- `UIScreen.currentEDRHeadroom` is not documented as a range-matching signal. It stays the engine's heuristic,
  backed by the proof.
- `AVPlayer.availableHDRModes` is deprecated in tvOS 26 ("Use eligibleForHDRPlayback instead") and the engine still
  reads it for Dolby Vision capability (`AetherEngine.swift:1788`). There is no non-deprecated Dolby Vision query.

**Starting playback**
- `AVPlayer.preroll(atRate:) async -> Bool` (and the completion-handler form, `cancelPendingPrerolls()`): "Once
  the completion handler is called with YES, the player's rate can be set with minimal latency." Call it only at
  rate 0 and after the **player's** status is readyToPlay (it throws otherwise); it returns NO if interrupted by a
  time change or "if preroll is not possible for some other reason". Apple says nothing either way about HLS.
- `setRate(_:time:atHostTime:)` raises if `automaticallyWaitsToMinimizeStalling` is true (WWDC16 session 503: to
  synchronize with an external timeline "you must opt out"). HLS is supported since tvOS 11. Apple's own pattern
  (sample AVMediaSelectionDemo, `prerollPlayersAndStartPlayback`): preroll every player, then
  `setRate(1, time:, atHostTime: now + 10 ms)` on the host clock.
- The engine keeps the flag true. 35fa16d0 reverted a session-wide `false` because AVPlayer "drop[ped] rate to 0
  immediately after asset.load completed and never resume[d]". With the flag false, a rate set over an empty buffer
  behaves as a stall, and a stall without auto-wait leaves the player at rate 0; the engine calls `play()` before
  the item is ready (`NativeAVPlayerHost.play()`), so the first `play()` landed on an empty buffer. That failure
  needs an empty buffer at the moment the rate is set, which a successful preroll rules out. The software route
  already starts at a host time on its synchronizer.
- There is no "prepare" or "ready to start" API on `AVPlayer` or `AVPlayerItem` through tvOS 27. Item status has no
  async load; it is KVO, or Swift Observation (`AVPlayer.isObservationEnabled`, tvOS 26, process-wide and set
  before any player exists, so not something the engine can switch on alone inside a host app).
- `reasonForWaitingToPlay` and `rateDidChangeNotification` reasons say why a play is held.

**Audio**
- `AVAudioSession.maximumOutputNumberOfChannels` is the documented HDMI channel capability; the audio route does
  not consult it today.
- `AVAudioSession.renderingMode` reads `notApplicable` on this HDMI route throughout playback in every log, so it
  cannot confirm Atmos. No API reports whether the sink is showing or capable of Atmos.

**Measuring**
- `AVMetricEventStream` (tvOS 18) on the item gives `AVMetricPlayerItemInitialLikelyToKeepUpEvent`,
  `AVMetricHLSPlaylistRequestEvent`, `AVMetricHLSMediaSegmentRequestEvent` and, since tvOS 26, the variant
  switch's video, audio and subtitle renditions. That is the precise, Apple-defined readout for step 8.

## Principles

- A step starts when its inputs exist, never on a guess that they will.
- Every input a step needs is produced before that step, and is final.
- A step waits for the documented event that means "done", not for a time that usually covers it.
- Timers detect failure and report it. They never select a different route because something was slow.
- One start: picture and programme audio begin once, together, at a moment the engine chose.

## Proposed startup

### Step 1: Know the content

- **Requires:** the container header.
- **Produces:** tracks, codecs, frame rate, field order, HDR and Dolby Vision signalling, the audio track that
  will play, the P5 RPU audit.
- **Gate:** `streamsProbed`. Already deterministic.

### Step 2: Decide the output plan, before any write

| Decision | Inputs | Before the switch? |
|---|---|---|
| Native or software | probe facts, the VideoToolbox capability session | yes. AE#348 kept VideoToolbox work out of the switch; here it runs before the write, so there is no switch to keep it out of |
| Dolby Vision handling (P7 FEL overlay or dual layer, P8.1, P5) | `DualLayerRouteDecision` (EL packets, up to 256), `CodecRoute` | yes; the EL read is real I/O, measured as part of this step |
| Output frame rate | probe rate, deinterlace option | yes |
| Audio route (passthrough, bridge, APAC bed, objects) | codec, profile, DTS:X verdict, `objectAudioRendering`, `maximumOutputNumberOfChannels` | yes |
| Atmos activator | the audio route plays APAC and every output port is HDMI | yes |
| Master or media playlist | whether the panel presents HDR here | only when the panel is proven: the proof, persisted (below), or the refusal latch |
| Criteria (range, rate, codec tag) | the rows above | yes, from them: a session the plan routes to the media playlist asks for the range it will present |

- **Produces:** one immutable `StartupPlan` value (route, DV handling, variant, criteria, audio route, activator).
  Today these are mutable locals in `loadSession` (`useSoftwarePath`, `felOverlayWanted`, `elType`,
  `routingPanelHDR`) plus `CodecRoute`, `PreparedServe`, `AppliedCriteria` and `SessionLoadContract`; the plan
  bundles what they decide and is passed down instead of re-read.
- **The one input that may need the switch:** master or media on an unproven panel. Persist the proof (and the
  refusal) across launches, keyed to the display, and clear it on
  `AVDisplayManagerModeSwitchSettingsChangedNotification` and `AVPlayer.eligibleForHDRPlaybackDidChangeNotification`.
  With no proof, the plan commits to the master (`attemptsHDRMasterOnUnprovenPanel`) and serves it only after the
  switch ends (the existing #667 wait, now the rule for that case alone). A refusal is the existing in-place
  media fallback (#98), reported, and recorded for later loads.
- **Gate:** the plan is complete. Nothing after it changes the plan except a reported failure.

### Step 3: Ask for the output and start production

In this order, with no wait between:

1. Start the Atmos activator if the plan has one. It stays on, unpaused, from here until the programme is playing
   (step 6), across the item's creation and the switch end; it then follows the AVPlayer as today. On a reused
   host it re-attaches explicitly rather than through `currentAVPlayer`'s `didSet`.
2. Write the criteria once (`DisplayCriteriaController.apply`, which already arms the switch observation before
   the write).
3. `HLSVideoEngine.prepare()`: plan, server, producer. This no longer waits behind a gate on any route.
4. Make every rendition AVPlayer may select itself answerable at once: the forced rendition is filled first and
   its requests are not held during startup.
5. Leave the indexed subtitle text fill and the sidecar fill for step 6.

### Step 4: Create the item and preroll, during the switch

- **Requires:** the criteria written, the producer started, and the variant known (immediately when proven;
  after the switch for an unproven master).
- **Does:** `serve()`, create and assign the `AVPlayerItem`, mount seek, then once `AVPlayer.status` is
  readyToPlay, `await player.preroll(atRate: 1)`.
- **Gate:** preroll returned. NO is not a route change: it means "start without it", and is logged with
  `reasonForWaitingToPlay`.
- The 2026-10-22 logs show the item reaching readyToPlay and the layer ready for display about 0.6 s after the
  item, without `play()`. That contradicts the comment at `NativeAVPlayerHost.swift:1975` ("item.status never
  advances past .unknown until AVPlayer is told to play"); preroll is verified on device before the comment changes.

### Step 5: Wait for the display

- **Requires:** the criteria written. Runs alongside steps 3 and 4.
- **Gate:** `AVDisplayManagerModeSwitchEndNotification`, or `isDisplayModeSwitchInProgress` false for a switch
  whose end is never announced. The existing shortcuts stay, because each is a documented "no switch": Match
  Content off (`isDisplayCriteriaMatchingEnabled` false) and unchanged criteria (#133).
- **Failure detector:** `observedEndCapMs` (6 s; the measured maximum is 3.55 s). Reaching it is reported as a
  display failure and the start proceeds.
- The 2 s `stage2CapMs` release is no longer on the load path: nothing in steps 3 and 4 waits for the switch.

### Step 6: Start

- **Requires:** step 4 and step 5, in either order.
- **Does:** Apple's prerolled start. With preroll returned YES: set `automaticallyWaitsToMinimizeStalling` false,
  `setRate(1, time: .invalid, atHostTime: hostNow + lead)`, and set it back to true once `timeControlStatus` is
  `.playing`, so stalls during the session keep auto-wait's recovery. Programme audio and picture start on the same
  timebase at a host time the engine chose, a fixed `lead` after the switch end. With preroll NO, a plain `play()`
  (auto-wait left on), logged. Then hand the activator to the AVPlayer and start the deferred fills.
- **To verify on device:** that toggling the flag around the start is accepted (the header neither allows nor
  forbids it), the smallest `lead` that starts on time, and that `play()` after preroll is actually slower or
  more variable than the host-time start (not measured; the "minimal latency" in the header is unquantified).
- **Software route:** the same gate before `softwareHost.play()`, which today has none; its synchronizer already
  prerolls and can start at a host time.

### Timers in the new design

| Timer | Today | New role |
|---|---|---|
| `stage2CapMs` (2 s) | releases the load mid-switch | off the load path |
| `observedEndCapMs` (6 s) | upper bound on the play gate | failure detector for step 5 |
| Readiness gate (#35) | done: AirPlay receivers only | unchanged |
| #98 media fallback on -11868 / -11848 | reactive, any load | unchanged; on a proven panel it should not fire, and when it does it is a reported failure |
| Subtitle request hold (1 s while reading advances) | can hold a forced rendition at startup | not applied to the forced rendition during startup |

## The Atmos label

The LG reads the audio as the HDMI link comes back after the switch. Today the silent Atmos stream is paused at
exactly that moment on the native route (variability item 3). With step 3 the activator is on through the switch
end on every APAC route, and the programme starts at the same point after it. One test settles what the LG shows.

## Order of work

1. Activator continuity: on from step 3 to the programme playing; explicit re-attach on a reused host. Small,
   independent, and the most likely cause of the missing Atmos label.
2. `StartupPlan` (step 2), with the criteria derived from it.
3. Persisted panel proof and refusal, with invalidation.
4. Producer and item off the pre-flight gate (steps 3 and 4); the #667 wait only for an unproven master.
5. Preroll, after confirming on device that the item reaches readyToPlay before `play()`.
6. One start on both events (step 6), on both routes.
7. Done: readiness gate for AirPlay receivers only.
8. Defer the indexed and sidecar fills to after the start, and fix the index fill's over-fetch.
9. Measure on device with `AVMetricEventStream` and the #361 checkpoints: start latency against today, and the LG
   banner.

## Housekeeping found on the way

- `availableHDRModes` is deprecated in tvOS 26.
- The tvOS 27 SDK deprecates the global `Notification.Name.AVPlayerItem…` names in favour of
  `AVPlayerItem.timeJumpedNotification` and its siblings.
- The engine's `NativeAVPlayerHost.swift:1975` comment is contradicted by the logs (step 4).
