#!/usr/bin/env bash
# 4K stills of scene-0031 from each take, same director camera, same looks (#187).
#   stills.sh <out dir> <frames> <name=take>...
set -euo pipefail
OUT="$1"; FRAMES="$2"; shift 2
WT="/Users/pierregc/claude-workspace/sillage-wt-187"
B="$HOME/claude-workspace/tracers-187-out/bin"
S="$HOME/claude-workspace/sillage/library/2026-10-30-b/scene-0031"
M="$HOME/claude-workspace/tracers-187-out/mirror-0031"
mkdir -p "$M" "$OUT/looks"
for f in scene.json clip.json hires.json look.json curves-hires.csv; do ln -sf "$S/$f" "$M/$f"; done

python3 - "$S/look.json" "$OUT/looks" <<'EOF'
import json, sys
base = json.load(open(sys.argv[1]))
out = sys.argv[2]
base.setdefault("look", {})
def variant(name, **fields):
    file = json.loads(json.dumps(base))
    file["name"] = name
    file["look"].update(fields)
    json.dump(file, open(f"{out}/{name}.look.json", "w"), indent=2)
variant("baseline")
variant("glint0.3", glint=0.3)
# Closer: the auto camera frames the centres themselves, so the merger and the remnant fill it.
def close(name, **fields):
    file = json.loads(json.dumps(base))
    file["name"] = name
    file["camera"] = dict(base.get("camera", {}), mode="auto", zoom=1.4)
    file["look"].update(fields)
    json.dump(file, open(f"{out}/{name}.look.json", "w"), indent=2)
close("close")
close("close-glint0.3", glint=0.3)
EOF

while [ -d "$HOME/claude-workspace/.gpu-lock" ]; do sleep 30; done
for pair in "$@"; do
    name="${pair%%=*}"; take="${pair#*=}"
    echo "== $name $(date '+%T')"
    DYLD_LIBRARY_PATH="$B" "$B/sillage-render" look "$M" --grid --stills "$OUT/$name" --width 3840 \
        --no-variants --no-catalogue --base "$OUT/looks/baseline.look.json" --take "$take" \
        --frames "$FRAMES" "$OUT/looks/glint0.3.look.json" "$OUT/looks/close.look.json" \
        "$OUT/looks/close-glint0.3.look.json" | grep -E "^(still|look|key)"
done
