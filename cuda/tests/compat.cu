// Tests of cuda/include on the CPU target (#281): the launch, the atomics and the memory calls
// of cuda_cpu.h, the types and functions of msl_compat.h, and a few of the tree's shared
// functions run from their MSL text. nvcc compiles the file too; it only runs on the CPU.
#include "cuda_cpu.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <vector>

#include "kernels.h"

// Inside the library's namespace, as an entry point is: there float3, min or abs are MSL's.
namespace metal {
namespace GPUTreeShaders {

// What dispatchThreads does on Metal: a grid of whole blocks, and no thread past the count.
__global__ void fillIndex(uint *out, uint count) {
    uint gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= count) { return; }
    out[gid] = gid;
}

__global__ void countThreads(unsigned int *counter, unsigned int *seen) {
    unsigned int thread = threadIdx.x + blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z);
    unsigned int block = blockIdx.x + gridDim.x * (blockIdx.y + gridDim.y * blockIdx.z);
    unsigned int threads = blockDim.x * blockDim.y * blockDim.z;
    atomicAdd(counter, 1u);
    atomicAdd(&seen[block * threads + thread], 1u);
}

__global__ void mortonEntry(const float3 *positions, ulong *codes, uint *order, const float *frame,
                            TreeParams p) {
    treeMorton(positions, codes, order, frame, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void gatherEntry(float4 *sorted, const float3 *positions, const float *mass,
                            const uint *order, TreeParams p) {
    treeGather(sorted, positions, mass, order, p, blockIdx.x * blockDim.x + threadIdx.x);
}

__global__ void rootEntry(atomic_uint *counters, BHNode *nodes, float *frame, uint *levels,
                          TreeParams p) {
    treeRoot(counters, nodes, frame, levels, p, blockIdx.x * blockDim.x + threadIdx.x);
}

#if defined(SILLAGE_CPU)

static int failures = 0;
static int checks = 0;
#define CHECK(condition)                                                    \
    do {                                                                    \
        checks += 1;                                                        \
        if (!(condition)) {                                                 \
            failures += 1;                                                  \
            std::printf("%s:%d: failed: %s\n", __FILE__, __LINE__, #condition); \
        }                                                                   \
    } while (0)

static uint32_t bits(float value) { return as_type<uint>(value); }

static void testLaunch() {
    const uint count = 1000;
    uint *out = nullptr;
    CHECK(cudaMalloc(&out, 1024 * sizeof(uint)) == cudaSuccess);
    CHECK(cudaMemset(out, 0xFF, 1024 * sizeof(uint)) == cudaSuccess);
    SILLAGE_LAUNCH(fillIndex, (count + 255) / 256, 256, out, count);
    bool ordered = true;
    for (uint i = 0; i < count; ++i) { ordered = ordered && out[i] == i; }
    CHECK(ordered);
    CHECK(out[count] == 0xFFFFFFFFu && out[1023] == 0xFFFFFFFFu);
    CHECK(cudaFree(out) == cudaSuccess);

    dim3 grid(3, 2, 2), block(4, 2, 3);
    unsigned int counter = 0;
    std::vector<unsigned int> seen(3 * 2 * 2 * 4 * 2 * 3, 0);
    SILLAGE_LAUNCH(countThreads, grid, block, &counter, seen.data());
    CHECK(counter == seen.size());
    CHECK(std::all_of(seen.begin(), seen.end(), [](unsigned int n) { return n == 1; }));
}

static void testCuda() {
    int i = 5;
    CHECK(atomicAdd(&i, 3) == 5 && i == 8);
    CHECK(atomicSub(&i, 2) == 8 && i == 6);
    CHECK(atomicMin(&i, 4) == 6 && i == 4);
    CHECK(atomicMin(&i, 9) == 4 && i == 4);
    CHECK(atomicMax(&i, 9) == 4 && i == 9);
    CHECK(atomicExch(&i, 1) == 9 && i == 1);
    CHECK(atomicCAS(&i, 2, 7) == 1 && i == 1);
    CHECK(atomicCAS(&i, 1, 7) == 1 && i == 7);
    unsigned long long wide = 1ull << 40;
    CHECK(atomicAdd(&wide, 1ull) == 1ull << 40 && wide == (1ull << 40) + 1);
    float f = 1.5f;
    CHECK(atomicAdd(&f, 2.0f) == 1.5f && f == 3.5f);
    CHECK(__ldg(&f) == 3.5f);

    char *host = nullptr;
    char *deviceMemory = nullptr;
    CHECK(cudaMallocHost(&host, 64) == cudaSuccess);
    CHECK(cudaMalloc(&deviceMemory, 64) == cudaSuccess);
    CHECK((reinterpret_cast<uintptr_t>(deviceMemory) & 255) == 0);
    for (int k = 0; k < 64; ++k) { host[k] = char(k); }
    CHECK(cudaMemcpy(deviceMemory, host, 64, cudaMemcpyHostToDevice) == cudaSuccess);
    CHECK(deviceMemory[63] == 63);
    CHECK(cudaFreeHost(host) == cudaSuccess && cudaFree(deviceMemory) == cudaSuccess);
    int devices = 0;
    CHECK(cudaGetDeviceCount(&devices) == cudaSuccess && devices == 1);
    CHECK(cudaDeviceSynchronize() == cudaSuccess && cudaGetLastError() == cudaSuccess);
    CHECK(::min(3, 5u) == 3u && ::max(2.0f, 3.0) == 3.0);
}

static void testVectors() {
    float4 v(1.0f, 2.0f, 3.0f, 4.0f);
    float3 a = v.xyz;
    CHECK(a.x == 1.0f && a.y == 2.0f && a.z == 3.0f);
    v.xyz = float3(5.0f, 6.0f, 7.0f);
    CHECK(v.x == 5.0f && v.z == 7.0f && v.w == 4.0f);
    v.xyz += a * 2.0f;
    CHECK(v.x == 7.0f && v.y == 10.0f && v.z == 13.0f && v.w == 4.0f);
    float4 other(0.0f, 0.0f, 0.0f, 9.0f);
    other.xyz = v.xyz;
    CHECK(other.x == 7.0f && other.z == 13.0f && other.w == 9.0f);
    CHECK(v.rgb.e[1] == 10.0f && v.r == 7.0f && v.a == 4.0f);
    float2 xy = v.xy;
    CHECK(xy.x == 7.0f && xy.y == 10.0f);
    v.xy = float2(1.0f, 1.0f);
    CHECK(v.x == 1.0f && v.y == 1.0f && v.z == 13.0f);
    CHECK(dot(v.xyz, float3(1.0f, 1.0f, 1.0f)) == 15.0f);
    float3 difference = v.xyz - a;
    CHECK(difference.x == 0.0f && difference.y == -1.0f && difference.z == 10.0f);
    float3 scaled = v.w * v.xyz;
    CHECK(scaled.z == 52.0f);
    float3 chosen = v.w > 0.0f ? v.xyz : float3(0.0f);
    CHECK(chosen.z == 13.0f);
    CHECK(float4(a, 1.0f).w == 1.0f && float4(xy, xy).z == 7.0f && float3(xy, 3.0f).z == 3.0f);

    float3 lower(3.0f, -1.0f, 2.0f);
    lower[1] = -4.0f;
    CHECK(lower.y == -4.0f && lower[2] == 2.0f);
    CHECK(all(lower <= float3(3.0f, 0.0f, 2.0f)) && !all(lower < 3.0f) && any(lower < -3.0f));
    CHECK(all(min(lower, float3(0.0f)) == float3(0.0f, -4.0f, 0.0f)));
    CHECK(all(max(lower, 0.0f) == float3(3.0f, 0.0f, 2.0f)));
    CHECK(all(clamp(lower, 0.0f, 2.5f) == float3(2.5f, 0.0f, 2.0f)));
    CHECK(all(select(lower, float3(9.0f), lower < 0.0f) == float3(3.0f, 9.0f, 2.0f)));
    CHECK(all(cross(float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f)) == float3(0.0f, 0.0f, 1.0f)));
    CHECK(length(float3(3.0f, 4.0f, 0.0f)) == 5.0f && distance(float2(1.0f, 1.0f), float2(4.0f, 5.0f)) == 5.0f);
    CHECK(all(normalize(float3(0.0f, 0.0f, 2.0f)) == float3(0.0f, 0.0f, 1.0f)));
    CHECK(all(mix(float3(0.0f), float3(2.0f, 4.0f, 8.0f), 0.5f) == float3(1.0f, 2.0f, 4.0f)));
    CHECK(all(-lower == float3(-3.0f, 4.0f, -2.0f)));

    uint3 q = uint3(float3(1.9f, 2.1f, 3.0f));
    CHECK(q.x == 1u && q.y == 2u && q.z == 3u);
    CHECK(all(((q << 2u) | 1u) == uint3(5u, 9u, 13u)) && all((q & 1u) == uint3(1u, 0u, 1u)));
    uint4 word(as_type<uint3>(float3(1.0f, 2.0f, 3.0f)), 77u);
    CHECK(word.x == 0x3F800000u && word.w == 77u);
    float3 back = as_type<float3>(word.xyz);
    CHECK(back.y == 2.0f);
    uint2 pair(3u, 4u);
    pair.x += 1u;
    CHECK(pair.x == 4u && all(pair == uint2(4u)));
    int2 cell = int2(-3, 5) % 4;
    CHECK(cell.x == -3 && cell.y == 1 && all(abs(int2(-3, 5)) == int2(3, 5)));

    float4x4 identity(float4(1.0f, 0.0f, 0.0f, 0.0f), float4(0.0f, 1.0f, 0.0f, 0.0f),
                      float4(0.0f, 0.0f, 1.0f, 0.0f), float4(1.0f, 2.0f, 3.0f, 1.0f));
    float4 moved = identity * float4(1.0f, 1.0f, 1.0f, 1.0f);
    CHECK(moved.x == 2.0f && moved.y == 3.0f && moved.z == 4.0f && moved.w == 1.0f);
    CHECK(sizeof(packed_float3) == 12 && float3(packed_float3(a)).z == 3.0f);

    static constexpr float3 table[2] = {float3(1.0f, 1.22f, 1.52f), float3(2.0f)};
    static_assert(table[0].y == 1.22f && table[1].z == 2.0f, "a vector constant is a constant");
    CHECK(table[1].x == 2.0f);
}

static void testFunctions() {
    CHECK(min(2.0f, 3.0f) == 2.0f && max(2u, 3u) == 3u && clamp(5, 0, 3) == 3);
    CHECK(saturate(1.5f) == 1.0f && saturate(-1.0f) == 0.0f && mix(2.0f, 4.0f, 0.25f) == 2.5f);
    CHECK(smoothstep(0.0f, 2.0f, 1.0f) == 0.5f && smoothstep(0.0f, 1.0f, 3.0f) == 1.0f);
    CHECK(fract(2.75f) == 0.75f && fract(-0.25f) == 0.75f && floor(-0.5f) == -1.0f);
    CHECK(sqrt(9.0f) == 3.0f && rsqrt(4.0f) == 0.5f && abs(-2.0f) == 2.0f && abs(-2) == 2);
    CHECK(exp2(3.0f) == 8.0f && log2(8.0f) == 3.0f && pow(2.0f, 10.0f) == 1024.0f);
    CHECK(ldexp(3.0f, -2) == 0.75f && fma(2.0f, 3.0f, 1.0f) == 7.0f && step(1.0f, 2.0f) == 1.0f);
    CHECK(isfinite(1.0f) && !isfinite(INFINITY) && !isfinite(NAN) && isnan(NAN) && isinf(-INFINITY));
    CHECK(popcount(0xF0F0u) == 8u && clz(1u) == 31u && ctz(8u) == 3u && clz(0u) == 32u);
    CHECK(as_type<uint>(1.0f) == 0x3F800000u && as_type<float>(0x40000000u) == 2.0f);
    CHECK(as_type<int>(as_type<float>(-7)) == -7);
    CHECK(select(1.0f, 2.0f, true) == 2.0f && select(1u, 2u, false) == 1u);
    CHECK(sizeof(half) == 4 && sizeof(half3) == 16 && half(0.5f) == 0.5f);
    CHECK(M_PI_F == 3.14159274f);

    atomic_uint counter = {5u};
    CHECK(atomic_fetch_add_explicit(&counter, 3u, memory_order_relaxed) == 5u);
    CHECK(atomic_load_explicit(&counter, memory_order_relaxed) == 8u);
    CHECK(atomic_fetch_min_explicit(&counter, 2u, memory_order_relaxed) == 8u && counter.value == 2u);
    CHECK(atomic_fetch_max_explicit(&counter, 9u, memory_order_relaxed) == 2u && counter.value == 9u);
    atomic_store_explicit(&counter, 1u, memory_order_relaxed);
    CHECK(counter.value == 1u);

    CHECK(simd_sum(3u) == 3u && simd_prefix_exclusive_sum(3u) == 0u && simd_broadcast(4u, 0) == 4u);
    CHECK(uint(static_cast<simd_vote::vote_t>(simd_ballot(true))) == 1u && simd_ballot(true).all());
}

static ulong spreadReference(uint value) {
    ulong out = 0;
    for (int bit = 0; bit < 21; ++bit) { out |= ulong((value >> bit) & 1u) << (3 * bit); }
    return out;
}

// The tree's functions that need no SIMD group, from GPUTreeShaders' own text.
static void testTreeText() {
    static_assert(tileSize == 2048 && buckets == 256 && counterUpper == 5, "the MSL's constants");
    const float ordered[] = {-INFINITY, -3.5f, -1e-30f, -0.0f, 0.0f, 1e-30f, 2.0f, INFINITY};
    for (int k = 0; k + 1 < 8; ++k) { CHECK(orderedFloat(ordered[k]) <= orderedFloat(ordered[k + 1])); }
    for (float value : ordered) { CHECK(bits(unorderedFloat(orderedFloat(value))) == bits(value)); }
    for (uint value : {0u, 1u, 0x155555u, 0x1FFFFFu, 0x0ABCDEu}) { CHECK(spread(value) == spreadReference(value)); }

    BHNode node;
    node.packed = float4(1.0f, as_type<float>(20000000), as_type<float>(-17), 0.0f);
    CHECK(bhRange(node) == 20000000 && bhSignedCount(node) == -17);

    const uint count = 300;
    std::vector<float3> positions(count);
    std::vector<float> mass(count);
    uint seed = 12345u;
    float3 lower(INFINITY), upper(-INFINITY);
    for (uint i = 0; i < count; ++i) {
        float3 p;
        for (int axis = 0; axis < 3; ++axis) {
            seed = seed * 1664525u + 1013904223u;
            p[axis] = float(seed >> 8) * (1.0f / 16777216.0f) * 20.0f - 10.0f;
        }
        positions[i] = p;
        mass[i] = 1.0f + float(i);
        lower = min(lower, p);
        upper = max(upper, p);
    }

    TreeParams p = {};
    p.count = count;
    p.nodeCapacity = count;
    std::vector<atomic_uint> counters(8);
    std::vector<uint> levels(24, 99u);
    for (uint gid = 0; gid < 24; ++gid) { treeReset(counters.data(), levels.data(), gid); }
    CHECK(counters[counterLower].value == 0xFFFFFFFFu && counters[counterUpper].value == 0u && levels[23] == 0u);
    for (uint axis = 0; axis < 3; ++axis) {
        atomic_fetch_min_explicit(&counters[counterLower + axis], orderedFloat(lower[axis]), memory_order_relaxed);
        atomic_fetch_max_explicit(&counters[counterUpper + axis], orderedFloat(upper[axis]), memory_order_relaxed);
    }
    std::vector<BHNode> nodes(count);
    float frame[8] = {};
    SILLAGE_LAUNCH(rootEntry, 1, 32, counters.data(), nodes.data(), frame, levels.data(), p);
    float3 extent = upper - lower;
    float radius = max(max(max(extent.x, extent.y), extent.z) * 0.5f, 1e-3f) * 1.001f;
    CHECK(frame[4] == radius && frame[3] == 2097151.0f / (2.0f * radius));
    CHECK(counters[counterNodes].value == 1u && bhSignedCount(nodes[0]) == -int(count));
    CHECK(nodes[0].packed.x == (radius * 2.0f) * (radius * 2.0f));

    std::vector<ulong> codes(count);
    std::vector<uint> order(count);
    SILLAGE_LAUNCH(mortonEntry, (count + 63) / 64, 64, positions.data(), codes.data(), order.data(), frame, p);
    bool same = true;
    for (uint i = 0; i < count; ++i) {
        float3 local = (positions[i] - float3(frame[0], frame[1], frame[2])) * frame[3];
        ulong code = (spreadReference(uint(local.x)) << 2) | (spreadReference(uint(local.y)) << 1)
                   | spreadReference(uint(local.z));
        same = same && codes[i] == code && order[i] == i;
    }
    CHECK(same);

    std::stable_sort(order.begin(), order.end(), [&](uint a, uint b) { return codes[a] < codes[b]; });
    std::vector<ulong> sortedCodes(count);
    for (uint slot = 0; slot < count; ++slot) { sortedCodes[slot] = codes[order[slot]]; }
    std::vector<float4> sorted(count);
    SILLAGE_LAUNCH(gatherEntry, (count + 63) / 64, 64, sorted.data(), positions.data(), mass.data(), order.data(), p);
    CHECK(sorted[7].w == mass[order[7]] && sorted[299].x == positions[order[299]].x);

    // Both ways of octantStarts, the scan up to 64 codes and the binary searches past it.
    for (uint length : {40u, count}) {
        uint offsets[9];
        octantStarts(sortedCodes.data(), 0, length, 60, offsets);
        bool right = offsets[0] == 0 && offsets[8] == length;
        for (uint digit = 0; digit < 8; ++digit) {
            for (uint k = offsets[digit]; k < offsets[digit + 1]; ++k) {
                right = right && uint((sortedCodes[k] >> 60) & 7ul) == digit;
            }
            right = right && offsets[digit] <= offsets[digit + 1];
        }
        CHECK(right);
    }
}

static int run() {
    testLaunch();
    testCuda();
    testVectors();
    testFunctions();
    testTreeText();
    std::printf("cuda/tests/compat.cu: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}

#endif

}  // namespace GPUTreeShaders
}  // namespace metal

#if defined(SILLAGE_CPU)
int main() { return metal::GPUTreeShaders::run(); }
#endif
