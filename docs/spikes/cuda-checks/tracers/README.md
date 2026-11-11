# Metal's side of the light tracers' check (#275)

What the CUDA light tracers are compared with: scene-0031 drawn at 200 k from 50 k massive as
the Mac draws it, a Metal run over that draw up to the first pericentre, and the same run from
positions that differ by their last bit, which gives the scale chaos alone parts two runs by.
Written on an Apple M4 Max on 2026-11-11 from commit 1bf7390 of `feat/275-cuda-tracers`, whose
Metal engine gives main's bits (ba07498): main's 607 tests and this one pass, and a short hires of scene-0031
with its tracers the same to the byte. Another render held the GPU throughout: nothing here is a
timing.

```
SILLAGE_TRACER_CHECK_OUT=<folder> ./scripts/dev.sh test --filter TracerCheckTests
```

wrote the folder twice, the same 20 files to the byte both times (`digests.txt`). The draw is
also the one a harness built on main ba07498 made with `MetalBarnesHutSolver.lightTracers`,
to the byte.

## The draw

`TracerCheck.scenes` over `scene.json` (the file of `assets/tenfold`, and of
`Tests/Fixtures/engines/scene/`), as `sillage-render hires --particles 200000 --massive 50000`
builds its two scenes: the draw at 200,000, whose disks hold at the massive softening, and the
massive count's at 50,000, whose softening and step the run takes. Then
`ParticleSystem.streamingLightTracers`, the tracers kept in one chunk.

| | |
| --- | --- |
| light tracers | 150,207 |
| massive visible | 49,793 |
| halo | 75,000, live |
| step | 0.042 (`0x3d2c0831`), 0.19782 Myr: the scene file's, as #274's run; the hires stage itself steps this clip at 0.04175 |
| softening | 0.34548503 kpc (`0x3eb0e36a`) |
| opening angle | 0.9 (`0x3f666666`), the tracers' too |
| tracers' sort | every 10 steps, chunks of 4,194,304: one chunk here |

No black hole. 1,560 steps reach t = 65.5197, 308.6 Myr, the first pericentre: the centres come
to 6.65 kpc of each other there.

| file | what |
| --- | --- |
| `scene.json` | the scene file |
| `sample.json` | `TracerCheck.Sample`: the massive scene and the solver's settings with their bit patterns (as the solver check writes them), the counts, the tracers' angle and sort, the steps, maps and extent |
| `massive.bin` | the massive set, as `RunCheckpoint.saveMassive` writes it (124,793 particles, visible first) |
| `tracers.bin` | the tracers as drawn, before any kick: every state (position, formation time in w), then every motion (velocity bits, `TracerWord` in w), 16 bytes each, as `LightTracerChunk` holds them |
| `metal/` | the reference run, 1,560 steps |
| `metal-bit-all/` | the same run with every position's x, tracers and massive alike, moved to the next float up (`TracerCheck.nudged`, `SolverCheck.nudged`) |
| `digests.txt` | SHA-256 of the 20 data files |

## A run

Everything is little endian.

- **`run.log`**: the lines `scripts/tracer-drift.py` reads, `tracers N light, M massive visible,
  H halo`, then one `drift frame <step> t=<Myr> Myr` a map.
- **`density.tracers.npy`, `density.massive.npy`**: `DensityMap`, float32 of shape (9, 256, 256),
  the tracers and the massive visible particles counted on the xy plane over a square of half
  side 60 kpc centred on the origin, each as a share of its own count, at steps 0, 195, ..., 1,560.
- **`curves.csv`**: `SolverCurves` every 10 steps over every particle, tracers included (they
  weigh nothing, so the momentum and the centre of mass are the massive particles'; `formed`
  counts tracers and massive visible particles alike).
- **`accelerations-<step>.bin`**, at steps 0 (`metal/` and `metal-bit-all/`), 1 and 1,560
  (`metal/`): three floats a particle and a fourth zeroed, tracers first, then the massive
  particles.
- **`particles-<step>.bin`, `state-<step>.json`**, at steps 1 and 1,560 (`metal/`): what a
  checkpoint holds, `writeParticles(to:)` (positions, then velocities, 16 bytes a particle,
  tracers first; then the massive particles' formation times, 4 bytes each) and `solver.state`.

## What the Mac found

**The light stays on the mass.** `tracer-drift.py metal/run.log metal/density.npy`, the tracers
against the massive visible particles of the same run:

| Myr | chi2 a cell | binned 4x4 | light elsewhere | noise alone |
| ---: | ---: | ---: | ---: | ---: |
| 0 | 1.039 | 0.995 | 5.52 % | 5.40 % |
| 39 | 0.981 | 0.960 | 5.29 % | 5.51 % |
| 77 | 0.979 | 0.993 | 5.57 % | 5.54 % |
| 116 | 0.997 | 0.889 | 5.26 % | 5.56 % |
| 154 | 1.010 | 0.967 | 5.73 % | 5.63 % |
| 193 | 1.054 | 0.913 | 5.51 % | 5.65 % |
| 231 | 0.999 | 0.972 | 5.55 % | 5.51 % |
| 270 | 0.999 | 1.053 | 5.42 % | 5.17 % |
| 309 | 0.996 | 0.969 | 4.86 % | 4.75 % |

Two samples of one distribution: chi-square near 1 at every instant, and the light elsewhere
within 0.25 points of what Poisson noise alone moves (50 k massive particles make that noise
about six times #238's at 2 M).

**How far one bit goes.** `metal-bit-all/` against `metal/`, each set against itself, as
chi-square a cell and the share elsewhere binned 4x4 (a chi-square of 1 is two independent draws):

| Myr | tracers, chi2 a cell | 4x4 | elsewhere | massive, chi2 a cell | 4x4 | elsewhere |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | 0 | 0 | 0 % | 0 | 0 | 0 % |
| 77 | 0.0001 | 0.0000 | 0.004 % | 0.0001 | 0.0000 | 0.002 % |
| 154 | 0.0011 | 0.0001 | 0.027 % | 0.0016 | 0.0002 | 0.030 % |
| 231 | 0.0060 | 0.0009 | 0.081 % | 0.0083 | 0.0010 | 0.119 % |
| 270 | 0.0142 | 0.0019 | 0.124 % | 0.0204 | 0.0041 | 0.232 % |
| 309 | 0.0369 | 0.0045 | 0.188 % | 0.0530 | 0.0092 | 0.375 % |

At the pericentre the centres of the two runs are 1.7 and 3.9 pc apart and 1,176 against 1,169
stars have formed. At step 0 the accelerations of every position a bit away differ from
`metal/`'s by 3.4e-7 of their length in the median for the tracers (2e-7 for the massive
particles), 4.1e-4 at the 99th percentile (2.5e-4) and 2.5 % at most (1.4 %): unlike #274's run,
some cells open differently once every position has moved.

## Scoring a CUDA run

A CUDA run over this draw is a folder of the same files. `TracerCheck.Run` and
`TracerCheck.score` read and score it in Swift; with Python and `numpy`:

```
python3 scripts/tracer-drift.py <run>/run.log <run>/density.npy
```

scores the tracers against the massive particles of one run, and the same functions applied to
one set of two runs (`chi2`, `binned`, `elsewhere` of `tracer-drift.py`) put CUDA against Metal
beside `metal-bit-all/` against `metal/`.
