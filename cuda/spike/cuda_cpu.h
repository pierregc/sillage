// A first, minimal CUDA runtime on the CPU (#271): the same .cu file builds with a host
// compiler and runs its kernels one thread after another. Only for kernels with no block
// barrier and no warp function. Under nvcc it only defines CUDA_LAUNCH.
#pragma once

#ifdef __CUDACC__

#define CUDA_LAUNCH(kernel, grid, block, ...) kernel<<<(grid), (block)>>>(__VA_ARGS__)

#else

#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <math.h>

#define __global__
#define __device__
#define __host__
#define __constant__
#define __forceinline__ inline
#define __launch_bounds__(...)
// __restrict__ is already a GCC and Clang keyword.

struct dim3 {
    unsigned x, y, z;
    dim3(unsigned x = 1, unsigned y = 1, unsigned z = 1) : x(x), y(y), z(z) {}
};

struct cuda_cpu_index {
    unsigned x, y, z;
};

inline cuda_cpu_index threadIdx, blockIdx;
inline dim3 blockDim, gridDim;

template <class Body>
void cuda_cpu_launch(dim3 grid, dim3 block, Body body) {
    gridDim = grid;
    blockDim = block;
    for (unsigned bz = 0; bz < grid.z; ++bz)
        for (unsigned by = 0; by < grid.y; ++by)
            for (unsigned bx = 0; bx < grid.x; ++bx) {
                blockIdx = {bx, by, bz};
                for (unsigned tz = 0; tz < block.z; ++tz)
                    for (unsigned ty = 0; ty < block.y; ++ty)
                        for (unsigned tx = 0; tx < block.x; ++tx) {
                            threadIdx = {tx, ty, tz};
                            body();
                        }
            }
}

#define CUDA_LAUNCH(kernel, grid, block, ...) \
    cuda_cpu_launch((grid), (block), [&] { kernel(__VA_ARGS__); })

template <class T>
inline T __ldg(const T *p) { return *p; }

enum cudaError_t { cudaSuccess = 0, cudaErrorMemoryAllocation = 2, cudaErrorNoDevice = 100 };
enum cudaMemcpyKind {
    cudaMemcpyHostToHost,
    cudaMemcpyHostToDevice,
    cudaMemcpyDeviceToHost,
    cudaMemcpyDeviceToDevice,
    cudaMemcpyDefault
};

inline cudaError_t cudaMalloc(void **p, size_t size) {
    *p = std::aligned_alloc(256, (size + 255) / 256 * 256 + 256);
    return *p ? cudaSuccess : cudaErrorMemoryAllocation;
}
template <class T>
inline cudaError_t cudaMalloc(T **p, size_t size) { return cudaMalloc((void **)p, size); }
inline cudaError_t cudaMemcpy(void *dst, const void *src, size_t size, cudaMemcpyKind) {
    std::memcpy(dst, src, size);
    return cudaSuccess;
}
template <class T>
inline cudaError_t cudaMemcpyToSymbol(T &symbol, const void *src, size_t size, size_t offset = 0,
                                      cudaMemcpyKind = cudaMemcpyHostToDevice) {
    std::memcpy((char *)&symbol + offset, src, size);
    return cudaSuccess;
}
inline cudaError_t cudaFree(void *p) {
    std::free(p);
    return cudaSuccess;
}
inline cudaError_t cudaDeviceSynchronize() { return cudaSuccess; }
inline cudaError_t cudaGetLastError() { return cudaSuccess; }
inline cudaError_t cudaGetDeviceCount(int *count) {
    *count = 1;
    return cudaSuccess;
}
inline const char *cudaGetErrorString(cudaError_t e) { return e == cudaSuccess ? "no error" : "error"; }

// The scalar min and max CUDA declares at global scope, mixed types included.
#define CUDA_CPU_MINMAX(R, A, B)                         \
    inline R min(const A a, const B b) { return (R)a < (R)b ? (R)a : (R)b; } \
    inline R max(const A a, const B b) { return (R)a > (R)b ? (R)a : (R)b; }
CUDA_CPU_MINMAX(int, int, int)
CUDA_CPU_MINMAX(unsigned int, unsigned int, unsigned int)
CUDA_CPU_MINMAX(unsigned int, int, unsigned int)
CUDA_CPU_MINMAX(unsigned int, unsigned int, int)
CUDA_CPU_MINMAX(float, float, float)
CUDA_CPU_MINMAX(double, double, double)
CUDA_CPU_MINMAX(double, float, double)
CUDA_CPU_MINMAX(double, double, float)
#undef CUDA_CPU_MINMAX

#endif
