// The light tracers' walk from the MSL text, built with nvcc for the GPU or with a host
// compiler through cuda_cpu.h, run against a dump of a Metal run (#271).
//
//   walk <dump-dir> [--top N] [--block N]
//
// Mode 2 over every tracer against Metal's accelerations, then mode 1 twice on copies of the
// motions, which must come out the same to the bit.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <string>
#include <vector>

#include "cuda_cpu.h"
#include "walk_msl.h"
#include "msl_end.h"

// What dispatchThreads gives the Metal kernel: one thread per index below `threads`.
__global__ void bhTracerStepEntry(float4 *states, uint4 *motions, const float4 *sorted,
                                  const BHNode *nodes, const float4 *moments, const uint *order,
                                  const float *frame, HaloGPU *haloList, HoleGPU *holes,
                                  const float3 *massive, DiskCooling *disks, TracerStepParams p,
                                  float3 *probe,
                                  uint threads) {
    uint gid = blockIdx.x * blockDim.x + threadIdx.x;
    if (gid >= threads) { return; }
    bhTracerStep(states, motions, sorted, nodes, moments, order, frame, haloList, holes, massive,
                 disks, p, probe, gid);
}

static_assert(sizeof(BHNode) == 32, "");
static_assert(sizeof(HaloGPU) == 48, "");
static_assert(sizeof(HoleGPU) == 32, "");
static_assert(sizeof(DiskCooling) == 64, "");
static_assert(sizeof(TracerStepParams) == 48, "");

#define CHECK(call)                                                                     \
    do {                                                                                \
        cudaError_t e = (call);                                                         \
        if (e != cudaSuccess) {                                                         \
            std::fprintf(stderr, "%s:%d: %s\n", __FILE__, __LINE__, cudaGetErrorString(e)); \
            std::exit(1);                                                               \
        }                                                                               \
    } while (0)

[[noreturn]] static void fail(const std::string &message) {
    std::fprintf(stderr, "walk: %s\n", message.c_str());
    std::exit(1);
}

struct Json {
    enum Kind { Null, Bool, Number, String, Array, Object } kind = Null;
    bool boolean = false;
    double number = 0;
    std::string text;
    std::vector<Json> items;
    std::map<std::string, Json> fields;

    const Json &operator[](const std::string &key) const {
        static const Json none;
        auto it = fields.find(key);
        return it == fields.end() ? none : it->second;
    }
    bool has(const std::string &key) const { return fields.count(key) != 0; }
};

struct JsonReader {
    const char *p;
    const char *end;

    void space() {
        while (p < end && (*p == ' ' || *p == '\n' || *p == '\r' || *p == '\t')) { ++p; }
    }
    void expect(char c) {
        space();
        if (p >= end || *p != c) { fail(std::string("manifest: expected '") + c + "'"); }
        ++p;
    }
    std::string string() {
        expect('"');
        std::string out;
        while (p < end && *p != '"') {
            if (*p == '\\' && p + 1 < end) { ++p; }
            out += *p++;
        }
        expect('"');
        return out;
    }
    Json value() {
        space();
        Json v;
        if (p >= end) { fail("manifest: unexpected end"); }
        if (*p == '{') {
            v.kind = Json::Object;
            ++p;
            space();
            if (*p == '}') { ++p; return v; }
            for (;;) {
                std::string key = string();
                expect(':');
                v.fields[key] = value();
                space();
                if (*p == ',') { ++p; continue; }
                expect('}');
                return v;
            }
        }
        if (*p == '[') {
            v.kind = Json::Array;
            ++p;
            space();
            if (*p == ']') { ++p; return v; }
            for (;;) {
                v.items.push_back(value());
                space();
                if (*p == ',') { ++p; continue; }
                expect(']');
                return v;
            }
        }
        if (*p == '"') {
            v.kind = Json::String;
            v.text = string();
            return v;
        }
        if (!std::strncmp(p, "true", 4)) { v.kind = Json::Bool; v.boolean = true; p += 4; return v; }
        if (!std::strncmp(p, "false", 5)) { v.kind = Json::Bool; p += 5; return v; }
        if (!std::strncmp(p, "null", 4)) { p += 4; return v; }
        char *after = nullptr;
        v.number = std::strtod(p, &after);
        if (after == p) { fail("manifest: bad value"); }
        v.kind = Json::Number;
        p = after;
        return v;
    }
};

static std::vector<unsigned char> readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) { fail("cannot read " + path); }
    return std::vector<unsigned char>(std::istreambuf_iterator<char>(in), {});
}

