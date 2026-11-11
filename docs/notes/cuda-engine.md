# The CUDA engine (#273)

The hires engine's CUDA twin for rented NVIDIA GPUs (#269), written and tested without one in
phase 1. #273 laid the frame the next steps build in: the C API, the Swift module over it, the
build for the GPU and for the CPU target, and the tree builder, the first engine in it. How a
kernel's text is shared with Metal is in [one-kernel-source.md](one-kernel-source.md); this note
is how the CUDA side around it is built, run and tested.

## Layout

| where | what |
| --- | --- |
| `cuda/include/sillage_cuda.h` | the C API: statuses and errors, contexts, buffers, pinned memory; includes one header a domain at its end |
| `cuda/include/sillage_cuda_tree.h` | the tree builder's calls |
| `cuda/include/module.modulemap` | the C API as the Swift module `CSillageCUDA` |
| `cuda/src/engine.h` | what the files of `cuda/src` share behind the API: `sc_context`, `sc_buffer`, `fail`, `check`, `allocate`, `pointer` |
| `cuda/src/context.cu` | errors, contexts, buffers and pinned memory |
| `cuda/src/tree.cu` | the 20 tree entry points, their launches and the tree's calls |
| `cuda/src/kernels.cu` | every library's MSL in one unit, for the checks (#281) |
| `cuda/tests/*.cu` | the C tests of the CPU target (`compat`, `tree_fixture`, `tree_entries`) |
| `Sources/SillageCUDA/` | the Swift: `CUDAContext` and `CUDAError`, `CUDABuffer` and `CUDAHostMemory`, `CUDATreeBuilder` |
| `Tests/SillageCUDATests/` | the Swift tests, run on Linux |

