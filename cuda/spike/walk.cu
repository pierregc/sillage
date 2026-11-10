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
            if (*p == '\\') { fail("manifest: escapes are not read"); }
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
            if (p < end && *p == '}') { ++p; return v; }
            for (;;) {
                std::string key = string();
                if (v.fields.count(key)) { fail("manifest: key " + key + " twice"); }
                expect(':');
                v.fields[key] = value();
                space();
                if (p < end && *p == ',') { ++p; continue; }
                expect('}');
                return v;
            }
        }
        if (*p == '[') {
            v.kind = Json::Array;
            ++p;
            space();
            if (p < end && *p == ']') { ++p; return v; }
            for (;;) {
                v.items.push_back(value());
                space();
                if (p < end && *p == ',') { ++p; continue; }
                expect(']');
                return v;
            }
        }
        if (*p == '"') {
            v.kind = Json::String;
            v.text = string();
            return v;
        }
        auto word = [&](const char *w) {
            size_t n = std::strlen(w);
            if (size_t(end - p) >= n && !std::strncmp(p, w, n)) { p += n; return true; }
            return false;
        };
        if (word("true")) { v.kind = Json::Bool; v.boolean = true; return v; }
        if (word("false")) { v.kind = Json::Bool; return v; }
        if (word("null")) { return v; }
        if (*p != '-' && (*p < '0' || *p > '9')) { fail("manifest: bad value"); }
        std::string digits;
        while (p < end && std::strchr("+-.0123456789eE", *p)) { digits += *p++; }
        char *after = nullptr;
        v.number = std::strtod(digits.c_str(), &after);
        if (*after != '\0' || !std::isfinite(v.number)) { fail("manifest: bad number " + digits); }
        v.kind = Json::Number;
        return v;
    }
    Json document() {
        Json v = value();
        space();
        if (p != end) { fail("manifest: text after the JSON"); }
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
    bool quadrupole = false;
    bool opensHoldingCells = false;

    bool has(const std::string &name) const { return buffers.count(name) != 0; }
    const Buffer &operator[](const std::string &name) const { return buffers.at(name); }
};

static const Json &member(const Json &object, const char *key, Json::Kind kind, const char *where) {
    std::string at = std::string(where) + "." + key;
    if (object.kind != Json::Object) { fail(std::string("manifest: ") + where + " is not an object"); }
    auto it = object.fields.find(key);
    if (it == object.fields.end()) { fail("manifest: no " + at); }
    if (it->second.kind != kind) { fail("manifest: " + at + " has the wrong type"); }
    return it->second;
}

static uint64_t integer(const Json &object, const char *key, const char *where) {
    double v = member(object, key, Json::Number, where).number;
    if (v < 0 || v != std::floor(v) || v > 9007199254740992.0) {
        fail(std::string("manifest: ") + where + "." + key + " is not a count");
    }
    return uint64_t(v);
}

static void onlyKeys(const Json &object, std::vector<std::string> keys, const char *where) {
    for (auto &[key, value] : object.fields) {
        if (std::find(keys.begin(), keys.end(), key) == keys.end()) {
            fail(std::string("manifest: ") + where + " has an unknown key " + key);
        }
    }
}

