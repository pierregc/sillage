#!/usr/bin/env bash
# Builds and tests the portable Swift on Linux (Swift 6.2, Ubuntu 22.04 or 24.04), in the manner
# of dev.sh: plain swiftc, no SwiftPM, output in .build/linux. SillageCore builds whole;
# SillageRender and the tests build without the files listed in scripts/linux-skip.txt and
# scripts/linux-skip-tests.txt, which need an Apple framework. docs/notes/linux-build.md says why.
#
# SillageCUDA, the CUDA engine's Swift (#273), links libsillagecuda.a, built by nvcc, when a GPU
# is there, and libsillagecuda_cpu.a, the CPU target, otherwise; SILLAGE_CUDA_TARGET=gpu or cpu
# chooses. docs/notes/cuda-engine.md says what the CPU target runs.
#
# Commands that take no arguments can follow one another, the modules built once:
# `scripts/linux.sh lint strict test-cuda`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/linux"

if ! command -v swiftc >/dev/null 2>&1 && [ -x /opt/swift/usr/bin/swiftc ]; then
    export PATH="/opt/swift/usr/bin:$PATH"
fi
command -v swiftc >/dev/null 2>&1 || { echo "swiftc not found: install Swift 6.2 for Linux" >&2; exit 1; }
THREADS="$(nproc 2>/dev/null || echo 4)"

