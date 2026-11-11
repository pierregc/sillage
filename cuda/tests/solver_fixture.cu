// The walk the solver shares, on the CPU target, against the reference outputs of
// Tests/Fixtures/engines/walk (#281): Metal's accelerations of 1,000 light tracers over a tree of
// 5,012 massive particles, and their velocities after one more step. bhWalk and halos run here
// from the shared MSL, each tracer placed in the tree's frame as bhTracerStep places it (#274);
// then bhTracerStep itself through sc_solver_tracer_step, over the fixture's tree laid out by
// sc_tree_upload (#275): its accelerations in mode 2 and its velocities in mode 1 within 1e-5 of
// Metal's, every packed word unchanged, and mode 1 twice the same bits; and bhTracerFormStars,
// whose tracer gas forms where the tree's slots give it a chance (docs/notes/one-kernel-source.md).
#include "cuda_cpu.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "sillage_cuda.h"
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

static bool ok(sc_status status, const char *what) {
    if (status == SC_OK) { return true; }
    std::printf("cuda/tests/solver_fixture.cu: %s: %s\n", what, sc_last_error());
    failures += 1;
    return false;
}

template <class T>
static bool identical(const std::vector<T> &a, const std::vector<T> &b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(T)) == 0;
}

template <class T>
static sc_buffer *made(sc_context *context, const std::vector<T> &items, size_t length = 0) {
    sc_buffer *buffer = nullptr;
    size_t bytes = std::max(length, items.size() * sizeof(T));
    if (!ok(sc_buffer_create(context, bytes, &buffer), "a buffer")) { return nullptr; }
    if (!items.empty()) { ok(sc_buffer_upload(buffer, 0, items.data(), items.size() * sizeof(T)), "an upload"); }
    return buffer;
}

template <class T>
static std::vector<T> read(const sc_buffer *buffer, size_t count, size_t offset = 0) {
    std::vector<T> items(count);
    ok(sc_buffer_download(buffer, offset, items.data(), count * sizeof(T)), "a download");
    return items;
}

// Where each depth starts in the fixture's canonical layout, level by level from the root, a
// parent's children contiguous: what sc_tree_upload asks.
static std::vector<uint32_t> levelStarts(const std::vector<BHNode> &nodes, uint32_t depths) {
    std::vector<uint32_t> starts(depths, uint32_t(nodes.size()));
    uint32_t start = 0, end = nodes.empty() ? 0u : 1u;
    for (uint32_t level = 0; level < depths; ++level) {
        starts[level] = start;
        uint32_t next = end;
        for (uint32_t index = start; index < end; ++index) {
            if (bhSignedCount(nodes[index]) > 0) { next += uint32_t(bhSignedCount(nodes[index])); }
        }
        start = end;
        end = next;
    }
    return starts;
}

