#!/bin/bash
# The second half of the grain spike: one disk filling the frame, which is where a particle
# shows. Renders an isolated disk at t = 0 in 4K for several counts and looks, scores them and
# lays them out.
#
#     scripts/gigantism-disk.sh <base look.json> <out dir>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE="$1"
OUT="$2"
R="$ROOT/scripts/dev.sh"
mkdir -p "$OUT/looks" "$OUT/disk"

python3 - "$BASE" "$OUT/looks" <<'EOF'
import json, sys
base = json.load(open(sys.argv[1]))
out = sys.argv[2]
base.setdefault("look", {})
# A fixed camera, nearly face-on, framed on the disk itself.
base["camera"] = {"mode": "fixed", "elevation": 1.35, "azimuth": 0.4, "zoom": 1.0, "percentile": 0.98, "radius": 0}

def variant(name, **fields):
    file = json.loads(json.dumps(base))
    file["name"] = name
    file["look"].update(fields)
    json.dump(file, open(f"{out}/{name}.look.json", "w"), indent=2)

variant("baseline")
variant("col40", columnSmoothing=40)
variant("glint0", glint=0)
variant("col40-glint0.3", columnSmoothing=40, glint=0.3)
variant("col80-glint0", columnSmoothing=80, glint=0)
EOF
VARIANTS="baseline col40 glint0 col40-glint0.3 col80-glint0"

echo "== one disk, t = 0, 4K"
: > "$OUT/disk.log"
for n in 250000 1000000 4000000 8000000; do
    for v in $VARIANTS; do
        echo "-- $v $n" | tee -a "$OUT/disk.log"
        "$R" render --preset disk --particles "$n" --steps 2 --frames 2 --seed 7 \
            --width 3840 --height 2160 --look "$OUT/looks/$v.look.json" \
            --out "$OUT/disk/$v-$n.png" --no-sidecars 2>&1 | { grep -E "^frame|^done" || true; } | tee -a "$OUT/disk.log"
    done
done

echo "== scores"
python3 "$ROOT/scripts/grain.py" score "$OUT"/disk/*.0001.png | tee "$OUT/disk.tsv"

echo "== sheets"
for n in 250000 1000000 4000000 8000000; do
    FILES=()
    for v in $VARIANTS; do FILES+=("$OUT/disk/$v-$n.0001.png"); done
    python3 "$ROOT/scripts/grain.py" sheet "$OUT/sheet-disk-$n.jpg" --crop auto --label-from ".0001.png" "${FILES[@]}"
done
FILES=()
for n in 250000 1000000 4000000 8000000; do FILES+=("$OUT/disk/baseline-$n.0001.png"); done
for n in 250000 1000000 4000000 8000000; do FILES+=("$OUT/disk/col40-glint0.3-$n.0001.png"); done
python3 "$ROOT/scripts/grain.py" sheet "$OUT/sheet-disk-count.jpg" --crop auto --label-from ".0001.png" "${FILES[@]}"
echo "done: $OUT"
