#!/usr/bin/env bash
# film_rc.sh animatic|film [piece...|assemble|overlay]: the Sombrero film, release candidate (#509).
#   Renders the flight of film_rc.py in pieces, each under the GPU lock (GAP seconds between them so
#   other jobs get a turn), skipping the 16-23.3 s hold; `assemble` makes the master (the freeze
#   frame held over the gap, pieces crossfaded a second past each seam, a fade in, no fade out) and
#   then the overlay; `overlay` alone redoes the split screen and its words on the master.
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
  animatic) fps=30; size=(--width 640 --height 360); codec=hevc; F=$OUT/flights/film-animatic.flight.json
            BIN_A=${BIN_A:-$BIN} ;;
  film) fps=30; size=(--preset 1080p); codec=prores; F=$OUT/flights/film.flight.json
        BIN_A=${BIN_A:-$SOM/out/508/bin/v11} ;;
  *) echo "film_rc.sh animatic|film [piece...|assemble|overlay]"; exit 2 ;;
esac
D=$OUT/$mode; mkdir -p "$D"
FREEZE=16; HOLD=7.3; END=95.5
# name:first second:last second:seconds drawn past it (F: the last frame alone). Each b piece but
# the last runs a second into the next and is crossfaded over it: two runs differ by a few percent
# in exposure and in their nearest stars.
PIECES=(a:0:16:F b1:23.3:42:1 b2:42:61:1 b3:61:78:1 b4:78:95.5:F)
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

overlay() {
  read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$D/master.mov" | tr , ' ')
  $PY -c "
import sys; sys.path.insert(0, '$W/references/sombrero/tools'); import film_split
film_split.hubble($w, $h).save('$D/hubble.png')"
  $PY "$W/scripts/picture-film.py" film "$D/master.mov" "$D/film.mp4" --picture "$D/hubble.png" --hold $FREEZE:$HOLD \
    --crf "$CRF" --layout shrink --left "Simulation  ·  Sillage" --right "Hubble  ·  ESA/Hubble & NASA, K. Noll"
}

case "${want[0]:-}" in
  overlay) overlay; exit 0 ;;
  assemble) ;;
  *) first=1
     for p in "${PIECES[@]}"; do
       IFS=: read -r name s e tail <<< "$p"
       if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " == *" $name "* ]]; then
         [ $first = 1 ] || sleep "$GAP"; first=0
         render "$name" "$s" "$e" "$tail"
       fi
     done
     [ ${#want[@]} -eq 0 ] || exit 0 ;;
esac

# the master: a with its last frame held over the hold, the b pieces crossfaded a second past each
# seam (offsets from the first b piece's start), faded in over 0.5 s, cut at the end
hold=$(python3 -c "print(round($HOLD * $fps) - 1)")
n="format=yuv422p10le,setsar=1,settb=AVTB,fps=$fps"
B0=$(python3 -c "print($FREEZE + $HOLD)")
o1=$(python3 -c "print(round(42 - $B0, 6))"); o2=$(python3 -c "print(round(61 - $B0, 6))"); o3=$(python3 -c "print(round(78 - $B0, 6))")
ffmpeg -v error -y -i "$D/a.mov" -i "$D/b1.mov" -i "$D/b2.mov" -i "$D/b3.mov" -i "$D/b4.mov" -filter_complex \
  "[0:v]$n,tpad=stop_mode=clone:stop=$hold[a];[1:v]$n[b1];[2:v]$n[b2];[3:v]$n[b3];[4:v]$n[b4];\
[b1][b2]xfade=transition=fade:duration=1:offset=$o1[x1];[x1][b3]xfade=transition=fade:duration=1:offset=$o2[x2];\
[x2][b4]xfade=transition=fade:duration=1:offset=$o3[x3];[a][x3]concat=n=2:v=1,fade=t=in:st=0:d=0.5[v]" \
  -map "[v]" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$D/master.mov"
echo "master frames $(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$D/master.mov") (expected $(python3 -c "print(round($END * $fps) + 1)"))"
overlay
