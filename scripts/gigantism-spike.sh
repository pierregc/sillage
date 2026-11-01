#!/bin/bash
# The grain spike (docs/notes/gigantism.md): look variants on a scene's hires take, grain
# against particle count at t = 0, and the render cost of each, in one folder.
#
#     scripts/gigantism-spike.sh <scene folder> <out dir> [frames]
#
# frames: captured frame numbers for the stills, comma separated; left out, the key frames.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCENE="$1"
OUT="$2"
FRAMES="${3:-}"
R="$ROOT/scripts/dev.sh"
mkdir -p "$OUT/looks" "$OUT/stills" "$OUT/count"

python3 - "$SCENE/look.json" "$OUT/looks" <<'EOF'
import json, sys
base = json.load(open(sys.argv[1]))
out = sys.argv[2]
base.setdefault("look", {})
look = base["look"]

def variant(name, **fields):
    file = json.loads(json.dumps(base))
    file["name"] = name
    file["look"].update(fields)
    json.dump(file, open(f"{out}/{name}.look.json", "w"), indent=2)

variant("baseline")
variant("smooth", smoothingScale=round(look.get("smoothingScale", 1.9) * 1.6, 2), minimumKernel=2.0)
variant("glint0", glint=0)
variant("col20", columnSmoothing=20)
variant("col40", columnSmoothing=40)
variant("col80", columnSmoothing=80)
variant("col40-glint0.3", columnSmoothing=40, glint=0.3)
variant("bloom-low", bloomThreshold=0.05, bloomIntensity=1.0)
EOF
VARIANTS="smooth glint0 col20 col40 col80 col40-glint0.3 bloom-low"
HAND=()
for v in $VARIANTS; do HAND+=("$OUT/looks/$v.look.json"); done

echo "== stills from the hires take"
"$R" look "$SCENE" --grid --stills "$OUT/stills" --width 3840 --no-variants --no-catalogue \
    --base "$OUT/looks/baseline.look.json" ${FRAMES:+--frames "$FRAMES"} "${HAND[@]}" | tee "$OUT/look.log"

echo "== grain against particle count, t = 0, 4K"
: > "$OUT/count.log"
for v in baseline col40; do
    for n in 250000 500000 1000000 2000000 4000000 8000000; do
        echo "-- $v $n" | tee -a "$OUT/count.log"
        "$R" render --scene "$SCENE/scene.json" --particles "$n" --steps 2 --frames 2 \
            --width 3840 --height 2160 --look "$OUT/looks/$v.look.json" \
            --out "$OUT/count/$v-$n.png" --no-sidecars 2>&1 | { grep -E "^frame|^done" || true; } | tee -a "$OUT/count.log"
    done
done

echo "== scores"
python3 "$ROOT/scripts/grain.py" score "$OUT"/stills/*.png | tee "$OUT/stills.tsv"
python3 "$ROOT/scripts/grain.py" score "$OUT"/count/*.0001.png | tee "$OUT/count.tsv"

echo "== sheets"
for f in $(ls "$OUT/stills" | sed -n 's/.*-\([0-9][0-9]*\)\.png$/\1/p' | sort -un); do
    FILES=()
    for v in baseline $VARIANTS; do FILES+=("$OUT/stills/$v-$f.png"); done
    python3 "$ROOT/scripts/grain.py" sheet "$OUT/sheet-$f.jpg" --crop auto --label-from "-$f.png" "${FILES[@]}"
done
FILES=()
for v in baseline col40; do
    for n in 250000 1000000 2000000 8000000; do FILES+=("$OUT/count/$v-$n.0001.png"); done
done
python3 "$ROOT/scripts/grain.py" sheet "$OUT/sheet-count.jpg" --crop auto --label-from ".0001.png" "${FILES[@]}"
echo "done: $OUT"