// The format of docs/notes/cuda-walk-spike.md, version 1. Anything else is refused.
static Dump load(const std::string &dir) {
    Dump d;
    d.dir = dir;
    auto text = readFile(dir + "/manifest.json");
    JsonReader reader{reinterpret_cast<const char *>(text.data()),
                      reinterpret_cast<const char *>(text.data()) + text.size()};
    d.manifest = reader.document();
    const Json &m = d.manifest;
    if (member(m, "format", Json::String, "top").text != "sillage-walk-dump") {
        fail("not a walk dump: " + dir);
    }
    if (member(m, "version", Json::Number, "top").number != 1) { fail("dump version is not 1"); }
    if (member(m, "byteOrder", Json::String, "top").text != "little") { fail("byteOrder is not little"); }
    member(m, "source", Json::String, "top");

    const Json &constants = member(m, "functionConstants", Json::Object, "top");
    onlyKeys(constants, {"bhQuadrupole", "bhOpensHoldingCells"}, "functionConstants");
    d.quadrupole = member(constants, "bhQuadrupole", Json::Bool, "functionConstants").boolean;
    d.opensHoldingCells =
        member(constants, "bhOpensHoldingCells", Json::Bool, "functionConstants").boolean;
    const Json &sort = member(m, "tracerSort", Json::Object, "top");
    onlyKeys(sort, {"interval", "counter", "stepsSinceSort"}, "tracerSort");
    integer(sort, "interval", "tracerSort");
    member(sort, "counter", Json::Number, "tracerSort");
    integer(sort, "stepsSinceSort", "tracerSort");

    struct Expected { const char *name; int binding; const char *type; size_t stride; bool required; };
    const Expected expected[] = {
        {"states", 0, "float4", 16, true},        {"motions", 1, "uint4", 16, true},
        {"sorted", 2, "float4", 16, true},        {"nodes", 3, "BHNode", 32, true},
        {"moments", 4, "float4", 16, true},       {"order", 5, "uint", 4, true},
        {"frame", 6, "float", 4, true},           {"halos", 7, "HaloGPU", 48, true},
        {"holes", 8, "HoleGPU", 32, true},        {"massive", 9, "float3", 16, true},
        {"disks", 10, "DiskCooling", 64, true},   {"params", 11, "TracerStepParams", 48, true},
        {"accelerations", 12, "float3", 16, true}, {"motions-mode1", 1, "uint4", 16, false}};
    const Json &list = member(m, "buffers", Json::Object, "top");
    std::vector<std::string> names;
    for (const Expected &e : expected) { names.push_back(e.name); }
    onlyKeys(list, names, "buffers");
    for (const Expected &e : expected) {
        if (!list.has(e.name)) {
            if (!e.required) { continue; }
            fail(std::string("manifest lists no buffer ") + e.name);
        }
        std::string named = std::string("buffers.") + e.name;
        const char *where = named.c_str();
        const Json &entry = member(list, e.name, Json::Object, "buffers");
        onlyKeys(entry, {"file", "binding", "type", "count", "stride"}, where);
        std::string file = member(entry, "file", Json::String, where).text;
        if (file.empty() || file.find('/') != std::string::npos) { fail(named + ": bad file name"); }
        if (integer(entry, "binding", where) != uint64_t(e.binding)) { fail(named + ": wrong binding"); }
        if (member(entry, "type", Json::String, where).text != e.type) {
            fail(named + ": type is not " + e.type);
        }
        Buffer b;
        b.count = integer(entry, "count", where);
        b.stride = integer(entry, "stride", where);
        if (b.stride != e.stride) {
            fail(named + ": stride " + std::to_string(b.stride) + ", expected " + std::to_string(e.stride));
        }
        b.bytes = readFile(dir + "/" + file);
        if (b.bytes.size() != b.count * b.stride) {
            fail(named + ": " + std::to_string(b.bytes.size()) + " bytes, manifest says " +
                 std::to_string(b.count) + " x " + std::to_string(b.stride));
        }
        d.buffers[e.name] = std::move(b);
    }
    if (d["params"].count != 1) { fail("params holds more or less than one TracerStepParams"); }
    std::memcpy(&d.params, d["params"].bytes.data(), sizeof(TracerStepParams));
    const TracerStepParams &p = d.params;

    // The manifest's copy of the parameters must be params.bin's, to the bit.
    const Json &mp = member(m, "params", Json::Object, "top");
    onlyKeys(mp, {"tracerCount", "haloCount", "timeStep", "openingAngleSquared", "softeningSquared",
                  "gravitationalConstant", "chunkStart", "sortChunk", "holeCount", "diskCount", "mode"},
             "params");
    auto count = [&](const char *key, uint32_t value) {
        if (integer(mp, key, "params") != value) { fail(std::string("params.bin and manifest disagree on ") + key); }
    };
    auto real = [&](const char *key, float value) {
        float f = float(member(mp, key, Json::Number, "params").number);
        if (std::memcmp(&f, &value, 4) != 0) { fail(std::string("params.bin and manifest disagree on ") + key); }
    };
    count("tracerCount", p.tracerCount);
    count("haloCount", p.haloCount);
    real("timeStep", p.timeStep);
    real("openingAngleSquared", p.openingAngleSquared);
    real("softeningSquared", p.softeningSquared);
    real("gravitationalConstant", p.gravitationalConstant);
    count("chunkStart", p.chunkStart);
    count("sortChunk", p.sortChunk);
    count("holeCount", p.holeCount);
    count("diskCount", p.diskCount);
    count("mode", p.mode);
    if (p.mode != 1 || p.chunkStart != 0) { fail("params.bin is not the mode 1 pass from slot 0"); }
    if (p.sortChunk == 0) { fail("sortChunk is 0"); }

    const Json &counts = member(m, "counts", Json::Object, "top");
    size_t tracers = p.tracerCount;
    size_t massive = d["sorted"].count;
    size_t nodes = d["nodes"].count;
    if (tracers == 0 || massive == 0 || nodes == 0) { fail("no tracer, no massive particle or no node"); }
    if (integer(counts, "tracers", "counts") != tracers) { fail("counts.tracers is not tracerCount"); }
    if (integer(counts, "massive", "counts") != massive) { fail("counts.massive is not sorted's count"); }
    if (integer(counts, "nodes", "counts") != nodes) { fail("counts.nodes is not nodes' count"); }
    for (auto [key, value] : {std::pair<const char *, uint>{"halos", p.haloCount}, {"holes", p.holeCount},
                              {"disks", p.diskCount}}) {
        if (counts.has(key) && integer(counts, key, "counts") != value) {
            fail(std::string("counts.") + key + " disagrees with params");
        }
    }
    for (const char *name : {"states", "motions", "order", "accelerations", "motions-mode1"}) {
        if (d.has(name) && d[name].count != tracers) { fail(std::string(name) + " does not hold every tracer"); }
    }
    if (d["massive"].count != massive) { fail("massive and sorted hold different counts"); }
    if (d["moments"].count != (d.quadrupole ? 2 * nodes : 0)) { fail("moments is not 2 per node, or 0"); }
    if (d["frame"].count != 8) { fail("frame is not 8 floats"); }
    if (d["halos"].count < std::max(p.haloCount, 1u)) { fail("halos holds fewer than haloCount, or none"); }
    if (d["holes"].count != std::max(p.holeCount, 1u)) { fail("holes is not holeCount, or 1"); }
    if (d["disks"].count != std::max(p.diskCount, 1u)) { fail("disks is not diskCount, or 1"); }

    // What the walk indexes with must stay inside the buffers.
    const uint *order = d["order"].as<uint>();
    std::vector<uint8_t> seen;
    for (size_t base = 0; base < tracers; base += p.sortChunk) {
        size_t span = std::min<size_t>(p.sortChunk, tracers - base);
        seen.assign(span, 0);
        for (size_t s = base; s < base + span; ++s) {
            if (order[s] >= span || seen[order[s]]++) {
                fail("order is not a permutation of its chunk at slot " + std::to_string(s));
            }
        }
    }
    const BHNode *tree = d["nodes"].as<BHNode>();
    for (size_t n = 0; n < nodes; ++n) {
        int start = as_type<int>(tree[n].packed.y);
        int signedCount = as_type<int>(tree[n].packed.z);
        bool ok = signedCount > 0
            ? signedCount <= 8 && start >= 1 && size_t(start) + size_t(signedCount) <= nodes
            : start >= 0 && size_t(start) + size_t(-int64_t(signedCount)) <= massive;
        if (!ok) { fail("node " + std::to_string(n) + " points outside the buffers"); }
    }
    const HoleGPU *holeList = d["holes"].as<HoleGPU>();
    for (uint h = 0; h < p.holeCount; ++h) {
        if (as_type<uint>(holeList[h].shape.y) >= massive) { fail("a hole's index is past the massive particles"); }
    }
    const float *frame = d["frame"].as<float>();
    if (!(frame[3] > 0) || !std::isfinite(frame[3])) { fail("frame's scale is not a positive number"); }
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
    bool quadrupole = d.quadrupole;
    bool opens = d.opensHoldingCells;
    CHECK(cudaMemcpyToSymbol(bhQuadrupole, &quadrupole, sizeof(bool)));
    CHECK(cudaMemcpyToSymbol(bhOpensHoldingCells, &opens, sizeof(bool)));

    const Json &m = d.manifest;
    std::printf("dump %s: %s\n", dir.c_str(), m["source"].text.c_str());
    if (m.has("scene")) {
        std::printf("  %s, %s, frame %.0f, step %.0f, time %.6g, walk order sorted %.0f steps ago\n",
                    m["scene"].text.c_str(), m["label"].text.c_str(), m["frame"].number,
                    m["step"].number, m["time"].number, m["tracerSort"]["stepsSinceSort"].number);
    }
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
