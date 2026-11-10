# One kernel source for Metal and CUDA (#281)

The hires engine gets a CUDA twin for rented NVIDIA GPUs (#269). Two copies of 62 kernels would
drift: a look tuned on the Mac would leave the rented GPU drawing something else, and nobody
would notice before a paid run. So the two engines share their source, and what cannot be shared
is checked on the Mac by every `./scripts/dev.sh check`, with no GPU and no CUDA toolkit, and on
every push by a GitHub workflow that compiles the CUDA code and runs it on the CPU.

- **One text for the kernels.** The MSL stays in the Swift strings Metal compiles. A kernel's
  work is an ordinary function of that text; its Metal entry point (`kernel`, `vertex` or
  `fragment`, with its `[[buffer(n)]]` attributes) only calls it, inside
  `#if defined(__METAL_VERSION__)`. The CUDA build compiles the very same text through
  `cuda/include/msl_compat.h` and adds its own entry points and launches, nothing else.
- **One text for the structs** the kernels read: defined in that MSL, read by CUDA through it.
- **One text for the CUDA entry points, two targets**: `nvcc` for the GPU, and a host compiler
  through `cuda/include/cuda_cpu.h` for the CPU, where the entry points without block barriers
  or warp functions run one thread after another on small inputs. Phase 1 of #269 tests the
  CUDA engine that way, with nothing rented.

#281 shared the tree (`GPUTreeShaders`, 20 kernels). The other libraries are still whole inside
`#if defined(__METAL_VERSION__)`: #274 and #275 share `BarnesHutShaders`, #276 and #277
`Shaders`; `RecordingShaders` (take playback) and `SolverShaders` (the restricted solver) stay
Metal only.

## Changing the engine from now on

**Change a kernel's arithmetic**: edit its shared function in the MSL, nothing else. The CUDA
engine has the change at its next build. `./scripts/dev.sh check` says at once if the new text
is not also C++ (below).

**Add a kernel, a shader or a pass**: write its work as a shared function; give it its Metal
entry point inside `#if defined(__METAL_VERSION__)`, and its CUDA entry point of the same name
in `cuda/src`, or mark it `pending #<issue>` or `metal-only: <reason>` in `cuda/kernels.txt`.
A pass goes into the shared order of a step or of a frame (portable Swift with exhaustive
switches, from #274 and #276 on), so that the CUDA module stops compiling until it handles it.
The check fails on a Metal function missing from `cuda/kernels.txt`, and says what to add.

**Change a struct a kernel reads**: change it in the MSL and in its Swift mirror. If
`cuda/src/kernels.cu` holds it to a size (`SILLAGE_STRUCT`), change the size there:
`KernelSourceTests` holds the Swift mirror to the same line.

**Change an output on purpose**: regenerate the reference outputs with
`./scripts/dev.sh fixtures` and say so in the PR (below).

**Share a library** (#274 to #277), as #281 did for the tree, in steps small enough that the
Mac can say after each one whether Metal still gives the same bits:

1. Add the preamble after `using namespace metal;`, the two macros Metal needs:
   ```
   #if defined(__METAL_VERSION__)
   #define SHARED static
   #define SHARED_CONSTANT constant
   #endif
   ```
2. Move the library's `#if defined(__METAL_VERSION__)` down as functions become shared: what is
   above it is shared, what is below is Metal's.
3. Give every shared function `SHARED` in place of `static` or `inline`, and every program-scope
   constant or table `SHARED_CONSTANT` in place of `constant`.
4. Move each kernel's body, unchanged, into a `SHARED` function that takes the kernel's
   arguments without their attributes, and leave a Metal entry point that calls it. Compare the
   bodies before and after by script, not by eye: #281's 373 lines were the same lines in the
   same order.
5. Write the CUDA entry points in `cuda/src`, update `cuda/kernels.txt`, and add a
   `SILLAGE_STRUCT` line and a mirror in `KernelSourceTests` for each struct read from a buffer.

## What the shared text may hold

The shared text is MSL that is also C++17. `scripts/kernel-check.sh` enforces it; these are the
rules it comes down to.

- **Qualifiers through two macros.** `SHARED` on every function: `static` on Metal,
  `static __device__ __forceinline__` under `nvcc`, `static inline` in C++. `SHARED_CONSTANT` on
  every program-scope constant and table: `constant` on Metal, `static __device__ constexpr`
  under `nvcc` (a device variable, so a table can be indexed at run time, and a constant
  expression, so a scalar can size an array), `static constexpr` in C++. A bare `static` or
  `inline` function compiles in C++ and fails under `nvcc`, which the workflow catches.
- **Every float literal carries its `f`.** MSL reads `0.5` as a float; C++ and CUDA read it as a
  double, and a consumer NVIDIA GPU runs double arithmetic at 1/64 of float speed. The check
  refuses a literal without a suffix anywhere in the MSL, guarded or not. A half literal
  (`0.5h`) is not C++: in shared text write `half(0.5f)`.
- **Address spaces.** `device`, `thread` and `threadgroup` vanish outside Metal and `constant`
  becomes `const`, so a shared function takes `device const float3 *positions`,
  `constant TreeParams &p` or `thread uint &work` as Metal wants them. Scalars bound as
  `constant uint &count` are passed to the shared function by value.
- **Threadgroup memory is declared in the entry point**, where Metal wants it and where CUDA
  declares its `__shared__` twin, and passed to the shared function as a `threadgroup` pointer
  (or reference, for a scalar). The barriers stay in the shared function:
  `threadgroup_barrier` is `__syncthreads` and `simdgroup_barrier` is `__syncwarp` under `nvcc`.
- **SIMD-group functions** (`simd_sum`, `simd_min`, `simd_max`, `simd_prefix_inclusive_sum`,
  `simd_prefix_exclusive_sum`, `simd_ballot`, `simd_broadcast`) are warp functions under `nvcc`:
  a warp is 32 lanes, as a SIMD group is on Apple's GPUs, and every lane of the warp must make
  the call. In C++ they are one-lane stand-ins, there for the text to compile: a function that
  calls one, or a barrier, runs only on a GPU, and its entry point is `cuda gpu-only`.
- **Atomics** (`atomic_uint`, `atomic_int`, and `atomic_load_explicit`, `_store_`, `_exchange_`,
  `_fetch_add_`, `_fetch_sub_`, `_fetch_min_`, `_fetch_max_`, `_fetch_and_`, `_fetch_or_`,
  `_fetch_xor_`): CUDA's atomic functions under `nvcc`, plain operations on the CPU, exact there
  since one thread runs at a time.
- **What only Metal has stays in the Metal entry point**: `[[...]]` attributes, texture reads
  and writes, samplers, `discard_fragment`, `point_coord`, and the thread's position, which the
  entry point passes down as plain integers. A function constant
  (`[[function_constant(n)]]`, three in `BarnesHutShaders`) stays there too and reaches the
  shared function as an argument, or becomes a template parameter of the CUDA entry point
  (#274).
- **No `static` local variable, no recursion, no `double`**, as in MSL.

What `msl_compat.h` gives the text, with MSL's meaning: `float2`, `float3`, `float4`, their
`int`, `uint` and `bool` twins and `float2x2`, `float3x3`, `float4x4`, laid out as in a Metal
buffer (a `float3` is 16 bytes aligned to 16; `packed_float3` is 12); every constructor, operator
and comparison the libraries use; the swizzles `.xyz`, `.rgb` and `.xy`, readable and writable,
as union members over `x y z w`; `as_type<T>`; `half`, `half2`, `half3` and `half4` as float
types, so the CUDA renderer computes in fp32 where Metal computes in fp16; `min`, `max`,
`clamp`, `saturate`, `mix`, `step`, `smoothstep`, `select`, `sign`, `abs`, `fract`, `floor`,
`ceil`, `round`, `trunc`, `sqrt`, `rsqrt`, `exp`, `exp2`, `log`, `log2`, `pow`, `sin`, `cos`,
`tan`, `sinpi`, `cospi`, `atan2`, `fma`, `ldexp`, `dot`, `cross`, `length`, `distance`,
`normalize`, `all`, `any`, `isfinite`, `isnan`, `isinf`, `popcount`, `clz`, `ctz`, and `M_PI_F`
and its kin. `min` and `max` are the specification's (`y < x ? y : x`), not `fmin`. A function
or a swizzle that is missing goes into `msl_compat.h`, with a line in `cuda/tests/compat.cu`,
never into a CUDA copy of the arithmetic.

## How the text reaches a C++ compiler

`scripts/kernel-sources.sh` writes each library's MSL to `.build/kernels/<library>.h` (and
`kernels.h`, which includes them all). A library is an `enum <library>` holding one
`static let source`, a multi-line string literal. The script refuses anything it could not hand
over as Metal sees it: a backslash (an interpolation or an escape), a `source` put together from
several strings, a second string in the file, MSL anywhere else. The header is the text
unchanged, wrapped like this:

```
#include "msl_compat.h"
namespace metal {
namespace GPUTreeShaders {
#include "msl_begin.h"
#line 4 "Sources/SillageRender/GPUTreeShaders.swift"
... the MSL, from `#include <metal_stdlib>` on ...
#include "msl_end.h"
}
}
```

- **The `#line`** sends every compiler message back to the Swift file and line.
- **Inside `namespace metal`**, `float3`, `uint3`, `min`, `max`, `abs` or `sqrt` are
  `msl_compat.h`'s: a name found in `metal` hides CUDA's own `float3` (12 bytes), its global
  `min` and `max`, and the C library's `abs(int)`. Outside it, with only
  `using namespace metal;`, the same names are ambiguous. So **CUDA code that touches MSL types
  is written inside `namespace metal { namespace <library> {`**, entry points included.
- **A namespace a library**, because two libraries define the same names (`BHNode` is in
  `GPUTreeShaders` and in `BarnesHutShaders`).
- **`msl_begin.h` and `msl_end.h`** define and undefine the address space keywords and the two
  macros. `device` and `thread` are common words: no header may be included between the two, and
  `cuda/include/metal_stdlib`, which the MSL's first line includes, is empty. Under `nvcc`,
  `msl_begin.h` also respells `__device__` as `__attribute__((__device__))`, because CUDA's own
  spelling, `__attribute__((device))`, would lose its word to the empty `device`.

## The CPU target

`cuda/include/cuda_cpu.h` is the first include of every file of `cuda/src`. Under `nvcc` it
includes the CUDA runtime and defines one macro; with a host compiler it defines `SILLAGE_CPU`
and stands in for CUDA:

- `__global__`, `__device__`, `__host__`, `__forceinline__`, `__noinline__` and
  `__launch_bounds__` are nothing or plain C++.
- **Every launch goes through `SILLAGE_LAUNCH(kernel, grid, block, args...)`**:
  `kernel<<<grid, block>>>(args...)` under `nvcc`, and on the CPU a loop over the blocks and
  their threads that sets `threadIdx`, `blockIdx`, `blockDim` and `gridDim` and calls the kernel.
- `atomicAdd`, `atomicSub`, `atomicMin`, `atomicMax`, `atomicAnd`, `atomicOr`, `atomicXor`,
  `atomicCAS` and `atomicExch` for the types CUDA has them for, as plain operations; `__ldg` a
  plain load.
- `cudaMalloc`, `cudaMallocHost`, `cudaMemcpy`, `cudaMemset`, `cudaFree` and `cudaFreeHost` on
  host memory aligned to 256 bytes; `cudaGetLastError`, `cudaPeekAtLastError`,
  `cudaGetErrorName`, `cudaGetErrorString`, `cudaDeviceSynchronize`, `cudaSetDevice` and
  `cudaGetDeviceCount`, which reports one device.
- The scalar `min` and `max` CUDA declares at global scope.

**Not emulated**: block barriers (`__syncthreads`), `__shared__` arrays, warp functions and
cooperative groups. An entry point that uses them is `cuda gpu-only` in `cuda/kernels.txt` and
sits under `#if !defined(SILLAGE_CPU)`. The CPU target is for correctness on small inputs, never
for speed.

An entry point does what Metal's dispatch does for the kernel: it works out the thread's
position from the block and thread indices, and since a CUDA grid is whole blocks where
`dispatchThreads` gives exactly the count asked, **it lets no thread at or past the count
through**:

```
namespace metal {
namespace GPUTreeShaders {
__global__ void gtGather(float4 *sorted, const float3 *positions, const float *mass,
                         const uint *order, TreeParams p) {
    treeGather(sorted, positions, mass, order, p, blockIdx.x * blockDim.x + threadIdx.x);
}
}
}
```

`cuda/build.sh` builds `cuda/src` and `cuda/tests` both ways: with `nvcc` for sm_120 (the RTX
5090), compile only, without FMA contraction or fast math until a file's Metal twin asks for
them, and it fails if a file's PTX holds a double precision instruction; then the CPU target
with `-O2 -ffp-contract=off -Wall -Wextra -Werror`, whose tests it runs. #273 builds the two
libraries the Swift links from the same files.

`cuda/tests/compat.cu` tests the two headers on the CPU target, 109 checks: the launch reaches
every thread of every block once, the atomics, the memory calls, the vector types and their
swizzles, the functions, and a few of the tree's shared functions run from their own MSL text
(the root cell and its frame, the Morton codes, the gather, both ways of `octantStarts`).
`cuda/tests/tree_probe.cu` only has `nvcc` generate device code for the tree's 20 shared
functions, so that their PTX is read too; #273 replaces it with the real entry points.
`cuda/spike/` is #271's throwaway, with two early headers of its own: `cuda/include` replaces
them, and nothing new includes the spike's.

## `cuda/kernels.txt`

One line for each Metal `kernel`, `vertex` and `fragment` function: `<library> <function>
<state>`.

| state | meaning |
| --- | --- |
| `cuda` | its entry point, `__global__ void <function>(` on one line, is in `cuda/src` and runs on the CPU target too |
| `cuda gpu-only` | it is in `cuda/src` but uses block barriers or warp functions: it runs only on a GPU, first in #283 |
| `pending #<issue>` | that issue writes it |
| `metal-only: <reason>` | the CUDA engine will not have it |

After #281: 62 functions, 59 pending (20 of the tree for #273, 8 of the massive solver for
#274, 3 of the tracers for #275, 20 particle passes for #276, 8 post-processing kernels for
#277) and 3 Metal only (`expandSnapshots`, `expandSnapshots21`, `integrate`). Phase 1 is over
when no line is pending.

## The reference outputs

`Tests/Fixtures/engines/` holds small outputs both engines must give, under 2 MB in all: a 20 k
tree, the accelerations of 1,000 tracers from a small `--dump-walk` (#271), and three 256 x 144
frames in three looks. The README beside them gives their formats, which a C++ reader needs no
Swift for.

- **On the Mac**, the tests require Metal to give them on every `./scripts/dev.sh check`, to the
  bit where Metal is deterministic.
- **On Linux**, from #273 on, the CPU target compares what it can run with them on every check,
  within a stated tolerance: two float machines agree to rounding on one force evaluation or one
  frame, not to the bit.
- **On a GPU**, #283's `scripts/gpu-box.sh setup` runs the whole comparison first thing on every
  box, so a full pass never starts on an engine that drifted.

`./scripts/dev.sh fixtures` regenerates them on the Mac. A PR that changes them on purpose
regenerates them and says so in its description; a PR that changes them without meaning to has
found a bug.

## What catches what

**On the Mac, in every `./scripts/dev.sh check`**, with `clang++` and no CUDA
(`scripts/kernel-check.sh`, also `./scripts/dev.sh kernels`, about a second):

- a float literal without its suffix, anywhere in the MSL, with the Swift file and line;
- shared MSL that is not C++17: a texture, an attribute, a half literal, a function
  `msl_compat.h` lacks, slipped outside `#if defined(__METAL_VERSION__)`, fails on the Mac and
  not on a rented box. Implicit conversions between float and double are errors there;
- a Metal function missing from `cuda/kernels.txt`, a line for a function that is gone, a
  function marked `cuda` without its entry point, a state that is not one;
- an MSL struct that changed size without its `SILLAGE_STRUCT` line, and a Swift mirror that no
  longer has that size (`KernelSourceTests`);
- a library's `source` that is no longer one plain string;
- Metal no longer giving the reference outputs;
- from #273 on, CUDA Swift that no longer typechecks against `cuda/include/sillage_cuda.h`, so a
  pass the CUDA engine does not handle.

**On GitHub, on every push** (`.github/workflows/linux.yml`, [no-ci.md](no-ci.md)):

- the same checks with `clang++` and `g++`;
- `nvcc` 13.5 compiles `cuda/src` and `cuda/tests` for sm_120: what C++ takes and CUDA does
  not, such as a shared function without `SHARED`, or a host function called from device code;
- no double precision instruction in the PTX;
- the CPU target builds without a warning and its tests pass, with `g++` and `clang++`;
- from #272 on, the portable Swift builds and passes its tests on Linux.

**Only on a GPU** (#283): anything with block barriers or warp functions, so the tree and the
sort; the big sizes; every timing; and the comparison of the reference outputs on CUDA, first
thing on every box.

## Why Swift and Metal stay

Pierre asked on 2026-11-10 whether to drop Metal and write the engine once in C++. No:

- **Metal is the only way to the Mac's GPU**, and CUDA does not run there. The Mac keeps
  exploring, styling and running the app; a second engine is needed whatever the first is
  written in.
- **The host language does not set the speed.** 98 to 99 % of a step is spent in the kernels
  ([solver-language.md](solver-language.md)); Swift only encodes them and waits.
- **The kernels are already written once**, in MSL, a C++ dialect that `nvcc` compiles through
  `msl_compat.h`. Nothing of their arithmetic is ported.
- **The Swift that plans, frames and records runs on Linux too** (#272), so both engines share
  it. A C++ host would rewrite it, about 51,000 lines of Swift with the app, and that rewrite
  would be the copy that drifts.

## What #281 measured

- **Float literals.** 593 literals on 344 lines of four libraries took their `f`
  (`BarnesHutShaders` 61, `GPUTreeShaders` 9, `Shaders` 520, `SolverShaders` 3). Each of the 146
  distinct values rounds to the same float read straight as a float and read as a double then
  narrowed, checked exactly, so Metal gives the same bits whichever way it reads them. The
  tracer walk of #271, compiled for sm_120, goes from 26 double precision instructions to none,
  with the same 40 registers and 128 byte stack frame.
- **The tree as CUDA.** The 20 shared functions of `GPUTreeShaders` compile for sm_120 with
  `nvcc` 13.5 through `msl_compat.h`, no line of them written for it: no double precision
  instruction, and the warp shuffles, ballots, barriers and atomics where Metal has its SIMD
  functions, barriers and atomics. They run first on a GPU in #283.
- **The other libraries, tried ahead.** With its guard lifted and its 11 kernels taken as plain
  functions, the whole of `BarnesHutShaders` already compiles as C++17 through `msl_compat.h`,
  no line changed. Of `Shaders`, the same trial refuses only what Metal alone has: the textures
  and samplers, `discard_fragment`, and 31 half literals. So #274 to #277 move code, they do not
  port it.
- **`inline` became `static` on Metal** for seven helpers of the tree (`bhRange`,
  `bhSignedCount`, `orderedFloat`, `unorderedFloat`, `spread`, `sameDigit`, `octantStarts`),
  all integer work, where it cannot change a result.

## Installing `nvcc` in a cloud session

The compiler and the runtime headers only, CUDA 13.5 from NVIDIA's apt repository, as the
workflow does:

```
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
sudo dpkg -i cuda-keyring_1.1-1_all.deb && sudo apt-get update
sudo apt-get install -y --no-install-recommends cuda-nvcc-13-5 cuda-cudart-dev-13-5
```

Where a session may not install packages, the same compiler runs unpacked: read the repository's
`Packages` index, download `cuda-nvcc-13-5`, `cuda-cudart-dev-13-5` and what they depend on
there (12 packages, 89 MB), check their SHA-256 against the index, `dpkg-deb -x` each into one
directory, and point `NVCC` at `usr/local/cuda-13.5/bin/nvcc` in it.
