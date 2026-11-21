# The CUDA engine's first run on a GPU (#283)

2026-11-21, one rented RTX 3090 (24 GB, driver 615.71, CUDA 12.8.93) on Vast.ai, on demand, from
the MacBook M6 through `scripts/gpu-box.sh` (docs/notes/cloud-runs.md). Pierre asked for a
minimal bring-up: that it works, one check, no sweep of sizes; the timings on a 5090 and the runs
at several counts are left to #380 and #381.

## What passed the first time

- **`scripts/linux.sh engine-check`**: `sillage-cuda check` on the GPU library, against the
  reference outputs of `Tests/Fixtures/engines`: the tree as the fixture (20,000 particles, 3,890
  cells), the four frames at 50.3 to 68.0 dB of PSNR, the two frames from inside at 58.1 and 53.0
  dB, the black hole's run (positions 4.2e-7, velocities 1.9e-6) and its three stills at 54 dB.
  Building everything from nothing and the check: 6 min 40 s on 32 cores.
- **`scripts/linux.sh test-cuda --skip 'Timed|FaintLight'`**: 93 tests through the real kernels,
  the seven `gpu-only` ones of the tree (bounds, the radix sort's five, split) running for the
  first time. Among those that pass: the tree to the bit against the CPU's at 500 k at t = 0 and
  after 200 steps, the solver against direct summation at 500 k, a merger of 500 k repeated to the
  bit and resumed from its checkpoint, the tracers of 8 M drawn from 2 M repeated and resumed, a
  take pass written twice the same. 11 min with the build.
- **A scene of today's size, whole**: scene-0031 of the fixtures (the Antennae archetype, the
  Mac's full-pass comparison scene) at 8 M visible on 12 M of dark matter, `sillage-cuda hires
  --particles 8000000 --frames 24 --take-interval 1 --profile`: the settle (2,588 steps) and 24
  frames from 148 to 338 Myr through the first pericentre, 4,606 steps in 36 min, a take of 1.76
  GB, a peak of 4.25 GB on the host and 3.6 GB on the device.
- **Stills at 4K** from that take (`sillage-cuda still --preset 4k`): 5 to 7.6 s a frame, and the
  stills of a flight from inside an arm (`--flight`): 15 s from outside, 50 to 110 s from inside.

## What failed

| test | what | cause |
| --- | --- | --- |
| `theSpacingRecordsComeFromTheSolversTree` | the solver's spacing records against a builder's | the test: on a GPU the cells of a level come in the order the split's atomics gave them, a build to the next (`docs/notes/gpu-tree.md`); it compared the raw records. Fixed: both compared in the level order. |
| `theParticlePassesAgreeWithMetalAt4K` | failed without its data | the test: it required `SILLAGE_CUDA_RENDER_4K` instead of being skipped without it. Fixed. |
| `aTakePassKilledTwiceAndResumedWritesTheSameFiles` (3,000 particles) | the resumed take, curves, state and frames differ from the straight run's | **open** |
| `aRunStoppedAfterACheckpointAndResumedDrawsTheSameFrames` | the same for the full pass | **open** |
| `aTakePassOnTheGPUKilledTwiceAndResumedWritesTheSameFiles` (2 M) | the run was not stopped after its first checkpoint in the settle | **open**, probably the same |
| `aRunOnTheGPUStoppedAndResumedDrawsTheSameFrames` | the same, for the full pass | **open** |

A straight run repeats itself to the bit on the GPU, and the solver alone resumes to the bit from
a new process (the 500 k merger). What does not resume exactly is the take pass and the full pass
on the GPU, while the same tests pass on the CPU target. The difference between the two targets
is the tree: built on the GPU with a layout that varies run to run, on the CPU target laid out
canonically from the CPU's tree. Something in those passes' resume depends on that layout or
on state the GPU path holds and a checkpoint does not; not found yet. #380 needs it before an
interruptible box: it is the next thing to fix, on the CPU target first by giving its tree a
shuffled layout of the same kind, then on a short GPU session.

## Timings, on the RTX 3090

With `--profile`, which waits for the device after every phase:

| | RTX 3090 | M4 Max |
| --- | ---: | ---: |
| a massive step at 20 M simulated (8 M on 12 M), ms | 430 to 470 | 450 |
| of which the force pass | 230 to 270 | |
| of which the tree (bounds, Morton, sort, nodes, masses) | 33 | |
| of which halo centres and disk frames (CPU) | 35 | |
| a frame of the run at 480 by 270 (render), s | 1.5 to 3.5 | |
| a 4K still, s | 5 to 7.6 | |
| a 4K still from inside an arm, s | 50 to 110 | |

So the 3090 steps a scene of today at about the M4 Max's speed. At 0.19 $/h (0.22 with storage)
a whole scene of today, 2 to 4 hours on the M4 Max, would cost about 0.5 to 0.9 $ on it, about
what a 5090 three times faster costs at three times the price: the card is a choice of waiting
time more than of money. The 5090's factor is still to be measured (#380).

**From inside a galaxy, the still is not the GPU's**: user time equals wall time, one core, and
`--threads 32` changes nothing. Part of the point stars' work is on the CPU, on one thread. A 4K
flight of 10 s at 24 frames a second would take more than 5 h; #382 should find it before it
draws flights on a box. Here 8 processes drew the frames of a 10 s flight at 12 frames a second
side by side: 5 ran out of the 3090's 24 GB (a still from inside allocates its renders at twice
the size, 7680 by 4320, and its stars pass), and the 3 left drew 45 of the 120 frames at about
350 s each, slowed by one another. Two or three side by side is what a 24 GB card holds.

## Cost

See `docs/notes/gpu-ledger.md`. One box, 2 h 41 min, 0.65 $ of credit used (storage included).
