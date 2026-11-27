#!/usr/bin/env bash
# film_stills.sh <scene> <look> <out> [myr]: the film's freeze frame on Hubble's axis at 3840 x 2160 and
# 6240 x 3744 (6144 px per 26.5 kpc), beside Hubble (cut and pair), its close-ups and texture scores,
# then the six shots of ../film-six.flight.json as 4K stills and a contact sheet (#506).
# SR: the sillage-render wrapper (default ~/claude-workspace/sombrero/sr.sh). PY: Python with numpy, scipy, pillow.
set -e
S="$1"; L="$2"; O="$3"; M="${4:-12}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
SR="${SR:-$HOME/claude-workspace/sombrero/sr.sh}"; PY="${PY:-python3}"
mkdir -p "$O/work"
python3 - "$O/work" "$M" <<'PY'
import json, math, sys
d, e = 80.0, math.radians(6)
k = {"eye": {"galaxy": 0, "offset": [0, round(-d * math.cos(e), 3), round(d * math.sin(e), 3)]},
     "aim": {"galaxy": 0, "offset": [0, 0, 0]}, "roll": 0.10}
for name, h in (("freeze-4k", 26.5 * 2160 / 3840), ("freeze-6144", 26.5 / 6144 * 3744)):
    key = dict(k, fov=round(2 * math.atan(h / 2 / d), 5)); m = float(sys.argv[2])
    json.dump({"version": 1, "inside": {"dustSlabs": 1.2}, "keys": [dict(key, at=0, myr=m), dict(key, at=1, myr=m + 0.5)]},
              open(f"{sys.argv[1]}/{name}.flight.json", "w"), indent=1)
PY
draw() {  # draw <name> <flight> <size options...>
  local n="$1" f="$2"; shift 2; rm -rf "$O/work/$n"; mkdir -p "$O/work/$n"
  "$W/scripts/gpu-lock.sh" run "sombrero-$n" "$SR" export "$S" --look "$L" --flight "$f" --flight-keys "$O/work/$n" "$@" \
    > "$O/work/$n.log" 2>&1 || { tail -3 "$O/work/$n.log"; exit 1; }
}
draw freeze-4k "$O/work/freeze-4k.flight.json" --preset 4k --flight-at 0
draw freeze-6144 "$O/work/freeze-6144.flight.json" --width 6240 --height 3744 --flight-at 0
draw six "$T/../film-six.flight.json" --preset 4k
F4="$O/work/freeze-4k/key-00-000.00s.png"; F6="$O/work/freeze-6144/key-00-000.00s.png"
"$PY" "$T/film_split.py" split "$F4" "$O"
"$PY" "$T/film_split.py" framing "$F4" "$O/work/freeze-4k-hf.png"
"$PY" -c "from PIL import Image; Image.open('$F6').crop((96, 0, 6240, 3636)).save('$O/work/freeze-6144-hf.png')"
"$PY" "$T/closeup.py" "$O/01-freeze-closeup.jpg" "$O/work/freeze-6144-hf.png" --labels "Sillage, 6144 px render"
"$PY" "$T/closeup.py" "$O/01-freeze-closeup-film.jpg" "$O/work/freeze-4k-hf.png" --scale 3840 --labels "Sillage, film frame"
"$PY" "$T/texture.py" "$O/work/freeze-6144-hf.png" --grid 6144 --json "$O/work/texture-6144.json" | grep summary
"$PY" "$T/texture.py" "$O/work/freeze-4k-hf.png" --grid 3072 --json "$O/work/texture-4k-3072.json" | grep summary
names=(02-1-zenith 02-2-hubble-axis 02-3-low-flight-banked 02-4-inside-disk 02-5-near-core 02-6-wide)
labels=("1  zenith" "2  Hubble's axis (the freeze)" "3  low over the dust, banked" "4  inside the disk" "5  near the core" "6  wide")
args=(); i=0
for p in "$O"/work/six/key-*.png; do
  "$PY" -c "from PIL import Image; Image.open('$p').convert('RGB').save('$O/${names[$i]}.jpg', quality=92)"
  args+=("${labels[$i]}=$p"); i=$((i + 1))
done
"$PY" "$T/film_split.py" sheet "$O/02-six-shots.jpg" 1268 "${args[@]}"
echo "done: $O"
