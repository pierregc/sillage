// The renderer's particle passes on the CPU target (#276), through the C API alone: a star lays
// its whole kernel, a frame drawn twice is the same to the bit, both ways for large splats lay
// the same bits, and a call the renderer cannot answer is refused. The Swift tests draw whole
// scenes with the frame plan (Tests/SillageCUDATests/CUDARenderTests.swift); this one runs
// where there is no Swift, with g++ and with clang++.
#include "cuda_cpu.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

#include "sillage_cuda.h"
#include "Shaders.h"

#if defined(SILLAGE_CPU)

namespace metal {
namespace Shaders {

static int failures = 0;

static void expect(bool condition, const char *what) {
    if (condition) { return; }
    failures += 1;
    std::printf("cuda/tests/render_passes.cu: %s\n", what);
}

static bool ok(sc_status status, const char *what) {
    if (status == SC_OK) { return true; }
    failures += 1;
    std::printf("cuda/tests/render_passes.cu: %s: %s, %s\n", what, sc_status_name(status), sc_last_error());
    return false;
}

// A small generator, the same on every machine.
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

// A camera on the y axis that looks at the origin with no perspective: one unit of length is
// `scale` of the half frame, and every particle stands at depth 50.
static SplatUniforms uniforms(float scale, uint count, uint side) {
    SplatUniforms u;
    std::memset(&u, 0, sizeof u);
    u.viewProjection = float4x4(float4(scale, 0.0f, 0.0f, 0.0f), float4(0.0f, 0.0f, 0.01f, 0.0f),
                                float4(0.0f, scale, 0.0f, 0.0f), float4(0.0f, 0.0f, 0.5f, 50.0f));
    u.megayearsPerUnit = 1.0f;
    u.ionisedMyr = 5.0f;
    u.ionisingRiseMyr = 1.0f;
    u.populationYoungMyr = 1.0f;
    u.populationSpan = 9.0f;
    u.populationLast = 1.0f;
    u.luminosityNormalisation = 1.0f;
    u.brightness = 1000000.0f / float(count);
    u.dustStrength = 1000000.0f / float(count);
    u.starSize = 1.0f;
    u.projectionScale = float(side) * 25.0f;
    u.smoothingScale = 1.0f;
    u.referenceArea = 0.01f;
    u.minimumSize = 2.0f;
    u.maximumSize = 40.0f;
    u.slabNear = 30.0f;
    u.slabScale = 1.0f / 40.0f;
    u.columnCell = 8.0f;
    u.glint = 1.0f;
    return u;
}

struct Scene {
    sc_context *context;
    std::vector<sc_buffer *> buffers;
    sc_render_massive massive;
    uint count;
};

// Stars and grains of dust scattered over the frame, a few of them wide.
static Scene scene(sc_context *context, uint count) {
    Random random{276u};
    std::vector<float4> positions(count);
    std::vector<float> population(count, 0.5f), formation(count), luminosity(count, 1.0f), smoothing(count),
        rampKeys(count, 1.7f);
    std::vector<uint> component(count), galaxy(count, 0u);
    std::vector<float2> traits(count, float2(1.0f, 1.0f));
    for (uint i = 0; i < count; ++i) {
        positions[i] = float4(random.next() * 1.6f - 0.8f, random.next() * 8.0f - 4.0f,
                              random.next() * 1.6f - 0.8f, 0.0f);
        bool dust = i % 4u == 0u;
        component[i] = dust ? 2u : 0u;
        formation[i] = dust ? 1e9f : -1e9f;
        smoothing[i] = i % 97u == 0u ? 0.3f : 0.004f + 0.02f * random.next();
    }
    Scene made;
    made.context = context;
    made.count = count;
    made.massive = sc_render_massive{held(context, positions), 0u,
                                     held(context, population),
                                     held(context, formation),
                                     held(context, luminosity),
                                     held(context, component),
                                     held(context, galaxy),
                                     held(context, smoothing),
                                     held(context, traits),
                                     held(context, rampKeys),
                                     count};
    made.buffers = {const_cast<sc_buffer *>(made.massive.positions),  const_cast<sc_buffer *>(made.massive.population),
                    const_cast<sc_buffer *>(made.massive.formation),  const_cast<sc_buffer *>(made.massive.luminosity),
                    const_cast<sc_buffer *>(made.massive.component),  const_cast<sc_buffer *>(made.massive.galaxy),
                    const_cast<sc_buffer *>(made.massive.smoothing),  const_cast<sc_buffer *>(made.massive.traits),
                    const_cast<sc_buffer *>(made.massive.ramp_keys)};
    return made;
}

static void release(Scene &made) {
    for (sc_buffer *buffer : made.buffers) { sc_buffer_destroy(buffer); }
}

static std::vector<unsigned long long> fixed(sc_renderer *renderer, sc_render_target which, uint side) {
    std::vector<unsigned long long> values(size_t(side) * side * 4u);
    ok(sc_buffer_download(sc_render_target_of(renderer, which), 0, values.data(), values.size() * 8u), "a download");
    return values;
}

// The dust then the stars of a scene, as the frame plan orders them.
static bool frame(sc_renderer *renderer, const Scene &made, SplatUniforms u) {
    DiskFrame frames[1];
    GalaxyRamp ramps[1];
    std::memset(frames, 0, sizeof frames);
    std::memset(ramps, 0, sizeof ramps);
    float stellar[4] = {8000.0f, 1.0f, 5000.0f, 1.0f};
    bool fine = ok(sc_render_set_stellar(renderer, stellar, 2u), "the stellar table")
        && ok(sc_render_set_particles(renderer, &made.massive, nullptr), "the particles")
        && ok(sc_render_set_frame(renderer, frames, 1u, ramps, 1u), "the frame") && ok(sc_render_clear(renderer), "clear");
    for (sc_render_pass pass : {SC_RENDER_DUST, SC_RENDER_STARS}) {
        u.pass = pass == SC_RENDER_STARS ? 1u : 0u;
        fine = fine && ok(sc_render_begin(renderer, pass), "begin")
            && ok(sc_render_draw(renderer, pass, &u, sizeof u, nullptr, 0u, 0u, made.count, 0u, 0u), "draw");
    }
    return fine && ok(sc_render_finish(renderer), "finish");
}

static int run() {
    sc_context *context = nullptr;
    if (!ok(sc_context_create(0, &context), "a context")) { return 1; }
    const uint side = 96u;
    sc_render_config config = {side, side, side / 8u, side / 8u, 0u, 0u, 0u, 0u};

    // One star, 20 pixels wide and off the pixel grid: its coverage is the kernel's integral.
    {
        Scene one = scene(context, 1u);
        float4 at(0.0131f, 0.0f, 0.0071f, 0.0f);
        float born = -1e9f;
        uint kind = 0u;
        ok(sc_buffer_upload(const_cast<sc_buffer *>(one.massive.positions), 0, &at, sizeof at), "the star");
        ok(sc_buffer_upload(const_cast<sc_buffer *>(one.massive.formation), 0, &born, 4u), "its age");
        ok(sc_buffer_upload(const_cast<sc_buffer *>(one.massive.component), 0, &kind, 4u), "its kind");
        sc_renderer *renderer = nullptr;
        ok(sc_renderer_create(context, &config, &renderer), "a renderer");
        SplatUniforms u = uniforms(50.0f, 1u, side);
        u.minimumSize = 20.0f;
        u.maximumSize = 20.0f;
        if (frame(renderer, one, u)) {
            std::vector<float> light(size_t(side) * side * 4u);
            ok(sc_buffer_download(sc_render_target_of(renderer, SC_RENDER_LIGHT), 0, light.data(), light.size() * 4u),
               "the light");
            double coverage = 0.0;
            for (size_t pixel = 0; pixel < light.size(); pixel += 4u) { coverage += double(light[pixel + 3u]); }
            double integral = 3.14159265358979 * 100.0 * (1.0 - std::exp(-4.5)) / 4.5;
            std::printf("  a star's coverage %.3f, its kernel's integral %.3f\n", coverage, integral);
            expect(std::fabs(coverage / integral - 1.0) < 0.01, "a star does not lay its whole kernel");
        }
        sc_renderer_destroy(renderer);
        release(one);
    }

    // A frame twice, then the second way for large splats: the same bits.
    {
        const uint count = 6000u;
        Scene many = scene(context, count);
        SplatUniforms u = uniforms(50.0f, count, side);
        sc_renderer *renderer = nullptr;
        ok(sc_renderer_create(context, &config, &renderer), "a renderer");
        frame(renderer, many, u);
        auto light = fixed(renderer, SC_RENDER_LIGHT_FIXED, side);
        auto dust = fixed(renderer, SC_RENDER_DUST_FIXED, side);
        size_t lit = 0, dusty = 0;
        for (auto value : light) { lit += value != 0ull ? 1u : 0u; }
        for (auto value : dust) { dusty += value != 0ull ? 1u : 0u; }
        std::printf("  %u particles: %zu of %zu values of light, %zu of dust\n", count, lit, light.size(), dusty);
        expect(lit > light.size() / 8u && dusty > 0u, "the frame is empty");
        frame(renderer, many, u);
        expect(fixed(renderer, SC_RENDER_LIGHT_FIXED, side) == light, "the light of a frame drawn twice differs");
        expect(fixed(renderer, SC_RENDER_DUST_FIXED, side) == dust, "the dust of a frame drawn twice differs");
        expect(sc_render_set_large(renderer, 16u) == SC_INVALID_ARGUMENT, "large splats with no room for them");
        sc_renderer_destroy(renderer);

        for (uint capacity : {4096u, 5u}) {
            sc_render_config roomy = config;
            roomy.large_capacity = capacity;
            sc_renderer *second = nullptr;
            ok(sc_renderer_create(context, &roomy, &second), "a renderer with room for large splats");
            ok(sc_render_set_large(second, 16u), "the second way");
            frame(second, many, u);
            std::printf("  the second way: %u splats over 16 pixels, room for %u\n", sc_render_large_count(second),
                        capacity);
            expect(sc_render_large_count(second) > capacity || capacity > 5u, "the list never fills");
            expect(sc_render_large_count(second) > 0u, "no splat was set aside");
            expect(fixed(second, SC_RENDER_LIGHT_FIXED, side) == light, "the two ways lay another light");
            expect(fixed(second, SC_RENDER_DUST_FIXED, side) == dust, "the two ways lay another dust");
            sc_renderer_destroy(second);
        }

        // What the renderer refuses.
        sc_renderer *strict = nullptr;
        ok(sc_renderer_create(context, &config, &strict), "a renderer");
        ok(sc_render_set_particles(strict, &many.massive, nullptr), "the particles");
        expect(sc_render_draw(strict, SC_RENDER_DUST, &u, sizeof u - 8u, nullptr, 0u, 0u, count, 0u, 0u)
                   == SC_INVALID_ARGUMENT, "uniforms of another size");
        expect(sc_render_draw(strict, SC_RENDER_DUST, &u, sizeof u, nullptr, 0u, 1u, count, 0u, 0u)
                   == SC_INVALID_ARGUMENT, "a range past the particles");
        expect(sc_render_draw(strict, SC_RENDER_STARS, &u, sizeof u, nullptr, 0u, 0u, 0u, 0u, 3u)
                   == SC_INVALID_ARGUMENT, "tracers that were never given");
        expect(sc_render_begin(strict, SC_RENDER_WEB_RESOLVE) == SC_INVALID_ARGUMENT, "the web without its lace");
        float mean = 0.0f;
        expect(sc_render_bake_lace(strict, &mean) == SC_INVALID_ARGUMENT, "a lace on a renderer without the web");
        sc_render_massive shorter = many.massive;
        shorter.count = count + 1u;
        expect(sc_render_set_particles(strict, &shorter, nullptr) == SC_INVALID_ARGUMENT, "buffers too short");
        sc_renderer_destroy(strict);
        release(many);
    }

    // The lace: its mean is its last level, and every level the mean of the one above.
    {
        sc_render_config webbed = {side, side, side / 8u, side / 8u, side / 2u, side / 2u, 64u, 0u};
        sc_renderer *renderer = nullptr;
        ok(sc_renderer_create(context, &webbed, &renderer), "a renderer with the web");
        float mean = 0.0f;
        ok(sc_render_bake_lace(renderer, &mean), "the lace");
        std::vector<float> lace(64u * 64u);
        ok(sc_buffer_download(sc_render_target_of(renderer, SC_RENDER_LACE), 0, lace.data(), lace.size() * 4u),
           "the lace's first level");
        double total = 0.0;
        for (float value : lace) { total += double(value); }
        std::printf("  a lace of 64 texels: mean %.6f\n", double(mean));
        expect(mean > 0.1f && std::fabs(total / double(lace.size()) / double(mean) - 1.0) < 1e-5,
               "the lace's last level is not its mean");
        sc_renderer_destroy(renderer);
    }

    sc_context_destroy(context);
    if (failures == 0) { std::printf("cuda/tests/render_passes.cu: the particle passes run on the CPU target\n"); }
    return failures == 0 ? 0 : 1;
}

}  // namespace Shaders
}  // namespace metal

int main() { return metal::Shaders::run(); }

#endif
