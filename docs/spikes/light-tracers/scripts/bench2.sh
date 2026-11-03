#!/usr/bin/env bash
# Reruns bench configs until one runs with no other GPU work alongside it (#187).
#   bench2.sh <name> <sillage-render options...>   (several: one per line on stdin)
set -uo pipefail
LOCK="$HOME/claude-workspace/.gpu-lock"
WT="/Users/pierregc/claude-workspace/sillage-wt-187"
B="$WT/.build/dev"
S="$HOME/claude-workspace/sillage/library/2026-10-30-b/scene-0031"
O="$HOME/claude-workspace/tracers-187-out/bench"
mkdir -p "$O"

until mkdir "$LOCK" 2>/dev/null; do
    echo "$(date '+%H:%M:%S') lock held by: $(cat "$LOCK"/owner 2>/dev/null)"
    sleep 30
done
echo "thread #187 (light tracers) bench, pid $$, $(date '+%F %T')" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT

foreign() { (pgrep -x tests; pgrep -x Sillage; pgrep -x sillage-render | grep -v "^${1:-x}$") | tr '\n' ' '; }

while read -r name rest; do
    [ -z "$name" ] && continue
    for attempt in 1 2 3 4; do
        while [ -n "$(foreign)" ]; do sleep 10; done
        echo "== $name (attempt $attempt) $(date '+%T')"
        # shellcheck disable=SC2086
        DYLD_LIBRARY_PATH="$B" "$B/sillage-render" --scene "$S/scene.json" --look "$S/look.json" \
            --width 480 --height 270 --settle 4 --steps 60 --frames 3 --no-sidecars \
            --out "$O/$name/f.png" $rest > "$O/$name.log" 2>&1 &
        pid=$!
        seen=""
        while kill -0 "$pid" 2>/dev/null; do
            now=$(foreign "$pid")
            [ -n "$now" ] && seen="$seen $now"
            sleep 1
        done
        wait "$pid"
        grep -E "^(tracers|frame|profile)" "$O/$name.log" | tail -4
        if [ -z "$seen" ]; then break; fi
        echo "disturbed by:$seen"
    done
done
if [ -n "${DEBUG_THETA:-}" ]; then
    while [ -n "$(foreign)" ]; do sleep 10; done
    echo "== tracer force error against the opening angle $(date '+%T')"
    DEV="$(xcode-select -p)"
    DYLD_LIBRARY_PATH="$B:$DEV/Library/Developer/usr/lib" DYLD_FRAMEWORK_PATH="$DEV/Library/Developer/Frameworks" \
        "$B/debugtheta" 2>&1 | grep -E "DEBUG|passed|failed|issue"
fi
echo "== done $(date '+%T')"
