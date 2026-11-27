#!/usr/bin/env bash
# rough_cut.sh animatic|film [piece...]: the Sombrero rough cut (#509).
#   Renders the flight in pieces, each under the GPU lock, skipping the 18-25.3 s hold; then
#   assembles: the freeze frame held over the gap, the split screen beside Hubble
#   (scripts/picture-film.py), a fade at each end. With piece names, renders only those
#   (a b1 b2 b3 b4) and stops; `assemble` alone redoes the assembly.
#   The film draws a (far shots) with #508's binary and the flight as #508 reads it, b1-b4 with
#   #510's binary and its inside stars (rough-cut-stars); the animatic all with #508's.
# Env: TAKE, LOOK, BIN508, BIN510, OUT ($SOMBRERO/out/509), CRF (x265, 20); SOMBRERO, the working
#   folder (~/claude-workspace/sombrero); SR, the sillage-render wrapper ($SOMBRERO/sr508.sh); PY.
set -euo pipefail
W=$(cd "$(dirname "$0")/../../.." && pwd)
SOM=${SOMBRERO:-$HOME/claude-workspace/sombrero}
TAKE=${TAKE:-$SOM/lib/sombrero-8m-s7}
LOOK=${LOOK:-$SOM/out/506/s2/looks/sombrero-506.look.json}
BIN508=${BIN508:-$SOM/out/508/bin/v11}
BIN510=${BIN510:-$SOM/out/510/bin/v2}
OUT=${OUT:-$SOM/out/509}
PY=${PY:-$SOM/venv/bin/python}
SR=${SR:-$SOM/sr508.sh}
CRF=${CRF:-20}
mode=$1; shift
case $mode in
  animatic) fps=10; size=(--width 640 --height 360); codec=hevc
            far=$OUT/flights/rough-cut-animatic.flight.json; near=$far; nbin=$BIN508 ;;
  film) fps=30; size=(--preset 1080p); codec=prores
        far=$OUT/flights/rough-cut.flight.json; near=$OUT/flights/rough-cut-stars.flight.json; nbin=$BIN510 ;;
  *) echo "rough_cut.sh animatic|film [piece...]"; exit 2 ;;
esac
D=$OUT/$mode; mkdir -p "$D"
# name:first second:last second:seconds drawn past it (F: the last frame). Each b piece but the
# last runs a second into the next, crossfaded over it: two runs differ by a few percent in
# exposure and in their stars from inside, a step at the seam otherwise.
PIECES=(a:0:18:F b1:25.3:40:1 b2:40:52:1 b3:52:64:1 b4:64:78:F)
want=("$@")

render() {
  local name=$1 s=$2 e=$3 tail=$4; [ "$tail" = F ] && tail="1 / $fps"
  local dur; dur=$(python3 -c "print(round($e - $s + $tail, 6))")
  local F=$near bin=$nbin; [ "$name" = a ] && { F=$far; bin=$BIN508; }
  SR_BIN=$bin "$W/scripts/gpu-lock.sh" run "sombrero-509-$mode-$name" "$SR" export "$TAKE" --look "$LOOK" \
    --flight "$F" "${size[@]}" --fps $fps --codec $codec --start "$s" --duration "$dur" \
    --out "$D/$name.mov" > "$D/$name.log" 2>&1 || { tail -5 "$D/$name.log"; exit 1; }
  tail -3 "$D/$name.log" | head -1
}

if [ ${#want[@]} -eq 0 ] || [ "${want[0]}" != assemble ]; then
  for p in "${PIECES[@]}"; do
    IFS=: read -r name s e tail <<< "$p"
    if [ ${#want[@]} -eq 0 ] || [[ " ${want[*]} " == *" $name "* ]]; then render "$name" "$s" "$e" "$tail"; fi
  done
  [ ${#want[@]} -eq 0 ] || exit 0
fi

# the master: a with its last frame held to 25.3 s, b1-b4 crossfaded a second past each seam,
# faded in over 0.5 s and out over 1.5 s
hold=$(python3 -c "print(round((25.3 - 18) * $fps) - 1)")
total=$(python3 -c "print(round(78 * $fps) + 1)")
n="format=yuv422p10le,setsar=1,settb=AVTB,fps=$fps"
ffmpeg -v error -y -i "$D/a.mov" -i "$D/b1.mov" -i "$D/b2.mov" -i "$D/b3.mov" -i "$D/b4.mov" -filter_complex \
  "[0:v]$n,tpad=stop_mode=clone:stop=$hold[a];[1:v]$n[b1];[2:v]$n[b2];[3:v]$n[b3];[4:v]$n[b4];\
[b1][b2]xfade=transition=fade:duration=1:offset=14.7[x1];[x1][b3]xfade=transition=fade:duration=1:offset=26.7[x2];\
[x2][b4]xfade=transition=fade:duration=1:offset=38.7[x3];[a][x3]concat=n=2:v=1,\
fade=t=in:st=0:d=0.5,fade=t=out:st=$(python3 -c "print(78 + 1 / $fps - 1.5)"):d=1.5[v]" \
  -map "[v]" -c:v prores_ks -profile:v 3 -pix_fmt yuv422p10le "$D/master.mov"
echo "master frames $(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 "$D/master.mov") (expected $total)"
# Hubble at the frame's own framing: 26.5 kpc across, nucleus at the centre
read -r w h < <(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$D/master.mov" | tr , ' ')
$PY -c "
import sys; sys.path.insert(0, '$W/references/sombrero/tools'); import film_split
film_split.hubble($w, $h).save('$D/hubble.png')"
$PY "$W/scripts/picture-film.py" film "$D/master.mov" "$D/rough-cut.mp4" --picture "$D/hubble.png" --hold 18:7.3 --crf "$CRF" \
  --layout shrink --left "Simulation  ·  Sillage" --right "Hubble  ·  ESA/Hubble & NASA, K. Noll"
