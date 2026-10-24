#!/bin/zsh
# Builds the placeholder clips for SEQ=placeholder (the `placeholder` arms of the pulse host) into $PULSE_OUT
# (default ../out). Run Scripts/build.sh first: these reuse its RPUs and match its clips' timeline.
#
# The question: can AVPlayer play a stand-in video track (flat picture, real format) whose rendering is
# suppressed, while the picture comes from frames we decode ourselves and enqueue on a layer inside AVKit's
# player layer? The placeholder matches the pulse clips in everything but the picture: 3840x2160, Main10,
# BT.2020 PQ with the same mastering metadata, 24000/1001, 1584 frames, a keyframe every 48. The Atmos
# E-AC-3 JOC demo (48.6 s) rides along as the audio.
#
#   ph_dv_null.mp4   Profile 8.1, constant RPU (rpu_null.bin)
#   ph_dv_l2.mp4     Profile 8.1, the L2 pulse RPU (rpu_l2.bin): the control for AVPlayer's own RPU reaching HDMI
#   ph_hdr10.mp4     plain HEVC HDR10, no Dolby Vision
#
# JOC (default: research/apac-objects/tvtest/media/ddp_joc_demo.mp4) overrides the audio source.
set -euo pipefail
HERE=${0:A:h}
OUT=${PULSE_OUT:-$HERE/../out}
OUT=${OUT:A}
JOC=${JOC:-$HERE/../../../../research/apac-objects/tvtest/media/ddp_joc_demo.mp4}
JOC=${JOC:A}

for tool in x265 dovi_tool MP4Box ffmpeg; do
  command -v $tool >/dev/null || { echo "missing tool: $tool (brew install x265 dovi_tool gpac ffmpeg)"; exit 1; }
done
for f in rpu_null.bin rpu_l2.bin pulse_l2.mp4; do
  [[ -s "$OUT/$f" ]] || { echo "missing $OUT/$f: run Scripts/build.sh first"; exit 1; }
done
[[ -s "$JOC" ]] || { echo "missing the Atmos audio $JOC (set JOC=<mp4 with an E-AC-3 JOC track>)"; exit 1; }
cd "$OUT"

# Flat dark grey, every frame the same: the encoder spends almost nothing past the first picture of each GOP.
# The x265 settings are base.hevc's apart from the preset and CRF, which only change how small it gets.
if [[ ! -s ph_flat.hevc ]]; then
  ffmpeg -v error -f lavfi -i "color=c=0x303030:s=3840x2160:r=24000/1001" -frames:v 1584 \
    -pix_fmt yuv420p10le -f rawvideo - |
  x265 --input - --input-res 3840x2160 --fps 24000/1001 \
    --input-depth 10 --input-csp i420 --output-depth 10 --profile main10 \
    --preset ultrafast --crf 28 --keyint 48 --min-keyint 48 --no-scenecut --no-open-gop \
    --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --range limited \
    --master-display "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(100000000,50)" \
    --max-cll "10000,400" --hdr10 --hdr10-opt --repeat-headers --aud \
    --frames 1584 -o ph_flat.hevc.tmp
  mv ph_flat.hevc.tmp ph_flat.hevc
fi

mux() {   # mux <hevc> <dvp option or ""> <out.mp4>
  local brand=()
  [[ -n "$2" ]] && brand=(-ab dby1)
  rm -f "$3"
  MP4Box -add "$1:fps=24000/1001${2:+:dvp=$2}" -add "$JOC#audio" -brand mp42isom "${brand[@]}" -quiet -new "$3"
}
for v in null l2; do
  dovi_tool inject-rpu -i ph_flat.hevc --rpu-in rpu_$v.bin -o ph_dv_$v.hevc
  mux ph_dv_$v.hevc f8.1 ph_dv_$v.mp4
  rm ph_dv_$v.hevc
done
mux ph_flat.hevc "" ph_hdr10.mp4

# The overlay pairs frames by presentation time, so the placeholder's first frame must sit where the pulse
# clip's does.
first() { ffprobe -v error -select_streams v:0 -show_entries packet=pts_time -of csv=p=0 "$1" | sort -g | head -1 }
echo "first video pts: pulse_l2 $(first pulse_l2.mp4)  ph_dv_null $(first ph_dv_null.mp4)  ph_hdr10 $(first ph_hdr10.mp4)"
ls -la ph_*.mp4
