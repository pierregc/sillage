# A doubled step (#225)

Hires and exploration ran at `--dt-scale 3.5`. The state note measured 8 as comfortable through a
pericentre and 16 as defensible at 300 000 particles, a 4K batch had already run at 7, and
[ten times the particles](ten-times-the-particles.md) counted on 7 to halve every time on the way
to 100 M. This is the comparison it asked for first: the same story at 3.5 and at 7, read against
the encounter's own chaos.

**Decision: hires stays at 3.5, exploration moves to 7.** At 7 the hires keeps the story but not
its knots or its star formation; the exploration ranks the same scenes in half the time.

## How it was measured

scene-0031 of `library/2026-10-30-b`: two spirals, mass ratio 0.85, bound, first pericentre
10.5 kpc at 305 Myr, merged by 510. Three hires at 8 M drawn from 2 M massive, alone on the
M4 Max, with twelve density maps and a take keeping one frame in sixteen:

| run | step | steps, settle and clip | wall | a step | peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.5 | 0.0989 Myr | 1 584 + 7 384 | 41.6 min | 258 ms | 9.7 GB |
| 3.5, the floor | 0.0989 Myr | 1 584 + 7 384 | 39.5 min | 250 ms | 9.6 GB |
| 7 | 0.1978 Myr | 792 + 3 692 | 21.4 min | 256 ms | 9.2 GB |

The floor is the 3.5 run with the second galaxy moved by 1 pc in `scene.json`: any other
difference has to be read against it. `--dt-scale 3.5001` would not have done, since a hires step
is a whole fraction of the preview's frame and comes out the same. Another thread's tests ran
for four minutes of the first 3.5 run, so the floor is the clean 3.5 timing: 7 is 1.85 times
faster, a step costing the same. At 7 the hires runs at the preview's own step.

Then three exploration batches of the same 20 scenes, seed 20261109, 100 000 a galaxy: 3.5 with
3 600 steps after a settle of 750, 7 with 1 800 after 375 (the same megayears, so every scene is
drawn and timed alike), and a floor at 3.5 settled one step longer.

`scripts/step-compare.py` reads them all: the curves (centres, closest pair, passages, the pair's
specific angular momentum while more than 5 kpc apart, tails, extent, stars formed, disruption),
the density maps (chi-square a cell, the same on 4x4 cells, and the share of the light that is
somewhere else, against what Poisson noise alone gives), 4K stills of five frames with the Hubble
look and the automatic camera, and `interest.py`'s scores. The solver keeps no total energy, so
energy and angular momentum are read where they show: the orbit, when the pair merges, and the
disks' thickness. Reports, stills and logs are on the branch `assets/225-doubled-step`, under
`docs/spikes/doubled-step/`.

## The hires: the story holds, what lives at the softening does not

| | floor against 3.5 | 7 against 3.5 |
| --- | ---: | ---: |
| first passage | 311.8 Myr, 6.11 against 6.13 kpc | 311.8 Myr, 6.17 kpc |
| merged, for good under 2 kpc | 510.4 Myr, both | 511.2 Myr |
| centres, rms and max | 0.07 and 0.25 kpc | 0.18 and 0.76 kpc |
| pair's angular momentum while apart, median | 0.42 % | 2.24 % |
| tails, rms of the share | 0.0003 | 0.0027 |
| tails at the end | 0.3006 against 0.3007 | 0.3094 |
| extent, rms | 0.01 % | 0.14 % |
| disks torn half way | same to 0.01 Myr | within 0.8 Myr |
| stars formed | +0.09 % | -14.7 % |
| density at 887 Myr, light elsewhere (noise 0.74 %) | 4.45 % | 9.31 % |
| same, chi-square a cell and on 4x4 cells | 7.9 and 18 | 26.6 and 114 |

The disks' thickness and extent at 157, 224 and 290 Myr agree to half a percent in all three
runs (0.211 and 0.135 kpc rms height at the start of the clip, 1.49 to 1.50 and 0.92 after the
pericentre), and so does every large feature: the passage, the merger, the tails, the remnant.
What goes past the floor is what lives at the scale of the softening:

