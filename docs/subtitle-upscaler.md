# The subtitle upscaler: integration

The upscaler is its own package, LibMLSubUpscaler (https://github.com/TheFireKahuna/LibMLSubUpscaler, MIT): bitmap
subtitles upscaled 2x by ArtCNN on the Neural Engine. Its README has the design, the A15 costs (a 1920x200 strip in
10.6 ms at p50 on the balanced configuration, Release), the findings and what is open. Nothing in the engine calls it
yet; this is the plan for the engine's side.

## Linking

Behind a trait of its own, like `TrueHDObjectAudio`: the package dependency, the product conditional on the trait, and
the hook compiled only with it. The dependency and the trait arrive with the hook, so the engine carries none of it
until then.

## The hook (not built)

The overlay drain already decodes bitmap display sets about 60 s ahead of the playhead (`SubtitleOverlayDrainer`),
one `SubtitleCue` per object with its cropped `CGImage`. Where the drain applies decoded cues, image cues go to a
prepared upscaler on a background queue, nearest the playhead first, and enter `subtitleCues` once upscaled (a cue is
late by its upscale only after a seek or at start). Results are keyed by stream, start time, position and pixel size,
so a re-decoded cue reuses its upscale. The scale is the display's pixels over the canvas's (a 1080p canvas on a 2160p
panel is 2x; a 1080p panel needs none). `SubtitleUpscaler.prewarm(_:)` runs at app open and `prepare(canvas:)` on the
upscaler that will run. The drain's apply step was being reworked when this was written, so the hook waits for it.
