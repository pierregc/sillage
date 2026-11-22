#!/usr/bin/env bash
# sweep.sh: 27 scenes round the chosen one (mass ratio x pericentre x axis tilt), each explored,
# run at 500k and matched to the Webb crop; scores to logs/sweep.csv
C="$HOME/claude-workspace/cartwheel"; BASE="${BASE:?the base scene.json}"
mkdir -p "$C/lib/sweep"
for r in 0.25 0.33 0.45; do for q in 0.6 1.2 2.0; do for t in 0.1 0.2 0.35; do
  n="r$r-q$q-t$t"; s="$C/lib/sweep/$n"
  [ -f "$s/match/cartwheel-crop.json" ] && continue
  python3 "$C/tools/make_scene.py" "$BASE" "$s" "$r" "$q" "$t" && cp "$C/lib/cartwheel/look.json" "$s/"
  "$C/tools/check.sh" "$s" || { echo "$n,failed" >> "$C/logs/sweep.csv"; continue; }
  python3 -c "import json,sys;m=json.load(open('$s/match/cartwheel-crop.json'));v=m['view'];print(f\"$n,{m['score']:.4f},{m['megayears']:.1f},{v['elevation']:.1f},{v['azimuth']:.1f},{v['roll']:.1f}\")" >> "$C/logs/sweep.csv"
done; done; done
echo done >> "$C/logs/sweep.csv"
