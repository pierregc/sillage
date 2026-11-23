#!/usr/bin/env bash
# photokey.sh <scene folder> <look> <out png> [preset]: the matched frame in a look, framed like the picture
C="$HOME/claude-workspace/ngc2207"; s="$1"; look="$2"; out="$3"; preset="${4:-1080p}"
mkdir -p "$s/flights"
python3 - "$s" "$C/tools/view2key.py" <<'PY'
import json, subprocess, sys
s, v2k = sys.argv[1], sys.argv[2]
k = json.loads(subprocess.check_output(["python3", v2k, f"{s}/match/ngc2207.json"]))
k2 = dict(k); k2["at"] = 1.0
json.dump({"version": 1, "keys": [k, k2]}, open(f"{s}/flights/photo.flight.json", "w"))
PY
d=$(mktemp -d)
"$C/tools/sr.sh" export "$s" --look "$look" --flight photo --preset "$preset" --flight-keys "$d" > "$C/logs/photokey-$(basename "$s").log" 2>&1 || exit 1
cp "$d"/key-00-*.png "$out"; rm -rf "$d"
