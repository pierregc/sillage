# Light tracers: drawing eight million for the price of two (#187)

Spike asked on 2026-11-02, a follow-up of [gigantism](gigantism.md). Only about eight million
particles make a disk that fills the frame read as matter, and a real 8 M run is paid twice: the
force pass scales with the particles, and the softening follows their spacing, so the step
halves too. The idea: draw the scene at 8 M, give the mass to 2 M of them, and integrate the
other 6 M as massless tracers in the field of the massive ones. In a collisionless system a
massless particle drawn from the same distribution follows the same orbits, and tracers move
neither the softening nor the step.

## How it is built

`sillage-render --particles 8000000 --massive 2000000` samples the scene at 8 M visible
(`--particles`), then `ParticleSystem.splittingLightTracers` keeps about 2 M of the visible
particles, and the same share of the dark matter, as the massive set, scaled so each galaxy's
kept particles carry all of its visible and of its dark mass. Black holes stay massive as they
are. The rest of the visible ones are tracers with no mass. The softening and the step are the
massive count's (`file.scene(particleCount: massive)`).

In the solver (`MetalBarnesHutSolver(..., tracers:)`) the tracers come first in the buffers,
`[tracers | massive visible | massive halo]`, so the visible particles stay one run for the
renderer and the take, and the tree is built over everything after the tracers
(`GPUTreeBuilder(first:)` binds the buffers at that offset). Then:

- **Force.** The force kernel is specialised by a function constant (`bhTracer`): a tracer
  reads its position from its own buffer, no leaf ever holds it, and it writes no traversal
  cost. Its opening angle is its own (`tracerOpeningAngle`, `--theta-tracers`), since its
  force error does not feed back. The tracers are sorted into Morton order with a second
  `GPUTreeBuilder` that only runs bounds, codes and the sort, so neighbours in a SIMD group
  walk alike.
- **Kick, drift, cooling, black holes.** Unchanged and over every particle: they are per
  particle already, and a hole's reaction is weighted by the mass, which a tracer does not have.
  The halo centres and the disk frames are summed over the massive particles only.
- **Star formation.** The rule reads density and compression off a leaf, and tracers are in no
  leaf. Each leaf writes its chance into its gas slots (function constant `bhLeafChances`), and
  a tracer's gas forms at the chance of the massive gas particle just before it in Morton order.
  See below for why not the leaf that holds it.
- **Smoothing.** The solver's tree holds none of the tracers, so `writeSmoothing` declines and
  `SmoothingField` builds its own tree over the drawn particles, as playback always did.

`--take-massive path` writes a second take of the same run with the massive particles alone,
and `--density` also writes the maps of each set, which `scripts/tracer-drift.py` compares.
`--profile` prints each pass's GPU time per step. With no `--massive` nothing changes: the
default run, its curves and its take are the same to the bit as before (scene-0031 at 200 k,
120 steps, against the base commit; the take's JSON header differs only in key order, as it
always did).

## What a step costs

