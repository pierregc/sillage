#!/usr/bin/env bash
# Exploration batch: free scenes explored one after another, several at once, each landing in
# its own scene folder the moment it is finished. Resumable, and reproducible from the batch
# seed alone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/dev"
LOOK="$ROOT/looks/raw.look.json"

# Both measured by --benchmark on an M4 Max, see "Exploration batches" in the README; run it
# again on another machine. SILLAGE_JOBS overrides the first for every batch, --jobs for one.
DEFAULT_JOBS=4
# Wall clock per particle per step, per scene finished, with DEFAULT_JOBS running at once, at
# the sizes a budget lands on: 101 at 50 000 a galaxy, 126 at 400 000, where the GPU is full.
NS_PER_PARTICLE_STEP=126
SECONDS_PER_SCENE=4     # starting up, and the steps before the first frame are counted apart
# explore follows a story past the planned span until it is over (#123): on the 2026-10-25
# night this much more of the span on average, which the budget and the disk count in.
STORY_EXTRA=__EXTRA__
MB_PER_SCENE=__MB__         # a raw preview at 960x540 is 5 to 25 MB for the planned span
MAX_FAILURES=5
# What --hours and --scenes choose the particle count from, and how much of the time it plans
# to fill: rejected draws, the scenes in flight at the deadline and the estimate's own error
# take the rest.
PER_GALAXY_CANDIDATES="50000 75000 100000 150000 200000 250000 300000 350000 400000 500000 750000 1000000"
BUDGET_FILL=0.85
BUDGET_SAMPLE=16

usage() {
    echo "usage: ${BASH_SOURCE[0]} [--scenes N] [--hours H] [--jobs N] [--seed S] [--out DIR]"
    echo "       [--per-galaxy N] [--span MYR | --steps N] [--dt-scale X] [--width W] [--height H]"
    echo "       [--frames N] [--fps N] [--settle N] [--plan] [-- explore options...]"
    echo "       ${BASH_SOURCE[0]} --benchmark [--scenes N] [--seed S] [--per-galaxy N] [--span MYR]"
}

scenes=""
hours=""
jobs="${SILLAGE_JOBS:-$DEFAULT_JOBS}"
out=""
benchmark=0
plan=0
build=1
quiet=0
# The batch's own settings, recorded in batch.conf on the first run and read back on the next,
# so a resumed batch draws and renders exactly as it started.
keys="seed per_galaxy span steps dt_scale width height frames fps settle extra"
seed="" per_galaxy="" span="" steps="" dt_scale="" width="" height="" frames="" fps="" settle="" extra=""

while [ $# -gt 0 ]; do
    case "$1" in
        --scenes)     scenes="$2"; shift 2 ;;
        --hours)      hours="$2"; shift 2 ;;
        --jobs)       jobs="$2"; shift 2 ;;
        --seed)       seed="$2"; shift 2 ;;
        --out)        out="$2"; shift 2 ;;
        --per-galaxy) per_galaxy="$2"; shift 2 ;;
        --span)       span="$2"; shift 2 ;;
        --steps)      steps="$2"; shift 2 ;;
        --dt-scale)   dt_scale="$2"; shift 2 ;;
        --width)      width="$2"; shift 2 ;;
        --height)     height="$2"; shift 2 ;;
        --frames)     frames="$2"; shift 2 ;;
        --fps)        fps="$2"; shift 2 ;;
        --settle)     settle="$2"; shift 2 ;;
        --benchmark)  benchmark=1; shift ;;
        --no-build)   build=0; shift ;;
        --quiet)      quiet=1; shift ;;
        --plan)       plan=1; shift ;;
        --help|-h)    usage; exit 0 ;;
        --)           shift; extra="$*"; break ;;
        *)            usage >&2; exit 2 ;;
    esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }
render() { DYLD_LIBRARY_PATH="$BIN" "$BIN/sillage-render" "$@"; }

# The galaxy count and the time step of scene `n` at `particles` in all, from the generator
# alone: the batch is replayed up to the index without a particle, in a few milliseconds.
probe() {
    # shellcheck disable=SC2086
    render --preset free --seed "$seed" --index "$1" --solver barnes-hut --particles "$2" \
        --dt-scale "$dt_scale" --check-only $extra 2>&1 | awk '
            /^draw / { sub(/^[^:]*: /, ""); galaxies = split($0, f, ", ") }
            /^check / { for (i = 2; i < NF; i++) if ($(i + 1) == "Myr," && $(i - 1) == "step") step = $i }
            END { if (galaxies && step) print galaxies, step }' || true
}

