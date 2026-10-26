#!/usr/bin/env bash
# Generate a small set of synthetic test clips under ./Fixtures/ for
# engine validation runs. Each clip is short (5 s) and deterministic
# (FFmpeg's testsrc2 source filter), so the output is reproducible
# across machines and copyright-clean. The clips exercise the four
# codec paths AetherEngine cares about:
#
#   sdr-h264.mp4    - H.264 BT.709, native AVPlayer path
#   hdr10-hevc.mp4  - HEVC Main10 BT.2020 / PQ, native AVPlayer path with HDR
#   av1.mp4         - AV1, software dav1d path on devices without HW
#   vp9.webm        - VP9, software libavcodec path
#   overlay-mpeg2.mkv - MPEG-2 + AAC, 8 s, a keyframe every 2 s: the software overlay over an AVPlayer placeholder
#   overlay-mpeg2-interlaced.mkv - the same, 576i25 video: deinterlaced at the field rate, 50 pictures a second
#   overlay-mpeg2-telecine.mkv    - the same, 23.976 film in 3:2 hard telecine at 480i29.97: inverse telecined
#   overlay-mpeg2-soft-telecine.ts  - the same, 23.976 film soft-telecined to 29.97 carriage: the film grid
#
# plus two clips for RestartTimelineContinuityTests (the suite skips
# those tests when the clips are absent, e.g. on CI):
#
#   restart-witness-av.mp4        - H.264 B-frames + AAC, 12 s (3 segments)
#   restart-witness-leadaudio.mp4 - same, video delayed 0.3 s so audio leads
#   restart-witness-subs.mkv      - same as MKV with an embedded SRT track (pump tap)
#   a53-captions.mp4              - H.264 with in-picture A/53 CEA-608 SEI (#131, #259)
#   hev1-inband-xps.mp4           - HEVC with in-band VPS/SPS/PPS and an empty hvcC
#   cue-axis-bframes.mkv/.mp4     - one HEVC B-pyramid stream in both containers (AE#561)
#   long-first-gop-{aac,pcm}.mkv  - 11 s first GOP, then 2 s GOPs; passthrough and bridged audio
#   bridge-eac3-51.mkv            - 5.1 PCM in MKV, drives the EAC3 audio bridge (AE#561 follow-up)
#   avsync/*                      - a white frame and a click at exactly 1 s, per audio codec and
#                                   container, for AVSyncTests (audio against video, to the sample)
#   decmem/*                      - 12 s of music-like audio in every codec the audio bridge decodes,
#                                   for AudioDecoderMemoryTests (a decode started anywhere matches a
#                                   continuous one past the decoder's declared memory)
#   determinism/*                 - 24 s of moving picture and music-like audio per audio route, for
#                                   ProducerDeterminismTests (segment N is the same bytes however
#                                   playback reached it)
#
# Real-world DV / Atmos / multichannel sources have to come from your
# own library. Drop those into ./Fixtures/user/ (also gitignored)
# and reference them from aetherctl runs.
#
# Usage:
#   ./Scripts/fetch-fixtures.sh
#
# Requires:
#   - ffmpeg with libx264, libx265, libaom-av1, libvpx-vp9 enabled (and libopus, libmp3lame for
#     the avsync clips).
#     macOS: `brew install ffmpeg` covers all four codecs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURES_DIR="$REPO_ROOT/Fixtures"
mkdir -p "$FIXTURES_DIR/user"

# Drop a README into the user dir on first run so the gitignore +
# intent are obvious if someone goes looking.
USER_README="$FIXTURES_DIR/user/README.md"
if [[ ! -f "$USER_README" ]]; then
    cat > "$USER_README" <<'EOF'
# user fixtures

This directory is gitignored. Drop real-world test sources here
(Dolby Vision MKVs, Atmos EAC3+JOC streams, multichannel sources,
etc.) and reference them from `aetherctl probe / serve / validate`
runs without worrying about accidentally pushing them.
EOF
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "ERROR: ffmpeg not on PATH. Install with: brew install ffmpeg" >&2
    exit 1
fi

echo "Fixtures dir: $FIXTURES_DIR"
echo ""

# H.264 SDR 1080p
echo "→ sdr-h264.mp4 (H.264 BT.709 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
    "$FIXTURES_DIR/sdr-h264.mp4"

# HEVC HDR10 1080p
echo "→ hdr10-hevc.mp4 (HEVC Main10 BT.2020 / PQ 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -vf "format=yuv420p10le" \
    -c:v libx265 -preset ultrafast \
    -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:hdr10=1" \
    -pix_fmt yuv420p10le \
    -tag:v hvc1 \
    "$FIXTURES_DIR/hdr10-hevc.mp4"

