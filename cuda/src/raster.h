// The rasteriser's rules for a point (#276), which the renderer's kernels follow by hand and
// cuda/tests/raster_probe.cu holds to Metal's own, case by case. Included after cuda_cpu.h.
#ifndef SILLAGE_RASTER_H
#define SILLAGE_RASTER_H

#include "msl_compat.h"

namespace metal {

// What Metal's rasteriser does with a point of size s at a clip position, on a target of
// `width` by `height` pixels whose centres sit at half integers. Read off a probe of the M4 Max
// (docs/notes/cuda-engine.md), which these rules give back in each of its 131 cases:
//   - the point is dropped when z < 0 or z > w, when |x| or |y| passes 1.5 w (its centre more
//     than a quarter of the frame outside it), or when s <= 0; a centre outside by less still
//     draws the part of its square that is inside;
//   - its size is capped at 511, and a size under 1 is not raised;
//   - it stands at c = ((x / w + 1) W / 2, (1 - y / w) H / 2), and its square runs from
//     c - s / 2 to c + s / 2 with each edge rounded to 1/256 of a pixel;
//   - it covers the pixels whose centre is in that square, the first edge included and the
//     last not;
//   - point_coord at a pixel is (its centre - the first edge) / span, where the span is the
//     square's side with its two edges rounded to a sixteenth of a pixel instead.
constexpr float largestPoint = 511.0f;

struct Square {
    float2 first;
    float2 span;
    int left;
    int right;
    int top;
    int bottom;
};

// The first pixel whose centre is at or past an edge.
static __device__ __forceinline__ int pixelEdge(float edge, uint side) {
    return int(min(max(ceilf(edge - 0.5f), 0.0f), float(side)));
}

static __device__ __forceinline__ float snapped(float at, float steps) { return rintf(at * steps) / steps; }

static __device__ __forceinline__ bool pointSquare(float4 clip, float pointSize, uint width, uint height,
                                                   Square &square) {
    float w = clip.w;
    if (!(w > 0.0f) || !(pointSize > 0.0f)) { return false; }
    if (!(clip.z >= 0.0f && clip.z <= w && fabsf(clip.x) <= 1.5f * w && fabsf(clip.y) <= 1.5f * w)) { return false; }
    float reach = min(pointSize, largestPoint) / 2.0f;
    float2 centre((clip.x / w + 1.0f) * float(width) / 2.0f, (1.0f - clip.y / w) * float(height) / 2.0f);
    float2 last(snapped(centre.x + reach, 256.0f), snapped(centre.y + reach, 256.0f));
    square.first = float2(snapped(centre.x - reach, 256.0f), snapped(centre.y - reach, 256.0f));
    square.span = float2(snapped(centre.x + reach, 16.0f) - snapped(centre.x - reach, 16.0f),
                         snapped(centre.y + reach, 16.0f) - snapped(centre.y - reach, 16.0f));
    square.left = pixelEdge(square.first.x, width);
    square.right = pixelEdge(last.x, width);
    square.top = pixelEdge(square.first.y, height);
    square.bottom = pixelEdge(last.y, height);
    return square.left < square.right && square.top < square.bottom;
}

// Where a pixel sits in the point's square, from 0 to 1 on each axis: Metal's point_coord.
static __device__ __forceinline__ float2 pointCoord(const Square &square, int x, int y) {
    return (float2(float(x) + 0.5f, float(y) + 0.5f) - square.first) / square.span;
}

}  // namespace metal

#endif
