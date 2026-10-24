# Deterministic startup

Status: proposal, 2026-10-24. Nothing here is implemented yet.

## Why

The same title, on the same Apple TV, starts differently from one load to the next. Three loads of
*Gladiator* (Dolby Vision 23.976, DTS:X rendered to an APAC 7.1.4 bed) on 2026-10-24:

| Load | Display switch ends | Programme playing | Gap after switch | Outcome |
|---|---|---|---|---|
| 04:34 | ~2.9 s | ~13 s | ~10 s | readiness gate reloaded the master twice, fell back to the media playlist, Dolby Vision dropped, display re-switched to HDR10, HDMI audio dropped to 2 ch, sound back after ~30 s |
| 06:01 | 3.04 s | 4.70 s | 1.66 s | started first time; LG banner showed Dolby Vision and Atmos |
| 06:14 | 3.08 s | 3.57 s | 0.49 s | started first time; LG banner showed Dolby Vision only; soundbar played Atmos |

The work was the same each time. The outcome changed because unrelated things changed speed: subtitle
segment requests held by the segment server, background reads competing at load, the first media segments.
Each of those moved the moment the programme started relative to the display switch, and the safety timers
turned "slow" into a different route altogether.

A startup should not work that way. Each step has inputs; each step should begin when its inputs exist, and
each input should be produced before the step that needs it. Timers should only detect failure.

## Today's startup

