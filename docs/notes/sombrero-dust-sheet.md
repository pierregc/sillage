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
