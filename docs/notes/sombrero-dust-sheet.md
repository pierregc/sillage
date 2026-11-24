# The Sombrero's dust sheet: what exists, and how to run the bench

State on 24/11 of the sampler side of #478's dust, for whoever takes it over. The plan, Pierre's
criteria, the measured figures and the split between agents are in `sombrero-dust-bench.md` on
branch `sombrero-478`; read it first. This note only says what is already written on branch
`claude/project-thread-yxfc71` (PR #481), so nobody starts it again.

## What is written

Two fields of `dustRing` in `scene.json` (`GalaxyConfig.DustRing`, `DiskSampler.sampleDisk`):

- `sheet`, 0 to 1: the share of the ring's grains laid as one continuous layer, the rest staying on
  threads or strands. Absent: none, and the scene samples to the bit as before.
- `cotton`, 0 to 1, absent 0.6: how uneven the sheet is.

A sheet grain is drawn in the ring's own radial profile (`radius`, `width`, `innerWidth`) and kept
with a chance `DiskSampler.sheetKept` of the cloud field `DiskSampler.sheetCloud` where it lands,
up to 64 tries, so the density is envelope times noise:

- `sheetCloud`: three readings of the sampler's hashed value noise (`grain`, three octaves each,
  no period): fine fibres and wide clouds read in coordinates that follow trailing spirals of pitch
  `sheetPitch` (0.22 as a tangent, about 12 degrees), bent by a slower noise so the lanes are not
  combed; and puffs read in plain x and y. Scaled to one standard deviation (`sheetSpread`).
- `sheetKept`: a lognormal, `exp(1.2 cotton (cloud - 2))`, times a floor that rises inward, from
  nothing at one inner width inside the radius to 0.8 standard deviations at two and a half: only
  the densest clouds are left there, the wisps Hubble shows inside the ring.
- The layer: `thickness` at the rim, 0.35 of it inside (`sheetFlare`), 0.6 of it as random height
  and the rest as a ripple whose phase and size come from a slow noise; each grain is launched cold
  on a circle with the vertical speed of its own phase (`DiskEquilibrium.verticalFrequency`), as
  the threads are, so the layer does not fall through the plane at once.

Test `theRingIsLaidAsASheet` (SamplingTests): cold, sparse inside, uneven as `cotton` asks, the
file round trip, nothing moved without the field.

## The bench, as it runs today

No run, no GPU, about 30 seconds a try in a cloud session:

```bash
SILLAGE_DUST_BENCH=references/sombrero/tools/dust-sheet.scene.json \
SILLAGE_DUST_BENCH_OUT=/tmp/grains.f32 SILLAGE_DUST_BENCH_COUNT=4000000 \
    scripts/linux.sh test-core --filter DustBench
python3 references/sombrero/tools/dust_map.py /tmp/grains.f32 /tmp/try 1.0      # strength
python3 references/sombrero/tools/dust_map.py /tmp/grains.f32 /tmp/try12 1.0 12 # after 12 Myr of shear
```

`DustBenchTests` samples the scene and writes the dust grains alone; `dust_map.py` draws them face
on and at Hubble's inclination. `dust-sheet.scene.json` is scene v6 with no young regions and the
ring as the infrared picture and Bendo et al. 2006 give it: radius 6.7, width 1.06, thickness
0.04, sheet 0.9, cotton 0.8, threads 700 for the rest.

It is a prototype, and these are its known gaps against the bench the plan asks for:

- The light behind the dust is a stand-in (a glow and a flat disk), not a frame of the take drawn
  with the dust off; the far side is dimmed by a fixed half. Use `bench/light.png` as planned.
- No roll, no crops beside Hubble's, no `measure.py` figures, no grid of variants in one call.
- The noise's constants (pitch, scales, weights, the floor, the flare, the ripple) are written in
  `DiskSampler.swift`: a try on them is an edit and a rebuild. For fast grids either read them from
  the environment in the bench only, or port `sheetCloud` and `sheetKept` to NumPy in the bench and
  port the winner back.
- The opacity per grain (`luminosity`) still carries the older coarse noise of the strands.

## What the first tries show

