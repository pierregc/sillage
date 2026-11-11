/* The renderer's particle passes (#276): what Metal's rasteriser draws with the vertex and
 * fragment functions of Shaders, as compute kernels. A kernel a pass, a thread a particle: the
 * shared per-particle function says where the point lands and what it carries, the kernel walks
 * the pixels of its square, and the shared per-pixel function says what each one takes.
 * Included by sillage_cuda.h.
 *
 * The light and the dust accumulate as 64-bit fixed point through integer atomics, exact and
 * free of the order the threads run in: a frame drawn twice is the same to the bit. Every
 * kernel here runs on the CPU target too. docs/notes/cuda-engine.md. */
#ifndef SILLAGE_CUDA_RENDER_H
#define SILLAGE_CUDA_RENDER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_renderer sc_renderer;

typedef struct sc_render_config {
    /* The supersampled light and dust, in pixels. */
    uint32_t width;
    uint32_t height;
    /* The column density's cells. */
    uint32_t column_width;
    uint32_t column_height;
    /* The dust web's coarse carrier and its tags; 0 by 0 for a renderer that draws no web. */
    uint32_t carrier_width;
    uint32_t carrier_height;
    /* Texels on a side of the baked lace, a power of two; 0 without the web. */
    uint32_t lace_texels;
    /* Splats the second way can set aside in one pass; 0 for the first way alone. */
    uint32_t large_capacity;
} sc_render_config;

/* FramePlan.Pass, in its order. */
typedef enum sc_render_pass {
    SC_RENDER_COLUMN = 0,
    SC_RENDER_WEB_CARRIER = 1,
    SC_RENDER_STARFIELD = 2,
    SC_RENDER_DUST = 3,
    SC_RENDER_PAINTED_DUST = 4,
    SC_RENDER_WEB_RESOLVE = 5,
    SC_RENDER_STARS = 6,
    SC_RENDER_PLAIN = 7
} sc_render_pass;

typedef enum sc_render_target {
    /* float4 a pixel, rows from the top: the light and its coverage, after sc_render_finish. */
    SC_RENDER_LIGHT = 0,
    /* float4 a pixel: the dust of the four depth slabs, once a pass has read it or after
     * sc_render_finish. */
    SC_RENDER_DUST_TARGET = 1,
    /* A float a cell: the emitting particles counted there. */
    SC_RENDER_COLUMN_TARGET = 2,
    /* float4 a coarse pixel: the dust handed to the web, slab by slab. */
    SC_RENDER_CARRIER = 3,
    /* float4 a coarse pixel: the galaxy that carried dust into each slab plus one, over 255. */
    SC_RENDER_TAGS = 4,
    /* The baked lace, a float a texel, level after level down to one texel. */
    SC_RENDER_LACE = 5,
    /* The light and the dust as they accumulate: four 64-bit fixed point values a pixel. */
    SC_RENDER_LIGHT_FIXED = 6,
    SC_RENDER_DUST_FIXED = 7
} sc_render_target;

/* The massive particles, as Metal binds them: 16 bytes a position from positions_offset, a
 * float2 a trait, 4 bytes a value elsewhere. The renderer keeps the pointers, not the buffers. */
typedef struct sc_render_massive {
    const sc_buffer *positions;
    size_t positions_offset;
    const sc_buffer *population;
    const sc_buffer *formation;
    const sc_buffer *luminosity;
    const sc_buffer *component;
    const sc_buffer *galaxy;
    const sc_buffer *smoothing;
    const sc_buffer *traits;
    const sc_buffer *ramp_keys;
    uint32_t count;
} sc_render_massive;

/* The light tracers (#238): a float4 a state, four 32-bit words a motion of which the last is
 * the tracer's word, the massive tree's spacing records with the frame they are read in and its
 * depth (cells NULL before there is a tree), and each galaxy's scale length. */
typedef struct sc_render_tracers {
    const sc_buffer *states;
    const sc_buffer *words;
    const sc_buffer *cells;
    const sc_buffer *tree_frame;
    uint32_t depth;
    uint32_t count;
    float scales[16];
} sc_render_tracers;

sc_status sc_renderer_create(sc_context *context, const sc_render_config *config,
                             sc_renderer **renderer);
void sc_renderer_destroy(sc_renderer *renderer);

/* StellarPopulation.table: a float2 a sample. */
sc_status sc_render_set_stellar(sc_renderer *renderer, const float *table, uint32_t samples);
/* BackgroundStar, 32 bytes each. */
sc_status sc_render_set_starfield(sc_renderer *renderer, const void *stars, uint32_t count);
/* Bakes the lace and its levels, once, and gives its mean. */
sc_status sc_render_bake_lace(sc_renderer *renderer, float *mean);
/* Splats whose square covers more than `threshold` pixels are set aside and drawn a block
 * each, the second way; 0 draws every splat from its particle's thread, the first way. */
sc_status sc_render_set_large(sc_renderer *renderer, uint32_t threshold);

/* 1 accumulates the light, the dust and the carrier as half floats, blended as Metal blends
 * its rgba16Float targets: the measure of what they lose (#283). The result then depends on
 * the order the threads run in, and the fixed targets hold a half's bits a value. Set before
 * a frame is cleared. */
sc_status sc_render_set_half_floats(sc_renderer *renderer, int32_t halves);

/* Either may be NULL. */
sc_status sc_render_set_particles(sc_renderer *renderer, const sc_render_massive *massive,
                                  const sc_render_tracers *tracers);
/* DiskFrame, 128 bytes a galaxy, and GalaxyRamp, 112 bytes a galaxy slot. */
sc_status sc_render_set_frame(sc_renderer *renderer, const void *disk_frames,
                              uint32_t frame_count, const void *ramps, uint32_t ramp_count);

/* Empties the light and the dust. */
sc_status sc_render_clear(sc_renderer *renderer);
/* What a pass needs done once before its particles are drawn: the targets it fills alone
 * emptied, the ones it reads brought up to date. */
sc_status sc_render_begin(sc_renderer *renderer, sc_render_pass pass);
/* Draws a pass over a range of the massive particles, then of the tracers: SplatUniforms with
 * its length, WebUniforms with its length for the web's passes. The column, the field stars,
 * the web's resolve and the plain points take no range of their own: the column and the plain
 * points draw the ranges given, which their callers make everything. After sc_render_begin,
 * calls for parts of one pass may run at once from several threads on the first way. */
sc_status sc_render_draw(sc_renderer *renderer, sc_render_pass pass, const void *splat_uniforms,
                         size_t splat_length, const void *web_uniforms, size_t web_length,
                         uint32_t massive_first, uint32_t massive_count, uint32_t tracer_first,
                         uint32_t tracer_count);
/* Brings SC_RENDER_LIGHT and SC_RENDER_DUST_TARGET up to date. */
sc_status sc_render_finish(sc_renderer *renderer);
/* A target of the renderer, which owns it. NULL for one this renderer does not have. */
sc_buffer *sc_render_target_of(sc_renderer *renderer, sc_render_target which);
/* What one unit of light or dust is in SC_RENDER_LIGHT_FIXED and SC_RENDER_DUST_FIXED. */
uint64_t sc_render_fixed_unit(void);
/* Splats set aside by the last pass drawn the second way, those past the capacity included. */
uint32_t sc_render_large_count(const sc_renderer *renderer);

#ifdef __cplusplus
}
#endif

#endif