- **Star formation is 15 % lower from the first frame on.** Per megayear, 623 against 530 before
  the pericentre, 1 013 against 869 up to the second passage, 688 against 574 through the
  merger, 363 against 312 in the remnant: 0.83 to 0.86 in every window, while the floor stays
  within 0.7 %. The burst keeps its shape and only its level drops.
- **Compact knots.** The 7 remnant keeps four compact knots where both 3.5 runs keep two, and the
  satellite on the bridge at 423 Myr sits elsewhere. Blurred by 8 px, the 4K stills of 7 differ
  from 3.5 by 1.8, 7.9, 7.4 and 8.3 % at 309, 423, 639 and 879 Myr, against 0.75, 3.6, 5.8 and
  6.3 % for the floor: twice the floor around the pericentre, 1.3 times it in the remnant.
- **The orbit** gains or loses five times the floor in angular momentum while the pair is apart,
  and the tails' share wanders nine times as far, still within 3 % at the end.

At 7 a disk star at the circular speed crosses a whole softening length a step, where
`recommendedTimeStep` was written for well under one: 0.15 of one at scale 1, half of one at 3.5.

## The exploration ranks the same scenes

| | floor against 3.5 | 7 against 3.5 | 7 against the floor |
| --- | ---: | ---: | ---: |
| score rank correlation (Spearman) | 0.81 | 0.73 | 0.93 |
| top 10 in common | 7 | 7 | 10 |
| top 4 in common | 3 | 3 | 3 |
| mean score difference | 0.047 | 0.066 | 0.023 |
| stars formed, median ratio (10 to 90 %) | 1.01 (0.93 to 1.05) | 0.67 (0.63 to 0.69) | 0.66 (0.63 to 0.72) |

One settle step more moves the ranking as much as doubling the step does. Four scenes whose
merger came late in the 3.5 batch (1, 6, 9 and 13) score about 0.2 lower there than in both
others, and read against the floor, 7 ranks the same top ten. Passages that do not merge come
back at the same distance and time within the floor: scene 2 at 2.78 and 2.79 kpc at 386 Myr
(floor 2.83), scene 15 at 3.62 and 3.66 at 252 (3.64), scene 11 at 1.55 and 1.52 at 431 (1.57).
Mergers move as much as the floor moves them.

Star formation is two thirds at 7, 0.66 to 0.68 in every window from 150 Myr to the end, against
0.99 to 1.05 for the floor: the dependence the hires showed, larger at this count. It is uniform
over the story, quiet disks included, so it is the rule's own response to the step rather than
the encounter's: the rule reads a leaf's density and the convergence of its flow
([star formation](star-formation.md)), both at the scale of the softening. Which of the two
moves was not measured. The burst ratio `interest.py` scores is a ratio and stays within the
floor.

The 20 scenes took 794 s at 7 against 1 636 s at 3.5. The first six scenes of the 3.5 batch shared
the GPU with another thread's tests and the floor batch with this ticket's own check; on scenes 7
to 20, 139 s a scene against 280, twice as fast, a particle step costing the same (54 and 55 ns a
slot).

No black hole was drawn among the twenty (about one scene in twenty carries one). Stars bound to
a hole are the fastest thing in a scene ([black holes](black-holes.md)) and were not measured at 7.

## What changed

- **Hires stays at 3.5.** The story holds at 7, but what an 8 M hires is for, the texture and the
  knots in 4K, moves past the floor, with 15 % of the stars, for 1.85 times the speed.
  `SceneFolder.hiresTimeStepScale` holds 3.5 for every hires whatever its preview ran at, and
  `--dt-scale` still overrides it. For #241, 198 M tracers from 2 M massive at 3.5 come to about
  10 hours for a story as long as this one, at today's 20 ns a tracer step; 7 would have made it
  5, and a day holds either.
- **Exploration runs at 7.** `explore-batch.sh` and `ExploreProbe` default to 7 with a settle of
  375 steps, the same 150 Myr; a night's probe reads `dt_scale` from `batch.conf`, so a batch
  started before keeps its 3.5 and 750. The cost model counts particle steps, which cost the same
  at both scales, so it needs no refit: a night plans half the steps. Previews form a third fewer
  stars than they did.
- **Left open.** An in-between step for hires (5 steps a frame, about 5.7) was not measured.
  Star formation's dependence on the step is worth a ticket of its own: a preview and its hires
  now run four times apart in step, and their star formation with them.
