// The tree builder on CUDA (#273): the entry points of GPUTreeShaders' 20 kernels and their
// launches, with the threadgroup sizes and dispatch shapes of GPUTreeBuilder.swift. An entry
// point declares the threadgroup memory, works out the thread's position as Metal's dispatch
// gives it, and calls the shared function; the arithmetic is the MSL's alone. Built without
// FMA contraction (--fmad=false, -ffp-contract=off), as Metal builds it with mathMode = .safe.
#include "cuda_cpu.h"

#include <initializer_list>
#include <new>

#include "engine.h"
#include "GPUTreeShaders.h"

namespace metal {
namespace GPUTreeShaders {

__global__ void gtReset(atomic_uint *counters, uint *levels) {
    treeReset(counters, levels, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gtRoot(atomic_uint *counters, BHNode *nodes, float *frame, uint *levels, TreeParams p) {
    treeRoot(counters, nodes, frame, levels, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gtMorton(const float3 *positions, ulong *codes, uint *order, const float *frame,
                         TreeParams p) {
    treeMorton(positions, codes, order, frame, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gtCloseLevel(atomic_uint *counters, uint *levels, TreeParams p) {
    treeCloseLevel(counters, levels, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gtGather(float4 *sorted, const float3 *positions, const float *mass,
                         const uint *order, TreeParams p) {
    treeGather(sorted, positions, mass, order, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gtLeafSums(BHNode *nodes, const float4 *sorted, const uint *levels, TreeParams p,
                           float4 *moments, const uint *counters) {
    treeLeafSums(nodes, sorted, levels, p, moments, counters, blockIdx.x * blockDim.x + threadIdx.x,
                 gridDim.x * blockDim.x);
}

__global__ void gtFold(BHNode *nodes, const uint *levels, TreeParams p, const uint *counters) {
    treeFold(nodes, levels, p, counters, blockIdx.x * blockDim.x + threadIdx.x, gridDim.x * blockDim.x);
}

__global__ void gtNormalize(BHNode *nodes, const uint *levels, TreeParams p, const uint *counters) {
    treeNormalize(nodes, levels, p, counters, blockIdx.x * blockDim.x + threadIdx.x,
                  gridDim.x * blockDim.x);
}

__global__ void gtFoldMoments(const BHNode *nodes, const uint *levels, TreeParams p, float4 *moments,
                              const uint *counters) {
    treeFoldMoments(nodes, levels, p, moments, counters, blockIdx.x * blockDim.x + threadIdx.x,
                    gridDim.x * blockDim.x);
}

__global__ void gtSmoothing(float *lengths, const BHNode *nodes, const uint *order, const uint *levels,
                            const uint *counters, TreeParams p, uint drawnCount, float ratio) {
    treeSmoothing(lengths, nodes, order, levels, counters, p, drawnCount, ratio,
                  blockIdx.x * blockDim.x + threadIdx.x, gridDim.x * blockDim.x);
}

__global__ void gtSpacingLeaves(uint2 *spacing, const BHNode *nodes, const uint *order,
                                const uint *levels, const uint *counters, TreeParams p, uint drawnCount) {
    treeSpacingLeaves(spacing, nodes, order, levels, counters, p, drawnCount,
                      blockIdx.x * blockDim.x + threadIdx.x, gridDim.x * blockDim.x);
}

__global__ void gtSpacingFold(uint2 *spacing, const BHNode *nodes, const uint *levels,
                              const uint *counters, TreeParams p) {
    treeSpacingFold(spacing, nodes, levels, counters, p, blockIdx.x * blockDim.x + threadIdx.x,
                    gridDim.x * blockDim.x);
}

__global__ void gtSpacingLengths(uint2 *spacing, const BHNode *nodes, const uint *levels,
                                 const uint *counters, TreeParams p, float ratio) {
    treeSpacingLengths(spacing, nodes, levels, counters, p, ratio, blockIdx.x * blockDim.x + threadIdx.x,
                       gridDim.x * blockDim.x);
}

// Block barriers and warp functions: on a GPU only, first in #283. A warp is Metal's SIMD group
// of 32 lanes.
#if !defined(SILLAGE_CPU)

__global__ void gtBounds(const float3 *positions, atomic_uint *counters, TreeParams p) {
    __shared__ float3 lowers[32];
    __shared__ float3 uppers[32];
    uint t = threadIdx.x;
    treeBounds(positions, counters, p, blockIdx.x * blockDim.x + t, gridDim.x * blockDim.x, t, t / 32u,
               t % 32u, blockDim.x / 32u, lowers, uppers);
}

__global__ void gtRadixCount(const ulong *keys, uint *table, TreeParams p) {
    __shared__ uint counters[sortSimds * buckets];
    uint t = threadIdx.x;
    treeRadixCount(keys, table, p, blockIdx.x, t, t / 32u, t % 32u, counters);
}

__global__ void gtScanReduce(const uint *table, uint *sums, TreeParams p) {
    __shared__ uint partial[8];
    uint t = threadIdx.x;
    treeScanReduce(table, sums, p, blockIdx.x, t, t / 32u, t % 32u, partial);
}

__global__ void gtScanTop(uint *sums, TreeParams p) {
    __shared__ uint partial[32];
    __shared__ uint chunkTotal;
    uint t = threadIdx.x;
    treeScanTop(sums, p, t, t / 32u, t % 32u, partial, chunkTotal);
}

__global__ void gtScanDown(uint *table, const uint *sums, TreeParams p) {
    __shared__ uint partial[8];
    uint t = threadIdx.x;
    treeScanDown(table, sums, p, blockIdx.x, t, t / 32u, t % 32u, partial);
}

__global__ void gtRadixScatter(const ulong *keysIn, const uint *valuesIn, ulong *keysOut,
                               uint *valuesOut, const uint *table, TreeParams p) {
    __shared__ uint counters[sortSimds * buckets];
    __shared__ uint starts[buckets];
    uint t = threadIdx.x;
    treeRadixScatter(keysIn, valuesIn, keysOut, valuesOut, table, p, blockIdx.x, t, t / 32u, t % 32u,
                     counters, starts);
}

__global__ void gtSplit(BHNode *nodes, const ulong *codes, atomic_uint *counters, const uint *levels,
                        const float *frame, TreeParams p) {
    treeSplit(nodes, codes, counters, levels, frame, p, blockIdx.x * blockDim.x + threadIdx.x,
              gridDim.x * blockDim.x, threadIdx.x % 32u);
}

#endif

}  // namespace GPUTreeShaders
}  // namespace metal

namespace gt = metal::GPUTreeShaders;

struct sc_tree {
    sc_context *context;
    gt::TreeParams params;
    uint32_t count;
    uint32_t first;
    uint32_t maximumDepth;
    uint32_t nodeCapacity;
    uint32_t tiles;
    uint32_t scanBlocks;
    bool quadrupole;
    bool ownOrder;
    sc_buffer *nodes;
    sc_buffer *moments;
    sc_buffer *order;
    sc_buffer *codes;
    sc_buffer *spareCodes;
    sc_buffer *spareOrder;
    sc_buffer *table;
    sc_buffer *sums;
    sc_buffer *counters;
    sc_buffer *levels;
    sc_buffer *frame;
    sc_buffer *spacing;
};

namespace sillage {
namespace tree {

// GPUTreeBuilder's dispatch shapes.
constexpr uint32_t tileSize = 2048u;
constexpr uint32_t radixBits = 8u;
// A kernel that strides over the nodes gives each node to one thread whatever the grid, so the
// CPU target runs one block of them: 1,024 blocks there are 262,144 calls a launch, nearly all
// with nothing to do, and were most of a solver's step (#274).
#if defined(SILLAGE_CPU)
constexpr uint32_t strideGroups = 1u;
#else
constexpr uint32_t strideGroups = 1024u;
#endif
constexpr uint32_t width = 256u;
#if defined(SILLAGE_CPU)
static_assert(tileSize == gt::tileSize && radixBits == gt::radixBits && width == gt::sortThreads,
              "the dispatches no longer fit GPUTreeShaders");
#endif

// What one build or sort runs over: the whole of `count` into `order`, or a chunk of it into
// another buffer.
struct Run {
    gt::TreeParams params;
    uint32_t tiles;
    uint32_t scanBlocks;
    const metal::float3 *positions;
    uint32_t *order;
};

static Run whole(const sc_tree *tree, const sc_buffer *positions) {
    return Run{tree->params, tree->tiles, tree->scanBlocks,
               pointer<const metal::float3>(positions, size_t(tree->first) * 16u), pointer<uint32_t>(tree->order)};
}

static gt::TreeParams at(gt::TreeParams p, uint32_t level, uint32_t shift = 0u) {
    p.level = level;
    p.shift = shift;
    return p;
}

static uint32_t groups(uint32_t threads) { return (threads + width - 1u) / width; }

#define LAUNCH(kernel, grid, block, ...)                                                      \
    do {                                                                                      \
        SILLAGE_LAUNCH(gt::kernel, dim3(grid), dim3(block), __VA_ARGS__);                     \
        if (sc_status launched = check(cudaGetLastError(), #kernel)) { return launched; }     \
    } while (0)

#if defined(SILLAGE_CPU)
static sc_status gpuOnly(const char *what) {
    return fail(SC_GPU_ONLY, "%s uses block barriers and warp functions: the CPU target cannot run it, "
                             "a GPU does (#283)", what);
}
#endif

static sc_status bounds(sc_tree *tree, const Run &run) {
#if defined(SILLAGE_CPU)
    (void)tree;
    (void)run;
    return gpuOnly("the bounds (gtBounds)");
#else
    auto counters = pointer<metal::atomic_uint>(tree->counters);
    auto levels = pointer<uint32_t>(tree->levels);
    LAUNCH(gtReset, 1u, 32u, counters, levels);
    LAUNCH(gtBounds, 512u, width, run.positions, counters, at(run.params, 0u));
    LAUNCH(gtRoot, 1u, 32u, counters, pointer<gt::BHNode>(tree->nodes), pointer<float>(tree->frame), levels,
           at(run.params, 0u));
    return SC_OK;
#endif
}

static sc_status morton(sc_tree *tree, const Run &run) {
    LAUNCH(gtMorton, groups(run.params.count), width, run.positions, pointer<metal::ulong>(tree->codes),
           run.order, pointer<const float>(tree->frame), run.params);
    return SC_OK;
}

static sc_status sort(sc_tree *tree, const Run &run) {
#if defined(SILLAGE_CPU)
    (void)tree;
    (void)run;
    return gpuOnly("the radix sort");
#else
    auto codes = pointer<metal::ulong>(tree->codes);
    auto spareCodes = pointer<metal::ulong>(tree->spareCodes);
    auto spareOrder = pointer<uint32_t>(tree->spareOrder);
    auto table = pointer<uint32_t>(tree->table);
    auto sums = pointer<uint32_t>(tree->sums);
    constexpr uint32_t radixPasses = (64u + radixBits - 1u) / radixBits;
    for (uint32_t pass = 0u; pass < radixPasses; ++pass) {
        bool even = pass % 2u == 0u;
        const metal::ulong *keysIn = even ? codes : spareCodes;
        metal::ulong *keysOut = even ? spareCodes : codes;
        const uint32_t *valuesIn = even ? run.order : spareOrder;
        uint32_t *valuesOut = even ? spareOrder : run.order;
        uint32_t shift = pass * radixBits;
        LAUNCH(gtRadixCount, run.tiles, width, keysIn, table, at(run.params, 0u, shift));
        LAUNCH(gtScanReduce, run.scanBlocks, width, table, sums, at(run.params, 0u));
        LAUNCH(gtScanTop, 1u, 1024u, sums, at(run.params, 0u));
        LAUNCH(gtScanDown, run.scanBlocks, width, table, sums, at(run.params, 0u));
        LAUNCH(gtRadixScatter, run.tiles, width, keysIn, valuesIn, keysOut, valuesOut, table,
               at(run.params, 0u, shift));
    }
    return SC_OK;
#endif
}

static sc_status split(sc_tree *tree, const Run &run) {
#if defined(SILLAGE_CPU)
    (void)tree;
    (void)run;
    return gpuOnly("the split (gtSplit)");
#else
    auto counters = pointer<metal::atomic_uint>(tree->counters);
    auto levels = pointer<uint32_t>(tree->levels);
    for (uint32_t level = 0u; level <= tree->maximumDepth; ++level) {
        LAUNCH(gtCloseLevel, 1u, 32u, counters, levels, at(run.params, level));
        if (level == tree->maximumDepth) { break; }
        LAUNCH(gtSplit, strideGroups, width, pointer<gt::BHNode>(tree->nodes),
               pointer<const metal::ulong>(tree->codes), counters, levels, pointer<const float>(tree->frame),
               at(run.params, level));
    }
    return SC_OK;
#endif
}

static sc_status masses(sc_tree *tree, const Run &run, const sc_buffer *mass, sc_buffer *sorted) {
    auto nodes = pointer<gt::BHNode>(tree->nodes);
    auto levels = pointer<const uint32_t>(tree->levels);
    auto moments = pointer<metal::float4>(tree->moments);
    auto flags = pointer<const uint32_t>(tree->counters);
    auto gathered = pointer<metal::float4>(sorted);
    LAUNCH(gtGather, groups(run.params.count), width, gathered, run.positions, pointer<const float>(mass),
           run.order, run.params);
    LAUNCH(gtLeafSums, strideGroups, width, nodes, gathered, levels, at(run.params, 0u), moments, flags);
    for (uint32_t level = tree->maximumDepth; level-- > 0u;) {
        LAUNCH(gtFold, strideGroups, width, nodes, levels, at(run.params, level), flags);
    }
    LAUNCH(gtNormalize, strideGroups, width, nodes, levels, at(run.params, 0u), flags);
    if (!tree->quadrupole) { return SC_OK; }
    for (uint32_t level = tree->maximumDepth; level-- > 0u;) {
        LAUNCH(gtFoldMoments, strideGroups, width, nodes, levels, at(run.params, level), moments, flags);
    }
    return SC_OK;
}

static sc_status phase(sc_tree *tree, sc_tree_phase which, const Run &run, const sc_buffer *mass,
                       sc_buffer *sorted) {
    switch (which) {
        case SC_TREE_BOUNDS: return bounds(tree, run);
        case SC_TREE_MORTON: return morton(tree, run);
        case SC_TREE_SORT: return sort(tree, run);
        case SC_TREE_NODES: return split(tree, run);
        case SC_TREE_MASSES: return mass && sorted ? masses(tree, run, mass, sorted) : SC_OK;
    }
    return fail(SC_INVALID_ARGUMENT, "no tree phase %d", int(which));
}

// The buffers a build reads must hold what it reads.
static sc_status inputs(const sc_tree *tree, const sc_buffer *positions, const sc_buffer *mass,
                        const sc_buffer *sorted) {
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "no tree"); }
    if (!holds(positions, size_t(tree->first) * 16u, size_t(tree->count) * 16u)) {
        return fail(SC_INVALID_ARGUMENT, "the positions do not hold %u float3 from %u", tree->count, tree->first);
    }
    if (mass && !holds(mass, 0u, size_t(tree->count) * 4u)) {
        return fail(SC_INVALID_ARGUMENT, "the masses do not hold %u floats", tree->count);
    }
    if (sorted && !holds(sorted, 0u, size_t(tree->count) * 16u)) {
        return fail(SC_INVALID_ARGUMENT, "the sorted particles do not hold %u float4", tree->count);
    }
    if (!tree->ownOrder) { return fail(SC_INVALID_ARGUMENT, "a tree without an order of its own only sorts"); }
    return use(tree->context);
}

static void releaseAll(sc_tree *tree) {
    for (sc_buffer **buffer : {&tree->nodes, &tree->moments, &tree->order, &tree->codes, &tree->spareCodes,
                               &tree->spareOrder, &tree->table, &tree->sums, &tree->counters, &tree->levels,
                               &tree->frame, &tree->spacing}) {
        release(*buffer);
    }
}

}  // namespace tree
}  // namespace sillage

using namespace sillage;
using namespace sillage::tree;

extern "C" {

sc_status sc_tree_create(sc_context *context, const sc_tree_config *config, sc_tree **made) {
    if (!config || !made) { return fail(SC_INVALID_ARGUMENT, "sc_tree_create: no config or no tree to write"); }
    *made = nullptr;
    sc_tree *tree = new (std::nothrow) sc_tree();
    if (!tree) { return fail(SC_OUT_OF_MEMORY, "no host memory for a tree"); }
    tree->context = context;
    tree->count = config->count > 0u ? config->count : 1u;
    tree->first = config->first;
    tree->maximumDepth = config->maximum_depth < 1u ? 1u : (config->maximum_depth > 21u ? 21u : config->maximum_depth);
    tree->nodeCapacity = config->node_capacity > 0u ? config->node_capacity : tree->count;
    tree->quadrupole = config->quadrupole != 0;
    tree->ownOrder = config->own_order != 0;
    tree->tiles = (tree->count + tileSize - 1u) / tileSize;
    uint32_t tableLength = tree->tiles << radixBits;
    tree->scanBlocks = (tableLength + 1023u) / 1024u;
    gt::TreeParams &p = tree->params;
    p.count = tree->count;
    p.leafCapacity = config->leaf_capacity > 0u ? config->leaf_capacity : 1u;
    p.maximumDepth = tree->maximumDepth;
    p.nodeCapacity = tree->nodeCapacity;
    p.tiles = tree->tiles;
    p.tableLength = tableLength;
    p.moments = tree->quadrupole ? 1u : 0u;

    size_t count = tree->count;
    size_t capacity = tree->nodeCapacity;
    struct Wanted {
        sc_buffer **buffer;
        size_t length;
    };
    sc_status status = SC_OK;
    for (const Wanted &wanted : {
             Wanted{&tree->nodes, capacity * sizeof(gt::BHNode)},
             Wanted{&tree->moments, tree->quadrupole ? capacity * 2u * 16u : 0u},
             Wanted{&tree->codes, count * 8u},
             Wanted{&tree->spareCodes, count * 8u},
             Wanted{&tree->order, tree->ownOrder ? count * 4u : 0u},
             Wanted{&tree->spareOrder, count * 4u},
             Wanted{&tree->table, size_t(tableLength) * 4u},
             Wanted{&tree->sums, size_t(tree->scanBlocks) * 4u},
             Wanted{&tree->counters, 8u * 4u},
             Wanted{&tree->levels, 24u * 4u},
             Wanted{&tree->frame, 8u * 4u},
         }) {
        *wanted.buffer = allocate(context, wanted.length, &status);
        if (status != SC_OK) {
            releaseAll(tree);
            delete tree;
            return status;
        }
    }
    *made = tree;
    return SC_OK;
}

void sc_tree_destroy(sc_tree *tree) {
    if (!tree) { return; }
    releaseAll(tree);
    delete tree;
}

sc_buffer *sc_tree_buffer_of(sc_tree *tree, sc_tree_buffer which) {
    if (!tree) { return nullptr; }
    switch (which) {
        case SC_TREE_NODES_BUFFER: return tree->nodes;
        case SC_TREE_MOMENTS_BUFFER: return tree->moments;
        case SC_TREE_ORDER_BUFFER: return tree->order;
        case SC_TREE_CODES_BUFFER: return tree->codes;
        case SC_TREE_FRAME_BUFFER: return tree->frame;
        case SC_TREE_LEVELS_BUFFER: return tree->levels;
        case SC_TREE_COUNTERS_BUFFER: return tree->counters;
        case SC_TREE_SPACING_BUFFER: return tree->spacing;
    }
    return nullptr;
}

uint32_t sc_tree_node_capacity(const sc_tree *tree) { return tree ? tree->nodeCapacity : 0u; }

sc_status sc_tree_build(sc_tree *tree, const sc_buffer *positions, const sc_buffer *mass, sc_buffer *sorted) {
    if (sc_status status = inputs(tree, positions, mass, sorted)) { return status; }
    Run run = whole(tree, positions);
    for (sc_tree_phase which : {SC_TREE_BOUNDS, SC_TREE_MORTON, SC_TREE_SORT, SC_TREE_NODES, SC_TREE_MASSES}) {
        if (sc_status status = phase(tree, which, run, mass, sorted)) { return status; }
    }
    return SC_OK;
}

sc_status sc_tree_build_phase(sc_tree *tree, sc_tree_phase which, const sc_buffer *positions,
                              const sc_buffer *mass, sc_buffer *sorted) {
    if (sc_status status = inputs(tree, positions, mass, sorted)) { return status; }
    return phase(tree, which, whole(tree, positions), mass, sorted);
}

sc_status sc_tree_state(sc_tree *tree, uint32_t *node_count, int32_t *overflowed) {
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "no tree"); }
    uint32_t counters[2] = {0u, 0u};
    if (sc_status status = sc_buffer_download(tree->counters, 0u, counters, sizeof counters)) { return status; }
    if (node_count) { *node_count = counters[0] < tree->nodeCapacity ? counters[0] : tree->nodeCapacity; }
    if (overflowed) { *overflowed = counters[1] != 0u ? 1 : 0; }
    return SC_OK;
}

sc_status sc_tree_grow(sc_tree *tree) {
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "no tree"); }
    if (tree->nodeCapacity > 0x7FFFFFFFu) { return fail(SC_OUT_OF_MEMORY, "a tree cannot hold 2^32 nodes"); }
    uint32_t capacity = tree->nodeCapacity * 2u;
    sc_status status = SC_OK;
    sc_buffer *nodes = allocate(tree->context, size_t(capacity) * sizeof(gt::BHNode), &status);
    if (status != SC_OK) { return status; }
    sc_buffer *moments = nullptr;
    if (tree->quadrupole) {
        moments = allocate(tree->context, size_t(capacity) * 2u * 16u, &status);
        if (status != SC_OK) {
            release(nodes);
            return status;
        }
        release(tree->moments);
        tree->moments = moments;
    }
    release(tree->nodes);
    tree->nodes = nodes;
    tree->nodeCapacity = capacity;
    tree->params.nodeCapacity = capacity;
    return SC_OK;
}

sc_status sc_tree_level_starts(sc_tree *tree, uint32_t *starts, uint32_t capacity) {
    if (!tree || !starts || capacity < tree->maximumDepth + 2u) {
        return fail(SC_INVALID_ARGUMENT, "sc_tree_level_starts: room for %u starts is needed",
                    tree ? tree->maximumDepth + 2u : 0u);
    }
    return sc_buffer_download(tree->levels, 0u, starts, size_t(tree->maximumDepth + 2u) * 4u);
}

sc_status sc_tree_smoothing(sc_tree *tree, sc_buffer *lengths, uint32_t drawn, float ratio) {
    if (!tree || !lengths) { return fail(SC_INVALID_ARGUMENT, "sc_tree_smoothing: no tree or no lengths"); }
    if (sc_status status = use(tree->context)) { return status; }
    uint32_t room = uint32_t(lengths->length / 4u);
    uint32_t drawnCount = drawn < tree->count ? drawn : tree->count;
    drawnCount = drawnCount < room ? drawnCount : room;
    LAUNCH(gtSmoothing, strideGroups, width, pointer<float>(lengths), pointer<const gt::BHNode>(tree->nodes),
           pointer<const uint32_t>(tree->order), pointer<const uint32_t>(tree->levels), pointer<const uint32_t>(tree->counters),
           at(tree->params, 0u), drawnCount, ratio);
    return SC_OK;
}

sc_status sc_tree_spacing(sc_tree *tree, uint32_t drawn, float ratio) {
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "no tree"); }
    if (sc_status status = use(tree->context)) { return status; }
    // A record keeps its first child in 24 bits.
    if (tree->nodeCapacity > (1u << 24)) {
        release(tree->spacing);
        return SC_OK;
    }
    size_t length = size_t(tree->nodeCapacity) * 8u;
    if (!tree->spacing || tree->spacing->length < length) {
        release(tree->spacing);
        sc_status status = SC_OK;
        tree->spacing = allocate(tree->context, length, &status);
        if (status != SC_OK) { return status; }
    }
    auto spacing = pointer<metal::uint2>(tree->spacing);
    auto nodes = pointer<const gt::BHNode>(tree->nodes);
    auto levels = pointer<const uint32_t>(tree->levels);
    auto flags = pointer<const uint32_t>(tree->counters);
    uint32_t drawnCount = drawn < tree->count ? drawn : tree->count;
    LAUNCH(gtSpacingLeaves, strideGroups, width, spacing, nodes, pointer<const uint32_t>(tree->order), levels, flags,
           at(tree->params, 0u), drawnCount);
    for (uint32_t level = tree->maximumDepth; level-- > 0u;) {
        LAUNCH(gtSpacingFold, strideGroups, width, spacing, nodes, levels, flags, at(tree->params, level));
    }
    LAUNCH(gtSpacingLengths, strideGroups, width, spacing, nodes, levels, flags, at(tree->params, 0u), ratio);
    return SC_OK;
}

sc_status sc_tree_sort_order(sc_tree *tree, const sc_buffer *positions, uint32_t offset, uint32_t points,
                             sc_buffer *order, uint32_t order_offset) {
    if (!tree) { return fail(SC_INVALID_ARGUMENT, "no tree"); }
    points = points < tree->count ? points : tree->count;
    if (points == 0u) { return SC_OK; }
    if (!holds(positions, size_t(offset) * 16u, size_t(points) * 16u) ||
        !holds(order, size_t(order_offset) * 4u, size_t(points) * 4u)) {
        return fail(SC_INVALID_ARGUMENT, "sc_tree_sort_order: %u points from %u, or their order from %u, "
                                         "do not fit", points, offset, order_offset);
    }
    if (sc_status status = use(tree->context)) { return status; }
    Run run = whole(tree, positions);
    run.params.count = points;
    run.tiles = (points + tileSize - 1u) / tileSize;
    run.params.tiles = run.tiles;
    run.params.tableLength = run.tiles << radixBits;
    run.scanBlocks = (run.params.tableLength + 1023u) / 1024u;
    run.positions = pointer<const metal::float3>(positions, size_t(offset) * 16u);
    run.order = pointer<uint32_t>(order, size_t(order_offset) * 4u);
    for (sc_tree_phase which : {SC_TREE_BOUNDS, SC_TREE_MORTON, SC_TREE_SORT}) {
        if (sc_status status = phase(tree, which, run, nullptr, nullptr)) { return status; }
    }
    return SC_OK;
}

sc_status sc_tree_upload(sc_tree *tree, const void *nodes, uint32_t node_count, const float *moments,
                         const uint32_t *order, const uint32_t *level_starts, const float *frame) {
    if (!tree || (node_count > 0u && !nodes) || !level_starts) {
        return fail(SC_INVALID_ARGUMENT, "sc_tree_upload: no tree, no nodes or no level starts");
    }
    uint32_t counters[8] = {node_count, 0u, 0u, 0u, 0u, 0u, 0u, 0u};
    if (node_count > tree->nodeCapacity) {
        counters[1] = 1u;
        return sc_buffer_upload(tree->counters, 0u, counters, sizeof counters);
    }
    uint32_t depths = tree->maximumDepth + 2u;
    for (uint32_t level = 0u; level + 1u < depths; ++level) {
        if (level_starts[level] > level_starts[level + 1u] || level_starts[level + 1u] > node_count) {
            return fail(SC_INVALID_ARGUMENT, "sc_tree_upload: the level starts are not the starts of %u nodes",
                        node_count);
        }
    }
    if (level_starts[0] != 0u || level_starts[depths - 1u] != node_count) {
        return fail(SC_INVALID_ARGUMENT, "sc_tree_upload: the level starts do not run from 0 to %u", node_count);
    }
    if (sc_status status = sc_buffer_upload(tree->nodes, 0u, nodes, size_t(node_count) * sizeof(gt::BHNode))) {
        return status;
    }
    if (moments && tree->quadrupole) {
        if (sc_status status = sc_buffer_upload(tree->moments, 0u, moments, size_t(node_count) * 2u * 16u)) {
            return status;
        }
    }
    if (order && tree->ownOrder) {
        if (sc_status status = sc_buffer_upload(tree->order, 0u, order, size_t(tree->count) * 4u)) { return status; }
    }
    if (frame) {
        if (sc_status status = sc_buffer_upload(tree->frame, 0u, frame, 8u * 4u)) { return status; }
    }
    uint32_t levels[24] = {};
    for (uint32_t level = 0u; level < depths; ++level) { levels[level] = level_starts[level]; }
    if (sc_status status = sc_buffer_upload(tree->levels, 0u, levels, sizeof levels)) { return status; }
    return sc_buffer_upload(tree->counters, 0u, counters, sizeof counters);
}

}  // extern "C"
