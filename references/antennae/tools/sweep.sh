#!/usr/bin/env bash
# sweep.sh <work dir> <plan.csv>: every scene of a plan (plan.py) through preview.sh, one after another, skipping
# those with a row in <work>/sweep.csv already, so it resumes where it stopped; <work>/STOP stops it between scenes.
# Needs $SR; reads $SIZE, $GPU_LOCK. Run it detached: nohup sweep.sh ... &
T="$(cd "$(dirname "$0")" && pwd)"; W="$(cd "$1" && pwd)"; plan="$2"
python3 - "$plan" <<'PY' | while IFS='|' read -r n args; do
import csv, sys
for r in csv.DictReader(open(sys.argv[1])):
    n = r.pop("name"); print(n + "|" + " ".join(f"{k}={v}" for k, v in r.items() if v != ""))
PY
  [ -e "$W/STOP" ] && break
  grep -q "^$n," "$W/sweep.csv" 2>/dev/null && continue
  # shellcheck disable=SC2086
  "$T/preview.sh" "$W" "$n" $args
done
wait; echo "$(date -u +%T) done $(basename "$plan")" >> "$W/logs/sweep.log"
