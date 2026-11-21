# Sticky gas on the tree's cells: the spike

The spike [Gas that dissipates](gas-that-dissipates.md) recommended, run on 2026-11-21 (#401). Gas
particles moved exactly as stars do, so the Mice's dust lanes came apart after the first passage
(#358, frame 2516). The question was whether a gas that loses its motion against the gas around it,
carried by the tree's own cells for a few percent of a step, gives the lanes back, and whether it
deserves an epic.

Everything here ran on the M4 Max, on the Mice of the flight (`scene-0067` of batch 20261104), cut
at 708 Myr: fifteen runs at 400,000 visible particles and a pair at 4 M, with and without. Times are
from the scene's start. The first passage is at 450 Myr, and 620 Myr, the flight's frame 2516, is
170 Myr after it, the moment the real Mice are seen at.

**In short.**

- **It works, at 2.3 % of a step, once the rule is changed.** Behind `--sticky-gas`, the gas that
  stayed in the disks sinks toward the nuclei after the passage and keeps thin dark lanes there and
  in the tails, where without it the gas spreads into a veil. A quiet disk is left as it was.
- **The note's rule fails on a quiet disk.** Holding each particle against its cell's mean velocity
  on every axis reads the disk's own shear as a collision: the gas layer goes from 63 pc to 7, and
  two thirds of the gas turns into stars before the galaxies meet.
- **What runs instead**: an inelastic collision along the line to the cell's other gas, a pressure
  floor that holds dense gas up over 2 kpc, and a gentle rate, one e-folding in 4 Myr. Without the
  floor, or at four times the rate, cold gas knots into beads.
- **The two numbers rule, and so does the count.** The rate sets how much gas reaches the nuclei,
  with no plateau. At 4 M the effect is about half what it is at 400,000: gas within 2 kpc of the
  nuclei at 620 Myr goes from 1.1 and 2.4 % to 3.0 and 4.4 %, where at 400,000 it went from 3.3 and
  6.0 % to 11.5 and 15.8 %. By the note's criteria that is drawing, not modelling.
- **Frame 2516 gets part of its lane back**: at 4 M the pixels over an optical depth of 2 from its
  camera go from 2,860 to 5,348, 72 % of what they were at 520 Myr (7,445).
- **Recommended next**: not the epic as written. A neighbour walk that keeps momentum and a floor
  set from the resolution would be the test of whether the count can stop ruling; until then the
  option is a look, worth keeping behind its flag for films of the Mice.

## What runs

`--sticky-gas on` on a render, an `explore` or a `hires`, or `stickyGas` in a scene file. Absent,
nothing is compiled, encoded or stored, and a scene replays as it did.

After the kick and the disk's cooling, four kernels (`BarnesHutShaders`):

1. `bhGasLeaves`, a thread a node: each leaf sums the mass, the momentum and the mass-weighted
   place of its unformed gas, and counts it.
2. `bhGasFold`, a dispatch a level from the deepest up: each branch is the sum of its children.
3. `bhGasChoose`, a dispatch a level from the root down: each node is given the cell its gas is
   held against, itself if it holds `cellGas` gas particles (16) and its parent's otherwise. The
   tree keeps no way up from a leaf, and this needs none.
4. `bhGasStick`, a thread a leaf: each gas particle of the leaf against that cell's *other* gas.

Nothing is kept from one step to the next: the cells' sums are made again from positions and
velocities, as the quadrupoles are, so a checkpoint and a take have nothing new in them. One thread
writes each leaf's particles and the folds go level by level, so a run repeats itself.

## The rule, and why it is not the note's

**The note's rule fails on a quiet disk.** It holds a particle against the cell's mean velocity on
every axis:

    w = v - (P - m v) / (M - m)
    if |w| > c:  v = v - w (1 - c / |w|) (1 - exp(-k dt))

At 400,000 particles a cell of sixteen gas particles is 300 to 900 pc wide, and a disk's own shear
across it is 20 to 40 km/s, above a sound speed of 10. The rule reads that shear as a collision,
and since it scales the whole of `w`, the motion across the plane is taken with it though nothing
puts it back, as rotation puts the shear back. At 300 Myr, both disks still alone:

| at 300 Myr, the two disks | without | the note's rule, k = 1 a Myr | k = one a crossing |
| --- | ---: | ---: | ---: |
| gas that has not formed stars | 97 % | 34 % | 64 % |
| thickness of the gas layer (median height inside 6 kpc) | 63, 64 pc | 7, 8 pc | 11, 14 pc |
| gas particles, formed or not, inside 1 kpc | 0.7, 1.6 % | 5.1, 15.3 % | 1.9, 5.1 % |

A layer ten parsecs thick, a seventh of the gas of one disk drained into its inner kiloparsec, and
two thirds of the gas turned into stars before the galaxies meet: the two risks the note named, "a
ceiling on random motion, not a floor" and "a viscosity where the shear is strong", at once. The
picture is a galaxy of bright knots with no dust.

**What runs instead is an inelastic collision along one line.** The particle meets the other gas of
its cell as one body, at that gas's centre of mass X and mean velocity:

    d = x - (X M - m x) / (M - m),  n = d / |d|
    closing = -w . n
    if closing > c:  v = v + n (closing - c) (1 - exp(-k dt))

Only the speed at which the particle closes on the gas ahead is lost. What it has across that line,
or away from it, is left alone, so a cell that turns loses nothing and a sheared one about a
quarter of what it did. It is the classical sticky particle (Schwarz 1981, in the note's sources),
with the cell's other gas for the second particle. It costs one more `float4` a node, the place.

**Dense gas keeps the motion that holds it up.** With that rule alone the layer is 22 to 30 pc and
88 % of the gas is left at 300 Myr, but cold gas knots: the lanes break into beads, each a bright
knot of new stars with a black dot in it, and neither a sound speed of 20 km/s nor a rate four
times slower changes that (table below). The sound speed is therefore never under

    c_eff = max(c, L sqrt(G rho))

where rho is the gas density of the cell and L a length, 2 kpc: a cloud smaller than L is held up
by the motion it is allowed to keep and does not collapse under its own weight. It is the pressure
floor the literature gives gas whose clouds it cannot resolve (the note's "stiffens the gas as it
gets dense", Springel and Hernquist 2003), and 2 kpc is the Jeans length of a real gas disk whose
clouds move at 10 km/s under 10 suns a pc² (100 / (4.30 × 10^-3 × 10) = 2.3 kpc). It costs
nothing: the cell's gas mass is the fold's. It is a floor on what is lost, not a push: gas that is
already slower stays slower.

**And the rate is gentle.** One e-folding in 4 Myr. The hole's gas wanted 50 e-foldings an orbit
because a crossing there lasts a few percent of one. A disk's gas meets the gas ahead of it all
the time, and at one e-folding a Myr it still knots (4 % of the quiet disks' gas, 11 % by 620 Myr).
Di Matteo et al. chose their collisions the same way, soft enough "to limit the formation of clump
instabilities".

The defaults: `c` 10 km/s, `k` 0.25 e-folding a Myr, sixteen gas particles a cell, no cell wider
than 2 kpc, `L` 2 kpc. `--sticky-gas <km/s>:<rate>:<crossing>:<cell gas>:<reach kpc>:<jeans kpc>`
sets them, an empty field keeping its default; `crossing` adds e-foldings a crossing of the cell
to the rate and is zero.

## The measures

How they are taken (`tools/` of the spike's folder, below): a dump of the particles and of the dust
target at a moment of the take (`export --dump-targets`), then

- **gas left**: the gas particles that have not formed stars;
- **the layer**: the median height of a disk's gas inside 6 kpc of its nucleus, along the thinnest
  axis of that gas;
- **inside 2 kpc**: the share of a galaxy's unformed gas within 2 kpc of its nucleus, the nucleus
  being the centre of its stars taken again in spheres down to 1.5 kpc;
- **knots**: the share of the gas more than 3 kpc from both nuclei that sits in a cube of 200 pc
  holding over thirty times what the median cube of a quiet disk holds (26 particles at 400,000);
- **the tails**: the distance from its nucleus inside which 99 % of a galaxy's visible particles lie;
- **dark pixels**: the pixels over an optical depth of 2 from the camera of the flight's frame
  2516, in a target of 1920 by 1080.

Two figures a galaxy are the larger one's, then the companion's.

### A quiet disk, and the Mice, at 400,000

Both disks at 300 Myr, 67 kpc apart and 150 Myr before they meet, stand for the quiet disk. The
calm-disk probe over 1 Gyr that the note asked for was not run: `probe-disk` does not carry the
option yet.

| at 400,000 | without | sticky gas |
| --- | ---: | ---: |
| **300 Myr, quiet disks** | | |
| gas left | 96.6 % | 96.1 % |
| the layer | 63, 64 pc | 57, 60 pc |
| gas particles, formed or not, inside 1 kpc | 0.7, 1.6 % | 0.8, 1.9 % |
| knots | 0.0 % | 0.0 % |
| **620 Myr, 170 Myr after the passage** | | |
| gas left | 91.3 % | 86.8 % |
| gas inside 2 kpc of its nucleus | 3.3, 6.0 % | 11.5, 15.8 % |
| the layer | 268, 318 pc | 170, 153 pc |
| median distance of the gas from its nucleus | 43, 12 kpc | 42, 8 kpc |
| knots | 0.0 % | 0.2 % |
| the tails | 74.8, 71.6 kpc | 74.3, 71.3 kpc |
| dark pixels from frame 2516's camera | 6,012 | 6,561 |
| the same without sticky gas at 520 Myr | 6,899 | |

Against the note's criteria: the layer stays between 50 and 200 pc, the gas inside 1 kpc moves
by a seventh and a fifth where a tenth was asked, under 1 % of the gas is in knots, the gas
inside 2 kpc of each nucleus has grown three times over, the tails are as long, and the dark pixels
of frame 2516 are 95 % of what they were at 520 Myr, where "at least" was asked.

The larger galaxy's gas as a whole is no nearer its nucleus: half of it is still beyond 42 kpc,
in the tails. Sticky gas does not hold a tail's gas back, and should not. What it changes is the
gas that stayed: it sinks, and it stays thin.

### The numbers do rule

Every run below is the collision along the line, at 400,000.

| | gas left at 300 Myr | the layer | knots at 300 Myr | inside 2 kpc at 620 Myr | knots at 620 Myr | gas left at 620 Myr |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| without sticky gas | 96.6 % | 63, 64 pc | 0.0 % | 3.3, 6.0 % | 0.0 % | 91.3 % |
| no floor, k 1 | 88.1 % | 22, 30 pc | 37.6 % | 10.5, 21.4 % | 37.9 % | 49.2 % |
| no floor, k 1, c 20 km/s | 92.7 % | 25, 42 pc | 26.1 % | 14.1, 27.6 % | 34.5 % | 61.0 % |
| no floor, k 0.25 | 92.8 % | 29, 41 pc | 24.5 % | 12.4, 18.2 % | 34.6 % | 64.7 % |
| L 1 kpc, k 1 | 94.2 % | 38, 42 pc | 15.0 % | 18.8, 27.1 % | 34.7 % | 79.0 % |
| L 2 kpc, k 4 | 94.8 % | 46, 47 pc | 9.8 % | 18.6, 34.6 % | 20.6 % | 80.2 % |
| L 2 kpc, k 1 | 95.6 % | 53, 55 pc | 3.9 % | 14.0, 21.3 % | 10.8 % | 84.4 % |
| **L 2 kpc, k 0.25** | 96.1 % | 57, 60 pc | 0.0 % | 11.5, 15.8 % | 0.2 % | 86.8 % |
| L 2 kpc, k 0.0625 | 96.4 % | 60, 62 pc | 0.0 % | 5.7, 8.4 % | 0.1 % | 90.3 % |
| L 2 kpc, k 0.25, c 5 km/s | 96.1 % | 58, 59 pc | 0.1 % | 10.1, 17.6 % | 0.3 % | 86.9 % |
| L 2 kpc, k 0.25, c 20 km/s | 96.2 % | 57, 59 pc | 0.0 % | 10.4, 15.7 % | 0.0 % | 87.3 % |
| L 4 kpc, k 0.25 | 96.4 % | 63, 62 pc | 0.0 % | 8.5, 14.4 % | 0.0 % | 88.0 % |

The bold row is the default. A run at L 1 kpc and k 0.25 was lost to the shared GPU and not run
again.

**The sound speed does not rule, and the reason is the floor.** From 5 to 20 km/s the figures are
the same to the noise of a run. In a disk the floor is above all three: the sound speed proper
only matters to gas too thin to be met often.

**The floor's length rules little from 2 kpc up**: at 4 kpc the quiet disk is untouched and a
quarter less gas reaches the larger nucleus. Under it the gas knots.

**The rate rules.** The note asked for "the same picture with the rate four times up and down". It
is not the same picture. Four times up the gas knots, four times down little gathers: the rate sets how much gas
reaches the nuclei, with no plateau between 0.06 and 4 a Myr, and the floor decides whether it
arrives as a lane or as beads. By the note's own words that makes the method "drawing, not
modelling" on this point: the two numbers are a setting of the picture, chosen where a quiet disk
is left as it was.

### At 4 M

The same pair of runs as a hires does them, 4 M visible and 6 M of halo, the step schedule on.

| at 4 M | without | sticky gas |
| --- | ---: | ---: |
| **300 Myr, quiet disks** | | |
| gas left | 88.9 % | 89.8 % |
| the layer | 54, 57 pc | 45, 49 pc |
| knots | 0.0 % | 0.0 % |
| **620 Myr** | | |
| gas left | 76.9 % | 71.9 % |
| gas inside 2 kpc of its nucleus | 1.1, 2.4 % | 3.0, 4.4 % |
| the layer | 424, 375 pc | 219, 281 pc |
| median distance of the gas from its nucleus | 47, 21 kpc | 43, 19 kpc |
| knots | 0.0 % | 0.2 % |
| the tails | 74.9, 71.3 kpc | 74.4, 70.9 kpc |
| dark pixels from frame 2516's camera | 2,860 | 5,348 |
| the same without sticky gas at 520 Myr | 7,445 | |
| **700 Myr** | | |
| dark pixels from the measuring camera | 24 | 3,631 |

The quiet disks are left alone and the tails keep their length, as at 400,000. But the gas that
reaches the nuclei is a quarter of what it is at 400,000, and the companion's gas half-mass radius
is 19 kpc where it was 8: **the count rules**, against the note's criterion of the same curve within
15 %. Two reasons are likely and neither was separated: a cell of sixteen gas particles is three
times narrower at 4 M, so the gas meets less of the shear and less of the other stream in each, and
the floor's length is fixed in kpc while the gas a cell holds is not. The images show it: thin dark
lanes at 4 M where the 400,000 run has thick ones, and in the tails a few filaments rather than a
band (the clips below).

Without sticky gas the dust at 700 Myr is all but gone from the measuring camera (24 pixels over an
optical depth of 2); with it, 3,631 remain.

## The cost

Measured alone on the GPU (the shared lock's `timing` mode), the Mice at 8 M visible and 12 M of
halo from their start, 100 steps profiled, twice each:

| | without | with |
| --- | ---: | ---: |
| a step | 459.8 ms | 472.0 ms |
| the sticky gas pass | | 11.0 ms |
| star formation, for scale | 10.7 ms | 10.7 ms |

2.3 % of a step, and the step grows by 2.6 %. The note's estimate was 2 to 3 %. One encoder holds
the forty-odd dispatches: an encoder each cost more than the levels did. On the GPU it is 36 bytes
for each node the tree has room for, 360 MB at 20 M simulated particles, where the note counted
on 16: the place is a second `float4`, and the cell each node reads is a word.

## What it does not do

- **It is not calibrated on anything.** The rate and the floor's length were chosen on one scene
  for leaving a quiet disk alone and keeping the gas out of knots. Between a rate that does nothing
  and one that knots there is a factor of sixteen, and the gas that reaches a nucleus goes with it.
- **Momentum is kept on average only.** The gas that is met is not pushed back. Two equal clouds
  thrown at each other at 100 km/s end up drifting at 14 km/s (`StickyGasTests`). The reaction
  would be one more fold of the kicks up to each cell and down again.
- **Star formation was left as it is**, and it reads the denser gas: 13 % of the gas has formed
  stars by 620 Myr where 9 % had. The rule has to be set again on a quiet disk before anything is
  said about bursts, and its compression term could then read the speed each particle has just
  lost.
- **The disks' cooling still acts on the gas** (`massiveDissipate`), before the encounter. The note
  would leave the gas out of it once it has a dissipation of its own. Not tried.
- **Light tracers' gas is not held.** A tracer is in no leaf. Every run here drew its massive
  particles only, so a film at 50 M from 8 M cannot use the option yet: its tracers' gas would stay
  spread while the massive gas sinks.
- **Metal only.** The four kernels are shared source and listed as pending in `cuda/kernels.txt`;
  the CUDA solver refuses a scene that asks for sticky gas.
- **No quiet disk over 1 Gyr**, no check that nothing lines up with the tree's axes beyond looking
  at the frames, and one scene, one orbit.
- **A stream is stopped over a few cells, not one.** Only the speed along the line to the gas
  ahead is lost, and that line is rarely the stream's. Two disks that pass through each other face
  on, each thinner than a cell, would mostly miss.

## Where things are

Outside the repository, on the Mac: `~/claude-workspace/epic-401-out`.

- `lib/<run>/scene-0067`: a scene folder a run, its take in it. `small-base` and `small-r025` are
  the pair at 400,000, `m4-base` and `m4-sticky` the pair at 4 M; the other `small-*` are the table
  above (`k1` and `x1` the note's rule, `v2a` no floor, `on` k 1, and so on).
- `tools/small.sh`, `final.sh`: a run. `dump.sh`, `measure.py`: the measures. `at.sh`, `clip.sh`:
  stills and clips of a flight. `timing.sh`, `profile.py`: the cost.
- `dumps/`, `stills/`, `clips/`, `logs/`.

The 4K clips of the 4 M pair are on the VPS, in `~/sillage-video/`, `avant` without and `apres`
with sticky gas:

- `mice-401-recul-2100-2520-{avant,apres}-4k.mp4`: frames 2100 to 2520 of the flight with time
  flowing (`dive-flowing`), the pull-out where the lanes went out.
- `mice-401-suivi-440-700-{avant,apres}-4k.mp4`: 440 to 700 Myr from a camera that follows the
  larger galaxy from 70 kpc below and 80 above (`tools/follow.flight.json`).
