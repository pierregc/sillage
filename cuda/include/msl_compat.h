// Metal Shading Language over CUDA C++ and plain C++17 (#281).
//
// The shared MSL of a library (everything outside `#if defined(__METAL_VERSION__)`) compiles
// through this header: with nvcc as device code, with a host compiler as plain C++. A library's
// text is included inside `namespace metal`, between msl_begin.h and msl_end.h, as
// scripts/kernel-sources.sh writes it: there `float3`, `min` or `sqrt` are the ones below, not
// CUDA's or the C library's. See docs/notes/one-kernel-source.md.
#ifndef SILLAGE_MSL_COMPAT_H
#define SILLAGE_MSL_COMPAT_H

#include <cfloat>
#include <cmath>
#include <cstdint>
#include <cstring>

#if defined(__CUDACC__)
#define MSL_API __host__ __device__ __forceinline__
#define MSL_DEVICE __device__ __forceinline__
#else
#define MSL_API inline
#define MSL_DEVICE inline
#endif

#define M_PI_F 3.14159265358979323846f
#define M_PI_2_F 1.57079632679489661923f
#define M_PI_4_F 0.78539816339744830962f
#define M_1_PI_F 0.31830988618379067154f
#define M_2_PI_F 0.63661977236758134308f
#define M_SQRT2_F 1.41421356237309504880f
#define M_E_F 2.71828182845904523536f

