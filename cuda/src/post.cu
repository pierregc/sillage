// The renderer's post-processing on CUDA (#277): the kernels of Shaders that turn the
// supersampled light into the picture. A thread a pixel of the image it writes, calling the
// shared function of the kernel's own arithmetic on textures held as floats in device memory; the
// bilinear filter is msl_texture.h's, Metal's being its GPU's. No block barrier and no shared
// memory, so every kernel here runs on the CPU target.
#include "cuda_cpu.h"

#include "engine.h"
#include "Shaders.h"

namespace metal {
namespace Shaders {

static __device__ __forceinline__ uint2 pixelOfThread() {
    return uint2(blockIdx.x * blockDim.x + threadIdx.x, blockIdx.y * blockDim.y + threadIdx.y);
}

static __device__ __forceinline__ void put(float *image, uint width, uint2 at, float4 value) {
    float *texel = image + (size_t(at.y) * width + at.x) * 4u;
    texel[0] = value.x;
    texel[1] = value.y;
    texel[2] = value.z;
    texel[3] = value.w;
}

__global__ void resolve(texels2d light, float *dst, uint width, uint height, uint factor) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, resolvePixel(light, gid, factor));
}

__global__ void plainComposite(texels2d light, float *output, uint width, uint height, uint factor,
                               float fade) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(output, width, gid, plainCompositePixel(light, gid, factor, fade));
}

__global__ void brightPass(texels2d src, float *dst, uint width, uint height, BloomParams p) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, brightPixel(src, gid, uint2(width, height), p));
}

__global__ void downsample(texels2d src, float *dst, uint width, uint height) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, downsamplePixel(src, gid, uint2(width, height)));
}

__global__ void upsampleAdd(texels2d src, texels2d base, float *dst, uint width, uint height) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, upsamplePixel(src, base, gid, uint2(width, height)));
}

__global__ void compactLight(texels2d point, texels2d broad, float *dst, uint width, uint height,
                             float amount) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, compactPixel(point, broad, gid, uint2(width, height), amount));
}

__global__ void diffractionSpikes(texels2d src, float *dst, uint width, uint height, SpikeParams p) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(dst, width, gid, spikesPixel(src, gid, uint2(width, height), p));
}

__global__ void composite(texels2d hdr, texels2d bloom, texels2d spikes, float *output, uint width,
                          uint height, CompositeParams p) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    put(output, width, gid, compositePixel(hdr, bloom, spikes, gid, uint2(width, height), p));
}

// What Metal's rgba8Unorm write does to a value: clamped to 0 and 1, a number that is not one
// read as 0, and rounded to nearest, ties to even.
static __device__ __forceinline__ unsigned char unorm8(float value) {
    if (!(value > 0.0f)) { return 0u; }
    return (unsigned char)(rintf(min(value, 1.0f) * 255.0f));
}

// The picture as bytes, a thread a pixel. `format` is sc_post_format.
__global__ void packPixels(const float *image, unsigned char *bytes, uint width, uint height, uint format) {
    uint2 gid = pixelOfThread();
    if (gid.x >= width || gid.y >= height) { return; }
    const float *texel = image + (size_t(gid.y) * width + gid.x) * 4u;
    unsigned char red = unorm8(texel[0]);
    unsigned char green = unorm8(texel[1]);
    unsigned char blue = unorm8(texel[2]);
    size_t pixel = size_t(gid.y) * width + gid.x;
    if (format == 0u) {
        unsigned char *at = bytes + pixel * 3u;
        at[0] = red;
        at[1] = green;
        at[2] = blue;
    } else {
        unsigned char *at = bytes + pixel * 4u;
        at[0] = format == 2u ? blue : red;
        at[1] = green;
        at[2] = format == 2u ? red : blue;
        at[3] = 255u;
    }
}

}  // namespace Shaders
}  // namespace metal

namespace sh = metal::Shaders;

