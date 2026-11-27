#!/usr/bin/env bash
# film_rc.sh animatic|film [piece...|assemble|overlay|changes]: the Sombrero film, release candidate (#509).
#   Renders the flight of film_rc.py in pieces, each under the GPU lock (GAP seconds between them so
#   other jobs get a turn), skipping the 16-25 s hold, and `wide`, the freeze drawn 1.55 times wider
#   for the split screen; `assemble` makes the master (the freeze frame held over the gap, pieces
#   crossfaded a second past each seam, a fade in, no fade out) and then the overlay; `overlay`
#   alone redoes the split screen and its words (split.py) on the master; `contact` the sheet;
#   `changes` the shots changed since 02 alone (a, then b2-b4, cut between), with its sheet.
#   film: ProRes pieces at RES (1080p, or 4k into OUT/film-4k); animatic: 640x360 at 30 fps, one
#   render a frame. One binary for all (#509's RC2: #510's stars, #511's dust, #512's sky and halo,
#   the sky kept out of the bloom), BIN_A only to draw piece a apart.
# Env: TAKE, TAKE_A (piece a's take, TAKE by default), LOOK, BIN_A, BIN, OUT, RES (1080p), CRF (x265,
#   20), GAP (20); SOMBRERO, the working folder the defaults are in (~/claude-workspace/sombrero); SR,
#   the wrapper that runs the sillage-render built in $SR_BIN ($SOMBRERO/sr509c.sh); PY, a Python with
#   numpy, scipy and Pillow ($SOMBRERO/venv/bin/python). docs/notes/sombrero.md has the film's own run.
set -euo pipefail
W=$(cd "$(dirname "$0")/../../.." && pwd)
SOM=${SOMBRERO:-$HOME/claude-workspace/sombrero}
TAKE=${TAKE:-$SOM/lib/sombrero-8m-s7-170}
TAKE_A=${TAKE_A:-$TAKE}
LOOK=${LOOK:-$W/references/sombrero/film/sombrero-509c.look.json}
BIN=${BIN:-$SOM/out/509c/bin/v2}
RES=${RES:-1080p}
OUT=${OUT:-$SOM/out/509c}
PY=${PY:-$SOM/venv/bin/python}
SR=${SR:-$SOM/sr509c.sh}
CRF=${CRF:-20}
GAP=${GAP:-20}
mode=$1; shift
case $mode in
  animatic) fps=30; size=(--width 640 --height 360); wsize="(640, 360)"; codec=prores; F=$OUT/flights/film-animatic.flight.json
            BIN_A=${BIN_A:-$BIN} ;;
  film) fps=30; size=(--preset "$RES"); codec=prores; F=$OUT/flights/film.flight.json
        case $RES in 1080p) wsize="(1920, 1080)" ;; 4k) wsize="(3840, 2160)" ;; *) echo "RES 1080p or 4k"; exit 2 ;; esac
        BIN_A=${BIN_A:-$BIN} ;;
  *) echo "film_rc.sh animatic|film [piece...|assemble|overlay|contact|changes|captions]"; exit 2 ;;
esac
D=$OUT/$mode; [ "$mode" = film ] && [ "$RES" != 1080p ] && D=$OUT/film-$RES; mkdir -p "$D"
FREEZE=16; HOLD=9; END=107.7; SEAMS=(43.7 64.7 88.2)
# name:first second:last second:seconds drawn past it (F: the last frame alone). Each b piece but
# the last runs a second into the next and is crossfaded over it: two runs differ by a few percent
# in exposure and in their nearest stars.
PIECES=(a:0:16:F b1:25:43.7:1 b2:43.7:64.7:1 b3:64.7:88.2:1 b4:88.2:107.7:F wide)
want=("$@")