The engine records eight checkpoints (#361, `StartupCheckpoint`). Times are from the 06:14 load, seconds from
`load()`.

| # | Checkpoint | Time | What it decides | What it waits on |
|---|---|---|---|---|
| 0 | dispatched | 0.00 | previous session torn down | nothing |
| 1 | sourceOpened | 0.03 | the source answers | the origin |
| 2 | containerOpened | 0.03 | container identified | the origin |
| 3 | streamsProbed | 0.10 | tracks, codecs, duration, frame rate | the origin (`find_stream_info`) |
| - | criteria written | 0.12 | **display range and rate** (`DisplayCriteria SET: dolbyVision dvh1 23.976`) | the probe only; the route is not chosen yet |
| - | Atmos activator | 0.12 or 2.4 | silent Dolby Atmos stream to hold the sink in Atmos | started before the criteria write for TrueHD Atmos only; for everything else at session construction |
| 4 | displayPrepared | 2.21 | "the handshake settled" | **a 2 s cap** (`proceed after cap ... panel still mid-switch`), not the switch |
| 5 | routed | 2.30 | **native or software, Dolby Vision handling, FEL overlay, master or media playlist** | the panel readout after (part of) the switch, VideoToolbox probes |
| 6 | sessionConstructed | 2.39 | audio route (passthrough or APAC bridge), producer, AVPlayer item created | nothing further |
| - | switch ends | 3.08 | `modeSwitchEnd` | the TV |
| - | `rate = 1` | 3.08 | play requested | the switch end |
| 7 | ready | 3.56 | AVPlayer `readyToPlay` | whatever AVPlayer fetched first: playlists, first segments, every rendition it selected itself (the forced subtitle) |
| 8 | presenting | 3.57 | picture and programme audio start | readiness |
| - | readiness gate (#35) | 4.0 if not ready | **reload the master, then drop to the media playlist** | a timer |

Two clocks run against each other from 0.12 s: the TV's switch (2.8 to 3.6 s, measured) and the item's
readiness, which depends on everything AVPlayer asks for. Whichever finishes last starts the programme.

## Where the variability comes from

1. **The display is asked for before the route is known.** The criteria are written at 0.12 s; the route that
   decides what will actually be presented is chosen at 2.3 s, partly from a panel readout taken after the
   switch (`currentEDRHeadroom`, the only signal tvOS gives for whether range matching is on). Usually the two
   agree. When they do not (a readiness fallback to the media playlist, say), a second switch follows, which is
   what took the HDMI audio route down at 04:34.
2. **The display wait is a cap, not the event.** `waitForSwitch` releases after 2 s ("proceed after cap") while
   the switch is still running. Since AE#348 the load continues beside the switch, so how far it gets before the
   switch ends depends on everything else.
3. **The item's start races the switch, and the readiness gate turns a slow start into a format change.** The
   item is created when the 2 s cap releases, about 0.7 s before the switch ends, so whether AVPlayer is ready
   before or after the switch depends on everything else. #35 (a Dolby Vision master after a cold launch that
   resolves no tracks or fails -11819) is handled by a readiness gate that reloads the master and then falls back
   to the media playlist on a timer, so a start that is merely slow (a held subtitle request, say) also ends in a
   reload or in Dolby Vision dropped. Creating the item mid-switch is not itself the problem; see "Creating the
   item during the switch" below.
4. **Readiness depends on data produced on demand.** AVPlayer will not start until it has the playlists, the first
   media segments and the first segments of every rendition it selected itself, including a FORCED=YES subtitle
   tvOS picks without being asked. Each is produced when requested, so its timing is whatever the producer and
   the network give that moment. Until 2026-10-24 the forced subtitle requests were also held up to 3 s each.
5. **The Atmos activator starts at different points.** For TrueHD Atmos it starts before the criteria write
   (0f3dd7e6, so the LG banner after the switch already sees Atmos). For a DTS:X track rendered to the same APAC
   bed it starts at session construction, after the 2 s cap. Its timing was the same at 06:01 and 06:14; the
   programme start was what moved.
6. **Background work starts at load.** The subtitle index fill, side readers, the Atmos confirmation demuxer, the
   I-frame side reader: all begin while the startup is still running and compete for the same origin.

## Principles

- A step starts when its inputs exist, never on a guess that they will.
- Every input a step needs is produced before that step, and is final: nothing later can change it.
- A step waits for the documented event that means "done", not for a time that usually covers it.
- Timers detect failure and report it. They never select a different route because something was slow.
- One start: picture and programme audio begin once, together, at a moment the engine chose.

## Proposed startup

### Step 1: Know the content

- **Requires:** the container header.
- **Produces:** tracks, codecs, frame rate, field order, HDR and Dolby Vision signalling, the audio track that
  will play.
- **Gate:** `streamsProbed`. Already deterministic.

### Step 2: Decide everything that defines the output

Everything the display and the audio route will be told is decided here, before anything is written.

| Decision | Requires | Available before the switch? |
|---|---|---|
| Route: native or software | codec, field order, multiview carriage, VideoToolbox hardware support | yes: probe facts plus `VTIsHardwareDecodeSupported` (cheap) |
| Dolby Vision handling: P7 FEL overlay or dual layer, P8.1 kept, converted, P5 | the RPU and EL probe, FEL capability gate | yes: probe-time; today it runs after the cap only because AE#348 avoided VideoToolbox work mid-switch |
| Variant: master (DV or HDR) or media playlist | whether this panel presents HDR and Dolby Vision, whether AVPlayer accepts the master here | yes once known: the engine already remembers "panel proven to engage HDR"; `VariantOracle` asks AVFoundation the variant question directly but is diagnostic today (its runs in today's logs failed -1008) |
| Output frame rate | content rate, deinterlace mode (double rate for 50i/60i), pulldown | yes: probe plus the deinterlace option |
| Output range | the variant plus the panel's proven capabilities | yes, from the two rows above |
| Audio route: passthrough, APAC bed, APAC objects | the track's codec and profile, `objectAudioRendering`, the HDMI route's channel capability | yes: probe plus `AVAudioSession` (`maximumOutputNumberOfChannels`) |
| Atmos activator needed | the audio route plays APAC to an HDMI sink | yes: from the row above, for every APAC route, not only TrueHD |

- **Produces:** one immutable output plan: route, variant, criteria (range, rate, codec tag), audio route.
- **Gate:** all rows decided. Nothing after this step may change the plan except a reported failure.
- **Gap to close:** a panel whose HDR behaviour has never been proven (first ever HDR title, or a settings
  change). The plan then has to commit to a guess; the guess and its failure handling should be explicit, and the
  proof cached for every later load.

### Step 3: Ask for the output, and prepare what the item will need

- **Requires:** the plan.
- **Does, in this order:**
  1. Start the Atmos activator if the plan plays APAC to HDMI, so Atmos is already on the link when the switch
     completes.
  2. Write the display criteria once.
  3. Start the producer: first media segments, with the audio bridge's first APAC packets encoded.
  4. Make every rendition AVPlayer may select on its own answerable at once: subtitle renditions from the
     container index or answered immediately (done 2026-10-24); the forced rendition the plan declared.
- **Defers:** background work that is not on the startup path (index text fills, side readers, Atmos
  confirmation, I-frame reader) until step 6, or runs it at a priority and connection budget that cannot delay
  steps 3 to 5.

### Step 4: Create and preroll the item, while the display switches

- **Requires:** criteria written (Apple: criteria before the item is assigned to the player), the producer started.
- **Does:** right after the criteria write, with no cap in between, create the `AVPlayerItem` on the planned
  variant, assign it, and call `AVPlayer.preroll(atRate:)`, the documented call for "load and decode enough to
  start immediately", which reports completion. Not used by the engine today.
- **Gate:** preroll completion.

### Step 5: Wait for the display

- **Requires:** criteria written. Runs alongside step 4.
- **Gate:** the documented end of the switch (`AVDisplayManager.isDisplayModeSwitchInProgress` false,
  `AVDisplayManagerModeSwitchEndNotification`). No cap that lets anything depend on the switch mid-way.
- **Failure detector:** a generous bound (the measured maximum is 3.55 s; the existing `observedEndCapMs` is
  6 s). Exceeding it is reported as a display failure, not treated as "probably done".

### Step 6: Start

- **Requires:** both events, the switch ended (step 5) and preroll completed (step 4), in whichever order they
  arrive.
- **Does:** start once: `play()`, or `setRate(_:time:atHostTime:)` to place the start precisely. Then release
  the deferred background work.
- **Result:** picture and programme audio start together, at the same point relative to the switch on every load.

### Creating the item during the switch

Answered 2026-10-24, from Apple's guidance, the history of #35 and the device logs:

- **Apple's guidance** (Tech Talk 503): assign `preferredDisplayCriteria`, which starts the switch, *before*
  assigning the `AVPlayerItem` to the `AVPlayer`, "so that AVPlayer configures itself based on the targeted
  display mode". The requirement is the order of the two assignments, not that the switch has completed.
  `AVDisplayManager` documents `isDisplayModeSwitchInProgress` and the start and end notifications without tying
  item creation to them.
- **#35** (cc23fd19) was found when the load still waited for the switch to finish before creating the item: the
  failure happened with the switch complete and the panel reporting HDR. It is a cold Dolby Vision decode path after
  a cold launch, with no signal tvOS exposes, not a consequence of creating the item mid-switch. Its device
  verification was left pending.
- **Device logs** (Apple TV 4K, tvOS 27.2, LG G5, 2026-10-22 and 2026-10-24): all 40 Dolby Vision loads created
  the item about 0.7 s before the switch ended, and in most AVPlayer was ready before the switch finished. None
  failed at startup. The only readiness-gate firings were three loads whose forced subtitle segments held AVPlayer's
  start; the -11819 and -11868 errors in the same logs all came mid-playback.

- **The #35 scenario itself** (force-quit, relaunch, resume a Dolby Vision title at once), five times cold on
  2026-10-24: every start created the item mid-switch, was ready about 0.2 s after the switch ended, and never
  armed a recovery. #35 does not reproduce on tvOS 27.2.

So step 4 overlaps step 5, and the start stays as fast as today's. The readiness gate no longer runs for a local
start (see below).

### Timers in the new design

| Timer today | Today's role | New role |
|---|---|---|
| Display settle cap (2 s) | lets the load continue mid-switch | removed; step 4 waits for the event |
| Display observed-end cap (6 s) | upper bound on the wait | failure detector for step 4 |
| Readiness gate (#35): reload master, fall back to media playlist | recovered a cold or slow start by changing the route | removed for a local start (a failed start is reported); kept for a master handed to an AirPlay receiver, whose capability the sender cannot read (#227) |
| Subtitle request hold (now 1 s, only while a feeder's reading advances) | gives a feeder time to reach a window | unchanged; no longer on the startup path, since step 3 makes forced renditions answerable at once |

## The Atmos label

What the LG shows next to Dolby Vision depends on what it receives as the HDMI link comes back after the switch.
Nothing tvOS exposes tells the app when that is: the `pbs.atmos` and `pbs.audioFormat` fields the display probe
logs are the output setting, constant through every switch. So it can only be judged by eye.

Today that moment varies with everything in "Where the variability comes from". With the startup above it is
fixed: the activator is on the link from before the switch for every APAC route, and the programme starts at the
same point after the switch on every load. Whatever the LG does with that, it does every time, and one test
settles it.

## Order of work

1. Step 2: move the route, variant, rate and audio decisions before the criteria write, and make the plan
   immutable. Start the activator for every APAC route there. (Done in part, e3f10a03: the activator starts before
   the switch for a DTS-HD MA track the probe labels DTS:X as well as for TrueHD Atmos.)
2. Steps 4 and 5: create the item and preroll right after the criteria write; replace the 2 s cap with the
   switch-end event, keeping the 6 s bound as a failure detector.
3. Step 6: start once, on both events.
4. Defer startup-competing background work to after the start.
5. Done: the readiness gate runs only for an AirPlay receiver; a local start is a plain start (cold-resume test
   above).
6. Measure on device: start latency against today, and the LG banner.