# Steps enough to cover the span, a whole number of them per frame. A step is shorter the more
# particles a disk holds, so a fixed count would show less of the encounter at a larger size.
steps_for() {
    awk -v span="$span" -v step="$1" -v frames="$frames" '
        BEGIN { per = int(span / step / frames); if (per * frames * step < span) per++
                print (per < 1 ? 1 : per) * frames }'
}

# The largest count a galaxy can have for the batch to fit in its hours, judged on the first
# scenes of the batch at each candidate count.
budget() {
    local n pg probed galaxies clip total best=""
    for pg in $PER_GALAXY_CANDIDATES; do
        total=0
        for n in $(seq 1 "$BUDGET_SAMPLE"); do
            galaxies="$(probe "$n" "$pg" | cut -d' ' -f1)"
            [ -n "$galaxies" ] || continue
            probed="$(probe "$n" $(( galaxies * pg )))"
            clip="${steps:-$(steps_for "${probed#* }")}"
            total=$(awk -v t="$total" -v p=$(( galaxies * pg )) -v s="$settle" -v k="$clip" \
                -v x="$STORY_EXTRA" -v c="$NS_PER_PARTICLE_STEP" -v o="$SECONDS_PER_SCENE" \
                'BEGIN { print t + o + p * (s + k * (1 + x)) * c / 1e9 }')
        done
        if awk -v t="$total" -v k="$BUDGET_SAMPLE" -v n="$scenes" -v h="$hours" -v f="$BUDGET_FILL" \
            'BEGIN { exit !(n * t / k <= h * 3600 * f) }'
        then
            best=$pg
            say "$(awk -v t="$total" -v k="$BUDGET_SAMPLE" -v pg="$pg" \
                'BEGIN { printf "budget: %d a galaxy fits, about %.0f s a scene", pg, t / k }')" >&2
        else
            break
        fi
    done
    echo "${best:-${PER_GALAXY_CANDIDATES%% *}}"
}

defaults() {
    [ -n "$seed" ] || seed="$(date +%Y%m%d)"
    [ -n "$width" ] || width=960
    [ -n "$height" ] || height=540
    [ -n "$frames" ] || frames=900
    [ -n "$fps" ] || fps=30
    [ -n "$settle" ] || settle=400
    # The exploration clip #13 measured: a step three and a half times the recommended one,
    # which settles over the first eighty megayears, and seven hundred more for the passages,
    # the tails and what they fall back into. The clip of #41, 900 steps at the generator's own
    # scale, covers forty.
    [ -n "$dt_scale" ] || dt_scale=3.5
    [ -n "$steps" ] || [ -n "$span" ] || span=700
    if [ -z "$per_galaxy" ] && [ -n "$scenes" ] && [ -n "$hours" ]; then
        per_galaxy="$(budget)"
    fi
    [ -n "$per_galaxy" ] || per_galaxy=50000
}

if [ "$build" -eq 1 ]; then
    # Built once, so a batch runs one binary from its first scene to its last.
    "$ROOT/scripts/dev.sh" build >/dev/null
fi

# 1, 2, 3 and 4 scenes at once over the same scenes of the same batch, each in a fresh folder.
# The figure that matters is the wall clock per scene finished, not how long any one scene
# took: running several at once makes each one slower and the batch faster.
if [ "$benchmark" -eq 1 ]; then
    [ -n "$scenes" ] || scenes=12
    defaults
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/sillage-benchmark.XXXXXX")"
    trap 'rm -rf "$scratch"' EXIT
    echo "benchmark: scenes 1 to $scenes of batch $seed, $per_galaxy a galaxy," \
        "${span:+$span Myr}${steps:+$steps steps}, ${width}x${height}"
    echo "jobs  wall s  s per scene  mean scene s  ns per particle step"
    for count in 1 2 3 4; do
        start=$(date +%s)
        "${BASH_SOURCE[0]}" --no-build --quiet --out "$scratch/jobs-$count" --scenes "$scenes" \
            --jobs "$count" --seed "$seed" --per-galaxy "$per_galaxy" --dt-scale "$dt_scale" \
            ${span:+--span "$span"} \
            ${steps:+--steps "$steps"} --width "$width" --height "$height" --frames "$frames" \
            --fps "$fps" --settle "$settle"
        wall=$(( $(date +%s) - start ))
        awk -F, -v j="$count" -v w="$wall" -v n="$scenes" -v o="$SECONDS_PER_SCENE" '
            $NF == "ok" { mean += $12; work += $5 * ($10 + $11) }
            END { printf "%4d  %6d  %11.1f  %12.1f  %20.1f\n", j, w, w / n, mean / n, (w - n * o) / work * 1e9 }' \
            "$scratch/jobs-$count/index.csv"
        rm -rf "${scratch:?}/jobs-$count"
    done
    exit 0
fi

[ -n "$out" ] || out="$ROOT/library/$(date +%Y-%m-%d)"
if [ "$plan" -eq 1 ]; then
    [ -f "$out/batch.conf" ] || defaults
    for key in $keys; do [ -z "${!key}" ] || echo "$key=${!key}"; done
    exit 0
fi
mkdir -p "$out/.logs"
conf="$out/batch.conf"
if [ -f "$conf" ]; then
    for key in $keys; do
        recorded="$(awk -v k="$key" 'index($0, k "=") == 1 { print substr($0, length(k) + 2) }' "$conf")"
        given="${!key}"
        if [ -n "$given" ] && [ "$given" != "$recorded" ]; then
            echo "$out was started with $key=$recorded; a batch keeps its settings" >&2
            exit 2
        fi
        printf -v "$key" '%s' "$recorded"
    done
else
    defaults
    for key in $keys; do echo "$key=${!key}"; done >"$conf"
fi

# A folder of the old flat layout holds scene-0001.mov where this writes scene-0001/, and the
# library would show both under one name.
if compgen -G "$out/*.mov" >/dev/null; then
    echo "$out holds a flat batch from scripts/library.sh; pick another --out" >&2
    exit 2
fi

index="$out/index.csv"
log="$out/batch.log"
HEADER="id,batch_seed,index,galaxies,particles,width,height,frames,fps,settle,steps,wall_seconds,video_bytes,score,rank,status"
[ -f "$index" ] || echo "$HEADER" >"$index"
# A batch started before #45 keeps the columns it started with.
scored=0
head -n 1 "$index" | grep -q ',score,rank,' && scored=1
first_new_row=$(( $(wc -l <"$index") + 1 ))
# A rejection is decided by the seed and the index alone, so a resumed batch need not ask again.
rejected=" $(awk -F, '$NF == "rejected" { print $1 }' "$index" | tr '\n' ' ') "

note() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$log"; }
finished() { find "$out" -mindepth 1 -maxdepth 1 -type d -name 'scene-*' | wc -l | tr -d ' '; }

free_mb=$(( $(df -Pk "$out" | awk 'NR == 2 { print $4 }') / 1024 ))
if [ -n "$scenes" ] && [ "$free_mb" -lt $(( scenes * MB_PER_SCENE )) ]; then
    echo "not enough disk: $(( scenes * MB_PER_SCENE )) MB wanted, $free_mb MB free" >&2
    exit 1
fi

# One scene, start to finish, in a hidden folder that is renamed into place only once the
# clip, the thumbnail and the curves are all written: the library skips hidden folders, so it
# never shows a scene halfway, and on the next run a folder that exists is a scene that is done.
explore_scene() {
    local n=$1 id stage scene_log galaxies particles=0 clip="" probed rc=0 start status video_bytes=0
    local frames_run=""
    local score=""
    id="$(printf 'scene-%04d' "$n")"
    stage="$out/.$id"
    scene_log="$out/.logs/$id.log"
    rm -rf "$stage"
    start=$(date +%s)

    # The particle count follows from the galaxy count, and the steps from the time step at
    # that particle count.
    galaxies="$(probe "$n" "$per_galaxy" | cut -d' ' -f1)"
    if [ -n "$galaxies" ]; then
        particles=$(( galaxies * per_galaxy ))
        probed="$(probe "$n" "$particles")"
        [ -z "$probed" ] || clip="${steps:-$(steps_for "${probed#* }")}"
    fi
    if [ -z "$clip" ]; then
        status="failed:probe"
        note "$id: the generator gave no draw or no step"
    else
        # shellcheck disable=SC2086
        render explore "$stage" --seed "$seed" --index "$n" --particles "$particles" \
            --width "$width" --height "$height" --frames "$frames" --fps "$fps" \
            --steps "$clip" --settle "$settle" --dt-scale "$dt_scale" --look "$LOOK" $extra \
            >"$scene_log" 2>&1 || rc=$?
        if [ "$rc" -eq 0 ] && [ -s "$stage/preview.mov" ] && [ -s "$stage/thumbnail.png" ]; then
            score="$(python3 "$ROOT/scripts/interest.py" "$stage" 2>>"$scene_log" | awk 'NR == 1 { print $1 }')" || true
            mv "$stage" "$out/$id"
            status=ok
            video_bytes=$(stat -f%z "$out/$id/preview.mov")
            # What ran, which is longer than planned when the story went on.
            read -r frames_run clip < <(python3 -c 'import json, sys
c = json.load(open(sys.argv[1])); print(c["frames"], c["steps"])' "$out/$id/clip.json")
        elif [ "$rc" -eq 3 ]; then
            status=rejected
            note "$id rejected: $(grep -m1 '^rejected' "$scene_log" | sed 's/^rejected *//')"
        else
            status="failed:$rc"
            note "$id failed, see .logs/$id.log"
        fi
    fi
    rm -rf "$stage"
    local wall=$(( $(date +%s) - start ))
    # One short line in a single write, so rows from scenes finishing together do not mix.
    local columns="$video_bytes"
    [ "$scored" -eq 0 ] || columns="$video_bytes,$score,"
    echo "$id,$seed,$n,$galaxies,$particles,$width,$height,${frames_run:-$frames},$fps,$settle,$clip,$wall,$columns,$status" >>"$index"
    # Through the binary, which writes one whole line however many scenes finish together.
    local event=(--scene "$id" --status "${status%%:*}" --seconds "$wall")
    case "$score" in "" | *[!0-9.]*) ;; *) event+=(--score "$score") ;; esac
    render event "$out" explore.scene "${event[@]}" 2>>"$log" || true
    case "$status" in
        failed*) render event "$out" error --scene "$id" --stage explore --message "$status" \
            --log ".logs/$id.log" 2>>"$log" || true ;;
    esac
    note "$id $status in ${wall}s, $galaxies galaxies, $particles particles, $clip steps"
    say "$id $status ${wall}s, $galaxies galaxies, $particles particles, $clip steps"
}

