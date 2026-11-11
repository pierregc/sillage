// Every Metal library's MSL in one translation unit (#281). nvcc compiles it for the GPU, a
// host compiler for the CPU target, and ./scripts/dev.sh check on the Mac as plain C++17: a
// construct only Metal knows, outside `#if defined(__METAL_VERSION__)`, fails here.
#include "cuda_cpu.h"
#include "kernels.h"

// The size of each struct a shared kernel reads from a buffer, as Metal lays it out. The Swift
// mirrors are held to the same lines by KernelSourceTests.
#define SILLAGE_STRUCT(library, name, bytes)                   \
    static_assert(sizeof(metal::library::name) == bytes,       \
                  #library "." #name " is no longer " #bytes " bytes: its Swift mirror must follow")

SILLAGE_STRUCT(BarnesHutShaders, BHNode, 32);
SILLAGE_STRUCT(BarnesHutShaders, BHParams, 32);
SILLAGE_STRUCT(BarnesHutShaders, HaloGPU, 48);
SILLAGE_STRUCT(BarnesHutShaders, DiskCooling, 64);
SILLAGE_STRUCT(BarnesHutShaders, SFParams, 36);
SILLAGE_STRUCT(BarnesHutShaders, HoleGPU, 32);
SILLAGE_STRUCT(GPUTreeShaders, BHNode, 32);
SILLAGE_STRUCT(GPUTreeShaders, TreeParams, 36);

// The renderer's particle passes (#276).
SILLAGE_STRUCT(Shaders, SplatUniforms, 176);
SILLAGE_STRUCT(Shaders, WebUniforms, 112);
SILLAGE_STRUCT(Shaders, DiskFrame, 128);
SILLAGE_STRUCT(Shaders, GalaxyRamp, 112);
SILLAGE_STRUCT(Shaders, BackgroundStar, 32);
