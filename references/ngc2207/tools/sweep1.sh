#!/usr/bin/env bash
# sweep1.sh: 27 scenes round Struck et al. 2005 (mass ratio x pericentre x eccentricity), each explored,
# run at 500k and matched to the picture; rows in logs/sweep.csv
C="$HOME/claude-workspace/ngc2207"; mkdir -p "$C/lib/sweep"
for r in 0.75 0.55 0.95; do for q in 22 16 28; do for e in 0.6 0.3 0.9; do
  n="r$r-q$q-e$e"; s="$C/lib/sweep/$n"
  [ -f "$s/match/ngc2207.json" ] && continue
  [ -e "$C/tools/STOP" ] && break 3
  python3 "$C/tools/make_scene.py" "$s" "$r" "$q" "$e"
  if "$C/tools/check.sh" "$s"; then "$C/tools/match.sh" "$s" & else echo "$n,failed" >> "$C/logs/sweep.csv"; fi
done; done; done
wait; echo done >> "$C/logs/sweep.csv"
