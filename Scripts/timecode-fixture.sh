#!/usr/bin/env bash
# A picture that states its own source frame number, for `aetherctl play --picture-probe`.
#
# Every axis observable the engine has describes what it WROTE. None of them says where AVPlayer then
# PUT that segment, and AE#408 shipped an early-opening gate on an assumption about exactly that. With
# this fixture the question needs no assumption: 12 blocks on one pixel row carry bit k of the frame
# index, so one row of pixels out of AVPlayer's own video output decodes to a source time.
#
# Pair it with Scripts/mkv-cue-fixture.py to get the AE#408 shape (Cues that are not sync samples):
#
#   Scripts/timecode-fixture.sh /tmp
#   python3 Scripts/mkv-cue-fixture.py /tmp/tc-drought.mkv /tmp/tc-cues-lie.mkv \
#       "$(python3 -c 'print(",".join(str(i) for i in range(1,120)))')"
#   swift run aetherctl play --seconds 12 --start-position 53 --picture-probe file:///tmp/tc-cues-lie.mkv
#
# `tc-drought.mkv` is the control arm (its Cues ARE its sync samples, `axisErr` stays 0 on every
# tick); `tc-cues-lie.mkv` is the case. A resume at 53 s re-aims the gate, opens at 43.000 against a
# boundary at 52.000 and reads `axisErr=-9.000`, the whole re-aim, constant for the run. (Before
# AE#423 evened out the backoff steps it opened at 38.417 and read `-13.583`.)
#
# The engine reads that axis from each segment's in-band clock (docs/segment-axis.md) and logs it,
# `segN plays from item Xs at source Ys: axis Zs`, so on every arm `axisErr` matches the logged axis
# and `capErr` stays inside the probe's two-frame quantisation. Arms worth running, on the line above:
#
#   --seek-every 12 --seek-count 1 --seek-pattern 80     a seek onto an axis-true stretch
#   --seek-every 12 --seek-count 1 --seek-pattern 65     a seek that re-places the re-aimed segment
#   --seek-every 12 --seek-count 1 --seek-pattern 60     a seek whose restart re-aims again
#   --seek-every 2 --seek-count 4 --seek-pattern 65,60,70,58   a burst
#
# The script also writes `tc-bframes.mkv` (`-bf 3`, `has_b_frames=2`) and `tc-bf1.mkv` (one frame of
# reorder): the same arms on their cues-lie twins open on a random-access point decoded a frame or two
# before it is presented. On `tc-bf-cues-lie.mkv`, `--seconds 40 --start-position 53 --seek-every 14
# --seek-count 2 --seek-pattern 65,60` is the arm where AVPlayer appends a re-aimed segment to the run it
# is playing (`seg34 plays from item 73.833s at source 64.833s: axis -9.000s`).
#
# For magnitudes this fixture cannot reach, engineer the droughts: a key 3 s below a boundary gives
# -3, 5 s gives -5.
set -euo pipefail
OUT_DIR="${1:?usage: timecode-fixture.sh <out-dir> [offset-seconds]}"
DUR=120
FPS=24

filters=""
for k in $(seq 0 11); do
  bit=$((1 << k))
  x=$((k * 52))
  [ -n "$filters" ] && filters="${filters},"
  filters="${filters}drawbox=x=${x}:y=0:w=50:h=50:color=white:t=fill:enable='gt(bitand(n\\,${bit})\\,0)'"
done

# Sync samples where we ask for them, with a deliberate 12 s drought between 43 s and 55 s: long
# enough that the gate's 4 / 8 / 16 / 32 s backoff has to escalate to reach a covering sample.
KEYS="0,1.5,3.2,7.1,10.3,14.9,18.2,22.7,26.1,30.5,34.2,38.4,43.0,55.0,56.5,58.9,61.3,64.8,67.2,71.6,75.1,79.4,83.8,87.2,91.6,95.1,99.5,103.2,107.8,111.4,115.9"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=640x360:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -vf "$filters" \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \
  -force_key_frames "$KEYS" -b:v 2M \
  -c:a aac -b:a 128k -shortest \
  "$OUT_DIR/tc-drought.mkv"
echo "wrote $OUT_DIR/tc-drought.mkv (${DUR}s, ${FPS}fps, source time = frame index / ${FPS})"

# The same fixture WITH B-frames (AE#418 round 4). Everything else is identical, so the pair isolates
# one variable: whether the epoch's first random-access point is presented where it is decoded.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=640x360:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -vf "$filters" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \
  -bf 3 -x264-params "b-pyramid=normal:open-gop=0" \
  -force_key_frames "$KEYS" -b:v 2M \
  -c:a aac -b:a 128k -shortest \
  "$OUT_DIR/tc-bframes.mkv"
echo "wrote $OUT_DIR/tc-bframes.mkv (same, has_b_frames=2)"

# AE#418 round 6: one frame of reorder instead of two, which is what the reporter's asset carries and
# what falsified round 5's constant. Everything else identical again, so the three clips differ in
# reorder depth alone.
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=black:s=640x360:r=${FPS}:d=${DUR}" \
  -f lavfi -i "sine=frequency=440:duration=${DUR}" \
  -vf "$filters" \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -g 1000 -sc_threshold 0 \
  -bf 1 -x264-params "b-pyramid=none:open-gop=0" \
  -force_key_frames "$KEYS" -b:v 2M \
  -c:a aac -b:a 128k -shortest \
  "$OUT_DIR/tc-bf1.mkv"
echo "wrote $OUT_DIR/tc-bf1.mkv (same, has_b_frames=1)"

# AE#534: the offset twin, when an origin is asked for.
#
# Every axis fixture in this repo starts at zero, and on a zero-origin source "this run carries no
# placement offset" and "item time is source time here" are the same number, so only the first of
# them is ever actually tested. A recording cut out of a longer one, or a TS remux, is not an exotic
# case. The twin is one `-c copy` remux away, and the ORDER matters: offset FIRST, inject Cues after,
# because a matroska remux regenerates Cues from the real keyframes and would undo the lie.
#
#   Scripts/timecode-fixture.sh /tmp/fx 600
#   python3 Scripts/mkv-cue-fixture.py /tmp/fx/tc-drought-600.mkv /tmp/fx/tc-cues-lie-600.mkv \
#       "$(python3 -c 'print(",".join(str(i) for i in range(601,720)))')"
#   swift run aetherctl play --seconds 60 --start-position 673 --picture-probe --picture-origin 600 \
#       --seek-every 12 --seek-count 1 --seek-pattern 680 file:///tmp/fx/tc-cues-lie-600.mkv
#
# `--picture-origin` is what keeps the verdict readable: the picture states a frame index, which the
# offset does not move, so without it `capErr` reads about -599.983 where the honest value is -0.017.
OFFSET="${2:-}"
if [ -n "$OFFSET" ]; then
  for base in tc-drought tc-bframes tc-bf1; do
    ffmpeg -hide_banner -loglevel error -y \
      -i "$OUT_DIR/$base.mkv" -c copy -output_ts_offset "$OFFSET" \
      "$OUT_DIR/$base-$OFFSET.mkv"
    echo "wrote $OUT_DIR/$base-$OFFSET.mkv (same picture, source timeline starts at ${OFFSET}s)"
  done
fi
