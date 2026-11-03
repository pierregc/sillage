# Gigantism: why a render reads as sand, and what buys the halo

Spike asked on 2026-11-01. A Hubble or Webb picture of a galaxy is a continuous glow with a
few resolved clusters in it; a Sillage frame at two million particles still reads as a cloud
of grains. The first idea was more particles, and the question was what else there is before
paying for that. Measured on the M4 Max (36 GB) on `library/2026-10-30-b/scene-0031`, the
newest 2 M hires (two spirals, 923 frames, 1003 s), and on the isolated disk preset. The
sheets, 1:1 crops, scores and logs are on the branch `assets/gigantism` under
`docs/spikes/gigantism/`; the 4K frames themselves stay on the Mac in
`~/claude-workspace/gigantism-out/`.

## Where the grain comes from

Three things, and only the third is the particle count.

**The kernel is sized in three dimensions and the picture is a projection.** Every star is
drawn as a Gaussian whose width follows the local interparticle spacing read off the solver's
tree (`SmoothingField`): `w * n^(-1/3)` for a leaf of `n` particles in a cell of width `w`,
times the look's `smoothingScale`. That is the right length for a volume. A thin disk seen
face-on stacks many of those spacings along a line of sight, and a kernel one spacing wide
covers only a few of the particles that share its patch of sky; noise per pixel goes as one
over the square root of that number. The profile makes it worse than it looks on paper: the
fragment falls as `exp(-4.5 r^2)` to the edge of the point, so the Gaussian's sigma is a
sixth of the point size, and a star drawn at a `span` of three spacings has an effective
width of half of one. The styles the nights generate make it worse again: scene-0031's look
has `smoothingScale` 1.2 and a kernel floor of 0.8 px, against 1.9 and 1.1 in the standard
look.

**Two per cent of the stars carry a quarter of the light as point sources.** `DiskSampler`
draws, on purpose, a compact minority: 2.2 % of the disk stars get four to forty-four times
the brightness and a kernel three quarters the size, "the sources the eye picks out one at a
time". In counting terms that is expensive. With the light per particle `w`, the number of
particles a pixel effectively averages is `N (mean w)^2 / mean(w^2)`; for the sampler's draw
(mean boost 14, mean square 325, on 2.2 % of the stars) that ratio is 0.19. A disk of
200 000 particles smooths like one of 40 000, and the forty thousand it smooths like are
exactly the bright ones. The HII knots add to this at ten times the light per unit mass.

**And the count.** With the two above fixed, what is left is Poisson noise in the column,
which falls as one over the square root of the number of particles under a kernel. Doubling
the particles takes 29 % off the grain; halving it costs four times the particles.

A fourth thing turned up in the measurement and is not grain at all: **the framing**. In
this scene, as in the nights' director shots, the galaxies cover 1 % of the frame in the
approach and 4.7 % at the widest, 150 to 250 px across in 4K. At that size every pixel
already averages tens of particles and the count does not show; and nothing 250 px wide reads
as gigantic, however it is drawn. Hubble fills the frame with the galaxy.

## What was tried

Three look fields, all behind neutral defaults, plus the two things a look could already do.
Neutral is not quite bit for bit: the default path against main differs by one level on
0.04 % of the pixels (915 of 2 073 600 on the disk preset at 300 k). The shader is compiled
with fast math, and the mere presence of the column code in `splatVertex` changes how the
compiler rounds the path that does not run it; each build is deterministic against itself.
Strict identity would take a function constant to compile the new code out of the default
pipeline. Two of the three are kept; the third was
measured and taken out again.

- `columnSmoothing` (slider "Étoiles sous le noyau (projection)"): before the splat pass a
  count pass draws one point per emitting particle into cells eight accumulation pixels wide.
  The splat vertex reads the count back at its own screen position and widens its kernel to
  cover that many stars in projection, never narrower than the tree's answer. One more vertex
  pass over the buffer and a 1/64 texture.
- `glint` (slider "Sources compactes"): the compact minority's extra light and narrowness,
  dialled from as sampled (1) to an ordinary star (0). Nothing is resampled; the shader knows
  them by their kernel scale.
