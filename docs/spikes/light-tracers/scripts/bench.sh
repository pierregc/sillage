#!/usr/bin/env bash
# Step cost of light tracers against real counts, scene-0031, alone on the GPU (#187).
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

# Work already running on the GPU when the lock was taken finishes first.
while pgrep -x sillage-render >/dev/null || pgrep -x tests >/dev/null || pgrep -x Sillage >/dev/null; do
    echo "$(date '+%H:%M:%S') waiting for: $(ps -Ao comm | grep -E 'sillage-render|/tests$|Sillage$' | sort | uniq -c | tr '\n' ' ')"
    sleep 20
done

run() {
    local name="$1"; shift
    echo "== $name $(date '+%T')"
    DYLD_LIBRARY_PATH="$B" "$B/sillage-render" --scene "$S/scene.json" --look "$S/look.json" \
        --width 480 --height 270 --settle 4 --steps 60 --frames 3 --no-sidecars \
        --out "$O/$name/f.png" "$@" > "$O/$name.log" 2>&1
    grep -E "^(tracers|frame|profile)" "$O/$name.log" | tail -4
    local foreign
    foreign=$( (pgrep -x tests; pgrep -x sillage-render; pgrep -x Sillage) | tr '\n' ' ')
    [ -n "$foreign" ] && echo "FOREIGN GPU work during $name: $foreign"
}

run 2m --particles 2000000 --dt 0.021
run 2m-prof --particles 2000000 --dt 0.021 --profile
run 8m-real --particles 8000000 --dt 0.0105
run 8m-real-prof --particles 8000000 --dt 0.0105 --profile
for theta in 0.9 1.1 1.3; do
    run "8m-tr$theta" --particles 8000000 --massive 2000000 --dt 0.021 --theta-tracers "$theta"
    run "8m-tr$theta-prof" --particles 8000000 --massive 2000000 --dt 0.021 --theta-tracers "$theta" --profile
done
run 4m-tr0.9 --particles 4000000 --massive 2000000 --dt 0.021
run 16m-tr0.9 --particles 16000000 --massive 2000000 --dt 0.021
echo "== done $(date '+%T')"
