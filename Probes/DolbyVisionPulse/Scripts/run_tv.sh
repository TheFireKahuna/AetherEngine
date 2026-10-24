#!/bin/zsh
# Builds the pulse host, installs it on an Apple TV, serves the clips from this Mac and plays an arm
# sequence, with the console attached. Only run it when a television session is wanted.
#
#   DEVICE="Apple TV" ./run_tv.sh               build + install, then play SEQ=main (about 11 min)
#   DEVICE=... ./run_tv.sh --no-build           play only (app already installed)
#   DEVICE=... SEQ=el ./run_tv.sh               TE engine (FEL) / NE enginenofel (EL dropped) on p7fel_el.mp4, then T
#   DEVICE=... SEQ=vt ./run_tv.sh               the three VideoToolbox arms only, on pulse_l2.mp4
#   DEVICE=... SEQ=cm4 ./run_tv.sh              CM v4.0 vs v2.9 on AVPlayer (P*) and the engine FEL route (T*): L2, L2 + v4.0
#                                               defaults, L8 tone and L8 six-vector pulses; record, then analyze.py --color
#   DEVICE=... SEQ=cm4q ./run_tv.sh             the same by eye: 8 arms of 20 s (P P4 P8 PH, T T4 T8 TH), about 3.5 min
#   DEVICE=... SEQ=l8ladder ./run_tv.sh         by eye: the L8 ladder, 20 s per rung and route (LADDER=a,b,c,d default, or e,f,g,h; ROUTES=P,T)
#   DEVICE=... SEQ=fmt ./run_tv.sh              the L2 pulse on the FEL route per output buffer: T p010, TF p010-full, TS sv22
#   DEVICE=... SEQ=bits ./run_tv.sh             12-bit survival on p7fel_sub10: TD p010 dithered (+ control), TR p010-round
#                                               (- control), TF p010-full, TS sv22; TF/TS pulse = bits below 10 reach the panel
#   DEVICE=... SEQ=card ./run_tv.sh             amplifier RPU on p7fel_card (14 s per arm): TR p010-round, TD p010, TB p010-bluenoise,
#                                               TF p010-full, TS sv22 (card_amp10.bin); TI identity
#                                               control; BR/BF/BS the p7fel_bullseye banding fallback, no override
#   DEVICE=... SEQ=cardov ./run_tv.sh           the amplifier card on both FEL routes (14 s per arm): TR/TS software host
#                                               p010-round / sv22, then OR/OS the native route's FEL overlay (felOverlay),
#                                               OI the overlay's identity control
#   DEVICE=... SEQ=placeholder ./run_tv.sh      the software route inside AVPlayer (Scripts/build_placeholder.sh): AVKit plays a
#                                               flat placeholder, the picture is our own decode on a layer in AVKit's player layer.
#                                               GD overlay pulses / placeholder constant, GX the reverse, GH HDR10 placeholder,
#                                               GS seeks on the counter clip; by eye, about 2.5 min
#   DEVICE=... SEQ=deint ./run_tv.sh            the deinterlace card on the software route (Scripts/build_deint.sh): DF field rate
#                                               with a seek, DR frame rate, DW the wrong-field-order control; by eye, about 45 s
#   DEVICE=... SEQ=film ./run_tv.sh             film in interlaced carriage (Scripts/build_film.sh), each clip ON then OFF
#                                               (film=off): FS soft telecine, FH hard telecine, FP 2:2; by eye, about 90 s
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
    # Does CM v4.0 reach the panel's display manager intact, on AVPlayer (P*) and the engine's FEL route (T*)?
    #   P/T    CM v2.9 L2 pulse            positive control: the panel follows trims at all (must pulse)
    #   PN     CM v2.9, nothing switches   negative control (must stay steady)
    #   P4/T4  CM v4.0 defaults, L2 pulse  steady = v4.0 arrived and the panel ignores L2; pulse = v4.0 stripped
    #   P8/T8  CM v4.0, L8 tone pulse      pulse = L8 reaches a display manager
    #   PH/TH  CM v4.0, L8 six-vector only red/cyan move, greys steady = the panel's own CM v4.0 reads our L8
    # The closing P repeats the first arm, so drift or a mode change during the run shows.
    ARMS="P|avplayer|$B/pulse_l2.mp4,PN|avplayer|$B/pulse_null.mp4,P4|avplayer|$B/pulse_l2v4.mp4"
    ARMS+=",P8|avplayer|$B/pulse_l8.mp4,PH|avplayer|$B/pulse_hue.mp4,T|engine|$B/p7fel_l2.mp4"
    ARMS+=",T4|engine|$B/p7fel_l2v4.mp4,T8|engine|$B/p7fel_l8.mp4,TH|engine|$B/p7fel_hue.mp4,P|avplayer|$B/pulse_l2.mp4"
    LABELS=P,PN,P4,P8,PH,T,T4,T8,TH,P
    for f in pulse_l2 pulse_null pulse_l2v4 pulse_l8 pulse_hue p7fel_l2 p7fel_l2v4 p7fel_l8 p7fel_hue; do
      [[ -e "$OUT/$f.mp4" ]] || { echo "missing $OUT/$f.mp4 (Scripts/build.sh makes it)"; exit 1; }
    done ;;
  cm4q)
    # cm4 by eye: the same arms minus the negative control and the closing repeat, 20 s each (the 6 s
    # pre-roll, then 4-5 switches), about 3.5 min. Not enough B phases for analyze.py; use cm4 for that.
    Q="secs=20"
    ARMS="P|avplayer|$B/pulse_l2.mp4|$Q,P4|avplayer|$B/pulse_l2v4.mp4|$Q,P8|avplayer|$B/pulse_l8.mp4|$Q"
    ARMS+=",PH|avplayer|$B/pulse_hue.mp4|$Q,T|engine|$B/p7fel_l2.mp4|$Q,T4|engine|$B/p7fel_l2v4.mp4|$Q"
    ARMS+=",T8|engine|$B/p7fel_l8.mp4|$Q,TH|engine|$B/p7fel_hue.mp4|$Q"
    LABELS=P,P4,P8,PH,T,T4,T8,TH
    for f in pulse_l2 pulse_l2v4 pulse_l8 pulse_hue p7fel_l2 p7fel_l2v4 p7fel_l8 p7fel_hue; do
      [[ -e "$OUT/$f.mp4" ]] || { echo "missing $OUT/$f.mp4 (Scripts/build.sh makes it)"; exit 1; }
    done ;;
  l8ladder)
    # By eye, 20 s per arm: the L8 tone pulse with fewer / shorter blocks (gen_pulse.py L8_LADDER), on AVPlayer
    # (PA-PD) then the engine FEL route (TA-TD). A one short block at 100 nits (streaming style), B one short
    # block at 1000 nits, C five short blocks, D one long (25-byte) block at 1000 nits.
    # LADDER=e,f,g,h (default a,b,c,d) picks the rungs: e/f a realistic / saturation-only trim at 1000 nits,
    # g the extreme trim at 600 nits, h a's block at 25 bytes. ROUTES=P (or T) plays one route only.
    Q="secs=20"; ARMS=""; LABELS=""
    for r in P:avplayer:pulse T:engine:p7fel; do
      [[ ",${ROUTES:-P,T}," == *",${r%%:*},"* ]] || continue
      for x in ${(s:,:)${LADDER:-a,b,c,d}}; do
        X=${(U)x}
        ARMS+="${ARMS:+,}${r%%:*}$X|${${r#*:}%%:*}|$B/${r##*:}_l8$x.mp4|$Q"
        LABELS+="${LABELS:+,}${r%%:*}$X"
        [[ -e "$OUT/${r##*:}_l8$x.mp4" ]] || { echo "missing $OUT/${r##*:}_l8$x.mp4 (Scripts/build.sh makes it)"; exit 1; }
      done
    done ;;
  fmt)
    # Does the per-frame RPU still drive the panel when the composer hands tvOS P010 with the low bits
    # used, or a 16-bit 4:2:2 sv22 buffer? A flat TS (or an HDR10 badge) means sv22 loses Dolby Vision.
    ARMS="T|engine|$B/p7fel_l2.mp4|out=p010,TF|engine|$B/p7fel_l2.mp4|out=p010-full,TS|engine|$B/p7fel_l2.mp4|out=sv22"
    LABELS=T,TF,TS ;;
  bits)
    ARMS="TD|engine|$B/p7fel_sub10.mp4|out=p010,TR|engine|$B/p7fel_sub10.mp4|out=p010-round,TF|engine|$B/p7fel_sub10.mp4|out=p010-full,TS|engine|$B/p7fel_sub10.mp4|out=sv22,TD|engine|$B/p7fel_sub10.mp4|out=p010"
    LABELS=TD,TR,TF,TS,TD ;;
  card)
    # Amplifier RPU: a luma curve steep in a narrow window, attached to every composed frame in place of the
    # identity one, so sub-10-bit steps in the composed picture become visible if they survive tvOS's output.
    # 14 s: inside the 15 s clips, so no arm relies on the end-of-clip loop. There is no 12-bit-declared
    # amplifier: libdovi refuses any bl_bit_depth but 10 (Tools/card_rpu).
    C="$B/p7fel_card.mp4"; A10="rpu=$B/card_amp10.bin;secs=14"
    ARMS="TR|engine|$C|out=p010-round;$A10,TD|engine|$C|out=p010;$A10,TB|engine|$C|out=p010-bluenoise;$A10"
    ARMS+=",TF|engine|$C|out=p010-full;$A10,TS|engine|$C|out=sv22;$A10"
    ARMS+=",TI|engine|$C|out=p010-full;rpu=$B/card_identity.bin;secs=14"
    ARMS+=",BR|engine|$B/p7fel_bullseye.mp4|out=p010-round;secs=14,BF|engine|$B/p7fel_bullseye.mp4|out=p010-full;secs=14"
    ARMS+=",BS|engine|$B/p7fel_bullseye.mp4|out=sv22;secs=14"
    LABELS=TR,TD,TB,TF,TS,TI,BR,BF,BS
    for f in p7fel_card.mp4 card_amp10.bin card_identity.bin p7fel_bullseye.mp4; do
      [[ -e "$OUT/$f" ]] || { echo "missing $OUT/$f (Scripts/build.sh makes it)"; exit 1; }
    done ;;
  cardov)
    # The card on the software host (T*) and on the native route's FEL overlay (O*), same clip and amplifier: does
    # the overlay keep the sub-10-bit steps the software route was shown to keep (2026-10-19)?
    C="$B/p7fel_card.mp4"; A10="rpu=$B/card_amp10.bin;secs=14"
    ARMS="TR|engine|$C|out=p010-round;$A10,TS|engine|$C|out=sv22;$A10"
    ARMS+=",OR|overlay|$C|out=p010-round;$A10,OS|overlay|$C|out=sv22;$A10"
    ARMS+=",OI|overlay|$C|out=p010-full;rpu=$B/card_identity.bin;secs=14"
    LABELS=TR,TS,OR,OS,OI
    for f in p7fel_card.mp4 card_amp10.bin card_identity.bin; do
      [[ -e "$OUT/$f" ]] || { echo "missing $OUT/$f (Scripts/build.sh makes it)"; exit 1; }
    done ;;
  placeholder)
    # GD: Dolby Vision placeholder with a constant RPU, the overlay decodes pulse_l2: a pulse means the overlay's
    #     RPU drives the panel. Press the remote here: the transport bar, pause, scrub.
    # GX: the reverse, the placeholder pulses and the overlay is constant: a pulse means AVPlayer's own RPU leaks.
    # GH: HDR10 placeholder, the overlay's frames without Dolby Vision attachments: HDR10 mode, steady.
    # GV: HDR10 placeholder with Dolby Vision criteria from the source, as the FEL overlay route serves AVPlayer
    #     (hvc1, DV only supplemental): a pulse means the overlay's RPU drives the panel. Press the remote here.
    # GS: seeks on the counter clip (BL nnnn) in GV's arrangement: the number after each seek should be the target.
    # GE: the intended design: the Dolby Vision placeholder carries the source's own per-frame RPU (ph_dv_l2 has
    #     pulse_l2's), AVKit sets the mode from it, the overlay shows the source's frames: DV, pulse, Atmos.
    # PH_ARMS (e.g. GE) plays a subset.
    ARMS="GD|placeholder|$B/ph_dv_null.mp4|src=pulse_l2.mp4;secs=40"
    ARMS+=",GX|placeholder|$B/ph_dv_l2.mp4|src=pulse_null.mp4;secs=25"
    ARMS+=",GH|placeholder|$B/ph_hdr10.mp4|src=pulse_l2.mp4;strip=1;secs=25"
    ARMS+=",GV|placeholder|$B/ph_hdr10.mp4|src=pulse_l2.mp4;criteria=src;secs=40"
    ARMS+=",GS|placeholder|$B/ph_hdr10.mp4|src=count_mel.mp4;criteria=src;secs=40;seeks=10@40,20@5,30@60"
    ARMS+=",GE|placeholder|$B/ph_dv_l2.mp4|src=pulse_l2.mp4;secs=45"
    LABELS=GD,GX,GH,GV,GS,GE
    if [[ -n "${PH_ARMS:-}" ]]; then
      # Pieces without a `|` continue the arm before them (a seeks= list).
      ARMS=$(print -r -- "$ARMS" | tr ',' '\n' | awk -v keep=",$PH_ARMS," -F'|' \
        'NF > 1 { k = index(keep, "," $1 ",") > 0 } k' | paste -sd, -)
      LABELS=$PH_ARMS
    fi
    for f in ph_dv_null.mp4 ph_dv_l2.mp4 ph_hdr10.mp4 pulse_l2.mp4 pulse_null.mp4 count_mel.mp4; do
      [[ -e "$OUT/$f" ]] || { echo "missing $OUT/$f (Scripts/build.sh, then Scripts/build_placeholder.sh)"; exit 1; }
    done ;;
  deint)
    # The deinterlace card (Scripts/build_deint.sh) on the software route, by eye; the legend below says what
    # each region shows. DF: correct field order at field rate, with a seek at 8 s back to 2 s (the window
    # starts over). DR: the same at frame rate. DW: the control, flagged bottom field first, deinterlaced wrong.
    # DP first: the card as progressive 50p, the same software route without the deinterlacer, so the screen
    # only ever sees the finisher's own buffers. DEINT_ARMS (e.g. DP,DF) plays a subset.
    ARMS="DP|soak|$B/deint_prog50.ts|minutes=0.17"
    ARMS+=",DF|soak|$B/deint_tff.ts|minutes=0.25;seeks=8@2"
    ARMS+=",DR|soak|$B/deint_tff.ts|minutes=0.17;fieldrate=frame"
    ARMS+=",DW|soak|$B/deint_bff.ts|minutes=0.17"
    LABELS=DP,DF,DR,DW
    if [[ -n "${DEINT_ARMS:-}" ]]; then
      ARMS=$(print -r -- "$ARMS" | tr ',' '\n' | awk -v keep=",$DEINT_ARMS," -F'|' \
        'NF > 1 { k = index(keep, "," $1 ",") > 0 } k' | paste -sd, -)
      LABELS=$DEINT_ARMS
    fi
    for f in deint_prog50.ts deint_tff.ts deint_bff.ts; do
      [[ -e "$OUT/$f" ]] || { echo "missing $OUT/$f (Scripts/build_deint.sh makes it)"; exit 1; }
    done ;;
  film)
    # Film in interlaced carriage (Scripts/build_film.sh, docs/software-route-gpu.md Part 6), by eye, each clip ON (film
    # handling) then OFF (film=off: the container's rate and timing, interlaced pictures through bwdif, as before):
    # FS soft telecine (DVD), FH hard telecine (broadcast), FP 2:2 (25p film in 1080i25). FILM_ARMS plays a subset.
    ARMS="FS|soak|$B/film_soft.ts|minutes=0.17;slate=off"
    ARMS+=",FSx|soak|$B/film_soft.ts|minutes=0.17;film=off;slate=off"
    ARMS+=",FH|soak|$B/film_hard.ts|minutes=0.17;slate=off"
    ARMS+=",FHx|soak|$B/film_hard.ts|minutes=0.17;film=off;slate=off"
    ARMS+=",FP|soak|$B/film_psf.ts|minutes=0.17;slate=off"
    ARMS+=",FPx|soak|$B/film_psf.ts|minutes=0.17;film=off;slate=off"
    LABELS=FS,FSx,FH,FHx,FP,FPx
    if [[ -n "${FILM_ARMS:-}" ]]; then
      ARMS=$(print -r -- "$ARMS" | tr ',' '\n' | awk -v keep=",$FILM_ARMS," -F'|' \
        'NF > 1 { k = index(keep, "," $1 ",") > 0 } k' | paste -sd, -)
      LABELS=$FILM_ARMS
    fi
    for f in film_soft.ts film_hard.ts film_psf.ts; do
      [[ -e "$OUT/$f" ]] || { echo "missing $OUT/$f (Scripts/build_film.sh makes it)"; exit 1; }
    done ;;
  subs)
    # AVKit's own subtitle selection and suppressesPlayerRendering (Scripts/build_subs.sh), by eye, about 2.5 min.
    # SUBS_ARMS (e.g. SP,SF) plays a subset.
    S="$B/subs/master.m3u8"
    ARMS="SA|subs|$S|case=auto,SS|subs|$S|case=sup,ST|subs|$S|case=trap,SF|subs|$S|case=fix"
    ARMS+=",SP|subs|$S|case=pip,SD|subs|$S|case=sdh"
    LABELS=SA,SS,ST,SF,SP,SD
    if [[ -n "${SUBS_ARMS:-}" ]]; then
      ARMS=$(print -r -- "$ARMS" | tr ',' '\n' | awk -v keep=",$SUBS_ARMS," -F'|' \
        'NF > 1 { k = index(keep, "," $1 ",") > 0 } k' | paste -sd, -)
      LABELS=$SUBS_ARMS
    fi
    [[ -e "$OUT/subs/master.m3u8" ]] || { echo "missing $OUT/subs (Scripts/build_subs.sh makes it)"; exit 1; } ;;
  *) echo "unknown SEQ=$SEQ (main|el|vt|count|cm4|cm4q|l8ladder|fmt|bits|card|cardov|placeholder|soak|deint|film|subs)"; exit 1 ;;
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
if [[ "$SEQ" == card || "$SEQ" == cardov ]]; then
  cat <<'LEGEND'
