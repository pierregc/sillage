# Gigantism: why a render reads as sand, and what buys the halo

Spike asked on 2026-11-01. A Hubble or Webb picture of a galaxy is a continuous glow with a
few resolved clusters in it; a Sillage frame at two million particles still reads as a
cloud of grains. The first idea was more particles, and the question was what else there is
before paying for that. Measured on scene SCENE of the library on the M4 Max; the sheets,
scores and logs are on the branch `assets/gigantism` under `docs/spikes/gigantism/`.

## Where the grain comes from

Three things, and only the third is the particle count.

**The kernel is sized in three dimensions and the picture is a projection.** Every star is
drawn as a Gaussian whose width follows the local interparticle spacing read off the
solver's tree (`SmoothingField`): `w * n^(-1/3)` for a leaf of `n` particles in a cell of
width `w`, times the look's `smoothingScale`. That is the right length for a volume. A thin
disk seen face-on stacks many of those spacings along a line of sight, and a kernel one
spacing wide covers only a few of the particles that share its patch of sky. Noise per pixel
goes as one over the square root of that number, so the disk comes out stippled however the
spacing is tuned. The profile makes it worse than it looks on paper: the fragment falls as
`exp(-4.5 r^2)` to the edge of the point, so the Gaussian's sigma is a sixth of the point
size, and a star drawn at a `span` of three spacings has an effective width of half of one.

**Two per cent of the stars carry a quarter of the light as point sources.** `DiskSampler`
draws, on purpose, a compact minority: 2.2 % of the disk stars get four to forty-four times
the brightness and a kernel three quarters the size, "the sources the eye picks out one at a
time". In counting terms that is expensive. With the light per particle `w`, the number of
particles a pixel effectively averages is `N (mean w)^2 / mean(w^2)`; for the sampler's draw
(mean boost 14, mean square 325, on 2.2 % of the stars) that ratio is 0.19. A disk of
200 000 particles smooths like one of 40 000, and the forty-thousand it smooths like are
exactly the bright ones. The HII knots add to this at ten times the light per unit mass.

**And the count.** With the two above fixed, what is left is Poisson noise in the column,
which falls as one over the square root of the number of particles under a kernel. Doubling
the particles takes 29 % off the grain; halving it costs four times the particles.

## What was tried

Three look fields, all behind defaults that leave every existing frame bit for bit as it was,
plus the two things a look could already do.

- `columnSmoothing` (slider "Étoiles sous le noyau (projection)"): before the splat pass a
  count pass draws one point per emitting particle into cells eight accumulation pixels wide.
  The splat vertex reads the count back at its own screen position and widens its kernel to
  cover that many stars in projection, never narrower than the tree's answer. One more vertex
  pass over the buffer and a 1/64 texture.
- `glint` (slider "Sources compactes"): the compact minority's extra light and narrowness,
  dialled from as sampled (1) to an ordinary star (0). Nothing is resampled; the shader knows
  them by their kernel scale.
- `haze` and `hazeScale` (sliders "Voile de lumière", "Largeur du voile"): a share of every
  star's light drawn `hazeScale` times wider into a target a quarter the size on each axis,
  added back at resolve. The exposure does not move: the main pass keeps `1 - haze`.
- For comparison, the two hammers a look already had: `smoothingScale` up with a higher
  kernel floor (the direction of the Onirique look), and bloom with its threshold at the
  floor.

`sillage-render look SCENE --stills DIR` writes each look at each key frame at full size,
and `scripts/grain.py score` measures them: over the body of the galaxies, the relative rms
of what is finer than two pixels (`grain`), the relative rms of what lies between four and
sixteen pixels (`structure`, the arms and lanes a smoothing must not take away), and the
share of body pixels standing a quarter above their surroundings (`points`, the sparkle).
`scripts/gigantism-spike.sh` runs the whole comparison.

## What the numbers say

TODO stills table, count series, timings.

## The other track: more particles

What the particle count buys is resolution: thinner lanes, finer arms, a smaller softening
and so sharper cores and tails. It buys smoothness only at the square-root rate above, and
it is paid for faster than linearly.

- **A step.** The force pass is 90 % of a step and the kernel sustains the same node rate at
  every size ([solver-language](solver-language.md)). At the opening angle the app and the
  nights run at (0.9): about 100 ms a step at 2 M visible, 260 ms at 5 M, 540 ms at 10 M,
  from the 0.6 figures of that note divided by the measured 2.55. TODO measured here.
- **More steps.** The softening follows the mean spacing and the time step follows the
  softening ([state note](state-and-known-limitations.md)): from 300 k to 2 M the same
  simulated time took 2.4 times the steps, about `N^0.46`. So 5 M costs 1.5 times the steps
  of 2 M, 10 M 2.1 times.
- **A hires, then.** The 2 M hires of a night take TODO minutes (`costs`); 5 M would be about
  four times that, 10 M about eleven times: one scene a night at 10 M, two or three at 5 M,
  against four at 2 M today.
- **Memory and disk.** A take costs six bytes a particle a frame: 2.8 GB for the 2 M hires of
  a night at the take interval of four, 7 GB at 5 M, 14 GB at 10 M. The tree's float ranges
  were fixed past sixteen million ([float-node-ranges](float-node-ranges.md)); with live
  halos a 10 M visible run simulates 25 M. The renderer draws 4.8 M in 18 ms at 1440p
  ([replay-slideshow](replay-slideshow.md)); it is never what decides.
- **The night budget.** Explore previews are capped at 200 000 a galaxy because past that a
  preview keeps no more of what a hires shows (#21); that cap is about choosing scenes and
  does not need to move. Only the hires count does, and only for the scenes kept.

## Recommendations

TODO after the numbers.