namespace sillage {
namespace post {

constexpr unsigned side = 16u;

#define LAUNCH(kernel, width, height, ...)                                                     \
    do {                                                                                       \
        SILLAGE_LAUNCH(sh::kernel, dim3((width + side - 1u) / side, (height + side - 1u) / side), \
                       dim3(side, side), __VA_ARGS__);                                         \
        if (sc_status launched = check(cudaGetLastError(), #kernel)) { return launched; }      \
    } while (0)

// Whether the image is a texture of its own size in a buffer that holds it.
static sc_status valid(const sc_post_image *image, const char *name, const char *what) {
    if (!image || !image->texels) { return fail(SC_INVALID_ARGUMENT, "%s: no %s", name, what); }
    if (image->width == 0u || image->height == 0u) {
        return fail(SC_INVALID_ARGUMENT, "%s: the %s is empty", name, what);
    }
    if (!holds(image->texels, 0u, size_t(image->width) * image->height * 16u)) {
        return fail(SC_INVALID_ARGUMENT, "%s: the %s of %u by %u does not fit its buffer", name, what,
                    image->width, image->height);
    }
    return SC_OK;
}

static sh::texels2d texture(const sc_post_image *image) {
    return metal::texels2d_of(pointer<const float>(image->texels), image->width, image->height, 4u);
}

static sc_status sized(const void *params, size_t bytes, size_t expected, const char *name) {
    if (!params || bytes != expected) {
        return fail(SC_INVALID_ARGUMENT, "%s: parameters of %zu bytes, the MSL reads %zu", name, bytes,
                    expected);
    }
    return SC_OK;
}

template <class T>
static T parameters(const void *params) {
    T value;
    memcpy(&value, params, sizeof(T));
    return value;
}

}  // namespace post
}  // namespace sillage

using namespace sillage;
using namespace sillage::post;

extern "C" {

sc_status sc_post_resolve(const sc_post_image *light, const sc_post_image *dst, uint32_t factor) {
    if (sc_status status = valid(light, "sc_post_resolve", "light")) { return status; }
    if (sc_status status = valid(dst, "sc_post_resolve", "destination")) { return status; }
    if (factor == 0u || light->width != dst->width * factor || light->height != dst->height * factor) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_resolve: %u by %u is not %u times %u by %u", light->width,
                    light->height, factor, dst->width, dst->height);
    }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(resolve, dst->width, dst->height, texture(light), pointer<float>(dst->texels), dst->width,
           dst->height, factor);
    return SC_OK;
}

sc_status sc_post_plain_composite(const sc_post_image *light, const sc_post_image *dst, uint32_t factor,
                                  float fade) {
    if (sc_status status = valid(light, "sc_post_plain_composite", "light")) { return status; }
    if (sc_status status = valid(dst, "sc_post_plain_composite", "destination")) { return status; }
    if (factor == 0u || light->width != dst->width * factor || light->height != dst->height * factor) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_plain_composite: %u by %u is not %u times %u by %u",
                    light->width, light->height, factor, dst->width, dst->height);
    }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(plainComposite, dst->width, dst->height, texture(light), pointer<float>(dst->texels), dst->width,
           dst->height, factor, fade);
    return SC_OK;
}

sc_status sc_post_bright(const sc_post_image *src, const sc_post_image *dst, const void *params,
                         size_t bytes) {
    if (sc_status status = valid(src, "sc_post_bright", "source")) { return status; }
    if (sc_status status = valid(dst, "sc_post_bright", "destination")) { return status; }
    if (sc_status status = sized(params, bytes, sizeof(sh::BloomParams), "sc_post_bright")) { return status; }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(brightPass, dst->width, dst->height, texture(src), pointer<float>(dst->texels), dst->width,
           dst->height, parameters<sh::BloomParams>(params));
    return SC_OK;
}

sc_status sc_post_downsample(const sc_post_image *src, const sc_post_image *dst) {
    if (sc_status status = valid(src, "sc_post_downsample", "source")) { return status; }
    if (sc_status status = valid(dst, "sc_post_downsample", "destination")) { return status; }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(downsample, dst->width, dst->height, texture(src), pointer<float>(dst->texels), dst->width,
           dst->height);
    return SC_OK;
}

