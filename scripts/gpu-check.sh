#!/usr/bin/env bash
# Tests of the GPU workflow's scripts with no box, no key and no Drive (#428, #440): gpu-box.sh
# and take-store.sh run against a recorded Vast and a local folder standing in for the Drive.
# Run by the Linux workflow; nothing here sends a request out.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME/.config/sillage" "$WORK/bin" "$WORK/drive"
KEY="vast-key-that-must-never-be-seen"
printf 'VAST_API_KEY=%s\nMAX_PRICE=0.80\n' "$KEY" > "$HOME/.config/sillage/gpu.env"
chmod 600 "$HOME/.config/sillage/gpu.env"
LOG="$WORK/requests.log"
: > "$LOG"
export PATH="$WORK/bin:$PATH" STUB_LOG="$LOG" STUB_DRIVE="$WORK/drive"

fail() { echo "gpu-check: $*" >&2; exit 1; }
expect() { grep -qF -- "$2" <<<"$1" || fail "expected \"$2\" in: $1"; }
refuse() { grep -qF -- "$2" <<<"$1" && fail "did not expect \"$2\" in: $1" || true; }

# The workflow's own shape.
yml="$ROOT/.github/workflows/gpu.yml"
grep -q '^  workflow_dispatch:' "$yml" || fail "gpu.yml must start by workflow_dispatch"
grep -qE '^  (pull_request|push|schedule)' "$yml" && fail "gpu.yml must have no trigger but workflow_dispatch"
grep -q 'cancel-in-progress: false' "$yml" || fail "gpu.yml must run one job at a time"
grep -q 'default: true' "$yml" || fail "gpu.yml must default to a dry run"
grep -c 'always()' "$yml" | grep -qE '^[2-9]' || fail "gpu.yml must destroy the box in a step and a job that always run"
for script in gpu-box.sh take-store.sh gpu-check.sh; do bash -n "$ROOT/scripts/$script"; done

# A recorded Vast: offers, credit and instances. The first offer is in China and is left out.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET; body=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift ;;
        -d) body="${2//$'\n'/ }"; shift ;;
        -H) printf '%s\n' "$2" >> "$STUB_LOG.headers"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
printf '%s %s %s\n' "$method" "$url" "$body" >> "$STUB_LOG"
case "$method $url" in
    "POST "*/bundles/) cat <<JSON
{"offers":[{"id":1,"machine_id":10,"gpu_name":"RTX 5090","dph_total":0.31,"geolocation":"Shanghai, CN","cpu_cores_effective":16,"cpu_ram":64000,"inet_down":900,"inet_up":500},
{"id":2,"machine_id":11,"gpu_name":"RTX 5090","dph_total":0.52,"geolocation":"Quebec, CA","cpu_cores_effective":16,"cpu_ram":64000,"inet_down":900,"inet_up":500},
{"id":3,"machine_id":12,"gpu_name":"RTX 5090","dph_total":0.61,"geolocation":"Paris, FR","cpu_cores_effective":16,"cpu_ram":64000,"inet_down":900,"inet_up":500}]}
JSON
    ;;
    "GET "*/users/current/) echo '{"credit":7.9,"balance":0}' ;;
    "GET "*/v1/instances/) echo '{"instances":[{"id":501,"label":"sillage-gh-1-1","gpu_name":"RTX 5090","actual_status":"running","dph_total":0.5},{"id":502,"label":"sillage","gpu_name":"RTX 3090","actual_status":"running","dph_total":0.3}]}' ;;
    "DELETE "*) echo '{"success":true}' ;;
    *) echo '{}' ;;
esac
STUB
chmod +x "$WORK/bin/curl"

out="$("$ROOT/scripts/gpu-box.sh" offers "RTX 5090")"
expect "$out" "2 RTX 5090 0.520 \$/h Quebec, CA"
refuse "$out" "Shanghai"
grep -q 'POST .*/bundles/ .*"dph_total":{"lte":0.80}' "$LOG" || fail "the offer query must carry the price ceiling"

: > "$LOG"
out="$(GPU_BOX_DRY=1 LABEL=sillage-gh-7-1 DEADLINE_HOURS=2 "$ROOT/scripts/gpu-box.sh" up "RTX 5090")"
expect "$out" "dry: PUT /asks/2/ (RTX 5090, 0.5200 \$/h, Quebec,_CA)"
expect "$out" '"label": "sillage-gh-7-1"'
expect "$out" 'sleep 7200'
grep -q '^PUT ' "$LOG" && fail "a dry run must not rent"

: > "$LOG"
out="$(LABEL=sillage-gh-1-1 "$ROOT/scripts/gpu-box.sh" cleanup)"
expect "$out" "destroyed instance 501"
refuse "$out" "502"
grep -q 'DELETE .*/instances/501/' "$LOG" || fail "cleanup must delete the labelled instance"
grep -q 'DELETE .*/instances/502/' "$LOG" && fail "cleanup must leave other labels alone"

