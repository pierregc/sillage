#!/usr/bin/env bash
# Crops of the same frame from each take, side by side, with grain.py from the gigantism spike.
#   sheets.sh <stills dir> <frames> <look> <name>...
set -euo pipefail
DIR="$1"; FRAMES="$2"; LOOK="$3"; shift 3
GRAIN="$HOME/claude-workspace/sillage-wt-gigantism/scripts/grain.py"
mkdir -p "$DIR/sheets" "$DIR/flat"
for frame in ${FRAMES//,/ }; do
    FILES=()
    for name in "$@"; do
        ln -sf "$DIR/$name/$LOOK-$frame.png" "$DIR/flat/$name-$LOOK-$frame.png"
        FILES+=("$DIR/flat/$name-$LOOK-$frame.png")
    done
    python3 "$GRAIN" sheet "$DIR/sheets/$LOOK-$frame.jpg" --crop auto --label-from "-$LOOK-$frame.png" "${FILES[@]}"
done
python3 "$GRAIN" score "$DIR"/flat/*.png
