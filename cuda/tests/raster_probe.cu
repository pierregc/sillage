// Metal's rasteriser, case by case (#276): Tests/Fixtures/engines/raster/probe.txt is what an
// Apple M4 Max does with one point at 131 clip positions and sizes, and pointSquare, which the
// renderer's kernels cover a point's pixels with, has to give each of them: whether the point
// is drawn, how many pixels it covers, the box they fill, and point_coord at the first and the
// last of them.
#include "cuda_cpu.h"

#include <cmath>
#include <cstdio>
#include <cstring>

#include "../src/raster.h"

#if defined(SILLAGE_CPU)

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "Tests/Fixtures/engines/raster/probe.txt";
    std::FILE *file = std::fopen(path, "r");
    if (!file) {
        std::printf("cuda/tests/raster_probe.cu: cannot open %s\n", path);
        return 1;
    }
    char line[512];
    int cases = 0;
    int failures = 0;
    float worst = 0.0f;
    while (std::fgets(line, sizeof line, file)) {
        if (line[0] == '#' || line[0] == '\n') { continue; }
        char name[128];
        unsigned width, height;
        float x, y, z, w, size, firstU, firstV, lastU, lastV;
        int covered, firstColumn, lastColumn, firstRow, lastRow;
        int read = std::sscanf(line, "%127s %u %u %f %f %f %f %f %d %d %d %d %d %f %f %f %f", name, &width, &height,
                               &x, &y, &z, &w, &size, &covered, &firstColumn, &lastColumn, &firstRow, &lastRow,
                               &firstU, &firstV, &lastU, &lastV);
        if (read != 17) {
            std::printf("cuda/tests/raster_probe.cu: cannot read the case %s", line);
            failures += 1;
            continue;
        }
        cases += 1;
        metal::Square square;
        bool drawn = metal::pointSquare(metal::float4(x, y, z, w), size, width, height, square);
        int pixels = drawn ? (square.right - square.left) * (square.bottom - square.top) : 0;
        if (pixels != covered) {
            std::printf("  %s: Metal covers %d pixels, pointSquare %d\n", name, covered, pixels);
            failures += 1;
            continue;
        }
        if (covered == 0 || firstColumn < 0) { continue; }
        if (square.left != firstColumn || square.right - 1 != lastColumn || square.top != firstRow
            || square.bottom - 1 != lastRow) {
            std::printf("  %s: Metal covers columns %d to %d and rows %d to %d, pointSquare %d to %d and %d to %d\n",
                        name, firstColumn, lastColumn, firstRow, lastRow, square.left, square.right - 1, square.top,
                        square.bottom - 1);
            failures += 1;
            continue;
        }
        if (firstU < 0.0f) { continue; }
        metal::float2 first = metal::pointCoord(square, square.left, square.top);
        metal::float2 last = metal::pointCoord(square, square.right - 1, square.bottom - 1);
        float off = std::fmax(std::fmax(std::fabs(first.x - firstU), std::fabs(first.y - firstV)),
                              std::fmax(std::fabs(last.x - lastU), std::fabs(last.y - lastV)));
        worst = std::fmax(worst, off);
        if (off > 1e-5f) {
            std::printf("  %s: point_coord off by %g\n", name, double(off));
            failures += 1;
        }
    }
    std::fclose(file);
    if (cases < 100) {
        std::printf("cuda/tests/raster_probe.cu: only %d cases in %s\n", cases, path);
        failures += 1;
    }
    std::printf("cuda/tests/raster_probe.cu: %d cases of Metal's rasteriser, %d off, point_coord within %.2g\n", cases,
                failures, double(worst));
    return failures == 0 ? 0 : 1;
}

#endif