what to look for (top-left label: arm, out=, rpu=, and the mode tvOS is sending; expect Dolby Vision):
  border visible     the amplifier RPU is active (TI and OI, the identity controls: expect flat grey)
  "½" visible        rounded or better
  "12" clean         12 or more bits survive tvOS's output (watch TF/TS, and OS on the overlay)
  speckled           dither (TD ordered, TB blue noise)
  BR/BF/BS           the bullseye banding fallback, no override: compare the rings across the three
LEGEND
fi
if [[ "$SEQ" == placeholder ]]; then
  cat <<'LEGEND'
what to look for (top-left: the arm and the mode tvOS is sending):
  GD  Dolby Vision; steady (measured 2026-10-24: the placeholder's constant RPU drives the panel, not the overlay's)
  GX  Dolby Vision; the picture pulses (measured: AVPlayer's own RPU reaches the TV)
  GH  HDR10 (not Dolby Vision); steady picture
  GV  steady (measured: the overlay's RPU never reaches the TV); Atmos; press the remote: bar, pause, scrub
  GE  Dolby Vision; the picture pulses; Atmos; press the remote: bar, pause, scrub (the picture follows)
  GS  after each seek (10 s: to 40, 20 s: to 5, 30 s: to 60) the BL counter shows the target frame within a moment
LEGEND
fi
if [[ "$SEQ" == deint ]]; then
  cat <<'LEGEND'
the card, top to bottom: a white bar sweeping right, a band of fine stripes, a 4-digit field number and a
small box stepping right. Expect the TV at 50 Hz (Match Frame Rate on).
  DP  control: the card as progressive 50p, no deinterlacer (10 s): everything moves as DF should
  DF  correct, field rate (15 s, at 8 s it jumps back to 0:02):
      bar edges clean, no comb teeth; stripes sharp and still; the number a steady blur of changing digits
      (50 a second, too fast to read) with no backward jumps; the box glides right, never steps back;
      after the jump the same, at once
  DR  frame rate (10 s): bar and stripes as DF; the box hops two places at a time, motion a little rougher
  DW  the control, field order flagged wrong (10 s): the box jitters back and forth, the bar shudders;
      if DF looked like this, the field order is being read wrong
  any arm: a frozen picture with the tone still playing is the wedge the old transfer copy guarded against
LEGEND
fi
if [[ "$SEQ" == film ]]; then
  cat <<'LEGEND'
the pan card: bars (top) and ruler ticks (bottom) panning right, two still lines between. Each clip plays twice,
10 s each: ON (film handling) then OFF (as before this work). Watch the bars glide:
  FS / FSx   3:2 soft telecine (DVD). ON: TV at 23.976, an even glide. OFF: TV at 29.97, a 2-3 stutter in the pan
  FH / FHx   3:2 hard telecine (broadcast). ON: TV at 23.976, an even glide, crisp ticks. OFF: deinterlaced at field
             rate, a stutter and softer, shimmering ticks
  FP / FPx   2:2, 25p film in 1080i25. ON: an even glide, crisp ticks. OFF: deinterlaced, slightly softer ticks
  every arm: the two middle lines never move; comb teeth on any edge are a fault
LEGEND
fi
case "$SEQ" in
  soak) ;;
  card|cardov|cm4q|l8ladder|placeholder|deint|film) echo "watch the TV (no recording needed); launching in 10 s" ;;
  *) echo "start the phone recording now; launching in 10 s" ;;
esac
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
  echo "cut and analyse: python3 $HERE/cut.py <recording>.MOV $LOG --slates$([[ $SEQ == cm4 ]] && echo " --color")"
  echo "                 then the same command with --sync <video seconds>=<clock read off the slate>"
fi
