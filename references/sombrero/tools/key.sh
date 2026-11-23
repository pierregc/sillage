#!/usr/bin/env bash
# key.sh <scene> <tag> <base look> <field=value,...> [myr]: one flight key as Hubble frames it (6 degrees from
# edge on, rolled 5.6 degrees, core at Hubble's), cropped to 1024 x 606 at 21 kpc across, then measured.
# Fields: any of "look", exposure=0 to drop the measured exposure, palette.<part>=r:g:b for every galaxy.
C="${SOMBRERO:-$HOME/claude-workspace/sombrero}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
s="$1"; tag="$2"; base="$3"; set_="$4"; myr="${5:-260}"; mkdir -p "$C/looks/k" "$C/out/k" "$s/flights"
L="$C/looks/k/$tag.look.json"
python3 - "$base" "$L" "$set_" "$tag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["name"] = sys.argv[4]; d.pop("camera", None); d["look"].pop("fieldOfView", None)
for kv in filter(None, sys.argv[3].split(",")):
    k, v = kv.split("=")
    if k == "exposure": d.pop("exposure", None)
    elif k == "armStrength": d[k] = float(v)
    elif k.startswith("palette."):
        for p in d["palette"]: p[k[8:]] = [float(x) for x in v.split(":")]
    elif ":" in v: d["look"][k] = [float(x) for x in v.split(":")]
    else: d["look"][k] = float(v)
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
python3 - "$s/flights/hubble.flight.json" "$myr" "${ROLL:-0.0977}" "$(python3 -c "print(${FRAME:-21} * 1.08)")" <<'PY'
import json, math, sys
d, e = 80.0, math.radians(float(__import__("os").environ.get("ELEV", "6")))
eye = {"galaxy": 0, "offset": [0, round(-d * math.cos(e), 3), round(d * math.sin(e), 3)]}
key = {"eye": eye, "aim": {"galaxy": 0, "offset": [0, 0, 0]}, "fov": round(2 * math.atan(float(sys.argv[4]) / (1024 / 606) / 2 / d), 4), "roll": float(sys.argv[3]) if float(__import__("os").environ.get("ELEV", "6")) < 80 else 0.0}
m = float(sys.argv[2])
f = {"version": 1}
ds = float(__import__("os").environ.get("DUSTSLABS", "0"))
if ds > 0: f["inside"] = {"dustSlabs": ds}
f["keys"] = [dict(key, at=0, myr=m), dict(key, at=1, myr=m + float(__import__("os").environ.get("DM", "1")))]
json.dump(f, open(sys.argv[1], "w"), indent=1)
PY
d=$(mktemp -d)
"$W/scripts/gpu-lock.sh" run "sombrero-key-$tag" "${SR:-$C/sr.sh}" export "$s" --look "$L" --flight hubble --preset "${PRESET:-1080p}" --flight-keys "$d" > "$C/logs/k-$tag.log" 2>&1 || { tail -3 "$C/logs/k-$tag.log"; exit 1; }
CORE=504,312 python3 "$T/tiles.py" "$d"/key-00*.png "$C/out/k/$tag.png" "$(python3 -c "print(${FRAME:-21} * 1.08 * 1920 / 1080 * 606 / 1024)")"
[ -n "$OUTW" ] && CORE=504,312 python3 "$T/tiles.py" "$d"/key-00*.png "$C/out/k/$tag-$OUTW.png" "$(python3 -c "print(${FRAME:-21} * 1.08 * 1920 / 1080 * 606 / 1024)")"
rm -rf "$d"
