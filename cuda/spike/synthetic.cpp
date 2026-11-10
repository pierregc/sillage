// Writes a small walk dump, in the format docs/notes/cuda-walk-spike.md gives, from a made-up
// pair of clusters and an octree built here the way GPUTreeBuilder lays it out. Its
// "accelerations" are a direct sum in double, not Metal's: it only exercises the harness.
//
//   synthetic <out-dir> [--tracers N] [--massive M] [--theta T] [--chunk C] [--seed S]
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <sys/stat.h>
#include <vector>

struct V { double x, y, z; };

static uint64_t spread(uint32_t value) {
    uint64_t x = uint64_t(value) & 0x1FFFFFull;
    x = (x | (x << 32)) & 0x001F00000000FFFFull;
    x = (x | (x << 16)) & 0x001F0000FF0000FFull;
    x = (x | (x << 8)) & 0x100F00F00F00F00Full;
    x = (x | (x << 4)) & 0x10C30C30C30C30C3ull;
    x = (x | (x << 2)) & 0x1249249249249249ull;
    return x;
}

static float bitsOf(int32_t v) { float f; std::memcpy(&f, &v, 4); return f; }
static float bitsOf(uint32_t v) { float f; std::memcpy(&f, &v, 4); return f; }

struct Node { float comMass[4]; float packed[4]; };

static void write(const std::string &path, const void *data, size_t size) {
    FILE *f = std::fopen(path.c_str(), "wb");
    if (!f || (size && std::fwrite(data, 1, size, f) != size)) {
        std::fprintf(stderr, "synthetic: cannot write %s\n", path.c_str());
        std::exit(1);
    }
    std::fclose(f);
}

