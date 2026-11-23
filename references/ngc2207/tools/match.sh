#!/usr/bin/env bash
# match.sh <scene folder> [extra match options]: the match against the picture from 20 to 460 Myr after
# the run's first pericentre (Struck's eye lasts 60 to 260), a free one over the whole take, the sheets
# and a row in logs/sweep.csv
C="$HOME/claude-workspace/ngc2207"; s="$1"; shift; n=$(basename "$s")
p=$(python3 "$C/tools/peri.py" "$s"); at=$(python3 -c "print($p + 240)")
if [ $# -eq 0 ]; then set -- --at "$at" --within 220 --fresh; fi
"$C/tools/sr.sh" match "$s" "$C/ref/ngc2207.map.json" --kpc-across 49.0 "$@" > "$C/logs/match-$n.log" 2>&1
[ "$1" = --at ] && [ "$5" = --fresh ] && "$C/tools/sr.sh" match "$s" "$C/ref/ngc2207-free.map.json" --kpc-across 49.0 >> "$C/logs/match-$n.log" 2>&1
(cd "$HOME/claude-workspace/sillage" && python3 scripts/photo-match.py sheet "$s/match/ngc2207.sheet.json") >> "$C/logs/match-$n.log" 2>&1
python3 "$C/tools/row.py" "$s" >> "$C/logs/sweep.csv"
