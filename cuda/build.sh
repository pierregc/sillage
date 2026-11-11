#!/usr/bin/env bash
# Builds cuda/src and cuda/tests two ways from the same files (#281): with nvcc for the GPU,
# compile only, and with a host compiler through cuda_cpu.h for the CPU target, whose tests
# then run. No GPU is needed for either.
#
#   cuda/build.sh [gpu] [cpu] [libs]      gpu and cpu by default
#
# libs builds the two libraries the Swift links (#273), in $CUDA_OUT/lib: libsillagecuda_cpu.a,
# and libsillagecuda.a for sm_86, sm_89 and sm_120 with PTX when nvcc is there.
#
# NVCC and CXX choose the compilers, CUDA_OUT the output (.build/cuda). Without nvcc the GPU
# builds are skipped with a message, unless REQUIRE_NVCC=1 (the GitHub workflow).
# docs/notes/one-kernel-source.md says how to install nvcc, docs/notes/cuda-engine.md what the
# libraries hold.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${CUDA_OUT:-$root/.build/cuda}"
kernels="$root/.build/kernels"
includes=(-I "$here/include" -I "$kernels")
wanted="${*:-gpu cpu}"

"$root/scripts/kernel-sources.sh" "$kernels"

sources=("$here"/src/*.cu "$here"/tests/*.cu)

nvcc="${NVCC:-$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)}"

# Whether nvcc is there, and recent enough for the RTX 5090 (sm_120 came with CUDA 12.8).
have_nvcc() {
    if [[ ! -x "$nvcc" ]]; then
        if [[ "${REQUIRE_NVCC:-0}" == 1 ]]; then echo "nvcc not found" >&2; exit 1; fi
        echo "nvcc not found: the GPU build is skipped (the GitHub workflow runs it)"
        return 1
    fi
    local release
    release="$("$nvcc" --version | sed -n 's/.*release \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
    read -r major minor <<< "$release"
    if (( major < 12 || (major == 12 && minor < 8) )); then
        echo "$nvcc is CUDA $major.$minor: CUDA 12.8 or later is needed for sm_120" >&2
        exit 1
    fi
}

build_gpu() {
    have_nvcc || return 0
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

cxx="${CXX:-c++}"
cpu_flags=(-std=c++17 -O2 -ffp-contract=off -fPIC -Wall -Wextra -Werror "${includes[@]}" -x c++)

# cuda/src for the CPU target, and its library.
build_cpu_library() {
    mkdir -p "$out/cpu" "$out/lib"
    rm -f "$out/cpu"/*.o
    local source name
    for source in "$here"/src/*.cu; do
        name="$(basename "$source" .cu)"
        "$cxx" "${cpu_flags[@]}" -c "$source" -o "$out/cpu/$name.o"
    done
    rm -f "$out/lib/libsillagecuda_cpu.a"
    ar rcs "$out/lib/libsillagecuda_cpu.a" "$out/cpu"/*.o
    echo "cpu: cuda/src built with $("$cxx" --version | head -1), $out/lib/libsillagecuda_cpu.a"
}

build_cpu() {
    build_cpu_library
    local source name
    for source in "$here"/tests/*.cu; do
        name="$(basename "$source" .cu)"
        grep -q '^int main' "$source" || { "$cxx" "${cpu_flags[@]}" -fsyntax-only "$source"; continue; }
        "$cxx" "${cpu_flags[@]}" "$source" -x none "$out/lib/libsillagecuda_cpu.a" -o "$out/cpu/$name"
        (cd "$root" && "$out/cpu/$name")
    done
}

# cuda/src for the GPUs of #270: the RTX 3090 and A100 class (sm_86), the RTX 4090 (sm_89), the
# RTX 5090 (sm_120), and PTX for what comes after. No FMA contraction, as in the GPU build.
build_gpu_library() {
    have_nvcc || return 0
    mkdir -p "$out/gpu-lib" "$out/lib"
    rm -f "$out/gpu-lib"/*.o
    local flags=(-std=c++17 -O3 --fmad=false -Xcompiler -fPIC "${includes[@]}"
        -gencode arch=compute_86,code=sm_86 -gencode arch=compute_89,code=sm_89
        -gencode arch=compute_120,code=[sm_120,compute_120])
    local source name
    for source in "$here"/src/*.cu; do
        name="$(basename "$source" .cu)"
        "$nvcc" "${flags[@]}" -c "$source" -o "$out/gpu-lib/$name.o"
    done
    rm -f "$out/lib/libsillagecuda.a"
    ar rcs "$out/lib/libsillagecuda.a" "$out/gpu-lib"/*.o
    echo "gpu: cuda/src built for sm_86, sm_89 and sm_120 with PTX, $out/lib/libsillagecuda.a"
}

for target in $wanted; do
    case "$target" in
        gpu) build_gpu ;;
        cpu) build_cpu ;;
        libs) build_cpu_library; build_gpu_library ;;
        *) echo "usage: cuda/build.sh [gpu] [cpu] [libs]" >&2; exit 2 ;;
    esac
done
