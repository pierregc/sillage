// The black hole close up on CUDA (#336). The step's four kernels call the shared functions of
// HoleShaders, a thread a cell or a tracer as Metal dispatches them. The splat is Metal's vertex
// and fragment functions done by hand, as the renderer's particle passes are (#276): a thread a
// tracer calls the shared per-tracer function, walks the pixels of its square by the
// rasteriser's rules, and adds what the shared per-pixel function gives each into the light. No
// arithmetic of the hole is in this file.
#include "cuda_cpu.h"

#include <cstring>

#include "engine.h"
#include "fixed.h"
#include "raster.h"
#include "HoleShaders.h"

namespace metal {
namespace HoleShaders {

using namespace fixedpoint;

static __device__ __forceinline__ uint threadInGrid() { return blockIdx.x * blockDim.x + threadIdx.x; }

__global__ void holeClear(uint4 *fixed, uint cells) { holeClearCell(fixed, cells, threadInGrid()); }

__global__ void holeDeposit(const float4 *positions, const float4 *velocities, atomic_uint *grid,
                            HoleStepParams p) {
    holeDepositTracer(positions, velocities, grid, p, threadInGrid());
}

__global__ void holeResolve(const uint *fixed, float4 *grid, uint cells) {
    holeResolveCell(fixed, grid, cells, threadInGrid());
}

__global__ void holeColumn(const float4 *grid, float *column, HoleStepParams p) {
    holeColumnSum(grid, column, p, threadInGrid());
}

__global__ void holeStep(float4 *positions, float4 *velocities, const float4 *grid, const float *column,
                         HoleStepParams p) {
    holeStepTracer(positions, velocities, grid, column, p, threadInGrid());
}

// Metal's point and its fragment: the pixels whose centre is in the square, those past the
// splat's disc left alone where Metal's fragment discards.
__global__ void holeSplatVertex(const float4 *positions, const float4 *velocities, HoleSplatUniforms u,
                                const float4 *lens, const float4 *farLens, uint count, fixed_t *light, uint width,
                                uint height) {
    uint vid = threadInGrid();
    if (vid >= count) { return; }
    HoleSplat splat = holeSplat(vid, positions, velocities, u, lens, farLens);
    Square square;
    if (!pointSquare(splat.position, splat.pointSize, width, height, square)) { return; }
    for (int y = square.top; y < square.bottom; ++y) {
        for (int x = square.left; x < square.right; ++x) {
            float r2 = holeRadius2(pointCoord(square, x, y));
            if (r2 > 1.0f) { continue; }
            half4 value = holeSplatPixel(splat.color, r2);
            fixed_t *pixel = light + (size_t(y) * width + size_t(x)) * 4u;
            addFixed(pixel, toFixed(value.x, fixedUnit));
            addFixed(pixel + 1, toFixed(value.y, fixedUnit));
            addFixed(pixel + 2, toFixed(value.z, fixedUnit));
            addFixed(pixel + 3, toFixed(value.w, fixedUnit));
        }
    }
}

__global__ void holeFinish(const fixed_t *fixed, float *values, size_t count) {
    size_t index = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) { return; }
    values[index] = float(fixed[index]) / fixedUnit;
}

}  // namespace HoleShaders
}  // namespace metal

namespace hs = metal::HoleShaders;