namespace metal {

typedef unsigned char uchar;
typedef unsigned short ushort;
typedef unsigned int uint;
typedef unsigned long ulong;
// Metal computes these in fp16; CUDA and the CPU compute them in fp32.
typedef float half;
static_assert(sizeof(ulong) == 8 && sizeof(long) == 8, "MSL's long and ulong are 64 bits");

template <class T> struct vec2;
template <class T> struct vec3;
template <class T> struct vec4;

// A swizzle laid over the first N components of a vector: reads as the N component vector V,
// writes those components only.
template <class V, class S, int N>
struct swizzle {
    S e[N];
    MSL_API operator V() const {
        V v;
        for (int i = 0; i < N; ++i) { (&v.x)[i] = e[i]; }
        return v;
    }
    MSL_API swizzle &operator=(const V &v) {
        for (int i = 0; i < N; ++i) { e[i] = (&v.x)[i]; }
        return *this;
    }
    MSL_API swizzle &operator+=(const V &v) { return *this = V(*this) + v; }
    MSL_API swizzle &operator-=(const V &v) { return *this = V(*this) - v; }
    MSL_API swizzle &operator*=(const V &v) { return *this = V(*this) * v; }
    MSL_API swizzle &operator/=(const V &v) { return *this = V(*this) / v; }
    MSL_API swizzle &operator*=(S s) { return *this = V(*this) * s; }
    MSL_API swizzle &operator/=(S s) { return *this = V(*this) / s; }
};

// The layout of a Metal buffer: a two component vector is 2 scalars, a three or four component
// one is 4, aligned to its size.
template <class T>
struct alignas(sizeof(T) * 2) vec2 {
    union {
        struct { T x, y; };
        struct { T r, g; };
        swizzle<vec2<T>, T, 2> xy;
    };
    vec2() = default;
    MSL_API constexpr explicit vec2(T s) : x(s), y(s) {}
    MSL_API constexpr vec2(T a, T b) : x(a), y(b) {}
    template <class U>
    MSL_API constexpr explicit vec2(const vec2<U> &v) : x(T(v.x)), y(T(v.y)) {}
    MSL_API T &operator[](int i) { return (&x)[i]; }
    MSL_API const T &operator[](int i) const { return (&x)[i]; }
};

template <class T>
struct alignas(sizeof(T) * 4) vec3 {
    union {
        struct { T x, y, z; };
        struct { T r, g, b; };
        swizzle<vec2<T>, T, 2> xy;
        swizzle<vec3<T>, T, 3> xyz;
        swizzle<vec3<T>, T, 3> rgb;
    };
    vec3() = default;
    MSL_API constexpr explicit vec3(T s) : x(s), y(s), z(s) {}
    MSL_API constexpr vec3(T a, T b, T c) : x(a), y(b), z(c) {}
    MSL_API constexpr vec3(const vec2<T> &v, T c) : x(v.x), y(v.y), z(c) {}
    MSL_API constexpr vec3(T a, const vec2<T> &v) : x(a), y(v.x), z(v.y) {}
    template <class U>
    MSL_API constexpr explicit vec3(const vec3<U> &v) : x(T(v.x)), y(T(v.y)), z(T(v.z)) {}
    MSL_API T &operator[](int i) { return (&x)[i]; }
    MSL_API const T &operator[](int i) const { return (&x)[i]; }
};

template <class T>
struct alignas(sizeof(T) * 4) vec4 {
    union {
        struct { T x, y, z, w; };
        struct { T r, g, b, a; };
        swizzle<vec2<T>, T, 2> xy;
        swizzle<vec3<T>, T, 3> xyz;
        swizzle<vec3<T>, T, 3> rgb;
    };
    vec4() = default;
    MSL_API constexpr explicit vec4(T s) : x(s), y(s), z(s), w(s) {}
    MSL_API constexpr vec4(T a, T b, T c, T d) : x(a), y(b), z(c), w(d) {}
    MSL_API constexpr vec4(const vec3<T> &v, T d) : x(v.x), y(v.y), z(v.z), w(d) {}
    MSL_API constexpr vec4(T a, const vec3<T> &v) : x(a), y(v.x), z(v.y), w(v.z) {}
    MSL_API constexpr vec4(const vec2<T> &u, const vec2<T> &v) : x(u.x), y(u.y), z(v.x), w(v.y) {}
    MSL_API constexpr vec4(const vec2<T> &v, T c, T d) : x(v.x), y(v.y), z(c), w(d) {}
    template <class U>
    MSL_API constexpr explicit vec4(const vec4<U> &v)
        : x(T(v.x)), y(T(v.y)), z(T(v.z)), w(T(v.w)) {}
    MSL_API T &operator[](int i) { return (&x)[i]; }
    MSL_API const T &operator[](int i) const { return (&x)[i]; }
};

typedef vec2<float> float2;
typedef vec3<float> float3;
typedef vec4<float> float4;
typedef vec2<int> int2;
typedef vec3<int> int3;
typedef vec4<int> int4;
typedef vec2<uint> uint2;
typedef vec3<uint> uint3;
typedef vec4<uint> uint4;
typedef vec2<bool> bool2;
typedef vec3<bool> bool3;
typedef vec4<bool> bool4;
typedef float2 half2;
typedef float3 half3;
typedef float4 half4;

static_assert(sizeof(float2) == 8 && alignof(float2) == 8, "MSL's float2 is 8 bytes");
static_assert(sizeof(float3) == 16 && alignof(float3) == 16, "MSL's float3 is 16 bytes");
static_assert(sizeof(float4) == 16 && alignof(float4) == 16, "MSL's float4 is 16 bytes");
static_assert(sizeof(uint2) == 8 && sizeof(uint3) == 16 && sizeof(uint4) == 16, "");
static_assert(sizeof(int2) == 8 && sizeof(int3) == 16 && sizeof(int4) == 16, "");

// 12 bytes, for a buffer that packs its float3.
struct packed_float3 {
    float x, y, z;
    packed_float3() = default;
    MSL_API constexpr packed_float3(float a, float b, float c) : x(a), y(b), z(c) {}
    MSL_API constexpr packed_float3(const float3 &v) : x(v.x), y(v.y), z(v.z) {}
    MSL_API constexpr operator float3() const { return float3(x, y, z); }
};
static_assert(sizeof(packed_float3) == 12 && alignof(packed_float3) == 4, "");

// Operators are plain functions on the named types, not templates, so that a swizzle converts
// to its vector on either side of one.
#define MSL_MAP2(V, a, f) V(f(a.x), f(a.y))
#define MSL_MAP3(V, a, f) V(f(a.x), f(a.y), f(a.z))
#define MSL_MAP4(V, a, f) V(f(a.x), f(a.y), f(a.z), f(a.w))
#define MSL_ZIP2(V, a, op, b) V(a.x op b.x, a.y op b.y)
#define MSL_ZIP3(V, a, op, b) V(a.x op b.x, a.y op b.y, a.z op b.z)
#define MSL_ZIP4(V, a, op, b) V(a.x op b.x, a.y op b.y, a.z op b.z, a.w op b.w)
#define MSL_LEFT2(V, a, op, s) V(a.x op s, a.y op s)
#define MSL_LEFT3(V, a, op, s) V(a.x op s, a.y op s, a.z op s)
#define MSL_LEFT4(V, a, op, s) V(a.x op s, a.y op s, a.z op s, a.w op s)
#define MSL_RIGHT2(V, s, op, a) V(s op a.x, s op a.y)
#define MSL_RIGHT3(V, s, op, a) V(s op a.x, s op a.y, s op a.z)
#define MSL_RIGHT4(V, s, op, a) V(s op a.x, s op a.y, s op a.z, s op a.w)

#define MSL_BINARY(N, V, T, R, op)                                                    \
    MSL_API constexpr R operator op(const V &a, const V &b) { return MSL_ZIP##N(R, a, op, b); } \
    MSL_API constexpr R operator op(const V &a, T s) { return MSL_LEFT##N(R, a, op, s); }       \
    MSL_API constexpr R operator op(T s, const V &a) { return MSL_RIGHT##N(R, s, op, a); }
#define MSL_ASSIGN(V, T, op)                                                \
    MSL_API V &operator op##=(V &a, const V &b) { return a = a op b; } \
    MSL_API V &operator op##=(V &a, T s) { return a = a op s; }

#define MSL_ARITHMETIC(N, V, T, B)     \
    MSL_BINARY(N, V, T, V, +)          \
    MSL_BINARY(N, V, T, V, -)          \
    MSL_BINARY(N, V, T, V, *)          \
    MSL_BINARY(N, V, T, V, /)          \
    MSL_ASSIGN(V, T, +)                \
    MSL_ASSIGN(V, T, -)                \
    MSL_ASSIGN(V, T, *)                \
    MSL_ASSIGN(V, T, /)                \
    MSL_BINARY(N, V, T, B, <)          \
    MSL_BINARY(N, V, T, B, <=)         \
    MSL_BINARY(N, V, T, B, >)          \
    MSL_BINARY(N, V, T, B, >=)         \
    MSL_BINARY(N, V, T, B, ==)         \
    MSL_BINARY(N, V, T, B, !=)

#define MSL_INTEGER(N, V, T)                                                     \
    MSL_BINARY(N, V, T, V, %)                                                    \
    MSL_BINARY(N, V, T, V, &)                                                    \
    MSL_BINARY(N, V, T, V, |)                                                    \
    MSL_BINARY(N, V, T, V, ^)                                                    \
    MSL_BINARY(N, V, T, V, <<)                                                   \
    MSL_BINARY(N, V, T, V, >>)                                                   \
    MSL_ASSIGN(V, T, %)                                                          \
    MSL_ASSIGN(V, T, &)                                                          \
    MSL_ASSIGN(V, T, |)                                                          \
    MSL_ASSIGN(V, T, ^)                                                          \
    MSL_ASSIGN(V, T, <<)                                                         \
    MSL_ASSIGN(V, T, >>)                                                         \
    MSL_API constexpr V operator~(const V &a) { return MSL_MAP##N(V, a, ~); }

MSL_ARITHMETIC(2, float2, float, bool2)
MSL_ARITHMETIC(3, float3, float, bool3)
MSL_ARITHMETIC(4, float4, float, bool4)
MSL_ARITHMETIC(2, int2, int, bool2)
MSL_ARITHMETIC(3, int3, int, bool3)
MSL_ARITHMETIC(4, int4, int, bool4)
MSL_ARITHMETIC(2, uint2, uint, bool2)
MSL_ARITHMETIC(3, uint3, uint, bool3)
MSL_ARITHMETIC(4, uint4, uint, bool4)
MSL_INTEGER(2, int2, int)
MSL_INTEGER(3, int3, int)
MSL_INTEGER(4, int4, int)
MSL_INTEGER(2, uint2, uint)
MSL_INTEGER(3, uint3, uint)
MSL_INTEGER(4, uint4, uint)

MSL_API constexpr float2 operator-(const float2 &a) { return MSL_MAP2(float2, a, -); }
MSL_API constexpr float3 operator-(const float3 &a) { return MSL_MAP3(float3, a, -); }
MSL_API constexpr float4 operator-(const float4 &a) { return MSL_MAP4(float4, a, -); }
MSL_API constexpr int2 operator-(const int2 &a) { return MSL_MAP2(int2, a, -); }
MSL_API constexpr int3 operator-(const int3 &a) { return MSL_MAP3(int3, a, -); }
MSL_API constexpr int4 operator-(const int4 &a) { return MSL_MAP4(int4, a, -); }

MSL_BINARY(2, bool2, bool, bool2, &&)
MSL_BINARY(3, bool3, bool, bool3, &&)
MSL_BINARY(4, bool4, bool, bool4, &&)
MSL_BINARY(2, bool2, bool, bool2, ||)
MSL_BINARY(3, bool3, bool, bool3, ||)
MSL_BINARY(4, bool4, bool, bool4, ||)
MSL_API constexpr bool2 operator!(const bool2 &a) { return MSL_MAP2(bool2, a, !); }
MSL_API constexpr bool3 operator!(const bool3 &a) { return MSL_MAP3(bool3, a, !); }
MSL_API constexpr bool4 operator!(const bool4 &a) { return MSL_MAP4(bool4, a, !); }
MSL_API constexpr bool all(const bool2 &b) { return b.x && b.y; }
MSL_API constexpr bool all(const bool3 &b) { return b.x && b.y && b.z; }
MSL_API constexpr bool all(const bool4 &b) { return b.x && b.y && b.z && b.w; }
MSL_API constexpr bool any(const bool2 &b) { return b.x || b.y; }
MSL_API constexpr bool any(const bool3 &b) { return b.x || b.y || b.z; }
MSL_API constexpr bool any(const bool4 &b) { return b.x || b.y || b.z || b.w; }

// Column major, as MSL's.
struct float2x2 {
    float2 columns[2];
    float2x2() = default;
    MSL_API constexpr float2x2(const float2 &a, const float2 &b) : columns{a, b} {}
    MSL_API float2 &operator[](int i) { return columns[i]; }
    MSL_API const float2 &operator[](int i) const { return columns[i]; }
};
struct float3x3 {
    float3 columns[3];
    float3x3() = default;
    MSL_API constexpr float3x3(const float3 &a, const float3 &b, const float3 &c) : columns{a, b, c} {}
    MSL_API float3 &operator[](int i) { return columns[i]; }
    MSL_API const float3 &operator[](int i) const { return columns[i]; }
};
struct float4x4 {
    float4 columns[4];
    float4x4() = default;
    MSL_API constexpr float4x4(const float4 &a, const float4 &b, const float4 &c, const float4 &d)
        : columns{a, b, c, d} {}
    MSL_API float4 &operator[](int i) { return columns[i]; }
    MSL_API const float4 &operator[](int i) const { return columns[i]; }
};
static_assert(sizeof(float2x2) == 16 && sizeof(float3x3) == 48 && sizeof(float4x4) == 64, "");

MSL_API constexpr float2 operator*(const float2x2 &m, const float2 &v) {
    return m.columns[0] * v.x + m.columns[1] * v.y;
}
MSL_API constexpr float3 operator*(const float3x3 &m, const float3 &v) {
    return m.columns[0] * v.x + m.columns[1] * v.y + m.columns[2] * v.z;
}
MSL_API constexpr float4 operator*(const float4x4 &m, const float4 &v) {
    return m.columns[0] * v.x + m.columns[1] * v.y + m.columns[2] * v.z + m.columns[3] * v.w;
}
MSL_API constexpr float2x2 operator*(const float2x2 &a, const float2x2 &b) {
    return float2x2(a * b.columns[0], a * b.columns[1]);
}
MSL_API constexpr float3x3 operator*(const float3x3 &a, const float3x3 &b) {
    return float3x3(a * b.columns[0], a * b.columns[1], a * b.columns[2]);
}
MSL_API constexpr float4x4 operator*(const float4x4 &a, const float4x4 &b) {
    return float4x4(a * b.columns[0], a * b.columns[1], a * b.columns[2], a * b.columns[3]);
}

// A bit cast between two types of one size.
template <class T, class U>
MSL_API T as_type(const U &u) {
    static_assert(sizeof(T) == sizeof(U), "as_type needs two types of one size");
    T t;
    memcpy(&t, &u, sizeof(T));
    return t;
}
template <class T, class V, class S, int N>
MSL_API T as_type(const swizzle<V, S, N> &s) {
    return as_type<T>(V(s));
}

// Scalars, as the MSL specification defines them. min and max return the first argument when
// neither is smaller.
#define MSL_MINMAX(T)                                               \
    MSL_API constexpr T min(T x, T y) { return y < x ? y : x; }     \
    MSL_API constexpr T max(T x, T y) { return x < y ? y : x; }     \
    MSL_API constexpr T clamp(T x, T lo, T hi) { return min(max(x, lo), hi); }
MSL_MINMAX(float)
MSL_MINMAX(int)
MSL_MINMAX(uint)
MSL_MINMAX(long)
MSL_MINMAX(ulong)
#undef MSL_MINMAX

MSL_API float abs(float x) { return fabsf(x); }
MSL_API constexpr int abs(int x) { return x < 0 ? -x : x; }
MSL_API float sqrt(float x) { return sqrtf(x); }
#if defined(__CUDACC__)
MSL_API float rsqrt(float x) { return rsqrtf(x); }
MSL_API float sinpi(float x) { return sinpif(x); }
MSL_API float cospi(float x) { return cospif(x); }
#else
MSL_API float rsqrt(float x) { return 1.0f / sqrtf(x); }
MSL_API float sinpi(float x) { return sinf(M_PI_F * x); }
MSL_API float cospi(float x) { return cosf(M_PI_F * x); }
#endif
MSL_API float exp(float x) { return expf(x); }
MSL_API float exp2(float x) { return exp2f(x); }
MSL_API float log(float x) { return logf(x); }
MSL_API float log2(float x) { return log2f(x); }
MSL_API float pow(float x, float y) { return powf(x, y); }
MSL_API float sin(float x) { return sinf(x); }
MSL_API float cos(float x) { return cosf(x); }
MSL_API float tan(float x) { return tanf(x); }
MSL_API float atan2(float y, float x) { return atan2f(y, x); }
MSL_API float floor(float x) { return floorf(x); }
MSL_API float ceil(float x) { return ceilf(x); }
MSL_API float round(float x) { return roundf(x); }
MSL_API float trunc(float x) { return truncf(x); }
MSL_API float fma(float a, float b, float c) { return fmaf(a, b, c); }
MSL_API float ldexp(float x, int k) { return ldexpf(x, k); }
MSL_API float fract(float x) { return fminf(x - floorf(x), 0x1.fffffep-1f); }
MSL_API constexpr float saturate(float x) { return clamp(x, 0.0f, 1.0f); }
MSL_API constexpr float mix(float x, float y, float a) { return x + (y - x) * a; }
MSL_API constexpr float step(float edge, float x) { return x < edge ? 0.0f : 1.0f; }
MSL_API constexpr float sign(float x) { return x > 0.0f ? 1.0f : (x < 0.0f ? -1.0f : 0.0f); }
MSL_API constexpr float smoothstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * (3.0f - 2.0f * t);
}
// On the bits, so that a host compiler's fast math cannot fold them away.
MSL_API bool isnan(float x) { return (as_type<uint>(x) & 0x7FFFFFFFu) > 0x7F800000u; }
MSL_API bool isinf(float x) { return (as_type<uint>(x) & 0x7FFFFFFFu) == 0x7F800000u; }
MSL_API bool isfinite(float x) { return (as_type<uint>(x) & 0x7F800000u) != 0x7F800000u; }

// A host and device function is compiled once for each, and __CUDA_ARCH__ says which.
#if defined(__CUDA_ARCH__)
MSL_API uint popcount(uint x) { return uint(__popc(x)); }
MSL_API uint clz(uint x) { return uint(__clz(int(x))); }
MSL_API uint ctz(uint x) { return x == 0u ? 32u : uint(__ffs(int(x)) - 1); }
#else
MSL_API uint popcount(uint x) { return uint(__builtin_popcount(x)); }
MSL_API uint clz(uint x) { return x == 0u ? 32u : uint(__builtin_clz(x)); }
MSL_API uint ctz(uint x) { return x == 0u ? 32u : uint(__builtin_ctz(x)); }
#endif

template <class T>
MSL_API constexpr T select(T a, T b, bool c) { return c ? b : a; }

#define MSL_UNARY(N, V, f) \
    MSL_API V f(const V &a) { return MSL_MAP##N(V, a, f); }
#define MSL_PAIR(N, V, T, f)                                                        \
    MSL_API V f(const V &a, const V &b) { return V(MSL_PAIR##N(f, a, b)); }         \
    MSL_API V f(const V &a, T s) { return f(a, V(s)); }
#define MSL_PAIR2(f, a, b) f(a.x, b.x), f(a.y, b.y)
#define MSL_PAIR3(f, a, b) f(a.x, b.x), f(a.y, b.y), f(a.z, b.z)
#define MSL_PAIR4(f, a, b) f(a.x, b.x), f(a.y, b.y), f(a.z, b.z), f(a.w, b.w)
#define MSL_TRIPLE2(f, a, b, c) f(a.x, b.x, c.x), f(a.y, b.y, c.y)
#define MSL_TRIPLE3(f, a, b, c) f(a.x, b.x, c.x), f(a.y, b.y, c.y), f(a.z, b.z, c.z)
#define MSL_TRIPLE4(f, a, b, c) f(a.x, b.x, c.x), f(a.y, b.y, c.y), f(a.z, b.z, c.z), f(a.w, b.w, c.w)

#define MSL_ORDERED(N, V, T, B)                                                               \
    MSL_PAIR(N, V, T, min)                                                                    \
    MSL_PAIR(N, V, T, max)                                                                    \
    MSL_API V clamp(const V &a, const V &lo, const V &hi) { return min(max(a, lo), hi); }     \
    MSL_API V clamp(const V &a, T lo, T hi) { return min(max(a, V(lo)), V(hi)); }             \
    MSL_API V select(const V &a, const V &b, const B &c) {                                    \
        return V(MSL_TRIPLE##N(MSL_SELECT, a, b, c));                                         \
    }
#define MSL_SELECT(a, b, c) (c ? b : a)

#define MSL_FLOATING(N, V)                                                                     \
    MSL_ORDERED(N, V, float, bool##N)                                                          \
    MSL_UNARY(N, V, abs)                                                                       \
    MSL_UNARY(N, V, sqrt)                                                                      \
    MSL_UNARY(N, V, rsqrt)                                                                     \
    MSL_UNARY(N, V, exp)                                                                       \
    MSL_UNARY(N, V, exp2)                                                                      \
    MSL_UNARY(N, V, log)                                                                       \
    MSL_UNARY(N, V, log2)                                                                      \
    MSL_UNARY(N, V, sin)                                                                       \
    MSL_UNARY(N, V, cos)                                                                       \
    MSL_UNARY(N, V, floor)                                                                     \
    MSL_UNARY(N, V, ceil)                                                                      \
    MSL_UNARY(N, V, fract)                                                                     \
    MSL_UNARY(N, V, saturate)                                                                  \
    MSL_UNARY(N, V, sign)                                                                      \
    MSL_PAIR(N, V, float, pow)                                                                 \
    MSL_PAIR(N, V, float, atan2)                                                               \
    MSL_API V mix(const V &a, const V &b, const V &t) { return a + (b - a) * t; }              \
    MSL_API V mix(const V &a, const V &b, float t) { return a + (b - a) * t; }                 \
    MSL_API V fma(const V &a, const V &b, const V &c) { return V(MSL_TRIPLE##N(fma, a, b, c)); } \
    MSL_API V step(const V &edge, const V &a) { return V(MSL_PAIR##N(step, edge, a)); }        \
    MSL_API V step(float edge, const V &a) { return step(V(edge), a); }                        \
    MSL_API V smoothstep(const V &e0, const V &e1, const V &a) {                               \
        return V(MSL_TRIPLE##N(smoothstep, e0, e1, a));                                        \
    }                                                                                          \
    MSL_API V smoothstep(float e0, float e1, const V &a) { return smoothstep(V(e0), V(e1), a); } \
    MSL_API float length_squared(const V &a) { return dot(a, a); }                             \
    MSL_API float length(const V &a) { return sqrtf(dot(a, a)); }                              \
    MSL_API float distance_squared(const V &a, const V &b) { return length_squared(a - b); }   \
    MSL_API float distance(const V &a, const V &b) { return length(a - b); }                   \
    MSL_API V normalize(const V &a) { return a / length(a); }

MSL_API constexpr float dot(const float2 &a, const float2 &b) { return a.x * b.x + a.y * b.y; }
MSL_API constexpr float dot(const float3 &a, const float3 &b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}
MSL_API constexpr float dot(const float4 &a, const float4 &b) {
    return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w;
}
MSL_API constexpr float3 cross(const float3 &a, const float3 &b) {
    return float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x);
}

MSL_FLOATING(2, float2)
MSL_FLOATING(3, float3)
MSL_FLOATING(4, float4)
MSL_ORDERED(2, int2, int, bool2)
MSL_ORDERED(3, int3, int, bool3)
MSL_ORDERED(4, int4, int, bool4)
MSL_ORDERED(2, uint2, uint, bool2)
MSL_ORDERED(3, uint3, uint, bool3)
MSL_ORDERED(4, uint4, uint, bool4)
MSL_UNARY(2, int2, abs)
MSL_UNARY(3, int3, abs)
MSL_UNARY(4, int4, abs)
MSL_UNARY(2, uint2, popcount)
MSL_UNARY(3, uint3, popcount)
MSL_UNARY(4, uint4, popcount)

// Atomics. A relaxed load or store is a plain one; the others are CUDA's atomic functions, and
// plain operations on the CPU, where one thread runs at a time.
struct atomic_uint {
    uint value;
};
struct atomic_int {
    int value;
};
static_assert(sizeof(atomic_uint) == 4 && sizeof(atomic_int) == 4, "an atomic is its value");
enum memory_order { memory_order_relaxed };

#define MSL_ATOMIC(A, T)                                                                         \
    MSL_DEVICE T atomic_load_explicit(const A *a, memory_order) { return a->value; }             \
    MSL_DEVICE void atomic_store_explicit(A *a, T v, memory_order) { a->value = v; }             \
    MSL_DEVICE T atomic_exchange_explicit(A *a, T v, memory_order) { MSL_ATOMIC_EXCHANGE(a, v) } \
    MSL_DEVICE T atomic_fetch_add_explicit(A *a, T v, memory_order) { MSL_ATOMIC_ADD(a, v) }     \
    MSL_DEVICE T atomic_fetch_sub_explicit(A *a, T v, memory_order) { MSL_ATOMIC_SUB(a, v) }     \
    MSL_DEVICE T atomic_fetch_min_explicit(A *a, T v, memory_order) { MSL_ATOMIC_MIN(a, v) }     \
    MSL_DEVICE T atomic_fetch_max_explicit(A *a, T v, memory_order) { MSL_ATOMIC_MAX(a, v) }     \
    MSL_DEVICE T atomic_fetch_and_explicit(A *a, T v, memory_order) { MSL_ATOMIC_AND(a, v) }     \
    MSL_DEVICE T atomic_fetch_or_explicit(A *a, T v, memory_order) { MSL_ATOMIC_OR(a, v) }       \
    MSL_DEVICE T atomic_fetch_xor_explicit(A *a, T v, memory_order) { MSL_ATOMIC_XOR(a, v) }
#if defined(__CUDACC__)
#define MSL_ATOMIC_EXCHANGE(a, v) return atomicExch(&a->value, v);
#define MSL_ATOMIC_ADD(a, v) return atomicAdd(&a->value, v);
#define MSL_ATOMIC_SUB(a, v) return atomicSub(&a->value, v);
#define MSL_ATOMIC_MIN(a, v) return atomicMin(&a->value, v);
#define MSL_ATOMIC_MAX(a, v) return atomicMax(&a->value, v);
#define MSL_ATOMIC_AND(a, v) return atomicAnd(&a->value, v);
#define MSL_ATOMIC_OR(a, v) return atomicOr(&a->value, v);
#define MSL_ATOMIC_XOR(a, v) return atomicXor(&a->value, v);
#else
#define MSL_ATOMIC_PLAIN(a, expression) \
    auto old = a->value;                \
    a->value = expression;              \
    return old;
#define MSL_ATOMIC_EXCHANGE(a, v) MSL_ATOMIC_PLAIN(a, v)
#define MSL_ATOMIC_ADD(a, v) MSL_ATOMIC_PLAIN(a, old + v)
#define MSL_ATOMIC_SUB(a, v) MSL_ATOMIC_PLAIN(a, old - v)
#define MSL_ATOMIC_MIN(a, v) MSL_ATOMIC_PLAIN(a, v < old ? v : old)
#define MSL_ATOMIC_MAX(a, v) MSL_ATOMIC_PLAIN(a, v > old ? v : old)
#define MSL_ATOMIC_AND(a, v) MSL_ATOMIC_PLAIN(a, old & v)
#define MSL_ATOMIC_OR(a, v) MSL_ATOMIC_PLAIN(a, old | v)
#define MSL_ATOMIC_XOR(a, v) MSL_ATOMIC_PLAIN(a, old ^ v)
#endif
MSL_ATOMIC(atomic_uint, uint)
MSL_ATOMIC(atomic_int, int)

// Barriers and SIMD-group functions. A warp is 32 lanes, as a SIMD group is on Apple's GPUs.
// CUDA's need every lane of the warp to make the call. On the CPU they are one-lane stand-ins,
// there for the text to compile: a function that calls one runs only on a GPU.
enum class mem_flags { mem_none, mem_device, mem_threadgroup, mem_texture };

struct simd_vote {
    typedef ulong vote_t;
#if defined(__CUDACC__)
    static constexpr uint every = 0xFFFFFFFFu;
#else
    static constexpr uint every = 1u;
#endif
    uint lanes;
    MSL_API explicit constexpr simd_vote(vote_t v = 0) : lanes(uint(v)) {}
    MSL_API explicit constexpr operator vote_t() const { return lanes; }
    MSL_API constexpr bool all() const { return lanes == every; }
    MSL_API constexpr bool any() const { return lanes != 0u; }
};

#if defined(__CUDACC__)

MSL_DEVICE void threadgroup_barrier(mem_flags) { __syncthreads(); }
MSL_DEVICE void simdgroup_barrier(mem_flags) { __syncwarp(); }
MSL_DEVICE uint msl_lane() {
    return (threadIdx.x + blockDim.x * (threadIdx.y + blockDim.y * threadIdx.z)) & 31u;
}

#define MSL_SHUFFLE(name, call)                                                              \
    template <class T>                                                                       \
    MSL_DEVICE T name(T v, uint k) { return call(0xFFFFFFFFu, v, k); }                       \
    template <class T>                                                                       \
    MSL_DEVICE vec2<T> name(vec2<T> v, uint k) { return vec2<T>(name(v.x, k), name(v.y, k)); } \
    template <class T>                                                                       \
    MSL_DEVICE vec3<T> name(vec3<T> v, uint k) {                                             \
        return vec3<T>(name(v.x, k), name(v.y, k), name(v.z, k));                            \
    }                                                                                        \
    template <class T>                                                                       \
    MSL_DEVICE vec4<T> name(vec4<T> v, uint k) {                                             \
        return vec4<T>(name(v.x, k), name(v.y, k), name(v.z, k), name(v.w, k));              \
    }
MSL_SHUFFLE(msl_shuffle, __shfl_sync)
MSL_SHUFFLE(msl_shuffle_up, __shfl_up_sync)
MSL_SHUFFLE(msl_shuffle_xor, __shfl_xor_sync)
#undef MSL_SHUFFLE

MSL_DEVICE simd_vote simd_ballot(bool predicate) {
    return simd_vote(__ballot_sync(0xFFFFFFFFu, predicate));
}
template <class T>
MSL_DEVICE T simd_broadcast(T v, uint lane) { return msl_shuffle(v, lane); }
template <class T>
MSL_DEVICE T simd_sum(T v) {
    for (uint k = 16u; k > 0u; k >>= 1) { v += msl_shuffle_xor(v, k); }
    return v;
}
template <class T>
MSL_DEVICE T simd_min(T v) {
    for (uint k = 16u; k > 0u; k >>= 1) { v = min(v, msl_shuffle_xor(v, k)); }
    return v;
}
template <class T>
MSL_DEVICE T simd_max(T v) {
    for (uint k = 16u; k > 0u; k >>= 1) { v = max(v, msl_shuffle_xor(v, k)); }
    return v;
}
template <class T>
MSL_DEVICE T simd_prefix_inclusive_sum(T v) {
    uint lane = msl_lane();
    for (uint k = 1u; k < 32u; k <<= 1) {
        T below = msl_shuffle_up(v, k);
        if (lane >= k) { v += below; }
    }
    return v;
}
template <class T>
MSL_DEVICE T simd_prefix_exclusive_sum(T v) {
    T before = msl_shuffle_up(simd_prefix_inclusive_sum(v), 1u);
    return msl_lane() == 0u ? T(0) : before;
}

#else

MSL_API void threadgroup_barrier(mem_flags) {}
MSL_API void simdgroup_barrier(mem_flags) {}
MSL_API simd_vote simd_ballot(bool predicate) { return simd_vote(predicate ? 1u : 0u); }
template <class T>
MSL_API T simd_broadcast(T v, uint) { return v; }
template <class T>
MSL_API T simd_sum(T v) { return v; }
template <class T>
MSL_API T simd_min(T v) { return v; }
template <class T>
MSL_API T simd_max(T v) { return v; }
template <class T>
MSL_API T simd_prefix_inclusive_sum(T v) { return v; }
template <class T>
MSL_API T simd_prefix_exclusive_sum(T) { return T(0); }

#endif

}  // namespace metal

#endif
