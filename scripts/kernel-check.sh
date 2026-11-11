#!/usr/bin/env bash
# The checks that keep the Metal and the CUDA engines on one kernel source (#281), run by
# ./scripts/dev.sh check on the Mac and by the GitHub workflow. They need no GPU and no CUDA
# toolkit: bash, awk and a C++17 compiler (CXX, clang++ by default).
#
#   1. no float literal of the MSL lacks its suffix: C++ and CUDA would read it as a double;
#   2. the shared MSL of every library, what is outside `#if defined(__METAL_VERSION__)`,
#      compiles as C++17 through cuda/include/msl_compat.h, and so do the CUDA entry points of
#      cuda/src that call it, as the CPU target builds them;
#   3. cuda/kernels.txt lists every Metal kernel, vertex and fragment function with its state,
#      and a function marked `cuda` has its entry point in cuda/src, as have the kernels a
#      function marked `cuda in` names.
#
# See docs/notes/one-kernel-source.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kernels="${KERNELS_OUT:-$root/.build/kernels}"
cxx="${CXX:-clang++}"
cd "$root"

"$root/scripts/kernel-sources.sh" "$kernels"

failed=0

# 1. Float literals. The #line of each header gives the Swift file and line back.
for header in "$kernels"/*.h; do
    [[ "$(basename "$header")" == kernels.h ]] && continue
    awk '
        /^#line / { file = $3; gsub(/"/, "", file); line = $2 - 1; next }
        file == "" { next }
        { line += 1 }
        /^#include / { next }
        {
            text = $0
            at = index(text, "//")
            if (at > 0) { text = substr(text, 1, at - 1) }
            n = length(text)
            i = 1
            while (i <= n) {
                c = substr(text, i, 1)
                if (c ~ /[A-Za-z_]/) {
                    while (i <= n && substr(text, i, 1) ~ /[A-Za-z0-9_]/) { i += 1 }
                    continue
                }
                if (c ~ /[0-9]/ || (c == "." && substr(text, i + 1, 1) ~ /[0-9]/)) {
                    j = i
                    hex = substr(text, i, 2) ~ /^0[xX]$/
                    while (j <= n) {
                        d = substr(text, j, 1)
                        if (d ~ /[0-9A-Za-z_.]/) { j += 1; continue }
                        if (!hex && (d == "+" || d == "-") && j > i && substr(text, j - 1, 1) ~ /[eE]/) { j += 1; continue }
                        break
                    }
                    token = substr(text, i, j - i)
                    if (!hex && token ~ /[.eE]/ && token !~ /[fFhH]$/) {
                        printf "%s:%d: the float literal %s has no suffix: C++ and CUDA read it as a double, 64 times slower than a float on a consumer NVIDIA GPU. Write %sf.\n", file, line, token, token
                        bad = 1
                    }
                    i = j
                    continue
                }
                i += 1
            }
        }
        END { exit bad }
    ' "$header" || failed=1
done

# 2. The shared MSL as C++17. Messages name the Swift file and line.
if ! command -v "$cxx" >/dev/null 2>&1; then
    echo "kernel-check: no C++ compiler ($cxx): set CXX" >&2
    exit 1
fi
if ! "$cxx" -std=c++17 -fsyntax-only -Werror=double-promotion -Werror=float-conversion \
    -I "$root/cuda/include" -I "$kernels" -x c++ "$root/cuda/src/kernels.cu"; then
    echo "kernel-check: the shared MSL does not compile as C++17, so it will not compile as CUDA." >&2
    echo "  What is outside \`#if defined(__METAL_VERSION__)\` is also the CUDA engine's source:" >&2
    echo "  write it another way, add what it needs to cuda/include/msl_compat.h, or keep it in" >&2
    echo "  the Metal entry point (docs/notes/one-kernel-source.md)." >&2
    failed=1
fi
for source in "$root"/cuda/src/*.cu; do
    [[ "$(basename "$source")" == kernels.cu ]] && continue
    if ! "$cxx" -std=c++17 -fsyntax-only -Werror=double-promotion -Werror=float-conversion \
        -I "$root/cuda/include" -I "$kernels" -x c++ "$source"; then
        echo "kernel-check: ${source#"$root"/} no longer compiles against the shared MSL: a shared" >&2
        echo "  function its entry points call changed. Change the CUDA entry point with it" >&2
        echo "  (docs/notes/cuda-engine.md)." >&2
        failed=1
    fi
done

# 3. cuda/kernels.txt against the MSL and against cuda/src.
entries="$(find "$root/cuda/src" -type f \( -name '*.cu' -o -name '*.h' \) -exec cat {} + | awk '
    /__global__/ {
        gsub(/__launch_bounds__\([^)]*\)/, "")
        sub(/^.*__global__/, "")
        if (match($0, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) {
            name = substr($0, RSTART, RLENGTH)
            sub(/[ \t]*\($/, "", name)
            print name
        }
    }' | tr '\n' ' ')"
for header in "$kernels"/*.h; do
    library="$(basename "$header" .h)"
    [[ "$library" == kernels ]] && continue
    awk -v library="$library" '
        { sub(/^\[\[[A-Za-z0-9_(), ]*\]\][ \t]*/, "") }
        /^(kernel|vertex|fragment)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/ {
            name = $3
            sub(/\(.*$/, "", name)
            print library, name
        }' "$header"
done > "$kernels/metal-functions.txt"

awk -v entries="$entries" '
    function fail(message) { print message; bad = 1 }
    BEGIN {
        count = split(entries, list, " ")
        for (i = 1; i <= count; ++i) { entry[list[i]] = 1 }
    }
    FNR == NR { metal[$1 " " $2] = 1; order[++total] = $1 " " $2; next }
    /^[ \t]*(#|$)/ { next }
    {
        key = $1 " " $2
        state = $0
        sub(/^[ \t]*[^ \t]+[ \t]+[^ \t]+[ \t]*/, "", state)
        where = "cuda/kernels.txt:" FNR ": "
        if (key in seen) { fail(where key " is listed twice."); next }
        seen[key] = 1
        if (!(key in metal)) {
            fail(where $1 " has no kernel, vertex or fragment function named " $2 " any more: remove the line.")
            next
        }
        if (state == "cuda" || state == "cuda gpu-only") {
            if (!($2 in entry)) {
                fail(where $2 " is marked `" state "`, but cuda/src has no `__global__ void " $2 "(`: write its entry point, or mark it `pending #<issue>`.")
            }
            tally[state] += 1
        } else if (state ~ /^cuda in [A-Za-z_][A-Za-z0-9_ ]*$/) {
            names = state
            sub(/^cuda in /, "", names)
            held = split(names, inside, " ")
            for (i = 1; i <= held; ++i) {
                if (!(inside[i] in entry)) {
                    fail(where $2 " is marked `" state "`, but cuda/src has no `__global__ void " inside[i] "(`: name the kernels that call its shared function.")
                }
            }
            tally["cuda in"] += 1
        } else if (state ~ /^pending #[0-9]+$/) {
            tally["pending"] += 1
        } else if (state ~ /^metal-only: [^ \t]/) {
            tally["metal-only"] += 1
        } else {
            fail(where "`" state "` is not a state: cuda, cuda gpu-only, cuda in <kernels>, pending #<issue> or metal-only: <reason>.")
        }
    }
    END {
        for (i = 1; i <= total; ++i) {
            if (!(order[i] in seen)) {
                split(order[i], part, " ")
                fail("cuda/kernels.txt has no line for " part[2] " of " part[1] ": the CUDA engine would run without it. Give it its CUDA entry point in cuda/src and add `" order[i] " cuda`, or add `" order[i] " pending #<issue>` or `" order[i] " metal-only: <reason>`.")
            }
        }
        if (!bad) {
            printf "kernels: %d Metal functions: %d cuda, %d cuda gpu-only, %d inside a kernel, %d pending, %d metal-only\n", total, tally["cuda"], tally["cuda gpu-only"], tally["cuda in"], tally["pending"], tally["metal-only"]
        }
        exit bad
    }
' "$kernels/metal-functions.txt" "$root/cuda/kernels.txt" || failed=1

exit "$failed"
