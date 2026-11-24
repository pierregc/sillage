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
that rim. Counted from `CORE`, as the bench counts, the pair looks 0.08 kpc lopsided; the bench centres
its ring on `CORE`, 0.04 kpc above Hubble's, which no figure corrects yet.

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
