#!/bin/zsh
# Synthetic Profile 7 FEL soak clip (out/p7fel_soak.mp4): what a real title costs the decoder and composer,
# without needing one. 4752 frames (3 min 18 s at 23.976): a moving, noisy 4K BL at ~40 Mb/s with the VUI
# of a UHD Blu-ray (BT.2020 PQ, chroma_sample_loc_type 2), a lossy 1080p EL, and dovi_tool's real FEL RPU
# (fel_rpu_null.bin, order-3 MMR chroma) on every frame. The picture is not meaningful; the load is.
# Needs build.sh's out/fel_rpu_null.bin, plus ffmpeg, x265, dovi_tool, MP4Box.
set -euo pipefail
cd "${0:A:h}/../out"
N=4752
[[ -s fel_rpu_null.bin ]] || { echo "run Scripts/build.sh first (needs out/fel_rpu_null.bin)"; exit 1; }
X265=(--fps 24000/1001 --input-depth 10 --input-csp i420 --output-depth 10 --profile main10
      --keyint 48 --min-keyint 48 --no-scenecut --no-open-gop --repeat-headers --aud --frames $N)
if [[ ! -s soak_bl.hevc ]]; then
  ffmpeg -v error -f lavfi -i "testsrc2=s=3840x2160:r=24000/1001,noise=alls=10:allf=t+u,format=yuv420p10le" \
    -frames:v $N -f rawvideo - | x265 --input - --input-res 3840x2160 "${X265[@]}" --preset superfast \
    --bitrate 40000 --vbv-bufsize 80000 --vbv-maxrate 60000 \
    --colorprim bt2020 --transfer smpte2084 --colormatrix bt2020nc --range limited --chromaloc 2 \
    --master-display "G(8500,39850)B(6550,2300)R(35400,14600)WP(15635,16450)L(10000000,50)" \
    --max-cll "1000,400" --hdr10 -o soak_bl.hevc.tmp
  mv soak_bl.hevc.tmp soak_bl.hevc
fi
if [[ ! -s soak_el.hevc ]]; then
  ffmpeg -v error -f lavfi -i "color=c=0x808080:s=1920x1080:r=24000/1001,noise=alls=6:allf=t+u,format=yuv420p10le" \
    -frames:v $N -f rawvideo - | x265 --input - --input-res 1920x1080 "${X265[@]}" --preset superfast \
    --crf 22 -o soak_el.hevc.tmp
  mv soak_el.hevc.tmp soak_el.hevc
fi
cat fel_rpu_null.bin fel_rpu_null.bin fel_rpu_null.bin > soak_rpu.bin
dovi_tool inject-rpu -i soak_el.hevc --rpu-in soak_rpu.bin -o soak_el_rpu.hevc
dovi_tool mux --bl soak_bl.hevc --el soak_el_rpu.hevc -o p7_soak.hevc
rm -f p7fel_soak.mp4
MP4Box -add p7_soak.hevc:fps=24000/1001:dvp=f7.6 -brand mp42isom -ab dby1 -quiet -new p7fel_soak.mp4
rm -f soak_el_rpu.hevc p7_soak.hevc soak_rpu.bin
ls -l p7fel_soak.mp4