namespace sillage {
namespace hole {

constexpr uint32_t block = 256u;

#define LAUNCH(kernel, threads, ...)                                                          \
    do {                                                                                      \
        SILLAGE_LAUNCH(hs::kernel, dim3(groups(threads)), dim3(block), __VA_ARGS__);         \
        if (sc_status launched = check(cudaGetLastError(), #kernel)) { return launched; }     \
    } while (0)

static uint32_t groups(size_t threads) { return uint32_t((threads + block - 1u) / block); }

template <class T>
static T parameters(const void *bytes) {
    T value;
    memcpy(&value, bytes, sizeof(T));
    return value;
}

static sc_status needs(const sc_buffer *buffer, size_t length, const char *call, const char *what) {
    if (!buffer) { return fail(SC_INVALID_ARGUMENT, "%s: no %s", call, what); }
    if (!holds(buffer, 0u, length)) {
        return fail(SC_INVALID_ARGUMENT, "%s: the %s holds %zu bytes, %zu are read", call, what, buffer->length,
                    length);
    }
    return SC_OK;
}

}  // namespace hole
}  // namespace sillage

using namespace sillage;
using namespace sillage::hole;

extern "C" {

sc_status sc_hole_step(const sc_hole_run *run, const void *params, size_t length, uint32_t steps) {
    const char *call = "sc_hole_step";
    if (!run) { return fail(SC_INVALID_ARGUMENT, "%s: no run", call); }
    if (!params || length != sizeof(hs::HoleStepParams)) {
        return fail(SC_INVALID_ARGUMENT, "%s: parameters of %zu bytes, the MSL reads %zu", call, length,
                    sizeof(hs::HoleStepParams));
    }
    hs::HoleStepParams p = parameters<hs::HoleStepParams>(params);
    if (p.gridRadii < 2u || p.gridAngles == 0u || p.gridHeights == 0u) {
        return fail(SC_INVALID_ARGUMENT, "%s: a grid of %u by %u by %u", call, p.gridRadii, p.gridAngles,
                    p.gridHeights);
    }
    size_t columns = size_t(p.gridRadii) * p.gridAngles;
    size_t cells = columns * p.gridHeights;
    size_t tracers = size_t(p.count) * 16u;
    if (sc_status status = needs(run->positions, tracers, call, "positions")) { return status; }
    if (sc_status status = needs(run->velocities, tracers, call, "velocities")) { return status; }
    if (sc_status status = needs(run->fixed, cells * 32u, call, "fixed point grid")) { return status; }
    if (sc_status status = needs(run->grid, cells * 16u, call, "grid")) { return status; }
    if (sc_status status = needs(run->column, columns * 4u, call, "columns")) { return status; }
    if (sc_status status = use(run->positions->context)) { return status; }
    auto positions = pointer<metal::float4>(run->positions);
    auto velocities = pointer<metal::float4>(run->velocities);
    auto grid = pointer<metal::float4>(run->grid);
    auto column = pointer<float>(run->column);
    metal::uint count = metal::uint(cells);
    for (uint32_t step = 0u; step < steps; ++step) {
        LAUNCH(holeClear, 2u * cells, pointer<metal::uint4>(run->fixed), count);
        LAUNCH(holeDeposit, p.count, positions, velocities, pointer<metal::atomic_uint>(run->fixed), p);
        LAUNCH(holeResolve, cells, pointer<const metal::uint>(run->fixed), grid, count);
        LAUNCH(holeColumn, columns, grid, column, p);
        LAUNCH(holeStep, p.count, positions, velocities, grid, column, p);
    }
    return SC_OK;
}

sc_status sc_hole_splat(sc_buffer *light, uint32_t width, uint32_t height, const sc_buffer *positions,
                        const sc_buffer *velocities, uint32_t count, const void *uniforms, size_t length,
                        const sc_buffer *lens, const sc_buffer *far_lens) {
    const char *call = "sc_hole_splat";
    if (!uniforms || length != sizeof(hs::HoleSplatUniforms)) {
        return fail(SC_INVALID_ARGUMENT, "%s: uniforms of %zu bytes, the MSL reads %zu", call, length,
                    sizeof(hs::HoleSplatUniforms));
    }
    if (width == 0u || height == 0u) { return fail(SC_INVALID_ARGUMENT, "%s: a light of %u by %u", call, width, height); }
    hs::HoleSplatUniforms u = parameters<hs::HoleSplatUniforms>(uniforms);
    if (sc_status status = needs(light, size_t(width) * height * 32u, call, "light")) { return status; }
    if (sc_status status = needs(positions, size_t(count) * 16u, call, "positions")) { return status; }
    if (sc_status status = needs(velocities, size_t(count) * 16u, call, "velocities")) { return status; }
    if (u.lensed != 0u) {
        size_t table = size_t(u.image + 1u) * u.radiusCount * u.angleCount * 16u;
        if (u.radiusCount < 2u || u.angleCount < 2u) {
            return fail(SC_INVALID_ARGUMENT, "%s: a lens table of %u by %u", call, u.radiusCount, u.angleCount);
        }
        if (u.lensBlend < 1.0f) {
            if (sc_status status = needs(lens, table, call, "near lens table")) { return status; }
        }
        if (u.lensBlend > 0.0f) {
            if (sc_status status = needs(far_lens, table, call, "far lens table")) { return status; }
        }
    }
    if (count == 0u) { return SC_OK; }
    if (sc_status status = use(light->context)) { return status; }
    LAUNCH(holeSplatVertex, count, pointer<const metal::float4>(positions), pointer<const metal::float4>(velocities),
           u, pointer<const metal::float4>(lens), pointer<const metal::float4>(far_lens), count,
           pointer<metal::fixedpoint::fixed_t>(light), width, height);
    return SC_OK;
}

sc_status sc_hole_finish(const sc_buffer *light, sc_buffer *values, uint32_t width, uint32_t height) {
    const char *call = "sc_hole_finish";
    size_t count = size_t(width) * height * 4u;
    if (sc_status status = needs(light, count * 8u, call, "light")) { return status; }
    if (sc_status status = needs(values, count * 4u, call, "values")) { return status; }
    if (count == 0u) { return SC_OK; }
    if (sc_status status = use(light->context)) { return status; }
    LAUNCH(holeFinish, count, pointer<const metal::fixedpoint::fixed_t>(light), pointer<float>(values), count);
    return SC_OK;
}

}  // extern "C"
