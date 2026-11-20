// The fixed point the renderers accumulate their light in (#276), shared by the galaxies' passes
// and the black hole's splats (#336). Included after cuda_cpu.h.
#ifndef SILLAGE_FIXED_H
#define SILLAGE_FIXED_H

#include "msl_compat.h"

namespace metal {
namespace fixedpoint {

typedef unsigned long long fixed_t;

// One unit of light or dust in a fixed point target, 2^40: a pixel holds up to 2^24, which is
// 256 times what Metal's half float target holds, in steps of 9e-13, and the largest pixel
// measured so far is in docs/notes/cuda-engine.md.
constexpr float fixedUnit = 1099511627776.0f;
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

}  // namespace fixedpoint
}  // namespace metal

#endif
