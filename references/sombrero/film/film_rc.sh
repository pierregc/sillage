#!/usr/bin/env bash
# film_rc.sh animatic|film [piece...|assemble|overlay]: the Sombrero film, release candidate (#509).
#   Renders the flight of film_rc.py in pieces, each under the GPU lock (GAP seconds between them so
#   other jobs get a turn), skipping the 16-25 s hold, and `wide`, the freeze drawn 1.55 times wider
#   for the split screen; `assemble` makes the master (the freeze frame held over the gap, pieces
#   crossfaded a second past each seam, a fade in, no fade out) and then the overlay; `overlay`
#   alone redoes the split screen and its words (split.py) on the master; `contact` the sheet.
#   film: 1080p ProRes pieces, piece a with BIN_A (#508's binary, the tuned freeze), the rest with
#   BIN; animatic: 640x360 at 30 fps, one render a frame, all with BIN.
# Env: TAKE, TAKE_A (piece a's take, TAKE by default), LOOK, BIN_A, BIN, OUT, CRF (x265, 20), GAP (20).
set -euo pipefail
W=$(cd "$(dirname "$0")/../../.." && pwd)
SOM=$HOME/claude-workspace/sombrero
TAKE=${TAKE:-$SOM/lib/sombrero-8m-s7-170}
TAKE_A=${TAKE_A:-$TAKE}
LOOK=${LOOK:-$SOM/out/506/s2/looks/sombrero-506.look.json}
BIN=${BIN:-$SOM/out/510/bin/v2}
OUT=${OUT:-$SOM/out/509b}
PY=$SOM/venv/bin/python
CRF=${CRF:-20}
GAP=${GAP:-20}
mode=$1; shift
case $mode in
  animatic) fps=30; size=(--width 640 --height 360); wsize="(640, 360)"; codec=prores; F=$OUT/flights/film-animatic.flight.json
            BIN_A=${BIN_A:-$BIN} ;;
  film) fps=30; size=(--preset 1080p); wsize="(1920, 1080)"; codec=prores; F=$OUT/flights/film.flight.json
        BIN_A=${BIN_A:-$SOM/out/508/bin/v11} ;;
  *) echo "film_rc.sh animatic|film [piece...|assemble|overlay]"; exit 2 ;;
esac
D=$OUT/$mode; mkdir -p "$D"
FREEZE=16; HOLD=9; END=98.7; SEAMS=(43.7 62.7 81.2)
# name:first second:last second:seconds drawn past it (F: the last frame alone). Each b piece but
# the last runs a second into the next and is crossfaded over it: two runs differ by a few percent
# in exposure and in their nearest stars.
PIECES=(a:0:16:F b1:25:43.7:1 b2:43.7:62.7:1 b3:62.7:81.2:1 b4:81.2:98.7:F wide)
want=("$@")

render() {
  local name=$1 s=$2 e=$3 tail=$4; [ "$tail" = F ] && tail="1 / $fps"
  local dur; dur=$(python3 -c "print(round($e - $s + $tail, 6))")
  local bin=$BIN take=$TAKE; [ "$name" = a ] && { bin=$BIN_A; take=$TAKE_A; }
  SR_BIN=$bin "$W/scripts/gpu-lock.sh" run "sombrero-509b-$mode-$name" "$SOM/sr508.sh" export "$take" --look "$LOOK" \
    --flight "$F" "${size[@]}" --fps $fps --codec $codec --start "$s" --duration "$dur" \
    --out "$D/$name.mov" > "$D/$name.log" 2>&1 || { tail -5 "$D/$name.log"; exit 1; }
  tail -3 "$D/$name.log" | head -1
}

# the freeze's camera, 1.55 times wider at the same scale, one PNG: the split screen's left half
wide() {
  local w=$1 h=$2 out=$3
  $PY - "$F" "$OUT/flights/wide.flight.json" "$FREEZE" <<'EOF'
import json, math, sys
d = json.load(open(sys.argv[1])); k = d["keys"][round(float(sys.argv[3]) * 30)]
k = {**k, "fov": round(2 * math.atan(math.tan(k["fov"] / 2) * 1.55), 7)}
json.dump({**d, "keys": [{**k, "at": 0}, {**k, "at": 1}]}, open(sys.argv[2], "w"))
EOF
  mkdir -p "$D/wide-keys"
  SR_BIN=$BIN_A "$W/scripts/gpu-lock.sh" run "sombrero-509b-$mode-wide" "$SOM/sr508.sh" export "$TAKE_A" --look "$LOOK" \
    --flight "$OUT/flights/wide.flight.json" --flight-keys "$D/wide-keys" --width "$w" --height "$h" > "$D/wide.log" 2>&1 \
    || { tail -5 "$D/wide.log"; exit 1; }
  cp "$D/wide-keys/key-00-000.00s.png" "$out"
}

