// The tree of Tests/Fixtures/engines, built on the CPU target from GPUTreeShaders' own text and
// compared with what Metal gave, to the bit (#281). A SIMD group of one lane and one thread a
// dispatch make the bounds and the split run here, and lay the nodes out in the fixture's
// canonical order; a stable sort stands in for the radix kernels, which need 32 lanes.
#include "cuda_cpu.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "kernels.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace GPUTreeShaders {

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/tree_fixture.cu: %s\n", what);
}

template <class T>
static std::vector<T> load(const std::string &path) {
    std::vector<T> items;
    std::FILE *file = std::fopen(path.c_str(), "rb");
    if (!file) {
        std::printf("cuda/tests/tree_fixture.cu: cannot open %s\n", path.c_str());
        failures += 1;
        return items;
    }
    std::fseek(file, 0, SEEK_END);
    long bytes = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);
    items.resize(size_t(bytes) / sizeof(T));
    if (size_t(bytes) % sizeof(T) != 0 || std::fread(items.data(), sizeof(T), items.size(), file) != items.size()) {
        std::printf("cuda/tests/tree_fixture.cu: %s is not whole %zu byte items\n", path.c_str(), sizeof(T));
        failures += 1;
    }
    std::fclose(file);
    return items;
}

// The number that follows "key": in the manifest. The keys read here are in it once.
static double number(const std::string &manifest, const char *key) {
    std::string quoted = std::string("\"") + key + "\"";
    size_t at = manifest.find(quoted);
    if (at == std::string::npos || manifest.find(quoted, at + 1) != std::string::npos) {
        std::printf("cuda/tests/tree_fixture.cu: the manifest does not hold \"%s\" once\n", key);
        failures += 1;
        return 0;
    }
    at = manifest.find(':', at);
    return std::strtod(manifest.c_str() + at + 1, nullptr);
}

template <class T>
static size_t differing(const std::vector<T> &mine, const std::vector<T> &theirs) {
    if (mine.size() != theirs.size()) { return std::max(mine.size(), theirs.size()); }
    size_t count = 0;
    for (size_t i = 0; i < mine.size(); ++i) {
        count += std::memcmp(&mine[i], &theirs[i], sizeof(T)) != 0 ? 1 : 0;
    }
    return count;
}

static void report(const char *name, size_t different, size_t total) {
    std::printf("  %-10s %zu of %zu differ\n", name, different, total);
    if (different != 0) { failures += 1; }
}