- With `sheet` 0.9 the lane at Hubble's inclination is one dark band with a streaked, clouded
  texture, and a ring face on, in place of separate lines. Nobody has judged it beside Hubble yet,
  and Pierre has not seen it in Sillage's own renderer.
- Face on, the fine streaks still read as brushed and a little blocky: value noise shows its
  lattice. Gradient noise, more octaves or a stronger bend are the things to try.
- The remaining threads stray outside the ring's edges as lone wires at 0.1 of the grains: try 0.
- Untested: how the renderer's dust web (`dustWeb` 1) and `dustWidth` draw a sheet; how the sheet
  looks after 12 to 18 Myr of the run; the far lane; close passes in flight.

## The bench, as built: `references/sombrero/tools/dust_bench.py`

```bash
git fetch origin assets/478-sombrero          # the real light, dust off (--light origin, the default)
python3 references/sombrero/tools/dust_bench.py --grains /tmp/v6.f32 --sheet /tmp/v6.jpg \
    --ref "Sillage v6 (rendu réel)=real-v6-still.png"       # grains from DustBenchTests
python3 references/sombrero/tools/dust_bench.py scale=0.4,0.9,1.8 warp=0,0.6,1.2 --sheet grid.jpg
```

Procedural dust (envelope times fBm, parameters in `DEFAULTS`, as key=value or JSON) takes about 10 s
a frame at 3072 px; a grid of 9 about 90 s at 1536 px. Hubble on top, variants below, French
labels, `measure.py` figures on each. Calibrated on the v6 grains (8 M take, 1.2 M dust grains)
against the real v6 still: `k` 0.19, `behind` 0.95, `behind_far` 0.18, `redden` 3, `blur` 0.6 px.
It reads the near lane as slightly wider and more solid than the renderer does (width 0.34 against
0.28, rim solid 0.77 against 0.63); the lane's depth, red over green and the far lane match.

### Bench fixes (#488)

- The envelope stops at `rim` whatever `fall` says (p1 to p6 carry `fall` 0.8, which used to leak
  dust to 1.09 of the rim). The mass beyond the rim is gone, so the figures renormalise: p6 rim solid
  0.73 to 0.83 (the same as the old code with `fall` 0.01).
- Sand: grains are drawn on a scrambled Sobol sequence and splatted bilinearly (`qmc`, `splat`, 1;
  0 gives the old random, nearest-pixel bench). On p6's low-density edge the error against a 48 M
  reference falls from 0.23 to 0.15 at 6 M grains and to 0.07 at `n=24000000` (13 s), where 2 px
  detail is carried without sand. Chunks are at most 3 M grains, so any `n` fits in memory.
- A thin sharp upper edge needs radial structure, which the 6 degree view foreshortens tenfold:
  `edge` (density share of a ridge at the rim), `edge_w` (kpc), `edge_thin` (thins the layer there).
  The soft left tip: `tipfade`, `tip_az`, `tip_w` thin a sector, most at the rim. All 0 by default.
  The far lane is only `behind_far` 0.18 of the light, so the line stays faint beside Hubble's.
- Noise lattice: each octave has its own spiral tilt (`twist`, 0.45) and reference radius
  (`rjitter`, 0.12), still periodic in azimuth. `twist=0 rjitter=0` restores the axis-aligned lattice.
- `grey` (0): the reddening is divided by `1 + grey k N`, so thin dust reddens and thick dust goes
  grey-brown; try `redden=5 grey=1.5`. No violet yet.
