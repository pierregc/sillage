// The tree's CUDA entry points on the CPU target (#273), on the tree of Tests/Fixtures/engines.
// The four of the cells' phases that need no barrier are launched one by one; the masses, the
// smoothing lengths and the spacing records run through the C API over the fixture's cells laid
// out by sc_tree_upload, as CUDATreeBuilder does on the CPU target. Metal's bits are required,
// the lengths aside (1e-6, as in tree_fixture.cu). The seven kernels with block barriers or
// warp functions run on a GPU in #283.
#include "cuda_cpu.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sillage_cuda.h"
#include "GPUTreeShaders.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace GPUTreeShaders {

// The entry points of cuda/src/tree.cu launched here.
__global__ void gtReset(atomic_uint *counters, uint *levels);
__global__ void gtRoot(atomic_uint *counters, BHNode *nodes, float *frame, uint *levels, TreeParams p);
__global__ void gtMorton(const float3 *positions, ulong *codes, uint *order, const float *frame, TreeParams p);
__global__ void gtCloseLevel(atomic_uint *counters, uint *levels, TreeParams p);

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/tree_entries.cu: %s\n", what);
}

static void report(const char *name, size_t different, size_t total) {
    std::printf("  %-10s %zu of %zu differ\n", name, different, total);
    if (different != 0) { failures += 1; }
}

template <class T>
static std::vector<T> load(const std::string &path) {
    std::vector<T> items;
    std::FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) {
        expect(false, ("cannot open " + path).c_str());
        return items;
    }
    std::fseek(file, 0, SEEK_END);
    long bytes = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    items.resize(size_t(bytes) / sizeof(T));
    size_t read = std::fread(items.data(), sizeof(T), items.size(), file);
    std::fclose(file);
    expect(size_t(bytes) % sizeof(T) == 0 && read == items.size(), ("a short read of " + path).c_str());
    return items;
}

template <class T>
static size_t differing(const std::vector<T> &mine, const std::vector<T> &theirs) {
    if (mine.size() != theirs.size()) { return std::max(mine.size(), theirs.size()); }
    size_t count = 0;
    for (size_t i = 0; i < mine.size(); ++i) { count += std::memcmp(&mine[i], &theirs[i], sizeof(T)) != 0 ? 1 : 0; }
    return count;
}

static bool ok(sc_status status, const char *what) {
    if (status == SC_OK) { return true; }
    std::printf("cuda/tests/tree_entries.cu: %s: %s, %s\n", what, sc_status_name(status), sc_last_error());
    failures += 1;
    return false;
}

// Within 1e-6 relative, as no two pow round alike.
static size_t far(const std::vector<float> &mine, const std::vector<float> &theirs) {
    if (mine.size() != theirs.size()) { return std::max(mine.size(), theirs.size()); }
    size_t count = 0;
    for (size_t i = 0; i < mine.size(); ++i) {
        float gap = mine[i] == theirs[i] ? 0.0f : abs(mine[i] - theirs[i]) / max(abs(theirs[i]), 1e-30f);
        count += gap > 1e-6f ? 1 : 0;
    }
    return count;
}