# AV1 SDR 1080p. Either AV1 encoder will do, the fixture only has to BE AV1.
# Homebrew's ffmpeg ships libsvtav1 and, depending on the formula's options, no
# libaom, and under `set -e` that missing encoder used to abort the whole run and
# leave the corpus half regenerated.
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " libaom-av1 "; then
    AV1_ENC=(-c:v libaom-av1 -crf 30 -b:v 0 -cpu-used 8)
elif ffmpeg -hide_banner -encoders 2>/dev/null | grep -q " libsvtav1 "; then
    AV1_ENC=(-c:v libsvtav1 -crf 30 -preset 10)
else
    AV1_ENC=()
fi
if [ ${#AV1_ENC[@]} -gt 0 ]; then
    echo "→ av1.mp4 (AV1 1080p @ 24fps, low CPU preset)"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
        -t 5 "${AV1_ENC[@]}" \
        "$FIXTURES_DIR/av1.mp4"
else
    echo "→ av1.mp4 SKIPPED (no libaom-av1 and no libsvtav1 in this ffmpeg)"
fi

# VP9 SDR 1080p
echo "→ vp9.webm (VP9 1080p @ 24fps)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1920x1080:rate=24" \
    -t 5 -c:v libvpx-vp9 -crf 30 -b:v 0 -cpu-used 8 \
    "$FIXTURES_DIR/vp9.webm"

# MPEG-2 with B-frames and AAC: a codec AVPlayer cannot decode, so the session decodes it and shows it in the
# software overlay over a placeholder (docs/software-route-gpu.md Part 1). Drives SoftwareOverlayEngineTests.
echo "→ overlay-mpeg2.mkv (MPEG-2 720p @ 25fps + AAC, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=1280x720:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 8 -c:v mpeg2video -q:v 4 -g 50 -bf 2 -c:a aac -b:a 128k \
    "$FIXTURES_DIR/overlay-mpeg2.mkv"

# The overlay's pictures that do not follow the placeholder's frames one for one (SoftwareOverlayEngineTests):
# real interlaced video, deinterlaced at the field rate; film in 3:2 hard telecine, which the load finds and inverse
# telecines to 4/5 of the carriage rate; film soft-telecined with repeat-field flags, played on the film grid.
echo "→ overlay-mpeg2-interlaced.mkv (MPEG-2 576i25 + AAC, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=720x576:rate=50" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 8 -vf "tinterlace=interleave_top,setfield=tff" -c:v mpeg2video -q:v 4 -g 50 -bf 2 \
    -flags +ildct+ilme -field_order tt -pix_fmt yuv420p -c:a aac -b:a 128k \
    "$FIXTURES_DIR/overlay-mpeg2-interlaced.mkv"

# Drawn at 180x120 and scaled up: testsrc2's moving parts drawn at 720x480 cover too little of the picture for the
# load's comb detector to see the cadence.
echo "→ overlay-mpeg2-telecine.mkv (23.976 film in 3:2 hard telecine, MPEG-2 480i29.97 + AAC, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=180x120:rate=24000/1001,scale=720:480:flags=neighbor" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 8 -vf "telecine=first_field=top:pattern=23,setfield=tff" -c:v mpeg2video -q:v 4 -g 15 -bf 2 \
    -flags +ildct+ilme -field_order tt -pix_fmt yuv420p -c:a aac -b:a 128k \
    "$FIXTURES_DIR/overlay-mpeg2-telecine.mkv"

# MPEG-TS, which states the carriage rate the load looks for; Matroska keeps only the timestamps.
echo "→ overlay-mpeg2-soft-telecine.ts (23.976 film soft-telecined to 29.97 carriage, MPEG-2 + AAC, 8s)"
SOFT_DIR="$(mktemp -d)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=720x480:rate=24000/1001" -frames:v 192 \
    -c:v mpeg2video -q:v 4 -bf 0 -g 12 -pix_fmt yuv420p -f mpeg2video "$SOFT_DIR/film.m2v"
python3 "$REPO_ROOT/Probes/DolbyVisionPulse/Scripts/mpeg2_pulldown.py" "$SOFT_DIR/film.m2v" "$SOFT_DIR/soft.m2v"
ffmpeg -hide_banner -loglevel error -y \
    -fflags +genpts -f mpegvideo -i "$SOFT_DIR/soft.m2v" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" \
    -t 8 -c:v copy -c:a aac -b:a 128k -muxrate 0 -f mpegts \
    "$FIXTURES_DIR/overlay-mpeg2-soft-telecine.ts"

# Restart-continuity witness: A/V with real B-frame reorder (bf 3) and a keyframe
# every 2 s so the 4 s segment plan cuts on keyframes. Drives
# RestartTimelineContinuityTests (continuous vs restarted segment equality).
echo "→ restart-witness-av.mp4 (H.264 B-frames + AAC mono, 12s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=12" \
    -c:v libx264 -preset veryfast -bf 3 -g 48 -pix_fmt yuv420p -b:v 200k \
    -c:a aac -b:a 48k -ac 1 -shortest \
    "$FIXTURES_DIR/restart-witness-av.mp4"

# Same content with the video track delayed 0.3 s, so the audio leads the
# video anchor at head-of-stream (the leading-audio guard scenario).
echo "→ restart-witness-leadaudio.mp4 (audio leads video by 0.3s, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -itsoffset 0.3 -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" \
    -map 0:v -map 1:a -c copy -t 8 \
    "$FIXTURES_DIR/restart-witness-leadaudio.mp4"

# Same content as MKV with an embedded SRT track (the subtitle pump-tap scenario,
# SubtitlePumpTapTests).
echo "→ restart-witness-subs.mkv (embedded SRT track)"
SRT_TMP="$(mktemp -t witness-subs).srt"
cat > "$SRT_TMP" <<'SRT'
1
00:00:00,500 --> 00:00:02,000
First cue

2
00:00:02,500 --> 00:00:04,500
Second cue crossing the first boundary

3
00:00:05,000 --> 00:00:07,000
Third cue

4
00:00:08,200 --> 00:00:10,000
Fourth cue

5
00:00:10,500 --> 00:00:11,500
Fifth cue
SRT
ffmpeg -hide_banner -loglevel error -y \
    -i "$FIXTURES_DIR/restart-witness-av.mp4" -i "$SRT_TMP" \
    -map 0:v -map 0:a -map 1:0 -c:v copy -c:a copy -c:s srt \
    -metadata:s:s:0 language=eng \
    "$FIXTURES_DIR/restart-witness-subs.mkv"
rm -f "$SRT_TMP"

# A/53 in-picture captions (#131, #259): US broadcast sources carry CEA-608 inside the
# video as user_data_registered_itu_t_t35 SEI, and no encoder emits those from a synthetic
# source, so they are injected here. Every access unit gets a cc_data SEI: the null pad pair
# real encoders send continuously, except every 48th AU (2 s at 24 fps), which carries a
# COMPLETE pop-on sequence (RCL, ENM, PAC, characters, EOC) in one SEI, so the caption is
# atomic inside a single access unit and survives B-frame reordering. B-frames stay on
# (-bf 3): they give the producer a non-zero playlist shift, which is what the axis witness
# in Issue259A53CaptionAxisTests measures.
echo "→ a53-captions.mp4 (H.264 with in-picture A/53 CEA-608 SEI, 12s)"
A53_RAW="$(mktemp -t a53-raw).264"
A53_CC="$(mktemp -t a53-cc).264"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=duration=12:size=320x180:rate=24" \
    -c:v libx264 -preset veryfast -bf 3 -g 48 -pix_fmt yuv420p -b:v 200k \
    -bsf:v "h264_metadata=aud=insert" -f h264 "$A53_RAW"
python3 - "$A53_RAW" "$A53_CC" <<'PY'
import sys

def odd_parity(v):
    v &= 0x7F
    return v if bin(v).count('1') % 2 == 1 else (v | 0x80)

# A complete pop-on caption: RCL, ENM, PAC row 1 col 0, character pairs, EOC.
def caption_pairs(text):
    pairs = [(0x14, 0x20), (0x14, 0x2E), (0x11, 0x40)]
    b = text.encode('ascii')
    for i in range(0, len(b), 2):
        pairs.append((b[i], b[i + 1] if i + 1 < len(b) else 0x00))
    pairs.append((0x14, 0x2F))
    return [(odd_parity(a), odd_parity(c)) for a, c in pairs]

# cc_data SEI: country 0xB5, provider 0x0031, "GA94", user_data_type_code 0x03, then
# process_cc_data_flag | cc_count, em_data, cc_count * (0xFC marker + 608 pair), marker.
def sei_nal(pairs):
    payload = bytearray([0xB5, 0x00, 0x31, 0x47, 0x41, 0x39, 0x34, 0x03])
    payload += bytes([0x40 | len(pairs), 0xFF])
    for d0, d1 in pairs:
        payload += bytes([0xFC, d0, d1])
    payload += b'\xFF'
    rbsp = bytearray([4])                      # payload_type: user_data_registered_itu_t_t35
    n = len(payload)
    while n >= 255:
        rbsp.append(0xFF)
        n -= 255
    rbsp.append(n)
    rbsp += payload
    rbsp.append(0x80)                          # rbsp_trailing_bits
    escaped = bytearray()
    zeros = 0
    for byte in rbsp:                          # emulation prevention
        if zeros >= 2 and byte <= 0x03:
            escaped.append(0x03)
            zeros = 0
        escaped.append(byte)
        zeros = zeros + 1 if byte == 0 else 0
    return b'\x00\x00\x00\x01\x06' + bytes(escaped)

src, dst = sys.argv[1], sys.argv[2]
data = open(src, 'rb').read()
out = bytearray()
prev = 0
au = 0
captions = 0
i = 0
while i + 3 <= len(data):
    if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
        payload = i + 3
        if data[payload] & 0x1F == 9:          # access unit delimiter: AU boundary
            end = payload + 2                  # AUD is header + primary_pic_type
            out += data[prev:end]
            if au % 48 == 0:
                captions += 1
                out += sei_nal(caption_pairs('CUE %d' % captions))
            else:
                out += sei_nal([(0x80, 0x80)])
            prev = end
            au += 1
        i += 3
    else:
        i += 1
out += data[prev:]
open(dst, 'wb').write(bytes(out))
print('    %d access units, %d captions' % (au, captions))
PY
ffmpeg -hide_banner -loglevel error -y \
    -f h264 -r 24 -i "$A53_CC" \
    -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=12" \
    -map 0:v -map 1:a -c:v copy -c:a aac -b:a 48k -ac 1 -shortest \
    "$FIXTURES_DIR/a53-captions.mp4"
rm -f "$A53_RAW" "$A53_CC"

# HEVC whose parameter sets live IN-BAND only: hev1 sample entry, hvcC header with
# numOfArrays = 0. That is what `MP4Box ...:xps_inband` and the common Dolby-Vision MP4
# authoring recipes write, and what the init.mp4 normalizer has to rebuild from packets
# (AetherPlayer#2, engine #19). ffmpeg always writes the parameter-set arrays, so the
# shape is synthesized: x265 repeats the headers in-band, then the hvcC payload is
# truncated to its 22-byte header + numOfArrays = 0 and the freed bytes are absorbed by a
# sibling `free` box, which keeps every parent box size and chunk offset valid.
# keyint 120 (5 s at 24 fps) puts the IRAPs far enough apart that a mid-GOP scan cannot
# stumble onto one by luck.
echo "→ hev1-inband-xps.mp4 (HEVC with in-band VPS/SPS/PPS, empty hvcC)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i testsrc2=size=320x240:rate=24 -t 6 \
    -c:v libx265 -x265-params "repeat-headers=1:keyint=120:min-keyint=120:log-level=none" \
    -tag:v hev1 "$FIXTURES_DIR/hev1-inband-xps.mp4"
python3 - "$FIXTURES_DIR/hev1-inband-xps.mp4" <<'PY'
import sys

path = sys.argv[1]
data = bytearray(open(path, 'rb').read())
tag = data.find(b'hvcC')
start = tag - 4
size = int.from_bytes(data[start:start + 4], 'big')
payload = data[tag + 4:start + size]
emptied = bytes(payload[:22]) + b'\x00'   # numOfArrays = 0
freed = size - (8 + len(emptied))
assert freed >= 8, f'hvcC too small to empty in place: {size}'
replacement = bytearray()
replacement += (8 + len(emptied)).to_bytes(4, 'big') + b'hvcC' + emptied
replacement += freed.to_bytes(4, 'big') + b'free' + bytes(freed - 8)
data[start:start + size] = replacement
open(path, 'wb').write(bytes(data))
PY

# AE#561: one HEVC elementary stream in both containers, so the only difference between the two
# files is what their index entries are stamped on. A Matroska Cue stores a presentation time, a
# mov/mp4 sample table stores decode times, and the keyframe-aligned plan's boundaries ARE those
# entries. B-frames (b-pyramid) are what makes the two axes differ at all; a dense keyint puts an
# IRAP well inside every 4 s segment, so a segment that lost its own IRAP still carries a later one
# and the defect shows as "opens below its first random-access point" rather than as no picture.
# The .mp4 is a stream copy on purpose: same packets, same timestamps, different index stamping.
echo "→ cue-axis-bframes.mkv + .mp4 (HEVC B-pyramid, same stream in both containers, 16s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=480x270:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 16 \
    -c:v libx265 -preset ultrafast -pix_fmt yuv420p \
    -x265-params "keyint=21:min-keyint=21:scenecut=0:bframes=4:b-pyramid=1:log-level=none" \
    -c:a aac -b:a 96k "$FIXTURES_DIR/cue-axis-bframes.mkv"
ffmpeg -hide_banner -loglevel error -y \
    -i "$FIXTURES_DIR/cue-axis-bframes.mkv" -c copy \
    "$FIXTURES_DIR/cue-axis-bframes.mp4"

# AE#561 follow-up: multichannel PCM in Matroska, which routes audio through the bridge in
# surround-compat mode, so the encoder is EAC3 rather than FLAC. That distinction is the whole
# point: FFmpeg's AC-3 family declares `initial_padding = 256` and stamps its first packet a
# padding below the frame it encoded, while FLAC declares none. 5.1 because the mode only reaches
# for EAC3 above two channels.
echo "→ bridge-eac3-51.mkv (5.1 PCM in MKV, drives the EAC3 bridge, 8s)"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=24" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 8 \
    -c:v libx264 -preset veryfast -g 48 -pix_fmt yuv420p -b:v 200k \
    -af "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0" \
    -c:a pcm_s24le "$FIXTURES_DIR/bridge-eac3-51.mkv"

# AetherEngine#268: finite HEVC-in-MPEG-TS HLS VOD, the carriage AVFoundation refuses to build a
# video track for. Three shapes, because each one only shows its own defect:
#   hls-hevc-vod/        PTS origin at ffmpeg's default 1.4 s, 6 s segments, 2 s GOP
#   hls-hevc-vod-offset/ PTS origin at ~1001 s, what broadcast-derived VOD carries (seek axis)
#   hls-hevc-vod-longgop/ 20 min, 10 s segments, ONE I-frame per segment (segment plan)
# plus an H.264 control that has to STAY on the native AVPlayer route. Serve the parent directory
# over HTTP (any static, range-capable origin) and drive it with
# `aetherctl play --seek-every 6 --seek-pattern 500,120 http://127.0.0.1:PORT/hls-hevc-vod/media.m3u8`.
echo "→ user/hls-hevc-vod* (HEVC-in-MPEG-TS HLS VOD, #268 route)"
hls_vod_fixture() {  # <dir> <encoder> <extra-out-args...>
    local dir="$FIXTURES_DIR/user/$1"; shift
    local codec="$1"; shift
    rm -rf "$dir" && mkdir -p "$dir"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=960x540:rate=25" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 120 \
        -c:v "$codec" -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 96k "$@" \
        -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type vod \
        -hls_segment_filename "$dir/seg%03d.ts" "$dir/media.m3u8"
}
hls_vod_fixture hls-hevc-vod libx265 -x265-params "keyint=50:min-keyint=50:scenecut=0:log-level=none"
hls_vod_fixture hls-h264-vod libx264 -g 50 -keyint_min 50 -sc_threshold 0

# The GOP is the point: one I-frame per 10 s segment, the reporter's shape. A 2 s GOP (above) hides
# the #268 round 2 defect entirely, because every plan boundary then still catches a keyframe. It
# also has to be long enough that a seek lands outside what the ingest has already produced, so
# 20 min rather than 120 s. Drive it with a target that is NOT a multiple of 20 s, e.g.
# `aetherctl play --seek-every 14 --seek-pattern 1055.79,333.3,777.7 http://127.0.0.1:PORT/hls-hevc-vod-longgop/media.m3u8`
# and watch `video gate open`: `anchorPts - target` must stay at the plan's boundary backoff.
LONGGOP_TS="$FIXTURES_DIR/user/hevc-longgop.ts"
LONGGOP_DIR="$FIXTURES_DIR/user/hls-hevc-vod-longgop"
rm -rf "$LONGGOP_DIR" && mkdir -p "$LONGGOP_DIR"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=320x180:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 1200 \
    -c:v libx265 -preset ultrafast \
    -x265-params "keyint=250:min-keyint=250:scenecut=0:log-level=none" \
    -pix_fmt yuv420p -c:a aac -b:a 64k -f mpegts "$LONGGOP_TS"
ffmpeg -hide_banner -loglevel error -y -i "$LONGGOP_TS" -c copy \
    -f hls -hls_time 10 -hls_list_size 0 -hls_playlist_type vod \
    -hls_segment_filename "$LONGGOP_DIR/seg%03d.ts" "$LONGGOP_DIR/media.m3u8"

# Broadcast-style PTS origin: mux once with the offset, then segment with -copyts so the segments
# keep it. A reader that mistakes an absolute source PTS for playlist time seeks to the wrong end of
# this one.
OFFSET_TS="$FIXTURES_DIR/user/hevc-offset.ts"
rm -rf "$FIXTURES_DIR/user/hls-hevc-vod-offset" && mkdir -p "$FIXTURES_DIR/user/hls-hevc-vod-offset"
ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=960x540:rate=25" \
    -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 120 \
    -c:v libx265 -preset ultrafast -x265-params "keyint=50:min-keyint=50:scenecut=0:log-level=none" \
    -pix_fmt yuv420p -c:a aac -b:a 96k -output_ts_offset 1000 -f mpegts "$OFFSET_TS"
ffmpeg -hide_banner -loglevel error -y -copyts -i "$OFFSET_TS" -c copy \
    -f hls -hls_time 6 -hls_list_size 0 -hls_playlist_type vod \
    -hls_segment_filename "$FIXTURES_DIR/user/hls-hevc-vod-offset/seg%03d.ts" \
    "$FIXTURES_DIR/user/hls-hevc-vod-offset/media.m3u8"

# A sequential origin's playlist is cut on video keyframes. A first GOP far longer than the 4 s stride
# is the shape a remote MKV had (11.3 s). Served forward-only its Cues are never read, so the plan is
# the uniform stride and audio reaches every boundary long before a keyframe does. One clip per audio
# path: AAC is passed through, stereo PCM goes through the FLAC bridge (the reporter's Vorbis did).
for AUDIO in aac pcm; do
    CODEC=aac; [ "$AUDIO" = pcm ] && CODEC=pcm_s16le
    echo "→ long-first-gop-$AUDIO.mkv (keyframes at 0, 11, 13, 15 ... s, 30 s)"
    ffmpeg -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=320x180:rate=24" \
        -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 30 \
        -c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 200k -bf 0 \
        -g 1000 -sc_threshold 0 -force_key_frames "0,11,13,15,17,19,21,23,25,27,29" \
        -c:a "$CODEC" -ac 2 -f matroska "$FIXTURES_DIR/long-first-gop-$AUDIO.mkv"
done

# AVSyncTests: one white frame and one click at exactly the same instant (frame 24 at 24 fps, sample
# 48000 at 48 kHz), in every audio codec the HLS route copies or bridges and in each container that
# carries it. H.264 with B-frames, so the video side has a composition offset to keep straight. FFmpeg's
# own decode puts the click on the frame in every clip (checked with -copyts); DTS is left out because
# FFmpeg's experimental encoder adds 512 samples of delay it does not declare, so the clip itself is off.
echo "→ avsync/* (frame and click at 1.000 s, per audio codec and container)"
mkdir -p "$FIXTURES_DIR/avsync"
AVSYNC_V="color=black:s=320x240:r=24:d=4,drawbox=x=0:y=0:w=320:h=240:color=white:t=fill:enable='eq(n,24)'"
AVSYNC_CLICK="if(between(n,48000,48143),0.8*sin(2*PI*1000*(n-48000)/48000),0)"
AVSYNC_STEREO="aevalsrc='$AVSYNC_CLICK|$AVSYNC_CLICK':s=48000:d=4"
AVSYNC_51="aevalsrc='$AVSYNC_CLICK|0|0|0|0|0':s=48000:d=4:c=5.1"
avsync_clip() {  # <name> <audio source> <audio args...>
    local name="$1" source="$2"; shift 2
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$AVSYNC_V" -f lavfi -i "$source" "$@" \
        -c:v libx264 -bf 3 -g 48 -pix_fmt yuv420p "$FIXTURES_DIR/avsync/$name"
}
avsync_clip aac.mkv "$AVSYNC_STEREO" -c:a aac -b:a 192k
avsync_clip aac.mp4 "$AVSYNC_STEREO" -c:a aac -b:a 192k
avsync_clip aac.ts "$AVSYNC_STEREO" -c:a aac -b:a 192k
avsync_clip ac3.mkv "$AVSYNC_51" -c:a ac3
avsync_clip ac3.ts "$AVSYNC_51" -c:a ac3
avsync_clip eac3.mkv "$AVSYNC_51" -c:a eac3
avsync_clip eac3.mp4 "$AVSYNC_51" -c:a eac3
avsync_clip flac.mkv "$AVSYNC_STEREO" -c:a flac
avsync_clip pcm.mkv "$AVSYNC_STEREO" -c:a pcm_s24le
avsync_clip truehd.mkv "$AVSYNC_51" -c:a truehd -strict -2
avsync_clip opus.mkv "$AVSYNC_STEREO" -c:a libopus
avsync_clip mp3.mkv "$AVSYNC_STEREO" -c:a libmp3lame
# The same frame and click with MPEG-2 video, which AVPlayer cannot decode: the session decodes it and the software
# overlay shows it, so the picture's time comes through the overlay and the click's through the HLS route.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$AVSYNC_V" -f lavfi -i "$AVSYNC_STEREO" \
    -c:v mpeg2video -q:v 4 -bf 2 -g 48 -pix_fmt yuv420p -c:a aac -b:a 192k "$FIXTURES_DIR/avsync/mpeg2-overlay.mkv"
# The overlay's pictures read back off the screen (OverlayScreenTimingTests): MPEG-2 carrying each frame's number as
# a 12-bit barcode across the top half (least significant bit on the left) and the white frame of the clips above in
# the bottom half, with the same click at 1.000 s.
AVSYNC_BARCODE="color=black:s=640x360:r=24:d=15,format=yuv420p,geq=lum='if(lt(Y,H/2),16+219*mod(floor(N/pow(2,floor(X*12/W))),2),if(eq(N,24),235,16))':cb=128:cr=128"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$AVSYNC_BARCODE" \
    -f lavfi -i "aevalsrc='$AVSYNC_CLICK|$AVSYNC_CLICK':s=48000:d=15" \
    -c:v mpeg2video -q:v 2 -bf 2 -g 48 -pix_fmt yuv420p -c:a aac -b:a 192k "$FIXTURES_DIR/avsync/mpeg2-barcode.mkv"
# FFmpeg's DTS encoder delays its output by one frame (512 samples) and declares no padding, so FFmpeg's
# own decode puts a click at 48 000 one frame late: the DTS clip's click goes in a frame early.
AVSYNC_DTS_CLICK="if(between(n,47488,47631),0.8*sin(2*PI*1000*(n-47488)/48000),0)"
avsync_clip dts.mkv "aevalsrc='$AVSYNC_DTS_CLICK|0|0|0|0|0':s=48000:d=4:c=5.1" -c:a dca -strict -2

# AudioDecoderMemoryTests: per channel, a tone with vibrato and a slow swell, a gated harmonic, a
# repeating chirp, gated noise bursts and a noise floor, so every band carries something that changes.
# Pure steady tones are avoided: Opus can settle into alternating between two rounded values on one.
echo "→ decmem/* (12 s of music-like audio per bridged codec)"
mkdir -p "$FIXTURES_DIR/decmem"
decmem_channel() {  # <base Hz> <noise seed> <phase>
    echo "0.18*sin(2*PI*$1*t+2*sin(2*PI*5.1*t))*(0.6+0.4*sin(2*PI*0.37*t+$3))+0.12*sin(2*PI*($1*2.71)*t)*lt(mod(t+$3,2.3),1.4)+0.1*sin(2*PI*(150*mod(t+$3,3.1)+900*mod(t+$3,3.1)*mod(t+$3,3.1)))+0.15*(random($2)*2-1)*lt(mod(t*1.13+$3,1.7),0.21)+0.05*(random($2+1)*2-1)"
}
DECMEM_ST="aevalsrc=exprs='$(decmem_channel 220 0 0)|$(decmem_channel 330 2 0.7)':d=12"
DECMEM_51="aevalsrc=exprs='$(decmem_channel 220 0 0)|$(decmem_channel 330 2 0.7)|$(decmem_channel 440 4 1.1)|$(decmem_channel 55 6 0.3)|$(decmem_channel 277 8 1.9)|$(decmem_channel 369 10 2.5)':d=12:c=5.1"
decmem_clip() {  # <name> <audio source> <rate> <audio args...>
    local name="$1" source="$2" rate="$3"; shift 3
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "$source:s=$rate" "$@" "$FIXTURES_DIR/decmem/$name"
}
decmem_clip mp2.mkv "$DECMEM_ST" 48000 -c:a mp2 -b:a 192k
decmem_clip mp3-64k.mp3 "$DECMEM_ST" 44100 -c:a libmp3lame -b:a 64k
decmem_clip mp3-vbr.mkv "$DECMEM_ST" 48000 -c:a libmp3lame -q:a 6
decmem_clip mp3-lsf.mp3 "$DECMEM_ST" 24000 -c:a libmp3lame -b:a 32k
decmem_clip vorbis.ogg "$DECMEM_ST" 48000 -c:a vorbis -strict -2
decmem_clip opus.mkv "$DECMEM_ST" 48000 -c:a libopus -b:a 128k
decmem_clip dts-51.mkv "$DECMEM_51" 48000 -c:a dca -strict -2
decmem_clip truehd-51.mkv "$DECMEM_51" 48000 -c:a truehd -strict -2
decmem_clip truehd-96k.mkv "$DECMEM_ST" 96000 -c:a truehd -strict -2
decmem_clip flac.mkv "$DECMEM_ST" 48000 -c:a flac

# ProducerDeterminismTests: the decmem audio over a moving picture, 24 s in 2 s GOPs (12 segments of
# the VOD keyframe plan), one clip per audio route: copied from Matroska, MPEG-TS (the uniform grid)
# and MP4, and bridged from Opus, DTS and TrueHD.
echo "→ determinism/* (24 s, per audio route)"
mkdir -p "$FIXTURES_DIR/determinism"
DET_ST="${DECMEM_ST/d=12/d=24}:s=48000"
DET_51="${DECMEM_51/d=12/d=24}:s=48000"
determinism_clip() {  # <name> <audio source> <audio args...>
    local name="$1" source="$2"; shift 2
    ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=320x240:r=24:d=24" -f lavfi -i "$source" "$@" \
        -c:v libx264 -bf 3 -g 48 -keyint_min 48 -sc_threshold 0 -pix_fmt yuv420p "$FIXTURES_DIR/determinism/$name"
}
determinism_clip aac.mkv "$DET_ST" -c:a aac -b:a 192k
determinism_clip ac3.ts "$DET_51" -c:a ac3
determinism_clip eac3.mp4 "$DET_51" -c:a eac3
determinism_clip flac.mkv "$DET_ST" -c:a flac
determinism_clip opus.mkv "$DET_ST" -c:a libopus -b:a 128k
determinism_clip dts.mkv "$DET_51" -c:a dca -strict -2
determinism_clip truehd.mkv "$DET_51" -c:a truehd -strict -2

# Audio whose timestamps are off their frames the ways the library's remuxes carry them, the audio itself continuous.
# Remuxed from the clips above, so the bitstream is the same and only the timestamps differ.
# - DTS (research/dts-timing): timestamps falling behind their frames and snapping back, about 2 ms off at worst.
# - TrueHD (a survey of seven titles): stamps a millisecond off either way on scattered packets, and on one title
#   the first packet stamped 5 ms ahead of the rest.
echo "→ avsync/{dts-drift,truehd-jitter,truehd-firststamp}.mkv, determinism/{dts-drift,truehd-jitter}.mkv"
audio_drift() {  # <from> <to> <packets per snap> <samples behind at the snap>
    local expr="round(mod(N\\,$3)*$4/$3/48000/TB)"
    ffmpeg -hide_banner -loglevel error -y -i "$1" -map 0 -c copy -bsf:a "setts=pts=PTS-$expr:dts=DTS-$expr" "$2"
}
TRUEHD_JITTER="if(eq(mod(N\\,7)\\,3)\\,1\\,if(eq(mod(N\\,11)\\,5)\\,-1\\,0))*0.001/TB"
for d in avsync determinism; do
    # DTS: a 512-sample frame a packet, 32 samples behind per 25 of them (as measured), back every 60.
    audio_drift "$FIXTURES_DIR/$d/dts.mkv" "$FIXTURES_DIR/$d/dts-drift.mkv" 60 77
    # TrueHD: a 40-sample access unit a packet; one packet in seven a millisecond late, one in eleven early.
    ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES_DIR/$d/truehd.mkv" -map 0 -c copy \
        -bsf:a "setts=pts=PTS+$TRUEHD_JITTER:dts=DTS+$TRUEHD_JITTER" "$FIXTURES_DIR/$d/truehd-jitter.mkv"
done
# TrueHD whose first packet is stamped apart from the rest: every packet but the first 5 ms later.
ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES_DIR/avsync/truehd.mkv" -map 0 -c copy \
    -bsf:a "setts=pts=if(eq(N\\,0)\\,PTS\\,PTS+0.005/TB):dts=if(eq(N\\,0)\\,DTS\\,DTS+0.005/TB)" \
    "$FIXTURES_DIR/avsync/truehd-firststamp.mkv"

echo ""
echo "Done. Try:"
echo "  swift run aetherctl probe $FIXTURES_DIR/sdr-h264.mp4"
echo "  swift run aetherctl probe $FIXTURES_DIR/hdr10-hevc.mp4"
echo "  swift run aetherctl validate $FIXTURES_DIR/av1.mp4"
echo ""
echo "Real-world DV / Atmos sources go in $FIXTURES_DIR/user/ (gitignored)."
