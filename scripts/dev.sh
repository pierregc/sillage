#!/usr/bin/env bash
# Builds and tests without SwiftPM. The Command Line Tools ship a PackageDescription
# whose interface and dylib disagree, which makes any manifest fail to compile.
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

build_app() {
    build_render
    swiftc -O -I "$BUILD" -L "$BUILD" -lSillageCore -lSillageRender -parse-as-library \
        -Xlinker -rpath -Xlinker @executable_path \
        "$ROOT"/Sources/SillageApp/*.swift -o "$BUILD/Sillage"

    local app="$BUILD/Sillage.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS"
    cp "$BUILD/Sillage" "$app/Contents/MacOS/Sillage"
    cp "$BUILD"/libSillage*.dylib "$app/Contents/MacOS/"
    # Every reference has to be rewritten, including the ones between the copied dylibs,
    # or dyld loads both the bundled copy and the one left in the build directory.
    for lib in SillageCore SillageRender; do
        install_name_tool -id "@rpath/lib$lib.dylib" "$app/Contents/MacOS/lib$lib.dylib" 2>/dev/null
    done
    for binary in Sillage libSillageCore.dylib libSillageRender.dylib; do
        for lib in SillageCore SillageRender; do
            install_name_tool -change "$BUILD/lib$lib.dylib" "@rpath/lib$lib.dylib" \
                "$app/Contents/MacOS/$binary" 2>/dev/null
        done
        install_name_tool -add_rpath "@loader_path" "$app/Contents/MacOS/$binary" 2>/dev/null
    done
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Sillage</string>
    <key>CFBundleIdentifier</key><string>dev.pierregc.sillage</string>
    <key>CFBundleName</key><string>Sillage</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
    codesign --force --sign - "$app" 2>/dev/null || true
    echo "$app"
}

# The package turns strict concurrency on and plain `swiftc` does not, which is how a
# `static var` on an enum compiles here and fails to build a package. SwiftPM cannot run on
# this machine at all — the Command Line Tools ship a PackageDescription whose interface and
# dylib disagree, and there is no Xcode.app to point `xcode-select` at — so the setting is
# applied by hand, one module at a time. This is the check that used to belong to CI, and the
# one that broke three pushes in a row when nothing was watching for it.
strict_concurrency() {
    build_render
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        "$ROOT"/Sources/SillageCore/*.swift
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -I "$BUILD" -L "$BUILD" -lSillageCore \
        "$ROOT"/Sources/SillageRender/*.swift
    swiftc -typecheck -strict-concurrency=complete -swift-version 6 \
        -I "$BUILD" -L "$BUILD" -lSillageCore -lSillageRender -parse-as-library \
        "$ROOT"/Sources/SillageApp/*.swift
}

# Everything CI used to run, in one command, and now the only gate there is. Run it before
# every commit.
check() {
    echo "== formatage"
    swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests"
    echo "== concurrence stricte"
    strict_concurrency
    echo "== application"
    build_app >/dev/null
    echo "== tests"
    run_tests
}

case "${1:-check}" in
    build)  build_render ;;
    lint)   swift format lint --recursive --strict "$ROOT/Sources" "$ROOT/Tests" ;;
    strict) strict_concurrency ;;
    check)  check ;;
    test)   shift || true; build_render; run_tests "$@" ;;
    app)    build_app ;;
    render) shift || true; build_render
            DYLD_LIBRARY_PATH="$BUILD" "$BUILD/sillage-render" "$@" ;;
    *)      echo "usage: ${BASH_SOURCE[0]} [check|build|test|lint|strict|render|app]" >&2
            exit 2 ;;
esac