struct Buffer {
    std::vector<unsigned char> bytes;
    size_t count = 0;
    size_t stride = 0;
    template <class T>
    const T *as() const { return reinterpret_cast<const T *>(bytes.data()); }
};

struct Dump {
    std::string dir;
    Json manifest;
    std::map<std::string, Buffer> buffers;
    TracerStepParams params;

    bool has(const std::string &name) const { return buffers.count(name) != 0; }
    const Buffer &operator[](const std::string &name) const { return buffers.at(name); }
};

static Dump load(const std::string &dir) {
    Dump d;
    d.dir = dir;
    auto text = readFile(dir + "/manifest.json");
    JsonReader reader{reinterpret_cast<const char *>(text.data()),
                      reinterpret_cast<const char *>(text.data()) + text.size()};
    d.manifest = reader.value();
    if (d.manifest["format"].text != "sillage-walk-dump") { fail("not a walk dump: " + dir); }
    if (d.manifest["version"].number != 1) { fail("dump version is not 1"); }

    const std::pair<const char *, size_t> expected[] = {
        {"states", 16}, {"motions", 16}, {"sorted", 16}, {"nodes", 32},    {"moments", 16},
        {"order", 4},   {"frame", 4},    {"halos", 48},  {"holes", 32},    {"massive", 16},
        {"disks", 64},  {"params", 48},  {"accelerations", 16}, {"motions-mode1", 16}};
    const Json &list = d.manifest["buffers"];
    for (auto &[name, stride] : expected) {
        const Json &entry = list[name];
        if (entry.kind != Json::Object) {
            if (std::string(name) == "motions-mode1") { continue; }
            fail(std::string("manifest lists no buffer ") + name);
        }
        Buffer b;
        b.count = size_t(entry["count"].number);
        b.stride = size_t(entry["stride"].number);
        if (b.stride != stride) {
            fail(std::string(name) + ": stride " + std::to_string(b.stride) + ", expected " +
                 std::to_string(stride));
        }
        b.bytes = readFile(dir + "/" + entry["file"].text);
        if (b.bytes.size() != b.count * b.stride) {
            fail(std::string(name) + ": " + std::to_string(b.bytes.size()) + " bytes, manifest says " +
                 std::to_string(b.count) + " x " + std::to_string(b.stride));
        }
        d.buffers[name] = std::move(b);
    }
    std::memcpy(&d.params, d[std::string("params")].bytes.data(), sizeof(TracerStepParams));

    size_t tracers = d.params.tracerCount;
    for (const char *name : {"states", "motions", "order", "accelerations"}) {
        if (d[name].count != tracers) { fail(std::string(name) + " does not hold every tracer"); }
    }
    if (d.has("motions-mode1") && d["motions-mode1"].count != tracers) {
        fail("motions-mode1 does not hold every tracer");
    }
    if (d["frame"].count < 4) { fail("frame holds fewer than 4 floats"); }
    if (d["halos"].count < std::max(d.params.haloCount, 1u)) { fail("fewer halos than haloCount"); }
    if (d["holes"].count < d.params.holeCount) { fail("fewer holes than holeCount"); }
    if (d["disks"].count < d.params.diskCount) { fail("fewer disks than diskCount"); }

    // The manifest's copy of the parameters must be the binary's.
    const Json &mp = d.manifest["params"];
    auto same = [&](const char *key, double value) {
        if (mp.has(key) && float(mp[key].number) != float(value)) {
            fail(std::string("params.bin and manifest disagree on ") + key);
        }
    };
    same("tracerCount", d.params.tracerCount);
    same("haloCount", d.params.haloCount);
    same("timeStep", d.params.timeStep);
    same("openingAngleSquared", d.params.openingAngleSquared);
    same("softeningSquared", d.params.softeningSquared);
    same("gravitationalConstant", d.params.gravitationalConstant);
    same("sortChunk", d.params.sortChunk);
    same("holeCount", d.params.holeCount);
    same("diskCount", d.params.diskCount);
    return d;
}

template <class T>
static T *upload(const Buffer &b) {
    void *p = nullptr;
    size_t size = std::max<size_t>(b.bytes.size(), 16);
    CHECK(cudaMalloc(&p, size));
    if (!b.bytes.empty()) { CHECK(cudaMemcpy(p, b.bytes.data(), b.bytes.size(), cudaMemcpyHostToDevice)); }
    return static_cast<T *>(p);
}

