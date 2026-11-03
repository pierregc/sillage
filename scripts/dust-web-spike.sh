#!/bin/bash
# Spike #173, the dust web (docs/notes/dust-web.md): an isolated calm disk run once at 2 M,
# then drawn today and with the web, face-on, at 60 degrees and edge-on, and followed round by
# a camera turning with its material at two scale lengths.
#
#     scripts/dust-web-spike.sh <library> <out dir>
#
# <library> holds 2026-10-30-b/scene-0031, whose first galaxy is the disk. The run takes about
# ten minutes alone on the M4 Max; the stills a few more. Sheets: scripts/dust-web-sheet.py.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIBRARY="$1"
OUT="$2"
R="$ROOT/.build/dev/sillage-render"
export DYLD_LIBRARY_PATH="$ROOT/.build/dev"
mkdir -p "$OUT/disk" "$OUT/looks" "$OUT/stills" "$OUT/turning"

# Première alone, on the calm disk of #172, face-on in the xy plane.
python3 - "$LIBRARY/2026-10-30-b/scene-0031/scene.json" "$OUT/disk/scene.json" <<'EOF'
import json, sys
source = json.load(open(sys.argv[1]))
galaxy = dict(source["galaxies"][0])
galaxy.update({
    "position": [0, 0, 0], "velocity": [0, 0, 0], "inclination": 0.0, "positionAngle": 0.0,
    "particleShare": 1, "clumpiness": 0.05, "youngClumpiness": 0.5, "armMassContrast": 0.3,
    "armStreaming": 1, "massLopsidedness": 0.03, "patternShare": 0.9, "name": "Première calme",
})
json.dump({
    "version": source["version"], "name": "Disque calme", "seed": source["seed"],
    "solver": "barnesHut", "timeStepScale": 3.5, "openingAngle": 0.9,
    "centerSoftening": source["centerSoftening"], "galaxies": [galaxy],
}, open(sys.argv[2], "w"), indent=2)
EOF
cat > "$OUT/disk/clip.json" <<'EOF'
{"fps": 30, "frames": 300, "height": 540, "particles": 2000000, "settle": 2000, "steps": 4200, "width": 960}
EOF

# 150 Myr settled, then 312 Myr captured, a turn and a half at two scale lengths.
if [ ! -f "$OUT/disk/take.sillage" ]; then
    "$R" --scene "$OUT/disk/scene.json" --particles 2000000 --solver barnes-hut \
        --settle 2000 --steps 4200 --frames 300 --fps 30 --width 960 --height 540 \
        --take "$OUT/disk/take.sillage" --take-interval 2 --curves "$OUT/disk/curves-hires.csv" \
        --look "$ROOT/looks/raw.look.json" --no-sidecars
fi

# One look per variant: the field set, the camera fixed on the disk.
look() {
    python3 - "$ROOT/looks/$1.look.json" "$OUT/looks/$2.look.json" "$2" "$3" "$4" <<'EOF'
import json, sys
file = json.load(open(sys.argv[1]))
file["name"] = sys.argv[3]
file.setdefault("look", {}).update(json.loads(sys.argv[4]))
file["camera"] = json.loads(sys.argv[5])
json.dump(file, open(sys.argv[2], "w"), indent=2)
EOF
}
rm -f "$OUT"/looks/*.look.json
for base in hubble webb ember-dust; do
    for angle in face:1.52 tilt:0.5236 edge:0.0; do
        camera="{\"mode\": \"fixed\", \"elevation\": ${angle#*:}, \"azimuth\": 0.4, \"radius\": 22}"
        look "$base" "$base-${angle%%:*}-today" "{}" "$camera"
        look "$base" "$base-${angle%%:*}-web" "{\"dustWeb\": 1}" "$camera"
    done
done
LOOKS=("$OUT"/looks/*.look.json)
"$R" look "$OUT/disk" --grid --stills "$OUT/stills" --width 3840 --frames 0,150,299 \
    --no-variants --no-catalogue --base "${LOOKS[0]}" "${LOOKS[@]:1}"

# The disk followed round: the camera turns at 0.02895 rad/Myr, the material's rate at two
# scale lengths, 1.0405 Myr a captured frame, so a crop stays on the same stretch of disk.
for k in 0 1 2 3 4 5 6 7; do
    frame=$((60 + 15 * k))
    azimuth=$(python3 -c "print(0.4 + 0.02895 * 1.0405 * 15 * $k)")
    camera="{\"mode\": \"fixed\", \"elevation\": 1.52, \"azimuth\": $azimuth, \"radius\": 22}"
    look hubble "turning-$frame-today" "{}" "$camera"
    look hubble "turning-$frame-web" "{\"dustWeb\": 1}" "$camera"
    "$R" look "$OUT/disk" --grid --stills "$OUT/turning" --width 3840 --frames "$frame" \
        --no-variants --no-catalogue --base "$OUT/looks/turning-$frame-today.look.json" \
        "$OUT/looks/turning-$frame-web.look.json"
done
echo "stills in $OUT/stills and $OUT/turning"