printf 'id=501\nhost=1.2.3.4\nport=4022\ndeadline=1800000000\n' > "$HOME/.config/sillage/box"
expect "$("$ROOT/scripts/gpu-box.sh" where)" "host 1.2.3.4, port 4022, deadline 2027-01-15 08:00 UTC"
rm -f "$HOME/.config/sillage/box"

grep -rqF "$KEY" "$LOG" "$LOG.headers" 2>/dev/null && grep -qF "$KEY" "$LOG" && fail "the key reached a request line"
grep -qF "$KEY" <<<"$out" && fail "the key was printed"

# The Drive, standing in as a local folder: rclone's `sillage:` remote maps to $STUB_DRIVE.
cat > "$WORK/bin/rclone" <<'STUB'
#!/usr/bin/env bash
map() { case "$1" in sillage:*) echo "$STUB_DRIVE/${1#sillage:}" ;; *) echo "$1" ;; esac; }
cmd="$1"; shift
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --exclude|--transfers|--drive-chunk-size|--stats|--max-depth) shift ;;
        --*) ;;
        *) args+=("$1") ;;
    esac
    shift
done
case "$cmd" in
    about) echo "{\"total\":$((STUB_FREE * 2)),\"used\":$STUB_FREE,\"free\":$STUB_FREE}" ;;
    copy) mkdir -p "$(map "${args[1]}")"; cp -a "$(map "${args[0]}")/." "$(map "${args[1]}")/"; rm -rf "$(map "${args[1]}")/.checkpoint" ;;
    check) diff -r -x .checkpoint -x '*.tmp' "$(map "${args[0]}")" "$(map "${args[1]}")" ;;
    lsf) (cd "$STUB_DRIVE/Sillage" && find . -mindepth 1 -maxdepth 2 -type d | sed 's:^\./::; s:$:/:' | sort) ;;
    purge) rm -rf "$(map "${args[0]}")" ;;
    *) echo "stub rclone: $cmd not stubbed" >&2; exit 1 ;;
esac
STUB
chmod +x "$WORK/bin/rclone"
mkdir -p "$WORK/drive/Sillage"

scene="$WORK/lib/2026-11-26-a/scene-0001"
mkdir -p "$scene/.checkpoint"
head -c 4096 /dev/urandom > "$scene/take.sillage"
echo '{"engine":"cuda"}' > "$scene/hires.json"
echo partial > "$scene/.checkpoint/state"
store="$ROOT/scripts/take-store.sh"

out="$(STUB_FREE=1000000 "$store" up "$scene")"
expect "$out" "uploaded"
[ -f "$scene/take.sillage.sha256" ] || fail "up must seal the take"
cmp -s "$scene/take.sillage" "$WORK/drive/Sillage/2026-11-26-a/scene-0001/take.sillage" || fail "the take on the Drive differs"
[ -e "$WORK/drive/Sillage/2026-11-26-a/scene-0001/.checkpoint" ] && fail "a checkpoint must not go to the Drive"

out="$(STUB_FREE=100 "$store" up "$scene" 2>&1 || true)"
expect "$out" "the Drive is full"
expect "$out" "archive"

out="$(STUB_FREE=1000000 "$store" down 2026-11-26-a/scene-0001 "$WORK/back")"
expect "$out" "verified"
cmp -s "$scene/take.sillage" "$WORK/back/take.sillage" || fail "the take that came back differs"

printf 'X' | dd of="$WORK/drive/Sillage/2026-11-26-a/scene-0001/take.sillage" bs=1 seek=100 conv=notrunc 2>/dev/null
out="$("$store" down 2026-11-26-a/scene-0001 "$WORK/corrupt" 2>&1 || true)"
expect "$out" "refused"

rm "$scene/take.sillage.sha256"
out="$("$store" verify "$scene/take.sillage" 2>&1 || true)"
expect "$out" "is missing"

# archive moves the oldest scene to the library, then clears it from the Drive.
mkdir -p "$WORK/drive/Sillage/2026-11-25-a/scene-0009"
head -c 2048 /dev/urandom > "$WORK/drive/Sillage/2026-11-25-a/scene-0009/take.sillage"
(cd "$WORK/drive/Sillage/2026-11-25-a/scene-0009" && sha256sum take.sillage > take.sillage.sha256)
mkdir -p "$WORK/mac-library"
"$store" archive "$WORK/mac-library" 1 > /dev/null
[ -s "$WORK/mac-library/2026-11-25-a/scene-0009/take.sillage" ] || fail "archive must bring the take to the library"
[ -e "$WORK/drive/Sillage/2026-11-25-a/scene-0009" ] && fail "archive must remove the scene from the Drive once checked"

out="$(TAKE_STORE_DRY=1 "$store" down 2026-11-26-a/scene-0001 "$WORK/dry")"
expect "$out" "dry: rclone copy sillage:Sillage/2026-11-26-a/scene-0001 $WORK/dry"

echo "gpu-check: all passed"
