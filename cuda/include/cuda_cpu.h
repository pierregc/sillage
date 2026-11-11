// CUDA over plain C++17 (#281): the files of cuda/src build with a host compiler and run their
// kernels on the CPU, one thread after another, for correctness on small inputs. Included first
// by every file of cuda/src; under nvcc it only defines SILLAGE_LAUNCH.
//
// Not emulated: block barriers (__syncthreads), __shared__ arrays, warp functions and
// cooperative groups. An entry point that uses them is `cuda gpu-only` in cuda/kernels.txt and
// sits under `#if !defined(SILLAGE_CPU)`.
#ifndef SILLAGE_CUDA_CPU_H
#define SILLAGE_CUDA_CPU_H

#if defined(__CUDACC__)

#include <cuda_runtime.h>

// Every launch goes through this, so that the CPU build can run it.
#define SILLAGE_LAUNCH(kernel, grid, block, ...) kernel<<<(grid), (block)>>>(__VA_ARGS__)

#else

#define SILLAGE_CPU 1

#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>

#define __global__
#define __device__
#define __host__
#define __forceinline__ inline
#define __noinline__
#define __launch_bounds__(...)
// __restrict__ is a keyword of GCC and Clang already.

struct dim3 {
    unsigned x, y, z;
    constexpr dim3(unsigned x = 1, unsigned y = 1, unsigned z = 1) : x(x), y(y), z(z) {}
};

struct sillage_cpu_index {
    unsigned x, y, z;
};

// Set by the launch for the thread that is running. One a host thread, so that two launches
// from two host threads do not mix.
inline thread_local sillage_cpu_index threadIdx, blockIdx;
inline thread_local dim3 blockDim, gridDim;

template <class Body>
void sillage_cpu_launch(dim3 grid, dim3 block, Body body) {
    gridDim = grid;
    blockDim = block;
    for (unsigned bz = 0; bz < grid.z; ++bz) {
        for (unsigned by = 0; by < grid.y; ++by) {
            for (unsigned bx = 0; bx < grid.x; ++bx) {
                blockIdx = {bx, by, bz};
                for (unsigned tz = 0; tz < block.z; ++tz) {
                    for (unsigned ty = 0; ty < block.y; ++ty) {
                        for (unsigned tx = 0; tx < block.x; ++tx) {
                            threadIdx = {tx, ty, tz};
                            body();
                        }
                    }
                }
            }
        }
    }
}

#define SILLAGE_LAUNCH(kernel, grid, block, ...) \
    sillage_cpu_launch((grid), (block), [&] { kernel(__VA_ARGS__); })

// CUDA's atomic functions for the types CUDA has them for. Exact, since one thread runs at a
// time. Each returns the value held before.
#define SILLAGE_CPU_ATOMIC(T)                                 \
    inline T atomicAdd(T *address, T value) {                 \
        T old = *address;                                     \
        *address = old + value;                               \
        return old;                                           \
    }                                                         \
    inline T atomicExch(T *address, T value) {                \
        T old = *address;                                     \
        *address = value;                                     \
        return old;                                           \
    }
#define SILLAGE_CPU_ATOMIC_INTEGER(T)                         \
    SILLAGE_CPU_ATOMIC(T)                                     \
    inline T atomicSub(T *address, T value) {                 \
        T old = *address;                                     \
        *address = old - value;                               \
        return old;                                           \
    }                                                         \
    inline T atomicMin(T *address, T value) {                 \
        T old = *address;                                     \
        *address = value < old ? value : old;                 \
        return old;                                           \
    }                                                         \
    inline T atomicMax(T *address, T value) {                 \
        T old = *address;                                     \
        *address = value > old ? value : old;                 \
        return old;                                           \
    }                                                         \
    inline T atomicAnd(T *address, T value) {                 \
        T old = *address;                                     \
        *address = old & value;                               \
        return old;                                           \
    }                                                         \
    inline T atomicOr(T *address, T value) {                  \
        T old = *address;                                     \
        *address = old | value;                               \
        return old;                                           \
    }                                                         \
    inline T atomicXor(T *address, T value) {                 \
        T old = *address;                                     \
        *address = old ^ value;                               \
        return old;                                           \
    }                                                         \
    inline T atomicCAS(T *address, T compare, T value) {      \
        T old = *address;                                     \
        if (old == compare) { *address = value; }             \
        return old;                                           \
    }