// bhTracerStep through the C API, as CUDABarnesHutSolver runs it.
static int throughTheAPI(const std::string &root) {
    const std::string walk = root + "/walk/";
    std::vector<float4> states = load<float4>(walk + "states.bin");
    std::vector<uint4> motions = load<uint4>(walk + "motions.bin");
    std::vector<float4> sorted = load<float4>(walk + "sorted.bin");
    std::vector<BHNode> nodes = load<BHNode>(walk + "nodes.bin");
    std::vector<float> moments = load<float>(walk + "moments.bin");
    std::vector<uint> order = load<uint>(walk + "order.bin");
    std::vector<float> frame = load<float>(walk + "frame.bin");
    std::vector<HaloGPU> haloList = load<HaloGPU>(walk + "halos.bin");
    std::vector<HoleGPU> holes = load<HoleGPU>(walk + "holes.bin");
    std::vector<float4> massive = load<float4>(walk + "massive.bin");
    std::vector<DiskCooling> disks = load<DiskCooling>(walk + "disks.bin");
    std::vector<TracerStepParams> params = load<TracerStepParams>(walk + "params.bin");
    std::vector<float3> reference = load<float3>(walk + "accelerations.bin");
    std::vector<uint4> stepped = load<uint4>(walk + "motions-mode1.bin");
    if (failures != 0) { return 1; }
    uint32_t tracers = uint32_t(states.size()), count = uint32_t(massive.size());
    TracerStepParams p = params[0];
    expect(p.tracerCount == tracers && p.mode == 1u && p.chunkStart == 0u && motions.size() == tracers &&
               order.size() == tracers && stepped.size() == tracers && sorted.size() == count,
           "the walk fixture's tracer pass is not the one this runs");
    if (failures != 0) { return 1; }

    sc_context *context = nullptr;
    if (!ok(sc_context_create(0, &context), "a context")) { return 1; }
    const uint32_t depth = 20;
    sc_tree_config treeConfig = {count, 0u, 16u, depth, uint32_t(nodes.size()), 1, 0};
    sc_tree *tree = nullptr;
    ok(sc_tree_create(context, &treeConfig, &tree), "a tree");
    std::vector<uint32_t> starts = levelStarts(nodes, depth + 2);
    ok(sc_tree_upload(tree, nodes.data(), uint32_t(nodes.size()), moments.data(), nullptr, starts.data(),
                      frame.data()),
       "the fixture's tree");

    // [tracers | massive] in the positions and velocities, as on Metal.
    std::vector<float4> positions(states);
    positions.insert(positions.end(), massive.begin(), massive.end());
    std::vector<uint4> velocities(motions);
    velocities.resize(size_t(tracers) + count, uint4(0u));
    std::vector<float> zeros(count, 0.0f);
    sc_buffer *positionBuffer = made(context, positions), *velocityBuffer = made(context, velocities);
    sc_buffer *accelerations = made(context, std::vector<float4>(count)), *mass = made(context, zeros);
    sc_buffer *sortedBuffer = made(context, sorted), *formation = made(context, zeros);
    sc_buffer *component = made(context, std::vector<uint>(count, 0u)), *cost = made(context, zeros);
    sc_buffer *orderBuffer = made(context, order), *probe = made(context, std::vector<float4>(tracers));
    if (failures != 0) { return 1; }
    sc_solver_config config = {count, tracers, 1, 1, 0};
    sc_solver_buffers buffers = {positionBuffer, velocityBuffer, accelerations, mass,    sortedBuffer,
                                 formation,      component,      nullptr,       cost,    nullptr,
                                 orderBuffer};
    sc_solver *solver = nullptr;
    if (!ok(sc_solver_create(context, &config, &buffers, &solver), "a solver of the fixture")) { return 1; }

    auto pass = [&](TracerStepParams q, sc_buffer *into) {
        return ok(sc_solver_tracer_step(solver, tree, &q, sizeof q, tracers, haloList.data(), uint32_t(haloList.size()),
                                        holes.data(), uint32_t(holes.size()), disks.data(), uint32_t(disks.size()),
                                        into),
                  "sc_solver_tracer_step");
    };
    TracerStepParams probing = p;
    probing.mode = 2u;
    pass(probing, probe);
    std::vector<float4> probed = read<float4>(probe, tracers);
    size_t far = 0, same = 0;
    float worst = 0.0f;
    for (uint32_t i = 0; i < tracers; ++i) {
        float3 mine = probed[i].xyz, metal = reference[i];
        float gap = length(mine - metal) / max(length(metal), 1e-30f);
        worst = max(worst, gap);
        far += gap > 1e-5f ? 1 : 0;
        same += std::memcmp(&mine, &metal, 12) == 0 ? 1 : 0;
    }
    expect(identical(read<uint4>(velocityBuffer, tracers), motions), "mode 2 moved a tracer");
    std::printf("bhTracerStep through sc_solver_tracer_step, %u tracers sorted %u at a time, blocks of 64\n", tracers,
                p.sortChunk);
    std::printf("  mode 2: accelerations %zu past 1e-5 of Metal's, the largest gap %.2e, %zu the same bits\n", far,
                double(worst), same);
    expect(far == 0, "a mode 2 acceleration further than 1e-5 from Metal's");

    pass(p, nullptr);
    std::vector<uint4> once = read<uint4>(velocityBuffer, tracers);
    size_t farVelocity = 0, words = 0;
    float worstVelocity = 0.0f;
    for (uint32_t i = 0; i < tracers; ++i) {
        float3 mine = as_type<float3>(once[i].xyz), metal = as_type<float3>(stepped[i].xyz);
        float gap = length(mine - metal) / max(length(metal), 1e-30f);
        worstVelocity = max(worstVelocity, gap);
        farVelocity += gap > 1e-5f ? 1 : 0;
        words += once[i].w == stepped[i].w ? 0 : 1;
    }
    ok(sc_buffer_upload(velocityBuffer, 0, motions.data(), motions.size() * sizeof(uint4)), "the motions again");
    pass(p, nullptr);
    bool repeats = identical(read<uint4>(velocityBuffer, tracers), once);
    std::printf("  mode 1: velocities %zu past 1e-5 of Metal's, the largest gap %.2e, %zu words changed, "
                "the same bits twice: %s\n", farVelocity, double(worstVelocity), words, repeats ? "yes" : "no");
    expect(farVelocity == 0 && words == 0, "a mode 1 velocity further than 1e-5 from Metal's, or a word changed");
    expect(repeats, "mode 1 twice gave other bits");
    expect(identical(read<float4>(positionBuffer, tracers), states), "the tracer pass moved a position");

    TracerStepParams wrong = p;
    wrong.sortChunk = 0u;
    expect(sc_solver_tracer_step(solver, tree, &wrong, sizeof wrong, tracers, haloList.data(), 1u, holes.data(), 1u,
                                 disks.data(), uint32_t(disks.size()), nullptr) == SC_INVALID_ARGUMENT,
           "a walk order sorted 0 at a time was taken");
    expect(sc_solver_tracer_step(solver, tree, &probing, sizeof probing, tracers, haloList.data(), 1u, holes.data(),
                                 1u, disks.data(), uint32_t(disks.size()), nullptr) == SC_INVALID_ARGUMENT,
           "mode 2 without a probe was taken");

    // bhTracerFormStars through sc_solver_tracer_form_stars, over the tree's codes: with every
    // slot's chance at 1 each gas tracer whose stars have not formed forms them now, at -1 none.
    std::vector<ulong> codes(count);
    for (uint32_t slot = 0; slot < count; ++slot) {
        float3 local = clamp((sorted[slot].xyz - float3(frame[0], frame[1], frame[2])) * frame[3], 0.0f, 2097151.0f);
        codes[slot] = (bhSpread(uint(local.x)) << 2) | (bhSpread(uint(local.y)) << 1) | bhSpread(uint(local.z));
    }
    expect(std::is_sorted(codes.begin(), codes.end()), "the fixture's sorted particles are not in Morton order");
    ok(sc_buffer_upload(sc_tree_buffer_of(tree, SC_TREE_CODES_BUFFER), 0, codes.data(), codes.size() * 8u),
       "the tree's codes");
    sc_buffer *chances = made(context, std::vector<float>(count, 1.0f));
    sc_solver_config forming = {count, tracers, 1, 1, 1};
    sc_solver_buffers withChances = buffers;
    withChances.slot_chances = chances;
    sc_solver *former = nullptr;
    ok(sc_solver_create(context, &forming, &withChances, &former), "a solver whose leaves write their chances");
    SFParams formation_params = {};
    formation_params.time = 12.5f;
    formation_params.seed = 7u;
    formation_params.nodeCount = uint(nodes.size());
    size_t gas = 0, formed = 0, otherwise = 0;
    for (float chance : {1.0f, -1.0f}) {
        ok(sc_buffer_upload(positionBuffer, 0, states.data(), states.size() * sizeof(float4)), "the states again");
        std::vector<float> every(count, chance);
        ok(sc_buffer_upload(chances, 0, every.data(), every.size() * 4u), "the chances");
        ok(sc_solver_tracer_form_stars(former, tree, &formation_params, sizeof formation_params),
           "sc_solver_tracer_form_stars");
        std::vector<float4> after = read<float4>(positionBuffer, tracers);
        for (uint32_t i = 0; i < tracers; ++i) {
            bool forms = chance > 0.0f && ((motions[i].w >> 4) & 7u) == 2u && states[i].w >= 1e8f;
            gas += chance > 0.0f && ((motions[i].w >> 4) & 7u) == 2u ? 1 : 0;
            formed += forms ? 1 : 0;
            float4 expected = states[i];
            if (forms) { expected.w = formation_params.time; }
            otherwise += std::memcmp(&after[i], &expected, 16) == 0 ? 0 : 1;
        }
    }
    std::printf("bhTracerFormStars through sc_solver_tracer_form_stars: %zu of %zu gas tracers formed at a chance"
                " of 1, none at -1, %zu tracers otherwise than expected\n", formed, gas, otherwise);
    expect(formed > 0 && otherwise == 0, "the tracers' star formation wrote otherwise than its rule");
    sc_solver_destroy(former);
    sc_buffer_destroy(chances);

    sc_solver_destroy(solver);
    for (sc_buffer *buffer : {positionBuffer, velocityBuffer, accelerations, mass, sortedBuffer, formation, component,
                              cost, orderBuffer, probe}) {
        sc_buffer_destroy(buffer);
    }
    sc_tree_destroy(tree);
    sc_context_destroy(context);
    return failures == 0 ? 0 : 1;
}

static int run(const std::string &root) {
    const std::string walk = root + "/walk/";
    std::vector<float4> states = load<float4>(walk + "states.bin");
    std::vector<float4> sorted = load<float4>(walk + "sorted.bin");
    std::vector<BHNode> nodes = load<BHNode>(walk + "nodes.bin");
    std::vector<float4> moments = load<float4>(walk + "moments.bin");
    std::vector<float> frame = load<float>(walk + "frame.bin");
    std::vector<HaloGPU> haloList = load<HaloGPU>(walk + "halos.bin");
    std::vector<TracerStepParams> params = load<TracerStepParams>(walk + "params.bin");
    std::vector<float3> reference = load<float3>(walk + "accelerations.bin");
    if (failures != 0) { return 1; }
    expect(params.size() == 1 && frame.size() == 8 && reference.size() == states.size(),
           "the walk fixture is not the one this reads");
    if (failures != 0) { return 1; }
    TracerStepParams p = params[0];
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
    return failures == 0 ? throughTheAPI(root) : 1;
}

}  // namespace BarnesHutShaders
}  // namespace metal

int main(int argc, char **argv) {
    return metal::BarnesHutShaders::run(argc > 1 ? argv[1] : "Tests/Fixtures/engines");
}

#endif
