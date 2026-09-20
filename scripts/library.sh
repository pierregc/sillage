#!/usr/bin/env bash
# Nightly batch of generated scenes, one per iteration, each reproducible from its seed alone.
# Meant to be left alone: a scene that fails is recorded and the night carries on.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A take is six bytes a particle a frame, so it is two thousand megabytes a scene against
# eighty for the video alone. The seed reproduces the scene exactly, so triage does not need
# one: takes are opt in, for the scenes already known to be worth re-rendering.
MB_PER_SCENE=80         # video and curves only; --takes raises it
MB_PER_TAKE=2000
MINUTES_PER_SCENE=9    # rough, and only used for the plan
SETTLE=400              # steps before the first frame, so a scene opens settled
FRAMES=900              # 30 s at 30 fps
FPS=30

hours=12
scenes=0                # 0 means only --hours stops the run
particles=700000
width=1600
height=900
out=""
base_seed=""
takes=0

usage() {
    echo "usage: ${BASH_SOURCE[0]} [--hours H] [--scenes N] [--particles N] [--vertical]"
    echo "       [--takes] [--base-seed N] [--out DIR]"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --hours)     hours="$2"; shift 2 ;;
        --scenes)    scenes="$2"; shift 2 ;;
        --particles) particles="$2"; shift 2 ;;
        --base-seed) base_seed="$2"; shift 2 ;;
        --out)       out="$2"; shift 2 ;;
        --vertical)  width=1080; height=1920; shift ;;
        --takes)     takes=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *)           usage >&2; exit 2 ;;
    esac
done

# The date is the base seed unless one is given, so rerunning the same night reproduces it.
[ -n "$base_seed" ] || base_seed="$(date +%Y%m%d)"
[ -n "$out" ] || out="$ROOT/library/$(date +%Y-%m-%d)"

mkdir -p "$out"
log="$out/library.log"
index="$out/index.csv"

deadline=$(awk -v h="$hours" 'BEGIN { printf "%d", h * 3600 }')
planned=$(awk -v h="$hours" -v m="$MINUTES_PER_SCENE" 'BEGIN { printf "%d", h * 60 / m }')
if [ "$scenes" -gt 0 ] && [ "$scenes" -lt "$planned" ]; then planned="$scenes"; fi
if [ "$planned" -lt 1 ]; then planned=1; fi

note() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"; }
bytes() { if [ -f "$1" ]; then stat -f%z "$1"; else echo 0; fi; }

# A deterministic sequence rather than $RANDOM: the night has to be reproducible, and the
# seeds have to be far apart so neighbouring scenes do not look alike.
seed_for() { echo $(( (base_seed * 1000003 + $1 * 2654435761) % 2147483647 )); }

needed=$(( planned * MB_PER_SCENE ))
free=$(( $(df -Pk "$out" | awk 'NR == 2 { print $4 }') / 1024 ))
echo "$planned scenes, ~$(( planned * MINUTES_PER_SCENE / 60 )) h, ${width}x${height}, $particles particles"
echo "seeds from $base_seed, into $out"
echo "disk: ${needed} MB wanted, ${free} MB free"
if [ "$free" -lt "$needed" ]; then
    echo "not enough disk for the plan; free space or lower --scenes/--hours" >&2
    exit 1
fi

if [ ! -f "$index" ]; then
    echo "id,seed,tempo,galaxies,particles,width,height,frames,fps,wall_seconds,video_bytes,take_bytes,status" >"$index"
fi
cat >"$out/README.txt" <<'TXT'
Scenes generated overnight by scripts/library.sh.

The videos are SILENT on purpose. They are scored by hand afterwards.

Any scene can be reproduced exactly from the seed in index.csv, at any size or particle
count, or replayed from its .sillage take without simulating it again:

    ./scripts/dev.sh render --preset contemplation --director --seed <seed> ...
    ./scripts/dev.sh render --take <id>.sillage ...

index.html is the contact sheet: python3 scripts/library-index.py <this directory>
TXT

# nohup already ignores it, but the script must also survive being started from a terminal
# that is later closed.
trap '' HUP
trap 'note "interrupted"; echo interrupted; exit 130' INT TERM

if [ "$takes" -eq 1 ]; then MB_PER_SCENE=$(( MB_PER_SCENE + MB_PER_TAKE )); fi