- `haze` and `hazeScale`, not kept: a share of every star's light drawn `hazeScale` times
  wider into a target a quarter the size on each axis, added back at resolve, the main pass
  keeping `1 - haze` so the exposure did not move. Measured below and removed afterwards.
- For comparison, the two hammers a look already had: `smoothingScale` up 1.6x with the
  kernel floor at 2 px (the direction of the Onirique look), and bloom with its threshold at
  0.05 and intensity 1.

`sillage-render look SCENE --stills DIR [--width 3840]` writes each look at each key frame
at full size, and `scripts/grain.py score` measures them. Over the body of the galaxies
(blurred luminance a floor above the sky, short of white): the relative rms of what is finer
than two pixels (`grain`), the relative rms of what lies between four and sixteen pixels
(`structure`, the arms and lanes a smoothing must not take away), and the share of body
pixels standing a quarter above their surroundings (`points`, the sparkle).
`scripts/gigantism-spike.sh` runs the scene comparison, `scripts/gigantism-disk.sh` the
single disk below.

## The scene: ten looks at five key frames

4K, supersample 2, the five key frames of the take (157, 237, 308, 637 and 887 Myr),
averaged. The sheets `sheet-<frame>.jpg` and the crops `crop-*-606.jpg` are what to look at;
the numbers say the same thing with less nuance.

| look | grain | structure | points |
| --- | --- | --- | --- |
| baseline | 0.184 | 0.244 | 8.7 % |
| smooth (smoothingScale x1.6, floor 2 px) | 0.152 (-18 %) | 0.245 | 6.9 % |
| bloom-low | 0.128 (-30 %) | 0.213 (-13 %) | 4.4 % |
| glint 0 | 0.153 (-17 %) | 0.245 | 7.1 % |
| column 20 | 0.170 (-8 %) | 0.245 | 8.6 % |
| column 40 | 0.153 (-17 %) | 0.246 | 7.8 % |
| column 80 | 0.136 (-26 %) | 0.246 | 6.4 % |
| column 40, glint 0.3 | 0.141 (-23 %) | 0.243 | 6.3 % |
| haze 0.5 (x4) | 0.136 (-26 %) | 0.237 (-3 %) | 5.2 % |
| column 40, haze 0.3 | 0.132 (-28 %) | 0.239 (-2 %) | 5.6 % |

- **Glint is what the eye sees.** At 1:1 on the big disk of frame 606 the baseline is
  riddled with bright points over the whole disk and the tail; at glint 0 nearly all of them
  go, the disk becomes a continuous, finely textured light, and the arms, the dark ring and
  the knots stay. The knots lose a little contrast (structure -3 to -5 % on that frame). It
  costs nothing: the still draws faster, since the points were the widest fragments.
- **The projected kernel works as designed and shows less than expected here.** Column 40
  and 80 take 17 and 26 % off the grain with the structure unchanged to the third decimal,
  and the crops confirm the lanes and arms are as sharp. But the bright points remain, so to
  the eye the frame is still grainy. Together with glint 0.3 it is the best compromise on
  this scene (-23 %, points from 10.2 to 7.4 % on frame 606). Cost: +5 ms GPU a frame at 2 M
  in 4K, +24 ms at 8 M.
- **Haze reads as a halo under the stars, not as fog.** It softens edges and makes the
  fewest points of all here; on the single disk below it washes the dust lanes out and costs
  36 ms a frame at 8 M. Removed.
- **Bloom at the floor is not a track.** It lifts everything and burns the core; its low
  grain score is an artefact of the mask growing into the glow, and it is the only variant
  that loses structure.
- **A third of the fine grain is the film noise.** The look's `noiseLevel` 0.0014 alone:
  baseline at t = 0 scores 0.109 with it and 0.075 without. That grain is the same at every
  count and every kernel, by design (see [scintillation](scintillation.md)).

## The scene: 250 000 to 8 million particles

