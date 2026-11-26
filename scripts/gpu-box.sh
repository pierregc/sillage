#!/usr/bin/env bash
# Rents an NVIDIA GPU on Vast.ai, ships the code to it, runs a command there, brings the results
# back and destroys it (#283). Runs from the Mac; docs/notes/cloud-runs.md says how to use it.
#
# Reads ~/.config/sillage/gpu.env, which never enters the repository:
#   VAST_API_KEY=...            the account's key (required)
#   SSH_KEY=~/.ssh/sillage_gpu  the private key whose public half is on the Vast account
#   GPU=RTX 3090                the default card for `up`
#   IMAGE=nvidia/cuda:12.8.1-devel-ubuntu24.04
#   MAX_PRICE=0.35              the highest $/h `up` accepts
#   DEADLINE_HOURS=3            the box deletes itself after this many hours, whatever happens
#
# The key is never printed, never written on a box and never put on a command line: curl reads
# it from a header file of its own. The box gets only Vast's per-instance key, which it uses to
# delete itself at its deadline.
#
#   offers [gpu]        the cheapest suitable on-demand offers (no rental)
#   up [gpu]            rents the cheapest suitable offer, waits for SSH, arms the deadline
#   status              the box's state, price, age and the time left before its deadline
#   setup               installs Swift 6.2, ffmpeg and tools, checks nvidia-smi and nvcc
#   ship                rsyncs the local checkout (without .build and .git) to /work/sillage
#   run <command>       runs it in /work/sillage in tmux, output in /work/logs/<n>.log
#   tail [n]            the end of the last (or n-th) run's log, and whether it has finished
#   wait                waits for the last run to finish, then shows its tail
#   ssh [command]       a shell, or one command, on the box
#   fetch <paths>       rsyncs paths of /work back to ~/claude-workspace/gpu-out/<date>-<box>/
#   down [note]         destroys the box, checks Vast no longer lists it, appends to the ledger
#   list                every instance on the account (a forgotten box shows here)
#   where               the box's id, address, port and deadline
#   cleanup             destroys every instance whose label is $LABEL (the workflow's safety net)
#
# GPU_BOX_DRY=1 prints what `up` and `down` would send instead of sending it.
# LABEL=<text> names the instances this run rents (default sillage); GPU_OUT=<dir> is where `fetch`
# puts what it brings back. .github/workflows/gpu.yml drives this script from GitHub's runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${SILLAGE_GPU_ENV:-$HOME/.config/sillage/gpu.env}"
STATE_DIR="$HOME/.config/sillage"
STATE="$STATE_DIR/box"
LEDGER="$ROOT/docs/notes/gpu-ledger.md"
API="https://console.vast.ai/api/v0"
API_ROOT="https://console.vast.ai/api"
SWIFT_URL="https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz"
SWIFT_SHA="8e3d63a3371caad495e694414b9b9a22c5f68c6473077406c7296472a41bc077"

die() { echo "gpu-box: $*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "$CONFIG is missing: it holds VAST_API_KEY=..."
if [ "$(stat -c %a "$CONFIG" 2>/dev/null || stat -f %Lp "$CONFIG")" != 600 ]; then
    die "$CONFIG must be chmod 600"
fi
# shellcheck disable=SC1090
set -a; . "$CONFIG"; set +a
[ -n "${VAST_API_KEY:-}" ] || die "VAST_API_KEY is not set in $CONFIG"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/sillage_gpu}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
GPU="${GPU:-RTX 3090}"
IMAGE="${IMAGE:-nvidia/cuda:12.8.1-devel-ubuntu24.04}"
MAX_PRICE="${MAX_PRICE:-0.35}"
DEADLINE_HOURS="${DEADLINE_HOURS:-3}"
DRY="${GPU_BOX_DRY:-0}"
INTERRUPTIBLE="${INTERRUPTIBLE:-0}"
BID_MARGIN="${BID_MARGIN:-1.2}"

# The key goes to curl through a header file only this user reads, never through argv.
HEADERS="$(mktemp "${TMPDIR:-/tmp}/gpu-box.XXXXXX")"
trap 'rm -f "$HEADERS"' EXIT
chmod 600 "$HEADERS"
printf 'Authorization: Bearer %s\n' "$VAST_API_KEY" > "$HEADERS"
unset VAST_API_KEY

