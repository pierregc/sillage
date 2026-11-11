// The renderer's particle passes on CUDA (#276). Metal draws each particle as a point with the
// rasteriser: a vertex function says where it lands and what it carries, the rasteriser covers
// the pixels of its square, and a fragment function says what each one takes, blended into the
// target. Here a kernel does a pass: a thread a particle calls the shared per-particle function
// of Shaders, walks the pixels of the square as the rasteriser would, and calls the shared
// per-pixel function for each. The entry points, the walk and the accumulation are this file's;
// no arithmetic of a splat is.
//
// The light and the dust accumulate as 64-bit fixed point through integer atomics that saturate,
// so a pixel's sum is exact whatever order the threads run in, and a frame drawn twice is the
// same to the bit. Nothing here needs a block barrier: every kernel runs on the CPU target.
#include "cuda_cpu.h"

#include <initializer_list>
#include <mutex>
#include <new>

#include "engine.h"
#include "Shaders.h"

namespace metal {
namespace Shaders {

typedef unsigned long long fixed_t;

// One unit of light or dust in a fixed point target, 2^40: a pixel holds up to 2^24, which is
// 256 times what Metal's half float target holds, in steps of 9e-13, and the largest pixel
// measured so far is in docs/notes/cuda-engine.md. A count of the column pass is one.
constexpr float fixedUnit = 1099511627776.0f;
constexpr float countUnit = 1.0f;
constexpr fixed_t fixedCeiling = ~0ull;

// What a value adds to its cell. Nothing negative and nothing that is not a number is laid.
static __device__ __forceinline__ fixed_t toFixed(float value, float unit) {
    if (!(value > 0.0f)) { return 0ull; }
    float scaled = value * unit;
    if (scaled >= 9.2233720e18f) { return 1ull << 63; }
    // Past 2^23 a float is whole already, and adding a half would round it away.
    return scaled < 8388608.0f ? fixed_t(scaled + 0.5f) : fixed_t(scaled);
}

// Adds to a cell and stops at the ceiling rather than wrap: the sum of what every thread adds,
// in any order.
static __device__ __forceinline__ void addFixed(fixed_t *cell, fixed_t amount) {
    if (amount == 0ull) { return; }
#if defined(SILLAGE_CPU)
    fixed_t held = __atomic_load_n(cell, __ATOMIC_RELAXED);
    for (;;) {
        fixed_t sum = held + amount;
        if (sum < held) { sum = fixedCeiling; }
        if (__atomic_compare_exchange_n(cell, &held, sum, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) { return; }
    }
#else
    fixed_t held = *cell;
    for (;;) {
        fixed_t sum = held + amount;
        if (sum < held) { sum = fixedCeiling; }
        fixed_t seen = atomicCAS(cell, held, sum);
        if (seen == held) { return; }
        held = seen;
    }
#endif
}

static __device__ __forceinline__ void add4(fixed_t *pixel, float4 value, float unit) {
    addFixed(pixel, toFixed(value.x, unit));
    addFixed(pixel + 1, toFixed(value.y, unit));
    addFixed(pixel + 2, toFixed(value.z, unit));
    addFixed(pixel + 3, toFixed(value.w, unit));
}

// The larger of a cell and a value that is not negative: their bits order as they do.
static __device__ __forceinline__ void maxBits(uint *cell, float value) {
    uint bits = as_type<uint>(value > 0.0f ? value : 0.0f);
    if (bits == 0u) { return; }
#if defined(SILLAGE_CPU)
    uint held = __atomic_load_n(cell, __ATOMIC_RELAXED);
    while (held < bits
           && !__atomic_compare_exchange_n(cell, &held, bits, true, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
#else
    atomicMax(cell, bits);
#endif
}

static __device__ __forceinline__ uint claim(uint *counter) {
#if defined(SILLAGE_CPU)
    return __atomic_fetch_add(counter, 1u, __ATOMIC_RELAXED);
#else
    return atomicAdd(counter, 1u);
#endif
}

// What Metal's rasteriser does with a point, on a target of `width` by `height` pixels whose
// centres sit at half integers: a point whose centre is outside the clip volume draws nothing,
// its size is held between the smallest and the largest a point may have, and it covers the
// pixels whose centre lies in the square of that size about its own.
constexpr float smallestPoint = 1.0f;
constexpr float largestPoint = 511.0f;

struct Square {
    float2 centre;
    float size;
    int left;
    int right;
    int top;
    int bottom;
};

static __device__ __forceinline__ int pixelEdge(float edge, uint side) {
    return int(min(max(ceilf(edge - 0.5f), 0.0f), float(side)));
}

static __device__ __forceinline__ bool pointSquare(float4 clip, float pointSize, uint width, uint height,
                                                   Square &square) {
    if (!(clip.w > 0.0f) || !(pointSize == pointSize)) { return false; }
    if (!(clip.x >= -clip.w && clip.x <= clip.w && clip.y >= -clip.w && clip.y <= clip.w && clip.z >= 0.0f
          && clip.z <= clip.w)) {
        return false;
    }
    square.size = min(max(pointSize, smallestPoint), largestPoint);
    square.centre = float2((clip.x / clip.w * 0.5f + 0.5f) * float(width),
                           (0.5f - clip.y / clip.w * 0.5f) * float(height));
    float reach = square.size * 0.5f;
    square.left = pixelEdge(square.centre.x - reach, width);
    square.right = pixelEdge(square.centre.x + reach, width);
    square.top = pixelEdge(square.centre.y - reach, height);
    square.bottom = pixelEdge(square.centre.y + reach, height);
    return square.left < square.right && square.top < square.bottom;
}

// Where a pixel sits in the point's square, from 0 to 1 on each axis: Metal's point_coord.
static __device__ __forceinline__ float2 pointCoord(const Square &square, int x, int y) {
    return (float2(float(x) + 0.5f, float(y) + 0.5f) - square.centre) / square.size + 0.5f;
}

// The buffers of a pass, as Metal binds them to its vertex function.
struct Massive {
    const float3 *positions;
    const float *population;
    const float *formation;
    const float *luminosity;
    const uint *component;
    const uint *galaxy;
    const float *smoothing;
    const float2 *traits;
    const float *rampKeys;
};

struct Tracers {
    const float4 *states;
    const uint *words;
    const uint2 *cells;
    const float *treeFrame;
    uint depth;
    float scales[16];
};

struct Frame {
    SplatUniforms u;
    WebUniforms w;
    const DiskFrame *frames;
    const float2 *stellar;
    const GalaxyRamp *ramps;
    ColumnDensity column;
};

struct Range {
    uint first;
    uint count;
};

// The targets a splat's pixels write, and the finished dust a star reads at its own.
struct Targets {
    fixed_t *light;
    fixed_t *dust;
    const float4 *finishedDust;
    uint width;
    uint height;
};

struct CarrierTargets {
    fixed_t *carrier;
    uint *tags;
    uint width;
    uint height;
};

// Which fragment function a splat's pixels go through: Metal's pipeline pairs it with the
// vertex function.
constexpr uint layDust = 0u;
constexpr uint layLight = 1u;
constexpr uint layStarfield = 2u;

// The second way for large splats: a splat whose square covers more than `threshold` pixels is
// set aside, and a block of threads shares its pixels afterwards. A list that is full leaves
// the splat to its particle's thread.
struct Large {
    void *entries;
    uint *count;
    uint capacity;
    uint threshold;
};

template <class Point>
static __device__ __forceinline__ bool setAside(const Large &large, const Square &square, const Point &point) {
    if (large.threshold == 0u) { return false; }
    uint pixels = uint(square.right - square.left) * uint(square.bottom - square.top);
    if (pixels <= large.threshold) { return false; }
    uint slot = claim(large.count);
    if (slot >= large.capacity) { return false; }
    static_cast<Point *>(large.entries)[slot] = point;
    return true;
}

static __device__ __forceinline__ void laySplat(uint lay, const Splat &splat, int x, int y, float2 coord,
                                                const Targets &targets) {
    size_t pixel = size_t(y) * targets.width + size_t(x);
    if (lay == layDust) {
        half4 dust(0.0f);
        if (dustPixel(splat.opticalDepth, splat.slab, coord, dust)) { add4(targets.dust + pixel * 4u, dust, fixedUnit); }
    } else if (lay == layLight) {
        half4 light(0.0f);
        if (lightPixel(splat.color, splat.slab, targets.finishedDust[pixel], coord, light)) {
            add4(targets.light + pixel * 4u, light, fixedUnit);
        }
    } else {
        half4 light(0.0f);
        if (starfieldPixel(splat.color, splat.spikes, coord, light)) {
            add4(targets.light + pixel * 4u, light, fixedUnit);
        }
    }
}

static __device__ __forceinline__ void drawSplat(const Splat &splat, uint lay, const Targets &targets,
                                                 const Large &large) {
    Square square;
    if (!pointSquare(splat.position, splat.pointSize, targets.width, targets.height, square)) { return; }
    if (setAside(large, square, splat)) { return; }
    for (int y = square.top; y < square.bottom; ++y) {
        for (int x = square.left; x < square.right; ++x) {
            laySplat(lay, splat, x, y, pointCoord(square, x, y), targets);
        }
    }
}

// A tag as Metal's rgba8Unorm target holds it.
static __device__ __forceinline__ float unorm8(float value) {
    return floorf(min(max(value, 0.0f), 1.0f) * 255.0f + 0.5f) / 255.0f;
}

static __device__ __forceinline__ void layCarrier(const WebCarrier &grain, int x, int y, float2 coord,
                                                  const CarrierTargets &targets) {
    half4 carrier(0.0f);
    half4 tags(0.0f);
    if (!webCarrierPixel(grain.carried, grain.slab, grain.tag, coord, carrier, tags)) { return; }
    size_t pixel = (size_t(y) * targets.width + size_t(x)) * 4u;
    add4(targets.carrier + pixel, carrier, fixedUnit);
    for (int channel = 0; channel < 4; ++channel) { maxBits(targets.tags + pixel + channel, unorm8(tags[channel])); }
}

static __device__ __forceinline__ void drawCarrier(const WebCarrier &grain, const CarrierTargets &targets,
                                                   const Large &large) {
    Square square;
    if (!pointSquare(grain.position, grain.pointSize, targets.width, targets.height, square)) { return; }
    if (setAside(large, square, grain)) { return; }
    for (int y = square.top; y < square.bottom; ++y) {
        for (int x = square.left; x < square.right; ++x) {
            layCarrier(grain, x, y, pointCoord(square, x, y), targets);
        }
    }
}

// A thread a particle, from the range's first. A CUDA grid is whole blocks: no thread past the
// count gets through.
static __device__ __forceinline__ bool particle(Range range, uint &vid) {
    uint index = blockIdx.x * blockDim.x + threadIdx.x;
    vid = range.first + index;
    return index < range.count;
}

// The column pass: a count into the cell a particle that emits falls in.
static __device__ __forceinline__ void drawCount(const CountPoint &point, fixed_t *cells, uint width,
                                                 uint height) {
    Square square;
    if (!pointSquare(point.position, point.pointSize, width, height, square)) { return; }
    for (int y = square.top; y < square.bottom; ++y) {
        for (int x = square.left; x < square.right; ++x) {
            addFixed(cells + size_t(y) * width + size_t(x), toFixed(countPixel().x, countUnit));
        }
    }
}

__global__ void countVertex(Massive m, Frame f, Range range, fixed_t *cells, uint width, uint height) {
    uint vid;
    if (!particle(range, vid)) { return; }
    drawCount(countPoint(m.positions[vid], m.component[vid], m.formation[vid], f.u), cells, width, height);
}

__global__ void countTracerVertex(Tracers t, Frame f, Range range, fixed_t *cells, uint width, uint height) {
    uint vid;
    if (!particle(range, vid)) { return; }
    drawCount(countTracer(t.states[vid], t.words[vid * 4u + 3u], f.u), cells, width, height);
}

// The dust and the stars: `lay` says which, as the pipeline does on Metal.
__global__ void splatVertex(Massive m, Frame f, Range range, uint lay, Targets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    Splat splat = massiveSplat(vid, m.positions, m.population, m.formation, m.luminosity, m.component, f.u,
                               m.galaxy, f.frames, m.smoothing, f.stellar, m.traits, m.rampKeys, f.ramps,
                               f.column);
    drawSplat(splat, lay, targets, large);
}

__global__ void splatTracerVertex(Tracers t, Frame f, Range range, uint lay, Targets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    Splat splat = tracerSplat(t.states[vid], t.words[vid * 4u + 3u], f.u, f.frames, f.stellar, f.ramps, t.cells,
                              t.treeFrame, t.depth, t.scales, f.column);
    drawSplat(splat, lay, targets, large);
}

__global__ void starfieldVertex(const BackgroundStar *stars, Frame f, Range range, Targets targets,
                                Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    drawSplat(starfieldSplat(stars[vid], f.u), layStarfield, targets, large);
}

// The dust under the web: what the painted strands lay.
__global__ void dustWebVertex(Massive m, Frame f, Range range, Targets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    Splat splat = massiveDustWeb(vid, m.positions, m.formation, m.luminosity, m.component, f.u, m.galaxy,
                                 f.frames, m.smoothing, m.traits, f.w);
    drawSplat(splat, layDust, targets, large);
}

__global__ void dustWebTracerVertex(Tracers t, Frame f, Range range, Targets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    Splat splat = tracerDustWeb(t.states[vid], t.words[vid * 4u + 3u], f.u, f.frames, f.w, t.cells, t.treeFrame,
                                t.depth, t.scales);
    drawSplat(splat, layDust, targets, large);
}

// The dust the web multiplies, into the coarse carrier and its tags.
__global__ void webCarrierVertex(Massive m, Frame f, Range range, CarrierTargets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    WebCarrier grain = massiveWebCarrier(vid, m.positions, m.formation, m.luminosity, m.component, f.u, m.galaxy,
                                         f.frames, m.smoothing, m.traits, f.w);
    drawCarrier(grain, targets, large);
}

__global__ void webCarrierTracerVertex(Tracers t, Frame f, Range range, CarrierTargets targets, Large large) {
    uint vid;
    if (!particle(range, vid)) { return; }
    WebCarrier grain = tracerWebCarrier(t.states[vid], t.words[vid * 4u + 3u], f.u, f.frames, f.w, t.cells,
                                        t.treeFrame, t.depth, t.scales);
    drawCarrier(grain, targets, large);
}

// The carrier times the web, a thread a pixel of the frame, where Metal draws one triangle
// over it. The carrier is read with Metal's bilinear sampler and the tags with its nearest.
__global__ void webResolveFragment(Frame f, Lace lace, texels2d carried, texels2d tagged, fixed_t *dust,
                                   uint width, uint height) {
    size_t pixel = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    if (pixel >= size_t(width) * height) { return; }
    float2 centre(float(pixel % width) + 0.5f, float(pixel / width) + 0.5f);
    float2 uv = webResolveAt(centre, f.w);
    half4 webbed(0.0f);
    if (webResolved(uv, sample_bilinear(carried, uv), sample_nearest(tagged, uv), f.frames, f.w, lace, webbed)) {
        add4(dust + pixel * 4u, webbed, fixedUnit);
    }
}

// The raw look's points: every pixel of the square, with no kernel.
static __device__ __forceinline__ void drawPlain(const PlainPoint &point, fixed_t *light, uint width,
                                                 uint height) {
    Square square;
    if (!pointSquare(point.position, point.pointSize, width, height, square)) { return; }
    for (int y = square.top; y < square.bottom; ++y) {
        for (int x = square.left; x < square.right; ++x) {
            add4(light + (size_t(y) * width + size_t(x)) * 4u, plainPixel(point.color), fixedUnit);
        }
    }
}

__global__ void plainVertex(Massive m, Frame f, Range range, fixed_t *light, uint width, uint height) {
    uint vid;
    if (!particle(range, vid)) { return; }
    drawPlain(plainPoint(m.positions[vid], m.component[vid], m.galaxy[vid], f.u, f.frames), light, width, height);
}

__global__ void plainTracerVertex(Tracers t, Frame f, Range range, fixed_t *light, uint width, uint height) {
    uint vid;
    if (!particle(range, vid)) { return; }
    drawPlain(plainTracer(t.states[vid], t.words[vid * 4u + 3u], f.u, f.frames), light, width, height);
}

// One tile of the lace, a thread a texel.
__global__ void bakeLace(float *lace, uint width) {
    size_t texel = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    if (texel >= size_t(width) * width) { return; }
    lace[texel] = laceTexel(uint2(uint(texel % width), uint(texel / width)), width);
}

// CUDA's own kernels, which have no Metal function: what Metal's blit, its blending and its
// tile memory do there.

// A level of the lace from the one before, each texel the mean of four: generateMipmaps.
__global__ void laceLevel(float *lace, uint from, uint to, uint side) {
    size_t texel = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    if (texel >= size_t(side) * side) { return; }
    size_t x = (texel % side) * 2u;
    size_t y = (texel / side) * 2u;
    const float *above = lace + from;
    size_t wide = size_t(side) * 2u;
    lace[to + texel] = 0.25f * (above[y * wide + x] + above[y * wide + x + 1u] + above[(y + 1u) * wide + x]
                                + above[(y + 1u) * wide + x + 1u]);
}

// A fixed point target as the floats the next pass reads.
__global__ void finishFixed(const fixed_t *fixed, float *values, size_t count, float unit) {
    size_t index = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) { return; }
    values[index] = float(fixed[index]) / unit;
}

// The splats set aside, a block each: its threads share the pixels of the square.
__global__ void largeSplats(const Splat *splats, uint count, uint lay, Targets targets) {
    if (blockIdx.x >= count) { return; }
    Splat splat = splats[blockIdx.x];
    Square square;
    if (!pointSquare(splat.position, splat.pointSize, targets.width, targets.height, square)) { return; }
    uint wide = uint(square.right - square.left);
    uint pixels = wide * uint(square.bottom - square.top);
    for (uint pixel = threadIdx.x; pixel < pixels; pixel += blockDim.x) {
        int x = square.left + int(pixel % wide);
        int y = square.top + int(pixel / wide);
        laySplat(lay, splat, x, y, pointCoord(square, x, y), targets);
    }
}

__global__ void largeCarriers(const WebCarrier *grains, uint count, CarrierTargets targets) {
    if (blockIdx.x >= count) { return; }
    WebCarrier grain = grains[blockIdx.x];
    Square square;
    if (!pointSquare(grain.position, grain.pointSize, targets.width, targets.height, square)) { return; }
    uint wide = uint(square.right - square.left);
    uint pixels = wide * uint(square.bottom - square.top);
    for (uint pixel = threadIdx.x; pixel < pixels; pixel += blockDim.x) {
        int x = square.left + int(pixel % wide);
        int y = square.top + int(pixel / wide);
        layCarrier(grain, x, y, pointCoord(square, x, y), targets);
    }
}

}  // namespace Shaders
}  // namespace metal

namespace sh = metal::Shaders;

struct sc_renderer {
    sc_context *context;
    sc_render_config config;
    uint32_t laceLevels;
    bool baked;
    float laceMean;
    uint32_t largeThreshold;
    uint32_t largeCount;
    std::mutex largeLock;
    // What a later pass reads as floats and an earlier one changed.
    bool columnStale;
    bool carrierStale;
    bool dustStale;
    bool hasMassive;
    bool hasTracers;
    sc_render_massive massive;
    sc_render_tracers tracers;
    uint32_t stellarSamples;
    uint32_t starCount;
    uint32_t frameCount;
    uint32_t rampCount;
    sc_buffer *lightFixed;
    sc_buffer *dustFixed;
    sc_buffer *light;
    sc_buffer *dust;
    sc_buffer *columnFixed;
    sc_buffer *column;
    sc_buffer *carrierFixed;
    sc_buffer *carrier;
    sc_buffer *tags;
    sc_buffer *lace;
    sc_buffer *large;
    sc_buffer *largeCounter;
    sc_buffer *stellar;
    sc_buffer *stars;
    sc_buffer *frames;
    sc_buffer *ramps;
    sc_buffer *fallback;
};

namespace sillage {
namespace render {

constexpr uint32_t width = 256u;
// A galaxy index is at most 15 in a tracer's word: the frames and the ramps hold that many.
constexpr uint32_t galaxySlots = 16u;

#define LAUNCH(kernel, grid, block, ...)                                                      \
    do {                                                                                      \
        SILLAGE_LAUNCH(sh::kernel, dim3(grid), dim3(block), __VA_ARGS__);                     \
        if (sc_status launched = check(cudaGetLastError(), #kernel)) { return launched; }     \
    } while (0)

static uint32_t groups(size_t threads) { return uint32_t((threads + width - 1u) / width); }

static size_t pixels(const sc_renderer *renderer) {
    return size_t(renderer->config.width) * renderer->config.height;
}

static size_t cells(const sc_renderer *renderer) {
    return size_t(renderer->config.column_width) * renderer->config.column_height;
}

static size_t coarse(const sc_renderer *renderer) {
    return size_t(renderer->config.carrier_width) * renderer->config.carrier_height;
}

static bool webbed(const sc_renderer *renderer) { return coarse(renderer) > 0u && renderer->config.lace_texels > 0u; }

// Where each level of the lace starts, in texels, and the texels of them all.
static size_t laceTexels(uint32_t side, uint32_t levels) {
    size_t total = 0u;
    for (uint32_t level = 0u; level < levels; ++level) {
        size_t wide = side >> level;
        total += wide * wide;
    }
    return total;
}

static void releaseAll(sc_renderer *renderer) {
    for (sc_buffer **buffer :
         {&renderer->lightFixed, &renderer->dustFixed, &renderer->light, &renderer->dust, &renderer->columnFixed,
          &renderer->column, &renderer->carrierFixed, &renderer->carrier, &renderer->tags, &renderer->lace,
          &renderer->large, &renderer->largeCounter, &renderer->stellar, &renderer->stars, &renderer->frames,
          &renderer->ramps, &renderer->fallback}) {
        release(*buffer);
    }
}

static sc_status clear(sc_buffer *buffer) {
    return buffer ? check(cudaMemset(buffer->device, 0, buffer->length < 16u ? 16u : buffer->length), "cudaMemset")
                  : SC_OK;
}

static sc_status finish(const sc_buffer *fixed, sc_buffer *values, size_t count, float unit) {
    LAUNCH(finishFixed, groups(count), width, pointer<const sh::fixed_t>(fixed), pointer<float>(values), count, unit);
    return SC_OK;
}

static sh::Massive massive(const sc_renderer *renderer) {
    const sc_render_massive &m = renderer->massive;
    return sh::Massive{pointer<const metal::float3>(m.positions, m.positions_offset),
                       pointer<const float>(m.population),
                       pointer<const float>(m.formation),
                       pointer<const float>(m.luminosity),
                       pointer<const metal::uint>(m.component),
                       pointer<const metal::uint>(m.galaxy),
                       pointer<const float>(m.smoothing),
                       pointer<const metal::float2>(m.traits),
                       pointer<const float>(m.ramp_keys)};
}

static sh::Tracers tracers(const sc_renderer *renderer) {
    const sc_render_tracers &t = renderer->tracers;
    sh::Tracers bound;
    bound.states = pointer<const metal::float4>(t.states);
    bound.words = pointer<const metal::uint>(t.words);
    // Before there is a tree a tracer reads one spacing, as Metal's fallback buffer gives it.
    bound.cells = pointer<const metal::uint2>(t.cells ? t.cells : renderer->fallback);
    bound.treeFrame = pointer<const float>(t.cells && t.tree_frame ? t.tree_frame : renderer->fallback);
    bound.depth = t.cells ? t.depth : 0u;
    for (int galaxy = 0; galaxy < 16; ++galaxy) { bound.scales[galaxy] = t.scales[galaxy]; }
    return bound;
}

static sh::Targets targets(const sc_renderer *renderer) {
    return sh::Targets{pointer<sh::fixed_t>(renderer->lightFixed), pointer<sh::fixed_t>(renderer->dustFixed),
                       pointer<const metal::float4>(renderer->dust), renderer->config.width,
                       renderer->config.height};
}

static sh::CarrierTargets carrierTargets(const sc_renderer *renderer) {
    return sh::CarrierTargets{pointer<sh::fixed_t>(renderer->carrierFixed), pointer<metal::uint>(renderer->tags),
                              renderer->config.carrier_width, renderer->config.carrier_height};
}

// The splats of one pass, the first way or the second: its particles' threads, then a block
// for each splat they set aside.
template <class Point, class Vertices, class Blocks>
static sc_status draw(sc_renderer *renderer, Vertices vertices, Blocks blocks) {
    sh::Large none{nullptr, nullptr, 0u, 0u};
    if (renderer->largeThreshold == 0u || renderer->config.large_capacity == 0u) { return vertices(none); }
    std::lock_guard<std::mutex> held(renderer->largeLock);
    if (sc_status status = clear(renderer->largeCounter)) { return status; }
    sh::Large large{renderer->large->device, pointer<metal::uint>(renderer->largeCounter),
                    renderer->config.large_capacity, renderer->largeThreshold};
    if (sc_status status = vertices(large)) { return status; }
    uint32_t aside = 0u;
    if (sc_status status = check(cudaMemcpy(&aside, renderer->largeCounter->device, 4u, cudaMemcpyDeviceToHost),
                                 "reading the large splats' count")) {
        return status;
    }
    renderer->largeCount = aside;
    uint32_t held_back = aside < large.capacity ? aside : large.capacity;
    return held_back > 0u ? blocks(pointer<const Point>(renderer->large), held_back) : SC_OK;
}

static sc_status drawSplats(sc_renderer *renderer, const sh::Frame &frame, sc_render_pass pass, sh::Range some,
                            sh::Range traced) {
    sh::Targets onto = targets(renderer);
    uint32_t lay = pass == SC_RENDER_STARS ? sh::layLight : (pass == SC_RENDER_STARFIELD ? sh::layStarfield : sh::layDust);
    auto vertices = [&](sh::Large large) -> sc_status {
        if (pass == SC_RENDER_STARFIELD) {
            if (renderer->starCount > 0u) {
                LAUNCH(starfieldVertex, groups(renderer->starCount), width,
                       pointer<const sh::BackgroundStar>(renderer->stars), frame, sh::Range{0u, renderer->starCount},
                       onto, large);
            }
            return SC_OK;
        }
        if (some.count > 0u) {
            if (pass == SC_RENDER_PAINTED_DUST) {
                LAUNCH(dustWebVertex, groups(some.count), width, massive(renderer), frame, some, onto, large);
            } else {
                LAUNCH(splatVertex, groups(some.count), width, massive(renderer), frame, some, lay, onto, large);
            }
        }
        if (traced.count > 0u) {
            if (pass == SC_RENDER_PAINTED_DUST) {
                LAUNCH(dustWebTracerVertex, groups(traced.count), width, tracers(renderer), frame, traced, onto, large);
            } else {
                LAUNCH(splatTracerVertex, groups(traced.count), width, tracers(renderer), frame, traced, lay, onto,
                       large);
            }
        }
        return SC_OK;
    };
    auto blocks = [&](const sh::Splat *aside, uint32_t count) -> sc_status {
        LAUNCH(largeSplats, count, width, aside, count, lay, onto);
        return SC_OK;
    };
    return draw<sh::Splat>(renderer, vertices, blocks);
}

static sc_status drawCarriers(sc_renderer *renderer, const sh::Frame &frame, sh::Range some, sh::Range traced) {
    sh::CarrierTargets onto = carrierTargets(renderer);
    auto vertices = [&](sh::Large large) -> sc_status {
        if (some.count > 0u) {
            LAUNCH(webCarrierVertex, groups(some.count), width, massive(renderer), frame, some, onto, large);
        }
        if (traced.count > 0u) {
            LAUNCH(webCarrierTracerVertex, groups(traced.count), width, tracers(renderer), frame, traced, onto, large);
        }
        return SC_OK;
    };
    auto blocks = [&](const sh::WebCarrier *aside, uint32_t count) -> sc_status {
        LAUNCH(largeCarriers, count, width, aside, count, onto);
        return SC_OK;
    };
    return draw<sh::WebCarrier>(renderer, vertices, blocks);
}

static sc_status drawPass(sc_renderer *renderer, const sh::Frame &frame, sc_render_pass pass, sh::Range some,
                          sh::Range traced) {
    const sc_render_config &config = renderer->config;
    switch (pass) {
        case SC_RENDER_COLUMN: {
            auto into = pointer<sh::fixed_t>(renderer->columnFixed);
            if (some.count > 0u) {
                LAUNCH(countVertex, groups(some.count), width, massive(renderer), frame, some, into,
                       config.column_width, config.column_height);
            }
            if (traced.count > 0u) {
                LAUNCH(countTracerVertex, groups(traced.count), width, tracers(renderer), frame, traced, into,
                       config.column_width, config.column_height);
            }
            return SC_OK;
        }
        case SC_RENDER_WEB_CARRIER: return drawCarriers(renderer, frame, some, traced);
        case SC_RENDER_STARFIELD:
        case SC_RENDER_DUST:
        case SC_RENDER_PAINTED_DUST:
        case SC_RENDER_STARS: return drawSplats(renderer, frame, pass, some, traced);
        case SC_RENDER_WEB_RESOLVE: {
            auto lace = metal::texels2d_of(pointer<const float>(renderer->lace), config.lace_texels,
                                           config.lace_texels, 1u, renderer->laceLevels);
            auto carried = metal::texels2d_of(pointer<const float>(renderer->carrier), config.carrier_width,
                                              config.carrier_height, 4u);
            auto tagged = metal::texels2d_of(pointer<const float>(renderer->tags), config.carrier_width,
                                             config.carrier_height, 4u);
            LAUNCH(webResolveFragment, groups(pixels(renderer)), width, frame, lace, carried, tagged,
                   pointer<sh::fixed_t>(renderer->dustFixed), config.width, config.height);
            return SC_OK;
        }
        case SC_RENDER_PLAIN: {
            auto light = pointer<sh::fixed_t>(renderer->lightFixed);
            if (some.count > 0u) {
                LAUNCH(plainVertex, groups(some.count), width, massive(renderer), frame, some, light, config.width,
                       config.height);
            }
            if (traced.count > 0u) {
                LAUNCH(plainTracerVertex, groups(traced.count), width, tracers(renderer), frame, traced, light,
                       config.width, config.height);
            }
            return SC_OK;
        }
    }
    return fail(SC_INVALID_ARGUMENT, "no render pass %d", int(pass));
}

static bool known(sc_render_pass pass) { return pass >= SC_RENDER_COLUMN && pass <= SC_RENDER_PLAIN; }

static bool needsWeb(sc_render_pass pass) {
    return pass == SC_RENDER_WEB_CARRIER || pass == SC_RENDER_PAINTED_DUST || pass == SC_RENDER_WEB_RESOLVE;
}

static bool drawsDust(sc_render_pass pass) {
    return pass == SC_RENDER_DUST || pass == SC_RENDER_PAINTED_DUST || pass == SC_RENDER_WEB_RESOLVE
        || pass == SC_RENDER_STARS;
}

}  // namespace render
}  // namespace sillage

using namespace sillage;
using namespace sillage::render;

extern "C" {

sc_status sc_renderer_create(sc_context *context, const sc_render_config *config, sc_renderer **made) {
    if (!config || !made) {
        return fail(SC_INVALID_ARGUMENT, "sc_renderer_create: no config or no renderer to write");
    }
    *made = nullptr;
    if (config->width == 0u || config->height == 0u) {
        return fail(SC_INVALID_ARGUMENT, "sc_renderer_create: a frame of %u by %u pixels", config->width,
                    config->height);
    }
    uint32_t side = config->lace_texels;
    if (side != 0u && ((side & (side - 1u)) != 0u || side > 32768u)) {
        return fail(SC_INVALID_ARGUMENT, "sc_renderer_create: a lace of %u texels a side, not a power of two", side);
    }
    sc_renderer *renderer = new (std::nothrow) sc_renderer();
    if (!renderer) { return fail(SC_OUT_OF_MEMORY, "no host memory for a renderer"); }
    renderer->context = context;
    renderer->config = *config;
    if (renderer->config.column_width == 0u || renderer->config.column_height == 0u) {
        renderer->config.column_width = 1u;
        renderer->config.column_height = 1u;
    }
    if (side == 0u || coarse(renderer) == 0u) {
        renderer->config.lace_texels = 0u;
        renderer->config.carrier_width = 0u;
        renderer->config.carrier_height = 0u;
    }
    side = renderer->config.lace_texels;
    for (uint32_t wide = side; wide > 0u; wide >>= 1) { renderer->laceLevels += 1u; }

    size_t frame = pixels(renderer);
    size_t carried = coarse(renderer);
    size_t aside = renderer->config.large_capacity;
    size_t entry = sizeof(sh::Splat) > sizeof(sh::WebCarrier) ? sizeof(sh::Splat) : sizeof(sh::WebCarrier);
    struct Wanted {
        sc_buffer **buffer;
        size_t length;
    };
    sc_status status = SC_OK;
    for (const Wanted &wanted : {
             Wanted{&renderer->lightFixed, frame * 32u},
             Wanted{&renderer->dustFixed, frame * 32u},
             Wanted{&renderer->light, frame * 16u},
             Wanted{&renderer->dust, frame * 16u},
             Wanted{&renderer->columnFixed, cells(renderer) * 8u},
             Wanted{&renderer->column, cells(renderer) * 4u},
             Wanted{&renderer->carrierFixed, carried * 32u},
             Wanted{&renderer->carrier, carried * 16u},
             Wanted{&renderer->tags, carried * 16u},
             Wanted{&renderer->lace, laceTexels(side, renderer->laceLevels) * 4u},
             Wanted{&renderer->large, aside * entry},
             Wanted{&renderer->largeCounter, 4u},
             Wanted{&renderer->frames, galaxySlots * sizeof(sh::DiskFrame)},
             Wanted{&renderer->ramps, galaxySlots * sizeof(sh::GalaxyRamp)},
             Wanted{&renderer->stellar, 16u},
             Wanted{&renderer->fallback, 16u},
         }) {
        *wanted.buffer = allocate(context, wanted.length, &status);
        if (status != SC_OK) {
            releaseAll(renderer);
            delete renderer;
            return status;
        }
    }
    // The spacing a tracer is drawn with before there is a tree to read one off.
    float spacing = 0.05f;
    status = check(cudaMemcpy(renderer->fallback->device, &spacing, 4u, cudaMemcpyHostToDevice), "cudaMemcpy");
    if (status != SC_OK) {
        releaseAll(renderer);
        delete renderer;
        return status;
    }
    renderer->dustStale = true;
    *made = renderer;
    return SC_OK;
}

void sc_renderer_destroy(sc_renderer *renderer) {
    if (!renderer) { return; }
    releaseAll(renderer);
    delete renderer;
}

// A small table the renderer keeps a copy of on the device.
static sc_status keep(sc_renderer *renderer, sc_buffer **buffer, const void *bytes, size_t length, size_t least) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (!bytes && length > 0u) { return fail(SC_INVALID_ARGUMENT, "no bytes to keep"); }
    size_t room = length > least ? length : least;
    if (!*buffer || (*buffer)->length < room) {
        sc_status status = SC_OK;
        sc_buffer *grown = allocate(renderer->context, room, &status);
        if (status != SC_OK) { return status; }
        release(*buffer);
        *buffer = grown;
    }
    if (sc_status status = use(renderer->context)) { return status; }
    if (sc_status status = clear(*buffer)) { return status; }
    return length > 0u
        ? check(cudaMemcpy((*buffer)->device, bytes, length, cudaMemcpyHostToDevice), "cudaMemcpy") : SC_OK;
}

sc_status sc_render_set_stellar(sc_renderer *renderer, const float *table, uint32_t samples) {
    if (sc_status status = keep(renderer, &renderer->stellar, table, size_t(samples) * 8u, 16u)) { return status; }
    renderer->stellarSamples = samples;
    return SC_OK;
}

sc_status sc_render_set_starfield(sc_renderer *renderer, const void *stars, uint32_t count) {
    if (sc_status status =
            keep(renderer, &renderer->stars, stars, size_t(count) * sizeof(sh::BackgroundStar), 32u)) {
        return status;
    }
    renderer->starCount = count;
    return SC_OK;
}

sc_status sc_render_bake_lace(sc_renderer *renderer, float *mean) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (!webbed(renderer)) { return fail(SC_INVALID_ARGUMENT, "this renderer was made without the dust web"); }
    if (sc_status status = use(renderer->context)) { return status; }
    if (!renderer->baked) {
        uint32_t side = renderer->config.lace_texels;
        auto lace = pointer<float>(renderer->lace);
        LAUNCH(bakeLace, groups(size_t(side) * side), width, lace, side);
        uint32_t from = 0u;
        for (uint32_t level = 1u; level < renderer->laceLevels; ++level) {
            uint32_t above = side >> (level - 1u);
            uint32_t to = from + above * above;
            uint32_t wide = side >> level;
            LAUNCH(laceLevel, groups(size_t(wide) * wide), width, lace, from, to, wide);
            from = to;
        }
        // The last level is one texel, the mean of the whole tile.
        if (sc_status status = check(cudaMemcpy(&renderer->laceMean, lace + from, 4u, cudaMemcpyDeviceToHost),
                                     "reading the lace's mean")) {
            return status;
        }
        renderer->baked = true;
    }
    if (mean) { *mean = renderer->laceMean; }
    return SC_OK;
}

sc_status sc_render_set_large(sc_renderer *renderer, uint32_t threshold) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (threshold > 0u && renderer->config.large_capacity == 0u) {
        return fail(SC_INVALID_ARGUMENT, "this renderer was made with no room for large splats");
    }
    renderer->largeThreshold = threshold;
    return SC_OK;
}

sc_status sc_render_set_particles(sc_renderer *renderer, const sc_render_massive *massive,
                                  const sc_render_tracers *tracers) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (massive) {
        size_t count = massive->count;
        struct Held {
            const sc_buffer *buffer;
            size_t offset;
            size_t stride;
            const char *name;
        };
        for (const Held &held : {
                 Held{massive->positions, massive->positions_offset, 16u, "positions"},
                 Held{massive->population, 0u, 4u, "populations"},
                 Held{massive->formation, 0u, 4u, "formation times"},
                 Held{massive->luminosity, 0u, 4u, "luminosities"},
                 Held{massive->component, 0u, 4u, "components"},
                 Held{massive->galaxy, 0u, 4u, "galaxies"},
                 Held{massive->smoothing, 0u, 4u, "smoothing lengths"},
                 Held{massive->traits, 0u, 8u, "traits"},
                 Held{massive->ramp_keys, 0u, 4u, "ramp keys"},
             }) {
            if (!holds(held.buffer, held.offset, count * held.stride)) {
                return fail(SC_INVALID_ARGUMENT, "the %s do not hold %zu values of %zu bytes", held.name, count,
                            held.stride);
            }
        }
        renderer->massive = *massive;
    }
    if (tracers) {
        size_t count = tracers->count;
        if (!holds(tracers->states, 0u, count * 16u) || !holds(tracers->words, 0u, count * 16u)) {
            return fail(SC_INVALID_ARGUMENT, "the tracers' buffers do not hold %zu states and words", count);
        }
        if (tracers->cells && (!holds(tracers->cells, 0u, 8u) || !holds(tracers->tree_frame, 0u, 16u))) {
            return fail(SC_INVALID_ARGUMENT, "the tracers' spacing records or their frame are empty");
        }
        renderer->tracers = *tracers;
    }
    renderer->hasMassive = massive != nullptr;
    renderer->hasTracers = tracers != nullptr;
    return SC_OK;
}

sc_status sc_render_set_frame(sc_renderer *renderer, const void *disk_frames, uint32_t frame_count,
                              const void *ramps, uint32_t ramp_count) {
    if (sc_status status = keep(renderer, &renderer->frames, disk_frames, size_t(frame_count) * sizeof(sh::DiskFrame),
                                galaxySlots * sizeof(sh::DiskFrame))) {
        return status;
    }
    if (sc_status status = keep(renderer, &renderer->ramps, ramps, size_t(ramp_count) * sizeof(sh::GalaxyRamp),
                                galaxySlots * sizeof(sh::GalaxyRamp))) {
        return status;
    }
    renderer->frameCount = frame_count;
    renderer->rampCount = ramp_count;
    return SC_OK;
}

sc_status sc_render_clear(sc_renderer *renderer) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (sc_status status = use(renderer->context)) { return status; }
    if (sc_status status = clear(renderer->lightFixed)) { return status; }
    if (sc_status status = clear(renderer->dustFixed)) { return status; }
    renderer->dustStale = true;
    return SC_OK;
}