note "start: plan $planned scenes, ${width}x${height}, $particles particles, base seed $base_seed"
SECONDS=0
n=0
done_count=0
failed_count=0
while :; do
    n=$(( n + 1 ))
    if [ "$scenes" -gt 0 ] && [ "$n" -gt "$scenes" ]; then break; fi
    if [ "$SECONDS" -ge "$deadline" ]; then note "out of time after ${SECONDS}s"; break; fi

    id="$(printf 'scene-%04d' "$n")"
    seed="$(seed_for "$n")"
    if [ -f "$out/$id.mov" ]; then note "$id exists, skipped"; continue; fi

    # Three tempos, chosen by the seed so the night stays reproducible. A clip covering only
    # a couple of hundred megayears shows two specks drifting; one covering a gigayear and a
    # half shows a whole merger and what it settles into. Both are worth having, and a library
    # of one tempo is a library that looks the same all the way down.
    # Eight profiles, cycled by scene number rather than drawn from the seed: seeds advance by
    # a constant, so a modulo of them comes out in long runs of the same thing. Every window of
    # eight scenes holds the whole range.
    #
    # The two ends are the point. Measured at 700k particles, a step covers 0.0325 Myr per
    # unit of dt_scale, so a thirty second clip crosses `29 * dt_scale * steps_per_frame`
    # megayears: 59 for profile 0, a disk turning almost imperceptibly with the camera inside
    # it, and 2048 for profile 7, four galaxies falling together and settling, seen from
    # outside. Nothing here goes past a step scale of 10, which is inside the range these runs
    # have been compared over.
    case $(( n % 8 )) in
        0) tempo=derive;   galaxies=1; haste=0.0; dt_scale=2;  steps_per_frame=1; immersed=1 ;;
        1) tempo=lent;     galaxies=2; haste=0.2; dt_scale=3;  steps_per_frame=2; immersed=1 ;;
        2) tempo=proche;   galaxies=2; haste=0.7; dt_scale=4;  steps_per_frame=3; immersed=1 ;;
        3) tempo=pose;     galaxies=2; haste=0.5; dt_scale=6;  steps_per_frame=4; immersed=0 ;;
        4) tempo=trio;     galaxies=3; haste=0.6; dt_scale=6;  steps_per_frame=5; immersed=0 ;;
        5) tempo=large;    galaxies=2; haste=0.9; dt_scale=8;  steps_per_frame=5; immersed=0 ;;
        6) tempo=quatuor;  galaxies=4; haste=0.8; dt_scale=8;  steps_per_frame=6; immersed=0 ;;
        *) tempo=ballet;   galaxies=4; haste=1.0; dt_scale=10; steps_per_frame=7; immersed=0 ;;
    esac
    immersed_flag=""
    [ "$immersed" -eq 1 ] && immersed_flag="--immersed"

    note "$id seed $seed tempo $tempo, $galaxies galaxies"
    start=$SECONDS
    rc=0
    take_flag=""
    [ "$takes" -eq 1 ] && take_flag="--take $out/$id.sillage"
    "$ROOT/scripts/dev.sh" render \
        --preset contemplation --seed "$seed" --director --solver barnes-hut \
        --particles "$particles" --settle "$SETTLE" --haste "$haste" --dt-scale "$dt_scale" \
        --galaxies "$galaxies" $immersed_flag \
        --steps "$(( FRAMES * steps_per_frame ))" --frames "$FRAMES" \
        --width "$width" --height "$height" --fps "$FPS" \
        --video "$out/$id.mov.partial" --curves "$out/$id.csv" $take_flag \
        >>"$log" 2>&1 || rc=$?
    wall=$(( SECONDS - start ))

    # Renamed only on success: a half written file must not look like a finished scene to the
    # skip-if-it-exists check on the next run.
    if [ "$rc" -eq 0 ] && [ -s "$out/$id.mov.partial" ]; then
        mv "$out/$id.mov.partial" "$out/$id.mov"
    else
        rm -f "$out/$id.mov.partial"
    fi

    video_bytes="$(bytes "$out/$id.mov")"
    take_bytes="$(bytes "$out/$id.sillage")"
    if [ "$rc" -ne 0 ]; then
        status="failed:$rc"
    elif [ "$video_bytes" -eq 0 ]; then
        status="failed:novideo"
        rm -f "$out/$id.mov"
    else
        status=ok
    fi
    if [ "$status" = ok ]; then done_count=$(( done_count + 1 )); else failed_count=$(( failed_count + 1 )); fi

    echo "$id,$seed,$tempo,$galaxies,$particles,$width,$height,$FRAMES,$FPS,$wall,$video_bytes,$take_bytes,$status" >>"$index"
    note "$id $status in ${wall}s, video $video_bytes B"
    echo "$id $tempo $status ${wall}s"
done

note "end: $done_count done, $failed_count failed, ${SECONDS}s"
echo "$done_count done, $failed_count failed, ${SECONDS}s"
