# Deterministic startup

Status: built 2026-10-26 on `research/12bit-fel` against the tvOS 27.2 SDK (Xcode 27.2, 27B5038j), every video
title on the native route (the software overlay and the FEL overlay over AVPlayer). Not yet measured on the
device; see "On the device".

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
  not consult it.
- `AVAudioSession.renderingMode` reads `notApplicable` on this HDMI route throughout playback in every log, so it
  cannot confirm Atmos. No API reports whether the sink is showing or capable of Atmos.

**Measuring**
- `AVMetricEventStream` (tvOS 18) on the item gives `AVMetricPlayerItemInitialLikelyToKeepUpEvent`,
  `AVMetricHLSPlaylistRequestEvent`, `AVMetricHLSMediaSegmentRequestEvent` and, since tvOS 26, the variant
  switch's video, audio and subtitle renditions. `AVPlayerItemMetricsLog` logs them per native item; it is the readout for the device measurement below.

## Principles

- A step starts when its inputs exist, never on a guess that they will.
- Every input a step needs is produced before that step, and is final.
- A step waits for the documented event that means "done", not for a time that usually covers it.
- Timers detect failure and report it. They never select a different route because something was slow.
- One start: picture and programme audio begin once, together, at a moment the engine chose.

## The startup, step by step

Every video load runs these steps in this order (`AetherEngine.loadSession`, `loadNative`).

### 1. Know the content

The probe gives tracks, codecs, frame rate, field order, HDR and Dolby Vision signalling, the audio track and the
P5 RPU audit. Checkpoints `sourceOpened`, `containerOpened`, `streamsProbed`.

### 2. Decide the route, before the display is asked anything

Native or overlay, the dual-layer decision (its EL probe reads up to 256 packets), the VideoToolbox capability
gate, the interlace refute probe, the IPT refusal. All of it runs before the criteria write, so no VideoToolbox
session opens and no packet is read while the panel switches; the AE#348 rule that settled the panel first for
these probes has nothing left to guard. Checkpoint `routed`.

### 3. Ask the display, and plan the playlist

In this order, with no wait between them:

1. The Atmos activator starts for a track the probe says plays as APAC (`anticipateAtmosOutput`).
2. The criteria are written once (`DisplayCriteriaController.apply`, which arms the switch observation first).
   Checkpoint `displayPrepared`: the display has been asked; its switch runs beside everything below.
