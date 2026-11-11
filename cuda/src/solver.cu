// The Barnes-Hut solver on CUDA: the entry points of the eight kernels of BarnesHutShaders that
// step the massive particles (#274) and of the three that step the light tracers (#275), and their
// launches, a C call a pass. An entry point works out the thread's position and calls the shared
// function; the arithmetic is the MSL's alone, and the order of a step is BarnesHutStep's, in
// Swift. None of them needs a block barrier or a warp function, so all of them run on the CPU
// target.
#include "cuda_cpu.h"

#include <cstring>
#include <initializer_list>
#include <new>

#include "engine.h"
#include "BarnesHutShaders.h"

namespace metal {
namespace BarnesHutShaders {

__global__ void bhKickDrift(float3 *positions, float3 *velocities, const float3 *accelerations, BHParams p) {
    massiveKickDrift(positions, velocities, accelerations, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void bhKick(float3 *velocities, const float3 *accelerations, BHParams p) {
    massiveKick(velocities, accelerations, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void bhDissipate(const float3 *positions, float3 *velocities, const float3 *accelerations,
                            const uint *component, const uint *galaxy, const DiskCooling *disks, BHParams p) {
    massiveDissipate(positions, velocities, accelerations, component, galaxy, disks, p,
                     blockIdx.x * blockDim.x + threadIdx.x);
}

// Metal's function constant bhLeafChances is the template parameter.
template <bool leafChances>
__global__ void bhFormStars(float *formation, const uint *component, const float *mass, const BHNode *nodes,
                            const uint *order, SFParams s, const float3 *positions, const float3 *velocities,
                            float *slotChances) {
    massiveFormStars(formation, component, mass, nodes, order, s, positions, velocities, slotChances,
                     leafChances, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void bhGather(float4 *sorted, const float3 *positions, const float *mass, const uint *order,
                         BHParams p) {
    massiveGather(sorted, positions, mass, order, p, blockIdx.x * blockDim.x + threadIdx.x);
}

// A thread a block of `width` particles, where Metal has a thread a particle and sums each
// threadgroup behind a barrier: holePullBlock adds the same reactions in the particles' order.
__global__ void bhHolePull(const float3 *positions, float3 *accelerations, const float *mass,
                           const uint *component, const HoleGPU *holes, uint holeCount, BHParams p,
                           float4 *partial, uint width) {
    holePullBlock(positions, accelerations, mass, component, holes, holeCount, p, partial,
                  blockIdx.x * blockDim.x + threadIdx.x, width);
}

__global__ void bhHoleSettle(const float3 *positions, float3 *accelerations, const HoleGPU *holes,
                             uint holeCount, uint groups, const float4 *partial, const HaloGPU *haloList,
                             BHParams p) {
    holeSettle(positions, accelerations, holes, holeCount, groups, partial, haloList, p,
               blockIdx.x * blockDim.x + threadIdx.x);
}

// Metal's function constants bhQuadrupole and bhOpensHoldingCells are the template parameters.
// A piece of the pass is `slots` threads on Metal; a CUDA grid is whole blocks, so the threads past
// the piece stop here rather than walk the next piece's first slots again.
template <bool quadrupole, bool opensHoldingCells>
__global__ void bhAcceleration(const float4 *sorted, float3 *accelerations, const BHNode *nodes,
                               const uint *order, const HaloGPU *haloList, BHParams p, uint *cost,
                               const float4 *moments, const ulong *codes, uint slots) {
    uint gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= slots) { return; }
    massiveAcceleration(sorted, accelerations, nodes, order, haloList, p, cost, moments, codes, quadrupole,
                        opensHoldingCells, gid);
}

__global__ void bhTracerFormStars(float4 *states, const uint4 *motions, const ulong *codes, const float *frame,
                                  const float *slotChances, SFParams s, uint2 counts) {
    tracerFormStars(states, motions, codes, frame, slotChances, s, counts, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void bhTracerDrift(float4 *states, const uint4 *motions, BHParams p) {
    tracerDrift(states, motions, p, blockIdx.x * blockDim.x + threadIdx.x);
}

// bhAcceleration's template parameters and bound again: a tracer walked twice would be kicked twice.
template <bool quadrupole, bool opensHoldingCells>
__global__ void bhTracerStep(float4 *states, uint4 *motions, const float4 *sorted, const BHNode *nodes,
                             const float4 *moments, const uint *order, const float *frame, const HaloGPU *haloList,
                             const HoleGPU *holes, const float3 *massive, const DiskCooling *disks,
                             TracerStepParams p, float3 *probe, uint slots) {
    uint gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= slots) { return; }
    tracerStep(states, motions, sorted, nodes, moments, order, frame, haloList, holes, massive, disks, p, probe,
               quadrupole, opensHoldingCells, gid);
}

}  // namespace BarnesHutShaders
}  // namespace metal

namespace bh = metal::BarnesHutShaders;

struct sc_solver {
    sc_context *context;
    sc_solver_config config;
    sc_solver_buffers buffers;
    // The lists a pass reads, which Metal binds as bytes.
    sc_buffer *halos;
    sc_buffer *holes;
    sc_buffer *disks;
    // The holes' reactions, bhHoleLimit sums a block of particles.
    sc_buffer *partial;
};

namespace sillage {
namespace solver {

// Threads a block. The walk keeps a stack of 32 entries a thread, and MetalBarnesHutSolver
// found 64 best for it on the M4 Max; #283 times it on NVIDIA.
constexpr uint32_t width = 256u;
constexpr uint32_t forceWidth = 64u;
// Particles a thread of bhHolePull, MetalBarnesHutSolver.holeGroupWidth.
constexpr uint32_t holeBlock = 256u;

static uint32_t blocks(uint32_t threads, uint32_t wide = width) { return (threads + wide - 1u) / wide; }

#define LAUNCH(kernel, grid, block, ...)                                                      \
    do {                                                                                      \
        SILLAGE_LAUNCH(kernel, dim3(grid), dim3(block), __VA_ARGS__);                         \
        if (sc_status launched = check(cudaGetLastError(), #kernel)) { return launched; }     \
    } while (0)

using FormStars = void (*)(float *, const metal::uint *, const float *, const bh::BHNode *, const metal::uint *,
                           bh::SFParams, const metal::float3 *, const metal::float3 *, float *);
using Acceleration = void (*)(const metal::float4 *, metal::float3 *, const bh::BHNode *, const metal::uint *,
                              const bh::HaloGPU *, bh::BHParams, metal::uint *, const metal::float4 *,
                              const metal::ulong *, metal::uint);
using TracerStep = void (*)(metal::float4 *, metal::uint4 *, const metal::float4 *, const bh::BHNode *,
                            const metal::float4 *, const metal::uint *, const float *, const bh::HaloGPU *,
                            const bh::HoleGPU *, const metal::float3 *, const bh::DiskCooling *,
                            bh::TracerStepParams, metal::float3 *, metal::uint);

static Acceleration acceleration(const sc_solver *solver) {
    if (solver->config.quadrupole != 0) {
        return solver->config.opens_holding_cells != 0 ? bh::bhAcceleration<true, true>
                                                       : bh::bhAcceleration<true, false>;
    }
    return solver->config.opens_holding_cells != 0 ? bh::bhAcceleration<false, true>
                                                   : bh::bhAcceleration<false, false>;
}

static TracerStep tracerStepEntry(const sc_solver *solver) {
    if (solver->config.quadrupole != 0) {
        return solver->config.opens_holding_cells != 0 ? bh::bhTracerStep<true, true> : bh::bhTracerStep<true, false>;
    }
    return solver->config.opens_holding_cells != 0 ? bh::bhTracerStep<false, true> : bh::bhTracerStep<false, false>;
}

// The struct a pass reads, from the bytes Swift filled it with.
template <class T>
static sc_status read(const sc_solver *solver, const void *bytes, size_t length, T &into, const char *name) {
    if (!solver) { return fail(SC_INVALID_ARGUMENT, "no solver"); }
    if (!bytes || length != sizeof(T)) {
        return fail(SC_INVALID_ARGUMENT, "%s is %zu bytes in the shared MSL, not %zu", name, sizeof(T), length);
    }
    std::memcpy(&into, bytes, sizeof(T));
    return use(solver->context);
}

static sc_status parameters(const sc_solver *solver, const void *bytes, size_t length, bh::BHParams &p) {
    if (sc_status status = read(solver, bytes, length, p, "BHParams")) { return status; }
    if (p.particleCount > solver->config.massive) {
        return fail(SC_INVALID_ARGUMENT, "a pass over %u particles, the solver holds %u", p.particleCount,
                    solver->config.massive);
    }
    return SC_OK;
}

// `count` elements of `stride` bytes in a device buffer of the solver's, made or grown for them;
// never an empty pointer, as Metal binds a placeholder for a list a kernel may not read.
static sc_status stage(sc_solver *solver, sc_buffer *&list, const void *bytes, uint32_t count, size_t stride) {
    size_t length = size_t(count) * stride;
    if (length > 0u && !bytes) { return fail(SC_INVALID_ARGUMENT, "a list of %u without its bytes", count); }
    if (!list || list->length < length) {
        release(list);
        sc_status status = SC_OK;
        list = allocate(solver->context, length, &status);
        if (status != SC_OK) { return status; }
    }
    return length > 0u ? sc_buffer_upload(list, 0u, bytes, length) : SC_OK;
}

static sc_status halos(sc_solver *solver, const bh::BHParams &p, const void *bytes, uint32_t count) {
    if (p.haloCount > count) {
        return fail(SC_INVALID_ARGUMENT, "%u analytic halos asked of a list of %u", p.haloCount, count);
    }
    return stage(solver, solver->halos, bytes, count, sizeof(bh::HaloGPU));
}

static metal::float3 *positions(const sc_solver *solver) {
    return pointer<metal::float3>(solver->buffers.positions, size_t(solver->config.first) * 16u);
}

static metal::float3 *velocities(const sc_solver *solver) {
    return pointer<metal::float3>(solver->buffers.velocities, size_t(solver->config.first) * 16u);
}

}  // namespace solver
}  // namespace sillage

using namespace sillage;
using namespace sillage::solver;

extern "C" {

sc_status sc_solver_create(sc_context *context, const sc_solver_config *config, const sc_solver_buffers *buffers,
                           sc_solver **made) {
    if (!config || !buffers || !made) {
        return fail(SC_INVALID_ARGUMENT, "sc_solver_create: no config, no buffers or no solver to write");
    }
    *made = nullptr;
    if (sc_status status = use(context)) { return status; }
    size_t massive = config->massive > 0u ? config->massive : 1u;
    size_t first = config->first;
    struct Wanted {
        const sc_buffer *buffer;
        size_t offset;
        size_t length;
        const char *name;
        bool optional;
    };
    for (const Wanted &wanted : {
             Wanted{buffers->positions, first * 16u, massive * 16u, "positions", false},
             Wanted{buffers->velocities, first * 16u, massive * 16u, "velocities", false},
             Wanted{buffers->accelerations, 0u, massive * 16u, "accelerations", false},
             Wanted{buffers->mass, 0u, massive * 4u, "masses", false},
             Wanted{buffers->sorted, 0u, massive * 16u, "sorted particles", false},
             Wanted{buffers->formation, 0u, massive * 4u, "formation times", false},
             Wanted{buffers->component, 0u, massive * 4u, "components", false},
             Wanted{buffers->galaxy, 0u, massive * 4u, "galaxies", true},
             Wanted{buffers->cost, 0u, massive * 4u, "costs", false},
             Wanted{buffers->slot_chances, 0u, massive * 4u, "slot chances", config->leaf_chances == 0},
             Wanted{buffers->tracer_order, 0u, first * 4u, "tracers' walk order", first == 0u},
         }) {
        if (!wanted.buffer && wanted.optional) { continue; }
        if (!holds(wanted.buffer, wanted.offset, wanted.length)) {
            return fail(SC_INVALID_ARGUMENT, "sc_solver_create: the %s do not hold %zu bytes from %zu", wanted.name,
                        wanted.length, wanted.offset);
        }
    }
    sc_solver *solver = new (std::nothrow) sc_solver();
    if (!solver) { return fail(SC_OUT_OF_MEMORY, "no host memory for a solver"); }
    solver->context = context;
    solver->config = *config;
    solver->config.massive = uint32_t(massive);
    solver->buffers = *buffers;
    *made = solver;
    return SC_OK;
}

void sc_solver_destroy(sc_solver *solver) {
    if (!solver) { return; }
    for (sc_buffer **buffer : {&solver->halos, &solver->holes, &solver->disks, &solver->partial}) {
        release(*buffer);
    }
    delete solver;
}

sc_status sc_solver_form_stars(sc_solver *solver, sc_tree *tree, const void *formation, size_t bytes) {
    bh::SFParams s;
    if (sc_status status = read(solver, formation, bytes, s, "SFParams")) { return status; }
    if (!tree || s.nodeCount > sc_tree_node_capacity(tree)) {
        return fail(SC_INVALID_ARGUMENT, "sc_solver_form_stars: no tree of %u nodes", s.nodeCount);
    }
    if (s.nodeCount == 0u) { return SC_OK; }
    const sc_solver_buffers &b = solver->buffers;
    FormStars bhFormStars = solver->config.leaf_chances != 0 ? bh::bhFormStars<true> : bh::bhFormStars<false>;
    // A placeholder without the tracers' chances, which the kernel then never writes.
    float *chances = pointer<float>(b.slot_chances ? b.slot_chances : b.mass);
    LAUNCH(bhFormStars, blocks(s.nodeCount), width, pointer<float>(b.formation), pointer<const metal::uint>(b.component),
           pointer<const float>(b.mass), pointer<const bh::BHNode>(sc_tree_buffer_of(tree, SC_TREE_NODES_BUFFER)),
           pointer<const metal::uint>(sc_tree_buffer_of(tree, SC_TREE_ORDER_BUFFER)), s, positions(solver),
           velocities(solver), chances);
    return SC_OK;
}

sc_status sc_solver_kick_drift(sc_solver *solver, const void *params, size_t bytes) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    LAUNCH(bh::bhKickDrift, blocks(p.particleCount), width, positions(solver), velocities(solver),
           pointer<const metal::float3>(solver->buffers.accelerations), p);
    return SC_OK;
}

sc_status sc_solver_gather(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "sc_solver_gather: no tree"); }
    LAUNCH(bh::bhGather, blocks(p.particleCount), width, pointer<metal::float4>(solver->buffers.sorted),
           positions(solver), pointer<const float>(solver->buffers.mass),
           pointer<const metal::uint>(sc_tree_buffer_of(tree, SC_TREE_ORDER_BUFFER)), p);
    return SC_OK;
}

sc_status sc_solver_accelerations(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes,
                                  uint32_t slots, const void *halo_list, uint32_t halo_count) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "sc_solver_accelerations: no tree"); }
    if (sc_status status = halos(solver, p, halo_list, halo_count)) { return status; }
    if (slots == 0u) { return SC_OK; }
    const sc_solver_buffers &b = solver->buffers;
    Acceleration bhAcceleration = acceleration(solver);
    // The moments are a placeholder without the quadrupole, which then never reads them.
    LAUNCH(bhAcceleration, blocks(slots, forceWidth), forceWidth, pointer<const metal::float4>(b.sorted),
           pointer<metal::float3>(b.accelerations),
           pointer<const bh::BHNode>(sc_tree_buffer_of(tree, SC_TREE_NODES_BUFFER)),
           pointer<const metal::uint>(sc_tree_buffer_of(tree, SC_TREE_ORDER_BUFFER)),
           pointer<const bh::HaloGPU>(solver->halos), p, pointer<metal::uint>(b.cost),
           pointer<const metal::float4>(sc_tree_buffer_of(tree, SC_TREE_MOMENTS_BUFFER)),
           pointer<const metal::ulong>(sc_tree_buffer_of(tree, SC_TREE_CODES_BUFFER)), slots);
    return SC_OK;
}

sc_status sc_solver_holes(sc_solver *solver, const void *params, size_t bytes, const void *hole_list,
                          uint32_t hole_count, const void *halo_list, uint32_t halo_count) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    if (hole_count == 0u) { return SC_OK; }
    if (hole_count > bh::bhHoleLimit) {
        return fail(SC_INVALID_ARGUMENT, "%u black holes, at most %u pull outside the tree", hole_count,
                    uint32_t(bh::bhHoleLimit));
    }
    if (sc_status status = halos(solver, p, halo_list, halo_count)) { return status; }
    if (sc_status status = stage(solver, solver->holes, hole_list, hole_count, sizeof(bh::HoleGPU))) { return status; }
    uint32_t groups = blocks(solver->config.massive, holeBlock);
    if (!solver->partial) {
        sc_status status = SC_OK;
        solver->partial = allocate(solver->context, size_t(groups) * bh::bhHoleLimit * 16u, &status);
        if (status != SC_OK) { return status; }
    }
    const sc_solver_buffers &b = solver->buffers;
    auto holes = pointer<const bh::HoleGPU>(solver->holes);
    auto partial = pointer<metal::float4>(solver->partial);
    LAUNCH(bh::bhHolePull, blocks(groups), width, positions(solver), pointer<metal::float3>(b.accelerations),
           pointer<const float>(b.mass), pointer<const metal::uint>(b.component), holes, hole_count, p, partial,
           holeBlock);
    LAUNCH(bh::bhHoleSettle, 1u, 1u, positions(solver), pointer<metal::float3>(b.accelerations), holes, hole_count,
           groups, partial, pointer<const bh::HaloGPU>(solver->halos), p);
    return SC_OK;
}

sc_status sc_solver_kick(sc_solver *solver, const void *params, size_t bytes) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    LAUNCH(bh::bhKick, blocks(p.particleCount), width, velocities(solver),
           pointer<const metal::float3>(solver->buffers.accelerations), p);
    return SC_OK;
}

sc_status sc_solver_dissipate(sc_solver *solver, const void *params, size_t bytes, const void *disk_list,
                              uint32_t disk_count) {
    bh::BHParams p;
    if (sc_status status = parameters(solver, params, bytes, p)) { return status; }
    if (disk_count == 0u) { return SC_OK; }
    if (!solver->buffers.galaxy) {
        return fail(SC_INVALID_ARGUMENT, "sc_solver_dissipate: the solver was made without its galaxies");
    }
    if (sc_status status = stage(solver, solver->disks, disk_list, disk_count, sizeof(bh::DiskCooling))) {
        return status;
    }
    const sc_solver_buffers &b = solver->buffers;
    LAUNCH(bh::bhDissipate, blocks(p.particleCount), width, positions(solver), velocities(solver),
           pointer<const metal::float3>(b.accelerations), pointer<const metal::uint>(b.component),
           pointer<const metal::uint>(b.galaxy), pointer<const bh::DiskCooling>(solver->disks), p);
    return SC_OK;
}

// MARK: - The light tracers (#275)

sc_status sc_solver_tracer_drift(sc_solver *solver, const void *params, size_t bytes) {
    bh::BHParams p;
    if (sc_status status = read(solver, params, bytes, p, "BHParams")) { return status; }
    if (p.particleCount > solver->config.first) {
        return fail(SC_INVALID_ARGUMENT, "a drift of %u light tracers, the solver holds %u", p.particleCount,
                    solver->config.first);
    }
    if (p.particleCount == 0u) { return SC_OK; }
    LAUNCH(bh::bhTracerDrift, blocks(p.particleCount), width, pointer<metal::float4>(solver->buffers.positions),
           pointer<const metal::uint4>(solver->buffers.velocities), p);
    return SC_OK;
}

sc_status sc_solver_tracer_form_stars(sc_solver *solver, sc_tree *tree, const void *formation, size_t bytes) {
    bh::SFParams s;
    if (sc_status status = read(solver, formation, bytes, s, "SFParams")) { return status; }
    if (solver->config.first == 0u || s.nodeCount == 0u) { return SC_OK; }
    if (!tree || !solver->buffers.slot_chances) {
        return fail(SC_INVALID_ARGUMENT, "sc_solver_tracer_form_stars: no tree, or no chances to read");
    }
    const sc_solver_buffers &b = solver->buffers;
    metal::uint2 counts(solver->config.first, solver->config.massive);
    LAUNCH(bh::bhTracerFormStars, blocks(solver->config.first), width, pointer<metal::float4>(b.positions),
           pointer<const metal::uint4>(b.velocities),
           pointer<const metal::ulong>(sc_tree_buffer_of(tree, SC_TREE_CODES_BUFFER)),
           pointer<const float>(sc_tree_buffer_of(tree, SC_TREE_FRAME_BUFFER)), pointer<const float>(b.slot_chances), s,
           counts);
    return SC_OK;
}

sc_status sc_solver_tracer_step(sc_solver *solver, sc_tree *tree, const void *params, size_t bytes, uint32_t slots,
                                const void *halo_list, uint32_t halo_count, const void *hole_list, uint32_t hole_count,
                                const void *disk_list, uint32_t disk_count, sc_buffer *probe) {
    bh::TracerStepParams p;
    if (sc_status status = read(solver, params, bytes, p, "TracerStepParams")) { return status; }
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "sc_solver_tracer_step: no tree"); }
    if (p.tracerCount > solver->config.first || p.sortChunk == 0u) {
        return fail(SC_INVALID_ARGUMENT, "a tracer pass over %u light tracers sorted %u at a time, the solver holds %u",
                    p.tracerCount, p.sortChunk, solver->config.first);
    }
    if (p.haloCount > halo_count || p.holeCount > hole_count || p.diskCount > disk_count ||
        hole_count > bh::bhHoleLimit) {
        return fail(SC_INVALID_ARGUMENT, "a tracer pass over %u halos, %u holes and %u disks given %u, %u and %u",
                    p.haloCount, p.holeCount, p.diskCount, halo_count, hole_count, disk_count);
    }
    if (p.mode == 2u && !holds(probe, 0u, size_t(p.tracerCount) * 16u)) {
        return fail(SC_INVALID_ARGUMENT, "sc_solver_tracer_step: no probe of %u accelerations", p.tracerCount);
    }
    if (sc_status status = stage(solver, solver->halos, halo_list, halo_count, sizeof(bh::HaloGPU))) { return status; }
    if (sc_status status = stage(solver, solver->holes, hole_list, hole_count, sizeof(bh::HoleGPU))) { return status; }
    if (sc_status status = stage(solver, solver->disks, disk_list, disk_count, sizeof(bh::DiskCooling))) {
        return status;
    }
    if (slots == 0u || p.tracerCount == 0u) { return SC_OK; }
    const sc_solver_buffers &b = solver->buffers;
    TracerStep bhTracerStep = tracerStepEntry(solver);
    // The probe is the accelerations outside mode 2, which then never writes it.
    LAUNCH(bhTracerStep, blocks(slots, forceWidth), forceWidth, pointer<metal::float4>(b.positions),
           pointer<metal::uint4>(b.velocities), pointer<const metal::float4>(b.sorted),
           pointer<const bh::BHNode>(sc_tree_buffer_of(tree, SC_TREE_NODES_BUFFER)),
           pointer<const metal::float4>(sc_tree_buffer_of(tree, SC_TREE_MOMENTS_BUFFER)),
           pointer<const metal::uint>(b.tracer_order),
           pointer<const float>(sc_tree_buffer_of(tree, SC_TREE_FRAME_BUFFER)),
           pointer<const bh::HaloGPU>(solver->halos), pointer<const bh::HoleGPU>(solver->holes), positions(solver),
           pointer<const bh::DiskCooling>(solver->disks), p,
           pointer<metal::float3>(p.mode == 2u ? probe : b.accelerations), slots);
    return SC_OK;
}

}  // extern "C"
