# The CUDA engine (#273)

The hires engine's CUDA twin for rented NVIDIA GPUs (#269), written and tested without one in
phase 1. #273 laid the frame the next steps build in: the C API, the Swift module over it, the
build for the GPU and for the CPU target, and the tree builder, the first engine in it. #274
added the solver of the massive particles and #275 its light tracers, which have sections of
their own ([the massive particles](#the-massive-particles-solver-274),
[the light tracers](#the-light-tracers-275)). How a kernel's text is shared with
Metal is in [one-kernel-source.md](one-kernel-source.md); this note is how the CUDA side around
it is built, run and tested.

## Layout

| where | what |
| --- | --- |
| `cuda/include/sillage_cuda.h` | the C API: statuses and errors, contexts, buffers, pinned memory; includes one header a domain at its end |
| `cuda/include/sillage_cuda_tree.h` | the tree builder's calls |
| `cuda/include/module.modulemap` | the C API as the Swift module `CSillageCUDA` |
| `cuda/src/engine.h` | what the files of `cuda/src` share behind the API: `sc_context`, `sc_buffer`, `fail`, `check`, `allocate`, `pointer` |
| `cuda/src/context.cu` | errors, contexts, buffers and pinned memory |
| `cuda/src/tree.cu` | the 20 tree entry points, their launches and the tree's calls |
| `cuda/include/sillage_cuda_solver.h`, `cuda/src/solver.cu` | the solver's calls, its 11 entry points and their launches: the massive particles' 8 (#274), the light tracers' 3 (#275) |
| `cuda/src/kernels.cu` | every library's MSL in one unit, for the checks (#281) |
| `cuda/tests/*.cu` | the C tests of the CPU target (`compat`, `tree_fixture`, `tree_entries`, `solver_fixture`) |
| `Sources/SillageCUDA/` | the Swift: `CUDAContext` and `CUDAError`, `CUDABuffer` and `CUDAHostMemory`, `CUDATreeBuilder`, `CUDABarnesHutSolver` and `CUDALightTracerStore` |
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
`sortOrder` (the light tracers' walk order) takes a stable sort of the same Morton codes on the
CPU target (#275).

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

`MetalBarnesHutSolver` on CUDA, first without its light tracers: a scene's massive particles stepped as
the Mac steps them, with the analytic or live halos, the black holes, star formation, the cooling
disks and dissipation, saved and resumed to the bit. Nothing of it is a copy. The kernels are the
shared MSL of `BarnesHutShaders`; the order of a step and the CPU work around it are portable
Swift that both solvers run. #275 adds the light tracers to it, #278 steps it in the full pass.

| where | what |
| --- | --- |
| `Sources/SillageRender/BarnesHutShaders.swift` | the eight massive kernels' work in shared functions, and the three tracer kernels' since #275 |
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
- **The light tracers** come in front of the massive particles in `positions` and
  `velocities`, as on Metal: `sc_solver_config.first` and `leaf_chances` are there for them.
  #275 runs their three passes ([below](#the-light-tracers-275)).

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

The Mac's folder is on `assets/cuda-checks` (e11a3d9), `docs/spikes/cuda-checks/tracers/`, with
its formats and what it found; the CUDA run is the CPU target's, 1,560 steps in 38 minutes.

**One force evaluation**, on the drawn positions: the tracers' accelerations are within 8.4e-8 of
Metal's in the median, 2.6e-7 at the 99th percentile and 6.2e-6 at most, none past 1e-4 and 3.6 %
with Metal's bits; the massive particles' within 7.7e-8, 2.3e-7 and 2.5e-6, as in #274. After one
step 98 % of the positions are Metal's to the bit, and every tracer's packed word.

**The light stays on the mass**, the tracers against the massive visible particles of the same
run, as `tracer-drift.py` scores them:

| Myr | CUDA: chi2 a cell | binned 4x4 | light elsewhere | noise alone | Metal: binned 4x4 | light elsewhere |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 1.039 | 0.995 | 5.52 % | 5.40 % | 0.995 | 5.52 % |
| 39 | 0.980 | 0.960 | 5.29 % | 5.51 % | 0.960 | 5.29 % |
| 77 | 0.978 | 0.993 | 5.57 % | 5.54 % | 0.993 | 5.57 % |
| 116 | 0.995 | 0.889 | 5.25 % | 5.56 % | 0.889 | 5.26 % |
| 154 | 1.009 | 0.966 | 5.73 % | 5.63 % | 0.967 | 5.73 % |
| 193 | 1.056 | 0.913 | 5.51 % | 5.65 % | 0.913 | 5.51 % |
| 231 | 0.997 | 0.970 | 5.57 % | 5.51 % | 0.972 | 5.55 % |
| 270 | 0.993 | 1.043 | 5.38 % | 5.17 % | 1.053 | 5.42 % |
| 309 | 1.012 | 0.977 | 4.85 % | 4.75 % | 0.969 | 4.86 % |

Chi-square near 1 at every instant and the light elsewhere within 0.25 points of the noise, as on
Metal; 50 k massive particles make that noise about six times #238's at 2 M.

**Against Metal**, each set's maps against the same set's on Metal, chi-square a cell binned 4 x 4,
beside Metal against itself with every position a last bit away:

| Myr | tracers, CUDA against Metal | Metal a bit away | massive, CUDA against Metal | Metal a bit away |
| ---: | ---: | ---: | ---: | ---: |
| 116 | 0.0001 | 0.0001 | 0.0002 | 0.0001 |
| 193 | 0.0002 | 0.0003 | 0.0002 | 0.0005 |
| 231 | 0.0006 | 0.0009 | 0.0007 | 0.0010 |
| 270 | 0.0012 | 0.0019 | 0.0025 | 0.0041 |
| 309 | 0.0031 | 0.0045 | 0.0038 | 0.0092 |

Along the run the most the centres part is 4.3 and 4.0 pc (Metal a bit away: 6.2 and 4.7), the
disks' thicknesses 1.6e-5 and 1.8e-5 (2.6e-5, 3.1e-5), the momentum 4.5e-4 (4.8e-4), and 1,177
stars form against Metal's 1,176 (1,169), tracers and massive particles together. At the
pericentre the tracers are 5.1 pc from Metal's in the median, 0.11 kpc at the 99th percentile,
exactly as far as the massive visible particles are. **The light stays on the mass on CUDA as on
Metal, and the CUDA run parts from Metal less than Metal parts from itself after a one-bit change.**
The test holds each instant to a chi-square under 1.3 and the light elsewhere under 1.25 times the
noise, and each set to three times what Metal a bit away gives.

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

## The light tracers (#275)

198 M of a 200 M run are light tracers (#187, #238): 32 bytes each in the solver's buffers and 4
of walk order, walked through the massive tree once a step and weighing nothing. #275 puts them
in `CUDABarnesHutSolver` as `MetalBarnesHutSolver` holds and steps them
([light-tracers.md](light-tracers.md#compact-tracers-238)), from the same source and on the same
step.

| where | what |
| --- | --- |
| `Sources/SillageRender/BarnesHutShaders.swift` | `tracerStep`, `tracerDrift` and `tracerFormStars`, the work of `bhTracerStep`, `bhTracerDrift` and `bhTracerFormStars`, with `TracerStepParams` |
| `cuda/src/solver.cu`, `cuda/include/sillage_cuda_solver.h` | their entry points, `sc_solver_tracer_step`, `_tracer_drift` and `_tracer_form_stars` |
| `Sources/SillageCUDA/CUDABarnesHutSolver.swift` | `CUDALightTracerStore`, the tracers in the solver, `lightTracers(context:drawn:massive:)`, `footprint` |
| `Sources/SillageCore/BarnesHutTree.swift` | `mortonOrder(of:)`, the walk order on the CPU target |
| `Sources/SillageRender/TracerCheck.swift`, `Tests/SillageRenderTests/TracerCheckTests.swift` | the run both engines make to check the light stays on the mass, and the Mac's side of it |
| `Tests/SillageCUDATests/CUDALightTracerTests.swift` | the tests, part of the solver's serialized suite |

### The kernels

The three bodies moved into shared functions line for line, the two function constants of
`bhTracerStep` (`bhQuadrupole`, `bhOpensHoldingCells`) reaching `tracerStep` as arguments and on
CUDA as the template parameters of `bhTracerStep<quadrupole, opensHoldingCells>`, launched through
a function pointer as `bhAcceleration` is. None needs a block barrier or a warp function, so all
three are `cuda` in `cuda/kernels.txt` and run on the CPU target: 24 `cuda`, 7 `cuda gpu-only`, 28
pending. Each `bhTracerStep` instantiation takes 40 registers for sm_120, as #271's spike did,
with no double precision instruction; the solver's PTX now holds 18 entry points and no barrier.

**A piece of a pass is its slots, not a whole number of blocks.** Metal's `dispatchThreads`
dispatches exactly the slots of a piece of the force pass; a CUDA grid is whole blocks, and the
shared function only stops at the whole count, so the last block of a piece ran the first slots of
the next piece too. For a massive particle that wrote the same acceleration twice; for a tracer,
whose pass kicks it, it was a second kick, which the test of the pass in pieces of 700 found. The
entry points of `bhTracerStep` and `bhAcceleration` now take the piece's `slots` and stop the
threads past it ([one-kernel-source.md](one-kernel-source.md#the-cpu-target)).

The tracers' passes are where `BarnesHutStep` puts them since #274: their star formation right
after the massive one, at the chances its leaves just wrote (`leaf_chances`, the slot chances);
their drift in `drift`; their fused pass after the massive pieces, a launch for each `forceChunk`
of the walk order, blocks of 64 as on Metal. A pass reads the lists it needs as the massive passes
do (the analytic halos, the black holes, the cooling disks), staged in the same small buffers.

### The buffers

As on Metal: `[tracers | massive visible | massive halo]` in the position and velocity buffers, a
tracer's formation time in the w of its position and its `TracerWord` in the w of its velocity,
everything else the massive particles' alone, the massive passes bound past the tracers
(`sc_solver_config.first`), the tree built over the massive particles (`CUDATreeBuilder(first:)`),
the halo centres, disk frames and holes' reactions summed over the massive particles from the
first of them. `particles` and `accelerations` give the tracers first, as Metal's do, the
tracers' accelerations walked again in mode 2 from the same tree.

- **Sampling by chunks straight into the GPU.** `CUDABarnesHutSolver.lightTracers(context:drawn:
  massive:)` samples through `ParticleSystem.streamingLightTracers`, which hands the tracers on a
  million at a time, packed: each chunk is uploaded into a `CUDALightTracerStore` as it comes,
  so the drawn count is never held on the host. The store's buffers become the solver's.
- **A resumed run** reads its tracers from the checkpoint and gives them no first half kick:
  `CUDALightTracerStore(context:capacity:awaiting:)` leaves them to `restore`, whose files are
  the Metal solver's (#240), 32 bytes a particle and 4 a massive particle, tracers first.
- **The walk order** is sorted a chunk at a time, 4 M a chunk every 10 steps
  (`BarnesHutHost.tracerSortChunk` and `tracerSortInterval`, which `--tracer-sort` and
  `--tracer-sort-chunk` set for both engines), each chunk counted from its start, 4 bytes a tracer.
  On a GPU it is the tree's radix sort, run by a second `CUDATreeBuilder` that only sorts
  (`sortOrder`, `gpu-only` kernels); on the CPU target a stable sort of the same Morton codes by
  the standard library (`BarnesHutTree.mortonOrder`), which gives the radix sort's order and the
  tree's (`aChunkSortsIntoMortonOrder` holds it to `BarnesHutTree.order`). The order only decides
  which thread walks which tracer: a tracer's result does not depend on it, so a run resumed with
  a freshly sorted order gives the same bits.

### The renderer's side

`writeSmoothing(into:drawn:)` writes what Metal's does: with tracers each massive visible particle
stands for (tracers + massive visible) / massive visible drawn particles, in the smoothing lengths
and in the spacing records a tracer's kernel reads (`buildSpacing`, #273). `tracerSpacing` gives
the renderer those records, the frame the codes are taken in and the depth, as `TracerDrawing`
does on Metal, for #276 and #278 to bind.

### Memory

The context counts the device bytes its buffers hold and the most they have held, from the
allocations (`sc_context_memory`, `CUDAContext.memoryHeld`). `CUDABarnesHutSolver.footprint`
works out the same total from the counts with the sizes the allocations take, and
`theMemoryIsWhatTheAllocationsHold` holds the two equal on a run of 80,072 tracers and 49,928
massive particles: 12,014,244 bytes. On paper, for scene-0031 drawn from 2 M massive (5 M with
the halos, the tree at its first node capacity of 2.5 M nodes, two disks cooled):

| drawn | tracers | the tracers | the massive particles | their tree | the sort | in all | a tracer |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8 M | 6 M | 0.22 GB | 0.44 GB | 0.30 GB | 0.09 GB | 1.05 GB | |
| 50 M | 48 M | 1.73 | 0.44 | 0.30 | 0.09 | 2.56 | 53 bytes |
| 100 M | 98 M | 3.53 | 0.44 | 0.30 | 0.09 | 4.36 | 44 |
| 200 M | 198 M | 7.13 | 0.44 | 0.30 | 0.09 | 7.96 | 40 |
| 1 G | 998 M | 35.93 | 0.44 | 0.30 | 0.09 | 36.76 | 37 |

- **The tracers are 36 bytes each and nothing else grows with them.** A massive particle holds 88
  bytes (its position and velocity, acceleration, gathered copy, mass, formation time, kind,
  galaxy, cost, slot chance), the tree 64 a node with the quadrupole and 24 a massive particle of
  codes and orders, the sort 86 MB at any count, as on Metal (light-tracers.md).
- **200 M fits a 32 GB card with room for the renderer.** The solver holds 8.0 GB; with about
  4 GB for the renderer's targets at 4K with supersampling 2 and the CUDA context's own few
  hundred megabytes, a run needs about 12.5 GB, which also fits a 24 GB RTX 4090. A tree that
  outgrows its first capacity doubles it, 160 MB more at 5 M massive. A billion needs about 41 GB
  with the renderer: one 48 GB card, or the tracers spread over several (#280).
- **On the host**, pinned copies of the massive positions and velocities (160 MB at 5 M), the
  massive set as sampled (320 MB) and one chunk of sampled tracers at a time (32 MB).

#283 measures the peak on a GPU (`aStepWithTracersIsTimed` prints it beside the footprint).

### Tests

**Now, in every Linux check and on every push**, on the CPU target:

- `cuda/tests/solver_fixture.cu`, with `g++` and `clang++`: `bhTracerStep` through
  `sc_solver_tracer_step` over the walk fixture's tree laid out by `sc_tree_upload`, 1,000 tracers
  over 5,012 massive particles in blocks of 64. In mode 2 no acceleration past 1e-5 of Metal's,
  the furthest 1.63e-6 away, 42 with Metal's bits; in mode 1 no velocity past 1e-5 of Metal's,
  the furthest 1.73e-7 away, every packed word unchanged and the same bits twice; mode 2 moves
  nothing, and a pass without its probe or with a walk order sorted 0 at a time is refused.
  `bhTracerFormStars` through `sc_solver_tracer_form_stars` over the tree's codes: at a chance of
  1 each of the 246 gas tracers whose stars had not formed forms them at this step's time, at -1
  none does, and no other tracer changes.
- `CUDA solver`, 7 more tests run here (55 s for the suite, 16 s before):
  `theMassiveParticlesRepeatTheRunWithoutTracersToTheBit`, 20 k massive and 80 k tracers for 20
  steps, then a black hole pass of 3 k massive and 9 k tracers for 40, side by side with the same
  massive particles alone: their positions, velocities, formation times, centres and disks to the
  bit, as `LightTracerTests` holds Metal; `aRunWithTracersRepeatsAndResumesFromItsCheckpoint`, a
  merger of 10 k massive and 20 k tracers with star formation, rigid halos and two cooling disks,
  200 steps twice and resumed from step 100 in a solver that samples nothing, the same bits,
  tracers and accelerations included; the tracers' pass in pieces of 700 and every pass profiled,
  the same bits, with the tracers' phases timed; a tracer's acceleration against direct summation
  (mean under 2 %, worst under 15 %); the streamed draw equal to the split one, and a run over it
  the same run; the spacing records and lengths a builder writes over the same positions; the
  memory held equal to the footprint.

**Written now, run on a GPU in #283**, each skipped on the CPU target with "needs an NVIDIA GPU
and libsillagecuda.a: #283 runs it":

- `theTracersOf8MRepeatAndResume`: scene-0031 drawn at 8 M from 2 M massive with the radix sort,
  the massive part against the run without tracers to the bit after 20 steps, then stopped,
  saved, resumed and stepped 20 more, the same bits.
- `aStepWithTracersIsTimed` at 8 M, 50 M and 200 M drawn from 2 M massive: sampled on the box
  (about five minutes at 200 M), ten steps profiled after two, on a `CUDATRACERS` line: a step,
  the walk in ns a tracer a step, against 21.0 on the M4 Max at 100 M (#238) and #283's own
  timing of the walk, the sort a step, and the device memory at its peak, held and on paper.

And on a GPU the tests of the first list run through the radix sort. One test waits for data
instead of a GPU: `theLightStaysOnTheMassAsOnMetal` is skipped without the Mac's draw and runs
of branch `assets/cuda-checks` (below); #283 runs it at 8 M with the Mac's runs at that size.

### Whether the light stays on the mass, against Metal

**The run.** Scene-0031 of 2026-10-30-b drawn at 200 k from 50 k massive as a hires draws it
(`TracerCheck.scenes`: the draw's disks held at the massive softening): 150,207 tracers and
124,793 massive particles with their live halos, step 0.042 (0.198 Myr), softening 0.3455 kpc,
opening angle 0.9 for both sets, 1,560 steps to 308.6 Myr, the first pericentre. The Mac drew it
once, `massive.bin` and `tracers.bin` (the tracers as drawn, before any kick), and both engines
step that draw: the Mac on Metal, twice to the byte, then once more with every position a last
bit away (`metal-bit-all`); Linux on the CPU target. Each writes nine density maps of the tracers
and of the massive visible particles (256 x 256 over 120 kpc, at steps 0, 195, ..., 1,560) with
the lines `scripts/tracer-drift.py` reads, and the accelerations at step 0.

The Mac's folder is on `assets/cuda-checks` (e11a3d9), `docs/spikes/cuda-checks/tracers/`, with
its formats and what it found; the CUDA run is the CPU target's, 1,560 steps in 38 minutes.

**One force evaluation**, on the drawn positions: the tracers' accelerations are within 8.4e-8 of
Metal's in the median, 2.6e-7 at the 99th percentile and 6.2e-6 at most, none past 1e-4 and 3.6 %
with Metal's bits; the massive particles' within 7.7e-8, 2.3e-7 and 2.5e-6, as in #274. After one
step 98 % of the positions are Metal's to the bit, and every tracer's packed word.

**The light stays on the mass**, the tracers against the massive visible particles of the same
run, as `tracer-drift.py` scores them:

| Myr | CUDA: chi2 a cell | binned 4x4 | light elsewhere | noise alone | Metal: binned 4x4 | light elsewhere |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 1.039 | 0.995 | 5.52 % | 5.40 % | 0.995 | 5.52 % |
| 39 | 0.980 | 0.960 | 5.29 % | 5.51 % | 0.960 | 5.29 % |
| 77 | 0.978 | 0.993 | 5.57 % | 5.54 % | 0.993 | 5.57 % |
| 116 | 0.995 | 0.889 | 5.25 % | 5.56 % | 0.889 | 5.26 % |
| 154 | 1.009 | 0.966 | 5.73 % | 5.63 % | 0.967 | 5.73 % |
| 193 | 1.056 | 0.913 | 5.51 % | 5.65 % | 0.913 | 5.51 % |
| 231 | 0.997 | 0.970 | 5.57 % | 5.51 % | 0.972 | 5.55 % |
| 270 | 0.993 | 1.043 | 5.38 % | 5.17 % | 1.053 | 5.42 % |
| 309 | 1.012 | 0.977 | 4.85 % | 4.75 % | 0.969 | 4.86 % |

Chi-square near 1 at every instant and the light elsewhere within 0.25 points of the noise, as on
Metal; 50 k massive particles make that noise about six times #238's at 2 M.

**Against Metal**, each set's maps against the same set's on Metal, chi-square a cell binned 4 x 4,
beside Metal against itself with every position a last bit away:

| Myr | tracers, CUDA against Metal | Metal a bit away | massive, CUDA against Metal | Metal a bit away |
| ---: | ---: | ---: | ---: | ---: |
| 116 | 0.0001 | 0.0001 | 0.0002 | 0.0001 |
| 193 | 0.0002 | 0.0003 | 0.0002 | 0.0005 |
| 231 | 0.0006 | 0.0009 | 0.0007 | 0.0010 |
| 270 | 0.0012 | 0.0019 | 0.0025 | 0.0041 |
| 309 | 0.0031 | 0.0045 | 0.0038 | 0.0092 |

Along the run the most the centres part is 4.3 and 4.0 pc (Metal a bit away: 6.2 and 4.7), the
disks' thicknesses 1.6e-5 and 1.8e-5 (2.6e-5, 3.1e-5), the momentum 4.5e-4 (4.8e-4), and 1,177
stars form against Metal's 1,176 (1,169), tracers and massive particles together. At the
pericentre the tracers are 5.1 pc from Metal's in the median, 0.11 kpc at the 99th percentile,
exactly as far as the massive visible particles are. **The light stays on the mass on CUDA as on
Metal, and the CUDA run parts from Metal less than Metal parts from itself after a one-bit change.**
The test holds each instant to a chi-square under 1.3 and the light elsewhere under 1.25 times the
noise, and each set to three times what Metal a bit away gives.

**To run it again**, on Linux, with the Mac's folder checked out from `assets/cuda-checks`:

```
SILLAGE_CUDA_TRACER_CHECKS=<folder> SILLAGE_CUDA_CHECKS_OUT=<out> scripts/linux.sh test-cuda \
    --filter theLightStaysOnTheMassAsOnMetal
python3 scripts/tracer-drift.py <out>/cuda-cpu/run.log <out>/cuda-cpu/density.npy
```

The test scores each instant as `tracer-drift.py` does (chi-square a cell binned 4 x 4 against the
Poisson noise of both maps, the light elsewhere against the noise alone), for each engine's
tracers against its massive particles and for each set against Metal's, beside Metal against
itself a last bit away, and prints it all on `CUDATRACERS` lines. The Metal side is written by
`SILLAGE_TRACER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter TracerCheckTests` on the Mac;
`SILLAGE_TRACER_CHECK_DRAWN`, `_MASSIVE` and `_STEPS` change the run, for #283's at 8 M.

### What #275 measured

- **Metal is the same to the bit.** After the kernels were shared and after the CUDA side was
  added, the Mac's check passed (608 tests, main's 607 and the comparison's, skipped without its
  folder), with `theMassiveParticlesRepeatTheRunWithoutTracersToTheBit` and
  `aBlackHolePassKeepsItsBits`, and a short hires of scene-0031 at 200 k drawn from 50 k massive,
  its tracers sorted, forming stars and checkpointed, gave main's 26 files to the byte.
- **The tracers' kernels compile for CUDA as they are**: no line of their MSL written for it,
  nothing added to `msl_compat.h`.
- **On the CPU target** the fixture's walk is Metal's to 1.63e-6, its velocities after a step to
  1.73e-7, and a run with tracers repeats and resumes to the bit. A step of scene-0031 at 200 k
  drawn from 50 k massive, 150,207 tracers and 124,793 massive particles, takes 1.46 s there.
- **One bug**, the double kick at the edge of a piece, which only CUDA's whole blocks can make.
- **The workflow** stays at 6 min 46 s, its longest job `swift-core`; the CUDA suites take 55 s
  of the `swift-checks` job, 39 more than before.

### For #278

The full pass on Linux takes from here what the Mac's takes from `MetalBarnesHutSolver`:
`CUDABarnesHutSolver.lightTracers(context:drawn:massive:)` to sample, `CUDALightTracerStore(
context:capacity:awaiting:)` and `restore(_:from:)` to resume, `positions`, `velocities` and
`formation` for the renderer and the take, `writeSmoothing(into:drawn:)` and `tracerSpacing` for
the kernels' sizes, `tracerWord(_:)`. What the Mac's full pass also reads in place on unified
memory, `drawnAttributes()`, `formed(after:until:)` and `radii(every:)`, has no CUDA twin yet:
on a GPU they become downloads of the tracers' words and formation times, or small kernels, as
#278 finds cheapest at 200 M (the words alone are 0.8 GB).