static void cellsEntryPoints(const std::string &tree, const std::vector<float3> &positions, TreeParams p) {
    std::vector<atomic_uint> counters(8);
    for (atomic_uint &counter : counters) { counter.value = 7u; }
    std::vector<uint> levels(24, 7u);
    SILLAGE_LAUNCH(gtReset, dim3(1), dim3(32), counters.data(), levels.data());
    bool reset = std::all_of(levels.begin(), levels.end(), [](uint level) { return level == 0u; });
    for (uint k = 0; k < 8u; ++k) {
        reset = reset && counters[k].value == (k >= counterLower && k < counterUpper ? 0xFFFFFFFFu : 0u);
    }
    expect(reset, "gtReset left the counters or the levels otherwise than Metal");

    // The bounds as gtBounds takes them, with the same ordered integers.
    for (const float3 &position : positions) {
        if (!(isfinite(position.x) && isfinite(position.y) && isfinite(position.z))) { continue; }
        for (uint axis = 0; axis < 3u; ++axis) {
            uint key = orderedFloat(position[axis]);
            uint &lower = counters[counterLower + axis].value;
            uint &upper = counters[counterUpper + axis].value;
            lower = key < lower ? key : lower;
            upper = key > upper ? key : upper;
        }
    }
    std::vector<BHNode> nodes(p.nodeCapacity);
    std::vector<float> frame(8, 0.0f);
    SILLAGE_LAUNCH(gtRoot, dim3(1), dim3(32), counters.data(), nodes.data(), frame.data(), levels.data(), p);
    report("frame", differing(frame, load<float>(tree + "frame.bin")), frame.size());
    expect(counters[counterNodes].value == 1u, "gtRoot did not make one root");

    const uint count = p.count;
    std::vector<ulong> codes(count);
    std::vector<uint> order(count, 0u);
    SILLAGE_LAUNCH(gtMorton, dim3((count + 255u) / 256u), dim3(256), positions.data(), codes.data(), order.data(),
                   frame.data(), p);
    bool numbered = true;
    for (uint i = 0; i < count; ++i) { numbered = numbered && order[i] == i; }
    expect(numbered, "gtMorton did not number the particles");
    std::stable_sort(order.begin(), order.end(), [&](uint a, uint b) { return codes[a] < codes[b]; });
    report("order", differing(order, load<uint>(tree + "order.bin")), order.size());

    p.level = 0u;
    SILLAGE_LAUNCH(gtCloseLevel, dim3(1), dim3(32), counters.data(), levels.data(), p);
    expect(levels[1] == 1u, "gtCloseLevel did not close the root's level");
}

