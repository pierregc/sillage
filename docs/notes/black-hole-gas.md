# A gas for the black hole close up that can be trusted

The close up's credibility rests on its gas ([the spike](black-hole-close-up.md), #314): tracers
pass through each other, so something has to take energy where streams meet, and the spike's grid
did it with three numbers nothing had calibrated. #334 reads four published disruptions, builds
the crossings in three dimensions, and sets the numbers against them.

**In short.**

- **The spike's viscosity made the first passage, not the gas.** Of the 18 points of the cloud
  that came out of the first pericentre bound (48 % at the release, 66 % after), none came from the
  crossings: a run with no gas at all keeps 48 %, and one with the viscosity alone gets 66 %. A
  loss of angular momentum acting on every tracer binds a stream that is not a disk yet. Published
  simulations leave about half bound (Shiokawa et al.: 46 %).
- **The spike's stickiness was too slow for anything to circularise.** A stream goes through
  another in a few per cent of an orbit, in which two e-foldings an orbit take a tenth of the
  relative motion, so they went through each other. From 20 e-foldings up the disk forms the
  same; the new default is 50.
- **The crossings are in three dimensions now**: a grid of the mean flow in log r, angle and
  height over the radius, each tracer pulled towards the mean of the *others* round it. A stream
  squeezed through the plane makes at most a twentieth of the heat it made in the plane's grid,
  and the first passage binds half as much: 0.4 points instead of 0.8 at a crossing speed of 0.1.
- **Calibrated, the cloud circularises in about 7 P\*** (P\* is the Kepler period of the most
  bound debris, 700 time units), to a ring of eccentricity 0.3 at 11 r_s: 1 to 10 P\* in Bonnerot
  et al., 3 to 10 in Shiokawa et al., whose flow ends at a mean eccentricity of 0.3 to 0.4. The
  ring sits at the circular radius of the bound half's mean angular momentum, 10.9 r_s.
- **What still differs**: the disk is thin, 0.02 of its radius where simulations with a gas that
  keeps its heat have 0.07 to 0.13 or 1; no tracer is swallowed where the simulations lose 3 to
  28 % through their inner edges; and the cloud is fat. Details at the end.

## What the papers say

Read for this ticket, from their text (arXiv), not from memory. Units: R_g = GM/c² = r_s / 2.

