# Metal's side of the CUDA solver check (#274)

What the CUDA solver for the massive particles is compared with: the massive particles of
scene-0031 at 20 k as the Mac samples them, a Metal run of 2,000 steps over them, and the same
run four more times from positions that differ by their last bit, which gives the scale chaos
alone produces. Written on an Apple M4 Max, 2026-11-11. Another render held the GPU throughout:
nothing here is a timing.

Two sets of files share the folder, over the same runs:

- **What `CUDABarnesHutSolverTests` reads** (`SILLAGE_CUDA_CHECKS` names this folder):
  `massive.bin`, and `curves.json` with `positions-<step>.bin` in `metal/`, `metal-one-bit/` and
  `metal-every-bit/`. The repository's own `SolverCheckTests` wrote them, at commit 7f33fac of
  `feat/274-cuda-solver`.
- **What the Mac's harness adds**, from commit b41436f (main before #274): `curves.csv` and
  `density.npy` in every run, Metal's checkpoints and accelerations in `metal/`, two more
  one-bit runs, and `compare.py`.

Both wrote the same runs: `massive.bin` is the same file, and the positions at steps 100, 1,000
and 2,000, the centres, the thickness and the momentum of each run are the same bits in both
sets.

## The run

Scene `2026-10-30-b/scene-0031` (`scene.json`, the file of `assets/tenfold`), built as
`sillage-render` builds a scene file for the Barnes-Hut solver and sampled with no light
tracers:

```swift
var file = try SceneFile.decoded(from: Data(contentsOf: sceneURL))
file.solver = .barnesHut
let scene = file.scene(particleCount: 20_000)
let system = RestrictedSolver.sampleParticles(for: scene)   // massive.bin
let solver = try MetalBarnesHutSolver(scene: scene, massive: system, tracers: nil)
```

49,999 particles: 20,000 visible and 29,999 of the two live halos, no black hole. Step 0.042
(`0x3d2c0831`, 0.19782 Myr), softening 0.5462539 kpc (`0x3f0bd74c`), opening angle 0.9,
quadrupole on, one tree a step, leaves of 16. 2,000 steps reach t = 83.9996567, 395.64 Myr: the
first pericentre is inside the run (the centres come to 6.67 kpc at step 1,560, 308.6 Myr), both
disks end torn, and 138 stars form.

| file | what |
| --- | --- |
| `scene.json` | the scene file |
| `scene-config.json` | the `SceneConfig` the Mac built from it at 20,000, as JSON with sorted keys, to compare with the one Linux builds |
| `sample.json` | the counts, the step, softening and opening angle with their bit patterns, and the solver's static settings |
| `massive.bin` | the sample, as `RunCheckpoint.saveMassive` writes it (#240) |
| `metal/` | the reference run |
| `metal-one-bit/` | the same run with particle 0's x (the first visible) moved to the next float up |
| `metal-every-bit/` | the same run with every particle's x moved to the next float up |
| `metal-bit-b/`, `metal-bit-c/` | two more one-bit runs: particle 19,999 (the last visible) and 49,998 (the last of the halo) |
| `compare.py` | scores two runs, or one run against the envelope of others |
| `SolverCurves.swift` | what writes a line of `curves.csv` and the maps, with no Metal in it |
| `solver-check.swift` | the Mac's harness around it |
| `digests.txt` | SHA-256 of every data file |

## Formats

Everything is little endian.

**`massive.bin`** (`RunCheckpoint.massiveSet()` reads it): `UInt64` count, `UInt64` visible
count; then for the `count` particles, visible first, the positions (16 bytes each, a
`SIMD3<Float>`), the velocities (the same), `birthRadius`, `population`, `luminosity`,
`formation`, `kernelScale` and `mass` (a `Float` each), `galaxyIndex` and `component` (a
`UInt32` each). 16 + 64 bytes a particle.

**`curves.json` and `positions-<step>.bin`** (`SolverCheck.record` in
`Sources/SillageRender/SolverCheck.swift`, read by `SolverCurves.load` and `SolverCheck.gaps`):
the curves every 10 steps as a `SolverCurves` in JSON, and the massive particles' positions, 16
bytes each, at steps 0, 100, 200, 500, 1,000, 1,500 and 2,000.

**`curves.csv`**: a line every 10 steps from step 0 to step 2,000 (201 lines), floats as `%.9g`
and doubles as `%.17g`.

| column | what |
| --- | --- |
| `step`, `time` | the step and `solver.time` |
| `cx_g`, `cy_g`, `cz_g` | `solver.centers[g]`, in kpc |
| `thickness_g`, `coherence_g`, `disruption_g`, `torn_g`, `ax_g`, `ay_g`, `az_g` | `solver.diskFrames[g]` |
| `px`, `py`, `pz` | the total momentum: mass times velocity over the 49,999 particles, summed in double in index order, a component at a time |
| `mx`, `my`, `mz` | the centre of mass, summed the same way, in kpc |
| `formed` | the visible particles whose formation time is no longer the one they were sampled with |

**`density.npy`**: `DensityMap` as it is, float32 of shape (9, 256, 256): the 20,000 visible
particles counted on the xy plane over a square of half side 80 kpc centred on the origin, as a
share of the 20,000, at steps 0, 250, ..., 2,000.

**`metal/particles-<step>.bin` and `state-<step>.json`**, at steps 1, 10, 100, 1,000 and 2,000:
what a checkpoint holds there. The first is `writeParticles(to:)`: the positions (16 bytes a
particle), the velocities (the same), the formation times (4 bytes a particle). The second is
`solver.state` (`SolverState`) as JSON with sorted keys. A solver built over `massive.bin` and
restored from the two goes on from that step.

**`metal/accelerations-<step>.bin`**, at steps 0, 1, 10, 100, 1,000 and 2,000:
`solver.accelerations`, three floats a particle and a fourth set to zero. They are the forces of
the tree built on that step's positions, the ones `particles-<step>.bin` holds (at step 0, those
of `massive.bin`).

