// Opens a library's MSL text (#281): the address space keywords and the two macros the shared
// text is written with. No header may be included before msl_end.h closes them.
#if defined(__CUDACC__)
// CUDA spells __device__ as __attribute__((device)), which the empty `device` below would
// erase; the double underscore name survives it.
#pragma push_macro("__device__")
#undef __device__
#define __device__ __attribute__((__device__))
#define SHARED static __device__ __forceinline__
// A device variable, so that a table can be indexed at run time; constexpr, so that a scalar
// can size an array.
#define SHARED_CONSTANT static __device__ constexpr
#else
#define SHARED static inline
#define SHARED_CONSTANT static constexpr
#endif
#define device
#define constant const
#define thread
#define threadgroup
