// Has nvcc generate device code for the 20 shared functions of the tree (#281), so that
// cuda/build.sh can read their PTX. Not an entry point, never launched: #273 writes the tree's
// entry points in cuda/src, and removes this file.
#include "cuda_cpu.h"

#include "kernels.h"

#if !defined(SILLAGE_CPU)

namespace metal {
namespace GPUTreeShaders {

__global__ void treeProbe(atomic_uint *counters, uint *levels, const float3 *positions,
                          BHNode *nodes, float *frame, ulong *codes, uint *order, uint *table,
                          uint *sums, ulong *keysOut, uint *valuesOut, float4 *sorted,
                          const float *mass, float4 *moments, float *lengths, uint2 *spacing,
                          TreeParams p, uint drawnCount, float ratio) {
    uint t = threadIdx.x;
    uint block = blockIdx.x;
    uint gid = block * blockDim.x + t;
    uint threads = gridDim.x * blockDim.x;
    uint simd = t / 32u;
    uint lane = t & 31u;
    uint simds = blockDim.x / 32u;
    __shared__ float3 lowers[32];
    __shared__ float3 uppers[32];
    __shared__ uint scratch[sortSimds * buckets];
    __shared__ uint starts[buckets];
    __shared__ uint chunkTotal;
    const uint *flags = &counters->value;
    treeReset(counters, levels, gid);
    treeBounds(positions, counters, p, gid, threads, t, simd, lane, simds, lowers, uppers);
    treeRoot(counters, nodes, frame, levels, p, gid);
    treeMorton(positions, codes, order, frame, p, gid);
    treeRadixCount(codes, table, p, block, t, simd, lane, scratch);
    treeScanReduce(table, sums, p, block, t, simd, lane, scratch);
    treeScanTop(sums, p, t, simd, lane, scratch, chunkTotal);
    treeScanDown(table, sums, p, block, t, simd, lane, scratch);
    treeRadixScatter(codes, order, keysOut, valuesOut, table, p, block, t, simd, lane, scratch,
                     starts);
    treeCloseLevel(counters, levels, p, gid);
    treeSplit(nodes, codes, counters, levels, frame, p, gid, threads, lane);
    treeGather(sorted, positions, mass, order, p, gid);
    treeLeafSums(nodes, sorted, levels, p, moments, flags, gid, threads);
    treeFold(nodes, levels, p, flags, gid, threads);
    treeNormalize(nodes, levels, p, flags, gid, threads);
    treeFoldMoments(nodes, levels, p, moments, flags, gid, threads);
    treeSmoothing(lengths, nodes, order, levels, flags, p, drawnCount, ratio, gid, threads);
    treeSpacingLeaves(spacing, nodes, order, levels, flags, p, drawnCount, gid, threads);
    treeSpacingFold(spacing, nodes, levels, flags, p, gid, threads);
    treeSpacingLengths(spacing, nodes, levels, flags, p, ratio, gid, threads);
}

}  // namespace GPUTreeShaders
}  // namespace metal

#endif