sc_status sc_render_begin(sc_renderer *renderer, sc_render_pass pass) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (!known(pass)) { return fail(SC_INVALID_ARGUMENT, "no render pass %d", int(pass)); }
    if (needsWeb(pass) && (!webbed(renderer) || !renderer->baked)) {
        return fail(SC_INVALID_ARGUMENT, "a pass of the dust web on a renderer without its lace baked");
    }
    if (sc_status status = use(renderer->context)) { return status; }
    switch (pass) {
        case SC_RENDER_COLUMN:
            renderer->columnStale = true;
            return clear(renderer->columnFixed);
        case SC_RENDER_WEB_CARRIER:
            renderer->carrierStale = true;
            if (sc_status status = clear(renderer->carrierFixed)) { return status; }
            return clear(renderer->tags);
        case SC_RENDER_STARFIELD:
        case SC_RENDER_PLAIN: return SC_OK;
        case SC_RENDER_DUST:
        case SC_RENDER_PAINTED_DUST:
        case SC_RENDER_WEB_RESOLVE:
        case SC_RENDER_STARS: break;
    }
    // A splat sizes its kernel from the column's cells, the resolve reads the carrier, and a
    // star reads the finished dust.
    if (renderer->columnStale && pass != SC_RENDER_WEB_RESOLVE) {
        if (sc_status status = finish(renderer->columnFixed, renderer->column, cells(renderer), sh::countUnit)) {
            return status;
        }
        renderer->columnStale = false;
    }
    if (renderer->carrierStale && pass == SC_RENDER_WEB_RESOLVE) {
        if (sc_status status =
                finish(renderer->carrierFixed, renderer->carrier, coarse(renderer) * 4u, sh::fixedUnit)) {
            return status;
        }
        renderer->carrierStale = false;
    }
    if (pass != SC_RENDER_STARS) {
        renderer->dustStale = true;
        return SC_OK;
    }
    if (renderer->dustStale) {
        if (sc_status status = finish(renderer->dustFixed, renderer->dust, pixels(renderer) * 4u, sh::fixedUnit)) {
            return status;
        }
        renderer->dustStale = false;
    }
    return SC_OK;
}

