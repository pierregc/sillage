#!/usr/bin/env bash
# Builds and tests without SwiftPM. The Command Line Tools ship a PackageDescription
# whose interface and dylib disagree, which makes any manifest fail to compile.
# GitHub CI uses swift build / swift test normally.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/dev"
DEV="$(xcode-select -p)"
FRAMEWORKS="$DEV/Library/Developer/Frameworks"
INTEROP="$DEV/Library/Developer/usr/lib"
PLUGIN="$DEV/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"

build_core() {
    mkdir -p "$BUILD"
    swiftc -O -emit-library -emit-module -enable-testing \
        -module-name SillageCore "$ROOT"/Sources/SillageCore/*.swift \
        -emit-module-path "$BUILD/SillageCore.swiftmodule" \
        -o "$BUILD/libSillageCore.dylib"
}

build_render() {
    build_core
    swiftc -O -emit-library -emit-module -enable-testing \
        -module-name SillageRender -I "$BUILD" -L "$BUILD" -lSillageCore \
        "$ROOT"/Sources/SillageRender/*.swift \
        -emit-module-path "$BUILD/SillageRender.swiftmodule" \
        -o "$BUILD/libSillageRender.dylib"
    swiftc -O -I "$BUILD" -L "$BUILD" -lSillageCore -lSillageRender \
        "$ROOT"/Sources/sillage-render/main.swift -o "$BUILD/sillage-render"
}

run_tests() {
    cat > "$BUILD/runner.swift" <<'SWIFT'
import Testing

@main struct Runner {
    static func main() async { _ = await __swiftPMEntryPoint() as CInt }
}
SWIFT
    swiftc -O -I "$BUILD" -L "$BUILD" -lSillageCore -lSillageRender \
        -F "$FRAMEWORKS" -framework Testing \
        -load-plugin-library "$PLUGIN" -parse-as-library \
        "$ROOT"/Tests/SillageCoreTests/*.swift "$ROOT"/Tests/SillageRenderTests/*.swift \
        "$BUILD/runner.swift" \
        -o "$BUILD/tests"
    DYLD_LIBRARY_PATH="$BUILD:$INTEROP" DYLD_FRAMEWORK_PATH="$FRAMEWORKS" "$BUILD/tests" "$@"
}

case "${1:-test}" in
    build)  build_render ;;
    lint)   swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests" ;;
    test)   shift || true; build_render; run_tests "$@" ;;
    render) shift || true; build_render
            DYLD_LIBRARY_PATH="$BUILD" "$BUILD/sillage-render" "$@" ;;
    *)      echo "usage: ${BASH_SOURCE[0]} [build|test|lint|render]" >&2; exit 2 ;;
esac
