/* The black hole close up (#336): the kernels of HoleShaders that step the torn cloud's tracers
 * with the gas's grid, and the splat that draws them where the hole shows them. The order of a
 * frame's draws is not here: HoleSplats, in Swift, gives the uniforms of each image to Metal and
 * to CUDA alike. Included by sillage_cuda.h.
 *
 * The grid's sums are 64-bit fixed point in the shared MSL itself (#332), and the splats add into
 * the renderer's own fixed point light (#276): a step and a frame are the same to the bit
 * however the threads run. Parameters come as the bytes of the structs the MSL reads
 * (HoleStepParams, HoleSplatUniforms); a size that is not the MSL's is refused. Every kernel runs
 * on the CPU target. */
#ifndef SILLAGE_CUDA_HOLE_H
#define SILLAGE_CUDA_HOLE_H

#ifdef __cplusplus
extern "C" {
#endif

/* A run's buffers, which the caller keeps. */
typedef struct sc_hole_run {
    /* A float4 a tracer: its position and the light it gives. */
    sc_buffer *positions;
    /* A float4 a tracer: its velocity and the tracers per unit area round it, -1 once
     * swallowed. */
    sc_buffer *velocities;
    /* Eight 32-bit words a cell of the grid: four sums as 64-bit fixed point. */
    sc_buffer *fixed;
    /* A float4 a cell: the sums as floats. */
    sc_buffer *grid;
    /* A float a column of the grid, its cells summed over every height. */
    sc_buffer *column;
} sc_hole_run;

/* `steps` steps of TidalRun.step: the grid emptied, the tracers deposited, the sums resolved and
 * summed by column, then each tracer stepped. */
sc_status sc_hole_step(const sc_hole_run *run, const void *params, size_t length, uint32_t steps);

/* One draw of holeSplatVertex over `count` tracers into `light`, four 64-bit fixed point values a
 * supersampled pixel (sc_render_fixed_unit() is one), `width` by `height`, rows from the top, as
 * Metal blends it into its rgba16Float target. The lens tables, float4 entries, may be NULL when
 * the uniforms draw straight. */
sc_status sc_hole_splat(sc_buffer *light, uint32_t width, uint32_t height, const sc_buffer *positions,
                        const sc_buffer *velocities, uint32_t count, const void *uniforms, size_t length,
                        const sc_buffer *lens, const sc_buffer *far_lens);

/* The light as four floats a pixel, what the post-processing reads. */
sc_status sc_hole_finish(const sc_buffer *light, sc_buffer *values, uint32_t width, uint32_t height);

#ifdef __cplusplus
}
#endif

#endif
