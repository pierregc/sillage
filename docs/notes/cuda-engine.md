# The CUDA engine (#273)

The hires engine's CUDA twin for rented NVIDIA GPUs (#269), written and tested without one in
phase 1. #273 laid the frame the next steps build in: the C API, the Swift module over it, the
build for the GPU and for the CPU target, and the tree builder, the first engine in it. #274
added the solver of the massive particles, which has [a section of its own](#the-massive-particles-solver-274).
How a kernel's text is shared with Metal is in [one-kernel-source.md](one-kernel-source.md);
this note is how the CUDA side around it is built, run and tested.

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
| `cuda/src/kernels.cu` | every library's MSL in one unit, for the checks (#281) |
| `cuda/tests/*.cu` | the C tests of the CPU target (`compat`, `tree_fixture`, `tree_entries`, `solver_fixture`) |
| `Sources/SillageCUDA/` | the Swift: `CUDAContext` and `CUDAError`, `CUDABuffer` and `CUDAHostMemory`, `CUDATreeBuilder`, `CUDABarnesHutSolver` |
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
