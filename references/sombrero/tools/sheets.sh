#!/usr/bin/env bash
# sheets.sh: the grid's stills cropped to Hubble's framing, on sheets beside the picture.
# Plain export (the look's camera, hard dust slabs) is the main sheet; the flight key's (soft slabs) the second.
C="${SOMBRERO:-$HOME/claude-workspace/sombrero}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
PIC="$W/references/catalogue/images/heic2506a.jpg"; o="$C/out/tiles"; mkdir -p "$o" "$C/sheets"
lab() { python3 -c "
import sys;n=sys.argv[1];r=[l.split(',') for l in open('$C/logs/sweep.csv') if l.startswith(n+',')][0]
print(f'{n}   bulge {r[1]} x {r[2]}, ring {r[3]}, disk {r[4]}, flat {r[5]}')" "$1"; }
names=$(awk -F, 'NR>1 && NF>6 {print $1}' "$C/logs/sweep.csv")
for m in ${MYR:-260}; do
  pl=(); fl=(); labels=()
  for n in $names; do
    D=$("$C/sr.sh" flight "$C/lib/sweep/$n" --at 200,300 --look "$C/looks/sombrero-plain.look.json" 2>&1 | grep -o '[0-9.]* kpc from its aim' | head -1 | cut -d' ' -f1)
    # the look's camera stands back by the galaxy's size: the frame is 2 D tan(fov / 2) wide times 16:9
    python3 "$T/tiles.py" "$C/out/plain/$n-$m.png" "$o/plain-$n-$m.png" "$(python3 -c "import math; print(2 * $D * math.tan(0.031 / 2) * 16 / 9)")" && pl+=("$o/plain-$n-$m.png")
    k=$(ls "$C/out/flight-$n"/*.png | sed -n "$(( $(echo 200 260 340 | tr ' ' '\n' | grep -n "^$m$" | cut -d: -f1) ))p")
    python3 "$T/tiles.py" "$k" "$o/flight-$n-$m.png" 22.1 && fl+=("$o/flight-$n-$m.png")
    labels+=("$(lab "$n") · $m Myr")
  done
  L=$(IFS='|'; echo "${labels[*]}" | tr ',' ';' | tr '|' ',')
  python3 "$W/scripts/picture-film.py" sheet "$C/sheets/sheet-plain-$m.jpg" "${pl[@]}" --picture "$PIC" --picture-label "Hubble (heic2506a)" --labels "$L" --columns 4 --tile-width 960
  python3 "$W/scripts/picture-film.py" sheet "$C/sheets/sheet-flight-$m.jpg" "${fl[@]}" --picture "$PIC" --picture-label "Hubble (heic2506a)" --labels "$L" --columns 4 --tile-width 960
done