- `clean_light` keeps knots above `keep_upper` (0.45 kpc over the plane's line), wide patches and
  weak ones (`peak` 16); `--face-linear JPG` draws the optical depth linearly, 0 to 1, unstretched.

### Hubble's full-resolution frame (#486)

The reference is ESA/Hubble's large JPEG of heic2506a, 14319 x 8477 px (1.85 pc a pixel at 26.5 kpc
across). It has Hubble's own framing: registered on the old 1024 x 606 copy it sits within 0.01 px
of it (at the copy's scale) and 0.00001 in scale, so the core is still at 0.4922, 0.3047 of the width
and the roll 5.63 degrees. The tools take it from `--hubble PATH`, else `$SOMBRERO_HUBBLE`, else the
local copy `hubble_ref.DEFAULT_PATH`, else from branch `assets/478-sombrero`: `heic2506a-lane-strip.jpg`
(a lossless crop of the same file, full width, rows 2640 to 6160, 11.2 MiB) and `heic2506a-3072.jpg`
(the whole frame at 3072 px, for the sky outside the strip). Positions are shares of the frame's
width (`hubble_ref.py`); `measure.py` brings every frame to `--width` (default 3072, the bench's)
and Hubble is drawn on sheets from the full frame at the sheet's scale, never enlarged.

Hubble's figures by the width they are measured at (`measure.py`, default width 3072):

| figure | old 1024 copy | large @1024 | large @3072 | large @6144 | large @14319 |
|---|---|---|---|---|---|
| near lane offset (kpc) | 0.71 | 0.70 | 0.73 | 0.73 | 0.73 |
| near lane width (kpc) | 0.27 | 0.31 | 0.29 | 0.28 | 0.28 |
| near lane left | 0.46 | 0.48 | 0.46 | 0.45 | 0.45 |
| near lane r/g | 1.34 | 1.30 | 1.28 | 1.28 | 1.28 |
| far lane left | 0.97 | 0.97 | 0.96 | 0.97 | 0.96 |
| rim width (kpc) | 0.21 | 0.22 | 0.17 | 0.17 | 0.17 |
| rim r/g | 1.29 | 1.22 | 1.22 | 1.22 | 1.22 |
| rim solid | 0.68 | 0.70 | 0.81 | 0.88 | 0.91 |

The halo, the side light, the disk and the sky do not move. The lane's red over green reads 1.28 on
the large frame, 0.06 under the old copy, which was a little more saturated than its source. The
rim's width and solidity depend on the pixel: the finer the scale, the narrower and the more
speckled it is, so a bench is compared to Hubble at the same width. At the bench's 3072 px, Prototype
6 reads rim solid 0.88 against Hubble's 0.81.

Close-ups: `closeup.py OUT.jpg [frames] [--scale N|native]` draws the lane's left tip, centre and right
tip, Hubble beside each frame at one scale (default 6144 px across, twice the bench). `dust_bench.py
--width 6144` renders the bench that wide in about 11 s and 5.4 GB; its light stays the 3072 px one,
so only the dust gains.

#### Bench fixes (#488), follow-up

- Geometry: `edge` sits at the OUTER radius, so on the far half it is the upper edge and on the near
  half the lower, sparse one. Hubble's sharp dark edge is the near lane's upper side, the INNER radii
  (`inner` 0.56 of the rim projects 0.5 kpc below the core). `taper` (kpc) makes the profile densest at the
  inner cut and sparse outward, `wobble`/`wobble_len` scallop that cut along the azimuth;
  `rise=0.05 floor=1 inward=1 taper=2 wobble=0.4` is a first setting.
- Thin layers: `thickness=0.005` draws clean at 3072 and 6144 px. Error against 48 M grains in the
  lane: 0.04 at 6 M, 0.016 at 24 M (3072); 0.045 and 0.018 (6144). 24 M grains: 15 s and 1.9 GB at 3072,
  20 s and 6.8 GB at 6144. A thinner layer is denser for the same `mass`: lower it.
- Colour: `redden=9 grey=0.8 mass=1.6` gives a dark top band and orange below it.

## Texture figures (#487): `texture.py`

The bench's figures (depth, width, r/g, rim solid) say nothing of the pattern; `texture.py` measures
the pattern on Hubble's full-resolution frame and scores any frame against it.

```bash
texture.py frame.png --json out.json --panel out.jpg      # about 1 s at 3072 px, 3 s at 6144
texture.py --build-ref                                     # measure Hubble again (60-100 s)
texture_proofs.py OUTDIR --frames DIR --grid 6144 --hubble-clean HUBBLE.png --sheets
```

`score(image)` returns the distance per figure, per region and the summary, every component's z
and the figures themselves; `panel(result, label)` draws a sheet panel. Hubble's side is cached in
`texture-ref.json` (70 kB); the 26 MB frame is only needed to rebuild it (`hubble_ref.py` finds it).

### What is measured, and how

- **Grid.** The frame is reduced to 3072 px (8.6 pc a pixel) or 6144 px (4.3 pc), the finest it
  fills. Hubble's point sources are removed first at full resolution (4816 compact peaks over an
  11 px median, bluer than their surroundings or very bright: the ring's young stars, globular
  clusters, foreground stars); bench frames are not cleaned, the bench draws no such points.
- **Unwrapping.** The near lane is cut along a centre line fitted on Hubble (a robust quartic through
  the dust's centroid; the left tip sits lower than the right) into u, kpc along the major axis
  from -7.5 to 7.5, and v, kpc across from -0.35 to 0.42, v > 0 towards the core.
- **Apparent opacity.** A = ln(I0 / I) on linear light (display values decoded with gamma 2.2), I0
  a quadratic in v fitted per column through rows 0.3 kpc beyond each side of the band (an upper
  envelope, its coefficients smoothed over 0.25 kpc along). The same estimator runs on every image,
  so no model of the dust-free galaxy enters the score. On the dust-free bench light it reads 0.01
  nat rms at 8-17 pc, 0.02 at 17-50 pc, 0.04 at 50-900 pc, against Hubble's 0.14, 0.16 and 0.16-0.39.
- **Scales.** Trusted from 4 px (35 pc at 3072, 17 pc at 6144; the analysis blurs every image by
  1 px so the bench's blur and Hubble's resampling end alike) to about 0.4 kpc (half a window along,
  half the band across). Beyond 1 kpc the fit's error equals Hubble's own variation: the figures do
  not use those scales. On Hubble the lane holds 3 to 6 times the grain's rms at every scale used.
- **Regions.** 16 windows of 0.94 kpc, pooled apart into the centre (|u| < 4.7 kpc) and the tips
  (4.7 to 7.5 kpc, seen along the ring's tangent: softer upper edge, wider strata).
- **Distances.** Per figure, the rms over its components and both regions of (value - Hubble) /
  spread, the spread being that of Hubble's windows scaled to an independent region of the same
  size (so a lane like Hubble's scores about 1). The summary is the power mean (p = 8) of the
  figures' distances, close to the worst figure, so no figure can be traded against the others.
  `colour` is shown, not summed (it is set by the bench's colour model, not by the dust's pattern).

At 6 degrees from edge on, radius is foreshortened about tenfold across the lane and height is
not: a thin horizontal filament is either in-plane structure in a very thin layer or a thin sheet
at some height. No figure across the lane can tell the two apart; do not read them as either.

### The figures, and Hubble's values (centre, 6144 grid)

- **spectre le long / en travers**: power of A along and across the lane, 17 to 410 pc. Hubble's
  power rises as about k^-1.9 along and k^-1.8 across: speckle at every scale, no preferred size.
- **histogramme**: quantiles 1 to 99 % of A in the lane's core rows. Hubble: 0.16, median 1.14, 2.42 nats.
- **phase (kurtosis)**: fourth moments of the 100 pc high pass, of two bands and of their slope
  across, which are 0 for any Gaussian-phase field whatever its spectrum. Hubble's high pass is
  flat-topped (-0.57): dust and gaps, evenly, rather than a few extreme spots.
- **asymétrie sombre/clair**: third moments of the same: dark speckle on a clear ground (+0.47) or
  clear holes in dark dust (negative).
- **intermittence**: how patchy the local energy of three bands is, log10 of its spread over its
  mean (-0.14 to -0.60). This is "even as a whole": Hubble's speckle fills the lane evenly; the
  prototypes concentrate it in patches (+4 to +10 spreads).
- **forme des taches**: Koenderink's shape index weighted by curvature at 4, 9 and 17 pc: shares of
  clear holes, streaks and dark knots (Hubble 0.13, 0.38, 0.14 at 4 pc; the rest saddles).
- **filaments**: dark ridges at their own width: 77 % of the strongest ridges are line-like, median
  length 23 pc and 98 pc at the 90th percentile, about 9 pc thick, 17 degrees from the lane on
  average with a 22 degree spread, 39 % of ridge area in parts longer than 150 pc (a web).
- **entre échelles**: correlation of a band's magnitude with the next band's (0.48 to 0.59): fine
  speckle sits where the coarser structure is, which a Gaussian field does not do.
- **Minkowski**: perimeter and Euler characteristic of the speckle above each decile (thresholds
  by quantile, so the histogram cannot move them); Hubble's Euler curve runs from -0.77 to +0.64.
- **taches sombres**: the darkest tenth as connected blobs: 63 per kpc^2, median 490 pc^2, elongation
  2.1, 16 degrees from the lane with a 21 degree spread.
- **anisotropie**: structure-tensor coherence (0.74) and orientation at three scales, and the speckle's
  correlation length along (50 pc) and across (22 pc).
- **strates**: peaks of 0.06 nats or more in the across profile of 0.47 kpc stretches (2.6), the
  share of the residual that holds over 0.1 and 0.3 kpc along, its autocorrelation across at 17 to
  140 pc (0.57, 0.20, then none).
- **bords**: per column, the 25-75 % rise of each edge, its raggedness and correlation length, and
  its place. The upper edge (towards the core) rises in 74 pc and is ragged by 19 pc over 56 pc;
  the lower one rises in 146 pc. At the tips the upper edge softens to 146 pc.
- **profil**: mean A across the band at 13 heights (peak 1.57 nats just over the centre line).
- **couleur / profondeur** (shown, not summed): A_g - A_r and A_b - A_r in four depth bins (0.2 to
  3 nats). Hubble: 0.18, 0.44, 0.67, then 0.52 in the thickest dust: the dark top band turns grey.
- **stationnarité** (whole lane): window-to-window spread of the core's mean A (0.13 nats), of the
  contrast at 35 and 70 pc and of the width (63 pc), and their left-right differences.
- **symétrie, répétition** (whole lane): correlation of the speckle at u with the speckle at -u
  (Hubble 0.03), and the highest correlation along the lane at lags of 1 to 7 kpc (0.06).

### Floor, prototypes, adversaries, round trip

Summary distances (p = 8; maps scored as maps, frames as frames). Prototypes rendered after #488's
merge (rim cut, Sobol grains, bilinear splats).

| | 3072 | 6144 |
|---|---|---|
| Hubble odd windows against even ones (noise floor) | 1.05 | 1.02 |
| Hubble left half against right half | 2.02 | 2.05 |
| Hubble with its point sources kept | 0.32 | 0.89 |
| p1 voile cotonneux | 8.70 | 8.38 |
| p2 voiles étirés | 10.33 | 7.26 |
| p3 cumulus effilochés | 5.08 | 5.10 |
| p4 nappe et fibres | 9.66 | 8.90 |
| p5 voile étagé | 9.02 | 7.54 |
| p6 veines de nuage | 7.42 | 5.92 |
| (a1) Gaussian phases, Hubble's spectrum and histogram, Hubble's mean profile (map) | 3.10 | 4.00 |
| (a2) the same, keeping all structure coherent over 1 kpc along (map) | 2.56 | 2.96 |
| (b) Hubble's left half mirrored onto the right (map) | 15.1 | 18.8 |
| (c) plain isotropic fBm on the bench, old figures 0.48 / 0.19 / 1.34 / 0.95 | 7.20 | 7.08 |
| should pass: Hubble cut in 1.5 kpc blocks and shuffled (map) | 1.80 | 1.63 |
| should pass: Hubble slid 3.7 kpc along the lane (map) | 1.86 | 2.06 |
| round trip, bench blur 0.6 | 1.86 | 3.20 |
| round trip, no blur | 1.21 | 1.09 |

- The left and right halves differ more than odd and even windows (2.0 against 1.0): Hubble's two
  sides really differ (the left tip broad and low, the right one narrower). Shuffling or sliding
  Hubble moves the tips' texture into the centre, which is why those pass at about 2, not 1.
- At 6144 the Gaussian fields fail on phase (4.1 to 4.7), intermittency (3.0 to 3.4), entre échelles
  (2.9 to 3.6) and, for a1, the edges (5.4) and profile (4.3); they pass the spectra, histogram, filaments (at 3072) and
  Minkowski. At 3072 a2 reaches 2.6, close to the left-right floor: score at 6144 where possible.
- The mirror fails only on symmetry (21 to 27), as it must: its local statistics are Hubble's.
- Prototypes: p3 ranks first of the six on both grids and p6 second; Pierre found p6 the least far. All are far (5 to 10). What sinks every one of them: too little power along the
  lane at 26 to 180 pc (-8 to -19 spreads: sheared noise is smooth along), patchy rather than even
  speckle (intermittency +4 to +10), and kurtosis on the wrong side (spiky, not flat-topped). p6
  is the best of the six on filaments, Minkowski, edges and symmetry, which is plausibly what Pierre
  sees: the right kind of element (veins) in the wrong distribution. p3 wins on the spectrum across
  and the blobs. The figures were not tuned to match Pierre's order. Before #488 the prototypes
  scored 3.5 to 5.4: the old bench's sand supplied fine power by accident.

### Round trip: can a perfect generator succeed on this bench?

Hubble's own apparent-opacity map, laid on the bench light with the bench's compositing (N solved so
the green channel dims by exp(-A); `behind` 0.95, `redden` 3), comes back at 1.2 (3072) and 1.1
(6144) without the bench's blur, at the noise floor. The light model and the `behind` share are not
the limit for the near lane (`behind` 0.8 would be: 3.4 to 4.6). Two things are:

- **The blur.** `blur` 0.6 (in 3072 px pixels, 5 pc) erases Hubble's 5-20 pc filaments: the round
  trip falls to 3.2 at 6144 (filaments 4.4, spectra 3.3 and 3.7). At 6144 it scores 1.68 with
  `blur` 0.3 and 1.10 with 0.15. A generator meant to match Hubble needs frames at 6144 px with
  `blur` 0.15 to 0.3, hence enough grains not to show sand (#488: 24 M grains).
- **The colour.** `couleur / profondeur` stays at 4.7 even for Hubble's own map: one reddening law
  cannot make the thickest dust grey. It is not summed. `grey` (#488) was not tested here: the
  round trip inverts the bench's law with `grey` 0.

### The far lane

The far half of the ring is unwrapped and measured the same way along its own centre line (a
robust quartic through the faint dips of Hubble's light over the core, weighted by their depth: 0.43
kpc over the core at the centre, 0.4 at 4.5 kpc out, 0.8 at the tips; band 0.4 kpc wide), reported
apart in `score()["far"]` and drawn, ten times more contrasted, on `hubble-lane.jpg`. Thin dark
filaments show there in a few stretches, against the bulge's grain. It is not scored, and no
figure is kept that would always pass:

- **Texture at the grain's level.** From 4 to 140 pc the far band's rms is 0.4 to 1.1 times the
  grain's in the rows beside it (0.008 to 0.015 nats a pixel); a figure would need 1.5 or more.
- **Depth, width, offset at the estimator's error.** Hubble's far profile peaks at +0.010 nats; on
  the dust-free bench light the same estimator reads -0.01 to -0.02 across the band. A centre line
  mirrored from the near lane did worse (+0.09 on the dust-free light, the bulge bending too fast
  for a quadratic so near the core), which is why the far line is fitted on Hubble's dips.
- The bench's far dust (p1-p6, mean A -0.045 against -0.019 on dust-free light) falls partly in the
  rows this estimator takes as dust-free: the bench's far half sits further from the core than
  Hubble's dips. Worth a look in #495; this estimator cannot measure it.

Judging the far lane needs another estimator (the bench light registered on Hubble with a
large-scale correction, or a frame-by-frame differential test), or counts of the few filaments
that stand above the grain; #495 is the place for it.

### Using the score without fooling yourself

- Score at 6144 with `blur` 0.15 to 0.3 when the frame can carry filaments; at 3072 Gaussian-phase
  fields come within 0.5 of Hubble's left-right floor.
- Read the bars, not only the summary: a frame is like Hubble when every summed figure is under
  about 2 (Hubble's own halves reach 2.5). Phase, intermittency and filaments are the figures a
  smooth or Gaussian field cannot fake; spectra and histogram alone can be matched by one.
- Score two or three seeds of a setting: one window's noise moves a figure by about 1.
- Do not paste Hubble's map, mirror or tile a texture: symmetry catches a mirror and any period
  under 7 kpc along the lane, but a copy of Hubble in another order would pass by construction.
- The figures' spreads come from 10 and 6 windows of one galaxy: a distance under 1.5 is noise,
  over 3 is a real difference.

Sheets for Pierre, in `~/claude-workspace/sombrero/banc/487/`: `hubble-lane.jpg` (the lane, near and
far, unwrapped and as opacity maps), `aller-retour.jpg` (the round trip beside Hubble, same scale),
`p6-adversaires.jpg` (p6, the fBm, the adversaries and the round trip, each map with its bars).

### Through the bench at low blur (follow-up)

Everything laid on the bench light at 6144 px with the explorers' settings, p1-p6 and the fBm
rendered at 24 M grains (`texture_proofs.py OUT --grid 6144 --blur 0.15 --frames DIR --sheets`).

| summary (worst bars) | `blur` 0.15 | `blur` 0.3 |
|---|---|---|
| round trip | 1.08 | 1.67 |
| Hubble in shuffled 1.5 kpc blocks | 1.79 (phase 2.4) | 2.07 (phase 2.7) |
| Hubble slid 3.7 kpc | 2.10 (anisotropy 2.7) | 2.20 (anisotropy 2.7) |
| Gaussian phases, Hubble's profile | 3.94 (edges 5.1, phase 5.0) | 4.12 |
| Gaussian phases, Hubble's 1 kpc structure | 3.14 (spectrum 4.1, phase 3.8) | 3.39 |
| mirror | 18.6 (symmetry 26.5) | 18.6 |
| plain fBm | 8.21 | 8.62 |
| p1 / p2 / p3 / p4 / p5 / p6 | 9.83 / 8.40 / 5.65 / 10.64 / 9.10 / 7.87 | 10.26 / 8.84 / 5.97 / 11.04 / 9.62 / 8.28 |

- At `blur` 0.15 the rows that should pass stay at or under Hubble's own left-right floor (2.05) and
  the Gaussian fields sit 1 to 2 above them; at 0.6 the bench's blur put all of them near 3.2.
- The Gaussian fields fail on phase (3.8 to 5.0), the spectra along (3.1 to 3.5), entre échelles
  (2.5 to 3.2) and intermittency (2.7). They pass filaments (1.7): that bar is no Gaussian test.
- **Pass line** at 6144, `blur` 0.15 to 0.3: summary under 2.3, no bar over 3, and phase under 3.
  The should-pass rows reach 2.2 and 2.7; the Gaussian fields break the phase bar in every case.
  The real test is phase together with the spectrum along and entre échelles: a field that passes
  all three is not Gaussian-phase noise with the right spectrum.

**Colour.** Fitting `redden` and `grey` on the round trip (redden 1 to 12, grey 0 to 4) brings
`couleur / profondeur` from 4.7 to 2.65 at best (redden 12, grey 4, the grid's corner), not to the
floor. The residual is in the ratio of blue to green reddening, which the bench fixes at 0.52 : 0.22
(2.4): Hubble's is 1.8 to 2.1 in thin and middle dust and 1.55 in the thickest bin, so the dense
top band is bluer than any one law with that ratio allows (scattered light, or the blue clusters
in it). Masking only that band would not help, the ratio is off in every bin; the honest course is
the one taken, colour shown and not summed. A per-channel law (or a blue light share in front of
the top band) would be the bench change, not an explorer's setting.

**Memory.** At 24 M grains a 6144 frame peaks at 6.8 GB in the main process, a 3072 frame at 1.9 GB
(14 s). A 3072 frame with `blur` 0.15 scored with `texture.py --grid 6144` is not meaningless: the
round trip scores 1.29 against 1.08, p6 8.42 against 7.87, the loss being mostly in the filaments
bar. So explorers can screen at 3072 (`--grid 6144` must be given, the default picks 3072 for a
3072 frame) and render finalists at 6144. Rendering only the lane's rows (about a fifth of the
frame's height, the score reads nothing else) would cut the 6144 frame's arrays about five times;
it needs a row window in `dust_bench.project` and `attenuate` and was not built.
