#!/bin/bash
# Frame cost at 8 M, 4K, photograph against wider young stars: 60 frames each, twice, alternated.
cd "$(dirname "$0")"
B=$SCRATCH/branch-build
mkdir -p cost
for round in 1 2; do
  for tag in photo y3 y3g06; do
    DYLD_LIBRARY_PATH=$B $B/sillage-render export scene-0067 --look looks/$tag-passage.look.json \
      --preset 4k --start 5.333333333333333 --duration 2 --fps 30 --no-overlay \
      --out cost/$tag-$round.mov 2>&1 | grep -E "^export +[0-9]+ frames" | sed "s/^/$tag round $round: /"
  done
done