int main(int argc, char **argv) {
    if (argc < 2) {
        std::fprintf(stderr, "usage: synthetic <out-dir> [--tracers N] [--massive M] [--theta T] [--chunk C] [--seed S]\n");
        return 1;
    }
    std::string dir = argv[1];
    size_t tracers = 20000, massive = 5000, chunk = 4096;
    double theta = 0.6;
    unsigned seed = 271;
    for (int a = 2; a + 1 < argc; a += 2) {
        std::string k = argv[a];
        double v = std::atof(argv[a + 1]);
        if (k == "--tracers") tracers = size_t(v);
        else if (k == "--massive") massive = size_t(v);
        else if (k == "--theta") theta = v;
        else if (k == "--chunk") chunk = size_t(v);
        else if (k == "--seed") seed = unsigned(v);
    }
    chunk = std::min(std::max<size_t>(chunk, 1), std::max<size_t>(tracers, 1));
    mkdir(dir.c_str(), 0755);

    std::mt19937_64 rng(seed);
    std::uniform_real_distribution<double> unit(0.0, 1.0);
    auto plummer = [&](V centre, double scale) {
        double r = scale / std::sqrt(std::pow(unit(rng) * 0.99 + 1e-6, -2.0 / 3.0) - 1.0);
        double z = 2 * unit(rng) - 1, phi = 2 * M_PI * unit(rng), s = std::sqrt(1 - z * z);
        return V{centre.x + r * s * std::cos(phi), centre.y + r * s * std::sin(phi), centre.z + r * z};
    };
    const V centres[2] = {{-1.5, 0.2, 0.1}, {2.0, -0.4, -0.3}};
    const double G = 1.0, softening = 0.02, holeSoftening = 0.05;

    std::vector<V> pos(massive);
    std::vector<float> mass(massive, float(1.0 / massive));
    for (size_t i = 0; i < massive; ++i) pos[i] = plummer(centres[i % 2], i % 2 ? 0.6 : 0.9);
    // Particle 0 is a black hole: pulled outside the tree, massless in it.
    pos[0] = centres[0];
    const float holeMass = 0.05f;
    mass[0] = 0;

    // The root and the codes as gtRoot and gtMorton make them.
    float lower[3] = {1e30f, 1e30f, 1e30f}, upper[3] = {-1e30f, -1e30f, -1e30f};
    std::vector<float> pf(massive * 3);
    for (size_t i = 0; i < massive; ++i) {
        float p[3] = {float(pos[i].x), float(pos[i].y), float(pos[i].z)};
        for (int k = 0; k < 3; ++k) {
            pf[3 * i + k] = p[k];
            lower[k] = std::min(lower[k], p[k]);
            upper[k] = std::max(upper[k], p[k]);
        }
    }
    float radius = std::max(std::max(std::max(upper[0] - lower[0], upper[1] - lower[1]), upper[2] - lower[2]) * 0.5f, 1e-3f) * 1.001f;
    float inverse = 2097151.0f / (2.0f * radius);
    float frame[8] = {0};
    for (int k = 0; k < 3; ++k) frame[k] = (lower[k] + upper[k]) * 0.5f - radius;
    frame[3] = inverse;
    frame[4] = radius;
    auto code = [&](const float *p) {
        uint32_t c[3];
        for (int k = 0; k < 3; ++k) {
            float local = (p[k] - frame[k]) * frame[3];
            c[k] = uint32_t(std::min(std::max(local, 0.0f), 2097151.0f));
        }
        return (spread(c[0]) << 2) | (spread(c[1]) << 1) | spread(c[2]);
    };
    std::vector<uint64_t> codes(massive);
    std::vector<uint32_t> order(massive);
    for (size_t i = 0; i < massive; ++i) { codes[i] = code(&pf[3 * i]); order[i] = uint32_t(i); }
    std::stable_sort(order.begin(), order.end(), [&](uint32_t a, uint32_t b) { return codes[a] < codes[b]; });
    std::vector<uint64_t> sortedCodes(massive);
    std::vector<float> sorted(massive * 4);
    for (size_t s = 0; s < massive; ++s) {
        uint32_t i = order[s];
        sortedCodes[s] = codes[i];
        for (int k = 0; k < 3; ++k) sorted[4 * s + k] = pf[3 * i + k];
        sorted[4 * s + 3] = mass[i];
    }

    // Level by level, siblings contiguous, as gtSplit lays them out.
    const int leafCapacity = 16, maximumDepth = 20;
    std::vector<Node> nodes(1);
    std::vector<int> start(1, 0), count(1, int(massive));
    nodes[0].packed[0] = (2 * radius) * (2 * radius);
    nodes[0].packed[1] = bitsOf(int32_t(0));
    nodes[0].packed[2] = bitsOf(int32_t(-int(massive)));
    nodes[0].packed[3] = bitsOf(uint32_t(63u << 3));
    size_t begin = 0, end = 1;
    for (int level = 0; level < maximumDepth && begin < end; ++level) {
        uint32_t shift = 60u - 3u * uint32_t(level);
        float width = std::ldexp(radius, -(level + 1)) * 2.0f;
        for (size_t n = begin; n < end; ++n) {
            if (count[n] <= leafCapacity) continue;
            int first = int(nodes.size()), children = 0;
            int s = start[n], e = start[n] + count[n];
            for (uint32_t o = 0; o < 8; ++o) {
                int a = s;
                while (a < e && uint32_t((sortedCodes[a] >> shift) & 7) < o) ++a;
                int b = a;
                while (b < e && uint32_t((sortedCodes[b] >> shift) & 7) == o) ++b;
                if (b == a) continue;
                Node child{};
                child.packed[0] = width * width;
                child.packed[1] = bitsOf(int32_t(a));
                child.packed[2] = bitsOf(int32_t(-(b - a)));
                child.packed[3] = bitsOf(uint32_t((shift << 3) | o));
                nodes.push_back(child);
                start.push_back(a);
                count.push_back(b - a);
                ++children;
            }
            nodes[n].packed[1] = bitsOf(int32_t(first));
            nodes[n].packed[2] = bitsOf(int32_t(children));
        }
        begin = end;
        end = nodes.size();
    }

    // Centres of mass and raw second moments about them, as BarnesHutTree.quadrupoles holds them.
    std::vector<float> moments(nodes.size() * 8, 0.0f);
    for (size_t n = 0; n < nodes.size(); ++n) {
        double m = 0, cx = 0, cy = 0, cz = 0;
        for (int s = start[n]; s < start[n] + count[n]; ++s) {
            double w = sorted[4 * s + 3];
            m += w;
            cx += w * sorted[4 * s];
            cy += w * sorted[4 * s + 1];
            cz += w * sorted[4 * s + 2];
        }
        if (m > 0) { cx /= m; cy /= m; cz /= m; }
        double q[6] = {0, 0, 0, 0, 0, 0};
        for (int s = start[n]; s < start[n] + count[n]; ++s) {
            double w = sorted[4 * s + 3];
            double dx = sorted[4 * s] - cx, dy = sorted[4 * s + 1] - cy, dz = sorted[4 * s + 2] - cz;
            q[0] += w * dx * dx; q[1] += w * dy * dy; q[2] += w * dz * dz;
            q[3] += w * dx * dy; q[4] += w * dx * dz; q[5] += w * dy * dz;
        }
        nodes[n].comMass[0] = float(cx);
        nodes[n].comMass[1] = float(cy);
        nodes[n].comMass[2] = float(cz);
        nodes[n].comMass[3] = float(m);
        float *qa = &moments[8 * n];
        qa[0] = float(q[0]); qa[1] = float(q[1]); qa[2] = float(q[2]); qa[3] = float(q[3]);
        qa[4] = float(q[4]); qa[5] = float(q[5]);
    }

    // Tracers: the clusters again, a few far outside the root, sorted a chunk at a time.
    std::vector<float> states(tracers * 4);
    std::vector<uint32_t> motions(tracers * 4);
    std::normal_distribution<double> gauss(0.0, 0.3);
    for (size_t i = 0; i < tracers; ++i) {
        V p = i % 50 == 7 ? V{30 * unit(rng) - 15, 30 * unit(rng) - 15, 30 * unit(rng) - 15}
                          : plummer(centres[i % 2], i % 2 ? 0.6 : 0.9);
        states[4 * i] = float(p.x);
        states[4 * i + 1] = float(p.y);
        states[4 * i + 2] = float(p.z);
        states[4 * i + 3] = i % 3 ? 1e9f : float(unit(rng));
        float v[3] = {float(gauss(rng)), float(gauss(rng)), float(gauss(rng))};
        std::memcpy(&motions[4 * i], v, 12);
        motions[4 * i + 3] = uint32_t(i % 2) | (uint32_t(i % 5) << 4);
    }
    std::vector<uint32_t> tracerOrder(tracers);
    for (size_t c0 = 0; c0 < tracers; c0 += chunk) {
        size_t c1 = std::min(c0 + chunk, tracers);
        std::vector<uint64_t> tc(c1 - c0);
        for (size_t i = c0; i < c1; ++i) tc[i - c0] = code(&states[4 * i]);
        for (size_t i = c0; i < c1; ++i) tracerOrder[i] = uint32_t(i - c0);
        std::stable_sort(tracerOrder.begin() + c0, tracerOrder.begin() + c1,
                         [&](uint32_t a, uint32_t b) { return tc[a] < tc[b]; });
    }

    // HaloGPU: centre before, centre after, (mass G, scale, profile, 0).
    float halos[2 * 12] = {0};
    for (int h = 0; h < 2; ++h) {
        float *e = &halos[12 * h];
        e[0] = e[4] = float(centres[h].x);
        e[1] = e[5] = float(centres[h].y);
        e[2] = e[6] = float(centres[h].z);
        e[8] = float(G * (h ? 0.7 : 1.2));
        e[9] = h ? 1.5f : 2.0f;
        e[10] = float(h);
    }
    float holes[8] = {0, 0, 0, float(G) * holeMass, float(holeSoftening * holeSoftening), bitsOf(uint32_t(0)), 0, 0};
    float disks[16] = {float(centres[0].x), float(centres[0].y), float(centres[0].z), 0.1f,
                       0, 0, 0, 0.05f,
                       0, 0, 1, 0,
                       2.0f, 3.0f, 0.3f, 0.6f};
    struct {
        uint32_t tracerCount, haloCount;
        float timeStep, openingAngleSquared, softeningSquared, gravitationalConstant;
        uint32_t chunkStart, sortChunk, holeCount, diskCount, mode, pad;
    } params = {uint32_t(tracers), 2, 0.01f, float(theta * theta), float(softening * softening),
                float(G), 0, uint32_t(chunk), 1, 1, 1, 0};
    static_assert(sizeof(params) == 48, "");

    // The reference: every massive particle summed directly, in double.
    std::vector<float> accelerations(tracers * 4, 0.0f);
    for (size_t i = 0; i < tracers; ++i) {
        double px = states[4 * i], py = states[4 * i + 1], pz = states[4 * i + 2];
        double ax = 0, ay = 0, az = 0;
        for (size_t s = 0; s < massive; ++s) {
            double m = sorted[4 * s + 3];
            if (m <= 0) continue;
            double dx = sorted[4 * s] - px, dy = sorted[4 * s + 1] - py, dz = sorted[4 * s + 2] - pz;
            double r2 = dx * dx + dy * dy + dz * dz + double(params.softeningSquared);
            double f = G * m / (r2 * std::sqrt(r2));
            ax += dx * f; ay += dy * f; az += dz * f;
        }
        for (int h = 0; h < 2; ++h) {
            const float *e = &halos[12 * h];
            double ox = px - e[4], oy = py - e[5], oz = pz - e[6], M = e[8], a = e[9];
            double f;
            if (e[10] == 0) {
                double d2 = ox * ox + oy * oy + oz * oz + a * a;
                f = -M / (d2 * std::sqrt(d2));
            } else {
                double r = std::max(std::sqrt(ox * ox + oy * oy + oz * oz), 1e-6);
                f = -M / (r * (r + a) * (r + a));
            }
            ax += ox * f; ay += oy * f; az += oz * f;
        }
        double dx = px - pf[0], dy = py - pf[1], dz = pz - pf[2];
        double r2 = dx * dx + dy * dy + dz * dz + double(holes[4]);
        double f = double(holes[3]) / (r2 * std::sqrt(r2));
        ax -= dx * f; ay -= dy * f; az -= dz * f;
        accelerations[4 * i] = float(ax);
        accelerations[4 * i + 1] = float(ay);
        accelerations[4 * i + 2] = float(az);
    }

    write(dir + "/states.bin", states.data(), states.size() * 4);
    write(dir + "/motions.bin", motions.data(), motions.size() * 4);
    write(dir + "/sorted.bin", sorted.data(), sorted.size() * 4);
    write(dir + "/nodes.bin", nodes.data(), nodes.size() * sizeof(Node));
    write(dir + "/moments.bin", moments.data(), moments.size() * 4);
    write(dir + "/order.bin", tracerOrder.data(), tracerOrder.size() * 4);
    write(dir + "/frame.bin", frame, sizeof(frame));
    write(dir + "/halos.bin", halos, sizeof(halos));
    write(dir + "/holes.bin", holes, sizeof(holes));
    std::vector<float> massivePositions(massive * 4, 0.0f);
    for (size_t i = 0; i < massive; ++i) std::memcpy(&massivePositions[4 * i], &pf[3 * i], 12);
    write(dir + "/massive.bin", massivePositions.data(), massivePositions.size() * 4);
    write(dir + "/disks.bin", disks, sizeof(disks));
    write(dir + "/params.bin", &params, sizeof(params));
    write(dir + "/accelerations.bin", accelerations.data(), accelerations.size() * 4);

    FILE *m = std::fopen((dir + "/manifest.json").c_str(), "w");
    std::fprintf(m,
        "{\n"
        "  \"format\": \"sillage-walk-dump\",\n"
        "  \"version\": 1,\n"
        "  \"byteOrder\": \"little\",\n"
        "  \"source\": \"synthetic (cuda/spike/synthetic.cpp, seed %u, theta %g): accelerations by direct summation in double, not Metal's\",\n"
        "  \"counts\": {\"tracers\": %zu, \"massive\": %zu, \"nodes\": %zu, \"halos\": 2, \"holes\": 1, \"disks\": 1},\n"
        "  \"functionConstants\": {\"bhQuadrupole\": true, \"bhOpensHoldingCells\": true},\n"
        "  \"tracerSort\": {\"interval\": 10, \"counter\": 9, \"stepsSinceSort\": 0},\n"
        "  \"params\": {\"tracerCount\": %zu, \"haloCount\": 2, \"timeStep\": %.9g, \"openingAngleSquared\": %.9g,"
        " \"softeningSquared\": %.9g, \"gravitationalConstant\": %.9g, \"chunkStart\": 0, \"sortChunk\": %zu,"
        " \"holeCount\": 1, \"diskCount\": 1, \"mode\": 1},\n"
        "  \"buffers\": {\n",
        seed, theta, tracers, massive, nodes.size(), tracers, double(params.timeStep),
        double(params.openingAngleSquared), double(params.softeningSquared),
        double(params.gravitationalConstant), chunk);
    struct { const char *name; int binding; const char *type; size_t count, stride; } list[] = {
        {"states", 0, "float4", tracers, 16},       {"motions", 1, "uint4", tracers, 16},
        {"sorted", 2, "float4", massive, 16},       {"nodes", 3, "BHNode", nodes.size(), 32},
        {"moments", 4, "float4", nodes.size() * 2, 16}, {"order", 5, "uint", tracers, 4},
        {"frame", 6, "float", 8, 4},                {"halos", 7, "HaloGPU", 2, 48},
        {"holes", 8, "HoleGPU", 1, 32},             {"massive", 9, "float3", massive, 16},
        {"disks", 10, "DiskCooling", 1, 64},        {"params", 11, "TracerStepParams", 1, 48},
        {"accelerations", 12, "float3", tracers, 16}};
    size_t entries = sizeof(list) / sizeof(list[0]);
    for (size_t k = 0; k < entries; ++k) {
        std::fprintf(m, "    \"%s\": {\"file\": \"%s.bin\", \"binding\": %d, \"type\": \"%s\", \"count\": %zu, \"stride\": %zu}%s\n",
                     list[k].name, list[k].name, list[k].binding, list[k].type, list[k].count,
                     list[k].stride, k + 1 < entries ? "," : "");
    }
    std::fprintf(m, "  }\n}\n");
    std::fclose(m);
    std::printf("synthetic dump in %s: %zu tracers, %zu massive, %zu nodes, theta %g\n", dir.c_str(),
                tracers, massive, nodes.size(), theta);
    return 0;
}
