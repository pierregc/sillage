#!/usr/bin/env bash
# Every CUDA check on one rented card, in one go: the engine check (the fixtures' frames held to
# Metal's, glow and Sombrero among them), then every CUDA Swift test on the GPU (flight export
# #382, Sombrero film #514 #517, dust glow and galaxies #516, point stars #518). Correctness only,
# no timing: any card of sm_86 or later does, the cheapest first. The verdict is printed last,
# where the workflow's log shows it, since artifacts cannot be fetched from the cloud.
#
#   gpu.yml, command: scripts/cuda-card-check.sh, gpu: RTX 3060, hours: 2 (billed by the second)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
OUT="${OUT:-$ROOT/out}"
mkdir -p "$OUT"
log="$OUT/cuda-card-check.log"
started=$SECONDS
# Timings, the 200 M faint light and exact resume on a GPU are left out on purpose.
{
    REQUIRE_NVCC=1 scripts/linux.sh engine-check &&
        REQUIRE_NVCC=1 scripts/linux.sh test-cuda --skip 'Timed|FaintLight|Resumed'
} > >(tee "$log") 2>&1
code=$?
wait

echo
echo "== VERDICT"
nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader | sed 's/^/VERDICT card: /'
grep -m1 "SillageCUDA links the" "$log" | sed 's/^/VERDICT /'
grep -q "SillageCUDA links the gpu target" "$log" || { echo "VERDICT the GPU library was not linked"; code=1; }
grep -E "^check " "$log" | sed 's/^/VERDICT /'
grep -E "✘|error:" "$log" | head -60 | sed 's/^/VERDICT /'
grep -E "^(✔|✘) Test run with" "$log" | tail -1 | sed 's/^/VERDICT /'
echo "VERDICT $([ "$code" = 0 ] && echo PASSED || echo "FAILED (exit $code)") in $(((SECONDS - started) / 60)) min"
exit "$code"
