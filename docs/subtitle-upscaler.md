# The subtitle upscaler: integration

The upscaler is its own package, LibMLSubUpscaler (https://github.com/TheFireKahuna/LibMLSubUpscaler, MIT): bitmap
subtitles upscaled 2x by ArtCNN on the Neural Engine. Its README has the design, the A15 costs (a 1920x200 strip in
10.6 ms at p50 on the balanced configuration, Release), the findings and what is open. This is the engine's side.

## Linking

Behind the `MLSubtitleUpscale` trait, off by default: the package and the code that uses it are compiled only with
it (`AetherEngine.OptionalComponent.mlSubtitleUpscale`). The engine re-exports the package, so a host shows
`ArtCNNLicense.text` with its notices without importing it.

## What a host does

- `AetherEngine.prewarmBitmapSubtitleUpscaler()` at app open: the models load in the background, under 2 s the
  first time after an install or an OS update (the default specialisation), well under one otherwise, and the
  `fastPrediction` ones replace them behind that.
- `bitmapSubtitlePixelSize`: the picture's rect it draws bitmap subtitles into, in pixels. A cue's canvas is scaled
  to cover it, centred, as Sodalite places cues; under 1.2x of its own size a cue stays as decoded (a 1080p canvas
  on a 1080p panel). Applies to cues decoded after it is set.

## How a cue is upscaled (`BitmapSubtitleUpscaling`)

- **In the drain tick's decode half**, on its `BlockingWork` thread, after the decode and before the tick's apply
  half: a cue enters `subtitleCues` already upscaled, and the main actor never waits for it. The OCR worker shares
  the decode and reads the bitmaps as decoded.
- **Which cues**: the last display set starting at or before the playhead (the line a landing shows) and every one
  after it. Earlier sets are history the reconstruction pass reads, which nothing shows.
- **A landing** decodes up to the composition that ends its reconstruction pass (the first with a cue at or after
  the playhead) and stops there, so its line waits for its own upscale and its successor's rather than the whole
  lead's, and the pass ends exactly as it always does, successor included. The rest stays stored behind the cursor,
  as a capped batch's does (#271), and the next tick, asked for at once, decodes it, upscaled. With no such
  composition in the window the landing decodes the whole window, as before.
  At a seek the landing arrives with `AVPlayerItemTimeJumpedNotification`, while AVPlayer still buffers towards the
  target, so the upscale normally finishes before the target's first frame.
- **Kept** by stream, start, geometry and output size, within 180 s of the playhead: a cue decoded again (a seek
  back into the retained window, an audio switch) is a lookup.
- **Playback start**: a session with a bitmap track starts playing once the upscaler is ready
  (`awaitBitmapSubtitleUpscaler`, before the autostart's play), which waits only when a session starts within a
  second or two of an install or an OS update. Readying starts when the load does.
- **In the background** (Picture in Picture, background audio), where the GPU is refused, a tick does not try: its
  bitmap cues publish as decoded and the channel is owed. A failed upscale (logged once) owes its channel too. On
  the return to the foreground each owed channel is re-landed (`resumeBitmapSubtitleUpscale`): the drain decodes its
  window again in place, the landing line first, and each re-decoded cue replaces its decoded copy, which the store
  matches on start and position alone (the pixel size is what the upscale changes). A failed preparation is not
  kept, so the next tick tries again.

## Not yet measured

On the A15: the landing's upscale against AVPlayer's buffering after a seek, the `fastPrediction` replacement's
benefit per prediction, and both under playback load (4K HDR, FEL composition).