## What the Mac found

**Metal repeats itself to the byte.** A second run of `metal/` gave the same 18 files.

**How far one bit goes.** Against `metal/`, the most each measure reaches anywhere along the
2,000 steps, from `curves.csv` and `density.npy` (`compare.py`):

| the most over the run | one bit | b | c | envelope of the three | every bit |
| --- | ---: | ---: | ---: | ---: | ---: |
| centre 0, kpc | 0.0189 | 0.0164 | 0.0177 | 0.0189 | 0.0206 |
| centre 1, kpc | 0.0129 | 0.0147 | 0.0102 | 0.0147 | 0.0128 |
| thickness 0 | 7.64e-05 | 7.67e-05 | 7.08e-05 | 7.67e-05 | 9.5e-05 |
| thickness 1 | 6.04e-05 | 9.35e-05 | 7.15e-05 | 9.35e-05 | 8.06e-05 |
| axis 0, degrees | 0.0178 | 0.0178 | 0.0188 | 0.0188 | 0.0174 |
| axis 1, degrees | 0.0174 | 0.0199 | 0.0185 | 0.0199 | 0.0251 |
| momentum | 0.000832 | 0.00058 | 0.000687 | 0.000832 | 0.000643 |
| centre of mass, kpc | 0.000122 | 8.21e-05 | 0.000145 | 0.000145 | 0.000127 |
| stars formed | 1 | 0 | 0 | 1 | 3 |
| chi-square a cell, 4x4 | 0.00514 | 0.00502 | 0.00596 | 0.00596 | 0.0122 |
| chi-square a cell, 8x8 | 0.000725 | 0.0012 | 0.00127 | 0.00127 | 0.0033 |
| stars elsewhere, % | 1.18 | 1.59 | 1.54 | 1.59 | 2.94 |

The total momentum itself goes from 2.13 to 2.70 in these units along the run (it drifts, as
`SceneConfig.openingAngle` says), and the galaxies' centres travel 50 and 63 kpc.

Particle by particle, the distance between the two runs' positions, in kpc (median, 99th
percentile and largest over the visible particles):

| step | one bit | every bit |
| ---: | --- | --- |
| 1 | 0, 0, 9.5e-07 | 1.9e-06, 3.8e-06, 7.6e-06 |
| 10 | 0, 0, 9.5e-07 | 1.9e-06, 4.3e-06, 2.4e-05 |
| 100 | 0, 0, 9.5e-07 | 4.3e-06, 7.3e-05, 5.6e-04 |
| 1,000 | 1.5e-04, 1.3e-03, 6.9e-03 | 6.3e-04, 5.5e-03, 2.2e-02 |
| 2,000 | 4.7e-03, 8.6e-02, 0.69 | 1.4e-02, 0.28, 1.45 |

- **One particle moved by one bit stays alone for a hundred steps or more**: what it changes of
  the others' forces is below their rounding. Once it spreads, the two runs part by a factor of
  about 30 between step 1,000 and step 2,000.
- **Every particle moved by one bit** is where an engine that rounds each force its own way
  starts from. It ends about three times further than one particle does particle by particle
  (median 0.014 kpc against 0.005), twice in the maps, and the same in the centres, thickness
  and momentum, which the passage sets.
- **One force evaluation.** With every position one bit away the accelerations at step 0 differ
  by 2e-07 of their length in the median, 2.4e-06 at the 99th percentile and 2.1e-05 at most.

## Commands

What the CUDA test reads, from a checkout of `feat/274-cuda-solver` (it writes `massive.bin`
and the three runs' `curves.json` and positions):

```
SILLAGE_SOLVER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter SolverCheckTests
```

The harness is `solver-check.swift` and `SolverCurves.swift` compiled against a build of the
commit (`./scripts/dev.sh build`):

```
swiftc -O -I .build/dev -L .build/dev -lSillageCore -lSillageRender \
    SolverCurves.swift solver-check.swift -o solver-check
export DYLD_LIBRARY_PATH=.build/dev
./solver-check sample scene.json 20000 .
./solver-check run scene.json . metal --snapshots 1,10,100,1000,2000
./solver-check run scene.json . metal-one-bit --nudge 0
./solver-check run scene.json . metal-bit-b --nudge 19999
./solver-check run scene.json . metal-bit-c --nudge 49998
./solver-check run scene.json . metal-every-bit --nudge all
```

For `compare.py`, a run of another engine is a folder holding `curves.csv` and `density.npy` in
these formats, and if it can `particles-<step>.bin` and `accelerations-<step>.bin`:

```
python3 compare.py metal cuda
python3 compare.py metal --scale metal-one-bit metal-bit-b metal-bit-c --test cuda
```

The first prints the measures along the run and, where both folders hold them, the distance
between the positions and the relative difference of the accelerations at each kept step. The
second puts the run beside the envelope of the three one-bit runs. `numpy` is all it needs.
