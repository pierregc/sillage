# The tracer walk from its MSL text, on CUDA and on the CPU (#271)

Spike of the CUDA epic (#269), phase 1: nothing rented, no NVIDIA GPU. It checks the two ideas
the CUDA engine rests on, on its hardest kernel, the light tracers' walk through the massive tree
(`bhTracerStep` in `BarnesHutShaders.swift`):

- the MSL text Metal compiles also compiles as CUDA, through a compatibility header;
- a CUDA entry point can be checked without an NVIDIA GPU, by building the same file with a host
  compiler and running it on the CPU against a state dumped from a real Metal run.

**Both hold.** The walk's MSL compiles under `nvcc` (CUDA 13.5, sm_120) and under `g++` and
`clang++` with **no line of MSL changed**: `msl_compat.h` takes it as it is. Run on the CPU
against two states of a Metal run of scene-0031, every one of 150,207 tracers gets Metal's
acceleration to rounding: a median of 8.5e-8 and 8.9e-8 relative, a 99.9th percentile of 5.2e-7
and 8.7e-7, none above 4.1e-6, and no walk decided a cell otherwise than Metal where it shows.
The whole fused step gives the same bits twice. One thing has to change in the shared text before
it is fast on NVIDIA: its float literals are double literals in C++ (below).

## What is in `cuda/spike/`

A throwaway, plain C++17 and CUDA, no Swift. `cuda/spike/build.sh` builds it both ways, checks
the MSL copy, runs the CPU build on a synthetic dump and then on every dump directory it is given.

| file | what it is |
| --- | --- |
| `walk_msl.h` | `bhWalk`, `bhSpread`, `halos`, `bhCool`, the structs they read and the whole `bhTracerStep` kernel, copied from `BarnesHutShaders.swift` (`sed -n` of seven line ranges, the Swift string's indentation removed). `build.sh` fails if the copy differs from the Swift. |
| `metal_stdlib` | Stands in for Metal's header, so the copy compiles from its first line, `#include <metal_stdlib>`. |
| `msl_compat.h` | MSL over CUDA C++: vector types, address spaces, the few functions the walk calls. |
| `msl_end.h` | Ends the MSL text: undefines the keyword macros, keeps the vector types. |
| `cuda_cpu.h` | CUDA over plain C++: qualifiers, `threadIdx` and friends, the launch loop, memory calls, CUDA's scalar `min` and `max`. |
| `walk.cu` | The CUDA entry point, the dump loader, the comparison, mode 1 twice. |
| `synthetic.cpp` | Writes a small dump in the same format from made-up clusters and an octree laid out as `GPUTreeBuilder` lays it out, with a direct sum in double for the accelerations. For the harness only. |

## The dump

`sillage-render hires --dump-walk <dir> --dump-walk-frames <list>` (part 1 of #271) writes, at
the end of the steps of each listed frame, `<dir>/frame-<5 digits>/`: one file per buffer
`bhTracerStep` binds, byte for byte as the GPU holds it, little endian, a Metal `float3` in 16
bytes. Counts are elements, not bytes; a file is `count * stride` bytes.

| file | binding | type | stride | count |
| --- | ---: | --- | ---: | --- |
| `states.bin` | 0 | `float4` | 16 | tracers |
| `motions.bin` | 1 | `uint4` | 16 | tracers |
| `sorted.bin` | 2 | `float4` | 16 | massive (all of `sortedBuffer`) |
| `nodes.bin` | 3 | `BHNode` | 32 | the builder's `nodeCount` |
| `moments.bin` | 4 | `float4` | 16 | 2 * nodes with the quadrupole, 0 without |
| `order.bin` | 5 | `uint` | 4 | tracers (`tracerOrder`) |
| `frame.bin` | 6 | `float` | 4 | 8 (the builder's `frame`) |
| `halos.bin` | 7 | `HaloGPU` | 48 | as bound: `haloList`, one a galaxy even with live halos and `haloCount` 0 |
| `holes.bin` | 8 | `HoleGPU` | 32 | as bound: `holes`, or the one placeholder |
| `massive.bin` | 9 | `float3` | 16 | massive (`positionBuffer` from byte `tracers * 16`) |
| `disks.bin` | 10 | `DiskCooling` | 64 | as this step's mode 1 bound them: `coolingDisks()`, or the placeholder |
| `params.bin` | 11 | `TracerStepParams` | 48 | 1: as this step's mode 1 bound it (mode 1, chunkStart 0) |
| `accelerations.bin` | 12 | `float3` | 16 | tracers: Metal's probe (mode 2) on this same state, indexed by tracer, not by slot |
| `motions-mode1.bin` | 1 | `uint4` | 16 | optional: `motions` after one more mode 1 pass over every tracer, run on a copy |

`sorted` and `order` are private buffers on the Mac and go through a blit. Nothing may run
between the dump and the probe: the probe reads `sorted` as the last force pass gathered it.

`manifest.json` beside them:

```json
{
  "format": "sillage-walk-dump",
  "version": 1,
  "byteOrder": "little",
  "source": "Metal, sillage-render hires --dump-walk",
  "scene": "2026-10-30-b/scene-0031",
  "label": "settled",
  "frame": 12,
  "step": 340,
  "time": 123.4,
  "dtScale": 3.5,
  "commit": "<the build's commit>",
  "device": "Apple M4 Max",
  "counts": {"tracers": 200000, "massive": 0, "massiveVisible": 50000, "nodes": 0,
             "halos": 2, "holes": 0, "disks": 2},
  "functionConstants": {"bhQuadrupole": true, "bhOpensHoldingCells": true},
  "tracerSort": {"interval": 10, "counter": 9, "stepsSinceSort": 0},
  "params": {"tracerCount": 200000, "haloCount": 2, "timeStep": 0.0, "openingAngleSquared": 0.0,
             "softeningSquared": 0.0, "gravitationalConstant": 0.0, "chunkStart": 0,
             "sortChunk": 200000, "holeCount": 0, "diskCount": 2, "mode": 1},
  "buffers": {
    "states": {"file": "states.bin", "binding": 0, "type": "float4", "count": 200000, "stride": 16},
    "...": "one entry per file above, under the file's name without .bin"
  }
}
```

`tracerSort.counter` is the solver's `stepsSinceTracerSort` as held, `stepsSinceSort` is 0 when
the walk order was sorted at this step's tree build. `scene`, `label`, `frame`, `step`, `time`,
`dtScale`, `commit`, `device` and the other `counts` are for the reader.

The loader refuses rather than guesses: another `format`, a `version` other than 1, a byte order
other than little, a key given twice or text after the JSON, a buffer name it does not know or a
required one missing, a key it does not know in a buffer's entry, a `binding`, `type` or `stride`
other than the table's, a file whose size is not `count * stride`, counts that disagree with each
other (every tracer buffer `tracerCount`, `massive` and `sorted` alike, `moments` 2 per node or
none, `frame` 8, `holes` and `disks` their count or 1, `halos` at least its count and at least
1), a manifest `params` that is not `params.bin` to the bit, or a `params.bin` that is not mode 1
from slot 0. It also checks what the walk indexes with: `order` a permutation of each sort chunk,
every node's range inside `nodes` or `sorted`, every hole's index inside the massive particles.

## The MSL as CUDA: no line changed

`walk_msl.h` is the MSL text as it is, and both compilers take it. What `msl_compat.h` does for
that, and where it had to be careful:

- **Vector types.** `float3`, `float4`, `uint3`, `uint4` with MSL's layout (a `float3` and a
  `uint3` are 16 bytes, aligned to 16), the operators the walk uses, scalar broadcast,
  `float4(float3, w)`, `uint4(uint3, w)`. CUDA has types of these names, with a 12 byte
  `float3`, so the MSL names are macros for `metal::msl_float3` and so on. The types cannot be
  called `float3` inside `metal` either: the MSL's `using namespace metal;` then made `uint3`
  ambiguous in the host stub `nvcc` generates.
- **`.xyz`** of a `float4` or `uint4` is a member of a union with `x, y, z, w`, a small type that
  reads as the three component vector and writes x, y and z only. Assigning one such swizzle to
  another copies w too, which MSL does not; the walk never does it, other kernels may.
- **Address spaces.** `device` and `thread` are empty. `constant` is `__constant__`: at program
  scope that makes a function constant (`constant bool bhQuadrupole [[function_constant(0)]];`) a
  `__constant__` variable the host sets with `cudaMemcpyToSymbol`, and on a parameter `nvcc`
  ignores it with warning 1835, suppressed. A `constant` pointer is therefore not `const` in
  CUDA: the entry point passes plain pointers.
- **CUDA's own qualifiers.** `__device__` and `__constant__` expand to
  `__attribute__((device))` and `__attribute__((constant))`, which the empty `device` and the
  `constant` macro rewrite. `msl_compat.h` redefines both with the double underscore attribute
  names, which `nvcc` accepts and the MSL macros do not touch.
- **Device functions.** Every MSL helper is `static` or `inline`, and `kernel` is a word MSL
  owns, so all three are macros that add `__device__` (`kernel` becomes `static __device__`):
  the kernel itself compiles as a device function with its `[[buffer(n)]]` attributes, which both
  compilers ignore, and the entry point in `walk.cu` calls it.
- **Functions.** `dot`, `length`, `cross`, `clamp`, `smoothstep`, `all` and `as_type` are
  written; `sqrt`, `abs`, `min` and `max` are CUDA's own global overloads, which `cuda_cpu.h`
  repeats for the host. `ulong` is `unsigned long`, 64 bits on Linux.

**Float literals are doubles.** MSL reads `0.5` as a float; C++ reads it as a double, so
`7.5 * dot(offset, qr) * inverse - 1.5 * (qa.x + qa.y + qa.z)` is double arithmetic, and so is
`max(length(offset), 1e-6)` through CUDA's `max(float, double)`. A consumer NVIDIA GPU runs double
at 1/64 of float. 20 lines of the walk's MSL have a float literal without its `f`; 5 of them
compile to double instructions, 26 lines of the PTX, three of them double arithmetic in the
quadrupole term every accepted cell takes. In the other 15 the compiler folds the double back to
float (`1.0 / distanceSquared` is `rcp.rn.f32`, a comparison with `0.0` a float comparison).
Suffixing only the 5 takes the PTX to no double at all; suffixing all 20 does the same; both keep
40 registers and 128 bytes of stack. Measured with `nvcc` 13.5 for sm_120 on a scratch copy, not
committed: in this ticket the MSL Metal runs does not move. Metal reads `0.5f` as it reads `0.5`,
so #281 should suffix all 20 and check that Metal's runs stay the same to the bit.

| line of `BarnesHutShaders.swift` | function | as it is | in the PTX |
| ---: | --- | --- | --- |
| 43 | `haloAcceleration` | `float r = max(length(offset), 1e-6);` | `max.f64` and two conversions, in each of the 3 copies the halo loop inlines: 9 lines |
| 49 | `halos` | `float3 total = float3(0.0);` | float |
| 112 | `bhCool` | `if (damping <= 0.0) { return velocity; }` | float |
| 119 | `bhCool` | `if (radius < 1e-3) { return velocity; }` | `setp.lt.f64` and a conversion: 2 |
| 123 | `bhCool` | `float radial = 1.0 - smoothstep(disk.reach.x, disk.reach.y, radius);` | float |
| 124 | `bhCool` | `float vertical = 1.0 - smoothstep(disk.reach.z, disk.reach.w, abs(height));` | float |
| 126 | `bhCool` | `if (weight <= 0.0) { return velocity; }` | float |
| 130 | `bhCool` | `if (inward <= 0.0) { return velocity; }` | float |
| 143 | `bhCool` | `if (random <= floorSpeed \|\| random < 1e-6) { return velocity; }` | `setp.lt.f64` and a conversion: 2 |
| 144 | `bhCool` | `float cooled = max(random * (1.0 - weight), floorSpeed);` | `sub.f64`, `mul.f64`, `max.f64` and three conversions: 6 |
| 488 | `bhWalk` | `float3 total = float3(0.0);` | float |
| 507 | `bhWalk` | `if (node.comMass.w <= 0.0) { continue; }` | float |
| 540 | `bhWalk` | `float inverse = 1.0 / distanceSquared;` | float (`rcp.rn.f32`) |
| 542 | `bhWalk` | `float radial = 7.5 * dot(offset, qr) * inverse - 1.5 * (qa.x + qa.y + qa.z);` | two `mul.f64`, a `fma.rn.f64` and four conversions: 7 |
| 543 | `bhWalk` | `total += (offset * radial - 3.0 * qr) * (gravitationalConstant * fifth);` | float |
| 656 | `bhTracerStep` | `const float resolution = 2097151.0;` | float |
| 658 | `bhTracerStep` | `bool inRoot = all(local >= 0.0) && all(local <= resolution);` | float |
| 659 | `bhTracerStep` | `local = clamp(local, 0.0, resolution);` | float |
| 670 | `bhTracerStep` | `float inverse = 1.0 / (r2 * sqrt(r2));` | float |
| 678 | `bhTracerStep` | `float halfStep = p.timeStep * 0.5;` | float |

The PTX before: 10 `cvt.f64.f32`, 5 `cvt.rn.f32.f64`, 4 `max.f64`, 3 `mul.f64`, 2 `setp.lt.f64`,
1 `fma.rn.f64`, 1 `sub.f64`. `build.sh` prints the count, so #281 can make it a check.
`GPUTreeShaders` already writes its literals this way.

## Build 1: `nvcc`, compile only

The cloud session installed NVIDIA's toolkit from its apt repository
(`developer.download.nvidia.com` is allowed in the `sillage` environment), the compiler and the
runtime headers only, 346 MB:

```
curl -fsSLO https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i cuda-keyring_1.1-1_all.deb && apt-get update
apt-get install -y --no-install-recommends cuda-nvcc-13-5 cuda-cudart-dev-13-5
```

CUDA 13.5 (V13.5.37), the newest in the repository on 2026-11-10 (12.8 to 13.5 were offered),
builds for sm_120, the RTX 50 series. `build.sh` builds and links `walk-gpu`; with no GPU it
prints that the run is #283's and exits. `ptxas` gives the entry point 40 registers, a 128 byte
stack frame (the walk's `int stack[32]`) and no spill. `nvcc` contracts multiplies and adds into
FMA by default (`--fmad=true`), as Metal's fast math does.

## Build 2: the CPU

`g++ -std=c++17 -O2 -ffp-contract=off` with `cuda_cpu.h`, no `-ffast-math`: **FMA contraction
off**, and the binary has no FMA instruction (`-march=native -ffp-contract=fast` makes 43). The
same file builds with `clang++`. What `cuda_cpu.h` needed:

- `__global__`, `__device__`, `__host__` and `__constant__` empty, `__forceinline__` as `inline`,
  `__launch_bounds__` dropped; `__restrict__` is already a GCC and Clang keyword.
- `threadIdx`, `blockIdx`, `blockDim`, `gridDim` as globals that `cuda_cpu_launch` sets while it
  runs the blocks and their threads one after another. `CUDA_LAUNCH(kernel, grid, block, ...)`
  is `kernel<<<grid, block>>>(...)` under `nvcc` and that loop on the CPU.
- `__ldg` a plain load; `cudaMalloc`, `cudaMemcpy`, `cudaMemcpyToSymbol`, `cudaFree` on host
  memory; `cudaGetDeviceCount`, `cudaDeviceSynchronize`, `cudaGetLastError` that succeed.
- CUDA's global `min` and `max` overloads, mixed float and double included, which the MSL calls
  resolve to under `nvcc`.

The entry point does what `dispatchThreads` does for the Metal kernel: `gid` from the block and
thread indices, and no thread at or past the dispatched count, since a CUDA grid is whole blocks.
Every entry point of #281 needs that bound.

## Accuracy against Metal

The dumps are on `assets/cuda-spike` (commit ecc36a9), `docs/spikes/cuda-spike/scene-0031/`, with
the run and its surprises in the README beside them. Scene-0031 of 2026-10-30-b at the hires step
(`--dt-scale 3.5`, 0.042 in the solver's units), 200 k drawn from 50 k massive: 150,207 tracers,
124,793 massive particles with their live halos (so `haloCount` 0), opening angle 0.9,
softening 0.3455 kpc, quadrupole on, no black hole, the walk order sorted 4 steps before. Frame
0 is the first after the settle (step 754, 149.2 Myr, both disks cooled, 30,189 nodes); frame
200 the first pericentre (step 1554, 307.4 Myr, centres 6.58 kpc apart, both disks too disturbed
to cool, 29,912 nodes). Metal built the walk with its default fast math.

`|a_cpu - a_metal| / |a_metal|` over every tracer, mode 2, `g++ -O2`, FMA contraction off:

| frame | median | 99.9th percentile | max | the same bits | above 1e-4 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0, settled | 8.50e-8 | 5.18e-7 | 4.01e-6 (tracer 147877) | 3.56 % | 0 |
| 200, pericentre | 8.88e-8 | 8.72e-7 | 3.50e-6 (tracer 147461) | 3.36 % | 0 |

The 20 largest are all between 1.1e-6 and 4.0e-6, on tracers of every size of acceleration
(0.025 to 0.25): rounding, accumulated over a walk of a few hundred cells.

Whether a rounding near the opening test made a walk take a cell Metal opened, or the reverse, was
measured on a scratch copy of the walk (not committed) that records, for every tracer, the
opening test it passed or failed by the smallest relative margin. 28 tracers at frame 0 and 18 at
frame 200 had one within 1e-6, where rounding can decide it (the closest, 3e-10). Each was walked
again with that one decision taken the other way. For 24 and 14 of them the other decision moves
the acceleration by 1e-4 to 1e-2, and the CPU is 1e-7 from Metal: it decided as Metal did. For the
other 4 and 4 the other decision moves it by 1.9e-7 to 1.6e-6, rounding itself, so which way
Metal went cannot be told and changes nothing. The ticket's rule, a bug if more than 0.1 % of
tracers are above 1e-4, is far from reached: none is.

Mode 1 twice on copies of the motions gives the same bits for every tracer, at both frames.
Against Metal's own mode 1 pass (`motions-mode1.bin`) the
velocities agree to a median of 0, a 99.9th percentile of 1.8e-7 and 1.6e-7 and a max of 7.6e-7
and 2.3e-7, and every tracer's packed word is the same: at frame 0 that pass cooled both disks
through `bhCool`, at frame 200 it cooled none.

How the CPU build is compiled moves this only at rounding: `clang++` gives the same bits as
`g++`; FMA contraction on (`-march=native -ffp-contract=fast`) brings it slightly closer to
Metal, which contracts too (median 7.4e-8 and 7.8e-8, 6.0 % and 5.7 % the same bits); float
literals read as floats, as MSL reads them (`-fsingle-precision-constant`, or the 20 literals
suffixed in a scratch copy, which give the same bits as each other), changes the median in the
third digit. No variant has a tracer above 1e-4.

The session on the Mac ran the same harness with Apple clang 21 on the same dumps and got the same
numbers to the last digit printed.

## What this means for #281

- **The approach holds**: one MSL text, compiled by Metal as it is and by `nvcc` and a host
  compiler through two headers. #281 can generalise `msl_compat.h` and `cuda_cpu.h` to the 62
  kernels rather than port them by hand.
- **Suffix the float literals** of the shared MSL (`0.5f`), at least in every kernel CUDA runs,
  and check that Metal's runs stay the same to the bit; then make "no `.f64` in the PTX" one of
  the checks. 20 lines in the walk alone.
- **Take the keyword macros as the method**, with their limits written down: `device`,
  `constant`, `thread`, `kernel`, `static` and `inline` are macros only between `metal_stdlib`
  and `msl_end.h`, every system header must come before, and `__device__` and `__constant__`
  must be redefined with the double underscore attribute names. A `static` local variable or a
  `static` data member inside the MSL would break the `static` macro; the walk has none.
- **What the walk did not need and other kernels will**: `threadgroup` memory (`__shared__`),
  `threadgroup_barrier`, the SIMD functions (`simd_sum`, `simd_prefix_exclusive_sum`,
  `simd_broadcast`, ballots), atomics (`atomic_fetch_add_explicit` and friends), `ldexp`,
  `popcount`, `exp`, the rest of the swizzles and their writes, `uint2`, a `constant` used as an
  array bound (`bhHoleLimit`, which `__constant__` cannot be). The CPU target can only run what
  has no barrier and no SIMD function, as the epic says.
- **Function constants become `__constant__` variables** set once from the host: a branch at
  run time, the same for every thread, where Metal specialises the pipeline when it builds it.
  Not measured here; #283 times it on a GPU, and templates on the constants are the way out if it
  costs anything.
- **Every entry point bounds its own grid**: Metal's `dispatchThreads` gives exactly the count
  asked, a CUDA grid is whole blocks.
- **Comparing with Metal**: the accelerations of one force evaluation agree to about 1e-6 at
  worst, and that is the scale to test against, not the bits. A tree is compared structurally:
  the Mac found that Metal lays a level's nodes out in an order that changes from run to run
  (#273).

## What a GPU is needed for (#283)

`walk-gpu` is built and linked but not run: with no device it prints that the run is #283's and
exits. On a GPU, `walk-gpu <dump-dir>` is the same comparison: the walk on an NVIDIA GPU, its
agreement with the CPU build and with Metal there, mode 1 twice for the same bits, and its time a
tracer (the CPU build's 4.8 microseconds a tracer on one core says nothing about it).
