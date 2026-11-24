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

### The far half (#495)

**Where it is.** On Hubble the far half of the ring is a thin, faint line over the core, the ring's
inner rim seen from behind, plus a mottled patch over the near lane at each tip. The rest of the far
half (out to the rim) does not show. `closeup.py --reference OUT.jpg` draws Hubble alone at 1.85 pc a
pixel, left, centre and right of the core, plain and with the smooth light divided out (`enhance`:
Hubble's own luminance with every dark feature under 0.3 kpc filled in by a grey closing, smoothed over
0.15 kpc, each channel divided by it times the local colour). It marks the near lane's dense band (0.51
to 0.70 kpc under the core's row) and orange filaments (to 1.0), the inner dust inside the ring (fine
filaments within 0.35 kpc of the core's row, both sides) and the far line, dashed from
its measured row.

**How it is measured.** `measure.py --halves [--width 0]` reads the frame laid flat in columns 0.5 kpc
wide every 0.5 kpc along the disk: each column's light against an upper envelope (a polynomial in log
light refitted on the points not under it), the darkest row 0.2 to 1.4 kpc over the core's row, the
width at half depth, the depth (1 - light left), the edge facing the core. The far figures are medians
over |x| 1 to 4.5 kpc (nearer the core the line is 1 % deep and the inner dust competes; past 4.5 the
line meets the tips). Hubble, full frame:

| far lane | value | left vs right | columns (sem) | baseline degree 2-4 | width 3072 to 14319 |
|---|---|---|---|---|---|
| offset over the core's row (kpc) | 0.45 | 0.002 | 0.02 | 0.43-0.45 | 0.45 |
| width at half depth (kpc) | 0.09 | 0.02 | 0.02 | 0.08-0.09 | 0.09 |
| depth | 0.039 | 0.005 | 0.005 | 0.038-0.039 | 0.039 |

So the offset is good to about 0.02 to 0.03 kpc. The 0.41 against 0.45 seen in #486 is not noise:
`measure.measure` counts from the brightest pixel, the nucleus, and reads 0.40 to 0.41 at every width;
counted from the nucleus the far line is at 0.41 here too. The depth is not constant: 0.01
over the core (|x| < 1), 0.03 at 2, 0.04 at 3, 0.055 at 4, 0.07 at 5 to 6 kpc.