render() {
  local name=$1 s=$2 e=$3 tail=$4; [ "$tail" = F ] && tail="1 / $fps"
  local dur; dur=$(python3 -c "print(round($e - $s + $tail, 6))")
  local bin=$BIN take=$TAKE; [ "$name" = a ] && { bin=$BIN_A; take=$TAKE_A; }
  SR_BIN=$bin "$W/scripts/gpu-lock.sh" run "sombrero-509c-$mode-$name" "$SR" export "$take" --look "$LOOK" \
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
  SR_BIN=$BIN_A "$W/scripts/gpu-lock.sh" run "sombrero-509c-$mode-wide" "$SR" export "$TAKE_A" --look "$LOOK" \
    --flight "$OUT/flights/wide.flight.json" --flight-keys "$D/wide-keys" --width "$w" --height "$h" > "$D/wide.log" 2>&1 \
    || { tail -5 "$D/wide.log"; exit 1; }
  cp "$D/wide-keys/key-00-000.00s.png" "$out"
}

overlay() {
  $PY "$W/references/sombrero/film/split.py" film "$D/master.mov" "$D/wide.png" "$D/film.mp4" $FREEZE:$HOLD --crf "$CRF"
}

# the sheet's frames, three a shot (seconds of the film)
SHOTS=("1 far=0.6" "1 far=8" "1 far=15.9" "2 split=17" "2 split=20.5" "2 split=24"
  "3 approach=25.7" "3 approach=28.2" "3 approach=31.2" "4 swoop=32.7" "4 swoop=34.2" "4 swoop=35.7"
  "5 low flight=37.2" "5 low flight=40.2" "5 low flight=43.2" "6 descent=44.7" "6 descent=47.2" "6 descent=50.7"
  "7 look right=52" "7 look right=58.9" "7 look right=64" "8 to the core=68" "8 to the core=73" "8 to the core=78"
  "9 core turning=80" "9 core turning=84" "9 core turning=88" "10 pull-out=90" "10 pull-out=95" "10 pull-out=100"
  "11 ending=102.5" "11 ending=105" "11 ending=107.6")

contact() {
  $PY "$W/references/sombrero/film/contact.py" "$D/film.mp4" "$D/contact.jpg" 640 "${SHOTS[@]}"
}

# the shots changed since 02: a (0-16), then b2-b4 (43.7 s on) crossfaded as in the master, cut
# between; its sheet with the film's seconds mapped (43.7 s of the film is 16 s of it)
changes() {
  local o2 o3 s=() x
  o2=$(python3 -c "print(round(${SEAMS[1]} - ${SEAMS[0]}, 6))"); o3=$(python3 -c "print(round(${SEAMS[2]} - ${SEAMS[0]}, 6))")
  ffmpeg -v error -y -i "$D/a.mov" -i "$D/b2.mov" -i "$D/b3.mov" -i "$D/b4.mov" -filter_complex \
    "[0:v]$n[a];[1:v]$n[b2];[2:v]$n[b3];[3:v]$n[b4];[b2][b3]xfade=transition=fade:duration=1:offset=$o2[x2];\
[x2][b4]xfade=transition=fade:duration=1:offset=$o3[x3];[a][x3]concat=n=2:v=1,fade=t=in:st=0:d=0.5,format=yuv420p[v]" \
    -map "[v]" -c:v libx264 -crf "$CRF" -preset slow -tune grain -tag:v avc1 -movflags +faststart "$D/changes.mp4"
  for x in "${SHOTS[@]:0:3}"; do s+=("$x"); done
  for x in "${SHOTS[@]:15}"; do s+=("${x%=*}=$(python3 -c "print(round(${x##*=} - ${SEAMS[0]} + $FREEZE, 3))")"); done
  $PY "$W/references/sombrero/film/contact.py" "$D/changes.mp4" "$D/changes-contact.jpg" 640 "${s[@]}"
}

case "${want[0]:-}" in
  overlay) overlay; exit 0 ;;
  contact) contact; exit 0 ;;
  changes) n="format=yuv422p10le,setsar=1,settb=AVTB,fps=$fps"; changes; exit 0 ;;
  captions) read -r cw ch < <(python3 -c "print(*(round(x * 1.55) for x in ${wsize}))")
            wide "$cw" "$ch" "$D/wide-captions.png"
            $PY "$W/references/sombrero/film/split.py" still "$D/wide-captions.png" "$D/split-captions.jpg" \
              "$(python3 -c "print('x'.join(str(x) for x in ${wsize}))")"; exit 0 ;;
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
