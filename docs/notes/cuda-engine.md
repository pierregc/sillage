# The CUDA engine (#273)

The hires engine's CUDA twin for rented NVIDIA GPUs (#269), written and tested without one in
phase 1. #273 laid the frame the next steps build in: the C API, the Swift module over it, the
build for the GPU and for the CPU target, and the tree builder, the first engine in it. #274
added the solver of the massive particles, which has
[a section of its own](#the-massive-particles-solver-274), and #276 the renderer's particle
passes, [which have theirs](#the-renderers-particle-passes-276). How a kernel's text is shared
with Metal is in [one-kernel-source.md](one-kernel-source.md); this note is how the CUDA side
around it is built, run and tested.

## Layout

| where | what |
| --- | --- |
| `cuda/include/sillage_cuda.h` | the C API: statuses and errors, contexts, buffers, pinned memory; includes one header a domain at its end |
| `cuda/include/sillage_cuda_tree.h` | the tree builder's calls |
| `cuda/include/module.modulemap` | the C API as the Swift module `CSillageCUDA` |
| `cuda/src/engine.h` | what the files of `cuda/src` share behind the API: `sc_context`, `sc_buffer`, `fail`, `check`, `allocate`, `pointer` |
| `cuda/src/context.cu` | errors, contexts, buffers and pinned memory |
| `cuda/src/tree.cu` | the 20 tree entry points, their launches and the tree's calls |
| `cuda/include/sillage_cuda_solver.h`, `cuda/src/solver.cu` | the massive solver's calls, its 8 entry points and their launches (#274) |
| `cuda/include/sillage_cuda_render.h`, `cuda/src/render.cu` | the renderer's calls, the 13 entry points of its particle passes and their launches (#276) |
| `cuda/src/kernels.cu` | every library's MSL in one unit, for the checks (#281) |
| `cuda/tests/*.cu` | the C tests of the CPU target (`compat`, `tree_fixture`, `tree_entries`, `solver_fixture`, `render_passes`, `raster_probe`) |
| `Sources/SillageCUDA/` | the Swift: `CUDAContext` and `CUDAError`, `CUDABuffer` and `CUDAHostMemory`, `CUDATreeBuilder`, `CUDABarnesHutSolver`, `CUDARenderer` |
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
`SillageCore` and, since the solver shares its step with Metal's (#274), `SillageRender`, and adds `Tests/SillageCUDATests` to the tests (`scripts/linux.sh test-cuda` runs
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

## The massive particles' solver (#274)

`MetalBarnesHutSolver` without its light tracers, on CUDA: a scene's massive particles stepped as
the Mac steps them, with the analytic or live halos, the black holes, star formation, the cooling
disks and dissipation, saved and resumed to the bit. Nothing of it is a copy. The kernels are the
shared MSL of `BarnesHutShaders`; the order of a step and the CPU work around it are portable
Swift that both solvers run. #275 adds the light tracers to it, #278 steps it in the full pass.

| where | what |
| --- | --- |
| `Sources/SillageRender/BarnesHutShaders.swift` | the eight massive kernels' work in shared functions, the three tracer kernels still Metal's (#275) |
| `Sources/SillageRender/BarnesHutRecords.swift` | the Swift mirrors of the structs those kernels read |
| `Sources/SillageRender/BarnesHutHost.swift` | the solver's CPU side: counts, masses, black holes, centres, disk frames, cooling disks, pass parameters, settings, a checkpoint's state |
| `Sources/SillageRender/BarnesHutStep.swift` | the step, the seed of a new solver and the restart of a restored one; `BarnesHutPass`, `BarnesHutPasses` |
| `cuda/include/sillage_cuda_solver.h`, `cuda/src/solver.cu` | the eight CUDA entry points and a C call a pass |
| `Sources/SillageCUDA/CUDABarnesHutSolver.swift` | the CUDA solver: its buffers, and each pass run |
| `Sources/SillageRender/SolverCheck.swift`, `scripts/solver-compare.py` | the run two engines are compared by, and its scoring |

### One step, two engines

- **`BarnesHutPass`** is one pass of a step: `starFormation`, `tracerStarFormation`, `drift`,
  `gather`, `accelerations(slots)`, `holes`, `kick`, `dissipation(disks)`,
  `tracerStep(mode, pieces, disks)`. An engine runs a pass by switching over it with no
  `default`. **A pass added for Metal is a new case, and `CUDABarnesHutSolver` stops compiling
  until it runs it**, on the Mac too, where `./scripts/dev.sh check` typechecks `SillageCUDA`.
- **`BarnesHutStep`** holds the order, and nothing else decides it: `run` (formation, drift, the
  tree build with the CPU work it leaves room for, the cooling disks, the forces a piece of
  `forceChunk` slots at a time, then the holes, the kick and the dissipation with the last
  piece, then the tracers), `seed` (what a new solver starts from) and `restored` (what a
  solver read back from a checkpoint starts from). When a reused tree gathers, when the tracers
  sort and how the force pass is cut are decided there. **A pass moved in `BarnesHutStep` moves
  for both engines.**
- **`BarnesHutPasses`** is what an engine gives the step: `run(passes)` as one submission,
  `profile(phase, passes)` for the same timed, `buildTree(sortingTracers:meanwhile:profiled:)`,
  and where the CPU reads the massive positions and velocities. Metal encodes `run`'s passes
  into one command buffer, commits and waits, as it did; CUDA queues their launches.
- **`BarnesHutHost`** is the CPU side, moved out of `MetalBarnesHutSolver` as it was: the halo
  centres summed in double a block at a time (`updateHaloCenters`), the disk frames
  (`updateDiskFrames`, `tidalStress`), the cooling disks, the halo list, each pass's parameters,
  star formation's parameters and its draw, the black holes' bookkeeping, the momentum, and
  `SolverState`. It reads the positions through a pointer: Metal's unified memory, or CUDA's
  copy in pinned host memory. The solver's settings (`forceChunk`, `treeReuse`, `leafCapacity`,
  `maximumTreeDepth`, `quadrupole`, `frameSample`, the tidal bounds, the tracers' sort) are its
  statics, which `MetalBarnesHutSolver` forwards under the names they had.

On the Mac nothing changed: the same passes go into the same command buffers in the same order,
profiled or not, and the CPU work still runs between the tree build's commit and its wait.

### The kernels

`bhKickDrift`, `bhKick`, `bhDissipate`, `bhFormStars`, `bhGather`, `bhHolePull`, `bhHoleSettle`
and `bhAcceleration` are `cuda` in `cuda/kernels.txt`: none needs a block barrier or a warp
function, so all eight run on the CPU target. Their work is in `massiveKickDrift`,
`massiveKick`, `massiveDissipate`, `massiveFormStars`, `massiveGather`, `holePull`,
`holeSettle` and `massiveAcceleration`, with `bhWalk`, `halos`, `bhCool`, `hashUnit` and
`bhWriteChances` beside them.

- **The function constants** stay in the Metal part and reach the shared functions as
  arguments: `leafChances` for `massiveFormStars`, `quadrupole` and `opensHoldingCells` for
  `bhWalk` and `massiveAcceleration`. On CUDA they are template parameters of the entry points,
  `bhFormStars<leafChances>` and `bhAcceleration<quadrupole, opensHoldingCells>`: six
  instantiations, each specialised as Metal specialises a pipeline, launched through a function
  pointer the solver picks once.
- **The black holes' pull is the one kernel CUDA runs another way.** On Metal a thread takes a
  particle, sums the reactions over its SIMD group and then over its threadgroup behind a
  barrier (`holePull`). On CUDA a thread takes a block of 256 particles and adds their reactions
  in the particles' order (`holePullBlock`): no barrier, so it runs on the CPU target, and a
  fixed order, so a run repeats. Both call `holePair` for a hole's pull on a particle and its
  reaction, so the arithmetic is written once; both leave four sums a block in `partial`, which
  `holeSettle` adds in the blocks' order on one thread, on both engines.
- **Launches**: blocks of 256 threads over the massive particles or the tree's nodes, blocks of
  64 for the walk as on Metal (#283 times other widths), one thread for `bhHoleSettle`. The
  lists Metal binds as bytes (halos, holes, disks) are staged in small device buffers.
- **Built like the tree**, without FMA contraction or fast math (`--fmad=false`,
  `-ffp-contract=off`), where Metal builds this library with its default fast math. #283 can
  time what contraction buys the walk; a checkpoint written on one NVIDIA model resumes the
  same on another either way, since contraction is the compiler's choice and not the GPU's. The
  PTX holds 12 entry points, no barrier and no double precision instruction.

### The C API and `CUDABarnesHutSolver`

`sillage_cuda_solver.h` is a call a pass (`sc_solver_form_stars`, `_kick_drift`, `_gather`,
`_accelerations`, `_holes`, `_kick`, `_dissipate`) over buffers the caller owns. A pass takes
its parameters as the bytes of the struct the MSL reads (`BHParams`, `SFParams`) and its lists
as the bytes of their elements (`HaloGPU`, `HoleGPU`, `DiskCooling`), which Swift fills as it
fills Metal's; a size other than the MSL's is refused, and `KernelSourceTests` holds the Swift
mirrors to the sizes `cuda/src/kernels.cu` asserts.

`CUDABarnesHutSolver` conforms to `Solver` and `BarnesHutPasses`. What the hires loop reads of
it: `positions` and `formation` (device buffers), `centers`, `diskFrames`, `time`, and
`writeSmoothing(into:drawn:)` from its own tree.

- **The CPU work overlaps the build.** `buildTree` copies the massive positions, and the
  velocities when a disk cools, to pinned host memory once the drift has landed, queues the tree
  build, and runs the shared CPU work on the copy while the device builds.
- **Errors.** A pass cannot throw through the shared step, so the solver keeps the first
  `CUDAError` in `failure` and runs nothing after it; `advance(steps:)` steps and throws it.
- **Checkpoints** are the Metal solver's files (#240): `state` is the host's `SolverState`,
  `writeParticles(to:)` downloads and writes the positions, the velocities and the formation
  times 256 MB at a time, `restore(_:from:)` reads them back, takes the counters and runs
  `BarnesHutStep.restored`.
- **Deterministic.** No float atomic feeds the motion: the only sums over particles on the
  device are the holes' reactions, added a block at a time and the blocks in a fixed order. The
  halo centres are summed in double in fixed blocks on the CPU. No fast math.
- **The massive set.** A sample drawn on Linux is the Mac's to rounding and not to the bit
  ([linux-build.md](linux-build.md)), so a run compared with Metal, and the full pass (#278),
  read the massive particles the Mac sampled, `massive.bin` (`RunCheckpoint.massiveSet()`).
  `init(context:scene:)` samples here, for tests and timings.
- **The light tracers (#275)** come in front of the massive particles in `positions` and
  `velocities`, as on Metal: `sc_solver_config.first` and `leaf_chances` are there for them,
  and the three passes this solver leaves empty are `tracerStarFormation`, `tracerStep` and the
  tracers' half of `drift`.

### On the CPU target

The whole step runs, slowly: the tree is the CPU's `BarnesHutTree` laid out by `sc_tree_upload`,
now with its sorted Morton codes, which the walk reads to open the cells around a particle. A
tree kernel that strides over the nodes gives each node to one thread whatever the grid, so the
CPU target launches one block of them where a GPU launches 1,024: the same nodes to the bit, and
a step of 20,000 particles went from 168 ms to 52.
A step of scene-0031 at 20 k, 49,999 particles with their live halos, takes 0.21 s there: 2,000
steps in seven minutes.

### Tests

**Now, in every Linux check and on every push**, on the CPU target (16 s for the three CUDA
suites):

- `cuda/tests/solver_fixture.cu`, with `g++` and `clang++`: `bhWalk` and `halos` from the MSL
  text over the walk fixture of #281, 1,000 tracers through a tree of 5,012 massive particles.
  No acceleration past 1e-5 of Metal's, the furthest 1.63e-6 away, 42 with Metal's bits.
- `CUDA solver` (7 tests run here): accelerations against direct summation at 2,000, 3,000 and
  20,000 to the tolerance `accelerationMatchesDirectSummation` holds the Metal solver to (mean
  under 2 %, worst under 15 % at an opening angle of 0.4); a black hole's pull on every particle
  and its reaction, as `aBlackHolePullsDirectlyAndTakesTheReaction`; 200 steps of a merger of
  20,000 with star formation, two cooling disks and dissipation, twice, the same bits, and
  stopped at step 100, saved and resumed in a solver that samples nothing, the same bits at
  step 200; the force pass in pieces of 700 slots, and every pass profiled, the same bits, over
  live halos; a tree reused for two steps, gathered in between, within 0.05 kpc after 20 steps;
  the smoothing lengths from the solver's own tree; a checkpoint of another size or cut short
  refused; a solver check's run written and read back.

**Written now, run on a GPU in #283**, each skipped on the CPU target with "needs an NVIDIA GPU
and libsillagecuda.a: #283 runs it":

- `accelerationMatchesDirectSummationAt500k`: direct summation at 500 k, over the tree its own
  kernels build.
- `aMergerOf500kRepeatsToTheBitAndResumesFromItsCheckpoint`: 200 k drawn and 300 k of live
  halos, 200 steps twice and resumed from step 100.
- `aStepIsTimed` at 2 M and 5 M massive particles: the mean of ten steps, phase by phase, on a
  `CUDASOLVER` line, to set against the M4 Max.

And on a GPU the tests of the first list run through the real tree, the radix sort and the split
among them. One test waits for data instead of a GPU: `aRunStaysWithinWhatChaosPartsTwoMetalRunsBy`
is skipped without the Metal runs of branch `assets/cuda-checks` (below), and #283 runs it on
its box with them, at 20 k and at 500 k.

### Against Metal

Two float machines do not follow a chaotic system to the bit, so the CUDA solver is held to
rounding on one force evaluation, and along a run to how far Metal parts from itself when a
position differs by its last bit.

**The run.** Scene-0031 of 2026-10-30-b at 20 k as a hires steps it: 49,999 particles, 20,000
drawn and 29,999 of the two live halos, step 0.042 (0.198 Myr), opening angle 0.9, quadrupole
on, two cooling disks, 2,000 steps to 395.6 Myr, through the first pericentre (308.6 Myr). The
Mac sampled it once, `massive.bin`, and both engines read that file. Linux builds the same
`SceneConfig` from `scene.json`, with the Mac's step, softening and opening angle to the bit.
The Mac ran Metal over it (identical to the byte twice over), then four more times from positions
a last bit away: one particle moved, three times over (the first drawn, the last drawn, the last
of the halo), and every particle moved. Its runs are on `assets/cuda-checks` (6c74570),
`docs/spikes/cuda-checks/solver/`, with their formats. The CUDA run is the CPU target's.

**One force evaluation**, on the positions of `massive.bin`: the accelerations are within
7.7e-8 of Metal's in the median, 2.4e-7 at the 99th percentile and 2.7e-6 at most, 4.7 % of them
with the same bits. Metal moved by one bit everywhere is 2e-7, 2.4e-6 and 2.1e-5 from itself.

**Particle by particle**, the distance between the two runs' positions of the drawn particles,
in kpc (median, 99th percentile, largest):

| step | CUDA against Metal | Metal, one particle a bit away | Metal, every particle a bit away |
| ---: | --- | --- | --- |
| 1 | 0, 1.5e-8, 3.8e-6 | 0, 0, 9.5e-7 | 1.9e-6, 3.8e-6, 7.6e-6 |
| 10 | 0, 1.9e-6, 5.4e-6 | 0, 0, 9.5e-7 | 1.9e-6, 4.3e-6, 2.4e-5 |
| 100 | 2.4e-7, 7.6e-6, 1.5e-4 | 0, 0, 9.5e-7 | 4.3e-6, 7.3e-5, 5.6e-4 |
| 1,000 | 3.3e-4, 3.2e-3, 0.021 | 1.5e-4, 1.3e-3, 6.9e-3 | 6.3e-4, 5.5e-3, 0.022 |
| 2,000 | 8.1e-3, 0.17, 1.41 | 4.7e-3, 0.086, 0.69 | 0.014, 0.28, 1.45 |

After one step more than half the particles still sit where Metal put them, to the bit. From
there the CUDA run parts from Metal as a Metal run does: further than one particle moved by a
bit, which stays alone for a hundred steps, and less far than every particle moved by a bit.

**Along the run**, the most each measure reaches over the 2,000 steps:

| measure | CUDA against Metal | Metal against itself, the widest of the four |
| --- | ---: | ---: |
| centre of galaxy 0, kpc | 0.0184 | 0.0206 |
| centre of galaxy 1, kpc | 0.0187 | 0.0147 |
| thickness of disk 0 | 1.04e-4 | 9.5e-5 |
| thickness of disk 1 | 1.23e-4 | 9.3e-5 |
| axis of disk 0, degrees | 0.0189 | 0.0188 |
| axis of disk 1, degrees | 0.0182 | 0.0251 |
| momentum | 7.8e-4 | 8.3e-4 |
| centre of mass, kpc | 9.8e-5 | 1.4e-4 |
| stars formed | 3 (141 against 138) | 3 |
| density maps, chi-square a cell, 4 x 4 | 0.0057 | 0.0122 |
| density maps, chi-square a cell, 8 x 8 | 0.0018 | 0.0033 |
| stars elsewhere, % | 1.75 | 2.94 |

The centres travel 50 and 63 kpc, the thickness goes from 0.02 to 0.28 and the momentum from
2.1 to 2.7 in those units, and a chi-square of 1 is two independent draws of one distribution.
**The CUDA run stays within what chaos alone gives.** Four measures pass the widest of four
Metal runs, by 0.3 % to 32 % (a centre, both thicknesses, an axis): four draws do not bound a
fifth, and the test allows three times the widest.

**To run it again**, on Linux, with the Mac's folder checked out from `assets/cuda-checks`:

```
SILLAGE_CUDA_CHECKS=<folder> SILLAGE_CUDA_CHECKS_OUT=<out> scripts/linux.sh test-cuda \
    --filter aRunStaysWithinWhatChaosPartsTwoMetalRunsBy
cd <folder> && python3 <repository>/scripts/solver-compare.py metal \
    --scale metal-bit-a metal-bit-b metal-bit-c metal-bit-all --test <out>/cuda-cpu
```

The test writes the CUDA run in the Mac's format (`SolverCheck`), holds the accelerations of step
0 to rounding and the measures above to three times the widest Metal run, and prints them on
`CUDASOLVER` lines; the script prints every measure along the run. The Metal side is written by
`SILLAGE_SOLVER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter SolverCheckTests` on the Mac,
at `SILLAGE_SOLVER_CHECK_PARTICLES` drawn (20,000) for `SILLAGE_SOLVER_CHECK_STEPS` (2,000).

### What #274 measured

- **Metal is the same to the bit.** After the kernels were shared, and again after the step and
  the CPU work moved out of `MetalBarnesHutSolver`, the Mac's check passed with the same 605
  tests, a short hires of scene-0031 (200 k drawn from 50 k massive) gave its 26 files to the
  byte, and so did a Metal run of 2,000 steps at 20 k with its checkpoints and accelerations.
  Scene-0031 has no black hole, and `holePair` rewrote the one place a hole pulls: a black hole
  pass at 12,000, alone and with light tracers, gave main's particles, state and accelerations
  to the byte at seven steps up to 1,200. `aBlackHolePassKeepsItsBits` now holds that run to
  its digests in every check on the Mac, on the GPU they were taken on.
- **The massive kernels compile for CUDA as they are**: 12 entry points for sm_120, no barrier,
  no double precision instruction.
- **The CPU target repeats itself and resumes to the bit** over 200 steps of a merger of 20,000.
- **A scene built on Linux has the Mac's step, softening and opening angle to the bit** at 20 k,
  though its sample does not (#272).

## The renderer's particle passes (#276)

What `Renderer` draws with Metal's rasteriser into its supersampled light and dust, before any
post-processing, drawn by compute kernels. #277 turns the two targets into a picture; #278
draws a full pass with it.

| where | what |
| --- | --- |
| `Sources/SillageRender/Shaders.swift` | the shared per-particle and per-pixel functions, and Metal's thin `vertex` and `fragment` functions |
| `Sources/SillageRender/FramePlan.swift` | `FramePlan`, the passes of a frame and their uniforms, for both renderers; `SplatUniforms` |
| `Sources/SillageRender/ParticleAttributes.swift` | the 28 bytes a massive particle carries, and the field stars |
| `Sources/SillageRender/ParticleTargets.swift` | what Metal's particle passes left and drew from, as `export --dump-targets` writes it and the comparison reads it |
| `cuda/include/sillage_cuda_render.h` | the renderer's calls |
| `cuda/include/msl_texture.h` | a texture read by hand: `texels2d` and its filters |
| `cuda/src/render.cu` | the 13 entry points of the passes, the walk over a point's pixels, the accumulation, the launches |
| `cuda/src/raster.h` | the pixels a point covers and `point_coord` at each, by Metal's rules |
| `cuda/tests/render_passes.cu`, `raster_probe.cu` | the C tests of the CPU target |
| `Tests/Fixtures/engines/raster/probe.txt` | what Metal's rasteriser did with 131 points |
| `Sources/SillageCUDA/CUDARenderer.swift` | the Swift renderer, which executes the frame plan |
| `Sources/SillageCUDA/CUDARenderChecks.swift` | the comparison with Metal's dumped frames, and the measures #283 makes on a box |
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

A point's pixels are covered by hand, so the rules are Metal's own, read off its rasteriser.
The Mac drew one point at 131 clip positions and sizes into a 64 by 64 float target, its
fragment writing `point_coord` (`raster-probe.swift`, with its pictures on the
`assets/cuda-checks` branch). What the M4 Max does with a point of size `s` at clip position
`(x, y, z, w)` in a frame of `W` by `H` pixels, and `pointSquare` in `cuda/src/raster.h` after
it:

1. the point is dropped when `z < 0` or `z > w`, when `|x| > 1.5 w` or `|y| > 1.5 w` (its
   centre more than a quarter of the frame outside it), or when `s <= 0`. A centre outside the
   frame by less still draws the part of its square that is inside;
2. its size is held under 511 pixels, and a size under 1 is not raised;
3. it stands at `c = ((x / w + 1) W / 2, (1 - y / w) H / 2)`, pixel centres at half integers
   and y down, and its square runs from `c - s / 2` to `c + s / 2` with **each edge rounded to
   1/256 of a pixel**;
4. it covers the pixels whose centre is in that square, the first edge included and the last
   not;
5. `point_coord` at a pixel is `(its centre - the first edge) / span`, where the span is the
   square's side with its two edges **rounded to a sixteenth of a pixel** instead. At a size of
   1.3 the span is 1.25 or 1.3125 according to where the centre falls.

`Tests/Fixtures/engines/raster/probe.txt` holds the probe's 131 cases, and
`cuda/tests/raster_probe.cu` holds `pointSquare` to each on every push: how many pixels, which
columns and rows, and `point_coord` at the first and the last, within 1.2e-6. Another GPU's
rasteriser rounds otherwise; these rules are the M4 Max's, and the CUDA renderer follows them
on every machine so that its picture is Metal's.

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
- **The scale, from the largest values measured.** On the twelve frames below, at 200 k drawn
  in 960 by 540, the largest value a pixel holds on any channel is 909 in the light of a splat
  look (the core of a wide shot, where Metal's half float holds 854), 23.5 in the dust, and
  5,586 in the raw look, whose alpha counts the points on a pixel and stops at 2,048 on Metal.
  The exposure divides the colours by the count, so they stay there at any count; the alpha
  grows with it, to about a hundred thousand a pixel for the raw look in a 4K frame at 200 M.
  The ceiling is 160 times that. #283's faint light measure prints the largest value it meets
  at 200 M.
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
- `cuda/tests/raster_probe.cu`, with both compilers: the 131 points of Metal's probe, pixel
  for pixel.
- `CUDA renderer` (15 tests run here): a frame drawn twice, by another renderer, from five
  threads at once, in slices as `render(camera:slice:)` cuts it, and the second way at three
  thresholds: the same bits each time; a star's kernel; dust dims a star behind it and not one
  in front; the plain points; a palette's ramp; the web moves only the dust; the column counts
  what emits; light tracers draw like the particles they stand for; the passes of each kind of
  frame; a pixel saturates rather than wrap; half floats hold 11 bits and lose what falls under
  their smallest value; the two measures of #283 run small.
- `theParticlePassesAgreeWithMetal`, a sixteenth, when `SILLAGE_CUDA_RENDER_TARGETS` names the
  Mac's folder: the comparison below. The folder is 128 MB on an assets branch, so the push
  workflow does not fetch it; #277's reference frames bring the comparison into every check.

**Written now, run on a GPU in #283**, each skipped on the CPU target with "needs an NVIDIA GPU
and libsillagecuda.a: #283 runs it":

- `theParticlePassesAgreeWithMetalAt4K`: the comparison below at 4K with supersampling 2, from
  a take at 8 M drawn from 2 M massive. The Mac fills the folder with `export --dump-targets`
  at 3840 by 2160; it ships with the box's data and `SILLAGE_CUDA_RENDER_4K` names it.
- `theFaintLightAt200MSurvivesTheAccumulation`: the sampler's starting positions at 200 M drawn
  from 50 M massive (`SILLAGE_CUDA_RENDER_COUNT` for another count), at 4K with supersampling 2,
  wide and close, accumulated in half floats and in fixed point: the light each keeps, decade by
  decade of pixel value, on `CUDARENDER` lines.
- `theParticlePassesAreTimed`: the particle passes at 4K at 8 M, 50 M and 200 M drawn, wide and
  close, both ways for large splats, the median of five frames after a first, against the line
  Metal's follow on the M4 Max (40 ms + 7.6 ns a particle a 4K frame, #239).

### Against Metal

**Metal's side.** `sillage-render export <scene> --look <look> --width 480 --height 270
--dump-targets <dir> --dump-targets-frames 12:wide,19:pericentre,4:close` writes, for the
frames named, what the particle passes left in their targets before any post-processing and
everything they drew from, byte for byte as the GPU holds it (`Renderer.particleTargets`,
`RenderTargetManifest` in `ParticleTargets.swift`). An export draws the same frames with and
without the option. The folder, little endian, rows from the top:

| where | what |
| --- | --- |
| `manifest.json` | `sillage-render-targets`, version 1: the commit, the device, the take, then every file with its type, stride, count and, for a texture, width and height. A reader goes by it |
| `particles/` | one value a drawn particle, as the renderer binds them: `population.f32`, `formation.f32`, `luminosity.f32`, `component.u32`, `galaxy.u32`, `traits.f32x2`, `rampKeys.f32`; and `stellar.f32x2` |
| `frames/<name>/` | `positions.f32x4` (16 bytes a position) and `smoothing.f32` |
| `targets/<look>/<name>/` | `splat-uniforms.bin` (176 bytes, `pass` 1), `web-uniforms.bin`, `disk-frames.bin`, `ramps.bin`, `starfield.bin`; `light.f16` and `dust.f16` (rgba16Float, a half's bits a value), `column.f32`, `carrier.f16`, `tags.u8` |
| `lace/` | 256 by 256 texels of the baked lace's first level and the whole of its fifth |

A target also lists its look, its frame, the director's shot, the camera, `supersample`,
`plain`, `starCount`, `dustWeb`, `columnSmoothing`, `holeShadow`, `mapped`, the luminosity
normalisation and the lace's mean.

**The frames compared.** On the `assets/cuda-checks` branch, under
`docs/spikes/cuda-checks/render/`: a take of scene-0031 of 2026-10-30-b at 200 k drawn from
50 k massive, 30 captured frames through the first pericentre, drawn at 480 by 270 on an M4
Max in four looks with the scene's director camera: `hubble` (the dust web, 1,500 field stars),
`red-vs-cyan` (no web, no dust), `raw` (plain points, supersampling 1) and `red-vs-cyan` with
`columnSmoothing` 8 for the column pass, each on a close shot of a disk (frame 4), a wide shot
(frame 12) and the pericentre (frame 19).

**The CUDA side**, on the CPU target in a cloud session (`CUDARenderChecks.compare`):

```
git worktree add ../checks origin/assets/cuda-checks
SILLAGE_CUDA_RENDER_TARGETS=../checks/docs/spikes/cuda-checks/render \
    SILLAGE_CUDA_RENDER_MAPS=/tmp/maps scripts/linux.sh test-cuda --filter theParticlePassesAgreeWithMetal
```

draws each frame from Metal's own bytes (its attribute buffers, positions, smoothing lengths,
disk frames, field stars, stellar table, and its uniforms laid over the plan's), once in fixed
point and once in half floats with one thread, which blends the fragments as Metal does and in
its order. Two minutes for the twelve frames, both ways, and again from the take alone. The
relative difference of a pixel is `|CUDA - Metal| / max(CUDA, Metal)` of the sum of its red,
green and blue, over the pixels where either holds something.

| look | frame | fixed point: total | median | 90 % | 99 % | half floats: total | median | 90 % | 99 % |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hubble` | close | 1.0017 | 0.66 % | 4.3 % | 10.6 % | 1.00009 | 0.18 % | 1.5 % | 4.1 % |
| `hubble` | wide | 1.0017 | 57 % | 100 % | 100 % | 0.99992 | 11 % | 67 % | 100 % |
| `hubble` | pericentre | 1.0024 | 0.76 % | 3.5 % | 8.9 % | 1.00003 | 0.16 % | 1.2 % | 3.3 % |
| `raw` | close | 1.0001 | 0.02 % | 0.04 % | 0.20 % | 1.00000 | 0 | 0 | 0 |
| `raw` | wide | 1.0282 | 0.02 % | 0.21 % | 3.7 % | 1.00001 | 0 | 0 | 0 |
| `raw` | pericentre | 1.0004 | 0.02 % | 0.04 % | 0.28 % | 1.00002 | 0 | 0 | 0 |
| `red-vs-cyan` | close | 1.0014 | 0.36 % | 2.8 % | 8.5 % | 0.99993 | 0.06 % | 1.3 % | 4.2 % |
| `red-vs-cyan` | wide | 1.0060 | 30 % | 100 % | 100 % | 0.99985 | 5.3 % | 50 % | 100 % |
| `red-vs-cyan` | pericentre | 1.0028 | 0.36 % | 2.0 % | 6.1 % | 0.99991 | 0.07 % | 0.91 % | 2.9 % |
| with the column | close | 1.0014 | 0.38 % | 2.8 % | 8.5 % | 0.99992 | 0.09 % | 1.3 % | 4.3 % |
| with the column | wide | 1.0060 | 30 % | 100 % | 100 % | 0.99985 | 5.3 % | 50 % | 100 % |
| with the column | pericentre | 1.0028 | 0.37 % | 2.0 % | 6.1 % | 0.99991 | 0.10 % | 0.92 % | 2.9 % |

- **The same picture.** Blending as Metal does, the whole light of a frame is Metal's within
  0.015 %, and in the raw look more than 99 pixels in 100 hold Metal's value exactly. In fixed
  point the CUDA renderer holds 0.01 to 0.6 % more light than Metal, what half floats round
  away, and 2.8 % more in the raw wide shot, whose core Metal stops counting.
- **The coverage**, the alpha of the light, where the kernels of a pixel add up and which no
  colour and no dust touches. In the splat looks its total is Metal's within 0.03 %, its
  median difference 0.03 to 0.07 %, its 99th percentile 0.3 to 0.4 %. That is the rasteriser's
  rules and the kernel, held.
- **By what Metal holds on a pixel**, in fixed point, in the splat looks: where it holds over
  1e-4 the median difference is 0.1 to 0.8 % and the 99th percentile 0.5 to 2 %; from 1e-5 to
  1e-4 the median is 1 to 6 %; from 1e-6 to 1e-5, 2 to 20 %; from 1e-7 to 1e-6, 10 to 38 %;
  and on 104,000 to 148,000 pixels of a wide shot, a third to a half of those the CUDA
  renderer lights, Metal holds nothing at all. A half float has 11 bits down to 6e-5 and loses
  one with each halving under it, to nothing under 3e-8: the faint outskirts are where the two
  engines part, and the CUDA one is the one that keeps the light.
- **The dust** (`hubble`, through the web): its total within 0.006 % in half floats, its
  median difference 0.3 % at most; the web's carrier within 0.006 % in total on the close
  shots, 0.3 % over on the wide one, its median 0.04 to 0.08 %; the tags the same on all but
  4 values of 1.5 million.
- **The column**: the same count in the frame (144,260, 152,165 and 146,273 particles), and in
  8,034, 8,040 and 8,036 cells of 8,040: a particle on a cell's edge falls on the other side.
- **The lace**: the first level baked here is Metal's within the rounding of its half floats
  (4.9e-4 of the value at most), its mean 0.54517 against 0.54492 from Metal's own levels.

**Where the large differences are.**

1. *The faint outskirts*, above: half floats, and the reason for the fixed point.
2. *The densest pixels.* In the core of a wide shot a pixel reaches 785 and 909 here where
   Metal holds 728 and 854, 6 to 7 % under, and in the raw look 5,586 against 2,048: past
   2,048 a half float no longer takes a one, and it rounds smaller additions away long before.
3. *Single pixels under a bright compact star*, up to 29 % in the close shot of `hubble` and
   66 % at the pericentre of `red-vs-cyan`: 132 pixels of the 207,870 where Metal holds more
   than 1e-3 are over 5 % in the first, 26 of 188,700 in the second, alone among neighbours
   that agree, and their coverage is Metal's. It reads as a tie in the sixteenths of rule 5:
   Metal's vertex arithmetic differs from this one's in its last bits, a point two pixels
   wide has its span rounded to the other sixteenth, its kernel is stretched by 3 %, and a
   star bright enough to be most of its pixel shows it. Read from the maps, not traced a
   particle at a time.
4. *Along the web's lanes* in `hubble`: the lace read with a hand-written anisotropic filter
   where Metal has its GPU's. The dust is 0.1 to 0.4 % apart in the median and the light
   behind it follows.

**What these frames do not draw**: a palette with a ramp (`mapped`), the dust without the web
(the `dust` pass in its four slabs, which shares `dustPixel` with the painted dust drawn
here), and a light tracer, which only a full pass draws. The tests of the CPU target cover the
three (a ramp paints its galaxy's stars and moves no kernel, a tracer draws like the particle
it stands for, the dust dims what stands behind it), not against Metal.

**The pictures**, on `assets/cuda-checks` under `docs/spikes/cuda-checks/render/compare/`, with
every number of the run in `comparison.txt` and the script that draws them from the maps the
test writes. Each has four panels: Metal's light and the CUDA light above, their relative
difference in fixed point and in half floats below, on a log scale from 1e-4 (black) through
0.2 % (red) and 5 % (yellow) to 1 (white).

| look | | | |
| --- | --- | --- | --- |
| `hubble` | [close](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/hubble-close.png) | [wide](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/hubble-wide.png) | [pericentre](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/hubble-pericentre.png) |
| `raw` | [close](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/raw-close.png) | [wide](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/raw-wide.png) | [pericentre](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/raw-pericentre.png) |
| `red-vs-cyan` | [close](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-close.png) | [wide](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-wide.png) | [pericentre](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-pericentre.png) |
| `red-vs-cyan-column` | [close](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-column-close.png) | [wide](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-column-wide.png) | [pericentre](https://raw.githubusercontent.com/pierregc/sillage/assets/cuda-checks/docs/spikes/cuda-checks/render/compare/red-vs-cyan-column-pericentre.png) |

**From the take alone**, as #278 will draw (`CUDARenderChecks.compareFromTake`): every input
made on Linux in place of Metal's bytes.

| input | against Metal's |
| --- | --- |
| population, formation, luminosity, ramp keys, component, galaxy, stellar table | the same bits |
| traits | 1,055 of 400,000 values differ, by 1.2e-7 at most (`exp` and `pow` of the two math libraries) |
| positions decoded from the take | two thirds differ in their last bits, by 7.6e-6 kpc at most on two frames and 3.1e-5 on the third: the decode's multiply and add, fused on Metal |
| smoothing lengths of the CUDA tree | half to all differ in their last bits (`pow`); 90 to 205 of 200,000 by more than 1e-5, a particle in another leaf, up to 63 % |
| uniforms from `TakeFraming` and `FramePlan` | 10 to 16 of 42 values differ, by 2e-5 at most |

The picture drawn from them is as close to Metal's as the one drawn from Metal's own bytes: the
same table within a unit of its last digit (the light's total within 0.015 % in half floats).

**What the test holds**, when `SILLAGE_CUDA_RENDER_TARGETS` names the folder: in half floats
the light's and the dust's totals within 0.1 %, the median difference of the light under 0.5 %
in each decade of Metal's value from 1e-4 up, of the dust under 1 %; in fixed point the
coverage's 90th percentile under 0.5 %; from the take alone the light's total within 0.2 %.
About twice what was measured.

### What #277 and #278 can rely on

- After `CUDARenderer.render(camera:)`, or `draw` then `finish`, `SC_RENDER_LIGHT` and
  `SC_RENDER_DUST_TARGET` hold four floats a supersampled pixel, rows from the top, on the
  device: `resolve` reads the light's red, green and blue as Metal's does. `target(.light)`
  downloads them.
- `CUDARenderer` conforms to `FramePreparing`: `TakeFraming.prepare` gives it the look, the
  palette, the time and the painted arms of a moment of a take, as it gives `Renderer`.
- A full pass hands it the solver's own buffers: `externalPositions` with their offset,
  `externalFormation`, `setSmoothing`, and `setTracers` with the tracers' states, their motions
  and the massive tree's spacing records.
- The post-processing kernels of `Shaders` are still inside the Metal guard, and their structs
  (`BloomParams`, `CompositeParams`, `SpikeParams`) already outside it. A kernel that reads a
  texture at its start can keep the read in its entry point; `msl_texture.h` has the bilinear
  filter by hand.
- The reference frames of `Tests/Fixtures/engines/frames` are final pictures: #277 draws them
  through these passes and sets the tolerance there, which puts the comparison with Metal in
  every Linux check without the assets branch.
