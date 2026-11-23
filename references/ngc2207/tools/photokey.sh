#!/usr/bin/env bash
# photokey.sh <scene folder> <look> <out png> [preset]: the matched frame in a look, framed like the picture
C="$HOME/claude-workspace/ngc2207"; s="$1"; look="$2"; out="$3"; preset="${4:-1080p}"
mkdir -p "$s/flights"
"$(dirname "$0")/../../../scripts/picture-film.py" flight "$s/match/ngc2207.json" --aspect 6353x2983 \
    --out "$s/flights/photo.flight.json" > /dev/null || exit 1
d=$(mktemp -d)
"$C/tools/sr.sh" export "$s" --look "$look" --flight photo --preset "$preset" --flight-keys "$d" > "$C/logs/photokey-$(basename "$s").log" 2>&1 || exit 1
cp "$d"/key-00-*.png "$out"; rm -rf "$d"