struct Device {
    float4 *states;
    uint4 *motions;
    float4 *sorted;
    BHNode *nodes;
    float4 *moments;
    uint *order;
    float *frame;
    HaloGPU *halos;
    HoleGPU *holes;
    float3 *massive;
    DiskCooling *disks;
    float3 *probe;
};

static double seconds(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - since).count();
}

static void run(const Dump &d, Device &g, uint mode, unsigned block) {
    TracerStepParams p = d.params;
    p.mode = mode;
    p.chunkStart = 0;
    uint n = p.tracerCount;
    dim3 grid((n + block - 1) / block);
    CUDA_LAUNCH(bhTracerStepEntry, grid, dim3(block), g.states, g.motions, g.sorted, g.nodes,
                g.moments, g.order, g.frame, g.halos, g.holes, g.massive, g.disks, p, g.probe, n);
    CHECK(cudaGetLastError());
    CHECK(cudaDeviceSynchronize());
}

static double length3(double x, double y, double z) { return std::sqrt(x * x + y * y + z * z); }

int main(int argc, char **argv) {
    std::string dir;
    size_t top = 20;
    unsigned block = 64;
    for (int a = 1; a < argc; ++a) {
        std::string arg = argv[a];
        if (arg == "--top" && a + 1 < argc) { top = std::strtoul(argv[++a], nullptr, 10); }
        else if (arg == "--block" && a + 1 < argc) { block = std::strtoul(argv[++a], nullptr, 10); }
        else if (dir.empty()) { dir = arg; }
        else { fail("usage: walk <dump-dir> [--top N] [--block N]"); }
    }
    if (dir.empty()) { fail("usage: walk <dump-dir> [--top N] [--block N]"); }

    int devices = 0;
    if (cudaGetDeviceCount(&devices) != cudaSuccess || devices == 0) {
        std::printf("SKIPPED: no CUDA device here. Running the walk on a GPU is #283's.\n");
        return 0;
    }

    Dump d = load(dir);
    const TracerStepParams &p = d.params;
    bool quadrupole = d.manifest["functionConstants"]["bhQuadrupole"].boolean;
    bool opens = d.manifest["functionConstants"]["bhOpensHoldingCells"].boolean;
    CHECK(cudaMemcpyToSymbol(bhQuadrupole, &quadrupole, sizeof(bool)));
    CHECK(cudaMemcpyToSymbol(bhOpensHoldingCells, &opens, sizeof(bool)));

    std::printf("dump %s: %s\n", dir.c_str(), d.manifest["source"].text.c_str());
    std::printf("  %u tracers, %zu massive, %zu nodes, %u halos, %u holes, %u disks, sortChunk %u\n",
                p.tracerCount, d["sorted"].count, d["nodes"].count, p.haloCount, p.holeCount,
                p.diskCount, p.sortChunk);
    std::printf("  opening angle %.4g, softening %.4g, G %.6g, dt %.6g, quadrupole %d, "
                "opens holding cells %d\n",
                std::sqrt(p.openingAngleSquared), std::sqrt(p.softeningSquared),
                p.gravitationalConstant, p.timeStep, int(quadrupole), int(opens));

    Device g;
    g.states = upload<float4>(d["states"]);
    g.motions = upload<uint4>(d["motions"]);
    g.sorted = upload<float4>(d["sorted"]);
    g.nodes = upload<BHNode>(d["nodes"]);
    g.moments = upload<float4>(d["moments"]);
    g.order = upload<uint>(d["order"]);
    g.frame = upload<float>(d["frame"]);
    g.halos = upload<HaloGPU>(d["halos"]);
    g.holes = upload<HoleGPU>(d["holes"]);
    g.massive = upload<float3>(d["massive"]);
    g.disks = upload<DiskCooling>(d["disks"]);
    size_t n = p.tracerCount;
    if (n == 0) { fail("the dump holds no tracer"); }
    CHECK(cudaMalloc(&g.probe, std::max<size_t>(n, 1) * sizeof(float3)));

    // Mode 2: the acceleration alone, against the dump's (Metal's in a real dump).
    auto clock = std::chrono::steady_clock::now();
    run(d, g, 2u, block);
    double walkSeconds = seconds(clock);
    std::vector<float3> mine(n);
    CHECK(cudaMemcpy(mine.data(), g.probe, n * sizeof(float3), cudaMemcpyDeviceToHost));
    const float3 *ref = d["accelerations"].as<float3>();

    std::vector<double> errors(n);
    size_t zero = 0;
    for (size_t i = 0; i < n; ++i) {
        double norm = length3(ref[i].x, ref[i].y, ref[i].z);
        double diff = length3(double(mine[i].x) - ref[i].x, double(mine[i].y) - ref[i].y,
                              double(mine[i].z) - ref[i].z);
        if (norm == 0) { ++zero; }
        errors[i] = norm > 0 ? diff / norm : (diff > 0 ? INFINITY : 0);
    }
    std::vector<double> sorted = errors;
    std::sort(sorted.begin(), sorted.end());
    auto rank = [&](double q) { return sorted[std::min(n - 1, size_t(std::ceil(q * n)) - 1)]; };
    size_t above = std::count_if(errors.begin(), errors.end(), [](double e) { return e > 1e-4; });
    size_t exact = std::count(errors.begin(), errors.end(), 0.0);
    std::printf("\nmode 2 against the dump's accelerations, |a_cpu - a_ref| / |a_ref| over %zu tracers:\n", n);
    std::printf("  median %.3e   99.9th percentile %.3e   max %.3e\n", rank(0.5), rank(0.999),
                sorted.back());
    std::printf("  identical %zu (%.2f %%)   above 1e-4: %zu (%.4f %%)   |a_ref| = 0: %zu\n",
                exact, 100.0 * exact / n, above, 100.0 * above / n, zero);
    std::printf("  walk %.3f s, %.1f ns a tracer\n", walkSeconds, 1e9 * walkSeconds / n);

    std::vector<size_t> worst(n);
    for (size_t i = 0; i < n; ++i) { worst[i] = i; }
    size_t shown = std::min(top, n);
    std::partial_sort(worst.begin(), worst.begin() + shown, worst.end(),
                      [&](size_t a, size_t b) { return errors[a] > errors[b]; });
    if (shown > 0) {
        std::printf("  the %zu largest:\n     tracer   rel. error        |a_ref|   a_cpu - a_ref\n", shown);
    }
    for (size_t k = 0; k < shown; ++k) {
        size_t i = worst[k];
        std::printf("  %9zu   %.3e   %.4e   (%+.3e, %+.3e, %+.3e)\n", i, errors[i],
                    length3(ref[i].x, ref[i].y, ref[i].z), double(mine[i].x) - ref[i].x,
                    double(mine[i].y) - ref[i].y, double(mine[i].z) - ref[i].z);
    }

    // Mode 1, the whole fused step, twice on copies of the motions.
    const Buffer &motions = d["motions"];
    std::vector<uint4> after[2];
    for (int round = 0; round < 2; ++round) {
        CHECK(cudaMemcpy(g.motions, motions.bytes.data(), motions.bytes.size(), cudaMemcpyHostToDevice));
        run(d, g, 1u, block);
        after[round].resize(n);
        CHECK(cudaMemcpy(after[round].data(), g.motions, n * sizeof(uint4), cudaMemcpyDeviceToHost));
    }
    size_t differing = 0;
    size_t moved = 0;
    for (size_t i = 0; i < n; ++i) {
        if (std::memcmp(&after[0][i], &after[1][i], sizeof(uint4)) != 0) { ++differing; }
        if (std::memcmp(&after[0][i], &motions.as<uint4>()[i], sizeof(uint4)) != 0) { ++moved; }
    }
    std::printf("\nmode 1 twice: %zu of %zu tracers differ between the runs (%zu changed by the step)\n",
                differing, n, moved);

    if (d.has("motions-mode1")) {
        const uint4 *theirs = d["motions-mode1"].as<uint4>();
        std::vector<double> e(n);
        size_t words = 0;
        for (size_t i = 0; i < n; ++i) {
            float3 a = as_type<float3>(after[0][i].xyz);
            float3 b = as_type<float3>(theirs[i].xyz);
            double norm = length3(b.x, b.y, b.z);
            double diff = length3(double(a.x) - b.x, double(a.y) - b.y, double(a.z) - b.z);
            e[i] = norm > 0 ? diff / norm : (diff > 0 ? INFINITY : 0);
            if (after[0][i].w != theirs[i].w) { ++words; }
        }
        std::sort(e.begin(), e.end());
        std::printf("mode 1 against the dump's motions-mode1, velocity: median %.3e   99.9th percentile %.3e   max %.3e;"
                    " words differing %zu\n",
                    e[n / 2], e[std::min(n - 1, size_t(std::ceil(0.999 * n)) - 1)], e.back(), words);
    }
    return differing == 0 ? 0 : 2;
}
