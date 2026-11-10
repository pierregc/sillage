# Ten times the particles

Asked on 2026-11-02: what would it take to run ten times the particles, galaxies of fifty
million stars. The night's hires went from 2 M to 8 M a scene with #185, and the two 8 M
hires in the library are the largest runs made here. Fifty million a galaxy is 100 M visible
particles for a pair: twelve times the largest run, fifty times the old default.

Measured on the M4 Max (14 cores, 32-core GPU, 36 GB, macOS 26.5.1) where it says so, alone on
the GPU; estimated otherwise, with the basis given. The sheets, crops, logs and the full
measurement record are on the branch `assets/tenfold` under `docs/spikes/tenfold/`
(`RESULTS.md`).

## A particle is not a star

A spiral of the nights holds 7 to 15 x 10^10 solar masses of visible matter (`potential.mass`
32 to 70 in units of 10^10, `diskMassFraction` 0.22), of the order of two hundred billion real
stars. Nobody follows those one by one. The sampler draws `particleCount` particles from the
galaxy's distribution instead, every visible one with the same mass: about half a million suns
each at the explore count (200 000 a galaxy), a hundred thousand at the old hires (1 M a
galaxy), and still about two thousand at fifty million a galaxy, a small open cluster. It works
because stars almost never meet: each moves in the smooth mean field of all the others, and the
particles sample that field. More of them is less sampling noise, finer grain and less spurious
scattering, not more stars.

Not every visible particle is starlight either: 14 to 38 % of a generated spiral's are dust,
which absorbs, and 1 to 5 % HII regions. The live halo adds 1.5 dark particles per visible one
(`haloParticleRatio`), each 2.4 times heavier than a visible particle, simulated and never
drawn. `--particles` counts the visible particles of the whole scene, so a 2 M hires of a pair
is 1 M a galaxy and 5 M simulated.

## What the count buys

The single-disk test of `gigantism.md` (disk preset, seed 7, t = 0, 4K, the disk 1460 px
across, base look of scene-0031) at 8, 20, 50 and 100 M particles, so the count is per galaxy.
The disk preset runs the restricted solver, so the run costs only sampling and drawing; at
t = 0 this is the sampler's disk, not an evolved one. Three looks: glint 1, glint 0.3 (the
styles' value since #184), and glint 0.3 with the camera at zoom 3, the inner disk filling the
frame.

- **The count shows at 1:1 in 4K and survives 1080p; shrunk to 720 px wide, the four counts
  cannot be told apart.** At glint 0.3, 8 M is fine sand with pinpoints and broken lanes; 20 M
  is finer, the HII knots starting to separate; 50 M is a continuous fine texture with
  continuous lanes; 100 M is a smooth light with film-like grain at the pixel and sharp dust
  filaments, more of them in the inner disk. The largest step is 8 M to 50 M.
- **In the close-up the blots go between 20 M and 50 M**, as they went between 4 and 8 M in the
  full frame: 8 M is a field of 5 to 10 px blots, 20 M smaller ones, 50 M fine grain, 100 M a
  continuous surface with the inner spiral and dozens of thin lanes drawn round the core. So
  the count a disk needs grows with how close the camera is: 8 M for a disk filling the frame,
  50 M for a third of one.
- **The glint still decides the sparkle.** At glint 1 the compact sources glitter at every count,
  finer and denser but there at 100 M (points 3.7 % at 8 M, 3.1 % at 100 M); at glint 0.3 they
  halve (3.1 % to 1.5 %).
- `grain.py` cannot rank counts, as the gigantism note warned: in the close-up grain rises from
  0.026 to 0.040 and structure falls from 0.042 to 0.024 because a particle shrinks from a
  blot into a pixel. The sheets are the measurement.
- Two things 8 M hid. From 50 M the HII knots are the most visible small-scale feature, a
  string of lilac smudges of nearly the same shape along the arms, which read as stamped. And a
  faint rectangle of about 8 by 16 px sits at the exact centre of every close-up, the same at
  every count, so not sampling. Neither was looked into.

## What drawing costs

| 4K, GPU a frame | 8 M | 20 M | 50 M | 100 M |
| --- | ---: | ---: | ---: | ---: |
| full disk | 58 ms | 135 ms | 300 ms | 670 ms |
| close-up | 94 ms | 180 ms | 449 ms | 914 ms |
| smoothing (GPU tree) | 13 ms | 35 ms | 101 ms | 210 ms |
| peak memory | 3.5 GB | 6.1 GB | 12.4 GB | 22.5 GB |

