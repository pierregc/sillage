/* The Barnes-Hut solver: the kernels of BarnesHutShaders that step the massive particles (#274)
 * and the light tracers (#275), a call a pass. The order of a step is not here: BarnesHutStep, in
 * Swift, runs these passes as it runs Metal's. Included by sillage_cuda.h.
 *
 * A pass takes its parameters as the bytes of the struct the shared MSL reads (BHParams,
 * SFParams, TracerStepParams) and its lists as the bytes of their elements (HaloGPU, HoleGPU,
 * DiskCooling), which Swift fills as it fills Metal's; a size that is not the MSL's is refused.
 * Every pass runs on the CPU target. */
#ifndef SILLAGE_CUDA_SOLVER_H
#define SILLAGE_CUDA_SOLVER_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_solver sc_solver;

typedef struct sc_solver_config {
    /* The massive particles, at least 1. */
    uint32_t massive;
    /* Their first in the position and velocity buffers, after as many light tracers (#275). */
    uint32_t first;
    int32_t quadrupole;
    int32_t opens_holding_cells;
    /* Star formation also writes each leaf's chance, for the light tracers' gas (#275). */
    int32_t leaf_chances;
} sc_solver_config;

/* The particles' buffers, which the caller keeps alive for as long as the solver. */
typedef struct sc_solver_buffers {
    /* 16 bytes a particle, the massive ones from `first`: a float3 each, and before them each
     * light tracer's position with its formation time in w, then its velocity with its
     * TracerWord in w (#238). */
    sc_buffer *positions;
    sc_buffer *velocities;
    /* A float3 a massive particle. */
    sc_buffer *accelerations;
    /* A float a massive particle: the masses the tree is built over, a black hole's 0. */
    sc_buffer *mass;
    /* A float4 a massive particle, by Morton slot: what the tree build gathers. */
    sc_buffer *sorted;
    /* A float a massive particle: when its stars formed. */
    sc_buffer *formation;
    /* A uint a massive particle. */
    sc_buffer *component;
    /* A uint a massive particle; NULL when no disk is cooled. */
    sc_buffer *galaxy;
    /* A uint a massive particle: what each walk cost, by Morton slot. */
    sc_buffer *cost;
    /* A float a massive particle, with leaf_chances; NULL otherwise. */
    sc_buffer *slot_chances;
    /* A uint a light tracer: their walk order, counted from each sort chunk's start; NULL
     * without tracers. */
    sc_buffer *tracer_order;
} sc_solver_buffers;

sc_status sc_solver_create(sc_context *context, const sc_solver_config *config,
                           const sc_solver_buffers *buffers, sc_solver **solver);
void sc_solver_destroy(sc_solver *solver);

/* bhFormStars over the tree's `SFParams.nodeCount` nodes. */
sc_status sc_solver_form_stars(sc_solver *solver, sc_tree *tree, const void *formation, size_t bytes);
/* bhKickDrift. */
sc_status sc_solver_kick_drift(sc_solver *solver, const void *params, size_t bytes);
/* bhGather: the particles into the tree's order, when a tree is used again. */
sc_status sc_solver_gather(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes);
/* bhAcceleration over `slots` Morton slots from `BHParams.chunkStart`, with the analytic halos
 * of `halos`, `halo_count` HaloGPU (at least `BHParams.haloCount`). */
sc_status sc_solver_accelerations(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes,
                                  uint32_t slots, const void *halos, uint32_t halo_count);
/* bhHolePull then bhHoleSettle: `hole_count` HoleGPU, at most 4. */
sc_status sc_solver_holes(sc_solver *solver, const void *params, size_t bytes, const void *holes,
                          uint32_t hole_count, const void *halos, uint32_t halo_count);
/* bhKick. */
sc_status sc_solver_kick(sc_solver *solver, const void *params, size_t bytes);
/* bhDissipate towards `disk_count` DiskCooling, one a galaxy. */
sc_status sc_solver_dissipate(sc_solver *solver, const void *params, size_t bytes, const void *disks,
                              uint32_t disk_count);

/* The light tracers (#275). bhTracerDrift over `BHParams.particleCount` of them. */
sc_status sc_solver_tracer_drift(sc_solver *solver, const void *params, size_t bytes);
/* bhTracerFormStars: the tracers' gas at the chances the massive pass just wrote into the slot
 * chances, found by the tracers' Morton codes in the tree's frame. */
sc_status sc_solver_tracer_form_stars(sc_solver *solver, sc_tree *tree, const void *formation,
                                      size_t bytes);
/* bhTracerStep over `slots` of the walk order from `TracerStepParams.chunkStart`: the walk
 * through the tree, the analytic halos of `halos`, the black holes of `holes` (at most 4) and
 * the cooling towards `disks`, each list at least as long as the parameters say. Mode 2 writes
 * each tracer's acceleration into `probe`, a float3 a tracer, and moves nothing. */
sc_status sc_solver_tracer_step(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes,
                                uint32_t slots, const void *halos, uint32_t halo_count,
                                const void *holes, uint32_t hole_count, const void *disks,
                                uint32_t disk_count, sc_buffer *probe);

#ifdef __cplusplus
}
#endif

#endif
