#!/usr/bin/env bash
# photokey.sh <scene folder> <match name> <look> <out png> [myr]: a still of the take from the match's view,
# cropped to the wide panel (8:9), 1080 px tall
T="$(cd "$(dirname "$0")" && pwd)"; s="$(cd "$1" && pwd)"; name="$2"; look="$3"; out="$4"; myr="${5:-}"
SR="${SR:-$HOME/claude-workspace/antennae/tools/sr.sh}"
mkdir -p "$s/flights"
python3 - "$s" "$T/view2key.py" "$name" "$myr" <<'PY'
import json, subprocess, sys
s, v2k, name, myr = sys.argv[1:5]
k = json.loads(subprocess.check_output(["python3", v2k, f"{s}/match/{name}.json", "0.15", "0"] + ([myr] if myr else [])))
k2 = dict(k); k2["at"] = 1.0
json.dump({"version": 1, "keys": [k, k2]}, open(f"{s}/flights/photo.flight.json", "w"))
PY
d=$(mktemp -d)
"$SR" export "$s" --look "$look" --flight photo --preset 1080p --flight-keys "$d" > "$d/log" 2>&1 || { cat "$d/log" >&2; exit 1; }
python3 - "$d"/key-00-*.png "$out" <<'PY'
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB"); w, h = im.size; cw = round(h * 256 / 288)
im.crop(((w - cw) // 2, 0, (w - cw) // 2 + cw, h)).save(sys.argv[2])
PY
rm -rf "$d"
