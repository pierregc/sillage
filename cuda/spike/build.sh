#!/usr/bin/env bash
# The tracer walk spike (#271), built two ways from walk.cu: nvcc for the GPU (compile only
# without one) and a host compiler through cuda_cpu.h for the CPU. Checks the MSL copy, runs
# the CPU build on a synthetic dump, then on every dump directory given.
#
#   cuda/spike/build.sh [dump-dir ...]
#
# NVCC, CXX and SPIKE_OUT (default cuda/spike/build) override the tools and the output.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
out="${SPIKE_OUT:-$here/build}"
mkdir -p "$out"

echo "== the MSL copy"
ranges='4,6p;11,28p;41,61p;83,151p;322,331p;390,401p;472,568p;616,693p'
if diff <(sed -n "$ranges" "$root/Sources/SillageRender/BarnesHutShaders.swift" | sed 's/^        //') \
    <(tail -n +5 "$here/walk_msl.h") >"$out/msl.diff"; then
    echo "walk_msl.h is BarnesHutShaders.swift's text, unchanged"
else
    echo "walk_msl.h differs from BarnesHutShaders.swift:" && cat "$out/msl.diff" && exit 1
fi

echo "== build 1: nvcc"
nvcc="${NVCC:-$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)}"
if [[ -x "$nvcc" ]]; then
    "$nvcc" --version | tail -2
    arch=sm_89
    if "$nvcc" --list-gpu-arch 2>/dev/null | grep -q compute_120; then arch=sm_120; fi
    # 1835: `constant` on a parameter, which is meant to be ignored there.
    flags=(-std=c++17 -O2 -arch="$arch" -I"$here" -diag-suppress 1835)
    "$nvcc" "${flags[@]}" -Xptxas -v "$here/walk.cu" -o "$out/walk-gpu" 2>&1 \
        | grep -E "error|warning|registers|stack frame" || true
    [[ -x "$out/walk-gpu" ]] || { echo "nvcc failed"; exit 1; }
    "$nvcc" "${flags[@]}" -ptx "$here/walk.cu" -o "$out/walk.ptx"
    echo "built for $arch; double precision instructions in the PTX: $(grep -cE '\.f64' "$out/walk.ptx" || true)"
else
    echo "nvcc not found: build 1 skipped (see docs/notes/cuda-walk-spike.md to install it)"
fi

echo "== build 2: the CPU"
cxx="${CXX:-g++}"
"$cxx" -std=c++17 -O2 -ffp-contract=off -Wall -Wextra -Wno-attributes -Wno-unknown-attributes \
    -I"$here" -x c++ "$here/walk.cu" -o "$out/walk-cpu"
"$cxx" -std=c++17 -O2 -Wall "$here/synthetic.cpp" -o "$out/synthetic"
echo "built with $("$cxx" --version | head -1), -O2, FMA contraction off"

echo "== synthetic, opening angle 0: the walk is a direct sum"
"$out/synthetic" "$out/synthetic-theta0" --theta 0 >/dev/null
"$out/walk-cpu" "$out/synthetic-theta0" --top 0 | tee "$out/synthetic-theta0.txt" | sed -n '5,7p;9,$p'
awk '/99.9th percentile/ { if ($5 + 0 > 1e-5) { print "too far from the direct sum"; exit 1 } }' \
    "$out/synthetic-theta0.txt"

for dump in "$@"; do
    echo "== $dump"
    "$out/walk-cpu" "$dump"
done