Same scene at t = 0, 4K, baseline and column 40, one frame each. The grain score does not
move: 0.109 at 250 k, 0.109 at 2 M, 0.107 at 8 M. Both galaxies are about 250 px across in
this framing, so every pixel already averages tens of particles and what the score measures
is the film noise and the compact minority. On `sheet-count.jpg` at 2x the 250 k disk is
visibly blotchy and the 8 M one finer, with cleaner arms; that is resolution, and it only
shows when the disk is large in the frame. Which is the next section.

Render cost in that series, 4K, GPU per frame: 2.6 ms at 250 k, 10 ms at 2 M, 28 ms at 8 M;
with the count pass 3.4, 15 and 52 ms. The solver in the same runs: 13 ms a step at 250 k,
107 at 2 M, 453 at 8 M.

## One disk filling the frame

The isolated disk preset at t = 0, seed 7, a fixed camera at 1.35 rad of elevation framed on
the disk: 1460 px across in 4K, two thirds of the height. Six looks at four counts
(`disk/sheet-disk-*.jpg`, `disk/crop-*.jpg`), the GPU time per frame in `disk.log`.

The grain score cannot rank the counts here, and it is worth saying why: at 250 000 a
particle is a soft blot of 5 to 15 px, which the 4 to 16 px band counts as structure, and at
8 M it is 1 to 2 px and lands in the grain band. The columns swap places as the count grows
(baseline grain 0.046 to 0.103, structure 0.108 to 0.057). The images are the measurement.

| at 1:1 | 250 k | 1 M | 4 M | 8 M |
| --- | --- | --- | --- | --- |
| baseline | soft blots, bokeh, plus bright points | smaller blots, a seeding of bright points with spikes | fine grain, still much sparkle | sand at the pixel, sharp dust filaments, sparkle |
| glint 0 | blots, no sparkle | blotchy, no sparkle | fine grain, no sparkle | continuous texture, sharp filaments, no points |
| column 80, glint 0 | frankly out of focus | smooth, no points, soft; lanes become dotted | smooth and nearly sharp | smooth and sharp, close to glint 0 |

- **Only 8 M makes a disk that reads as matter**, and 8 M with glint 0 is the best frame of
  the lot: a fine continuous texture, no scintillation, dust filaments drawn as lines. The
  blots go somewhere between 4 and 8 M.
- **Glint removes the sparkle at every count and changes nothing else.** It does not turn
  blots into a surface; it takes the points off whatever surface there is.
- **The projected kernel smooths by blurring.** At 1 M with column 80 the disk is smooth and
  reads as a soft focus, not as a resolved galaxy; the fine filaments 8 M draws are not there
  to be smoothed into view. And the dust lanes come out as strings of dots: the grains keep
  the three-dimensional kernel while the stars around them widen, which is a fixable detail,
  but the blur is the method's. At 8 M it costs nothing to the eye and 10 to 14 ms a frame.
- **Haze** lays a milky veil that hides the grain at 1 M and erases the lanes with it; at 8 M
  it makes the disk misty. Removed.

GPU per 4K frame with the disk filling it, where the cost is the pixels written: baseline
19 ms at 250 k, 26 at 1 M, 33 at 4 M, 55 at 8 M; glint 0 a little under that; the count pass
adds 2 to 14 ms. The disk preset's solver is the cheap one, so nothing here says what a step
costs: that is the next section.

## The other track: more particles

What the particle count buys is resolution: thinner lanes, finer arms, a smaller softening
and so sharper cores and tails. It buys smoothness only at the square-root rate above, and it
is paid for faster than linearly. Measured alone on the GPU, scene-0031 itself (Barnes-Hut,
live halo at 1.5x, opening angle 0.9), 20 steps:

| visible | simulated | a step | peak memory |
| ---: | ---: | ---: | ---: |
| 2 M | 5 M | 104 ms | 2.2 GB |
| 5 M | 12.5 M | 268 ms | 4.5 GB |
| 10 M | 25 M | 550 ms | 8.3 GB |

