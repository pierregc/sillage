# A doubled step (#225)

Hires and exploration run at `--dt-scale 3.5`. The state note measured 8 as comfortable through a
pericentre and 16 as defensible at 300 000 particles, a 4K batch had already run at 7, and
[ten times the particles](ten-times-the-particles.md) counted on 7 to halve every time on the way
to 100 M. This is the one comparison it asked for first: the same story at 3.5 and at 7, with a
floor to read it against.

## How it was measured

scene-0031 of `library/2026-10-30-b`: two spirals, mass ratio 0.85, bound, first pericentre
10.5 kpc at 305 Myr, merged by 510. Three hires at 8 M drawn from 2 M massive, alone on the
M4 Max, with twelve density maps and a take keeping one frame in sixteen:

| run | step | steps, settle and clip | wall | a step | peak |
| --- | ---: | ---: | ---: | ---: | ---: |
| 3.5 | 0.0989 Myr | 1 584 + 7 384 | 41.6 min | 258 ms | 9.7 GB |
| 3.5, the floor | 0.0989 Myr | 1 584 + 7 384 | 39.5 min | 250 ms | 9.6 GB |
| 7 | 0.1978 Myr | 792 + 3 692 | 21.4 min | 256 ms | 9.2 GB |

The floor is the 3.5 run with the second galaxy moved by 1 pc in `scene.json`: the encounter's
own chaotic divergence, which any other difference has to be read against. `--dt-scale 3.5001`
would not have done it, since a hires step is a whole fraction of the preview's frame and comes
out the same. Another thread's tests ran for four minutes of the first 3.5 run, so the floor run
is the clean 3.5 timing: 7 is 1.85 times faster, a step costing the same. At 7 the hires runs at
the preview's own step.

`scripts/step-compare.py` reads the runs: the curves (centres, closest pair, passages, the pair's
specific angular momentum while more than 5 kpc apart, tails, extent, stars formed, disruption),
the density maps (chi-square a cell, the same on 4x4 cells, and the share of the light that is
somewhere else, against what Poisson noise alone gives), and 4K stills of five frames with the
Hubble look and the automatic camera. The solver keeps no total energy, so energy and angular
momentum are read where they show: the orbit, when the pair merges, and the disks' thickness.
The reports, stills and logs are on the branch `assets/225-doubled-step`, under
`docs/spikes/doubled-step/`.

## The story holds, what lives at the softening does not

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
  within 0.7 %. The burst keeps its shape and only its level drops. The rule reads the
  convergence of the flow over a leaf of sixteen particles ([star formation](star-formation.md)),
  a few softening lengths across, and at 7 a disk star at the circular speed crosses a whole
  softening length a step, where `recommendedTimeStep` was written for well under one (0.15 of
  one at scale 1, half of one at 3.5).
- **Compact knots.** The 7 remnant keeps four compact knots where both 3.5 runs keep two, and a
  satellite on the bridge at 423 Myr sits 40 px higher in the 4K frame. Blurred by 8 px, the 4K
  stills of 7 differ from 3.5 by 1.8, 7.9, 7.4 and 8.3 % at 309, 423, 639 and 879 Myr, against
  0.75, 3.6, 5.8 and 6.3 % for the floor: twice the floor around the pericentre, 1.3 times it in
  the remnant.
- **The orbit** loses or gains five times the floor in angular momentum while the pair is
  apart, and the tails' share wanders nine times as far, still within 3 % at the end.

EXPLORE

## The decision

DECISION
