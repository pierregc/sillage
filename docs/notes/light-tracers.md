# Light tracers: drawing eight million for the price of two (#187)

Spike asked on 2026-11-02, a follow-up of [gigantism](gigantism.md). Only about eight million
particles make a disk that fills the frame read as matter, and a real 8 M run is paid twice: the
force pass scales with the particles, and the softening follows their spacing, so the step
halves too. The idea: draw the scene at 8 M, give the mass to 2 M of them, and integrate the
other 6 M as massless tracers in the field of the massive ones. In a collisionless system a
massless particle drawn from the same distribution follows the same orbits, and tracers move
neither the softening nor the step.

Measured on the M4 Max on `library/2026-10-30-b/scene-0031`, the gigantism spike's scene. The
sheets, crops, logs and scripts are on the branch `assets/light-tracers-187` under
`docs/spikes/light-tracers/`; the takes stay on the Mac in `~/claude-workspace/tracers-187-out/`.

## How it is built

`sillage-render --particles 8000000 --massive 2000000` samples the scene at 8 M visible
(`--particles`), then `ParticleSystem.splittingLightTracers` keeps about 2 M of the visible
particles, and the same share of the dark matter, as the massive set, scaled so each galaxy's
kept particles carry all of its visible and of its dark mass. Black holes stay massive as they
are. The rest of the visible ones are tracers with no mass. The softening and the step are the
massive count's (`file.scene(particleCount: massive)`). Since #211 the dark matter is sampled
at the massive count to begin with (`ParticleSystem.lightTracers(drawn:massive:)`, 3 M for 2 M)
and kept whole, rather than drawn at 12 M for a quarter of it to be kept.

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
  a tracer's gas forms at the chance of the massive gas particle just before it in Morton order
  (below).
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
goes on ([step-cost-growth](step-cost-growth.md)), so the start stands for the run. A
megayear is at the step each count's hires takes: 0.021 for 2 M and for anything with 2 M
massive, 0.0112 for a real 8 M (fifteen steps a frame against eight: the softening falls from
55 pc to the 30 pc floor).

| drawn | massive | tracers' angle | a step | a megayear | against 8 M |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 2 M | 2 M | | 111 ms | 1.12 s | 7.6x cheaper |
| 4 M | 2 M | 0.9 | 150 ms | 1.52 s | 5.6x |
| 8 M | 2 M | 0.9 | 232 ms | 2.35 s | 3.6x |
| 8 M | 2 M | 1.1 | 190 ms | 1.92 s | 4.4x |
| 8 M | 2 M | 1.3 | 169 ms | 1.70 s | 5.0x |
| 16 M | 2 M | 0.9 | 391 ms | 3.95 s | 2.2x |
| 8 M | 8 M | | 449 ms | 8.51 s | 1x |

- **A tracer costs what a massive particle's walk costs**, 20 ns a step at the scene's angle,
  and nothing else of note: the tracers' sort is 6.8 ms a step at 6 M and their star formation
  0.8 ms. The 2 M run's own 111 ms stay: its tree (5 M with the halo) and its walk (90 ms).
  So 8 M drawn is the 2 M step plus 120 ms, and the count drawn costs linearly from there.
- **The real 8 M pays three times**: twenty million walkers instead of eleven (the halo grows
  with it, 12 M against 3 M), a tree four times the size (sort 23 ms, masses 15), and nearly
  twice the steps. The tracers keep the 2 M step, which is most of the saving.
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
the GPU: **38 min**, against 17 for the 2 M hires and about 2 h 20 for a real 8 M (the
library's cost fit, 62.4 ns a particle step, #185; the real 8 M run made for the pictures below
shared the GPU and took 3 h 27). 8.4 GB at the peak; a take of 3.1 GB at one frame in sixteen,
so 12 GB at the hires interval of four, as for any 8 M.

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
  residual map has no structure: no shell, no tail, no arm in it (`drift/drift-tr09.jpg`).
