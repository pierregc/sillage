// The band a point star's streak is walked along (#425), against starShare: every pixel of the
// square that takes light lies in the band, for streaks of every length and slant, straight
// across or up the frame, none at all, and stars wider than a pixel or narrower; and a long
// streak's band is a small part of its square.
#include "cuda_cpu.h"

#include <cmath>
#include <cstdio>

#include "../src/raster.h"
#include "../src/band.h"
#include "Shaders.h"

#if defined(SILLAGE_CPU)

namespace {

struct Random {
    unsigned state;
    float next() {
        state = state * 1664525u + 1013904223u;
        return float(state >> 8) / 16777216.0f;
    }
};

int failures = 0;

}  // namespace

int main() {
    using namespace metal;
    const unsigned width = 1920;
    const unsigned height = 1080;
    Random random{425u};
    const float slants[] = {0.0f, 1.5707964f, 1e-4f, 1.5706964f, 0.7853982f, 3.1415927f, -1.5707964f, 2e-3f};
    long walked = 0;
    long held = 0;
    long lit = 0;
    int stars = 0;
    for (int trial = 0; trial < 4000; ++trial) {
        float size = 0.2f + 8.0f * random.next();
        float travel = trial % 10 == 0 ? 0.0f : 480.0f * random.next() * random.next();
        float slant = trial < 800 ? slants[trial % 8] : 6.2831855f * random.next();
        float2 moved(travel * cosf(slant), travel * sinf(slant));
        float pointSize = travel > 0.0f ? travel + 2.0f * size + 1.5f : size + 1.5f;
        float2 half_streak = 0.5f * float2(moved.x, -moved.y) / pointSize;
        float radius = 0.5f * size / pointSize;
        float pixel = 1.0f / pointSize;
        float4 clip(2.4f * random.next() - 1.2f, 2.4f * random.next() - 1.2f, 0.5f, 1.0f);
        Square square;
        if (!pointSquare(clip, pointSize, width, height, square)) { continue; }
        stars += 1;
        Band band = starBand(half_streak, radius, pixel, square, false);
        if (band.whole) {
            failures += 1;
            std::printf("cuda/tests/star_band.cu: star %d walks its whole square\n", trial);
            continue;
        }
        long counted = 0;
        for (int y = square.top; y < square.bottom; ++y) {
            int left, right;
            bandRow(band, square, y, left, right);
            counted += right - left;
            for (int x = square.left; x < square.right; ++x) {
                float share = Shaders::starShare(pointCoord(square, x, y), half_streak, radius, pixel);
                if (share <= 0.0f) { continue; }
                lit += 1;
                if (x < left || x >= right) {
                    failures += 1;
                    if (failures < 10) {
                        std::printf("cuda/tests/star_band.cu: star %d (size %g, streak %g at %g) lights (%d, %d) "
                                    "outside its band [%d, %d)\n",
                                    trial, size, travel, slant, x, y, left, right);
                    }
                }
            }
        }
        if (long(bandPixels(band, square)) != counted) {
            failures += 1;
            std::printf("cuda/tests/star_band.cu: star %d counts its band two ways\n", trial);
        }
        walked += counted;
        held += long(square.right - square.left) * long(square.bottom - square.top);
    }
    // Streaks of up to 480 pixels, most of them short: the band holds a few times the lit
    // pixels and a fraction of the squares'.
    if (!(stars > 3000 && walked * 4 < held && walked < 4 * lit)) {
        failures += 1;
        std::printf("cuda/tests/star_band.cu: %d stars, %ld pixels walked of %ld, %ld lit\n", stars, walked, held,
                    lit);
    }
    std::printf("cuda/tests/star_band.cu: %d stars, the bands walk %ld pixels of the squares' %ld, %ld lit\n", stars,
                walked, held, lit);
    return failures == 0 ? 0 : 1;
}

#else
int main() { return 0; }
#endif
