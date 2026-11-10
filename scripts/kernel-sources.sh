#!/usr/bin/env bash
# Writes the MSL of each Metal library to .build/kernels/<library>.h, for nvcc and the CPU
# build to include (#281). A library is an `enum <library>` holding one `static let source`,
# a multi-line string literal that Metal compiles as it is. The header holds that text
# unchanged, inside `namespace metal::<library>` and between msl_begin.h and msl_end.h, with a
# #line that sends a compiler's messages back to the Swift file. kernels.h includes them all.
#
#   scripts/kernel-sources.sh [output directory]
#
# Refuses a string it cannot hand over as Metal sees it: one with a backslash (an
# interpolation or an escape), a raw string, a `source` put together from several pieces, or
# MSL found anywhere else. Plain bash and awk, the same on macOS and Linux.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/.build/kernels}"
mkdir -p "$out"
rm -f "$out"/*.h

cd "$root"
files="$(grep -l 'metal_stdlib' Sources/*/*.swift | LC_ALL=C sort)"
[[ -n "$files" ]] || { echo "kernel-sources: no MSL found under Sources" >&2; exit 1; }

index="$out/kernels.h"
{
    echo "// Written by scripts/kernel-sources.sh: every Metal library's MSL. Do not edit."
    echo "#ifndef SILLAGE_KERNELS_H"
    echo "#define SILLAGE_KERNELS_H"
} > "$index"

for file in $files; do
    library="$(awk '/^enum [A-Za-z_][A-Za-z0-9_]* \{$/ { print $2 }' "$file")"
    if [[ "$(wc -w <<< "$library")" -ne 1 ]]; then
        echo "kernel-sources: $file holds MSL but not one top-level \`enum <library> {\`." >&2
        echo "  Keep a library's MSL in one enum of its own, or teach this script the new layout." >&2
        exit 1
    fi
    awk -v file="$file" -v library="$library" '
        function refuse(why) {
            printf "kernel-sources: %s:%d: %s\n", file, NR, why > "/dev/stderr"
            printf "  The CUDA build compiles the text Metal compiles: keep %s.source one plain\n", library > "/dev/stderr"
            printf "  multi-line string, or teach scripts/kernel-sources.sh how Metal now puts it together.\n" > "/dev/stderr"
            failed = 1
            exit 1
        }
        state == 0 && /"""/ {
            if ($0 !~ /^    static let source = """$/) { refuse("a multi-line string that is not `static let source = \"\"\"`") }
            state = 1
            first = NR + 1
            next
        }
        state == 1 && /^ *"""$/ {
            indent = index($0, "\"") - 1
            state = 2
            next
        }
        state == 1 {
            if (index($0, "\\") > 0) { refuse("a backslash in the MSL: an interpolation or an escape") }
            if (index($0, "\"\"\"") > 0) { refuse("the string does not close on a line of its own") }
            lines[++count] = $0
            next
        }
        state == 2 && /"""/ { refuse("a second multi-line string") }
        state == 2 && /metal_stdlib/ { refuse("MSL outside `source`") }
        END {
            if (failed) { exit 1 }
            if (state != 2) { printf "kernel-sources: %s: no `static let source = \"\"\"` closed by `\"\"\"`\n", file > "/dev/stderr"; exit 1 }
            printf "// Written by scripts/kernel-sources.sh from %s. Do not edit.\n", file
            printf "#ifndef SILLAGE_KERNELS_%s_H\n#define SILLAGE_KERNELS_%s_H\n", library, library
            printf "#include \"msl_compat.h\"\n"
            printf "namespace metal {\nnamespace %s {\n", library
            printf "#include \"msl_begin.h\"\n"
            printf "#line %d \"%s\"\n", first, file
            for (i = 1; i <= count; ++i) {
                line = lines[i]
                if (line ~ /^ *$/) { print ""; continue }
                if (substr(line, 1, indent) !~ /^ *$/) {
                    printf "kernel-sources: %s:%d: a line indented less than the closing quotes\n", file, first + i - 1 > "/dev/stderr"
                    exit 1
                }
                print substr(line, indent + 1)
            }
            printf "#include \"msl_end.h\"\n"
            printf "}  // namespace %s\n}  // namespace metal\n#endif\n", library
        }
    ' "$file" > "$out/$library.h" || { rm -f "$out/$library.h"; exit 1; }
    echo "#include \"$library.h\"" >> "$index"
done
echo "#endif" >> "$index"
