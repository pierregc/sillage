/* The tree builder (#273): GPUTreeBuilder's kernels and dispatches, on CUDA. The same tree as
 * the CPU's BarnesHutTree to the bit, laid out level by level. Included by sillage_cuda.h.
 *
 * On the CPU target the bounds, the sort and the split (block barriers and warp functions)
 * return SC_GPU_ONLY: CUDATreeBuilder lays out a BarnesHutTree with sc_tree_upload instead,
 * and every other kernel runs from there. */
#ifndef SILLAGE_CUDA_TREE_H
#define SILLAGE_CUDA_TREE_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sc_tree sc_tree;

typedef struct sc_tree_config {
    /* Positions the tree is built over, at least 1. */
    uint32_t count;
    /* The first position of the buffer the tree is built over: `order` counts from it. The
     * masses start at their buffer's start. */
    uint32_t first;
    uint32_t leaf_capacity;
    /* 1 to 21. */
    uint32_t maximum_depth;
    /* 0 for `count`. */
    uint32_t node_capacity;
    int32_t quadrupole;
    /* 0 leaves `order` empty, for a builder that only sorts into another buffer. */
    int32_t own_order;
} sc_tree_config;

typedef enum sc_tree_phase {
    SC_TREE_BOUNDS = 0,
    SC_TREE_MORTON = 1,
    SC_TREE_SORT = 2,
    SC_TREE_NODES = 3,
    SC_TREE_MASSES = 4
} sc_tree_phase;

typedef enum sc_tree_buffer {
    /* BHNode, 32 bytes, up to the node capacity. */
    SC_TREE_NODES_BUFFER = 0,
    /* Two float4 a node with the quadrupole, as BarnesHutTree.quadrupoles. */
    SC_TREE_MOMENTS_BUFFER = 1,
    /* Particle indices in Morton order. */
    SC_TREE_ORDER_BUFFER = 2,
    /* The sorted Morton codes, 64 bits each. */
    SC_TREE_CODES_BUFFER = 3,
    /* The root's corner, the codes' scale, the root's half width, then three zeros. */
    SC_TREE_FRAME_BUFFER = 4,
    /* Where each depth starts, then the node count: 24 uint. */
    SC_TREE_LEVELS_BUFFER = 5,
    /* The node count, the overflow flag, then the bounds as ordered integers: 8 uint. */
    SC_TREE_COUNTERS_BUFFER = 6,
    /* A uint2 a node, made by sc_tree_spacing; none before it. */
    SC_TREE_SPACING_BUFFER = 7
} sc_tree_buffer;

sc_status sc_tree_create(sc_context *context, const sc_tree_config *config, sc_tree **tree);
void sc_tree_destroy(sc_tree *tree);
/* A buffer of the tree, for reading it or binding it to the next kernels. Nodes and moments
 * change with sc_tree_grow, the spacing records with sc_tree_spacing. NULL for none. */
sc_buffer *sc_tree_buffer_of(sc_tree *tree, sc_tree_buffer which);
uint32_t sc_tree_node_capacity(const sc_tree *tree);

/* Every phase, then the masses gather the particles into `sorted` (16 bytes each) and sum the
 * leaves from there. `mass` and `sorted` may be NULL for the cells alone. */
sc_status sc_tree_build(sc_tree *tree, const sc_buffer *positions, const sc_buffer *mass,
                        sc_buffer *sorted);
sc_status sc_tree_build_phase(sc_tree *tree, sc_tree_phase phase, const sc_buffer *positions,
                              const sc_buffer *mass, sc_buffer *sorted);
/* The node count (at most the capacity) and whether the build ran out of nodes, in which case
 * the masses stopped: grow, then build again. */
sc_status sc_tree_state(sc_tree *tree, uint32_t *node_count, int32_t *overflowed);
/* Doubles the node buffers. */
sc_status sc_tree_grow(sc_tree *tree);
/* maximum_depth + 2 entries: where each depth starts, the last being the node count. */
sc_status sc_tree_level_starts(sc_tree *tree, uint32_t *starts, uint32_t capacity);

/* The smoothing lengths of the first `drawn` particles, each standing for `ratio`. */
sc_status sc_tree_smoothing(sc_tree *tree, sc_buffer *lengths, uint32_t drawn, float ratio);
/* The spacing records a light tracer reads (#238), into the tree's own buffer. Leaves none
 * past 2^24 nodes, as a record keeps its first child in 24 bits. */
sc_status sc_tree_spacing(sc_tree *tree, uint32_t drawn, float ratio);
/* Sorts `points` positions from `offset` into Morton order, written into `order` from
 * `order_offset` and counted from the first of them. Uses the tree's own buffers. */
sc_status sc_tree_sort_order(sc_tree *tree, const sc_buffer *positions, uint32_t offset,
                             uint32_t points, sc_buffer *order, uint32_t order_offset);

/* Lays out a tree built elsewhere, the CPU's BarnesHutTree, in the buffers a build fills, as
 * the cells phase leaves them: `nodes` in the level order, `level_starts` its maximum_depth + 2
 * entries, `order` its count (ignored without an order of its own), `frame` 8 floats. `moments`
 * may be NULL. More nodes than the capacity raise the overflow flag and lay out nothing, as a
 * build that runs out does. For the CPU target and the tests. */
sc_status sc_tree_upload(sc_tree *tree, const void *nodes, uint32_t node_count,
                         const float *moments, const uint32_t *order,
                         const uint32_t *level_starts, const float *frame);

#ifdef __cplusplus
}
#endif

#endif