sc_status sc_render_draw(sc_renderer *renderer, sc_render_pass pass, const void *splat_uniforms,
                         size_t splat_length, const void *web_uniforms, size_t web_length,
                         uint32_t massive_first, uint32_t massive_count, uint32_t tracer_first,
                         uint32_t tracer_count) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (!known(pass)) { return fail(SC_INVALID_ARGUMENT, "no render pass %d", int(pass)); }
    if (!splat_uniforms || splat_length != sizeof(sh::SplatUniforms)) {
        return fail(SC_INVALID_ARGUMENT, "SplatUniforms is %zu bytes in the MSL, and %zu were given",
                    sizeof(sh::SplatUniforms), splat_length);
    }
    sh::Frame frame;
    memcpy(&frame.u, splat_uniforms, sizeof frame.u);
    memset(&frame.w, 0, sizeof frame.w);
    if (needsWeb(pass)) {
        if (!web_uniforms || web_length != sizeof(sh::WebUniforms)) {
            return fail(SC_INVALID_ARGUMENT, "WebUniforms is %zu bytes in the MSL, and %zu were given",
                        sizeof(sh::WebUniforms), web_length);
        }
        if (!webbed(renderer) || !renderer->baked) {
            return fail(SC_INVALID_ARGUMENT, "a pass of the dust web on a renderer without its lace baked");
        }
        memcpy(&frame.w, web_uniforms, sizeof frame.w);
    }
    bool particles = pass != SC_RENDER_STARFIELD && pass != SC_RENDER_WEB_RESOLVE;
    if (particles && massive_count > 0u
        && (!renderer->hasMassive || massive_first > renderer->massive.count
            || massive_count > renderer->massive.count - massive_first)) {
        return fail(SC_INVALID_ARGUMENT, "no massive particles from %u to %u", massive_first,
                    massive_first + massive_count);
    }
    if (particles && tracer_count > 0u
        && (!renderer->hasTracers || tracer_first > renderer->tracers.count
            || tracer_count > renderer->tracers.count - tracer_first)) {
        return fail(SC_INVALID_ARGUMENT, "no light tracers from %u to %u", tracer_first,
                    tracer_first + tracer_count);
    }
    if (drawsDust(pass) && !renderer->dustFixed->length) {
        return fail(SC_INVALID_ARGUMENT, "a pass of the splat on a renderer without its dust");
    }
    if (sc_status status = use(renderer->context)) { return status; }
    frame.frames = pointer<const sh::DiskFrame>(renderer->frames);
    frame.ramps = pointer<const sh::GalaxyRamp>(renderer->ramps);
    frame.stellar = pointer<const metal::float2>(renderer->stellar);
    frame.column = metal::texels2d_of(pointer<const float>(renderer->column), renderer->config.column_width,
                                      renderer->config.column_height, 1u);
    return drawPass(renderer, frame, pass, sh::Range{massive_first, massive_count},
                    sh::Range{tracer_first, tracer_count});
}