overlay() {
  $PY "$W/references/sombrero/film/split.py" film "$D/master.mov" "$D/wide.png" "$D/film.mp4" $FREEZE:$HOLD --crf "$CRF"
}

contact() {
  local s=()
  for x in "1 far=0.1" "1 far=8" "1 far=15.9" "2 split=17" "2 split=20.5" "2 split=24" \
    "3 approach=25.7" "3 approach=28.2" "3 approach=31.2" "4 swoop=32.7" "4 swoop=34.2" "4 swoop=35.7" \
    "5 low flight=37.2" "5 low flight=40.2" "5 low flight=43.2" "6 descent=44.7" "6 descent=47.2" "6 descent=50.7" \
    "7 look up=54" "7 look left=58.7" "7 look right=61.7" "8 to the core=64.7" "8 to the core=67.7" "8 to the core=71.2" \
    "9 core turning=74.2" "9 core turning=77.7" "9 core turning=81.1" "10 pull-out=83.2" "10 pull-out=88.2" "10 pull-out=92.7" \
    "11 racing=94.2" "11 racing=96.2" "11 racing=98.6"; do s+=("$x"); done
  $PY "$W/references/sombrero/film/contact.py" "$D/film.mp4" "$D/contact.jpg" 640 "${s[@]}"
}

case "${want[0]:-}" in
  overlay) overlay; exit 0 ;;
  contact) contact; exit 0 ;;
  captions) wide 2976 1674 "$D/wide-1080p.png"
            $PY "$W/references/sombrero/film/split.py" still "$D/wide-1080p.png" "$D/split-captions.jpg" 1920x1080; exit 0 ;;
  assemble) ;;
  *) first=1
     for p in "${PIECES[@]}"; do
       IFS=: read -r name s e tail <<< "$p"
       if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " == *" $name "* ]]; then
         [ $first = 1 ] || sleep "$GAP"; first=0
         if [ "$name" = wide ]; then
           read -r ww wh < <(python3 -c "print(*(round(x * 1.55) for x in ${wsize}))"); wide "$ww" "$wh" "$D/wide.png"
         else render "$name" "$s" "$e" "$tail"; fi
       fi
     done
     [ ${#want[@]} -eq 0 ] || exit 0 ;;
esac

# the master: a with its last frame held over the hold, the b pieces crossfaded a second past each
# seam (offsets from the first b piece's start), faded in over 0.5 s, cut at the end
hold=$(python3 -c "print(round($HOLD * $fps) - 1)")
n="format=yuv422p10le,setsar=1,settb=AVTB,fps=$fps"
B0=$(python3 -c "print($FREEZE + $HOLD)")
o1=$(python3 -c "print(round(${SEAMS[0]} - $B0, 6))"); o2=$(python3 -c "print(round(${SEAMS[1]} - $B0, 6))"); o3=$(python3 -c "print(round(${SEAMS[2]} - $B0, 6))")
ffmpeg -v error -y -i "$D/a.mov" -i "$D/b1.mov" -i "$D/b2.mov" -i "$D/b3.mov" -i "$D/b4.mov" -filter_complex \
  "[0:v]$n,tpad=stop_mode=clone:stop=$hold[a];[1:v]$n[b1];[2:v]$n[b2];[3:v]$n[b3];[4:v]$n[b4];\
[b1][b2]xfade=transition=fade:duration=1:offset=$o1[x1];[x1][b3]xfade=transition=fade:duration=1:offset=$o2[x2];\
[x2][b4]xfade=transition=fade:duration=1:offset=$o3[x3];[a][x3]concat=n=2:v=1,fade=t=in:st=0:d=0.5[v]" \
  -map "[v]" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$D/master.mov"
echo "master frames $(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$D/master.mov") (expected $(python3 -c "print(round($END * $fps) + 1)"))"
overlay
