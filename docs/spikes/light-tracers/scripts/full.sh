#!/usr/bin/env bash
# scene-0031's hires run again: 2M massive + 6M light tracers, or the real thing (#187).
#   full.sh <name> <lock: yes|no> <sillage-render options...>
set -uo pipefail
NAME="$1"; LOCKED="$2"; shift 2
LOCK="$HOME/claude-workspace/.gpu-lock"
WT="/Users/pierregc/claude-workspace/sillage-wt-187"
B="$HOME/claude-workspace/tracers-187-out/bin"
S="$HOME/claude-workspace/sillage/library/2026-10-30-b/scene-0031"
O="$HOME/claude-workspace/tracers-187-out/$NAME"
mkdir -p "$O"

if [ "$LOCKED" = yes ]; then
    until mkdir "$LOCK" 2>/dev/null; do
        echo "$(date '+%H:%M:%S') lock held by: $(cat "$LOCK"/owner 2>/dev/null)"
        sleep 30
    done
    echo "thread #187 (light tracers) full run $NAME, pid $$, $(date '+%F %T')" > "$LOCK/owner"
    trap 'rm -rf "$LOCK"' EXIT
    while pgrep -x sillage-render >/dev/null || pgrep -x tests >/dev/null || pgrep -x Sillage >/dev/null; do
        echo "$(date '+%H:%M:%S') waiting for: $(ps -Ao comm | grep -E 'sillage-render|/tests$|Sillage$' | sort | uniq -c | tr '\n' ' ')"
        sleep 20
    done
else
    # Never while someone is timing.
    while [ -d "$LOCK" ]; do
        echo "$(date '+%H:%M:%S') lock held by: $(cat "$LOCK"/owner 2>/dev/null)"
        sleep 60
    done
fi

echo "== $NAME $(date '+%T')"
start=$(date +%s)
DYLD_LIBRARY_PATH="$B" /usr/bin/time -l "$B/sillage-render" --scene "$S/scene.json" --look "$S/look.json" \
    --frames 923 --fps 30 --width 960 --height 540 --no-sidecars \
    --video "$O/hires.mov" --curves "$O/curves.csv" --take "$O/take.sillage" --take-interval 16 \
    --density "$O/density.npy" --density-frames 12 "$@" > "$O/run.log" 2>&1
status=$?
echo "== $NAME exit $status in $(( $(date +%s) - start )) s $(date '+%T')"
grep -E "^(tracers|settle|done|drift|density)" "$O/run.log"
tail -25 "$O/run.log" | grep -E "maximum resident|real"
