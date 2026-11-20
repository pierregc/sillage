// The black hole close up on the CPU target (#336), through the C API alone: the grid holds
// every tracer once, a lone tracer keeps its circular orbit and one inside the swallowing radius
// is swallowed, a run repeats to the bit, a splat lays its kernel round its point and nothing
// for a tracer swallowed, and a call that cannot be answered is refused. The Swift tests hold a
// still to Metal's (Tests/SillageCUDATests/CUDAHoleTests.swift).
#include "cuda_cpu.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "sillage_cuda.h"
#include "HoleShaders.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace HoleShaders {

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/hole_passes.cu: %s\n", what);
}

static bool ok(sc_status status, const char *what) {
    if (status == SC_OK) { return true; }
    failures += 1;
    std::printf("cuda/tests/hole_passes.cu: %s: %s, %s\n", what, sc_status_name(status), sc_last_error());
    return false;
}

struct Random {
    uint state;
    float next() {
        state = state * 1664525u + 1013904223u;
        return float(state >> 8) * (1.0f / 16777216.0f);
    }
};

template <class T>
static sc_buffer *held(sc_context *context, const std::vector<T> &values) {
    sc_buffer *buffer = nullptr;
    ok(sc_buffer_create(context, values.size() * sizeof(T), &buffer), "a buffer");
    ok(sc_buffer_upload(buffer, 0, values.data(), values.size() * sizeof(T)), "an upload");
    return buffer;
}

template <class T>
static std::vector<T> read(const sc_buffer *buffer, size_t count) {
    std::vector<T> values(count);
    ok(sc_buffer_download(buffer, 0, values.data(), count * sizeof(T)), "a download");
    return values;
}

// A small grid round the hole, as TidalRun.parameters lays one out between the swallowing radius
// and 50.
static HoleStepParams params(uint count, uint heights) {
    HoleStepParams p;
    std::memset(&p, 0, sizeof p);
    p.count = count;
    p.timeStep = 0.25f;
    p.swallow = 1.5f;
    p.subStepAngle = 0.05f;
    p.maximumSubSteps = 64u;
    p.gridRadii = 24u;
    p.gridAngles = 32u;
    p.gridHeights = heights;
    p.logInner = std::log(1.5f);
    p.logScale = 24.0f / (std::log(50.0f) - std::log(1.5f));
    p.heightCell = 1.0f / 8.0f;
    p.stickiness = 50.0f;
    p.crossing = 0.1f;
    p.viscosity = 1.0f / 2500.0f;
    p.cooling = 10.0f;
    return p;
}

struct Run {
    sc_hole_run buffers;
    void release() {
        for (sc_buffer *buffer :
             {buffers.positions, buffers.velocities, buffers.fixed, buffers.grid, buffers.column}) {
            sc_buffer_destroy(buffer);
        }
    }
};

static Run make(sc_context *context, const std::vector<float4> &positions, const std::vector<float4> &velocities,
                const HoleStepParams &p) {
    size_t columns = size_t(p.gridRadii) * p.gridAngles;
    size_t cells = columns * p.gridHeights;
    Run run;
    run.buffers.positions = held(context, positions);
    run.buffers.velocities = held(context, velocities);
    ok(sc_buffer_create(context, cells * 32u, &run.buffers.fixed), "the fixed point grid");
    ok(sc_buffer_create(context, cells * 16u, &run.buffers.grid), "the grid");
    ok(sc_buffer_create(context, columns * 4u, &run.buffers.column), "the columns");
    return run;
}

// A cloud of tracers on near circular orbits round the hole, a little out of the plane.
static void cloud(uint count, std::vector<float4> &positions, std::vector<float4> &velocities) {
    Random random{336u};
    positions.clear();
    velocities.clear();
    for (uint i = 0; i < count; ++i) {
        float r = 4.0f + 30.0f * random.next();
        float angle = 2.0f * M_PI_F * random.next();
        float z = (random.next() - 0.5f) * 0.1f * r;
        float speed = std::sqrt(r) / (r - 1.0f) * (0.9f + 0.2f * random.next());
        positions.push_back(float4(r * std::cos(angle), r * std::sin(angle), z, 0.0f));
        velocities.push_back(float4(-speed * std::sin(angle), speed * std::cos(angle), 0.0f, 0.0f));
    }
}

