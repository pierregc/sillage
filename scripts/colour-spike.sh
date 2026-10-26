#!/usr/bin/env bash
# Spike #118: today's colouring and every mapping on one scene, in one world.
# usage: colour-spike.sh <scene folder> <telescope|free> <out dir> [family]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/dev"
scene=$1 world=$2 out=$3 family=${4:-}
if [ "$world" = telescope ]; then
    base=observatory family=${family:-hubble-visible}
else
    base=nebula-soft family=${family:-nebula}
fi
blend=${BLEND:-0.75}
mappings=${MAPPINGS:-radius component population mix}

run() {
    local name=$1 mapping=$2
    shift 2
    if [ "$mapping" = baseline ]; then
        env -u SILLAGE_COLOURS DYLD_LIBRARY_PATH="$BUILD" "$BUILD/sillage-render" colours "$scene" \
            --out "$out" --name "$name" --world "$world" --base "$base" --family "$family" "$@"
    else
        SILLAGE_COLOURS=$mapping SILLAGE_COLOUR_WORLD=$world SILLAGE_COLOUR_FAMILY=$family \
            SILLAGE_COLOUR_SET=${SET:-hubble-visible} SILLAGE_COLOUR_BLEND=$blend \
            DYLD_LIBRARY_PATH="$BUILD" "$BUILD/sillage-render" colours "$scene" \
            --out "$out" --name "$name" --world "$world" --base "$base" --family "$family" "$@"
    fi
}

clip=${CLIP---clip}
[ -n "${SKIP_BASELINE:-}" ] || run baseline baseline $clip
[ -n "${SKIP_BASELINE:-}" ] || run fixed fixed
for mapping in $mappings; do
    run "${PREFIX:-}$mapping" "$mapping" $clip
done