| | the disruption | what it reports |
| --- | --- | --- |
| Bonnerot, Rossi, Lodato & Price 2016 ([1501.04635](https://arxiv.org/abs/1501.04635)), MNRAS 455, 2253 | SPH, relativistic precession exact (Tejeda and Rosswog's potential), 1 M☉ star on a bound orbit round 10⁶ M☉, e = 0.8 or 0.95, β = 1 or 5: R_p = 9.4 R_g, a\* = 47 R_g for e = 0.8 | The stream is untouched until it crosses itself at 1.2 P\* (P\* the star's orbit, from the return of the most bound debris), by precession (89.7° a turn at β = 5). Gas that cools at once: the mean energy reaches the circular orbit's at 8 P\* and the debris form a thin ring a little outside R_circ = (1 + e) R_p, with 3 % accreted (under 5 % at the best resolution); at e = 0.95 the first crossing is at 0.15 P\* and the ring is there by 1 P\*; at β = 1 it takes 16 P\*. Gas that keeps its heat: a thick torus between R_circ and a\*, 26 % accreted and 91 % still bound at 8 P\*. Without precession (a Kepler potential) nothing circularises. t_visc / P\* is 3 × 10³ for the thin ring (α = 0.1, H/R = 0.01) and 2 for the torus (H/R = 1) |
| Shiokawa et al. 2015 ([1501.04365](https://arxiv.org/abs/1501.04365)), ApJ 804, 85 | General relativistic hydrodynamics, a parabolic disruption of a white dwarf by a 500 M☉ hole, R_p = 100 R_g, a_min = 500 R_g, followed for 12 P\* | 46 % of the star bound, 54 % not. Shocks near the pericentre and, by precession, near the apocentre of the most bound debris; they bring the characteristic radius to a_min, not to 2 R_p. 3 to 10 P\* to gather 80 % of the bound mass; mean eccentricity 0.3 to 0.4 over most of the flow at the end; at 12 P\* a third of the bound mass is within 2 R_p, half within 6 R_p, three quarters within 16 R_p, and 28 % went through the inner boundary at 0.3 R_p, half of that after 6 P\* |
| Andalman, Liska, Tchekhovskoy, Coughlin & Stone 2022 ([2008.04922](https://arxiv.org/abs/2008.04922)), MNRAS 510, 1627 | General relativistic hydrodynamics, β = 7, R_p = 7 R_g, a hole spinning at 0.94, parabolic, realistic mass ratio | A disk forms by five violent self-intersections about 12 hours apart, then stream-disk shocks at the pericentre; about 20 % of the infalling mass reaches the hole; mean eccentricity 0.88; the disk's scale height over its radius 0.069 at 1.4 days and 0.132 at 5.7; the debris' pericentre moves from 7 to about 12 R_g |
| Liptai, Price, Mandel & Lodato 2019 ([1910.10154](https://arxiv.org/abs/1910.10154)) | General relativistic SPH, Kerr, bound orbits, e = 0.8 and 0.95, β = 1 and 5 | Without cooling a thick torus, H/R about 1, surface density as r⁻³, out to the star's apocentre; with efficient cooling a narrow ring near the pericentre |

Hayasaki et al. 2013 and 2016, Piran et al. 2015 and Lu and Bonnerot 2020, which the three
first ones lean on, were not read here.

**Where the scene sits among them.** The closest is Bonnerot et al.'s RI5e.8: a\* = 47 R_g
against the cloud's a_min = 23.5 r_s = 47 R_g, pericentre 12 R_g against 9.4. The cloud's most bound
orbit has e = 0.75 and general relativity would turn it by 52° a turn, between RI5e.8's 90° and
RI1e.8's 14°; Paczyński and Wiita's potential gives about 85 % of general relativity's (36°
against 43° at the spike's own check). It is a
parabolic disruption, as Shiokawa's and Andalman's, with a_min / R_p = 3.9, near Shiokawa's 5 and
far from a real star's 250 at β = 5: the cloud's radius is 0.25 of its pericentre, a star's 0.05
to 0.07, so it is fat. Its gas, which radiates what it dissipates at once, is Bonnerot's and Liptai's cooling
case: a thin ring, not a torus.

## The gas

The tracers still deposit their velocities on a grid each step and are pulled towards the mean
flow round them where they cross; what changed is the grid and the numbers.

- **A grid in three dimensions** (`GasGrid`): 192 rings in log r from 1.5 to 200 r_s, 384 sectors,
  and 32 layers of height over the cylindrical radius, 1/64 each, so a cell is about as tall as
  wide and the grid reaches 0.25 of the radius over and under the plane. A tracer's mean is
  taken over eight cells, trilinear, without its own deposit; a tracer with fewer than one other's
  worth of neighbours feels nothing. The tracers per unit area that the temperature reads come from
  the column, summed over the layers by a new kernel (`holeColumn`). `--grid-heights 1` is the
  spike's grid.
- **Stickiness 50 e-foldings an orbit** (was 2): see the sweep.
- **Crossing speed 0.1** of the circular speed (was 0.3): the motion against the mean that counts,
  and so the gas's sound speed, and what its disk is as thick as. 0.1 is in the 0.07 to 0.13 that
  Andalman et al. measure.
- **Viscosity 2500 orbits** (was 40): a thin disk's is 1 / (2π α (H/R)²) orbits, 4000 for α = 0.1
  and H/R = 0.02, and a run of 7 P\* is 24 orbits at 11 r_s. Bonnerot et al. put the ring's at
  3 × 10³ P\*.

## Calibration

1 M tracers, the default scene, to 5000 time units (7.2 P\*), each row one run. `circ` is the mean,
over the bound tracers within 6 R_p (the flow), of their energy in that of the circular orbit with
their angular momentum: 1 for a circular orbit. `e` is their mean eccentricity from their turning
points, `in2` the share of the cloud's bound half within 2 R_p, `swallowed` the share of all
tracers. `scripts/gas-curves.py` draws the curves.

| | bound after the pericentre | circ and e at 4 P\* | circ and e at 7 P\* | in2 at 7 P\* | swallowed at 7 P\* |
| --- | --- | --- | --- | --- | --- |
| the spike: plane grid, 2, 0.3, 40 | 0.653 | 0.71, 0.52 | 0.70, 0.52 | 0.09 | 27 % |
| **this: 3D grid, 50, 0.1, 2500** | **0.486** | **0.84, 0.37** | **0.91, 0.28** | **0.27** | **0** |
| the plane grid, the same numbers | 0.491 | 0.89, 0.29 | 0.93, 0.25 | 0.28 | 0 |
| stickiness 2 | 0.482 | 0.30, 0.84 | 0.55, 0.66 | 0.05 | 0 |
| stickiness 20 | 0.484 | 0.80, 0.41 | 0.90, 0.30 | 0.26 | 0 |
| stickiness 200 | 0.489 | 0.81, 0.42 | 0.87, 0.35 | 0.20 | 0 |
| crossing speed 0.05 | 0.500 | 0.85, 0.34 | 0.91, 0.28 | 0.30 | 0 |
| crossing speed 0.2 | 0.482 | 0.80, 0.42 | 0.89, 0.31 | 0.24 | 0 |
| crossing speed 0.3 | 0.482 | 0.75, 0.49 | 0.88, 0.31 | 0.22 | 0 |
| viscosity 40 orbits | 0.657 | 0.88, 0.21 | 0.84, 0.27 | 0.06 | 32 % |
| viscosity 160 | 0.529 | 0.87, 0.32 | 0.96, 0.14 | 0.46 | 0 |
| viscosity 400 | 0.502 | 0.85, 0.35 | 0.92, 0.26 | 0.39 | 0 |

- **Stickiness**: 20 to 200 give one disk; 2 gives none within the run. The disk's energy loss is
  limited by where streams meet, not by how fast the gas takes hold, once it takes hold within a
  crossing.
- **The crossing speed** matters at the first pericentre only below 0.1: the cloud is squeezed
  through the plane there with vertical speeds of 0.05 to 0.25 of the circular speed, and at 0.05
  the nozzle shock, real but small, binds two points (Guillochon et al. and Shiokawa et al. put
  what it dissipates at θ² of the orbital energy, θ the stream's angular thickness: Kochanek 1994, as
  Shiokawa et al. quote it). From 0.1 to
  0.3 the disk is the same within the scatter between runs, 0.05 in the late columns.
- **Viscosity** is the one that moves the story: 40 orbits binds 18 points at the first
  pericentre, 160 five, 400 two; 40 also swallows a third of the cloud by 7 P\* and drains
  the ring to 6 r_s. From 400 up it changes nothing a viewer sees in 7 P\*.
- **Heating**: the gas starts to heat at 1.3 to 1.4 P\* in every run that circularises, 0.3 to 0.4
  P\* after the most bound debris come back, and peaks at 3.1 to 4.1 P\*; in the reference run a
  second burst follows at 5.5 to 6.5 P\* (`heating` in the CSV).

### The first passage, in three dimensions or not

The binding of the first pericentre with no viscosity, 1 M tracers, 100 time units on:

| crossing speed | the plane's grid | the grid with height |
| --- | --- | --- |
| 0.02 | +3.3 points | +3.9 |
| 0.05 | +2.2 | +1.5 |
| 0.1 | +0.8 | +0.4 |
| 0.2 | 0.0 | 0.0 |
| 0.3 | 0.0 | 0.0 |

From 0.05 to 0.1 the grid with height takes half the binding; below, at 0.02, the squeeze is
what it takes for a crossing on the scale of its own cells, and the nozzle shock it finds is real.
The spike's note has 81 % bound at a crossing speed of 0.1 against 66 % at 0.3; on the spike's
code as merged, with its plane grid, stickiness 2 and viscosity 40, they are 66.6 % and 66.2 %,
and the 18 points are the viscosity's.

And a unit test (`aSqueezeThroughThePlaneIsNotACrossingWithHeight`): tracers falling towards the
plane from both sides at 0.05 of the circular speed, at a crossing speed of 0.05, make a twentieth
of the heat in the grid with height that the plane's grid makes.

### Resolution

| | circ, e at 4 P\* | at 7 P\* |
| --- | --- | --- |
| 250 000 tracers | 0.58, 0.64 | 0.86, 0.35 |
| 1 000 000 | 0.84, 0.37 | 0.91, 0.28 |
| 4 000 000 | 0.85, 0.36 | 0.90, 0.30 |
| 6 000 000, the scene's | SIX_FOUR | SIX_SEVEN |
| 16 layers of height | 0.85, 0.35 | 0.90, 0.30 |
| 32, the default | 0.84, 0.37 | 0.91, 0.28 |
| 64 | 0.77, 0.45 | 0.86, 0.35 |

One million tracers and more draw the same disk, and so do 16 and 32 layers. Fewer tracers or
thinner layers leave fewer tracers in a cell, a cell needs another tracer's worth of neighbours
to feel any, and the gas takes hold later: at 250 000 the disk is a third of the way at 4 P\*.
The grid is summed with float atomics, so two runs differ by about 0.05 in the late columns.

## Against the papers

2 M tracers, the default scene to 12 P\* (8400 time units), against what the papers report at the
same P\* or the same end:

| | the papers | here |
| --- | --- | --- |
| bound after the first passage | 46 % (Shiokawa) | 48.6 %, from 47.9 at the release |
| first self-crossing | 1.2 P\* after the first return at e = 0.8, 0.15 P\* at e = 0.95 (Bonnerot) | 1.3 to 1.4 P\*, 0.3 to 0.4 after the first return: the stream is long, as e = 0.95's |
| circularised | the mean energy reaches the circular orbit's at 8 P\* at e = 0.8, 1 P\* at e = 0.95 (Bonnerot); 3 to 10 P\* to gather 80 % (Shiokawa) | circ 0.84 at 4 P\*, 0.91 at 7, 0.93 at 12 |
| where | a ring a little outside R_circ (Bonnerot); the characteristic radius at a_min, not 2 R_p (Shiokawa) | the median radius of the flow 10.8 r_s at 7 P\*, 10.3 at 12, first and last quartile 8.7 and 12.3; R_circ of the cloud's centre 12.1, of the bound half's mean momentum 10.9 |
| eccentricity | 0.3 to 0.4 at 12 P\* (Shiokawa); 0.88 (Andalman, spinning, real mass ratio) | 0.29 at 7 P\*, 0.25 at 12 |
| height over radius | 0.07 to 0.13 (Andalman); thin ring when cooling is efficient (Bonnerot, Liptai); about 1 for a torus | 0.02 |
| within 2, 6 and 16 R_p at 12 P\* | a third, a half, three quarters of the bound (Shiokawa) | 0.45, 0.55, 0.57 |
| swallowed | 3 % at 8 P\* when cooling is efficient, 26 % when not (Bonnerot); 28 % of the bound by 12 P\* through 0.3 R_p (Shiokawa); about 20 % (Andalman) | 0 |

The shares within 16 R_p are of the tracers bound at the release: 43 % of them are beyond 96 r_s
at 12 P\*, where Shiokawa's leaves 25 %. The cloud's spread of energies is not a star's, and the two
were not compared.

## What still differs

- **The disk is cold.** The gas radiates what it dissipates at once, which is Bonnerot's and
  Liptai's efficient cooling, and what those find in that case is a thin ring; the 0.02 here is
  that ring, not Andalman's 0.07 to 0.13 or the torus of a gas that keeps its heat. A share of
  each dissipation kept as random motion, a pressure, would thicken it; the crossing speed is
  already the sound speed, and the fraction that stays is the missing knob.
- **Nothing is swallowed**, and the ring has an inner edge at 8 r_s, not at the last stable
  orbit. The papers' 3 to 28 % come from the shocks scattering angular momentum, or from
  numerical viscosity that the grid here does not share: the sticky gas conserves momentum pair by
  pair. A viscosity of 160 orbits does carry the ring in to 6 r_s by 7 P\*, but binds five points at
  the first pericentre; it is a speed-up of time for a video, not a physics. The
  scene's `viscousOrbits` stays a scene option for that.
- **The cloud is fat** (radius 0.25 of the pericentre), the potential precesses 85 % of general
  relativity's, and the hole does not spin: with a spin and a tilted orbit, nodal precession
  delays the crossings (Liptai et al., Andalman et al.).
- **Four papers were read for the numbers their text gives**; no figure was digitised, so a
  range in a column is the range the text has.

## Stills

<!-- STILLS -->

## For a flight through the scene

The epic's end is flying inside a scene with a hole. What the gas gives a flight:

- **Where the gas is**: from 2 P\* the stream and its crossings, from 4 P\* a ring 8.7 to 12.3 r_s
  out (quartiles), 0.02 of its radius thick, so about 0.2 r_s: a sheet that a camera crosses in
  a few frames. Nothing plunges, so there is no gas inside the last stable orbit.
- **The light**: the heating that the Physics look draws peaks at 3 to 4 P\* and falls to a fifth of
  its peak by 7 P\*, so a flight that holds the exposure of one moment (`exposureAt` in the look)
  sees the settled ring dim against the crossings.
- **Cost**: the step costs TIMING.
- **State**: the grid is rebuilt from the tracers each step, so a take's frames (positions and
  velocities) are enough to go on from, as #332's export does when a frame sits between two.

## How to run it

    DYLD_LIBRARY_PATH=.build/dev .build/dev/sillage-render black-hole run out/hole \
        --tracers 1000000 --metrics out/hole/metrics.csv --metrics-interval 50 --no-frames
    scripts/gas-curves.py out/hole/curves.png "this=out/hole/metrics.csv"

`--metrics` writes a row of `TidalMeasure` every interval: the time in P\*, the swallowed share,
the bound share, `circ`, the eccentricity, the plunging share, the height over the radius, the
heating, the shares of the bound half within 2, 6 and 16 R_p and the radius of the flow's first
quartile, median and last quartile. `--grid-heights` and `--height-cell` change the grid.
