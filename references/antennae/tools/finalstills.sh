#!/usr/bin/env bash
# finalstills.sh <work dir> [look]: the stills the sheet of 25 needs, from <work>/final25.csv: each finalist at its
# matched moment and view, and for the best five the approach and the first passage from the same view.
# Needs $SR; holds $GPU_LOCK for each still.
T="$(cd "$(dirname "$0")" && pwd)"; W="$(cd "$1" && pwd)"; L="${2:-$T/../../../looks/hubble.look.json}"; LOCK="${GPU_LOCK:-$HOME/claude-workspace/.gpu-lock}"
still() { until mkdir "$LOCK" 2>/dev/null; do sleep 5; done; echo "antennae stills pid $$" > "$LOCK/owner"; "$T/photokey.sh" "$@"; local rc=$?; rm -rf "$LOCK"; return $rc; }
python3 - "$W/final25.csv" <<'PY' | while read -r rank n p1; do
import csv, sys, json
for r in csv.DictReader(open(sys.argv[1])):
    print(r["rank"], r["name"], r.get("peri1") or "0")
PY
  s="$W/lib/$n"; mkdir -p "$s/stills"
  [ -s "$s/stills/match.png" ] || still "$s" antennae "$L" "$s/stills/match.png"
  if [ "$rank" -le 5 ]; then
    p1=$(python3 -c "import sys; sys.path.insert(0, '$T'); from clock import clock; c = clock('$s'); print(c['pericentres'][0]['myr'], c['start_myr'])")
    read -r peri start <<< "$p1"
    a=$(python3 -c "print(max($peri - 60, $start + 2))")
    [ -s "$s/stills/approach.png" ] || still "$s" antennae "$L" "$s/stills/approach.png" "$a"
    [ -s "$s/stills/impact.png" ] || still "$s" antennae "$L" "$s/stills/impact.png" "$peri"
  fi
done