# The files of a module, less the ones a skip list names. A name on the list that is not a file
# is an error, so the lists cannot go stale.
sources() {
    local dir="$1" skip="${2:-}"
    local files=("$dir"/*.swift)
    if [ -n "$skip" ]; then
        local name
        while read -r name; do
            [ -f "$dir/$name" ] || { echo "$skip lists $name, which is not in $dir" >&2; exit 1; }
        done < <(skipped "$skip")
        local kept=() file
        for file in "${files[@]}"; do
            skipped "$skip" | grep -qxF "$(basename "$file")" || kept+=("$file")
        done
        files=("${kept[@]}")
    fi
    printf '%s\n' "${files[@]}"
}

skipped() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"; }

core_sources() { sources "$ROOT/Sources/SillageCore"; }
render_sources() { sources "$ROOT/Sources/SillageRender" "$ROOT/scripts/linux-skip.txt"; }
cuda_sources() { sources "$ROOT/Sources/SillageCUDA"; }

# The test files of a set: all, core, render or cuda.
test_sources() {
    local set="${1:-all}" skip="$ROOT/scripts/linux-skip-tests.txt" name file dir dirs
    case "$set" in
        core) dirs=(SillageCoreTests) ;;
        render) dirs=(SillageRenderTests) ;;
        cuda) dirs=(SillageCUDATests) ;;
        *) dirs=(SillageCoreTests SillageRenderTests SillageCUDATests) ;;
    esac
    while read -r name; do
        [ -f "$ROOT/Tests/SillageCoreTests/$name" ] || [ -f "$ROOT/Tests/SillageRenderTests/$name" ] \
            || { echo "$skip lists $name, which is not a test file" >&2; exit 1; }
    done < <(skipped "$skip")
    for dir in "${dirs[@]}"; do
        for file in "$ROOT"/Tests/$dir/*.swift; do
            skipped "$skip" | grep -qxF "$(basename "$file")" || echo "$file"
        done
    done
}

build_core() {
    mkdir -p "$BUILD"
    swiftc -O -num-threads "$THREADS" -emit-library -emit-module -enable-testing \
        -module-name SillageCore $(core_sources) \
        -emit-module-path "$BUILD/SillageCore.swiftmodule" \
        -o "$BUILD/libSillageCore.so"
}

built_render=0
built_cuda=0

build_render() {
    [ "$built_render" = 1 ] && return
    build_core
    swiftc -O -num-threads "$THREADS" -emit-library -emit-module -enable-testing \
        -module-name SillageRender -I "$BUILD" -L "$BUILD" -lSillageCore \
        $(render_sources) \
        -emit-module-path "$BUILD/SillageRender.swiftmodule" \
        -o "$BUILD/libSillageRender.so"
    built_render=1
}

# The library SillageCUDA links: the GPU's when nvcc built it and a GPU is there.
cuda_target() {
    local target="${SILLAGE_CUDA_TARGET:-}"
    if [ -z "$target" ]; then
        target=cpu
        if [ -f "$ROOT/.build/cuda/lib/libsillagecuda.a" ] && nvidia-smi -L 2>/dev/null | grep -q GPU; then
            target=gpu
        fi
    fi
    echo "$target"
}

build_cuda() {
    [ "$built_cuda" = 1 ] && return
    build_render
    if [ -z "${CXX:-}" ]; then
        CXX="$(command -v c++ || command -v clang++ || command -v g++ || echo c++)"
        export CXX
    fi
    "$ROOT/cuda/build.sh" libs
    local libraries
    if [ "$(cuda_target)" = gpu ]; then
        local nvcc="${NVCC:-$(command -v nvcc || echo /usr/local/cuda/bin/nvcc)}"
        local cuda="$(cd "$(dirname "$nvcc")/.." && pwd)"
        libraries=(-lsillagecuda -L "$cuda/lib64" -lcudart_static -ldl -lrt -lpthread)
    else
        libraries=(-lsillagecuda_cpu)
    fi
    echo "SillageCUDA links the $(cuda_target) target"
    swiftc -O -num-threads "$THREADS" -emit-library -emit-module -enable-testing \
        -module-name SillageCUDA -I "$BUILD" -I "$ROOT/cuda/include" -L "$BUILD" -lSillageCore \
        -lSillageRender \
        $(cuda_sources) \
        -emit-module-path "$BUILD/SillageCUDA.swiftmodule" \
        -L "$ROOT/.build/cuda/lib" "${libraries[@]}" -lstdc++ \
        -o "$BUILD/libSillageCUDA.so"
    built_cuda=1
}

# Builds and runs the tests of a set (test_sources), with swift-testing's own arguments after it.
run_tests() {
    local set="$1"
    shift
    local modules=(-lSillageCore)
    [ "$set" = core ] || modules+=(-lSillageRender)
    [ "$set" = core ] || [ "$set" = render ] || modules+=(-I "$ROOT/cuda/include" -lSillageCUDA)
    cat > "$BUILD/runner.swift" <<'SWIFT'
import Foundation
import Testing

@main struct Runner {
    static func main() async { exit(await __swiftPMEntryPoint() as CInt) }
}
SWIFT
    swiftc -O -num-threads "$THREADS" -I "$BUILD" -L "$BUILD" "${modules[@]}" \
        -parse-as-library $(test_sources "$set") "$BUILD/runner.swift" \
        -Xlinker -rpath -Xlinker "$BUILD" \
        -o "$BUILD/tests-$set"
    # Some tests read the clock in the zone they were written in, Pierre's.
    TZ="${TZ:-Europe/Paris}" LD_LIBRARY_PATH="$BUILD" "$BUILD/tests-$set" "$@"
}

# The package turns strict concurrency on and plain swiftc does not, as dev.sh explains.
strict_concurrency() {
    build_cuda
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -module-name SillageCore $(core_sources)
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -module-name SillageRender -I "$BUILD" -L "$BUILD" -lSillageCore $(render_sources)
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -module-name SillageCUDA -I "$BUILD" -I "$ROOT/cuda/include" $(cuda_sources)
}

check() {
    echo "== format"
    swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests"
    echo "== strict concurrency"
    strict_concurrency
    echo "== tests"
    run_tests all
}

usage() {
    echo "usage: ${BASH_SOURCE[0]} [check|build|lint|strict|files|test-cuda]..." >&2
    echo "       ${BASH_SOURCE[0]} test|test-core|test-render|test-cuda [swift-testing arguments]" >&2
    exit 2
}

run_command() {
    case "$1" in
        build)  build_cuda ;;
        lint)   swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests" ;;
        strict) strict_concurrency ;;
        files)  echo "== SillageCore"; core_sources; echo "== SillageRender"; render_sources
                echo "== SillageCUDA"; cuda_sources; echo "== Tests"; test_sources all ;;
        check)  check ;;
        test)   shift; build_cuda; run_tests all "$@" ;;
        test-core) shift; build_core; run_tests core "$@" ;;
        test-render) shift; build_render; run_tests render "$@" ;;
        test-cuda) shift; build_cuda; run_tests cuda "$@" ;;
        *)      usage ;;
    esac
}

[ $# -gt 0 ] || set -- check
case "$1" in
    test|test-core|test-render|test-cuda) [ $# -eq 1 ] || { run_command "$@"; exit; } ;;
esac
for name in "$@"; do run_command "$name"; done
