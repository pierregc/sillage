// The pixels of a point star's square its box can light (#425). Included after raster.h.
//
// A streak is a thin box turned in a square as wide as the streak is long, and starShare (Shaders)
// gives nothing past the box: a row is walked only where the box crosses it, two pixels to spare
// on each side, so every pixel that takes light is still laid and the frame keeps its bits.
// cuda/tests/star_band.cu holds the band to starShare. A change to the box there changes it here.
#ifndef SILLAGE_BAND_H
#define SILLAGE_BAND_H

#include "raster.h"

namespace metal {

struct Band {
    float2 along;
    float2 reach;
    bool whole;
};

// The star's box in its square's point coordinates, its half lengths along the streak and across
// it. `whole`, or a box that is not a number, walks the whole square.
static __device__ __forceinline__ Band starBand(float2 half_streak, float radius, float pixel, const Square &square,
                                                bool whole) {
    Band band;
    float half_length = length(half_streak);
    band.along = half_length > 1e-9f ? half_streak / half_length : float2(1.0f, 0.0f);
    float margin = 2.0f * max(pixel, max(1.0f / square.span.x, 1.0f / square.span.y));
    band.reach = float2(half_length + radius, radius) + (0.5f * pixel + margin);
    band.whole = whole || !(isfinite(band.along.x) && isfinite(band.along.y) && isfinite(band.reach.x)
                            && isfinite(band.reach.y));
    return band;
}

// Narrows [low, high] to where |k dx + q| < r. The point coordinates of a square's pixels lie
// within a unit of its centre, so a k near zero leaves dx free.
static __device__ __forceinline__ bool bandSlab(float k, float q, float r, float &low, float &high) {
    if (fabsf(k) < 1e-3f) { return fabsf(q) < r + 4.0f * fabsf(k); }
    float a = (-r - q) / k;
    float b = (r - q) / k;
    low = max(low, min(a, b));
    high = min(high, max(a, b));
    return low < high;
}

// The pixels [left, right) of row y the band crosses.
static __device__ __forceinline__ void bandRow(const Band &band, const Square &square, int y, int &left, int &right) {
    left = square.left;
    right = square.right;
    if (band.whole) { return; }
    float dy = (float(y) + 0.5f - square.first.y) / square.span.y - 0.5f;
    float low = -4.0f;
    float high = 4.0f;
    if (!bandSlab(band.along.x, band.along.y * dy, band.reach.x, low, high)
        || !bandSlab(-band.along.y, band.along.x * dy, band.reach.y, low, high)) {
        right = left;
        return;
    }
    float first = float(square.left);
    float last = float(square.right);
    float from = min(max(square.first.x - 0.5f + (low + 0.5f) * square.span.x, first), last);
    float to = min(max(square.first.x - 0.5f + (high + 0.5f) * square.span.x, first), last);
    left = max(square.left, int(floorf(from)) - 1);
    right = max(left, min(square.right, int(ceilf(to)) + 2));
}

static __device__ __forceinline__ uint bandPixels(const Band &band, const Square &square) {
    uint pixels = 0u;
    for (int y = square.top; y < square.bottom; ++y) {
        int left, right;
        bandRow(band, square, y, left, right);
        pixels += uint(right - left);
    }
    return pixels;
}

}  // namespace metal

#endif
