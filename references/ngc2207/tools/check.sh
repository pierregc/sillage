#!/usr/bin/env bash
# check.sh <scene folder> [particles]: explore, a small hires and the match against the picture
C="$HOME/claude-workspace/ngc2207"; s="$1"; n=$(basename "$s")
"$C/tools/gpu.sh" "explore-$n" "$C/tools/sr.sh" explore "$s" --particles 200000 --width 960 --height 540 \
    --frames 900 --fps 30 --steps 1800 --settle 375 --dt-scale 7 --solver barnes-hut --story-cap 860 --no-check || exit 1
"$C/tools/gpu.sh" "hires-$n" "$C/tools/sr.sh" hires "$s" --particles "${2:-500000}" --sticky-gas on --no-video --checkpoint-every 0 || exit 1
