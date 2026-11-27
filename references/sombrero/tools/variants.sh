#!/usr/bin/env bash
# variants.sh <scene> <tag> <base look> <key=value,...> [flight]: one plain still at 260 Myr (and a flight key
# with "flight") in a copy of the look with those fields of "look" changed (or exposure.median/top)
C="${SOMBRERO:-$HOME/claude-workspace/sombrero}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
s="$1"; tag="$2"; base="$3"; set_="$4"; mkdir -p "$C/looks/v" "$C/out/v"
L="$C/looks/v/$tag.look.json"
python3 - "$base" "$L" "$set_" "$tag" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["name"] = sys.argv[4]
for kv in filter(None, sys.argv[3].split(",")):
    k, v = kv.split("=")
    if k == "exposure": d.pop("exposure", None)
    elif k.startswith("exposure."): d["exposure"][k[9:]] = float(v)
    else: d["look"][k] = float(v)
json.dump(d, open(sys.argv[2], "w"), indent=1)
PY
fr=$(python3 -c "
import json;c=json.load(open('$s/clip.json'))['story'];a,b=c['startMyr'],c['endMyr'];print(round((260-a)/(b-a)*c['endFrame']))")
d=$(mktemp -d)
"$W/scripts/gpu-lock.sh" run "sombrero-v-$tag" "$C/sr.sh" export "$s" --look "$L" --preset 1080p --stills "$d" --still-frames "$fr" --out "$d/v.mp4" > "$C/logs/v-$tag.log" 2>&1 || exit 1
D=$("$C/sr.sh" flight "$s" --at 200,300 --look "$L" 2>&1 | grep -o '[0-9.]* kpc from its aim' | head -1 | cut -d' ' -f1)
fov=$(python3 -c "import json;print(json.load(open('$L'))['look'].get('fieldOfView',0.6))")
python3 "$T/tiles.py" "$d"/*.png "$C/out/v/plain-$tag.png" "$(python3 -c "import math;print(2*$D*math.tan($fov/2)*16/9)")"
if [ "$5" = flight ]; then
  F="$C/looks/v/$tag-flight.look.json"; python3 -c "
import json;d=json.load(open('$L'));d.pop('camera',None);d['look'].pop('fieldOfView',None);json.dump(d,open('$F','w'))"
  "$W/scripts/gpu-lock.sh" run "sombrero-vf-$tag" "$T/stills.sh" "$s" "$d/f" "$F" 260,261 > "$C/logs/vf-$tag.log" 2>&1
  python3 "$T/tiles.py" "$d"/f/key-00*.png "$C/out/v/flight-$tag.png" 22.1
fi
rm -rf "$d"