**A new domain** (#274's solver, #276's renderer) takes files of its own, so that two tickets
working at once meet on one line each: `cuda/include/sillage_cuda_<domain>.h`, included at the
end of `sillage_cuda.h`; `cuda/src/<domain>.cu`; `Sources/SillageCUDA/CUDA<Domain>.swift`;
`Tests/SillageCUDATests/CUDA<Domain>Tests.swift`; its lines in `cuda/kernels.txt`, which are
already apart by library. Nothing else needs to change: `cuda/build.sh` and `scripts/linux.sh`
take every `cuda/src/*.cu` and every Swift file of the module and its tests.

## The C API

- **Plain C**, so that Swift imports it as it is and no C++ type crosses it. Handles are opaque
  (`sc_context`, `sc_buffer`, `sc_tree`); every call is `sc_<domain>_<verb>`.
- **Nothing is thrown.** A call returns an `sc_status`: `SC_OK`, `SC_INVALID_ARGUMENT`,
  `SC_OUT_OF_MEMORY`, `SC_NO_DEVICE`, `SC_CUDA_ERROR` (the runtime's error, named in the
  message) or `SC_GPU_ONLY` (the CPU target cannot run it). The message of the last failure on
  the calling thread is `sc_last_error()`. In Swift every failure is a `CUDAError` with a
  `code` and that message.
- **A context a device.** Work goes to the device's default stream, in the order it is asked;
  a call returns once its work is queued, and a download waits for it.
  `sc_context_synchronize` (`CUDAContext.synchronize()`) waits for everything and reports an
  error a kernel left behind. Several streams can come with several GPUs (#280).
- **Buffers** are device memory, zeroed when made as Metal's are, never empty underneath (a
  kernel may be handed one it does not read), with lengths and offsets in bytes. Uploads,
  downloads, fills and copies check their range and refuse what does not fit. A buffer an engine
  owns, such as the tree's nodes, reaches Swift as a borrowed `CUDABuffer` its owner frees.
- **Pinned host memory** (`CUDAHostMemory`) for the large transfers of the next steps.
- **Swift sees no C type.** `SillageCUDA` imports `CSillageCUDA` with `internal import`, so the
  command and the next modules use Swift types only.

## What an entry point does, and what the shared MSL does

The shared MSL does the work, all of it: the arithmetic, the loops over a level or a node, the
barriers, the warp functions, the atomics. A CUDA entry point, of the Metal kernel's name, only
gives the shared function what Metal's attributes give it:

| Metal | CUDA entry point |
| --- | --- |
| `thread_position_in_grid` | `blockIdx.x * blockDim.x + threadIdx.x` |
| `threads_per_grid` | `gridDim.x * blockDim.x` |
| `threadgroup_position_in_grid` | `blockIdx.x` |
| `thread_index_in_threadgroup` | `threadIdx.x` |
| `simdgroup_index_in_threadgroup`, `thread_index_in_simdgroup` | `threadIdx.x / 32`, `threadIdx.x % 32`: a warp is a SIMD group of 32 lanes |
| `simdgroups_per_threadgroup` | `blockDim.x / 32` |
| `threadgroup T name[n]` | `__shared__ T name[n]`, declared in the entry point |
| `constant T &p [[buffer(k)]]` | `T p`, by value |
| `device T *x [[buffer(k)]]` | `T *x` |

A launch goes through `SILLAGE_LAUNCH` and is checked with `cudaGetLastError` (`LAUNCH` in
`tree.cu`). `dispatchThreadgroups(groups, width)` is `<<<groups, width>>>`;
`dispatchThreads(count)` is `<<<ceil(count / width), width>>>`, and the shared function's own
`if (i >= p.count) return;` stops the threads a whole block adds past the count. The tree's
shapes are `GPUTreeBuilder.swift`'s:

| kernels | grid | block |
| --- | ---: | ---: |
| `gtReset`, `gtRoot`, `gtCloseLevel` | 1 | 32 |
| `gtBounds` | 512 | 256 |
| `gtMorton`, `gtGather` | count / 256 | 256 |
| `gtRadixCount`, `gtRadixScatter` | tiles of 2,048 keys | 256 |
| `gtScanReduce`, `gtScanDown` | blocks of 1,024 table entries | 256 |
| `gtScanTop` | 1 | 1,024 |
| `gtSplit`, `gtLeafSums`, `gtFold`, `gtNormalize`, `gtFoldMoments`, `gtSmoothing`, `gtSpacing*` | 1,024 | 256 |

Eight radix passes of eight bits, ping-ponging between the codes and a spare; one split and one
level closed a depth; the folds from the deepest level up. A tree that runs out of nodes raises
its flag, the mass passes stop, `sc_tree_grow` doubles the node buffers and the build runs
again, as on Metal.

**No FMA contraction** anywhere in `cuda/src`: `--fmad=false` for `nvcc`, `-ffp-contract=off` for
the CPU target, as Metal builds the tree with `mathMode = .safe`. The tree's PTX holds no fused
multiply-add but the ones inside CUDA's own `powf`, which the smoothing lengths call and which
the tolerance on lengths already covers. A later file whose Metal twin contracts would say so in
its own flags.

## Building

```
cuda/build.sh [gpu] [cpu] [libs]
```

- `gpu`: every file of `cuda/src` and `cuda/tests` with `nvcc` for sm_120, compile only, and
  no double precision instruction in the PTX (#281).
- `cpu`: `cuda/src` with a host compiler through `cuda_cpu.h` (`-O2 -ffp-contract=off -fPIC
  -Wall -Wextra -Werror`) into `.build/cuda/lib/libsillagecuda_cpu.a`, then every C test linked
  against it and run.
- `libs`: the two libraries the Swift links, in `.build/cuda/lib`, from every file of `cuda/src`
  but `kernels.cu`, which defines nothing: `libsillagecuda_cpu.a`, and,
  where `nvcc` is, `libsillagecuda.a` for sm_86 (RTX 30 series, A40), sm_89 (RTX 4090, L40S)
  and sm_120 (RTX 5090) with PTX for what comes after (`-std=c++17 -O3 --fmad=false`). CUDA 12.8
  or later, for sm_120; the build refuses an older one. An A100 (8.0) would need sm_80 added,
  which nothing plans ([gpu-rental.md](gpu-rental.md)).

`NVCC`, `CXX` and `CUDA_OUT` choose the compilers and the output. Installing `nvcc` is in
[one-kernel-source.md](one-kernel-source.md); this ticket's session ran it unpacked from the
packages, as that note describes for a session that may not install them.

`scripts/linux.sh` runs `cuda/build.sh libs`, builds `SillageCUDA` (`libSillageCUDA.so`) over
`SillageCore`, and adds `Tests/SillageCUDATests` to the tests (`scripts/linux.sh test-cuda` runs
them alone). It links the GPU library when it
was built and `nvidia-smi` lists a GPU, the CPU one otherwise, and says which;
`SILLAGE_CUDA_TARGET=gpu` or `cpu` chooses. The CUDA runtime goes in statically
(`cudart_static`), so a box needs only its driver.

On the Mac, `./scripts/dev.sh check` (also `./scripts/dev.sh cuda`) typechecks `SillageCUDA`,
strict concurrency included, and its tests against `sillage_cuda.h`, plain C, with no CUDA and
no library; `scripts/kernel-check.sh` compiles every file of `cuda/src` against the shared MSL.
A shared function whose signature changes, or a C call the Swift no longer matches, fails there.

The GitHub workflow runs `cuda/build.sh gpu libs` with `nvcc` 13.5 in its `cuda` job, and the
CPU target's C tests with `g++` and `clang++`; its `swift-checks` job runs the Swift tests of the
CPU target with the formatter and the typecheck (`scripts/linux.sh lint strict test-cuda`),
where there is no `nvcc` and the CPU library is linked ([no-ci.md](no-ci.md)).

## The CPU target

The same files built by a host compiler, through `cuda_cpu.h`: a launch is a loop over the blocks
and their threads, one thread after another, so it is exact on small inputs and never fast. Its
launch keeps the thread's position in `thread_local` variables, so the Swift tests, which run in
parallel, can launch from several threads at once.

**What it cannot run**: block barriers and warp functions. Of the tree's 20 kernels, 7 use them
and are `cuda gpu-only` in `cuda/kernels.txt`: `gtBounds`, the radix sort's five
(`gtRadixCount`, `gtScanReduce`, `gtScanTop`, `gtScanDown`, `gtRadixScatter`) and `gtSplit`.
They sit under `#if !defined(SILLAGE_CPU)`, and the phases that need them (bounds, sort, nodes)
return `SC_GPU_ONLY` there. The 13 others are `cuda`: they run on both.

**Its tree.** In place of those seven, `CUDATreeBuilder` builds the CPU's own `BarnesHutTree`
over the positions and lays it out with `sc_tree_upload`, as the cells phases leave a GPU build:
its cells in the level order (`BarnesHutTree.levelOrdered`) with no mass yet, their level starts
(`BarnesHutTree.levelStarts`), its order, and the frame its codes were taken in
(`BarnesHutTree.frame`), the counters set as a build sets them. The masses, the moments, the
smoothing lengths and the spacing records then come from the CUDA entry points, the shared MSL
run on the CPU, so the next steps can run their own kernels over a real tree. A tree of more
nodes than the capacity raises the overflow flag, and the grow-and-build-again loop is the GPU's.
`sortOrder` (the light tracers' walk order) takes a `BarnesHutTree`'s order on the CPU target.

## Tests

**Now, in every Linux check and on every push**, on the CPU target:

- `cuda/tests/tree_entries.cu`, with `g++` and `clang++`: on the fixture tree of 20,000
  particles, `gtReset`, `gtRoot`, `gtMorton` and `gtCloseLevel` launched one by one (the frame
  and the order to the bit); through the C API over the fixture's cells, the masses, moments and
  levels to the bit, the lengths within 1e-6 and the spacing links to the bit, with a node
  capacity that fits and with one of 1,000 that has to grow twice; a build that needs the
  barriers refused with `SC_GPU_ONLY`, a second device refused, an upload past a buffer's end
  refused.
- `CUDA context` (5 tests): the target and its device, a device that is not there, buffers
  zeroed, uploaded, downloaded, filled and copied, ranges refused with their message, an empty
  buffer, pinned memory both ways.
- `CUDA tree` (13 tests run here): the tree equal to `BarnesHutTree` through
  `BarnesHutTree.compare` (the comparison `GPUTreeBuilder` now reads its Metal buffers through)
  on `GPUTreeTests`' sets, 200 k disk and merged core, duplicates, 1, 17 and 2,049 particles,
  with and without quadrupoles; the merged core at the depth ceiling; the overflow path; a tree
  laid out with its masses by `sc_tree_upload`; the fixture tree (order, cells, masses, moments,
  frame and levels to the bit, lengths to 1e-6, spacing links to the bit), and the same lengths
  from the cells alone; the lengths and spacing records the CPU works out from its own tree, at
  100 k; a chunk's Morton order; the phases the CPU target leaves to a GPU, and its Morton codes.

**Written now, run on a GPU in #283**, each skipped on the CPU target with "needs an NVIDIA GPU
and libsillagecuda.a: #283 runs it":

- `aMergerAtTheStart`: a 500 k merger at t = 0, sampled on the box (`RestrictedSolver`): the
  tree to the bit, and the lengths and spacing records against the CPU's.
- `aMergerAfter200Steps`: the same merger 200 steps in, read from a take of a Metal run named
  by `SILLAGE_CUDA_TREE_TAKE` (its last frame, so no CUDA solver is needed); written on the Mac
  and shipped with the box's data.
- `theMassiveParticlesOfADump`: the 5 M massive particles of #283's 8 M walk dump,
  `massive.bin` of the folder named by `SILLAGE_CUDA_TREE_DUMP`
  ([cuda-walk-spike.md](cuda-walk-spike.md)).
- `theBuildIsTimed`: the build at 2 M and 5 M, the median of ten after a first one, printed on a
  `CUDATREE` line against 11 ms on the M4 Max at 5 M ([gpu-tree.md](gpu-tree.md)); positions from
  the dump when it holds enough, sampled otherwise.

And on a GPU, the tests of the first list run through the real kernels: the 20 entry points,
the radix sort and the split, on the same sets, the fixture tree and the overflow path. #283
runs `scripts/linux.sh check` on the box first, with both variables set.

## What #273 measured

- **`nvcc` 13.5 compiles it all at once**: the 20 entry points and the C API, for sm_120 with no
  double precision instruction, and the library for sm_86, sm_89 and sm_120 with PTX, about 20
  seconds of compiling here. The PTX has the barriers, shuffles, ballots and atomics where Metal
  has its barriers, SIMD functions and atomics (`gtScanTop` 9 barriers and 30 shuffles,
  `gtRadixCount` 2 barriers and 18 ballots, `gtSplit` 12 shuffles and 17 atomics).
- **No line of the tree's MSL changed**, and nothing went into `msl_compat.h`: the entry points
  compile against the shared functions as #281 left them.
- **On the CPU target the 13 kernels give Metal's bits** on the fixture tree, lengths aside
  (none past 1e-6), with `g++` 13.3 and `clang++` 18.1.
- **The Swift tests of the CPU target take about two seconds.** With the GPU library and no
  driver, every call returns `SC_NO_DEVICE` or `SC_CUDA_ERROR` with the runtime's message, and
  nothing crashes.

## The renderer's particle passes (#276)

What `Renderer` draws with Metal's rasteriser into its supersampled light and dust, before any
post-processing, drawn by compute kernels. #277 turns the two targets into a picture; #278
draws a full pass with it.

| where | what |
| --- | --- |
| `Sources/SillageRender/Shaders.swift` | the shared per-particle and per-pixel functions, and Metal's thin `vertex` and `fragment` functions |
| `Sources/SillageRender/FramePlan.swift` | `FramePlan`, the passes of a frame and their uniforms, for both renderers; `SplatUniforms` |
| `Sources/SillageRender/ParticleAttributes.swift` | the 28 bytes a massive particle carries, and the field stars |
| `cuda/include/sillage_cuda_render.h` | the renderer's calls |
| `cuda/include/msl_texture.h` | a texture read by hand: `texels2d` and its filters |
| `cuda/src/render.cu` | the 13 entry points of the passes, the walk over a point's pixels, the accumulation, the launches |
| `cuda/tests/render_passes.cu` | the C test of the CPU target |
| `Sources/SillageCUDA/CUDARenderer.swift` | the Swift renderer, which executes the frame plan |
| `Sources/SillageCUDA/CUDARenderChecks.swift` | the measures #283 makes on a box |
| `Tests/SillageCUDATests/CUDARenderTests.swift` | the Swift tests |

### What is shared, and what a kernel does

Metal draws a particle as a point: a vertex function says where it lands, how wide, and what
it carries; the rasteriser covers the pixels of its square; a fragment function says what each
pixel takes; the target blends it in. CUDA has no rasteriser, so a kernel does a pass, a thread
a particle:

1. it calls the **shared per-particle function** (`massiveSplat`, `tracerSplat`,
   `starfieldSplat`, `massiveDustWeb`, `massiveWebCarrier`, `countPoint`, `plainPoint` and
   their tracer twins), which returns a plain struct (`Splat`, `WebCarrier`, `CountPoint`,
   `PlainPoint`): the clip position, the point size, and what the pixels read;
2. it works out the point's square as the rasteriser does (`pointSquare`, below) and walks its
   pixels;
3. for each it calls `splatRadius2(coord)` and leaves the pixel alone past one, where Metal's
   fragment calls `discard_fragment`, then the **shared per-pixel function** (`dustPixel`,
   `lightPixel`, `starfieldPixel`, `webCarrierPixel` with `webTagPixel`, `countPixel`,
   `plainPixel`) and adds its value to the target.

The arithmetic of a splat is in `Shaders` alone. Metal's `vertex` functions copy the plain
struct into a stage struct that carries `[[position]]` and `[[point_size]]`; its `fragment`
functions take `point_coord`, discard, and call the same per-pixel function. `webResolveFragment`
is a thread a pixel of the frame, where Metal draws one triangle over it, and `bakeLace` a
thread a texel.

**A fragment discards first.** Metal compiles `Shaders` with fast math, and a fragment whose
shared function returned early with its value written through a reference gave other bytes
than main (up to 38 half float steps in the light of a star behind dust). The form that keeps
them: in the Metal fragment, the test and `discard_fragment()` first, then the shared function,
its value returned. The CUDA kernel makes the same test in the same place.

**A texture read in the middle of a shared function** goes through a type and a one-line
function each engine defines, side by side in the MSL: `ColumnDensity` with `columnRead`, and
`Lace` with `laceRead`. On Metal they are a `texture2d` and a `sample` with the sampler; on
CUDA a `texels2d` (float texels in device memory) and a filter of `msl_texture.h` written by
hand: `sample_bilinear` (linear, clamp to edge) for the column density, the carrier and, with
`sample_nearest`, the tags; `sample_anisotropic` (trilinear over the lace's levels, up to
eight taps along the footprint's long axis, repeat) for the lace. Metal's own filters are its
GPU's; how far the hand-written ones land from them is in the comparison below.

### The rasteriser's rules

`pointSquare` in `render.cu`, to be held to what the Mac's probe measured (below):

- a point whose centre is outside the clip volume (`-w <= x, y <= w`, `0 <= z <= w`) draws
  nothing;
- its size is held between 1 and 511 pixels;
- pixel centres sit at half integers, x to the right and y down, and the point covers the
  pixels whose centre is in the square of its size about its own: from
  `ceil(centre - size / 2 - 0.5)` to `ceil(centre + size / 2 - 0.5)`, the last left out;
- `point_coord` at a pixel is `(pixel + 0.5 - centre) / size + 0.5`.

### The frame plan

`FramePlan(settings:camera:time:drawnCount:tracerCount:luminosityNormalisation:mapped:laceScale:stages:first:)`
gives a frame's passes in order and their uniforms, from the look's settings and the camera,
with the expressions `Renderer.encodeSplat` had:

| pass | when | CUDA entry points |
| --- | --- | --- |
| `column` | `columnSmoothing > 0`, first part of the frame | `countVertex`, `countTracerVertex` |
| `webCarrier` | the web is drawn | `webCarrierVertex`, `webCarrierTracerVertex` |
| `starfield` | `starCount > 0`, first part | `starfieldVertex` |
| `dust` or `paintedDust` | stage 0, without or with the web | `splatVertex` and `splatTracerVertex`, or `dustWebVertex` and `dustWebTracerVertex` |
| `webResolve` | after `paintedDust` | `webResolveFragment` |
| `stars` | stage 1 | `splatVertex`, `splatTracerVertex` |
| `plain` | the raw look, alone | `plainVertex`, `plainTracerVertex` |

`Renderer` and `CUDARenderer` both execute `plan.passes` through a `switch` with no `default`:
a pass added to `FramePlan.Pass` stops both from compiling until they draw it, and the Mac's
typecheck of `SillageCUDA` says so there. `plan.uniforms(for:)` sets `SplatUniforms.pass`.
`stages` and `first` draw part of a frame into what earlier parts left, as
`Renderer.render(camera:slice:)` does.

`ParticleAttributes(particles)` makes what a renderer holds of each massive particle
(population, luminosity, component, galaxy, the two traits, the ramp key: 28 bytes), each
galaxy's scale length for the tracers, and the luminosity normalisation; `BackgroundStar.field`
the field stars; `GalaxyRamp.ramps(for:slots:)` the ramps of a palette; `RenderSettings.apply`
a look; `TakeFraming.moment` what `FramePreparing.prepare` sets. Both renderers call them, so
only the buffers are CUDA's.

### Accumulation

- **64-bit fixed point, 2^40 a unit.** A pixel of the light, the dust or the carrier is four
  unsigned 64-bit values. A value a pixel takes is rounded to the nearest 2^-40 (9e-13) and
  added with a compare-and-swap that stops at the ceiling rather than wrap. The sum of what
  every thread adds is the same in any order, so **a frame drawn twice is the same to the
  bit**, on a GPU as on the CPU target, whatever the number of threads. A pixel holds up to
  2^24 = 16.8 million, 256 times the 65,504 of Metal's half float target.
- **What is not laid**: a negative value and a value that is not a number add nothing. Every
  per-pixel function of `Shaders` gives non-negative values today.
- **The column pass counts**: one a particle, in 64-bit integers. Metal counts in a 32-bit
  float, which stops at 2^24 a cell; no cell is near it at 200 M drawn.
- **The tags** of the web's carrier take the largest value, as Metal's `max` blend, held as
  Metal's 8-bit target holds them.
- **Floats for the next pass.** A star reads the finished dust, a splat the column's cells, the
  resolve the carrier: `sc_render_begin` converts the fixed point a pass reads into floats
  once, after the passes that wrote it. `sc_render_finish` does it for the light and the dust,
  which is what #277 reads (`SC_RENDER_LIGHT`, `SC_RENDER_DUST_TARGET`: four floats a pixel,
  rows from the top).
- **Memory**: 96 bytes a supersampled pixel (the light and the dust as fixed point and as
  floats), 3.2 GB at 4K with supersampling 2, plus 85 MB for a lace of 4,096 texels. Metal
  holds 16. #283 measures whether the float copies should go.
- **Half floats, for the measure.** `CUDARenderer.halfFloats` accumulates as Metal's
  `rgba16Float` targets do, a half float a value blended one fragment after another. It
  depends on the order, and is there to measure what half floats lose (below).

### Large splats, two ways

- **The first way**: a particle's thread walks every pixel of its square. Most splats cover a
  few pixels; a close-up gives some hundreds, and their threads hold their whole warp back.
- **The second way** (`CUDARenderer.largeSplatPixels`, `sc_render_set_large`): a splat whose
  square covers more pixels than the threshold is set aside in a list (an atomic counter, the
  struct the shared function returned), and a second kernel (`largeSplats`, `largeCarriers`)
  draws the list a block a splat, its 256 threads sharing the pixels. A list that is full
  leaves the splat to its particle's thread. No block barrier and no shared memory, so it runs
  on the CPU target, and it lays the same bits as the first way: integer sums do not care
  which thread adds.

#283 times both on a wide shot and on a close one and keeps the faster.

### Tests

**Now, on the CPU target**, in every Linux check and on every push:

- `cuda/tests/render_passes.cu`, with `g++` and `clang++`: a star lays its whole kernel (its
  coverage against the kernel's integral over the point's disc, within 1 %); a frame of 6,000
  stars and grains drawn twice gives the same bits; the second way gives the first way's bits
  with room for its splats and with a list that fills; the calls the renderer refuses; the
  lace's last level is its mean.
- `CUDA renderer` (13 tests run here): a frame drawn twice, by another renderer, from five
  threads at once, in slices as `render(camera:slice:)` cuts it, and the second way at three
  thresholds: the same bits each time; a star's kernel; dust dims a star behind it and not one
  in front; the plain points; the web moves only the dust; the column counts what emits; light
  tracers draw like the particles they stand for; the passes of each kind of frame; a pixel
  saturates rather than wrap; half floats hold 11 bits and lose what falls under their smallest
  value; the two measures of #283 run small.

**Written now, run on a GPU in #283**, each skipped on the CPU target with "needs an NVIDIA GPU
and libsillagecuda.a: #283 runs it":

- `theFaintLightAt200MSurvivesTheAccumulation`: the sampler's starting positions at 200 M drawn
  from 50 M massive (`SILLAGE_CUDA_RENDER_COUNT` for another count), at 4K with supersampling 2,
  wide and close, accumulated in half floats and in fixed point: the light each keeps, decade by
  decade of pixel value, on `CUDARENDER` lines.
- `theParticlePassesAreTimed`: the particle passes at 4K at 8 M, 50 M and 200 M drawn, wide and
  close, both ways for large splats, the median of five frames after a first, against the line
  Metal's follow on the M4 Max (40 ms + 7.6 ns a particle a 4K frame, #239).
