#!/usr/bin/env bash
# The measure of #425 on a GPU box: frames from inside a disk of scene-0031 at 8 M on 12 M, in 4K,
# their point stars walked over their whole squares (before) and along their streaks' bands
# (after), with --profile, and the two sets of PNGs compared to the byte: two frames of a video at
# 3 a second, each four renders over its shutter, as #424 timed them (a still has no shutter, so
# no streaks). The take is the fixture's clip, two frames at 13 Myr, a few minutes of steps on a
# GPU; the flight is frozen there.
#
#   scripts/gpu-box.sh run scripts/spikes/point-stars-timing.sh
#
# PARTICLES, PRESET and START make it small enough for the CPU target, to check the script:
#   PARTICLES=20000 PRESET=1080p scripts/spikes/point-stars-timing.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PARTICLES="${PARTICLES:-8000000}"
FRAMES="${FRAMES:-2}"
PRESET="${PRESET:-4k}"
START="${START:-3.8}"
WORK="${WORK:-$ROOT/.build/point-stars-timing}"
scene="$WORK/scene-0031"
tool="$ROOT/.build/linux/sillage-cuda"
export LD_LIBRARY_PATH="$ROOT/.build/linux${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# The take pass refuses an engine that was not checked; a box starts without .build.
[ -f .build/linux/engine-check.json ] && [ -z "${REBUILD:-}" ] || scripts/linux.sh tool engine-check
mkdir -p "$WORK"
if [ ! -f "$scene/take.sillage" ]; then
    rm -rf "$scene"
    cp -R Tests/Fixtures/engines/scene "$scene"
    started=$SECONDS
    "$tool" hires "$scene" --particles "$PARTICLES" --dt-scale 3.5 --frames "$FRAMES" \
        --take-interval 1 --dt-schedule off --checkpoint-every 0
    echo "TIMING take: $PARTICLES massive, $FRAMES frames in $((SECONDS - started)) s"
fi

for way in before after; do
    rm -rf "${WORK:?}/$way" "$WORK/$way.mp4" "$WORK/.$way.mp4.segments"
    whole=()
    [ "$way" = before ] && whole=(--whole-squares)
    started=$SECONDS
    "$tool" export "$scene" --look Tests/Fixtures/engines/frames/webb.look.json \
        --flight scripts/spikes/point-stars-timing.flight.json --preset "$PRESET" --no-overlay \
        --fps 3 --start "$START" --duration 0.67 --stills "$WORK/$way" --still-frames 0,1 \
        --out "$WORK/$way.mp4" --profile "${whole[@]}"
    echo "TIMING $way: $((SECONDS - started)) s for two frames from $START s"
done

same=yes
for picture in "$WORK"/before/*.png; do
    cmp -s "$picture" "$WORK/after/$(basename "$picture")" || { same=no; echo "TIMING differs: $(basename "$picture")"; }
done
ls "$WORK"/after/*.png > /dev/null || same=no
echo "TIMING the same bytes: $same"
[ "$same" = yes ]