static int run() {
    sc_context *context = nullptr;
    if (!ok(sc_context_create(0, &context), "a context")) { return 1; }

    // The grid holds every tracer inside it once: the weights of its corners sum to one.
    for (uint heights : {1u, 8u}) {
        std::vector<float4> positions;
        std::vector<float4> velocities;
        cloud(2000u, positions, velocities);
        HoleStepParams p = params(2000u, heights);
        Run run = make(context, positions, velocities, p);
        ok(sc_hole_step(&run.buffers, &p, sizeof p, 1u), "a step");
        std::vector<float4> grid = read<float4>(run.buffers.grid, size_t(p.gridRadii) * p.gridAngles * heights);
        double held = 0.0;
        for (const float4 &cell : grid) { held += double(cell.w); }
        uint inside = 0u;
        for (const float4 &x : positions) {
            float3 cell;
            if (holeCell(x.xyz, p, cell)) { inside += 1u; }
        }
        std::printf("  %u layers: %u tracers inside the grid, %.4f in its cells\n", heights, inside, held);
        expect(inside > 1000u && std::fabs(held - double(inside)) < 1e-3, "the grid does not hold its tracers once");
        std::vector<float> column = read<float>(run.buffers.column, size_t(p.gridRadii) * p.gridAngles);
        double columns = 0.0;
        for (float value : column) { columns += double(value); }
        expect(std::fabs(columns - held) < 1e-3, "the columns do not sum the grid");
        run.release();
    }

    // A run of 40 steps repeats to the bit, and so does the same run cut into two.
    {
        std::vector<float4> positions;
        std::vector<float4> velocities;
        cloud(3000u, positions, velocities);
        HoleStepParams p = params(3000u, 8u);
        Run whole = make(context, positions, velocities, p);
        Run again = make(context, positions, velocities, p);
        ok(sc_hole_step(&whole.buffers, &p, sizeof p, 40u), "a run");
        ok(sc_hole_step(&again.buffers, &p, sizeof p, 15u), "the run's first part");
        ok(sc_hole_step(&again.buffers, &p, sizeof p, 25u), "the run's second part");
        std::vector<float4> a = read<float4>(whole.buffers.positions, 3000u);
        std::vector<float4> b = read<float4>(again.buffers.positions, 3000u);
        std::vector<float4> va = read<float4>(whole.buffers.velocities, 3000u);
        std::vector<float4> vb = read<float4>(again.buffers.velocities, 3000u);
        expect(std::memcmp(a.data(), b.data(), a.size() * 16u) == 0
                   && std::memcmp(va.data(), vb.data(), va.size() * 16u) == 0,
               "a run cut into two is not the run");
        float light = 0.0f;
        for (const float4 &x : a) { light = std::fmax(light, x.w); }
        expect(light > 0.0f, "the gas gave no tracer any heat");
        whole.release();
        again.release();
    }

    // Alone, without gas, a tracer on a circular orbit stays on it; one inside the swallowing
    // radius is swallowed and no longer moves.
    {
        float r = 8.0f;
        float speed = std::sqrt(r) / (r - 1.0f);
        std::vector<float4> positions = {float4(r, 0.0f, 0.0f, 0.0f), float4(1.2f, 0.0f, 0.0f, 0.0f)};
        std::vector<float4> velocities = {float4(0.0f, speed, 0.0f, 0.0f), float4(0.0f, 0.1f, 0.0f, 0.0f)};
        HoleStepParams p = params(2u, 1u);
        p.stickiness = 0.0f;
        p.viscosity = 0.0f;
        Run run = make(context, positions, velocities, p);
        float orbit = 2.0f * M_PI_F * (r - 1.0f) * std::sqrt(r);
        uint steps = uint(orbit / p.timeStep);
        ok(sc_hole_step(&run.buffers, &p, sizeof p, steps), "an orbit");
        std::vector<float4> x = read<float4>(run.buffers.positions, 2u);
        std::vector<float4> v = read<float4>(run.buffers.velocities, 2u);
        float radius = std::sqrt(x[0].x * x[0].x + x[0].y * x[0].y + x[0].z * x[0].z);
        std::printf("  a circular orbit at r = 8 after %u steps: r = %.6f\n", steps, double(radius));
        expect(std::fabs(radius - r) < 1e-3f, "a circular orbit drifted");
        expect(v[1].w == -1.0f && v[0].w >= 0.0f, "the tracer inside the swallowing radius was not swallowed");
        run.release();
    }

    // A splat lays its kernel round its point, the same twice, and nothing for a tracer swallowed.
    {
        const uint side = 32u;
        HoleSplatUniforms u;
        std::memset(&u, 0, sizeof u);
        u.viewProjection = float4x4(float4(1.0f, 0.0f, 0.0f, 0.0f), float4(0.0f, 1.0f, 0.0f, 0.0f),
                                    float4(0.0f, 0.0f, 0.0f, 0.0f), float4(0.0f, 0.0f, 0.5f, 1.0f));
        u.camera = float4(0.0f, 0.0f, -50.0f, 50.0f);
        u.projectionScale = 1.0f;
        u.minimumSize = 5.0f;
        u.maximumSize = 5.0f;
        u.brightness = 1.0f;
        u.hottest = 6000.0f;
        u.innerEdge = 0.1f;
        u.edgePeak = 1.0f;
        u.lightScale = 1.0f;
        u.supersample = 1.0f;
        std::vector<float4> positions = {float4(0.1f, 0.2f, 0.5f, 0.0f), float4(-0.5f, -0.5f, 0.5f, 0.0f)};
        std::vector<float4> velocities = {float4(0.0f), float4(0.0f, 0.0f, 0.0f, -1.0f)};
        sc_buffer *x = held(context, positions);
        sc_buffer *v = held(context, velocities);
        sc_buffer *light = nullptr;
        sc_buffer *values = nullptr;
        ok(sc_buffer_create(context, side * side * 32u, &light), "the light");
        ok(sc_buffer_create(context, side * side * 16u, &values), "the light as floats");
        ok(sc_hole_splat(light, side, side, x, v, 2u, &u, sizeof u, nullptr, nullptr), "a splat");
        std::vector<unsigned long long> first = read<unsigned long long>(light, side * side * 4u);
        ok(sc_buffer_fill(light, 0u), "the light emptied");
        ok(sc_hole_splat(light, side, side, x, v, 2u, &u, sizeof u, nullptr, nullptr), "the splat again");
        std::vector<unsigned long long> second = read<unsigned long long>(light, side * side * 4u);
        expect(first == second, "a splat drawn twice differs");
        ok(sc_hole_finish(light, values, side, side), "the light as floats");
        std::vector<float> pixels = read<float>(values, side * side * 4u);
        // At clip (0.1, 0.2) the point stands at (17.6, 12.8), its square five pixels wide.
        uint lit = 0u;
        bool near = true;
        float alpha = 0.0f;
        float brightest = 0.0f;
        uint where = 0u;
        for (uint y = 0; y < side; ++y) {
            for (uint x = 0; x < side; ++x) {
                const float *pixel = &pixels[(y * side + x) * 4u];
                alpha = std::fmax(alpha, pixel[3]);
                if (pixel[0] + pixel[1] + pixel[2] <= 0.0f) { continue; }
                lit += 1u;
                near = near && std::fabs(float(x) + 0.5f - 17.6f) < 3.0f && std::fabs(float(y) + 0.5f - 12.8f) < 3.0f;
                if (pixel[1] > brightest) {
                    brightest = pixel[1];
                    where = y * side + x;
                }
            }
        }
        std::printf("  a splat of 5 pixels: %u pixels lit, the brightest at (%u, %u)\n", lit, where % side,
                    where / side);
        expect(lit >= 9u && lit <= 25u && near, "the splat is not round its point, or the swallowed tracer drew");
        expect(where == 12u * side + 17u, "the splat's brightest pixel is not its centre's");
        expect(alpha == 0.0f, "a splat laid coverage");
        expect(sc_hole_splat(light, side, side, x, v, 2u, &u, sizeof u - 4u, nullptr, nullptr) == SC_INVALID_ARGUMENT,
               "uniforms of another size");
        u.lensed = 1u;
        u.radiusCount = 8u;
        u.angleCount = 8u;
        expect(sc_hole_splat(light, side, side, x, v, 2u, &u, sizeof u, nullptr, nullptr) == SC_INVALID_ARGUMENT,
               "a lensed splat without its table");
        expect(sc_hole_splat(light, side, side, x, v, 3u, &u, sizeof u, x, x) == SC_INVALID_ARGUMENT,
               "more tracers than the buffers hold");
        for (sc_buffer *buffer : {x, v, light, values}) { sc_buffer_destroy(buffer); }
    }

    {
        HoleStepParams p = params(10u, 1u);
        sc_hole_run empty;
        std::memset(&empty, 0, sizeof empty);
        expect(sc_hole_step(&empty, &p, sizeof p, 1u) == SC_INVALID_ARGUMENT, "a step without buffers");
        expect(sc_hole_step(&empty, &p, sizeof p - 4u, 1u) == SC_INVALID_ARGUMENT, "parameters of another size");
    }

    sc_context_destroy(context);
    if (failures == 0) { std::printf("cuda/tests/hole_passes.cu: the black hole's kernels run on the CPU target\n"); }
    return failures == 0 ? 0 : 1;
}

}  // namespace HoleShaders
}  // namespace metal

int main() { return metal::HoleShaders::run(); }

#endif