SILLAGE_CPU_ATOMIC_INTEGER(int)
SILLAGE_CPU_ATOMIC_INTEGER(unsigned int)
SILLAGE_CPU_ATOMIC_INTEGER(unsigned long long)
SILLAGE_CPU_ATOMIC(float)
SILLAGE_CPU_ATOMIC(double)
#undef SILLAGE_CPU_ATOMIC_INTEGER
#undef SILLAGE_CPU_ATOMIC

template <class T>
inline T __ldg(const T *address) { return *address; }

enum cudaError_t {
    cudaSuccess = 0,
    cudaErrorInvalidValue = 1,
    cudaErrorMemoryAllocation = 2,
    cudaErrorNoDevice = 100,
};
enum cudaMemcpyKind {
    cudaMemcpyHostToHost,
    cudaMemcpyHostToDevice,
    cudaMemcpyDeviceToHost,
    cudaMemcpyDeviceToDevice,
    cudaMemcpyDefault,
};

// Device memory is host memory, aligned as cudaMalloc aligns it.
inline cudaError_t sillage_cpu_allocate(void **pointer, size_t size) {
    *pointer = std::aligned_alloc(256, (size + 255) / 256 * 256 + 256);
    return *pointer ? cudaSuccess : cudaErrorMemoryAllocation;
}
template <class T>
inline cudaError_t cudaMalloc(T **pointer, size_t size) {
    return sillage_cpu_allocate((void **)pointer, size);
}
template <class T>
inline cudaError_t cudaMallocHost(T **pointer, size_t size) {
    return sillage_cpu_allocate((void **)pointer, size);
}
inline cudaError_t cudaFree(void *pointer) {
    std::free(pointer);
    return cudaSuccess;
}
inline cudaError_t cudaFreeHost(void *pointer) {
    std::free(pointer);
    return cudaSuccess;
}
inline cudaError_t cudaMemcpy(void *to, const void *from, size_t size, cudaMemcpyKind) {
    std::memcpy(to, from, size);
    return cudaSuccess;
}
inline cudaError_t cudaMemset(void *pointer, int value, size_t size) {
    std::memset(pointer, value, size);
    return cudaSuccess;
}

inline cudaError_t cudaDeviceSynchronize() { return cudaSuccess; }
inline cudaError_t cudaGetLastError() { return cudaSuccess; }
inline cudaError_t cudaPeekAtLastError() { return cudaSuccess; }
inline cudaError_t cudaSetDevice(int device) {
    return device == 0 ? cudaSuccess : cudaErrorInvalidValue;
}
inline cudaError_t cudaGetDeviceCount(int *count) {
    *count = 1;
    return cudaSuccess;
}
inline const char *cudaGetErrorName(cudaError_t error) {
    switch (error) {
        case cudaSuccess: return "cudaSuccess";
        case cudaErrorInvalidValue: return "cudaErrorInvalidValue";
        case cudaErrorMemoryAllocation: return "cudaErrorMemoryAllocation";
        case cudaErrorNoDevice: return "cudaErrorNoDevice";
    }
    return "unknown";
}
inline const char *cudaGetErrorString(cudaError_t error) {
    switch (error) {
        case cudaSuccess: return "no error";
        case cudaErrorInvalidValue: return "invalid argument";
        case cudaErrorMemoryAllocation: return "out of memory";
        case cudaErrorNoDevice: return "no CUDA-capable device is detected";
    }
    return "unknown error";
}

// The scalar min and max CUDA declares at global scope, mixed types included.
#define SILLAGE_CPU_MINMAX(R, A, B)                                          \
    inline R min(const A a, const B b) { return (R)a < (R)b ? (R)a : (R)b; } \
    inline R max(const A a, const B b) { return (R)a > (R)b ? (R)a : (R)b; }
SILLAGE_CPU_MINMAX(int, int, int)
SILLAGE_CPU_MINMAX(unsigned int, unsigned int, unsigned int)
SILLAGE_CPU_MINMAX(unsigned int, int, unsigned int)
SILLAGE_CPU_MINMAX(unsigned int, unsigned int, int)
SILLAGE_CPU_MINMAX(long long, long long, long long)
SILLAGE_CPU_MINMAX(unsigned long long, unsigned long long, unsigned long long)
SILLAGE_CPU_MINMAX(float, float, float)
SILLAGE_CPU_MINMAX(double, double, double)
SILLAGE_CPU_MINMAX(double, float, double)
SILLAGE_CPU_MINMAX(double, double, float)
#undef SILLAGE_CPU_MINMAX

#endif

#endif
