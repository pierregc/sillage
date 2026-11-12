/* The post-processing of a frame (#277): the kernels of Shaders that turn the supersampled light
 * into the picture, a call each, and the pass that packs it into 8-bit bytes. The order of the
 * passes is not here: PostPlan, in Swift, gives it to Metal and to CUDA alike. Included by
 * sillage_cuda.h.
 *
 * An image is four floats a texel, rows from the top, in device memory: what sc_render_finish
 * leaves of the light, and what each pass writes in fp32 where Metal's textures hold halves.
 * A pass takes its parameters as the bytes of the struct the shared MSL reads (BloomParams,
 * SpikeParams, CompositeParams); a size other than the MSL's is refused. A thread a pixel and
 * no block barrier: every pass runs on the CPU target. */
#ifndef SILLAGE_CUDA_POST_H
#define SILLAGE_CUDA_POST_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_post_image {
    sc_buffer *texels;
    uint32_t width;
    uint32_t height;
} sc_post_image;

/* resolve: the box average of `factor` by `factor` light texels a texel of `dst`. */
sc_status sc_post_resolve(const sc_post_image *light, const sc_post_image *dst, uint32_t factor);
/* plainComposite: the average and the raw look's exposure curve, times `fade`. */
sc_status sc_post_plain_composite(const sc_post_image *light, const sc_post_image *dst,
                                  uint32_t factor, float fade);
/* brightPass, with a BloomParams. */
sc_status sc_post_bright(const sc_post_image *src, const sc_post_image *dst, const void *params,
                         size_t bytes);
/* downsample. */
sc_status sc_post_downsample(const sc_post_image *src, const sc_post_image *dst);
/* upsampleAdd: `src` upsampled, and `base` at the size of `dst` added. */
sc_status sc_post_upsample(const sc_post_image *src, const sc_post_image *base,
                           const sc_post_image *dst);
/* compactLight: `point` less `amount` of `broad`. */
sc_status sc_post_compact(const sc_post_image *point, const sc_post_image *broad,
                          const sc_post_image *dst, float amount);
/* diffractionSpikes, with a SpikeParams. */
sc_status sc_post_spikes(const sc_post_image *src, const sc_post_image *dst, const void *params,
                         size_t bytes);
/* composite, with a CompositeParams. */
sc_status sc_post_composite(const sc_post_image *hdr, const sc_post_image *bloom,
                            const sc_post_image *spikes, const sc_post_image *dst,
                            const void *params, size_t bytes);

typedef enum sc_post_format {
    /* 3 bytes a pixel. */
    SC_POST_RGB = 0,
    /* 4 bytes a pixel, alpha 255. */
    SC_POST_RGBA = 1,
    /* 4 bytes a pixel in the order an encoder's BGRA wants, alpha 255. */
    SC_POST_BGRA = 2
} sc_post_format;

/* The image as 8-bit unsigned normalised values, rounded to nearest even and clamped as Metal
 * writes an rgba8Unorm texture, rows from the top, into `bytes` (width * height times the
 * format's bytes at least). */
sc_status sc_post_pack(const sc_post_image *image, sc_buffer *bytes, sc_post_format format);

#ifdef __cplusplus
}
#endif

#endif
