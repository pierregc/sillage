#!/usr/bin/env bash
# sweep.sh: the preview grid. Bulge share x extent, then the ring's width, the disk's thickness and the
# bulge's flattening round the middle. Each: explore at 200 k, hires at 500 k with sticky gas, stills.
C="${SOMBRERO:-$HOME/claude-workspace/sombrero}"; T="$(cd "$(dirname "$0")" && pwd)"; W="$T/../../.."
SR="$C/sr.sh"; LOCK="$W/scripts/gpu-lock.sh"; LOOK="$C/looks/sombrero.look.json"; PLAIN="$C/looks/sombrero-plain.look.json"
run() { # name bulge extent width thickness flattening
  n="$1"; s="$C/lib/sweep/$n"; [ -f "$C/out/plain/$n-260.png" ] && return
  python3 "$T/make_scene.py" "$s" "$2" "$3" "$4" "$5" "$6"
  t0=$(date +%s)
  "$LOCK" run "sombrero-explore-$n" "$SR" explore "$s" --particles 200000 --width 960 --height 540 --no-check > "$C/logs/explore-$n.log" 2>&1 || { echo "$n,explore failed" >> "$C/logs/sweep.csv"; return; }
  t1=$(date +%s)
  "$LOCK" run "sombrero-hires-$n" "$SR" hires "$s" --particles 500000 --sticky-gas on --no-video --checkpoint-every 0 > "$C/logs/hires-$n.log" 2>&1 || { echo "$n,hires failed" >> "$C/logs/sweep.csv"; return; }
  t2=$(date +%s)
  fr=$(python3 -c "
import json;c=json.load(open('$s/clip.json'))['story'];a,b=c['startMyr'],c['endMyr'];n=c['endFrame']
print(','.join(str(round((m-a)/(b-a)*n)) for m in (200,260,340)))")
  "$LOCK" run "sombrero-plain-$n" "$SR" export "$s" --look "$PLAIN" --preset 1080p --stills "$C/out/plain-$n" --still-frames "$fr" > "$C/logs/plain-$n.log" 2>&1
  mkdir -p "$C/out/plain"; i=0; for m in 200 260 340; do f=$(ls "$C/out/plain-$n"/*.png | sed -n "$((i+1))p"); cp "$f" "$C/out/plain/$n-$m.png"; i=$((i+1)); done
  "$LOCK" run "sombrero-flight-$n" "$T/stills.sh" "$s" "$C/out/flight-$n" "$LOOK" 200,260,340 > "$C/logs/flight-$n.log" 2>&1
  echo "$n,$2,$3,$4,$5,$6,$((t1-t0)),$((t2-t1)),$(( $(date +%s)-t2 ))" >> "$C/logs/sweep.csv"
}
for b in 0.6 0.75 0.85; do for e in 0.9 1.25 1.7; do run "b$b-e$e" $b $e 1.06 0.2 0.65; done; done
run w0.6 0.75 1.25 0.6 0.2 0.65; run w1.5 0.75 1.25 1.5 0.2 0.65
run h0.12 0.75 1.25 1.06 0.12 0.65; run h0.35 0.75 1.25 1.06 0.35 0.65
run f0.5 0.75 1.25 1.06 0.2 0.5; run f0.85 0.75 1.25 1.06 0.2 0.85
echo done >> "$C/logs/sweep.csv"