**What it says about the ring.** Hubble's nucleus is 0.04 kpc under `CORE`'s row (peak of the light,
and the light's symmetry along the minor axis beyond the lanes: 0.05 to 0.07). About the nucleus the
far line follows a circle of 5.5 kpc (rms 0.05 kpc over the columns) and the near lane's inner edge one
of 5.9 kpc: the far line is the mirror of the near lane's inner edge within 0.04 kpc in projection, not
of the lane's body (0.69). The ring is centred on the nucleus within the noise, with a dense, thin inner
rim: 0.09 kpc of projected width leaves at most about 0.04 kpc of height (sigma) or 0.9 kpc of radius to
that rim. Counted from `CORE`, as the bench counts, the pair looks 0.08 kpc lopsided.

**Centring on the nucleus.** Hubble's nucleus is 0.108 kpc along the disk (to the right) and 0.041 kpc
under `CORE` (peak of the light laid flat, smoothed 4 to 37 pc: 0.106 to 0.110 and -0.040 to -0.041; the
bulge's mirror symmetry 1.2 to 2.2 kpc out gives 0.08 and -0.04). The bench light's peak and symmetry
sit on `CORE` (0.00, 0.00 to 0.01). At 6 degrees, 0.04 kpc on the sky is 0.38 kpc of radius, so a ring
fitted on a bench centred on `CORE` takes radii 0.4 kpc too large. `centre=nucleus` moves the light frame
by `NUCLEUS` (sub-pixel) and projects the ring about the same point; `centre=core` (default) renders to
the byte as before. With it, the lanes' rows move 0.04 kpc down and their fitted radii do not (p6 by
depth: near inner edge 0.62 to 0.66 under `CORE`, rings 6.64 and 6.62 kpc). P6 + taper with `inner=0.6`
puts its far line on Hubble's (0.44 against 0.45) but its near inner edge at 0.50 against Hubble's 0.56:
a mirror-symmetric ring cannot land both; Hubble's near edge lies 0.4 kpc further out than its far line
(`centre-nucleus-rows.jpg` in the bench's output of #495).

For the explorers: `share=depth centre=nucleus`, measured at 3072 and 6144 against the far figures
(`loin h`, `loin l`, `loin creux`) as well as the near ones, `n=24000000` for layers under 0.01 kpc.

**The light's shares.** With `share=split` the near half dims `behind` 0.95 of the light and the far
half `behind_far` 0.18, cut at the row of the core: at the tips the share steps from 0.95 to 0.18 across
the axis, and the lane ends in a wedge with a straight top. Over the core a far half that is dense
anywhere comes out as an even grey slab (p6 with `taper=2`: 0.07 deep at every column, 0.44 wide).
`share=depth` gives each grain the share of light behind it along its line of sight in a 3D model of the
light (`light_model.py`, fitted with `light_model.py fit` to the bench light's energy, i.e. the display
undone through the v6 look's curve, stretch 1.1 and white point 13): an oblate Sersic bulge (re 2.42
kpc, n 2.81, q 0.70) and a disk of free radial profile (knots every kpc) and sech^2 height 0.16 kpc;
relative rms 0.12, the model up to 30 % low on the minor axis between 0.5 and 1.5 kpc. A pixel's share
is its grains' column-weighted mean per half; the two layers are composited in depth order. The shares
on the ring run from 0.97 to 1.0 (near) and 0.0 to 0.03 (far) over the core to about 0.6 / 0.4 at the
tangent points (`light-model-fit.jpg`), with no step.

| prototype 6 at 3072 | near left | width | r/g | rim solid | far offset | far width | far depth | far depth at x 0 / 2 / 4 / 6 |
|---|---|---|---|---|---|---|---|---|
| Hubble | 0.46 | 0.29 | 1.28 | 0.81 | 0.45 | 0.09 | 0.039 | 0.009 / 0.028 / 0.055 / 0.068 |
| p6, split | 0.45 | 0.25 | 1.41 | 0.93 | 0.79 | 0.31 | 0.095 | 0.081 / 0.088 / 0.095 / 0.118 |
| p6, depth | 0.46 | 0.23 | 1.39 | 0.81 | 0.64 | 0.42 | 0.050 | 0.006 / 0.022 / 0.049 / 0.103 |
| p6 + taper, split | 0.49 | 0.27 | 1.35 | 0.64 | 0.51 | 0.44 | 0.071 | 0.072 / 0.070 / 0.051 / 0.100 |
| p6 + taper, depth | 0.72 | 0.26 | 1.18 | 0.10 | 0.42 | 0.17 | 0.056 | 0.009 / 0.042 / 0.066 / 0.104 |

(p6 + taper: `rise=0.05 floor=1 inward=1 taper=2 wobble=0.4`.) The depth shares give the far lane
Hubble's shape, faint over the core and deeper outward, and p6's near lane does not move (rim solid
0.93 to 0.81, Hubble's). A ring densest at its inner cut loses its near lane at the outer columns: its
dense dust there is at the inner rim's tangent point, beside the bulge, with half the light in front.
Hubble's near lane at x 5 to 6 kpc lies 0.65 to 0.72 under the core's row on the right (0.35 to 0.5 on
the left, the soft end), the ring at 8 to 8.5 kpc, in front of most of the light: the ring needs both a dense inner rim (the far line) and dense dust out to
the rim (the near lane at the ends). At the tips the depth shares draw the far half as a soft veil over
the near lane, a lens where `split` draws a wedge; Hubble shows less there, mottled dust under bright
blue-white light, the young stars `clean_light` removes and the model leaves out, part of them in front.

`share=split` stays the default, so older parameter files render to the byte; `share=depth` is the one
to explore with. `stretch=1.1` composites in the renderer's energy instead of the display light made
linear: every lane comes out shallower (p6: near left 0.53 split, 0.57 depth) and the curve alone already
fades the far lane over the bulge; it needs `k` calibrated on a Sillage render first. Scattered light is
left out: it fills the near lane a little (folded into `k` and `mass`, fitted on Hubble), and a far
half lit from our side scatters little back toward us; the shares alone give the far lane's depth.

What the bench's far lane can be trusted for: its height and width (pure geometry) and the shape of its
depth along the disk; its depth over the core only to a factor of about two (the light model, the
display-linear compositing); not at the tips beyond 5 kpc, where the young stars and the far half's
density decide. Not verified: the v6 grains with `share=depth` against the v6 render (the grains are not
on the Mac), and any Swift or GPU render.

Sheets: `closeup.py OUT.jpg frames...` now adds a fourth row, the far half over the core, and writes
`OUT-far.jpg`: the far half left, centre and right, each frame plain and enhanced. `dust_bench.py` prints
`loin h`, `loin l` and `loin creux` (the far lane's offset, width and depth) beside the near figures.

### The colour law (#499): `colour_law.py`, `law=hubble`

The bench's one reddening law cannot give Hubble's colours because Hubble's dust has two kinds of colour,
not one law that flattens with depth. `colour_law.py measure OUT` reads A_r and A_b against A_g on the
cleaned 6144 grid (texture.py's estimator, maps smoothed 1.5 px, pixels binned by A_g; curves and fits in
`colour-law.json`). Sheets for Pierre: `~/claude-workspace/sombrero/banc/499/` (`colour-law-ratio-map.png`,
`colour-law-curves.png`, `colour-law-tests.png`, `closeup-colour.jpg`).

**Two zones.** `d` is the distance below the lane's upper edge (the highest row where A_g passes 0.6). The
**dense band** is d < 0.10 kpc (the thin skirt over the edge included), the **orange zone** 0.15 to 0.45.
Centre, ratio of medians (scatter: spread of the 10 windows' own medians, then pixel IQR):

| A_g | band A_r/A_g | band A_b/A_g | orange A_r/A_g | orange A_b/A_g | tips: band | tips: orange |
|---|---|---|---|---|---|---|
| 0.6-0.8 | 0.72 | 1.09 | 0.42 | 1.70 | 0.75 / 1.11 | 0.47 / 1.52 |
| 1.0-1.2 | 0.79 | 1.03 | 0.44 | 1.64 | 0.74 / 1.15 | 0.57 / 1.41 |
| 1.8-2.0 | 0.93 | 0.98 | 0.63 | 1.33 | 0.94 / 1.02 | 0.74 / 1.18 |
| 2.25-2.5 | 0.96 | 0.99 | 0.72 | 1.20 | | 0.83 / 1.13 (A_g 2.3) |

Windows' sd 0.02 to 0.08 in the orange zone and 0.04 to 0.13 in the band (more at the tips); pixel IQR
0.07 to 0.19. Binning on A_r or A_b instead of A_g moves a ratio by at most 0.02 (0.1 in the thinnest
band bin). The band is grey (A_b/A_g 1.0, A_r/A_g 0.7 rising to 0.95) from A_g 0.4 on; the orange zone
reddens (0.42 : 1 : 1.7 in thin dust) and flattens towards grey as it thickens. Hubble's global
"1.8-2.1, 1.55 in the thickest dust" is the two mixed: the bar's bins hold both zones.

**The band is not a depth.** At the same column (A_g 1.3 to 2.0, centre) A_b/A_g is 1.0 for the pixels
under the edge and 1.5 beyond d = 0.15, with A_g unchanged (`colour-law-tests.png`, left). Any law of
the column alone paints the band orange or the orange zone grey. 0.10 kpc under the edge is about 1 kpc of
radius at 6 degrees: this is the ring's inner rim, the dense thin one of #495.

**What the floor explains.** A share b of the light behind the dust makes ratios flatten with a fixed
law: A_c <= -ln(1-b). With the light model's b (`share=depth`; mean floor 1-b: orange 0.03 centre and 0.11
tips, band 0.09 and 0.24) a fixed law (r : g : b = 0.58 : 1 : 1.56 orange, 0.84 : 1 : 1.03 band) fits
both regions to 0.10 nat rms. The orange zone's thin-dust law (A_g under 0.7) laid back over the whole
range misses by 0.38 nat rms at the centre and 0.46 at the tips with no floor, 0.20 and 0.16 with the
model's floor: the floor takes about half of the flattening. Floors fitted free are 0.06 (centre) and
0.09 (tips) in the orange zone and 0.11 and 0.14 in the band, against the model's 0.03 and 0.11, 0.09
and 0.24: close in the orange zone, too low at the centre and too high at the tips in the band. The rest
needs the law itself to grey with the column: the orange zone's A_r/A_g stays 0.43 up to A_g 1.1
then rises to 0.72, which no floor gives. Shared floors alone leave the band's colour untouched.

**What makes the band grey-blue.**
- *A flatter law in thick dust:* holds inside each zone (above), but cannot make the band: see the same
  column. Nor is the band grey only where thick: it is grey from A_g 0.4.
- *Scattered light:* not supported. Light scattered to us is added and bluer than the lane's light, so
  the deepest pixels (A_g >= 2) would let through more blue than green. They let through 0.129, 0.116,
  0.118 (r, g, b) in the band against a neutral light (I0 b/g 0.98, r/g 1.03), a floor of unreddened light
  at 12 %; in the orange zone 0.214, 0.112, 0.065, no floor at all (`colour-law-tests.png`, middle). A blue
  floor would be 1.3 to 1.5 times green's; at most a few per cent of the band's floor can be blue.
- *Young stars and clusters:* not the cause. The band's ratio curves with the 4816 point sources removed
  and kept are the same to 0.02 (`colour-law-tests.png`, right): the medians do not see them. Their blue
  dots show in the raw crop, 18 % of the band's pixels change by more than 0.1 nat in A_b, and no
  median ratio moves.
So the band is neutral, not blue: its display colour is about (86, 79, 82) against Hubble's orange
(130, 82, 64), and it reads blue-grey beside orange. The data support grey dust (large grains, or opaque
clumps with gaps, which the pixel cannot tell apart) in the inner rim, plus a neutral floor of light
that avoids the dust (about 12 %, of which the model's b gives 9 % at the centre and 24 % at the tips).
No additive term is needed.

**The option.** `law=hubble` (default `old`, every old file renders to the byte, checked at 1536 px with
`share=split` and `share=depth`). Per pixel, from the dust column N, its share q in the inner rim (a second
column map, grains within `rim_w` x 0.7 to 1.4 kpc of the inner cut, the radius split foreshortened to
0.1 kpc) and the light's share b: tau_g = k N (1 + redden 0.22) (green's opacity of the old law, so
`k`, `mass` and `redden` keep their meaning), then for each zone the red and blue optical depths are
tau_g (1 + (a - 1) / (1 + tau_g / t)), a pixel mixing the two zones by q, and the transmission is
`leak` + (1 - leak) exp(-tau_c) behind the usual (1-b) + b. Numbers (`dif_*` the rest of the dust,
`rim_*` the inner rim; a is the thin-dust ratio to green, t where it greys):

| | a_r | a_b | t | fitted to |
|---|---|---|---|---|
| `dif`, curves | 0.30 | 1.83 | 3.2 | the measured curves behind the model floor (0.075 nat rms) |
| `rim`, curves | 0.21 | 1.17 | 0.47 | (0.086 nat rms) |
| `dif`, default | 0.19 | 1.95 | 3.5 | the 16 z of the `colour` bar, from the line above |
| `rim`, default | 0.20 | 1.68 | 0.37 | |

`rim_w` 1.1 (kpc, the radius where half the rim is left; set by eye on p6 + taper at 3072 px, where the
grey band comes out about 0.1 kpc thick under the edge, like Hubble's) and `leak` 0. The numbers are made for `share=depth`: behind
`share=split` and `behind` 0.95 the same law scores 4.97.

**Proof** (`colour_law.py proof OUT`: Hubble's cleaned map on the bench light at 6144 px, no blur, N solved
so green dims by exp(-A) as in `texture_proofs.lay`; blur 0.15 gives the same figures):

| round trip | summary | `colour` | others that moved |
|---|---|---|---|
| old law, `behind` 0.95 (#498) | 1.08 | 4.71 | |
| old law, light model's b | 1.06 | 4.34 | |
| `law=hubble` curves' numbers, light model's b | | 2.97 | |
| `law=hubble` default, `behind` 0.95 | 0.99 | 4.97 | |
| `law=hubble` default, light model's b | 1.00 | **1.72** | skewness 0.4 to 0.8, intermittency 0.4 to 1.0, entre échelles 0.6 to 0.9, symmetry 0.3 to 0.7; none above 1.3 |

The colour bar's own floor: Hubble's odd against even windows 0.60, left against right half 1.72, so
1.72 is at the left-right floor. It is a fit: the six numbers were refined on this bar's components
(centre and tips), so it is not held-out. The other bars move a little because the luminance holds the
three channels; the `colour` bar is the only one it was tuned for. Close-up, Hubble beside the round trip
and beside p6 + taper, old law and new: `closeup-colour.jpg`.

**p6 with the taper envelope** (`rise=0.05 floor=1 inward=1 taper=2 wobble=0.4 share=depth centre=nucleus
blur=0.15 n=24000000`, 6144 px, old law then `law=hubble`): summary 7.14 to 7.42, `colour` 5.72 to 5.99.
The bar does not follow, and should not yet: p6 + taper puts all its thick dust in the inner rim (the
bar's thickest bin comes out 0.23 against Hubble's 0.51, the thin bins 0.28 against 0.18), where Hubble
has as much thick dust in the orange zone. The ratios by zone do follow (A_g 1.4 to 2, centre, old law
then new then Hubble: band 0.70 / 1.23, 0.92 / 1.06, 0.89 / 1.00; orange 0.66 / 1.35, 0.58 / 1.38,
0.57 / 1.41). So `law=hubble` gives the right colour for a given dust, and the bar will come down with
the dust's depth distribution, not by changing the law. Other bars: phase 9.6 to 10.1, skewness 4.9
to 5.3, intermittency 6.4 to 6.8, blobs 4.6 to 5.2.

**For the explorers' finalists:** `law=hubble share=depth centre=nucleus` and nothing else changed (dust,
`k`, `mass` untouched); the inner rim is the grains within about 1 kpc of `inner` x `rim`, so a ring whose
dense dust sits elsewhere gets its grey band there.

Not verified: any renderer (Swift, GPU) or `--grains` frames; the rim as a radial class is the reading of
a 6-degree view (the foreshortened 0.1 kpc) and the explorers' rings may put their band at other radii;
`rim_w` was set on one render; the tips' bands (floor 0.24 in the model against 0.14 fitted) are the
weakest numbers; Hubble's colours are its published processing decoded with gamma 2.2, not calibrated
photometry.