Measured alone on the GPU (M4 Max), scene-0031 of 2026-10-30-b (two spirals, the gigantism
spike's scene), 60 steps after 4 of warm-up, from t = 0. Steps no longer get slower as a run
goes on ([step-cost-growth](step-cost-growth.md)), so the start stands for the run. The step is
the one each count's hires uses: 0.021 for 2 M and for anything with 2 M massive, 0.0105 for a
real 8 M, since the softening halves.

| drawn | massive | tracers' angle | a step | a megayear | against 8 M |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 M | 2 M | | 111 ms | 1.12 s | 8.1x cheaper |
| 4 M | 2 M | 0.9 | 150 ms | 1.52 s | 6.0x |
| 8 M | 2 M | 0.9 | 232 ms | 2.35 s | 3.9x |
| 8 M | 2 M | 1.1 | 190 ms | 1.92 s | 4.7x |
| 8 M | 2 M | 1.3 | 169 ms | 1.70 s | 5.3x |
| 16 M | 2 M | 0.9 | 391 ms | 3.95 s | 2.3x |
| 8 M | 8 M | | 449 ms | 9.07 s | 1x |

- **A tracer costs what a massive particle's walk costs**, 20 ns a step at the scene's angle,
  and nothing else of note: the tracers' sort is 6.8 ms a step at 6 M and their star formation
  0.8 ms. The 2 M run's own 111 ms stay: its tree (5 M with the halo) and its walk (90 ms).
  So 8 M drawn is the 2 M step plus 120 ms, and the count drawn costs linearly from there.
- **The real 8 M pays three times**: twenty million walkers instead of eleven (the halo grows
  with it, 12 M against 3 M), a tree four times the size (sort 23 ms, masses 15), and twice the
  steps. The tracers keep the 2 M step, which is most of the saving.
- **A looser angle for the tracers alone** halves their walk at 1.3 (48 ms against 111). It is
  not free, below.

## Star formation without a leaf

The rule reads a leaf: its baryon density and the convergence of its flow decide a chance per
step for each gas particle in it ([star formation](star-formation.md)). A tracer is in no leaf,
so its gas has to borrow a chance. What is kept: every leaf writes its chance into its gas
slots, and a tracer's gas walks back from its place in the sorted codes to the first massive gas
particle and forms at that chance. Drawn from the same distribution, a tracer's gas is equally
likely to follow any massive gas particle, so the chances it reads are distributed as theirs
are, and the one it reads is almost always from its own cell or the next one.

The first test said otherwise: tracer gas formed a third less than the massive gas over 400
steps of an isolated disk (1.27 % of it against 1.84 %), and two other readings gave the same
(the cell that holds the tracer, found by its Morton code in the tree's frame, and the leaf of
whatever massive particle comes before it). The fault was the test's: it sampled at 80 k and
softened for 80 k with 40 k massive. Softened for twice the particles there are, massive
particles pull each other into pairs and clumps below the softening, which a tracer cannot
join, and the massive gas's own leaves come out denser. With the massive count's softening,
400 k drawn and 200 k massive, the kept reading agrees: 1.72 % of the tracers' gas formed in
320 steps and 1.72 % of the massive gas (759 and 757 knots), 178 against 184 after 80. The
other two readings were not tried again. The tracers must have the massive count's softening,
which `--massive` gives them.

## Whether the light stays on the mass

The whole hires of scene-0031 again (923 frames, 157 to 887 Myr through the pericentre at
305 Myr and the tails after it), drawn at 8 M with 2 M massive and the tracers at 0.9, alone on
the GPU: **38 min**, against 17 for the 2 M hires and about 2 h 40 for a real 8 M (the `costs`
fit). 8.4 GB at the peak; a take of 3.1 GB at one frame in sixteen, so 12 GB at the hires
interval of four, as for any 8 M.

At twelve instants the tracers and the massive particles are counted on the same grid
(`--density`, 256 cells across 120 kpc), and `scripts/tracer-drift.py` compares the two maps
against the Poisson noise of their counts:

| Myr | chi2 a cell | binned 4x4 | light elsewhere | noise alone |
| ---: | ---: | ---: | ---: | ---: |
| 158 | 1.00 | 0.96 | 0.90 % | 0.92 % |
| 290 | 1.00 | 1.03 | 0.88 % | 0.82 % |
| 423 | 1.03 | 1.02 | 1.13 % | 1.07 % |
| 556 | 1.04 | 1.05 | 1.37 % | 1.29 % |
| 688 | 1.04 | 1.05 | 1.40 % | 1.30 % |
| 887 | 1.01 | 1.03 | 1.28 % | 1.22 % |

- **The maps are the same distribution to within a few per cent of the noise.** A chi-square of
  one per cell is two samples of one distribution; the tail goes to 1.05 at most. The share of
  light that sits somewhere else is what the noise alone moves, within a tenth of a point. The
  residual map has no structure: no shell, no tail, no arm in it (`drift.png` on the assets
  branch).
- **The tails and the disks too.** The share of light in tails and bridges ends at 29.04 % for
  the tracers and 28.93 % for the massive particles. Over every particle of the take, the rms
  extent of the tracers ends 0.11 % wider (54 kpc, so 60 pc), against 0.04 % between two random
  halves of the tracers: a hint of the light particles being pushed out by encounters with the
  heavy ones, too small to see. Each disk's thickness off the plane it turns in, over every
  disk particle of the take, agrees to 0.6 % at worst, where two halves of the tracers differ
  by up to 0.5 %.
