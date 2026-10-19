#!/bin/zsh
# Builds the pulse host, installs it on an Apple TV, serves the clips from this Mac and plays an arm
# sequence, with the console attached. Only run it when a television session is wanted.
#
#   DEVICE="Apple TV" ./run_tv.sh               build + install, then play SEQ=main (about 11 min)
#   DEVICE=... ./run_tv.sh --no-build           play only (app already installed)
#   DEVICE=... SEQ=el ./run_tv.sh               TE engine (FEL) / NE enginenofel (EL dropped) on p7fel_el.mp4, then T
#   DEVICE=... SEQ=vt ./run_tv.sh               the three VideoToolbox arms only, on pulse_l2.mp4
#   DEVICE=... SEQ=cm4 ./run_tv.sh              CM v4.0: P8 AVPlayer / T8 engine (FEL) on the L8-only pulse, P/T the L2 controls
#   DEVICE=... SEQ=fmt ./run_tv.sh              the L2 pulse on the FEL route per output buffer: T p010, TF p010-full, TS sv22
#   DEVICE=... SEQ=bits ./run_tv.sh             12-bit survival on p7fel_sub10: TD p010 dithered (+ control), TR p010-round
#                                               (- control), TF p010-full, TS sv22; TF/TS pulse = bits below 10 reach the panel
#   DEVICE=... SEQ=count ./run_tv.sh            counter clips: T / NE / TL (FEL route, residual, RPU pulse) and PM (8.1 control)
#   DEVICE=... SEQ=soak SOAK_URL=<http url | file under $PULSE_OUT> [SOAK_MIN=5] [SOAK_SEEKS=60@1800,150@600,240@3000] ./run_tv.sh
#                                               one FEL soak arm; its summary line is grepped at the end
#
# Required: DEVICE, a `xcrun devicectl list devices` name or identifier.
# Optional: TEAM (development team id, for signing), PULSE_BUNDLE_PREFIX (default
#           de.superuser404.dolbyvisionpulse), PULSE_OUT (clip directory, default ../out),
#           PORT (default 8765), DD (derived data path, default ../.dd, gitignored),
#           IFACE (network interface whose address the Apple TV fetches the clips from; default: the
#           first of en0, en1 that has an address).
# Xcode is the one `xcode-select -p` points at; set DEVELOPER_DIR to use another.
set -euo pipefail
HERE=${0:A:h}
ROOT=${HERE:h}
: "${DEVICE:?set DEVICE to a devicectl name or id (xcrun devicectl list devices)}"
xcrun --find xcodebuild >/dev/null 2>&1 || { echo "no Xcode found: install it or run xcode-select -s <Xcode.app>/Contents/Developer"; exit 1; }
PREFIX=${PULSE_BUNDLE_PREFIX:-de.superuser404.dolbyvisionpulse}
BUNDLE=$PREFIX.host
OUT=${PULSE_OUT:-$ROOT/out}
PORT=${PORT:-8765}
DD=${DD:-$ROOT/.dd}
SEQ=${SEQ:-main}