- **The tails and the disks too.** The share of light in tails and bridges ends at 29.04 % for
  the tracers and 28.93 % for the massive particles. Over every particle of the take, the rms
  extent of the tracers ends 0.11 % wider (54 kpc, so 60 pc), against 0.04 % between two random
  halves of the tracers: a hint of the light particles being pushed out by encounters with the
  heavy ones, too small to see. Each disk's thickness off the plane it turns in, over every
  disk particle of the take, agrees to 0.6 % at worst, where two halves of the tracers differ
  by up to 0.5 %.

## A looser angle for the tracers: no

The tracers' force against the same tracers walked at 0.3 (scene-0031 at t = 0, 2 M drawn,
500 k massive), and the radial part of the error, along the true pull:

| angle | mean error | p99 | along the pull |
| ---: | ---: | ---: | ---: |
| 0.9 | 0.56 % | 1.9 % | -0.17 % |
| 1.1 | 1.6 % | 6.5 % | -0.49 % |
| 1.3 | 3.8 % | 17 % | -0.97 % |
| 1.5 | 6.8 % | 26 % | -1.18 % |

The error does not stay random: it pulls short. The massive particles carry the 0.9 one, so at
0.9 the tracers err as the mass does; at 1.3 they are pulled about 0.8 % less than the stars
they were drawn with, and they drift out. The same hires with the tracers at 1.3 (and the very
same massive particles, which the tracers do not touch: their numbers match the 0.9 run's to
the digit) ends with the tracers 4 % wider in rms extent, a point more of the light in the
tails (29.9 against 28.9 %), disks up to 13 % thicker during the merger, and a chi-square of
2.5 a cell from the first frame up to 6 at the end (23 binned), 5.6 % of the light elsewhere
against 1.3 % of noise. A tracer walks at the scene's angle; 1.1 was not run in full.

## Does it look like eight million

The three takes of scene-0031, drawn with the same look and the auto camera framed on the
centres (so the pair at the pericentre and the remnant fill the frame), at four frames: 157 Myr
(two disks), 309 (pericentre), 639 and 879 (the remnant). `2M` is the massive particles of the
tracer run drawn alone (`--take-massive`): the same run, a quarter of the particles. `tracers`
is all 8 M of it. `real8m` is a real 8 M run of the scene, its own sample and its own dynamics
(softened at 30 pc, at a step of 0.0105, a little under the 0.0112 the hires stage would take).
Sheets and 1:1 crops in `sheets/`.

| frame | 2 M | 2 M + 6 M tracers | real 8 M |
| --- | --- | --- | --- |
| 157 Myr | blots, arms as dotted bands | fine continuous texture | the same, arm edges a little crisper |
| 309 Myr | coarse sand on the bridge and tails | fine | fine, more bright compact knots |
| 639 Myr | the remnant mottled | smooth body, fine grain | smooth body, fine grain |
| 879 Myr | mottled all over | smooth | smooth, its own satellites |

The grain score's structure band (the 4 to 16 px blots that make a disk read as particles,
`grain.py` from #182; the fine band is not comparable across counts) says the same: 0.129,
0.129, 0.108, 0.098 at 2 M over the four frames, 0.115, 0.091, 0.078, 0.074 with the tracers,
0.121, 0.095, 0.073, 0.069 for the real 8 M.

- **The texture is the drawn count's.** What made 8 M read as matter in #182 is how many points
  the eye averages, and the tracers give that exactly: at every frame they are as fine as the
  real run and far from the 2 M blots.
- **The shapes are the massive count's.** The arms, tails, satellites and knots are those of the
  2 M dynamics, softened at 55 pc against 30. The real 8 M keeps its arm edges a little crisper
  before the encounter and grows more bright compact knots at the pericentre; its satellites
  are its own, as any second run of a scene would make. Nothing else in the frames reads as a
  lower resolution.

## What was decided

Pierre left the calls to the thread on 2026-11-03.