static void throughTheAPI(const std::string &tree, const std::vector<float3> &positions,
                          const std::vector<float> &mass, TreeParams p, uint drawn, float ratio) {
    expect(sc_build_target() == SC_TARGET_CPU, "the CPU target says it is the GPU's");
    sc_context *context = nullptr;
    if (!ok(sc_context_create(0, &context), "sc_context_create")) { return; }
    sc_context *other = nullptr;
    expect(sc_context_create(1, &other) == SC_NO_DEVICE && std::strstr(sc_last_error(), "no device 1"),
           "a second device was found on the CPU target");

    std::vector<BHNode> fixture = load<BHNode>(tree + "nodes.bin");
    std::vector<float4> moments = load<float4>(tree + "moments.bin");
    std::vector<uint> order = load<uint>(tree + "order.bin");
    std::vector<uint> levels = load<uint>(tree + "levels.bin");
    std::vector<float> frame = load<float>(tree + "frame.bin");
    std::vector<float> smoothing = load<float>(tree + "smoothing.bin");
    std::vector<uint2> spacing = load<uint2>(tree + "spacing.bin");
    if (failures != 0) { return; }
    // The cells, as the cells' phases leave them: no mass yet.
    std::vector<BHNode> cells = fixture;
    for (BHNode &cell : cells) { cell.comMass = float4(0.0f); }
    const uint count = p.count;
    const uint nodeCount = uint(fixture.size());

    sc_buffer *positionBuffer = nullptr, *massBuffer = nullptr, *sorted = nullptr, *lengths = nullptr;
    ok(sc_buffer_create(context, count * 16u, &positionBuffer), "positions");
    ok(sc_buffer_create(context, count * 4u, &massBuffer), "masses");
    ok(sc_buffer_create(context, count * 16u, &sorted), "sorted");
    ok(sc_buffer_create(context, drawn * 4u, &lengths), "lengths");
    ok(sc_buffer_upload(positionBuffer, 0, positions.data(), count * 16u), "uploading the positions");
    ok(sc_buffer_upload(massBuffer, 0, mass.data(), count * 4u), "uploading the masses");
    expect(sc_buffer_upload(massBuffer, 4, mass.data(), count * 4u) == SC_INVALID_ARGUMENT,
           "an upload past the end of a buffer went through");

    for (uint capacity : {nodeCount, 1000u}) {
        sc_tree_config config = {count, 0u, p.leafCapacity, p.maximumDepth, capacity, 1, 1};
        sc_tree *built = nullptr;
        if (!ok(sc_tree_create(context, &config, &built), "sc_tree_create")) { continue; }
        expect(sc_tree_build(built, positionBuffer, massBuffer, sorted) == SC_GPU_ONLY &&
                   std::strstr(sc_last_error(), "#283"),
               "a build with block barriers ran on the CPU target");
        uint grown = 0;
        int32_t overflowed = 1;
        uint32_t nodesBuilt = 0;
        while (overflowed && grown < 8u) {
            ok(sc_tree_upload(built, cells.data(), nodeCount, nullptr, order.data(), levels.data(), frame.data()),
               "sc_tree_upload");
            ok(sc_tree_state(built, &nodesBuilt, &overflowed), "sc_tree_state");
            if (overflowed) {
                ok(sc_tree_grow(built), "sc_tree_grow");
                grown += 1;
            }
        }
        expect(!overflowed && nodesBuilt == nodeCount && (capacity == nodeCount) == (grown == 0u),
               "the tree did not grow to hold its nodes, or grew when it held them");
        ok(sc_tree_build_phase(built, SC_TREE_MASSES, positionBuffer, massBuffer, sorted), "the masses");

        std::vector<BHNode> nodes(nodeCount);
        std::vector<float4> builtMoments(2u * nodeCount);
        std::vector<uint> starts(p.maximumDepth + 2u);
        ok(sc_buffer_download(sc_tree_buffer_of(built, SC_TREE_NODES_BUFFER), 0, nodes.data(), nodeCount * 32u),
           "downloading the nodes");
        ok(sc_buffer_download(sc_tree_buffer_of(built, SC_TREE_MOMENTS_BUFFER), 0, builtMoments.data(),
                              nodeCount * 32u),
           "downloading the moments");
        ok(sc_tree_level_starts(built, starts.data(), uint(starts.size())), "sc_tree_level_starts");
        std::printf("the masses of %u nodes from the fixture's cells, a node capacity of %u grown %u times\n",
                    nodeCount, capacity, grown);
        report("nodes", differing(nodes, fixture), nodes.size());
        report("moments", differing(builtMoments, moments), builtMoments.size());
        report("levels", differing(starts, levels), starts.size());

        std::vector<float> builtLengths(drawn);
        ok(sc_tree_smoothing(built, lengths, drawn, ratio), "sc_tree_smoothing");
        ok(sc_buffer_download(lengths, 0, builtLengths.data(), drawn * 4u), "downloading the lengths");
        ok(sc_tree_spacing(built, drawn, ratio), "sc_tree_spacing");
        std::vector<uint2> records(nodeCount);
        ok(sc_buffer_download(sc_tree_buffer_of(built, SC_TREE_SPACING_BUFFER), 0, records.data(), nodeCount * 8u),
           "downloading the spacing records");
        std::vector<float> recordLengths(nodeCount), theirLengths(nodeCount);
        size_t links = 0;
        for (uint n = 0; n < nodeCount; ++n) {
            recordLengths[n] = as_type<float>(records[n].x);
            theirLengths[n] = as_type<float>(spacing[n].x);
            links += records[n].y != spacing[n].y ? 1 : 0;
        }
        size_t past = far(builtLengths, smoothing) + far(recordLengths, theirLengths);
        std::printf("  %-10s %zu of %zu past 1e-6\n", "lengths", past, builtLengths.size() + recordLengths.size());
        if (past != 0) { failures += 1; }
        report("links", links, records.size());
        sc_tree_destroy(built);
    }

    for (sc_buffer *buffer : {positionBuffer, massBuffer, sorted, lengths}) { sc_buffer_destroy(buffer); }
    sc_context_destroy(context);
}

static int run(const std::string &root) {
    const std::string tree = root + "/tree/";
    std::vector<float3> positions = load<float3>(tree + "positions.bin");
    std::vector<float> mass = load<float>(tree + "mass.bin");
    if (failures != 0) { return 1; }
    // The fixture's tree: leaf capacity 16, depth 20, quadrupoles, 16,000 drawn each for 4.
    TreeParams p = {};
    p.count = uint(positions.size());
    p.leafCapacity = 16u;
    p.maximumDepth = 20u;
    p.nodeCapacity = p.count;
    p.moments = 1u;
    std::printf("the tree's entry points on the CPU target, over %s: %u particles\n", root.c_str(), p.count);
    cellsEntryPoints(tree, positions, p);
    throughTheAPI(tree, positions, mass, p, 16000u, 4.0f);
    return failures == 0 ? 0 : 1;
}

}  // namespace GPUTreeShaders
}  // namespace metal

int main(int argc, char **argv) {
    return metal::GPUTreeShaders::run(argc > 1 ? argv[1] : "Tests/Fixtures/engines");
}

#endif
