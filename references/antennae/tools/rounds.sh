#!/usr/bin/env bash
# rounds.sh <work dir> <round 1 end> <round 2 end>: the night of #525 after round 1 was started with sweep.sh on
# <work>/plan-r1.csv. At each end (HH:MM UTC, the next such time) the running sweep is stopped between
# scenes; then round 2 (50 scenes round the best 5 families), the 30 best again at 500 k with another seed (their
# takes kept), and the 25 kept in <work>/final25.csv. Needs $SR.
T="$(cd "$(dirname "$0")" && pwd)"; W="$(cd "$1" && pwd)"; at() { local t; t=$(TZ=UTC date -j -f %H:%M "$1" +%s); [ "$t" -le "$(date +%s)" ] && t=$((t + 86400)); echo "$t"; }
e1=$(at "$2"); e2=$(at "$3")
log() { echo "$(date -u +%T) $*" >> "$W/logs/rounds.log"; }
until_done() {  # until_done <plan> <end epoch>: wait for the sweep of a plan, stopping it at the end
  until grep -q "done $(basename "$1")" "$W/logs/sweep.log" 2>/dev/null; do
    [ "$(date +%s)" -ge "$2" ] && [ ! -e "$W/STOP" ] && { touch "$W/STOP"; log "stop $(basename "$1")"; }
    sleep 30
  done; rm -f "$W/STOP"
}
until_done "$W/plan-r1.csv" "$e1"; log "round 1: $(grep -c ',ok,' "$W/sweep.csv") rows"
python3 "$T/plan.py" "$W/plan-r2.csv" 50 2 --around "$W/sweep.csv" 5 0.3
SIZE=200000 "$T/sweep.sh" "$W" "$W/plan-r2.csv" &
until_done "$W/plan-r2.csv" "$e2"; log "round 2 done"
python3 "$T/select.py" "$W" finalists 30 "$W/plan-f.csv"
SIZE=500000 KEEP_TAKE=1 "$T/sweep.sh" "$W" "$W/plan-f.csv"
python3 "$T/select.py" "$W" keep 25 "$W/final25.csv" >> "$W/logs/rounds.log"; log "finalists done"
