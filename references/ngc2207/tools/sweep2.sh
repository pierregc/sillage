#!/usr/bin/env bash
# sweep2.sh <round-1 scene name>: 27 scenes at its mass, pericentre and eccentricity, the disks'
# orientations varied, the bulges brighter (0.14 and 0.1, for the picture's cores): NGC 2207's inclination x IC 2163's inclination x IC 2163's line of nodes
C="$HOME/claude-workspace/ngc2207"; base="$1"
r=$(sed -E 's/^r([0-9.]+)-q.*/\1/' <<< "$base"); q=$(sed -E 's/.*-q([0-9.]+)-e.*/\1/' <<< "$base"); e=$(sed -E 's/.*-e([0-9.]+)$/\1/' <<< "$base")
for i1 in 0.5 0.25 0.85; do for i2 in 0.7 0.35 1.05; do for w2 in 0 2.09 4.19; do
  n="o-$base-i$i1-j$i2-w$w2"; s="$C/lib/sweep/$n"
  [ -f "$s/match/ngc2207.json" ] && continue
  [ -e "$C/tools/STOP" ] && break 3
  python3 "$C/tools/make_scene.py" "$s" "$r" "$q" "$e" "$i1" "$i2" 0 "$w2" 260 0.14 0.1
  if "$C/tools/check.sh" "$s"; then "$C/tools/match.sh" "$s" & else echo "$n,failed" >> "$C/logs/sweep.csv"; fi
done; done; done
wait; echo done2 >> "$C/logs/sweep.csv"