if [[ -n "${IFACE:-}" ]]; then
  IP=$(ipconfig getifaddr "$IFACE" 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on IFACE=$IFACE"; exit 1; }
else
  IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
  [[ -n "$IP" ]] || { echo "no IP address on en0 or en1: set IFACE=<interface> or connect this Mac to the Apple TV's network (the device fetches the clips from it)"; exit 1; }
fi
B="http://$IP:$PORT"
case "$SEQ" in
  main)
    ARMS="P|avplayer|$B/pulse_l2.mp4,V1|vt|$B/pulse_l2.mp4,V2|vtcopy|$B/pulse_l2.mp4,T|engine|$B/p7fel_l2.mp4,N|engine|$B/p7fel_null.mp4,S|vtstrip|$B/pulse_l2.mp4,P1|avplayer|$B/pulse_l1.mp4,T1|engine|$B/p7fel_l1.mp4,P|avplayer|$B/pulse_l2.mp4"
    LABELS=P,V1,V2,T,N,S,P1,T1,P ;;
  el)
    ARMS="TE|engine|$B/p7fel_el.mp4,NE|enginenofel|$B/p7fel_el.mp4,T|engine|$B/p7fel_l2.mp4"
    LABELS=TE,NE,T ;;
  vt)
    ARMS="P|avplayer|$B/pulse_l2.mp4,V1|vt|$B/pulse_l2.mp4,V2|vtcopy|$B/pulse_l2.mp4,S|vtstrip|$B/pulse_l2.mp4"
    LABELS=P,V1,V2,S ;;
  count)
    ARMS="T|engine|$B/p7fel_count_null.mp4,NE|enginenofel|$B/p7fel_count_null.mp4,TL|engine|$B/p7fel_count_l2.mp4,PM|avplayer|$B/count_mel.mp4"
    LABELS=T,NE,TL,PM ;;
  soak)
    : "${SOAK_URL:?SEQ=soak needs SOAK_URL=<http url or a file under PULSE_OUT>}"
    case "$SOAK_URL" in
      http://*|https://*) U="$SOAK_URL" ;;
      *) [[ -e "$OUT/$SOAK_URL" ]] || { echo "no such file under $OUT: $SOAK_URL"; exit 1; }
         U="$B/${SOAK_URL#./}" ;;
    esac
    ARMS="SOAK|soak|$U|minutes=${SOAK_MIN:-5};seeks=${SOAK_SEEKS:-60@1800,150@600,240@3000}"
    LABELS=SOAK ;;
  cm4)
    # Does CM v4.0 (L8) reach the panel? P/T pulse on L2 (v2.9) as the positive controls; P8/T8 only
    # pulse if the L8 blocks survive to the TV's display manager.
    ARMS="P|avplayer|$B/pulse_l2.mp4,P8|avplayer|$B/pulse_l8.mp4,T|engine|$B/p7fel_l2.mp4,T8|engine|$B/p7fel_l8.mp4"
    LABELS=P,P8,T,T8 ;;
  fmt)
    # Does the per-frame RPU still drive the panel when the composer hands tvOS P010 with the low bits
    # used, or a 16-bit 4:2:2 sv22 buffer? A flat TS (or an HDR10 badge) means sv22 loses Dolby Vision.
    ARMS="T|engine|$B/p7fel_l2.mp4|out=p010,TF|engine|$B/p7fel_l2.mp4|out=p010-full,TS|engine|$B/p7fel_l2.mp4|out=sv22"
    LABELS=T,TF,TS ;;
  bits)
    ARMS="TD|engine|$B/p7fel_sub10.mp4|out=p010,TR|engine|$B/p7fel_sub10.mp4|out=p010-round,TF|engine|$B/p7fel_sub10.mp4|out=p010-full,TS|engine|$B/p7fel_sub10.mp4|out=sv22,TD|engine|$B/p7fel_sub10.mp4|out=p010"
    LABELS=TD,TR,TF,TS,TD ;;
  *) echo "unknown SEQ=$SEQ (main|el|vt|count|cm4|fmt|bits|soak)"; exit 1 ;;
esac

if [[ "${1:-}" != "--no-build" ]]; then
  SIGN=()
  [[ -n "${TEAM:-}" ]] && SIGN=(DEVELOPMENT_TEAM="$TEAM")
  xcodebuild -project "$ROOT/Device/DolbyVisionPulse.xcodeproj" -scheme DolbyVisionPulse \
    -destination 'generic/platform=tvOS' -configuration Debug -derivedDataPath "$DD" \
    -allowProvisioningUpdates PULSE_BUNDLE_PREFIX="$PREFIX" "${SIGN[@]}" build | tail -1
  xcrun devicectl device install app --device "$DEVICE" "$DD/Build/Products/Debug-appletvos/DolbyVisionPulseHost.app"
fi

python3 "$HERE/serve.py" $PORT "$IP" "$OUT" >/dev/null 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
sleep 1

LOG=tv_${SEQ}_$(date +%Y%m%d_%H%M%S).log
echo "labels for analyze.py: --arms $LABELS"
[[ "$SEQ" == soak ]] || echo "start the phone recording now; launching in 10 s"
sleep 10
# `process launch` hands --environment-variables to the app process (unlike a test bundle).
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing --console \
  --environment-variables "{\"PULSE_ARMS\":\"$ARMS\"}" $BUNDLE | tee "$LOG" || echo "(launch ended non-zero: app crashed or was killed; pulling the log anyway)"
xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
  --domain-identifier $BUNDLE --source Library/Caches/pulse-log.txt --destination "${LOG%.log}.app.log" \
  >/dev/null 2>&1 || echo "(could not pull the app log)"
echo "log: $LOG (+ ${LOG%.log}.app.log)"
if [[ "$SEQ" == soak ]]; then
  grep -h "soak summary" "$LOG" "${LOG%.log}.app.log" 2>/dev/null | sort -u || echo "(no soak summary line found)"
else
  echo "cut and analyse: python3 $HERE/cut.py <recording>.MOV $LOG --slates"
  echo "                 then the same command with --sync <video seconds>=<clock read off the slate>"
fi