- **More steps too.** The softening follows the mean spacing and the time step follows the
  softening ([state note](state-and-known-limitations.md)): in these runs 20 steps covered
  2.1 Myr at 2 M, 1.3 at 5 M and 1.1 at 10 M. So a megayear costs about 1 s at 2 M, 4 s at
  5 M and 10 s at 10 M.
- **A hires, then.** `costs` fits a hires at 108 s + 62.4 ns a visible particle step: 23 min
  for 2 M over 10 000 steps. The two 8 M hires in the library (`2026-10-30-b`, scenes 0044 and
  0030) took 28 681 and 28 084 steps with the settle and 4 h each, and the fit puts both within
  2 %. A 10 M hires is five to six hours: one scene a night, against four at 2 M; 5 M is about
  two hours, two scenes a night. (A first fit written here, 1415 s + 57.2 ns, was run on a
  mirror of the library made of symbolic links: a link has its own date, so every run weighed
  the same and the explore runs lost their durations. Mirror with `cp -p`.)
- **Memory and disk.** A take costs six bytes a particle a frame: 2.8 GB for the 2 M hires of
  a night at the take interval of four, 7 GB at 5 M, 14 GB at 10 M. The Mac has 36 GB and
  1.3 TB free; the 10 M run peaked at 8.3 GB. The tree's float ranges were fixed past sixteen
  million ([float-node-ranges](float-node-ranges.md)). The renderer draws 8 M in 28 ms in 4K:
  never what decides.
- **The night budget.** Explore previews are capped at 200 000 a galaxy because past that a
  preview keeps no more of what a hires shows (#21); that cap is about choosing scenes and
  does not need to move. Only the hires count does, and only for the scenes kept.

## Recommendations

In the order they pay.

1. **Frame tighter.** Nothing 250 px wide reads as gigantic, and the nights' shots keep the
   galaxies at 1 to 5 % of the frame. Shots that fill the frame with a disk, or with the
   pericentre, are the first thing that gives size, and they are also where the particle
   count becomes worth paying for. This is the director's and the camera plan's business, not
   the renderer's: a ticket on the Cinematographer's framing. Done in #186,
   [director shots](director-shots.md).
2. **Turn the glint down in the shipped and generated styles**, 0 to 0.3. It takes the
   scintillation off every frame at every count for nothing, and it is the one change in
   this spike that reads the way the brief asked. The field exists and has a slider; the
   catalogue and `StyleAuto` still write 1. Whether the sampler should stop drawing the
   minority at all is a separate question: as a dial it is reversible per style.
   Done in #184 at 0.3 (`RenderLook.styleGlint`): the catalogue, the built in five and the
   standard look name it, so every style a night or the editor writes carries it. A file
   that leaves the field out was written before it existed and reads as 1
   (`LookFile.omittedLook`), so the scenes already in the library keep their picture.
3. **Hires at 8 M for the scenes that will be looked at closely.** It is the count at which a
   frame-filling disk stops being blots. The price is measured: about 4 h a scene against
   25 min at 2 M, 14 GB of take against 2.8, 15 GB of memory, one or two scenes a night instead of
   four. 5 M is a middle (about 2 h) that was not rendered at this framing; if the budget
   allows one scene a night, 8 M; if it must stay at two or three, 5 M and look.
   Done in #185: 8 M is Auto's hires count, and Auto picks one to four scenes, so a night
   plans one or two ([night manager](../night-manager.md)).
4. **Keep the projected kernel as a dial at 0.** It is cheap and it does what it says
   (-17 to -26 % grain, structure untouched) on wide shots where a galaxy is small, and it
   is honest about what it cannot do: it blurs a 1 M disk rather than resolving it. If it
   is ever turned on by default, the dust should widen with the stars.
5. **Not worth pursuing:** the haze layer (removed), bloom at the floor (burns the core),
   and a general smoothing increase (modest, and it blurs everything alike).

What was not tried and might be: light tracers, massless particles integrated in the field
of the massive ones, to multiply what is drawn without shrinking the softening and the step
(the force pass scales with the walkers, so perhaps half the cost of real particles); and
drawing the dust from the same column count. Both are tickets, not spikes.
