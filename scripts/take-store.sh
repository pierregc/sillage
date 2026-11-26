#!/usr/bin/env bash
# Keeps every hires take whole in a folder of Pierre's Google Drive, with its SHA-256 (#440).
# Runs on a rented box (the workflow calls it), in a cloud session's tests and on the Mac.
#
# rclone reaches the Drive with the `drive.file` scope: it sees only the files it created, in the
# `Sillage` folder, nothing else of the Drive. Its configuration is the `sillage` remote, kept as
# the repository secret RCLONE_CONF and never in a file of the repository, an issue or a log.
#
#   seal <take>                  writes <take>.sha256 beside the take
#   verify <take>                checks the take against <take>.sha256; refuses a mismatch
#   room <bytes>                 says how much room the Drive has, refuses if <bytes> do not fit
#   up <scene dir>               verifies the take, checks the room, copies the scene folder to
#                                Sillage/<library date>/<scene>/ and checks the copy by hash
#   down <date>/<scene> <dir>    fetches that scene into <dir> and checks the take's digest
#   list                         the scenes on the Drive, oldest first, with their sizes
#   archive <library dir> [n]    moves the n oldest scenes (1 by default) from the Drive into the
#                                library on this machine, checked, then removes them from the Drive
#   install                      installs rclone on a Debian or Ubuntu box
#
# TAKE_STORE_DRY=1 prints the rclone commands instead of running them.
# RCLONE_CONFIG=<file> is the rclone configuration (default ~/.config/rclone/rclone.conf);
# TAKE_STORE_REMOTE=<remote:folder> overrides sillage:Sillage.
set -euo pipefail

REMOTE="${TAKE_STORE_REMOTE:-sillage:Sillage}"
DRY="${TAKE_STORE_DRY:-0}"
MARGIN_PERCENT=5

die() { echo "take-store: $*" >&2; exit 1; }

rc() {
    if [ "$DRY" = 1 ]; then echo "dry: rclone $*"; else rclone "$@"; fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

bytes_of() {
    python3 -I -c '
import os, sys
total = 0
for root, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = [d for d in dirs if d != ".checkpoint"]
    total += sum(os.path.getsize(os.path.join(root, f)) for f in files if not f.endswith(".tmp"))
print(total)' "$1"
}

seal() {
    [ -f "${1:-}" ] || die "seal: no such take: ${1:-}"
    echo "$(sha256_of "$1")  $(basename "$1")" > "$1.sha256"
    echo "sealed $1: $(cut -c1-16 "$1.sha256")..."
}

verify() {
    local take="${1:-}"
    [ -f "$take" ] || die "verify: no such take: $take"
    [ -f "$take.sha256" ] || die "verify: $take.sha256 is missing: a take with no digest is not drawn"
    local want got
    want="$(cut -d' ' -f1 "$take.sha256")"
    got="$(sha256_of "$take")"
    [ "$want" = "$got" ] || die "verify: $take does not match its digest (wrote $want, reads $got): refused"
    echo "verified $take"
}

room() {
    local need="${1:?room: how many bytes?}"
    if [ "$DRY" = 1 ]; then rc about "$REMOTE" --json; return; fi
    local free
    free="$(rclone about "$REMOTE" --json | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d.get("free", -1))')"
    if [ "$free" = -1 ]; then echo "the Drive did not say how much room it has: going on"; return; fi
    python3 -I -c '
import sys
need, free, margin = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
gb = lambda n: "%.1f GB" % (n / 1e9)
print("the Drive has %s free, this upload needs %s" % (gb(free), gb(need)))
sys.exit(0 if need * (100 + margin) // 100 <= free else 1)' "$need" "$free" "$MARGIN_PERCENT" ||
        die "the Drive is full: run \`scripts/take-store.sh archive <library dir>\` on the Mac to move the oldest takes to its disk, then run the job again"
}

scene_remote() {
    local dir="${1%/}"
    echo "$REMOTE/$(basename "$(dirname "$dir")")/$(basename "$dir")"
}

up() {
    local dir="${1:?up: which scene folder?}"
    [ -d "$dir" ] || die "up: no such folder: $dir"
    local take="$dir/take.sillage"
    [ -f "$take" ] || die "up: $dir has no take.sillage"
    [ -f "$take.sha256" ] || seal "$take"
    verify "$take"
    room "$(bytes_of "$dir")"
    local target
    target="$(scene_remote "$dir")"
    rc copy "$dir" "$target" --exclude '.checkpoint/**' --exclude '*.tmp' --checksum --transfers 4 --drive-chunk-size 256M --stats 60s --stats-one-line
    rc check "$dir" "$target" --exclude '.checkpoint/**' --exclude '*.tmp' --one-way
    echo "uploaded $dir to $target and checked it by hash"
}

down() {
    local name="${1:?down: which scene (<date>/<scene>)?}" dest="${2:?down: into which folder?}"
    mkdir -p "$dest"
    rc copy "$REMOTE/$name" "$dest" --checksum --transfers 4 --stats 60s --stats-one-line
    if [ "$DRY" = 1 ]; then return; fi
    verify "$dest/take.sillage"
}

list() {
    rc lsf "$REMOTE" --dirs-only -R --max-depth 2 | sed 's:/$::' | grep '/' | sort
}

archive() {
    local library="${1:?archive: which library folder?}" count="${2:-1}" scene
    [ -d "$library" ] || die "archive: no such folder: $library"
    while read -r scene; do
        [ -n "$scene" ] || continue
        echo "moving $scene to $library"
        down "$scene" "$library/$scene"
        rc check "$REMOTE/$scene" "$library/$scene" --one-way
        rc purge "$REMOTE/$scene"
    done < <(list | head -n "$count")
}

install() {
    command -v rclone >/dev/null 2>&1 && { rclone version | head -1; return; }
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends rclone > /dev/null
    rclone version | head -1
}

[ $# -gt 0 ] || { sed -n '2,25p' "$0"; exit 2; }
command="$1"; shift
case "$command" in
    seal) seal "$@" ;;
    verify) verify "$@" ;;
    room) room "$@" ;;
    up) up "$@" ;;
    down) down "$@" ;;
    list) list ;;
    archive) archive "$@" ;;
    install) install ;;
    *) die "unknown command $command" ;;
esac