3. The master-or-media answer is planned (`plannedPanelRouting`). Every input but the panel readout exists now:
   eligibility, the AE#588 refusal latch, the host's `attemptsHDRMasterOnUnprovenPanel` and `panelIsInHDRMode`,
   and the panel proof. The readout changes the route only on an eligible, unlatched display the load may not
   offer the master on trust, so:
   - **decided, master:** an eligible, unlatched display the load may attempt, or one the proof or the host's
     assertion says presents HDR. An unproven master is served once the switch has ended (#667).
   - **decided, media:** an ineligible display, or a latched refusal.
   - **at the settled panel:** an unproven display the load may not attempt (the host declined it, or a live
     load). The pre-flight gate runs beside the session for VOD, in front of it for live, as before.

The planned answer goes to the session (`HLSVideoEngine.plannedPanelIsInHDRMode`), which knows from `prepare()` on
which playlist it will serve (`plannedServesMaster`). Anything the session builds that depends on that choice can be
built for it in `prepare()`; nothing that could change it waits for the panel.

**The panel proof** (`PanelProof`) is the display having been seen engaging HDR for an engine HDR write. It is
stored between launches under the output configuration it was earned in (`isDisplayCriteriaMatchingEnabled`,
`eligibleForHDRPlayback`), so a cold launch on a proven display serves its master without the #667 wait. It is
forgotten when that configuration changes (`AVDisplayManagerModeSwitchSettingsChanged`,
`eligibleForHDRPlaybackDidChange`) or when AVFoundation refuses an HDR master (#98). Range matching turned off with
frame-rate matching kept reports through neither notification; a stale proof there costs one in-place media
fallback, and that refusal forgets it.

The refusal latch stays in memory and clears on a return from the background (AE#588): it describes an output
configuration the user can only change by leaving the app.

### 4. Build the session and the item, during the switch

`prepare()` builds the plan, the server and the producer, and the producer cuts ahead. `serve` follows at once for a
decided plan, after the switch's end for an unproven master, after the settled panel otherwise. The `AVPlayerItem`
is created and assigned (criteria first, item second, as Tech Talk 503 asks), the mount seek is issued, and the
start's preroll is asked for (`NativeAVPlayerHost.prerollForStart`): it begins as soon as the item is ready and its
mount seek has landed. Checkpoint `sessionConstructed`.

The Atmos activator follows the AVPlayer from here, and while the engine is still loading a session that plays
APAC it keeps the silent Atmos stream playing over the paused player and across the item swap
(`AtmosOutputActivator.hostVerdict`). A reused player re-attaches it explicitly.

For an overlay session the producer holds the first segment of a run until the overlay's decoder has the picture at
the run's start: the software overlay's picture (`OverlayDecodeTap.awaitRunStart`), or the FEL overlay's
enhancement picture (`FelEnhancementTap.awaitRunStart`). Before AVPlayer moves its clock, the decoder works toward
the run's start (`OverlayRunStart`). AVPlayer's readiness, and so the preroll, already includes the overlay's, and a
FEL start opens on the full composed picture.

### 5. Wait for the display

The play gate (`waitForSwitch`, `.awaitObservedEnd` for VOD) waits for `modeSwitchEnd`, or the in-progress flag
clearing for a switch that never announces its end. Match Content off and unchanged criteria (#133) have nothing to
wait for. `observedEndCapMs` (6 s) bounds it and is reported when reached.

Then the panel is read for the label (`readSettledPanel`): what the panel presents once the switch has ended.

### 6. Start once

`NativeAVPlayerHost.startPrerolled()`:
- **preroll finished:** auto-wait off, `setRate(rate, time: .invalid, atHostTime: now + 10 ms)`, auto-wait back on at
  the first status after it (or at a `.paused` the start stalled into, which is restarted with auto-wait). Picture,
  programme audio and the overlay (it reads the item's clock) start together. Apple's own prerolled start
  (AVMediaSelectionDemo, `prerollPlayersAndStartPlayback`).
- **The player's status when deciding, not the observed one** (`afterPrerolledStart`). The observer hops to the main
  actor, so a `.paused` read just before the start can arrive once the player is `.playing`. On the Apple TV
  (2026-10-27) that stale pause was taken for a stalled start and `play()` called again: the item's clock jumped 37 ms
  forward 100 ms into playback, and the overlay's layer dropped the pictures the jump passed (6 drops, 5 pictures out
  of order, in every session's first seconds). `StartupPlanTests` holds the decision on that sequence.
- **preroll still running:** waited for; it ends when the pipelines hold what the start needs, which a `play()`
  would wait for too.
- **item not ready, or preroll interrupted:** a plain `play()`, logged with the reason.

Live loads keep their own start (AE#440), a paused mount does not start (#124), and a master handed to an AirPlay
receiver runs the readiness gate (#227). Then `state = .playing`, and the activator follows the playing player.

## Timers

| Timer | Role |
|---|---|
| `stage2CapMs` (2 s) | the pre-flight gate of a plan left to the settled panel, and live; off every decided load's path |
| `observedEndCapMs` (6 s) | the play gate's bound; reaching it is logged |
| #667 wait | an unproven master's serve, until the switch it asked for ends |
| Readiness gate (#35) | AirPlay receivers only |
| #98 media fallback | reactive; a display refusal also forgets the proof |
| Overlay run start (5 s) | an overlay or FEL enhancement decoder with no picture for the run's start; released and logged |

## On the device

Measured on the Apple TV 4K (A15, tvOS 27.2) into the LG G5, 2026-10-27, a FEL title with TrueHD Atmos, before the
restart fix above: the activator was active on HDMI before the switch and after it (1); `start: prerolled, the clock
starts 10 ms ahead` (2); `first likely to keep up ... after 1.417 s` (6); `overlay run start: first picture decoded
after 0 ms`, no residual-off picture (7); `panel proven to engage HDR by a stored proof` on the load (4). The switch
took 2.9 s end to end. Still to check: 3, 5, the LG banner, and the overlay layer's drops in the first seconds now that
the start runs once (the goal is none). To check on the Apple TV and the LG G5:

1. The LG banner shows Dolby Vision and Atmos on an APAC title (the activator held through the switch's end).
2. `start: prerolled` in the log on VOD loads, and the gap from `modeSwitchEnd` to the first frame across loads.
3. Toggling `automaticallyWaitsToMinimizeStalling` around the start is accepted (no stall, no exception).
4. A cold launch on the proven display: `panel proven to engage HDR by a stored proof`, and no #667 wait.
5. A decided master served right after the write, before the switch has started, is accepted.
6. `AVPlayerItemMetricsLog`'s `first likely to keep up` against the #361 checkpoints.
7. On a FEL title, `overlay run start: first picture decoded` and no `residualOff` count at the start.

## Handed on

- **The demuxed audio rendition** (`docs/demuxed-audio.md`): `plannedServesMaster` is the answer its shape is
  chosen from in `prepare()`; a session whose plan was left to the settled panel keeps the muxed shape, which plays
  from either playlist.

