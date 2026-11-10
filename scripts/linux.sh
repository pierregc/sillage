#!/usr/bin/env bash
# Builds and tests the portable Swift on Linux (Swift 6.2, Ubuntu 22.04 or 24.04), in the manner
# of dev.sh: plain swiftc, no SwiftPM, output in .build/linux. SillageCore builds whole;
# SillageRender and the tests build without the files listed in scripts/linux-skip.txt and
# scripts/linux-skip-tests.txt, which need an Apple framework. docs/notes/linux-build.md says why.
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

test_sources() {
    local skip="$ROOT/scripts/linux-skip-tests.txt" name file dir
    while read -r name; do
        [ -f "$ROOT/Tests/SillageCoreTests/$name" ] || [ -f "$ROOT/Tests/SillageRenderTests/$name" ] \
            || { echo "$skip lists $name, which is not a test file" >&2; exit 1; }
    done < <(skipped "$skip")
    for dir in SillageCoreTests SillageRenderTests; do
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

build_render() {
    build_core
    swiftc -O -num-threads "$THREADS" -emit-library -emit-module -enable-testing \
        -module-name SillageRender -I "$BUILD" -L "$BUILD" -lSillageCore \
        $(render_sources) \
        -emit-module-path "$BUILD/SillageRender.swiftmodule" \
        -o "$BUILD/libSillageRender.so"
}

run_tests() {
    cat > "$BUILD/runner.swift" <<'SWIFT'
import Foundation
import Testing

@main struct Runner {
    static func main() async { exit(await __swiftPMEntryPoint() as CInt) }
}
SWIFT
    swiftc -O -num-threads "$THREADS" -I "$BUILD" -L "$BUILD" -lSillageCore -lSillageRender \
        -parse-as-library $(test_sources) "$BUILD/runner.swift" \
        -Xlinker -rpath -Xlinker "$BUILD" \
        -o "$BUILD/tests"
    # Some tests read the clock in the zone they were written in, Pierre's.
    TZ="${TZ:-Europe/Paris}" LD_LIBRARY_PATH="$BUILD" "$BUILD/tests" "$@"
}

# The package turns strict concurrency on and plain swiftc does not, as dev.sh explains.
strict_concurrency() {
    build_render
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -module-name SillageCore $(core_sources)
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -module-name SillageRender -I "$BUILD" -L "$BUILD" -lSillageCore $(render_sources)
}

check() {
    echo "== format"
    swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests"
    echo "== strict concurrency"
    strict_concurrency
    echo "== tests"
    run_tests
}

case "${1:-check}" in
    build)  build_render ;;
    lint)   swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests" ;;
    strict) strict_concurrency ;;
    files)  echo "== SillageCore"; core_sources; echo "== SillageRender"; render_sources
            echo "== Tests"; test_sources ;;
    check)  check ;;
    test)   shift || true; build_render; run_tests "$@" ;;
    *)      echo "usage: ${BASH_SOURCE[0]} [check|build|test|lint|strict|files]" >&2
            exit 2 ;;
esac