static int run(const std::string &root) {
    const std::string tree = root + "/tree/";
    // Until the fixtures are on the branch; a fixture with a manifest is compared whole.
    if (std::FILE *probe = std::fopen((root + "/manifest.json").c_str(), "rb")) {
        std::fclose(probe);
    } else {
        std::printf("cuda/tests/tree_fixture.cu: no %s/manifest.json yet, nothing compared\n", root.c_str());
        return 0;
    }
    std::vector<char> text = load<char>(root + "/manifest.json");
    std::string manifest(text.begin(), text.end());
    std::vector<float3> positions = load<float3>(tree + "positions.bin");
    std::vector<float> mass = load<float>(tree + "mass.bin");
    if (failures != 0) { return 1; }

    const uint count = uint(positions.size());
    TreeParams p = {};
    p.count = count;
    p.leafCapacity = uint(number(manifest, "leafCapacity"));
    p.maximumDepth = uint(number(manifest, "maximumDepth"));
    p.nodeCapacity = count;
    p.moments = 1u;
    const uint drawnCount = uint(number(manifest, "drawnCount"));
    const float ratio = float(number(manifest, "ratio"));
    expect(mass.size() == count && p.leafCapacity > 0u && p.maximumDepth > 0u && p.maximumDepth <= 21u,
           "the manifest and the inputs do not make a tree");
    if (failures != 0) { return 1; }

    std::vector<atomic_uint> counters(8);
    std::vector<uint> levels(24);
    std::vector<BHNode> nodes(p.nodeCapacity);
    std::vector<float4> moments(2 * size_t(p.nodeCapacity));
    std::vector<float> frame(8, 0.0f);
    std::vector<ulong> codes(count);
    std::vector<uint> order(count);
    const uint *flags = &counters[0].value;

    // One thread, alone in its SIMD group and its threadgroup.
    for (uint gid = 0; gid < 32u; ++gid) { treeReset(counters.data(), levels.data(), gid); }
    float3 lowers[32], uppers[32];
    treeBounds(positions.data(), counters.data(), p, 0u, 1u, 0u, 0u, 0u, 1u, lowers, uppers);
    treeRoot(counters.data(), nodes.data(), frame.data(), levels.data(), p, 0u);
    for (uint i = 0; i < count; ++i) { treeMorton(positions.data(), codes.data(), order.data(), frame.data(), p, i); }

    std::stable_sort(order.begin(), order.end(), [&](uint a, uint b) { return codes[a] < codes[b]; });
    std::vector<ulong> sortedCodes(count);
    for (uint slot = 0; slot < count; ++slot) { sortedCodes[slot] = codes[order[slot]]; }

    for (uint level = 0; level <= p.maximumDepth; ++level) {
        p.level = level;
        treeCloseLevel(counters.data(), levels.data(), p, 0u);
        if (level == p.maximumDepth) { break; }
        treeSplit(nodes.data(), sortedCodes.data(), counters.data(), levels.data(), frame.data(), p, 0u, 1u, 0u);
    }
    expect(flags[counterOverflow] == 0u, "the build ran out of nodes");
    const uint nodeCount = flags[counterNodes];

    std::vector<float4> sorted(count);
    for (uint slot = 0; slot < count; ++slot) { treeGather(sorted.data(), positions.data(), mass.data(), order.data(), p, slot); }
    treeLeafSums(nodes.data(), sorted.data(), levels.data(), p, moments.data(), flags, 0u, 1u);
    for (uint level = p.maximumDepth; level-- > 0u;) {
        p.level = level;
        treeFold(nodes.data(), levels.data(), p, flags, 0u, 1u);
    }
    treeNormalize(nodes.data(), levels.data(), p, flags, 0u, 1u);
    for (uint level = p.maximumDepth; level-- > 0u;) {
        p.level = level;
        treeFoldMoments(nodes.data(), levels.data(), p, moments.data(), flags, 0u, 1u);
    }

    std::vector<float> smoothing(drawnCount, 0.0f);
    treeSmoothing(smoothing.data(), nodes.data(), order.data(), levels.data(), flags, p, drawnCount, ratio, 0u, 1u);
    std::vector<uint2> spacing(nodeCount);
    treeSpacingLeaves(spacing.data(), nodes.data(), order.data(), levels.data(), flags, p, drawnCount, 0u, 1u);
    for (uint level = p.maximumDepth; level-- > 0u;) {
        p.level = level;
        treeSpacingFold(spacing.data(), nodes.data(), levels.data(), flags, p, 0u, 1u);
    }
    treeSpacingLengths(spacing.data(), nodes.data(), levels.data(), flags, p, ratio, 0u, 1u);

    nodes.resize(nodeCount);
    moments.resize(2 * size_t(nodeCount));
    levels.resize(p.maximumDepth + 2u);

    std::printf("the tree of %s: %u particles, %u nodes, built from the MSL text on the CPU\n",
                root.c_str(), count, nodeCount);
    report("frame", differing(frame, load<float>(tree + "frame.bin")), frame.size());
    report("order", differing(order, load<uint>(tree + "order.bin")), order.size());
    report("levels", differing(levels, load<uint>(tree + "levels.bin")), levels.size());
    report("nodes", differing(nodes, load<BHNode>(tree + "nodes.bin")), nodes.size());
    report("moments", differing(moments, load<float4>(tree + "moments.bin")), moments.size());

    // The lengths go through pow, which no two math libraries round alike: held to 1e-6. The
    // drawn counts and the links of the spacing records are integers, to the bit.
    std::vector<float> theirSmoothing = load<float>(tree + "smoothing.bin");
    std::vector<uint2> theirSpacing = load<uint2>(tree + "spacing.bin");
    expect(theirSmoothing.size() == smoothing.size() && theirSpacing.size() == spacing.size(),
           "smoothing.bin or spacing.bin has another count");
    if (failures != 0) { return 1; }
    size_t far = 0, exact = 0, links = 0;
    float worst = 0.0f;
    auto compare = [&](float mine, float theirs) {
        exact += as_type<uint>(mine) == as_type<uint>(theirs) ? 1 : 0;
        float gap = abs(mine - theirs) / max(abs(theirs), 1e-30f);
        if (mine == theirs) { gap = 0.0f; }
        worst = max(worst, gap);
        far += gap > 1e-6f ? 1 : 0;
    };
    for (size_t i = 0; i < smoothing.size(); ++i) { compare(smoothing[i], theirSmoothing[i]); }
    for (size_t n = 0; n < spacing.size(); ++n) {
        compare(as_type<float>(spacing[n].x), as_type<float>(theirSpacing[n].x));
        links += spacing[n].y != theirSpacing[n].y ? 1 : 0;
    }
    size_t lengths = smoothing.size() + spacing.size();
    std::printf("  %-10s %zu of %zu past 1e-6, the largest gap %.2e, %zu the same bits\n", "lengths",
                far, lengths, double(worst), exact);
    report("links", links, spacing.size());
    if (far != 0) { failures += 1; }
    return failures == 0 ? 0 : 1;
}

}  // namespace GPUTreeShaders
}  // namespace metal

int main(int argc, char **argv) {
    return metal::GPUTreeShaders::run(argc > 1 ? argv[1] : "Tests/Fixtures/engines");
}

#endif