1. **Light tracers are the way to draw 8 M.** For the cost of a 2 M run and a bit (2.35 s a
   megayear against 8.5, a hires of 38 min against two hours and more), the frame has
   the texture of 8 M, the light stays on the mass through a whole merger, and the tracers' gas
   forms its stars at the massive gas's rate. Merged behind `--massive`, which nothing passes
   yet: the nights' hires (#185 made it a real 8 M) move to 8 M drawn from 2 M massive in a
   follow-up ticket, with the hires stage giving the step and the settle from the massive count,
   `costs` fitting the massive and the traced particles apart, and the dark matter sampled at the
   massive count rather than drawn at 8 M and three quarters thrown away.
2. **The tracers walk at the scene's angle.** 1.3 drifts; 1.1 would save a fifth of the step
   and was not measured in full.
3. **More than 8 M drawn costs linearly:** 16 M drawn from 2 M is still 2.3 times cheaper than a
   real 8 M. Worth it only where the frame is filled at 4K and beyond.

## In the nights (#211)

Done on 2026-11-04. A night's hires is drawn at 8 M with the mass on 2 M (`hires.massive`,
Auto), and `hires --massive M` takes its softening, its step and its settle from M, so the steps
halve before a tracer costs anything: the two stories of the 2026-10-30 night take 14 964 and
14 042 steps from 2 M against 28 681 and 28 084 as real 8 M. `hires.json` keeps `massive`
beside `particles`; a record without it was a run in which every particle carried mass, and a
real 8 M already done stands for 8 M from 2 M when a night resumes. The tracers walk at the
scene's opening angle, and `hires` refuses `--theta-tracers`.

- **The dark matter is drawn at the massive count**: 3 M for 2 M, kept whole, where the halo
  was drawn at 12 M for a quarter of it to be kept. The sample of scene-0031 is 11 M particles
  instead of 20 M, and sampling and splitting it peak at 1.8 GB instead of 2.5; it is hardly
  faster (13.3 s against 14.4, the disks are most of it), and the run's own peak is the take's.
- **`costs` prices the tracers apart.** The massive steps are fitted as before, on the runs
  without tracers, and the tracer steps on what the runs with tracers took past that, as a line
  through zero (20 ns a step before any run). Every night draws 8 M from 2 M, so its runs alone
  could not tell the two terms apart. On the library's history the massive line comes out as it
  was, 108 s + 62.4 ns a step, and `costs --check` gives the same rows as before.
- **The first night with tracer hires**, in a library of its own (four previews at 50 000 a
  galaxy, one pick: scene-0002 of seed 20261104, a spiral and a globular), ran its hires of 487
  frames over 8 071 + 6 818 steps in 66 minutes, 63 planned. A real 8 M of the same story would
  be 18 080 steps (its softening is near the floor already, so the step gains less than usual),
  2 h 32 by the model. Its take of 6.1 GB drew and exported like any other: the style step in
  11 s, the 4K export in 32 s. Refitted on it, a tracer step costs 22 ns over the library's
  massive line, 23.5 over the fallback's.

## In the app (#222)

Calculer en haute résolution, on a scene page and on Choisies, draws as a night does: past 2 M,
2 M carry the mass and the others are light tracers, and every size of the menu is priced with
its tracers. Auto stops at a night's 8 M, the most that ends before seven otherwise, so a hires
asked from the app is one a night finds done (same count drawn, as many massive); at the
machine's maximum it queued a real 10 M of about eight hours. The menu offers 8 M besides 1, 2,
5 and 10 M. A real count, every particle massive, is left to the command line (`hires` or
`queue add hires` with `--particles` and without `--massive`).

## On the command line (#243)

`hires` and `queue add hires` without `--particles` drew a real count at the machine's maximum,
10 M, so `hires <batch>`, which the night manager's guide gives for every yes scene, queued runs
of several hours each. They now draw what a night draws, its 8 M (the maximum below that) from
2 M massive, `--massive` aside, through one rule (`SceneFolder.hiresDraw`) that the batch's skip
(`hiresDone`), a queued job's price and its title read too. A scene a night finished, or one
done at a real 8 M, is skipped. `--particles N` alone stays a real N.
