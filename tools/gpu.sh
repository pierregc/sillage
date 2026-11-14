#!/bin/bash
# Runs a command under the shared GPU lock, waiting up to 30 min for it.
LOCK="$HOME/claude-workspace/.gpu-lock"
for i in $(seq 1 360); do
  if mkdir "$LOCK" 2>/dev/null; then
    echo "issue-315 photograph pid $$ $(date '+%F %T')" > "$LOCK/owner"
    trap 'rm -rf "$LOCK"' EXIT
    "$@"
    exit $?
  fi
  [ $i = 1 ] && echo "gpu.sh: waiting for $(cat "$LOCK/owner" 2>/dev/null)" >&2
  sleep 5
done
echo "gpu.sh: lock still held after 30 min" >&2
exit 75
