# Previews at 200 M (#241)

Step 5 of epic #236. The ticket planned 2 M massive with 50 M tracers, then the whole story at
198 M. Pierre dropped the 50 M stage and asked instead for about an hour of computing at 200 M
drawn: a known scene, shown while the collision is under way, an extract only, in 4K through a
camera somewhat inside the system, to judge whether 200 M is worth a long run. Seeing it, he asked
for a second hour with ten times the mass. This note is those two previews. Crops, stills and the
two side by side are on `assets/241-preview` under `docs/spikes/200m-preview/`.

## The runs

- **The scene.** scene-0031 of 2026-10-30-b, two spirals of the `antennae` generator, the scene
  every tracer measurement has used since #187. The library having been deleted, it was read
  from `assets/tenfold` (`docs/spikes/tenfold/`), with its Webb look and the immersed director
  (`camera.mode` `immersed`).
- **Brought close.** Its first pericentre moved from 304.5 to 80 Myr: the encounter's
  `pericentreTime` changed and the galaxies placed again by `placeEncountersGivingWay`, as a
  generated scene is. The disks reach about 20 kpc; at 50 Myr they would have started 29 kpc
  apart, overlapping, at 80 they start 41 kpc apart, just clear.
- **Two passes**, as a night's full pass runs: the massive pass (the same draw, its tracers
  dropped as they come, a take at one frame in four), then the full pass drawing 4K as it runs,
  framed on that take, with a checkpoint every 160 frames.
- **The same instants.** 32 to 233 Myr in 480 frames, the pericentre around frame 115. The first
  preview steps at `--dt-scale 14`, four times a hires's step: 76 steps not drawn, then one a
  frame. The second steps at exactly half that (`--dt 0.04446`, about what its finer softening
  asks at the same scale): 152 not drawn, then two a frame, so both films show the same instant
  in the same frame, through the same shots.

| | first preview | second preview |
| --- | ---: | ---: |
| drawn | 200 M | 100 M |
| light tracers | 198 M | 92 M |
| massive visible | 2 M | 8 M |
| halo | 3 M | 12 M |
| softening | 55 pc | 30 pc (the floor) |
| a step | 0.42 Myr | 0.21 Myr |

## What they cost

On the M4 Max, alone on the GPU, Pierre using the Mac meanwhile.

| | first, massive pass | first, full pass | second, massive pass | second, full pass |
| --- | ---: | ---: | ---: | ---: |
| sampling | 295 s | 315 s | 151 s | 148 s |
| a step | 0.11 to 0.16 s | 4.27 s | 0.45 s | 2.49 to 2.61 s |
| a 4K frame drawn | | 1.70 s | | 0.77 s |
| wall time | 6.2 min | 58.6 min | 11.9 min | 56.8 min |
| peak footprint | 4.2 GB | 10.8 GB | 9.8 GB | 11.0 GB |
| on disk | take 2.0 GB | video 103 MB | take 8.0 GB | video 103 MB |

- **A tracer step** costs 21.0 ns on 2 M massive, as at 100 M drawn (#238), and 23.4 ns on 20 M,
  whose tree is deeper.
- **Checkpoints** of 6.52 GB, written in 1.07 and 1.08 s, and 3.66 GB in 0.67 to 0.69 s; the
  massive set once, 0.32 and 1.28 GB in 0.10 and 0.26 s. Two at most while one is written,
  removed when the run ends.
- **The massive part** of each full pass repeated its massive pass to the bit, over the take's
  121 stored frames.
- `CostModel`'s fallbacks follow: 21 ns a tracer step (20 before), and a 4K frame drawn at
  0.034 s + 8.35 ns a particle, through #239's 101 ms at 8 M and these 1.70 s at 200 M
  (0.040 s + 7.6 ns before); the 0.77 s at 100 M sit 12 % under that line.

**A whole story** of this scene at a hires's step, 923 frames in 4K and vertical, by these
numbers: on 2 M massive, 8 480 steps, about 11 h and 11 GB of memory; on 20 M massive, 15 430
steps (the step halves with the softening), about 12 h at 100 M drawn and about 22 h and 14 GB
at 200 M. The epic's bounds are 24 h, 20 GB and 35 GB of disk. On disk the key frames weigh
most at 200 M (1.6 GB each, and their take about 10 GB); on 20 M massive the massive take at one
frame in four would be 15 GB more, so one in eight there.

## What they show

- **Proportions.** In the first preview 97.5 % of the particles drawn carry no mass: gravity is
  computed between 5 M particles (2 M visible, 3 M halo), a hundred tracers to each massive
  visible one, against three in a night's 8 M. In the second, 20 M carry it, 12 tracers to each.
- **Continuous matter.** At 200 M drawn the streams read smooth, with thin filaments and the sharp
  edges of shells that 2 M's grain hides; in close-up a fine grain, where 2 M draws large soft
  discs. Pierre found the very fine, milky look interesting.
- **The shapes are the massive count's.** The arms, tails and knots of the first preview are those
  of a run softened at 55 pc, and the continuous rendering shows them as they are where the grain
  hid them: Pierre found the modelling coarser, and asked whether too few massive particles were
  why. A step four times a hires's, which heats and thickens the disks, and a look tuned for
  coarse grain soften both previews further.
- **Ten times the mass.** With 20 M massive the same encounter keeps its shapes, with a little
  more fine structure in the debris (thinner streams, more shells and ripples around the core),
  a modest change at these scales next to the one from 2 M drawn to 200 M. Its grain is a little
  coarser, at 100 M drawn. Pierre judges it on the side-by-side.

## What is left

- Past 8 M visible the softening is at its 30 pc floor, so more mass sharpens nothing more.
- A hires's step instead of four times it, and a look tuned for 200 M (more contrast, point-like
  stars), are the levers left on the shapes and on the milky look.
- #241 closes on these previews, and with it epic #236.
