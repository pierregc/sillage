// The walk the massive solver shares (#274), on the CPU target, against the reference
// accelerations of Tests/Fixtures/engines/walk (#281): Metal's own for 1,000 light tracers over a
// tree of 5,012 massive particles. bhWalk and halos run here from the shared MSL, each tracer
// placed in the tree's frame as bhTracerStep places it, and must come within 1e-5 of Metal
// (docs/notes/one-kernel-source.md). The tracers' own kernel is #275's.
#include "cuda_cpu.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "BarnesHutShaders.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace BarnesHutShaders {

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/solver_fixture.cu: %s\n", what);
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

// TracerStepParams, as bhTracerStep reads it (docs/notes/cuda-walk-spike.md).
struct WalkParams {
    uint tracerCount;
    uint haloCount;
    float timeStep;
    float openingAngleSquared;
    float softeningSquared;
    float gravitationalConstant;
    uint chunkStart;
    uint sortChunk;
    uint holeCount;
    uint diskCount;
    uint mode;
    uint pad;
};

static int run(const std::string &root) {
    const std::string walk = root + "/walk/";
    std::vector<float4> states = load<float4>(walk + "states.bin");
    std::vector<float4> sorted = load<float4>(walk + "sorted.bin");
    std::vector<BHNode> nodes = load<BHNode>(walk + "nodes.bin");
    std::vector<float4> moments = load<float4>(walk + "moments.bin");
    std::vector<float> frame = load<float>(walk + "frame.bin");
    std::vector<HaloGPU> haloList = load<HaloGPU>(walk + "halos.bin");
    std::vector<WalkParams> params = load<WalkParams>(walk + "params.bin");
    std::vector<float3> reference = load<float3>(walk + "accelerations.bin");
    if (failures != 0) { return 1; }
    expect(params.size() == 1 && frame.size() == 8 && reference.size() == states.size(),
           "the walk fixture is not the one this reads");
    if (failures != 0) { return 1; }
    WalkParams p = params[0];
    // The fixture's run: the quadrupole, cells around a particle opened, no black hole.
    expect(p.holeCount == 0u && moments.size() == 2 * nodes.size() && p.haloCount <= haloList.size(),
           "the walk fixture has holes, no moments or too few halos: this test follows it no longer");
    if (failures != 0) { return 1; }

    size_t same = 0, far = 0;
    float worst = 0.0f;
    for (size_t i = 0; i < states.size(); ++i) {
        float3 position = states[i].xyz;
        const float resolution = 2097151.0f;
        float3 local = (position - float3(frame[0], frame[1], frame[2])) * frame[3];
        bool inRoot = all(local >= 0.0f) && all(local <= resolution);
        local = clamp(local, 0.0f, resolution);
        ulong code = (bhSpread(uint(local.x)) << 2) | (bhSpread(uint(local.y)) << 1) | bhSpread(uint(local.z));
        uint work = 0;
        float3 acceleration = bhWalk(position, code, inRoot, 0xFFFFFFFFu, sorted.data(), nodes.data(),
                                     moments.data(), p.openingAngleSquared, p.softeningSquared,
                                     p.gravitationalConstant, true, true, work) +
                              halos(position, haloList.data(), p.haloCount, true);
        float3 metal = reference[i];
        same += std::memcmp(&acceleration, &metal, 12) == 0 ? 1 : 0;
        float gap = length(acceleration - metal) / max(length(metal), 1e-30f);
        worst = max(worst, gap);
        far += gap > 1e-5f ? 1 : 0;
        expect(work > 0u, "a walk that visited no node");
    }
    std::printf("the walk of Tests/Fixtures/engines: %zu tracers over %zu massive particles in %zu nodes, "
                "from the MSL text on the CPU\n", states.size(), sorted.size(), nodes.size());
    std::printf("  accelerations %zu of %zu past 1e-5 of Metal's, the largest gap %.2e, %zu the same bits\n", far,
                states.size(), double(worst), same);
    expect(far == 0, "an acceleration further than 1e-5 from Metal's");
    return failures == 0 ? 0 : 1;
}

}  // namespace BarnesHutShaders
}  // namespace metal

int main(int argc, char **argv) {
    return metal::BarnesHutShaders::run(argc > 1 ? argv[1] : "Tests/Fixtures/engines");
}

#endif
