#!/usr/bin/env bash
# Runs a command on the rented box in tmux (so a dropped SSH link does not stop it), waits for it,
# shows the end of its log and exits with its exit code (#428). Used by .github/workflows/gpu.yml.
set -euo pipefail
box="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gpu-box.sh"
"$box" run "$@"
n="$(sed -n 's/^run=//p' "$HOME/.config/sillage/box")"
"$box" wait "$n" || true
exit "$("$box" ssh "cat /work/logs/$n.exit")"
