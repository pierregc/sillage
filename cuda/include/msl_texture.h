// Textures a shared function reads, as the CUDA engine holds them (#276): float texels in
// device memory, read by hand with the filter Metal's sampler names. Metal's own filters are
// its GPU's; these are the textbook ones, and docs/notes/cuda-engine.md says how far apart the
// two land. Included by msl_compat.h, inside nothing.
#ifndef SILLAGE_MSL_TEXTURE_H
#define SILLAGE_MSL_TEXTURE_H

namespace metal {

// Level 0 first, each level's rows from the top, `channels` floats a texel. `offset` is where
// each level starts, in texels; a level is half the one before on each side, never under 1.
struct texels2d {
    const float *texels;
    uint width;
    uint height;
    uint channels;
    uint levels;
    uint offset[16];
};

MSL_API texels2d texels2d_of(const float *texels, uint width, uint height, uint channels,
                             uint levels = 1u) {
    texels2d t;
    t.texels = texels;
    t.width = width;
    t.height = height;
    t.channels = channels;
    t.levels = levels < 16u ? levels : 16u;
    uint start = 0u;
    for (uint level = 0u; level < 16u; ++level) {
        t.offset[level] = start;
        uint w = max(width >> level, 1u);
        uint h = max(height >> level, 1u);
        start += w * h;
    }
    return t;
}

// A texel as Metal returns one: the channels a texture lacks read 0, and its alpha 1.
MSL_API float4 texel(const texels2d &t, uint level, uint x, uint y) {
    uint w = max(t.width >> level, 1u);
    const float *at = t.texels + size_t(t.offset[level] + y * w + x) * t.channels;
    float4 value(0.0f, 0.0f, 0.0f, 1.0f);
    for (uint c = 0u; c < t.channels && c < 4u; ++c) { value[int(c)] = at[c]; }
    return value;
}

MSL_API uint texel_clamped(float at, uint side) {
    return uint(min(max(at, 0.0f), float(side - 1u)));
}

MSL_API uint texel_wrapped(float at, uint side) {
    float turns = floorf(at / float(side));
    return min(uint(at - turns * float(side)), side - 1u);
}

// filter::nearest, address::clamp_to_edge, coord::normalized.
MSL_API float4 sample_nearest(const texels2d &t, float2 uv) {
    return texel(t, 0u, texel_clamped(floorf(uv.x * float(t.width)), t.width),
                 texel_clamped(floorf(uv.y * float(t.height)), t.height));
}

// filter::linear over one level; the neighbours past an edge are the edge's own texels, or
// the other side's when the texture repeats.
MSL_API float4 sample_linear_level(const texels2d &t, float2 uv, uint level, bool repeats) {
    uint w = max(t.width >> level, 1u);
    uint h = max(t.height >> level, 1u);
    float x = uv.x * float(w) - 0.5f;
    float y = uv.y * float(h) - 0.5f;
    float left = floorf(x);
    float top = floorf(y);
    float across = x - left;
    float down = y - top;
    uint x0, x1, y0, y1;
    if (repeats) {
        x0 = texel_wrapped(left, w);
        x1 = texel_wrapped(left + 1.0f, w);
        y0 = texel_wrapped(top, h);
        y1 = texel_wrapped(top + 1.0f, h);
    } else {
        x0 = texel_clamped(left, w);
        x1 = texel_clamped(left + 1.0f, w);
        y0 = texel_clamped(top, h);
        y1 = texel_clamped(top + 1.0f, h);
    }
    return mix(mix(texel(t, level, x0, y0), texel(t, level, x1, y0), across),
               mix(texel(t, level, x0, y1), texel(t, level, x1, y1), across), down);
}

// filter::linear, address::clamp_to_edge, coord::normalized, the first level.
MSL_API float4 sample_bilinear(const texels2d &t, float2 uv) {
    return sample_linear_level(t, uv, 0u, false);
}

// filter::linear, mip_filter::linear, address::repeat at a level of detail.
MSL_API float4 sample_trilinear(const texels2d &t, float2 uv, float lod) {
    float last = float(t.levels - 1u);
    float at = min(max(lod, 0.0f), last);
    uint fine = uint(at);
    uint coarse = min(fine + 1u, t.levels - 1u);
    float4 value = sample_linear_level(t, uv, fine, true);
    if (coarse == fine) { return value; }
    return mix(value, sample_linear_level(t, uv, coarse, true), at - float(fine));
}

// filter::linear, mip_filter::linear, address::repeat, max_anisotropy(most), with the
// footprint's two axes in normalised coordinates, as gradient2d gives them: taps along the
// longer axis, at the level of detail the shorter one asks for.
MSL_API float4 sample_anisotropic(const texels2d &t, float2 uv, float2 dx, float2 dy, float most) {
    float2 size(float(t.width), float(t.height));
    float along = length(dx * size);
    float across = length(dy * size);
    float2 axis = dx;
    if (across > along) {
        float swapped = along;
        along = across;
        across = swapped;
        axis = dy;
    }
    float taps = min(max(ceilf(along / max(across, 1e-12f)), 1.0f), max(most, 1.0f));
    float lod = log2f(max(along / taps, 1e-12f));
    float4 total(0.0f);
    uint count = uint(taps);
    for (uint tap = 0u; tap < count; ++tap) {
        float share = (float(tap) + 0.5f) / taps - 0.5f;
        total += sample_trilinear(t, uv + axis * share, lod);
    }
    return total / taps;
}

}  // namespace metal

#endif
