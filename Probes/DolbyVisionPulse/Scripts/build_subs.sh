#!/bin/zsh
# Builds the subtitle-rendition stream for SEQ=subs (the `subs` arms of the pulse host) into $PULSE_OUT/subs
# (default ../out/subs): a 60 s VOD HLS with English audio as its own rendition and three English WebVTT
# subtitle renditions, declared as Apple's HLS Authoring Specification asks:
#
#   English          regular,  AUTOSELECT=NO                       cues "REGULAR #n" every 3 s, at the bottom
#   English SDH      SDH,      AUTOSELECT=YES, accessibility CHARACTERISTICS (4.5, 4.6)   "[SDH] #n" every 3 s
#   English Forced   FORCED=YES, AUTOSELECT=YES (5.11)              "FORCED #n" every 12 s, at the top
#
# Every cue names its rendition and its time, so a camera (or an eye) can tell which rendition AVKit draws.
# The picture is ffmpeg's testsrc, whose running counter is the presentation time in seconds.
set -euo pipefail
HERE=${0:A:h}
OUT=${PULSE_OUT:-$HERE/../out}
OUT=${OUT:A}/subs
command -v ffmpeg >/dev/null || { echo "missing tool: ffmpeg (brew install ffmpeg)"; exit 1; }
mkdir -p "$OUT"
cd "$OUT"

SECS=60
SEG=6
# No B-frames and no mux delay: both playlists start at PTS 0, so X-TIMESTAMP-MAP=MPEGTS:0 maps cue time 0 to it.
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "testsrc=size=1920x1080:rate=30:duration=$SECS" \
  -c:v libx264 -preset veryfast -profile:v high -bf 0 -g 30 -keyint_min 30 -sc_threshold 0 -pix_fmt yuv420p -an \
  -muxdelay 0 -muxpreload 0 -f hls -hls_time $SEG -hls_playlist_type vod -hls_segment_filename 'v%02d.ts' video.m3u8
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=frequency=440:duration=$SECS:sample_rate=48000" \
  -af volume=0.05 -c:a aac -b:a 96k -metadata:s:a:0 language=eng \
  -muxdelay 0 -muxpreload 0 -f hls -hls_time $SEG -hls_playlist_type vod -hls_segment_filename 'a%02d.ts' audio.m3u8

python3 - "$SECS" "$SEG" <<'PY'
import sys
secs, seg = int(sys.argv[1]), int(sys.argv[2])

def ts(t):
    return "%02d:%02d:%06.3f" % (t // 3600, (t % 3600) // 60, t % 60)

renditions = {
    # name: [(start, end, text, settings)]
    "reg": [(3 * k + 0.2, 3 * k + 2.8, "REGULAR #%d  (%ds)" % (k, 3 * k), "") for k in range(secs // 3)],
    "sdh": [(3 * k + 0.2, 3 * k + 2.8, "[SDH] #%d  ♪  (%ds)" % (k, 3 * k), "") for k in range(secs // 3)],
    "forced": [(12 * k + 1.5, 12 * k + 5.5, "FORCED #%d  (%ds)" % (k, 12 * k), " line:10%") for k in range(secs // 12)],
}
for name, cues in renditions.items():
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:%d" % seg, "#EXT-X-MEDIA-SEQUENCE:0",
             "#EXT-X-PLAYLIST-TYPE:VOD"]
    for i in range(secs // seg):
        a, b = i * seg, (i + 1) * seg
        body = ["WEBVTT", "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000", ""]
        for start, end, text, settings in cues:
            if start < b and end > a:   # every cue lies inside one segment by construction
                body += ["%s --> %s%s" % (ts(start), ts(end), settings), text, ""]
        open("%s_%02d.vtt" % (name, i), "w").write("\n".join(body))
        lines += ["#EXTINF:%d.000," % seg, "%s_%02d.vtt" % (name, i)]
    lines.append("#EXT-X-ENDLIST")
    open("sub_%s.m3u8" % name, "w").write("\n".join(lines) + "\n")

sdh = "public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound"
master = [
    "#EXTM3U", "#EXT-X-VERSION:6", "#EXT-X-INDEPENDENT-SEGMENTS",
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",LANGUAGE="en",NAME="English",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8"',
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English",DEFAULT=NO,AUTOSELECT=NO,FORCED=NO,URI="sub_reg.m3u8"',
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English SDH",DEFAULT=NO,AUTOSELECT=YES,FORCED=NO,'
    'CHARACTERISTICS="%s",URI="sub_sdh.m3u8"' % sdh,
    '#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",LANGUAGE="en",NAME="English Forced",DEFAULT=NO,AUTOSELECT=YES,FORCED=YES,URI="sub_forced.m3u8"',
    '#EXT-X-STREAM-INF:BANDWIDTH=4000000,AVERAGE-BANDWIDTH=3000000,CODECS="avc1.640028,mp4a.40.2,wvtt",'
    'RESOLUTION=1920x1080,FRAME-RATE=30.000,AUDIO="aud",SUBTITLES="subs"',
    "video.m3u8",
]
open("master.m3u8", "w").write("\n".join(master) + "\n")
PY
echo "built $OUT/master.m3u8"