api() {
    local method="$1" path="$2" body="${3:-}" url
    # Paths starting with /v1/ go to Vast's v1 API (the list of instances moved there).
    case "$path" in /v1/*) url="$API_ROOT$path" ;; *) url="$API$path" ;; esac
    if [ -n "$body" ]; then
        curl -sS --fail-with-body -X "$method" -H "@$HEADERS" -H 'Content-Type: application/json' \
            -d "$body" "$url"
    else
        curl -sS --fail-with-body -X "$method" -H "@$HEADERS" "$url"
    fi
}

json() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

state_get() { [ -f "$STATE" ] && sed -n "s/^$1=//p" "$STATE" | head -1; }
state_put() {
    { grep -v "^$1=" "$STATE" 2>/dev/null || true; echo "$1=$2"; } > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"
}
need_box() { [ -n "$(state_get id)" ] || die "no box: run \`up\` first"; }

credit() { api GET /users/current/ | json 'print(round(d.get("credit",0)+d.get("balance",0),4))'; }

# The query for one card: on demand (interruptible with INTERRUPTIBLE=1: a bid, paused by a higher
# bid or an on-demand rental, BID_MARGIN above the host's minimum bid, 1.2 by default), one GPU, verified host, CUDA 12.8 driver, 8 cores, 32 GB,
# 60 GB of disk, a decent link, reliability 0.98, under MAX_PRICE.
offers_json() {
    local gpu="$1"
    cat <<JSON
{"gpu_name":{"eq":"$gpu"},"num_gpus":{"eq":1},"rentable":{"eq":true},"verified":{"eq":true},
 "type":"$( [ "$INTERRUPTIBLE" = 1 ] && echo bid || echo on-demand )","cuda_max_good":{"gte":12.8},"reliability2":{"gte":0.98},
 "cpu_cores_effective":{"gte":8},"cpu_ram":{"gte":32000},"disk_space":{"gte":60},
 "inet_down":{"gte":200},"inet_up":{"gte":100},
 "$( [ "$INTERRUPTIBLE" = 1 ] && echo min_bid || echo dph_total )":{"lte":$MAX_PRICE},
 "duration":{"gte":14400},"order":[["$( [ "$INTERRUPTIBLE" = 1 ] && echo min_bid || echo dph_total )","asc"]],"limit":20}
JSON
}

# Hosts in mainland China are left out: downloads from swift.org and GitHub are unreliable there.
offers() {
    local gpu="${1:-$GPU}"
    api POST /bundles/ "$(offers_json "$gpu")" | json '
o=[x for x in d.get("offers",[]) if not (x.get("geolocation") or "").endswith("CN")]
for x in o[:10]:
    print(x["id"], x["gpu_name"], "%.3f $/h" % (x.get("min_bid") if x.get("min_bid") and "'"$INTERRUPTIBLE"'" == "1" else x["dph_total"]), x.get("geolocation"),
          "cores %d ram %d GB" % (x.get("cpu_cores_effective",0), x.get("cpu_ram",0)/1000),
          "down %d up %d Mb/s" % (x.get("inet_down",0), x.get("inet_up",0)),
          "%.3f $/GB down" % (x.get("inet_down_cost") or 0))
if not o: print("no offer")'
}

# What the box runs at start: the deadline, enforced by the box itself with Vast's key for that
# instance alone (CONTAINER_API_KEY), since Vast enforces none.
onstart() {
    local seconds=$((DEADLINE_HOURS * 3600))
    cat <<SH
mkdir -p /work/logs
{ env; tr '\\0' '\\n' < /proc/1/environ 2>/dev/null; } | grep -E '^CONTAINER_(ID|API_KEY)=' | sort -u > /root/.vast-instance && chmod 600 /root/.vast-instance
nohup bash -c 'sleep $seconds; . /root/.vast-instance; curl -sS -X DELETE -H "Authorization: Bearer \$CONTAINER_API_KEY" $API/instances/\$CONTAINER_ID/' > /work/logs/watchdog.log 2>&1 &
echo "deadline armed: $DEADLINE_HOURS h" > /work/logs/watchdog.armed
SH
}

instance() { api GET "/instances/$(state_get id)/" | json "i=d.get('instances') or {}; $1"; }

ssh_args() {
    echo -i "$SSH_KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$STATE_DIR/known_hosts" -o ServerAliveInterval=30 \
        -o ConnectTimeout=15 -p "$(state_get port)"
}
on_box() { need_box; ssh $(ssh_args) "root@$(state_get host)" "$@"; }

up() {
    [ -z "$(state_get id)" ] || die "a box is already up ($(state_get id)): \`down\` it first"
    local gpu="${1:-$GPU}" offer
    offer="$(api POST /bundles/ "$(offers_json "$gpu")" | json '
o=[x for x in d.get("offers",[]) if not (x.get("geolocation") or "").endswith("CN") and str(x.get("machine_id")) not in "'"${SKIP_MACHINES:-}"'".split(",")]
b="'"$INTERRUPTIBLE"'" == "1"
print("%s %.4f %s" % (o[0]["id"], o[0]["min_bid"] * '"$BID_MARGIN"' if b else o[0]["dph_total"], (o[0].get("geolocation") or "?").replace(" ","_")) if o else "")')"
    [ -n "$offer" ] || die "no $gpu offer under $MAX_PRICE \$/h"
    read -r offer_id price place <<<"$offer"
    local body
    body="$(python3 -c 'import json,sys; b={"client_id":"me","image":sys.argv[1],
        "disk":60,"runtype":"ssh_direc ssh_proxy","label":sys.argv[5],"onstart":sys.argv[2]}
if sys.argv[3] == "1": b["price"] = round(float(sys.argv[4]), 4)
print(json.dumps(b))' "$IMAGE" "$(onstart)" "$INTERRUPTIBLE" "$price" "${LABEL:-sillage}")"
    if [ "$DRY" = 1 ]; then
        echo "dry: PUT /asks/$offer_id/ ($gpu, $price \$/h, $place)"
        echo "$body" | json 'print(json.dumps(d, indent=1))'
        return
    fi
    local before id
    before="$(credit)"
    id="$(api PUT "/asks/$offer_id/" "$body" | json 'print(d.get("new_contract") or "")')"
    [ -n "$id" ] || die "Vast refused the rental of offer $offer_id"
    mkdir -p "$STATE_DIR"
    {
        echo "id=$id"; echo "gpu=$gpu"; echo "price=$price"; echo "place=$place"
        echo "started=$(date -u +%s)"; echo "credit=$before"
        echo "deadline=$(( $(date -u +%s) + DEADLINE_HOURS * 3600 ))"
    } > "$STATE"
    chmod 600 "$STATE"
    echo "rented box $id: $gpu, $price \$/h, $place; deadline in $DEADLINE_HOURS h"
    local status="" host="" port="" t=0
    while [ $t -lt 900 ]; do
        read -r status host port <<<"$(instance '
p=(i.get("ports") or {}).get("22/tcp") or []
if i.get("public_ipaddr") and p: print(i.get("actual_status"), i["public_ipaddr"].strip(), p[0]["HostPort"])
else: print(i.get("actual_status"), i.get("ssh_host") or "-", i.get("ssh_port") or "-")')"
        if [ "$status" = running ] && [ "$host" != - ]; then
            state_put host "$host"; state_put port "$port"
            if on_box true 2>/dev/null; then
                echo "box $id ready after $t s: ssh -p $port root@<box> (\`gpu-box.sh ssh\`)"
                on_box 'cat /work/logs/watchdog.armed 2>/dev/null || echo "deadline NOT armed"'
                # A host whose link cannot fetch Swift in minutes is no use: 20 MB in 20 s at least.
                local speed
                speed="$(on_box 'timeout 25 curl -s -o /dev/null -w "%{speed_download}" "https://speed.cloudflare.com/__down?bytes=20000000" || echo 0' 2>/dev/null | tail -1)"
                if python3 -c "import sys; sys.exit(0 if float('${speed:-0}' or 0) > 1e6 else 1)"; then
                    echo "download speed $(python3 -c "print('%.0f' % (float('$speed') / 1e6))") MB/s"
                    return
                fi
                echo "box $id downloads at ${speed:-0} B/s: destroying it (SKIP_MACHINES=$(instance 'print(i.get("machine_id"))') to avoid it)" >&2
                down "host too slow to download"
                exit 1
            fi
        fi
        sleep 10; t=$((t + 10))
    done
    echo "box $id not reachable after 15 minutes (status $status): destroying it" >&2
    down "never reachable"
    exit 1
}

status() {
    need_box
    local now started deadline
    now="$(date -u +%s)"; started="$(state_get started)"; deadline="$(state_get deadline)"
    instance 'print("box", i.get("id"), i.get("gpu_name"), i.get("actual_status"), "%.3f $/h" % (i.get("dph_total") or 0))'
    echo "up $(( (now - started) / 60 )) min, about $(python3 -c "print('%.2f' % ($(state_get price) * ($now - $started) / 3600))") \$ so far; deadline in $(( (deadline - now) / 60 )) min"
}

setup() {
    on_box "SWIFT_URL='$SWIFT_URL' SWIFT_SHA='$SWIFT_SHA' bash -s" <<'SH'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl git rsync tmux ffmpeg \
    build-essential binutils libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libncurses-dev \
    libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config tzdata unzip \
    zlib1g-dev python3 > /dev/null
if [ ! -x /opt/swift/usr/bin/swiftc ]; then
    mkdir -p /opt/swift /tmp/swift-dl
    curl -sSfL -C - --retry 3 -o /tmp/swift-dl/swift.tar.gz "$SWIFT_URL"
    echo "$SWIFT_SHA  /tmp/swift-dl/swift.tar.gz" | sha256sum -c -
    tar -xzf /tmp/swift-dl/swift.tar.gz -C /opt/swift --strip-components=1
    rm -rf /tmp/swift-dl
fi
grep -q /opt/swift /root/.bashrc || echo 'export PATH=/opt/swift/usr/bin:/usr/local/cuda/bin:$PATH' >> /root/.bashrc
export PATH=/opt/swift/usr/bin:/usr/local/cuda/bin:$PATH
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
nvcc --version | tail -2
swift --version 2>&1 | head -1
nproc; free -g | sed -n 2p
SH
}

ship() {
    need_box
    on_box 'mkdir -p /work/sillage'
    # Without .git (over a gigabyte): the commit shipped is written in /work/sillage/.shipped.
    git -C "$ROOT" rev-parse HEAD > "$STATE_DIR/shipped"
    rsync -az --delete --exclude .build --exclude .git --exclude '.DS_Store' -e "ssh $(ssh_args)" \
        "$ROOT/" "root@$(state_get host):/work/sillage/"
    rsync -az -e "ssh $(ssh_args)" "$STATE_DIR/shipped" "root@$(state_get host):/work/sillage/.shipped"
    echo "shipped $(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet || echo ' with local changes') to /work/sillage"
}

run() {
    [ $# -gt 0 ] || die "run what?"
    local n
    n="$(on_box 'ls /work/logs/*.log 2>/dev/null | grep -c "/[0-9]*\.log$" || true')"
    n=$((n + 1))
    local cmd
    printf -v cmd '%q ' "$@"
    on_box "cd /work/sillage && tmux new-session -d -s run$n \"export PATH=/opt/swift/usr/bin:/usr/local/cuda/bin:\\\$PATH; ( $cmd ) > /work/logs/$n.log 2>&1; echo \\\$? > /work/logs/$n.exit\""
    state_put run "$n"
    echo "run $n started: $*"
}

tail_run() {
    local n="${1:-$(state_get run)}"
    on_box "tail -n 40 /work/logs/$n.log; if [ -f /work/logs/$n.exit ]; then echo \"== run $n finished, exit \$(cat /work/logs/$n.exit)\"; else echo '== run $n still running'; fi"
}

wait_run() {
    local n="${1:-$(state_get run)}"
    while ! on_box "test -f /work/logs/$n.exit"; do sleep 30; done
    tail_run "$n"
}

fetch() {
    need_box
    local out="${GPU_OUT:-$HOME/claude-workspace/gpu-out/$(date +%Y-%m-%d)-$(state_get id)}"
    mkdir -p "$out"
    local path
    for path in "${@:-logs}"; do
        rsync -az -e "ssh $(ssh_args)" "root@$(state_get host):/work/$path" "$out/"
    done
    echo "fetched into $out"
}

down() {
    need_box
    local id note="${1:-}"
    id="$(state_get id)"
    if [ "$DRY" = 1 ]; then echo "dry: DELETE /instances/$id/"; return; fi
    api DELETE "/instances/$id/" > /dev/null || true
    local t=0
    while api GET /v1/instances/ | json "import sys; sys.exit(0 if any(str(i.get('id'))=='$id' for i in d.get('instances',[])) else 1)"; do
        [ $t -lt 120 ] || die "Vast still lists box $id after 2 minutes: check the console"
        sleep 5; t=$((t + 5))
    done
    local now started minutes cost before after spent
    now="$(date -u +%s)"; started="$(state_get started)"
    minutes=$(( (now - started + 59) / 60 ))
    cost="$(python3 -c "print('%.3f' % ($(state_get price) * $minutes / 60))")"
    before="$(state_get credit)"
    sleep 5
    after="$(credit)"
    spent="$(python3 -c "print('%.3f' % ($before - $after))")"
    if [ ! -f "$LEDGER" ]; then
        cat > "$LEDGER" <<'MD'
# GPU ledger

Every rented session, appended by `scripts/gpu-box.sh down` (#283). Cost at the box's hourly price
times its minutes; credit used is what the Vast account lost over the session (storage and
bandwidth included). Euros at 1.12 $ a euro.

| date (UTC) | provider | GPU | $/h | minutes | cost $ | credit used $ | € | issue | what ran |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
MD
    fi
    local euros
    euros="$(python3 -c "print('%.2f' % (max($cost, $spent) / 1.12))")"
    echo "| $(date -u +%Y-%m-%d) | Vast.ai | $(state_get gpu) | $(state_get price) | $minutes | $cost | $spent | $euros | ${ISSUE:-#283} | ${note:-} |" >> "$LEDGER"
    rm -f "$STATE"
    echo "box $id destroyed after $minutes min: about $cost \$ at its price, $spent \$ of credit used; $after \$ left"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo "### GPU ledger line"
            echo "| date (UTC) | provider | GPU | \$/h | minutes | cost \$ | credit used \$ | € | issue | what ran |"
            echo "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |"
            tail -n 1 "$LEDGER"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
}

list() {
    api GET /v1/instances/ | json '
for i in d.get("instances",[]): print(i.get("id"), i.get("gpu_name"), i.get("actual_status"), "%.3f $/h" % (i.get("dph_total") or 0), i.get("label"))
if not d.get("instances"): print("no instance on the account")'
    echo "credit: $(credit) \$"
}

where() {
    need_box
    echo "id $(state_get id), host $(state_get host), port $(state_get port), deadline $(date -u -d "@$(state_get deadline)" '+%Y-%m-%d %H:%M UTC' 2>/dev/null || date -u -r "$(state_get deadline)" '+%Y-%m-%d %H:%M UTC')"
}

cleanup() {
    local label="${LABEL:-sillage}" ids id
    ids="$(api GET /v1/instances/ | json "print(' '.join(str(i['id']) for i in d.get('instances',[]) if i.get('label') == '$label'))")"
    [ -n "$ids" ] || { echo "no instance labelled $label"; return; }
    for id in $ids; do
        if [ "$DRY" = 1 ]; then echo "dry: DELETE /instances/$id/"; continue; fi
        api DELETE "/instances/$id/" > /dev/null || true
        echo "destroyed instance $id labelled $label"
    done
}

[ $# -gt 0 ] || { sed -n '2,34p' "$0"; exit 2; }
command="$1"; shift
case "$command" in
    offers) offers "$@" ;;
    up) up "$@" ;;
    status) status ;;
    setup) setup ;;
    ship) ship ;;
    run) run "$@" ;;
    tail) tail_run "$@" ;;
    wait) wait_run "$@" ;;
    ssh) on_box "$@" ;;
    fetch) fetch "$@" ;;
    down) down "$@" ;;
    list) list ;;
    where) where ;;
    cleanup) cleanup ;;
    *) die "unknown command $command" ;;
esac
