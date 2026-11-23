#!/usr/bin/env bash
# Takes turns on a machine's GPU (#468): one heavy job at a time, whoever starts it.
#
#   gpu-lock.sh run <label> <command...>   waits for the lock, runs the command, releases it
#   gpu-lock.sh status                     who holds the lock, since when, and whether it is alive
#
# The lock is a directory, made with mkdir so that taking it is atomic, holding `owner` (label,
# pid, host, start). It is $SILLAGE_GPU_LOCK, else ~/claude-workspace/.gpu-lock where that folder
# exists, else ~/.sillage-gpu-lock. A lock whose process is gone on this host is taken over; a
# lock held by a live process is never removed. GPU_LOCK_WAIT caps the wait in seconds (forever).
set -euo pipefail

if [ -n "${SILLAGE_GPU_LOCK:-}" ]; then
    LOCK="$SILLAGE_GPU_LOCK"
elif [ -d "$HOME/claude-workspace" ]; then
    LOCK="$HOME/claude-workspace/.gpu-lock"
else
    LOCK="$HOME/.sillage-gpu-lock"
fi
HOST="$(hostname)"

owner_field() { sed -n "s/^$1=//p" "$LOCK/owner" 2>/dev/null; }

stale() {
    [ -d "$LOCK" ] || return 1
    local pid host
    pid="$(owner_field pid)"
    host="$(owner_field host)"
    [ -n "$pid" ] && [ "$host" = "$HOST" ] && ! kill -0 "$pid" 2>/dev/null
}

status() {
    if [ ! -d "$LOCK" ]; then
        echo "gpu-lock: free ($LOCK)"
        return 0
    fi
    local state=alive
    stale && state="dead, will be taken over"
    echo "gpu-lock: held by $(owner_field label), pid $(owner_field pid) on $(owner_field host)," \
        "since $(owner_field since) ($state)"
}

run() {
    [ $# -ge 2 ] || { echo "usage: gpu-lock.sh run <label> <command...>" >&2; exit 2; }
    local label="$1" waited=0 limit="${GPU_LOCK_WAIT:-0}"
    shift
    mkdir -p "$(dirname "$LOCK")"
    until mkdir "$LOCK" 2>/dev/null; do
        if stale; then
            echo "gpu-lock: taking over from $(owner_field label), whose process is gone" >&2
            rm -rf "$LOCK"
            continue
        fi
        if [ "$waited" -eq 0 ]; then echo "gpu-lock: waiting: $(status | cut -d: -f2-)" >&2; fi
        if [ "$limit" -gt 0 ] && [ "$waited" -ge "$limit" ]; then
            echo "gpu-lock: still held after ${limit} s, giving up" >&2
            exit 75
        fi
        sleep 5
        waited=$((waited + 5))
    done
    printf 'label=%s\npid=%s\nhost=%s\nsince=%s\n' "$label" "$$" "$HOST" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK/owner"
    trap 'rm -rf "$LOCK"' EXIT
    trap 'exit 130' INT TERM
    local code=0
    "$@" || code=$?
    exit "$code"
}

case "${1:-}" in
    run)    shift; run "$@" ;;
    status) status ;;
    *)      echo "usage: gpu-lock.sh run <label> <command...> | status" >&2; exit 2 ;;
esac