sc_status sc_render_finish(sc_renderer *renderer) {
    if (!renderer) { return fail(SC_INVALID_ARGUMENT, "no renderer"); }
    if (sc_status status = use(renderer->context)) { return status; }
    if (renderer->dustStale) {
        if (sc_status status = finish(renderer->dustFixed, renderer->dust, pixels(renderer) * 4u, sh::fixedUnit)) {
            return status;
        }
        renderer->dustStale = false;
    }
    if (renderer->columnStale) {
        if (sc_status status = finish(renderer->columnFixed, renderer->column, cells(renderer), sh::countUnit)) {
            return status;
        }
        renderer->columnStale = false;
    }
    if (renderer->carrierStale) {
        if (sc_status status =
                finish(renderer->carrierFixed, renderer->carrier, coarse(renderer) * 4u, sh::fixedUnit)) {
            return status;
        }
        renderer->carrierStale = false;
    }
    return finish(renderer->lightFixed, renderer->light, pixels(renderer) * 4u, sh::fixedUnit);
}

sc_buffer *sc_render_target_of(sc_renderer *renderer, sc_render_target which) {
    if (!renderer) { return nullptr; }
    switch (which) {
        case SC_RENDER_LIGHT: return renderer->light;
        case SC_RENDER_DUST_TARGET: return renderer->dust;
        case SC_RENDER_COLUMN_TARGET: return renderer->column;
        case SC_RENDER_CARRIER: return webbed(renderer) ? renderer->carrier : nullptr;
        case SC_RENDER_TAGS: return webbed(renderer) ? renderer->tags : nullptr;
        case SC_RENDER_LACE: return webbed(renderer) ? renderer->lace : nullptr;
        case SC_RENDER_LIGHT_FIXED: return renderer->lightFixed;
        case SC_RENDER_DUST_FIXED: return renderer->dustFixed;
    }
    return nullptr;
}

uint64_t sc_render_fixed_unit(void) { return uint64_t(sh::fixedUnit); }

uint32_t sc_render_large_count(const sc_renderer *renderer) { return renderer ? renderer->largeCount : 0u; }

}  // extern "C"
