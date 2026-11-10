// A first, minimal Metal Shading Language layer over CUDA C++ (#271).
// Included by `#include <metal_stdlib>` at the top of the MSL text, through ./metal_stdlib.
// Under nvcc the MSL compiles as device code; with a host compiler, cuda_cpu.h comes first
// and turns the CUDA qualifiers into plain C++.
#pragma once

#include <cstdint>
#include <cstring>
#include <math.h>

#ifdef __CUDACC__
// CUDA spells its qualifiers as __attribute__((device)) and __attribute__((constant)), which
// the MSL address space macros below would empty. The double underscore form survives them.
#undef __device__
#define __device__ __attribute__((__device__))
#undef __constant__
#define __constant__ __attribute__((__constant__))
#endif

#define MSL_FN __host__ __device__ __forceinline__

typedef unsigned int uint;
typedef unsigned long ulong;
static_assert(sizeof(ulong) == 8, "MSL's ulong is 64 bits");

namespace metal {

struct msl_bool3 {
    bool x, y, z;
};

struct alignas(16) msl_float3 {
    float x, y, z;
    msl_float3() = default;
    MSL_FN explicit msl_float3(float s) : x(s), y(s), z(s) {}
    MSL_FN msl_float3(float x, float y, float z) : x(x), y(y), z(z) {}
};

struct alignas(16) msl_uint3 {
    uint x, y, z;
    msl_uint3() = default;
    MSL_FN explicit msl_uint3(uint s) : x(s), y(s), z(s) {}
    MSL_FN msl_uint3(uint x, uint y, uint z) : x(x), y(y), z(z) {}
};

// `.xyz` of a four component vector, read as the three component one. Writing through it keeps
// w; assigning one swizzle to another copies w too, which MSL does not (not used by the walk).
template <class V, class S>
struct swizzle_xyz {
    S e[4];
    MSL_FN operator V() const { return V(e[0], e[1], e[2]); }
    MSL_FN swizzle_xyz &operator=(const V &v) {
        e[0] = v.x;
        e[1] = v.y;
        e[2] = v.z;
        return *this;
    }
    MSL_FN swizzle_xyz &operator+=(const V &v) { return *this = V(*this) + v; }
    MSL_FN swizzle_xyz &operator-=(const V &v) { return *this = V(*this) - v; }
};

struct alignas(16) msl_float4 {
    union {
        struct {
            float x, y, z, w;
        };
        swizzle_xyz<msl_float3, float> xyz;
    };
    msl_float4() = default;
    MSL_FN explicit msl_float4(float s) { x = y = z = w = s; }
    MSL_FN msl_float4(float a, float b, float c, float d) { x = a, y = b, z = c, w = d; }
    MSL_FN msl_float4(msl_float3 v, float d) { x = v.x, y = v.y, z = v.z, w = d; }
};

struct alignas(16) msl_uint4 {
    union {
        struct {
            uint x, y, z, w;
        };
        swizzle_xyz<msl_uint3, uint> xyz;
    };
    msl_uint4() = default;
    MSL_FN msl_uint4(uint a, uint b, uint c, uint d) { x = a, y = b, z = c, w = d; }
    MSL_FN msl_uint4(msl_uint3 v, uint d) { x = v.x, y = v.y, z = v.z, w = d; }
};

static_assert(sizeof(msl_float3) == 16 && alignof(msl_float3) == 16, "MSL's float3 is 16 bytes");
static_assert(sizeof(msl_uint3) == 16 && sizeof(msl_float4) == 16 && sizeof(msl_uint4) == 16, "");

typedef msl_float3 v3;
MSL_FN v3 operator+(v3 a, v3 b) { return v3(a.x + b.x, a.y + b.y, a.z + b.z); }
MSL_FN v3 operator-(v3 a, v3 b) { return v3(a.x - b.x, a.y - b.y, a.z - b.z); }
MSL_FN v3 operator*(v3 a, v3 b) { return v3(a.x * b.x, a.y * b.y, a.z * b.z); }
MSL_FN v3 operator-(v3 a) { return v3(-a.x, -a.y, -a.z); }
MSL_FN v3 operator*(v3 a, float s) { return v3(a.x * s, a.y * s, a.z * s); }
MSL_FN v3 operator*(float s, v3 a) { return v3(s * a.x, s * a.y, s * a.z); }
MSL_FN v3 operator/(v3 a, float s) { return v3(a.x / s, a.y / s, a.z / s); }
MSL_FN v3 &operator+=(v3 &a, v3 b) { return a = a + b; }
MSL_FN v3 &operator-=(v3 &a, v3 b) { return a = a - b; }
MSL_FN v3 &operator*=(v3 &a, float s) { return a = a * s; }
MSL_FN msl_bool3 operator>=(v3 a, float s) { return {a.x >= s, a.y >= s, a.z >= s}; }
MSL_FN msl_bool3 operator<=(v3 a, float s) { return {a.x <= s, a.y <= s, a.z <= s}; }

MSL_FN bool all(msl_bool3 b) { return b.x && b.y && b.z; }
MSL_FN float dot(msl_float3 a, msl_float3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
MSL_FN float length(msl_float3 a) { return sqrtf(dot(a, a)); }
MSL_FN msl_float3 cross(msl_float3 a, msl_float3 b) {
    return msl_float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}
MSL_FN float clamp(float x, float lo, float hi) { return fminf(fmaxf(x, lo), hi); }
MSL_FN msl_float3 clamp(msl_float3 v, float lo, float hi) {
    return msl_float3(clamp(v.x, lo, hi), clamp(v.y, lo, hi), clamp(v.z, lo, hi));
}
MSL_FN float smoothstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}

template <class T, class U>
MSL_FN T as_type(const U &u) {
    static_assert(sizeof(T) == sizeof(U), "as_type needs types of one size");
    T t;
    memcpy(&t, &u, sizeof(T));
    return t;
}
template <class T, class V, class S>
MSL_FN T as_type(const swizzle_xyz<V, S> &s) {
    return as_type<T>(V(s));
}

}  // namespace metal

// CUDA declares float3, float4, uint3 and uint4 of its own, with a 12 byte float3. Other names
// inside `metal`, so the MSL's `using namespace metal;` clashes with nothing CUDA declares.
#define bool3 metal::msl_bool3
#define float3 metal::msl_float3
#define float4 metal::msl_float4
#define uint3 metal::msl_uint3
#define uint4 metal::msl_uint4

// Address spaces. `constant` keeps its meaning at program scope (a function constant becomes a
// __constant__ variable the host sets) and is ignored on a parameter.
#define device
#define constant __constant__
#define thread
#define kernel static
// The MSL text's helpers are `static` or `inline`; under nvcc they have to be device functions.
#define static static __device__
#define inline __device__ inline