sc_status sc_post_upsample(const sc_post_image *src, const sc_post_image *base, const sc_post_image *dst) {
    if (sc_status status = valid(src, "sc_post_upsample", "source")) { return status; }
    if (sc_status status = valid(base, "sc_post_upsample", "base")) { return status; }
    if (sc_status status = valid(dst, "sc_post_upsample", "destination")) { return status; }
    if (base->width != dst->width || base->height != dst->height) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_upsample: the base is %u by %u, the destination %u by %u",
                    base->width, base->height, dst->width, dst->height);
    }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(upsampleAdd, dst->width, dst->height, texture(src), texture(base), pointer<float>(dst->texels),
           dst->width, dst->height);
    return SC_OK;
}

sc_status sc_post_compact(const sc_post_image *point, const sc_post_image *broad, const sc_post_image *dst,
                          float amount) {
    if (sc_status status = valid(point, "sc_post_compact", "point source")) { return status; }
    if (sc_status status = valid(broad, "sc_post_compact", "broad source")) { return status; }
    if (sc_status status = valid(dst, "sc_post_compact", "destination")) { return status; }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(compactLight, dst->width, dst->height, texture(point), texture(broad), pointer<float>(dst->texels),
           dst->width, dst->height, amount);
    return SC_OK;
}

sc_status sc_post_spikes(const sc_post_image *src, const sc_post_image *dst, const void *params,
                         size_t bytes) {
    if (sc_status status = valid(src, "sc_post_spikes", "source")) { return status; }
    if (sc_status status = valid(dst, "sc_post_spikes", "destination")) { return status; }
    if (sc_status status = sized(params, bytes, sizeof(sh::SpikeParams), "sc_post_spikes")) { return status; }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(diffractionSpikes, dst->width, dst->height, texture(src), pointer<float>(dst->texels), dst->width,
           dst->height, parameters<sh::SpikeParams>(params));
    return SC_OK;
}

sc_status sc_post_composite(const sc_post_image *hdr, const sc_post_image *bloom, const sc_post_image *spikes,
                            const sc_post_image *dst, const void *params, size_t bytes) {
    if (sc_status status = valid(hdr, "sc_post_composite", "frame")) { return status; }
    if (sc_status status = valid(bloom, "sc_post_composite", "bloom")) { return status; }
    if (sc_status status = valid(spikes, "sc_post_composite", "spikes")) { return status; }
    if (sc_status status = valid(dst, "sc_post_composite", "destination")) { return status; }
    if (sc_status status = sized(params, bytes, sizeof(sh::CompositeParams), "sc_post_composite")) {
        return status;
    }
    if (hdr->width != dst->width || hdr->height != dst->height) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_composite: the frame is %u by %u, the destination %u by %u",
                    hdr->width, hdr->height, dst->width, dst->height);
    }
    if (sc_status status = use(dst->texels->context)) { return status; }
    LAUNCH(composite, dst->width, dst->height, texture(hdr), texture(bloom), texture(spikes),
           pointer<float>(dst->texels), dst->width, dst->height, parameters<sh::CompositeParams>(params));
    return SC_OK;
}

sc_status sc_post_pack(const sc_post_image *image, sc_buffer *bytes, sc_post_format format) {
    if (sc_status status = valid(image, "sc_post_pack", "image")) { return status; }
    if (format != SC_POST_RGB && format != SC_POST_RGBA && format != SC_POST_BGRA) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_pack: format %d is not one", int(format));
    }
    size_t needed = size_t(image->width) * image->height * (format == SC_POST_RGB ? 3u : 4u);
    if (!bytes || !holds(bytes, 0u, needed)) {
        return fail(SC_INVALID_ARGUMENT, "sc_post_pack: a buffer of %zu bytes is needed", needed);
    }
    if (sc_status status = use(image->texels->context)) { return status; }
    LAUNCH(packPixels, image->width, image->height, pointer<const float>(image->texels),
           pointer<unsigned char>(bytes), image->width, image->height, uint32_t(format));
    return SC_OK;
}

}  // extern "C"
