#!/usr/bin/env bash
# preview.sh <work dir> <name> [key=value ...]: one scene of a sweep: make_scene.py (Karl), explore at 200 k as a
# whole story, hires at $SIZE with sticky gas, then (in the background, off the GPU) the matches and a row in
# <work>/sweep.csv; the take is deleted after unless $KEEP_TAKE is set. Needs $SR, the sillage-render to run (a script or the binary); holds $GPU_LOCK for the GPU stages.
T="$(cd "$(dirname "$0")" && pwd)"; W="$(cd "$1" && pwd)"; n="$2"; shift 2; s="$W/lib/$n"
SIZE="${SIZE:-200000}"; LOCK="${GPU_LOCK:-$HOME/claude-workspace/.gpu-lock}"; SEED="${SEED:-}"
gpu() {  # gpu <log> <command...>
  until mkdir "$LOCK" 2>/dev/null; do sleep 5; done
  echo "antennae sweep $n pid $$ $(date -u +%FT%T)" > "$LOCK/owner"
  "${@:2}" > "$W/logs/$1.log" 2>&1; local rc=$?; rm -rf "$LOCK"; return $rc
}
mkdir -p "$W/logs"
[ -f "$s/scene.json" ] || python3 "$T/make_scene.py" "$s" karl "$@" ${SEED:+seed=$SEED} || exit 1
[ -f "$s/clip.json" ] || gpu "explore-$n" "$SR" explore "$s" --particles 200000 --width 960 --height 540 \
    --frames 900 --fps 30 --steps 1800 --settle 375 --dt-scale 7 --solver barnes-hut --story-cap 3000 --no-check || { echo "$n,failed,explore" >> "$W/sweep.csv"; exit 1; }
[ -f "$s/curves-hires.csv" ] || gpu "hires-$n" "$SR" hires "$s" --particles "$SIZE" --sticky-gas on --no-video --checkpoint-every 0 || { echo "$n,failed,hires" >> "$W/sweep.csv"; exit 1; }
( "$T/match.sh" "$W" "$s" && python3 "$T/row.py" "$W" "$s" "$@" >> "$W/sweep.csv"; [ -n "${KEEP_TAKE:-}" ] || rm -f "$s/take.sillage" ) > "$W/logs/match-$n.log" 2>&1 &
