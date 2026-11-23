#!/usr/bin/env bash
# key.sh <scene> <tag> <base look> <field=value,...> [myr]: one flight key as Hubble frames it (6 degrees from
# edge on, rolled 5.6 degrees, core at Hubble's), cropped to 1024 x 606 at 21 kpc across, then measured.
# Fields: any of "look", exposure=0 to drop the measured exposure, palette.<part>=r:g:b for every galaxy.
C="${SOMBRERO:-$HOME/claude-workspace/sombrero}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
s="$1"; tag="$2"; base="$3"; set_="$4"; myr="${5:-260}"; mkdir -p "$C/looks/k" "$C/out/k"
L="$C/looks/k/$tag.look.json"
python3 - "$base" "$L" "$set_" "$tag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["name"] = sys.argv[4]; d.pop("camera", None); d["look"].pop("fieldOfView", None)
for kv in filter(None, sys.argv[3].split(",")):
    k, v = kv.split("=")
    if k == "exposure": d.pop("exposure", None)
    elif k.startswith("palette."):
        for p in d["palette"]: p[k[8:]] = [float(x) for x in v.split(":")]
    elif ":" in v: d["look"][k] = [float(x) for x in v.split(":")]
    else: d["look"][k] = float(v)
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
python3 - "$s/flights/hubble.flight.json" "$myr" "${ROLL:-0.0977}" <<'PY'
import json, math, sys
d, e = 80.0, math.radians(6)
eye = {"galaxy": 0, "offset": [0, round(-d * math.cos(e), 3), round(d * math.sin(e), 3)]}
key = {"eye": eye, "aim": {"galaxy": 0, "offset": [0, 0, 0]}, "fov": round(2 * math.atan(21.0 / (1024 / 606) / 2 / d), 4), "roll": float(sys.argv[3])}
m = float(sys.argv[2])
json.dump({"version": 1, "keys": [dict(key, at=0, myr=m), dict(key, at=1, myr=m + 1)]}, open(sys.argv[1], "w"), indent=1)
PY
d=$(mktemp -d)
"$W/scripts/gpu-lock.sh" run "sombrero-key-$tag" "$C/sr.sh" export "$s" --look "$L" --flight hubble --preset 1080p --flight-keys "$d" > "$C/logs/k-$tag.log" 2>&1 || { tail -3 "$C/logs/k-$tag.log"; exit 1; }
CORE=504,312 python3 "$T/tiles.py" "$d"/key-00*.png "$C/out/k/$tag.png" 22.1; rm -rf "$d"
