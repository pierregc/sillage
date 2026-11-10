#!/usr/bin/env bash
# Builds cuda/src and cuda/tests two ways from the same files (#281): with nvcc for the GPU,
# compile only, and with a host compiler through cuda_cpu.h for the CPU target, whose tests
# then run. No GPU is needed for either.
#
#   cuda/build.sh [gpu] [cpu]      both by default
#
# NVCC and CXX choose the compilers, CUDA_OUT the output (.build/cuda). Without nvcc the GPU
# build is skipped with a message, unless REQUIRE_NVCC=1 (the GitHub workflow).
# docs/notes/one-kernel-source.md says how to install nvcc.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${CUDA_OUT:-$root/.build/cuda}"
kernels="$root/.build/kernels"
includes=(-I "$here/include" -I "$kernels")
wanted="${*:-gpu cpu}"

"$root/scripts/kernel-sources.sh" "$kernels"

sources=("$here"/src/*.cu "$here"/tests/*.cu)

build_gpu() {
    local nvcc="${NVCC:-$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)}"
    if [[ ! -x "$nvcc" ]]; then
        if [[ "${REQUIRE_NVCC:-0}" == 1 ]]; then echo "nvcc not found" >&2; exit 1; fi
        echo "nvcc not found: the GPU build is skipped (the GitHub workflow runs it)"
        return
    fi
    "$nvcc" --version | grep release
    mkdir -p "$out/gpu"
    # The RTX 5090 of the runs. No FMA contraction and no fast math: a file whose Metal twin
    # contracts says so itself when it gets its entry points.
    local flags=(-std=c++17 -O3 -arch=sm_120 --fmad=false "${includes[@]}")
    local source name doubles
    for source in "${sources[@]}"; do
        name="$(basename "$source" .cu)"
        "$nvcc" "${flags[@]}" -c "$source" -o "$out/gpu/$name.o"
        "$nvcc" "${flags[@]}" -ptx "$source" -o "$out/gpu/$name.ptx"
        doubles="$(grep -cE '\.f64' "$out/gpu/$name.ptx" || true)"
        if [[ "$doubles" != 0 ]]; then
            echo "$source: $doubles double precision instructions in its PTX ($out/gpu/$name.ptx)." >&2
            echo "  A consumer NVIDIA GPU runs them at 1/64 of float speed: look for a double in the" >&2
            echo "  shared MSL or in the entry point (grep f64 in the PTX names the function)." >&2
            exit 1
        fi
        echo "gpu: $name.cu compiled for sm_120, no double precision instruction"
    done
}

build_cpu() {
    local cxx="${CXX:-c++}"
    mkdir -p "$out/cpu"
    local flags=(-std=c++17 -O2 -ffp-contract=off -Wall -Wextra -Werror "${includes[@]}" -x c++)
    local source name
    for source in "$here"/src/*.cu; do
        name="$(basename "$source" .cu)"
        "$cxx" "${flags[@]}" -c "$source" -o "$out/cpu/$name.o"
    done
    echo "cpu: cuda/src built with $("$cxx" --version | head -1)"
    for source in "$here"/tests/*.cu; do
        name="$(basename "$source" .cu)"
        grep -q '^int main' "$source" || { "$cxx" "${flags[@]}" -fsyntax-only "$source"; continue; }
        "$cxx" "${flags[@]}" "$source" -o "$out/cpu/$name"
        "$out/cpu/$name"
    done
}

for target in $wanted; do
    case "$target" in
        gpu) build_gpu ;;
        cpu) build_cpu ;;
        *) echo "usage: cuda/build.sh [gpu] [cpu]" >&2; exit 2 ;;
    esac
done
