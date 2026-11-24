#!/usr/bin/env bash
# stills.sh <scene folder> <out dir> [look] [myr,...]: the galaxy as Hubble sees it (6 degrees from edge on,
# 21 kpc across at the picture's aspect), one PNG a moment, drawn as flight keys (soft dust slabs)
s="$1"; out="$2"; look="${3:-photograph}"; at="${4:-200,260,340}"; T="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$s/flights" "$out"
python3 - "$s/flights/hubble.flight.json" "$at" <<'PY'
import json, math, sys
d, e = 80.0, math.radians(6)
eye = {"galaxy": 0, "offset": [0, round(-d * math.cos(e), 3), round(d * math.sin(e), 3)]}
aim = {"galaxy": 0, "offset": [0, 0, 0]}
fov = 2 * math.atan(21.0 / (1024 / 606) / 2 / d)
keys = [{"at": i, "myr": float(m), "eye": eye, "aim": aim, "fov": round(fov, 4)} for i, m in enumerate(sys.argv[2].split(","))]
json.dump({"version": 1, "keys": keys}, open(sys.argv[1], "w"), indent=1)
PY
d=$(mktemp -d)
"${SR:-$HOME/claude-workspace/sombrero/sr.sh}" export "$s" --look "$look" --flight hubble --preset 1080p --flight-keys "$d" || exit 1
for f in "$d"/key-*.png; do cp "$f" "$out/"; done; rm -rf "$d"
