#!/bin/zsh
# Film in interlaced carriage for SEQ=film (docs/software-route-gpu.md Part 6), from the pan card (pan_card.swift):
# bars and ruler ticks panning 12 px per film frame, the motion where cadence errors show:
#   out/film_soft.ts  23.976 film, MPEG-2 coded progressive, 3:2 soft telecine (mpeg2_pulldown.py), 29.97 carriage
#   out/film_hard.ts  the same film hard-telecined (FFmpeg's telecine filter), MPEG-2 coded interlaced, 29.97
#   out/film_psf.ts   25 fps film in 1080i25 (2:2): each film frame's two fields, MPEG-2 coded interlaced
# 40 s each, with a quiet tone.
set -eo pipefail
HERE="${0:a:h}"
OUT=${PULSE_OUT:-$HERE/../out}
BIN="$OUT/pan_card"
mkdir -p "$OUT"
swiftc -O "$HERE/pan_card.swift" -o "$BIN"
TONE=(-f lavfi -i "sine=f=440:r=48000,volume=0.1")
M2V=(-c:v mpeg2video -b:v 25M -maxrate 30M -bufsize 9M -g 12)

echo "→ $OUT/film_soft.ts"
"$BIN" 960 | ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt gray -s 1920x1080 -r 24000/1001 -i - \
  -vf format=yuv420p "${M2V[@]}" -bf 0 -f mpeg2video "$OUT/film_soft24.m2v"
python3 -I "$HERE/mpeg2_pulldown.py" "$OUT/film_soft24.m2v" "$OUT/film_soft.m2v"
ffmpeg -hide_banner -loglevel error -y -fflags +genpts -f mpegvideo -i "$OUT/film_soft.m2v" "${TONE[@]}" -t 40 \
  -c:v copy -c:a mp2 -b:a 192k -f mpegts "$OUT/film_soft.ts"

echo "→ $OUT/film_hard.ts"
"$BIN" 960 | ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt gray -s 1920x1080 -r 24000/1001 -i - \
  "${TONE[@]}" -t 40 -vf "format=yuv420p,telecine=first_field=top:pattern=23,setfield=tff" \
  "${M2V[@]}" -bf 2 -flags +ilme+ildct -alternate_scan 1 -c:a mp2 -b:a 192k -f mpegts "$OUT/film_hard.ts"

echo "→ $OUT/film_psf.ts"
"$BIN" 1000 | ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt gray -s 1920x1080 -r 25 -i - \
  "${TONE[@]}" -t 40 -vf "format=yuv420p,setfield=tff" \
  "${M2V[@]}" -bf 2 -flags +ilme+ildct -alternate_scan 1 -c:a mp2 -b:a 192k -f mpegts "$OUT/film_psf.ts"

for clip in film_soft film_hard film_psf; do
  ffprobe -v error -select_streams v -show_entries stream=field_order,avg_frame_rate:format=duration -of compact "$OUT/$clip.ts"
done
