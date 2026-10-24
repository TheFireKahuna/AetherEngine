#!/bin/zsh
# The deinterlace card (deint_card.swift) as 1080i25 MPEG-2 in MPEG-TS, for SEQ=deint:
#   out/deint_tff.ts  woven top field first and flagged so: the correct clip
#   out/deint_bff.ts  the same weave flagged bottom field first: the control, deinterlaced with
#                     the field order wrong (the box steps back every other field, numbers 1, 0, 3, 2)
#   out/deint_prog50.ts  the card as progressive 50p (30 s): the software route without the deinterlacer
# 60 s each, with a quiet 440 Hz tone so the route has an audio clock.
set -eo pipefail
HERE="${0:a:h}"
OUT=${PULSE_OUT:-$HERE/../out}
BIN="$OUT/deint_card"
mkdir -p "$OUT"
swiftc -O "$HERE/deint_card.swift" -o "$BIN"
for order in tff bff; do
  echo "→ $OUT/deint_$order.ts"
  "$BIN" 3000 | ffmpeg -hide_banner -loglevel error -y \
    -f rawvideo -pix_fmt gray -s 1920x1080 -r 50 -i - \
    -f lavfi -i "sine=f=440:r=48000,volume=0.1" -t 60 \
    -vf "format=yuv420p,tinterlace=interleave_top,setfield=$order" \
    -c:v mpeg2video -b:v 25M -maxrate 30M -bufsize 9M -g 12 -bf 2 -flags +ilme+ildct -alternate_scan 1 \
    -c:a mp2 -b:a 192k -f mpegts "$OUT/deint_$order.ts"
done
# The control: the same card as progressive 50p, which the deinterlacer never touches.
echo "→ $OUT/deint_prog50.ts"
"$BIN" 1500 | ffmpeg -hide_banner -loglevel error -y \
  -f rawvideo -pix_fmt gray -s 1920x1080 -r 50 -i - \
  -f lavfi -i "sine=f=440:r=48000,volume=0.1" -t 30 -vf format=yuv420p \
  -c:v mpeg2video -b:v 25M -maxrate 30M -bufsize 9M -g 24 -bf 2 \
  -c:a mp2 -b:a 192k -f mpegts "$OUT/deint_prog50.ts"
for order in tff bff; do
  ffprobe -v error -select_streams v -show_entries stream=field_order,avg_frame_rate:format=duration -of compact "$OUT/deint_$order.ts"
done
