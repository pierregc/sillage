#!/usr/bin/env bash
# match.sh <work dir> <scene folder>: the match on the wide panel (scale held, 102.5 kpc) from 20 Myr after the first
# pericentre to the merger, the view searched freely, and a free match over the whole take
T="$(cd "$(dirname "$0")" && pwd)"; W="$(cd "$1" && pwd)"; s="$(cd "$2" && pwd)"
read at within < <(python3 - "$s" "$T" <<'PY'
import sys
sys.path.insert(0, sys.argv[2]); from clock import clock
c = clock(sys.argv[1]); p = c["pericentres"][0]["myr"] + 20; m = c["merger_myr"] or c["end_myr"]
print(f"{(p + m) / 2:.1f} {max(m - p, 20) / 2:.1f}")
PY
)
"$SR" match "$s" "$W/ref/antennae.map.json" --kpc-across 102.5 --at "$at" --within "$within" --fresh || exit 1
"$SR" match "$s" "$W/ref/antennae-free.map.json" --kpc-across 102.5 --fresh