About 6 to 7 ms a million particles in the full frame. Drawing is never what decides: a 923
frame export at 100 M is about 15 minutes. It does rule out playing a 100 M take live in the
app. 100 M on the disk preset is at the edge of the machine: about 205 bytes a particle (the
sampled copy, the restricted solver's buffers, the renderer's attributes, the smoothing tree),
and with the usual applications open the system compressed 16 to 18 GB of pages during each
100 M run. Sampling is one core, 0.59 µs a particle, a minute at 100 M.

## The solver past ten million

scene-0031 (two spirals, opening angle 0.9, `--dt-scale` 3.5), 30 steps, the last 20 timed:

| visible | halo | simulated | a step | per particle-step | per Myr | peak | per particle |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 10 M | 15 M (1.5) | 25 M | 565 ms | 22.6 ns | 9.8 s | 8.2 GB | 327 B |
| 20 M | 30 M (1.5) | 50 M | 1430 ms | 28.6 ns | 24.9 s | 15.3 GB | 306 B |
| 20 M | 12 M (0.6) | 32 M | 806 ms | 25.2 ns | 14.0 s | 10.3 GB | 322 B |
| 40 M | 12 M (0.3) | 52 M | 1312 ms | 25.2 ns | 22.8 s | 16.0 GB | 307 B |

The 10 M run reproduces the gigantism note (550 ms, 8.3 GB). The hires records of the
2026-10-30-b batch agree: 22.4 ns a simulated particle-step for scene-0031 at 2 M, 24.8 and
25.5 for the two 8 M scenes, drawing, video and take included.

**The step stops shrinking at about seven million.** `SceneConfig.recommendedSoftening` follows
the sparsest disk's spacing as one over the square root of its count, but never below 0.03 kpc,
and the step follows the softening. On scene-0031 that floor is reached at about 6.6 M visible:
0.0546 kpc and a step of 0.105 Myr at 2 M, 0.0346 and 0.066 at 5 M, 0.030 and 0.0575 from 8 M
on, the same at 10, 20, 40 and 50 M. Larger disks reach it later (scene-0030 sits at 0.0415 at
8 M). Past the floor, more particles neither shorten the step nor sharpen the force
resolution; they only lower the particle noise. Without the floor 100 M would get 7.7 pc and a
step four times shorter.

**The halo is the cheapest lever measured.** At 20 M visible, a halo at 0.6 instead of 1.5
takes 44 % off the step and a third off the memory, and 40 M visible with a halo at 0.3 costs
less a step than 20 M at 1.5. What a lighter live halo does to the disks was not measured.

**Memory is about 310 bytes a simulated particle at the peak**, plus the take's in-memory budget
(a quarter of the machine, 9 GB) once a take spills. In steady state the code holds 64 bytes for
the sampled copy `main.swift` keeps for the whole run, 84 in the solver's buffers (position,
velocity, acceleration, Morton-sorted copy, mass, formation, component, galaxy, the diagnostic
cost counter), 56 in the tree builder (two code and two order arrays, nodes and quadrupole
moments at half a node a particle) and 36 a visible particle in the renderer and the smoothing
field: about 220 a simulated particle. The rest is the sampler's transient. Metal is not the
limit: the largest buffer at 130 M simulated is 2.1 GB against a `maxBufferLength` of 22.6 GB,
and the working set allowed is 30.2 GB.

## A take snaps its particles to a grid

`Recording.appendLocked` quantises each frame to 16 bits an axis over the box of every visible
particle, and the box grows with the story as material is thrown out. `scripts/take-quantum.py`
reads it back from the takes themselves, on the first, middle and last stored frames:

| take | extent, first to last | quantum | sharing a cell, first / middle / last | most in one cell |
| --- | --- | --- | --- | ---: |
| scene-0031, 2 M | 230 to 958 kpc | 3.5 to 14.6 pc | 0.07 / 1.2 / 3.0 % | 19 |
| scene-0044, 8 M | 400 to 1 272 kpc | 6.1 to 19.4 pc | 1.6 / 4.6 / 13.4 % | 70 |
| scene-0030, 8 M | 667 to 2 153 kpc | 10.2 to 32.9 pc | 5.6 / 15.3 / 18.2 % | 948 |

On the last frame of scene-0030, 15 % of the emitting particles have lost their own cell. A
better box does not fix it. The script also prints the quantum of a box over the central 99.9 %
of the particles, and of one such box a galaxy (the coarsest galaxy counts), each leaving about
0.27 % outside:

| take, last frame | whole box | central 99.9 % | one central box a galaxy |
| --- | ---: | ---: | ---: |
| scene-0031, 2 M | 14.6 pc | 5.5 pc | 4.7 pc |
| scene-0044, 8 M | 19.4 pc | 10.3 pc | 9.5 pc |
| scene-0030, 8 M | 32.9 pc | 13.2 pc | 10.5 pc |

Late in a story the tidal debris of each galaxy alone spans 600 to 700 kpc in the 8 M scenes, so
a galaxy's own box is barely smaller than the scene's central one. Boxes buy two to three times; early frames
gain more (scene-0044's first frame goes from 6.1 to 1.4 pc with a box a galaxy).

A disk filling a 4K frame is about 20 pc a pixel, so late in an 8 M take the points already sit
on a grid of one to one and a half pixels, and at 50 M a galaxy in a close-up the grid would be
in every pixel. `hires.mov` is drawn from the solver's floats and is not affected; `look`, the
library's stills and every export are drawn from the take. This matters before any count goes
up: the frame-filling shots of #186 are drawn from 8 M takes late in their story.

The fix is more bits rather than a better box: 21 bits an axis packed in 8 bytes is 32 times
finer, about 1 pc over the largest box measured and 0.3 pc with a box a galaxy, for a take a
third larger. Done in #237, see `takes-on-disk.md`. Coding each position relative to its galaxy's centre on a scale that is finest at
the centre would keep 6 bytes and serve the close-ups of the inner disk, at the cost of the tails.

## What 100 M costs as the code stands

- **It does not fit.** 100 M visible with the halo at 1.5 is 250 M simulated, about 77 GB at
  310 bytes; with the halo at 0.3, 130 M simulated and 40 GB. The machine has 36.
- **If it did, a day and a half a gigayear.** About 7.5 s a step at 30 ns a particle-step and
  17 000 steps a gigayear at the floor: 36 h for each gigayear of story, and the nights' stories
  run 0.9 to 1.6 Gyr with their settle.
- **The take is 600 MB a kept frame**: 140 GB for scene-0031's 923 frames at the interval of
  four, 230 GB for scene-0030's 1514. The volume has 1.3 TB free.
- **And it could not hold the positions**, above.

## The levers

**Cap the halo, not the ratio.** The live halo is there for dynamical friction and a halo that
answers; it does not need 1.5 particles a star once there are many stars. The disk heating it
causes grows with the mass of a halo particle, and depends only weakly on the ratio between halo
and star particles once that is past one (Ludlow et al. 2021, arXiv:2105.03561; Wilkinson et
al. 2023, arXiv:2208.07623, heating "largely insensitive to the stellar particle mass"). Holding
the halo at the count of today's 8 M hires, six million a galaxy, keeps a halo particle at
about 6.5 x 10^4 suns, the heating the 8 M runs already have and a fifteenth of the 10^6 suns at
which Ludlow et al. measure sigma_z rising by half over 5 Gyr. The stars then weigh a thirtieth
of a halo particle at 50 M a galaxy; mass segregation runs on the halo's relaxation time
divided by that ratio (Ludlow et al. 2019, arXiv:1903.10110), of the order of a thousand
crossing times here, ten gigayears and more even in the inner disk, so not within a clip. To be
checked with the calm-disk probe before use, not assumed. 100 M visible is then 112 M simulated
instead of 250.

**Hold less memory.** Drop the sampled copy once the solver and the renderer have their buffers,
drop the cost counter outside measurements, fold the kick into the force pass so the
acceleration buffer goes, reserve the sampler's arrays: from about 220 to 140 bytes a simulated
particle in steady state, and the transient with them. With the halo capped, 100 M visible is
then 16 to 18 GB.

**Light tracers (#187).** Massless particles drawn from the same distribution, kicked by the
massive particles' tree, never in it. A spike is running on this; the cost side of it:

- The walk is the step, and a tracer walks the tree like any particle: about 0.85 of a
  simulated particle-step (the force pass is 82 % of a step, `perf-milestone-7.md`). Tracers do
  not make a walk cheaper; they make the tree smaller and keep the step long.
- They keep the step long only while the massive set is under the softening floor. 2 M massive
  particles keep scene-0031 at a step of 0.105 Myr, 1.8 times the floor's; 8 M massive are at
  the floor already and save no steps.
- The disks' dynamics do not need more massive particles: from 54 000 to a million stars a
  galaxy nothing the probe measures moves beyond the seed spread (`lumpy-arms.md`), and past
  the floor the force resolution does not improve anyway. What the count buys is the picture,
  which is exactly what tracers supply.
- A tracer's force error does not feed back, so tracers can walk at a looser angle than the
  massive set: 0.9 to 1.2 is about 0.45 of the nodes, if the drift between tracers and stars
  stays invisible, which is what #187 has to show.
- To decide: whether the compact minority, the dust, the HII regions and the gas that forms
  stars live in the massive set or among the tracers; the cooling (`bhDissipate`) has to reach
  the disk material the tracers carry; tracers need kernel sizes from their own spacing and a
  Morton order of their own, or their walks diverge (`state-and-known-limitations.md`).
- The literature has massless particles matching the massive ones in distribution (Comparetta
  and Quillen 2010, arXiv:1005.4952, four million in a dwarf of 9 000 to 60 000), and tracers
  feel the massive set's noise as stars do (Sellwood 2015, arXiv:1504.06500): they sample the
  noise, they do not reduce it.

**A longer step.** Hires runs at `--dt-scale` 3.5; the state note measures 8 as comfortable
through a pericentre and 16 as defensible, and a 4K batch already ran at 7. 7 halves every time
below, after one comparison of a hires at 3.5 and 7 on the same scene.

**A cheaper walk for everyone.** A group walk building interaction lists in threadgroup memory
(Bonsai, Bédorf et al. 2012, arXiv:1106.1900) is the known way past a walk bound by its own
loop. Bonsai reports at least four times a one-thread-per-body code, with different multipoles
and criteria; no controlled comparison exists, and `solver-language.md` puts 1.3 to 2x on the
force pass as plausible and unproven.

**A bigger machine.** The Mac Studio with M5 Ultra (shipping since September 2026,
https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/) has an
80-core GPU, 1.2 TB/s and up to 512 GB, against this machine's 32 cores and 410 GB/s: an
estimated two and a half to three times the walk, and the memory to hold 250 M simulated as the
code stands. A cloud H100 (about $4 an hour, 67 TFLOPS and 3.35 TB/s against about 14 and 0.41)
would need the solver ported from Metal to CUDA. PKDGRAV3 has an experimental Metal backend; no
performance figures were found.

## What each route would cost

Hours of M4 Max a gigayear of story at `--dt-scale` 3.5 (settle included; the nights' stories
run 0.9 to 1.6 Gyr), from the per particle-step costs above, 23 to 30 ns growing with the
count, and scene-0031's steps. Drawing a 4K frame adds 0.1 to 0.9 s a frame.

| route | simulated | tracers | a step | a gigayear | memory |
| --- | ---: | ---: | ---: | ---: | ---: |
| 8 M, as now (#185) | 20 M | | 0.45 s | 2.2 h | 15 GB with the take |
| 20 M, halo at 1.5 (measured) | 50 M | | 1.43 s | 6.9 h | 15 GB + take |
| 20 M, halo at 0.6 (measured) | 32 M | | 0.81 s | 3.9 h | 10 GB + take |
| 100 M, halo at 1.5 | 250 M | | 7.5 s | 36 h | 77 GB, does not fit |
| 100 M, halo capped at 12 M | 112 M | | 3.0 s | 14.5 h | 34 GB, does not fit |
| same, less memory | 112 M | | 3.0 s | 14.5 h | 18 GB |
| 2 M massive and 98 M tracers | 5 M | 98 M | 2.0 s | 5.3 h | 22 GB, 12 with less memory |
| same, tracers at angle 1.2 | 5 M | 98 M | 0.95 s | 2.5 h | same |
| same, `--dt-scale` 7 | 5 M | 98 M | 0.95 s | 1.3 h | same |

## What to do, in order

1. **Give the take more bits.** The grid already costs the 8 M takes their late frames in close
   shots, a better box only buys two to three times, and nothing above 8 M is worth keeping
   without it.
2. **Measure the halo cap with the probe, and hold less memory.** Together they make 20 M visible
   (10 M a galaxy) about four hours a gigayear: one scene a night, with no new physics.
3. **100 M is a tracer question.** If #187 shows tracers holding to the stars over a run, 2 M
   massive and 98 M tracers is two and a half to five hours a gigayear. Without tracers, 100 M
   all massive is fourteen hours a gigayear at best on this machine, after the memory work, and
   an M5 Ultra would divide that by two and a half to three.
4. **The group walk** is worth a spike of its own whichever route is taken: it multiplies
   everything.

Not worth it: a CUDA port for a hobby pipeline, another host language (`solver-language.md`),
and lowering the softening floor, which would multiply the steps by four at 100 M for a force
resolution finer than a pixel of a frame-filling disk.