trap '' HUP
# Takes the scenes in flight down with the batch; their hidden folders are cleared on resume.
# TERM rather than INT, which a scene started in the background ignores.
trap 'trap - INT TERM; note "interrupted"; echo interrupted; kill -TERM 0' INT TERM

# Left unbounded on both counts, a batch runs for a night.
[ -n "$scenes" ] || [ -n "$hours" ] || hours=12
deadline=""
[ -z "$hours" ] || deadline=$(( $(date +%s) + $(awk -v h="$hours" 'BEGIN { printf "%d", h * 3600 }') ))
say "batch $seed into $out, $jobs at once, $per_galaxy particles a galaxy," \
    "${span:+$span Myr}${steps:+$steps steps}, ${width}x${height}"
note "start: seed $seed, $jobs at once, $per_galaxy a galaxy, scenes ${scenes:-unbounded}, hours ${hours:-unbounded}"
started=$(date +%s)
n=0
while :; do
    done_count=$(finished)
    running=$(jobs -pr | wc -l | tr -d ' ')
    if [ -n "$scenes" ] && [ "$done_count" -ge "$scenes" ]; then break; fi
    if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ]; then note "out of time"; break; fi
    # A failure is the machine or the code rather than the scene, and the next scene will
    # most likely fail the same way.
    if [ "$(tail -n "+$first_new_row" "$index" | grep -c ',failed')" -ge "$MAX_FAILURES" ]; then
        note "stopped after $MAX_FAILURES failures"
        echo "stopped after $MAX_FAILURES failures, see $out/.logs" >&2
        break
    fi
    # Full, or enough scenes in flight to finish the batch: one of them may yet be rejected.
    if [ "$running" -ge "$jobs" ] || { [ -n "$scenes" ] && [ $(( done_count + running )) -ge "$scenes" ]; }; then
        sleep 0.5
        continue
    fi
    n=$(( n + 1 ))
    id="$(printf 'scene-%04d' "$n")"
    [ ! -d "$out/$id" ] || continue
    case "$rejected" in *" $id "*) continue ;; esac
    explore_scene "$n" &
done
wait
# Ranked once every scene is in, the only moment nothing else writes the index.
python3 "$ROOT/scripts/interest.py" "$out" >/dev/null 2>>"$log" || note "scoring failed"

elapsed=$(( $(date +%s) - started ))
tail -n "+$first_new_row" "$index" | awk -F, -v e="$elapsed" -v j="$jobs" '
    $NF == "ok" { ok++; wall += $12 }
    $NF == "rejected" { rejected++ }
    $NF ~ /^failed/ { failed++ }
    END {
        line = sprintf("%d done, %d rejected, %d failed in %d s", ok, rejected, failed, e)
        if (ok) line = line sprintf(": %.1f s per scene, each %.1f s on average, %d at once", e / ok, wall / ok, j)
        print line
    }' | tee -a "$log"
