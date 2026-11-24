# Sombrero dust: the finalists from above, through time and at a grazing angle (#504)

Part of #485. The finalists of the three tracks (#489 A, #490 B, #491 C) were tuned at Hubble's angle, 6
degrees from edge on, at one instant. The film Pierre aims for (#478) opens from the zenith with time
flowing, freezes on Hubble's axis, then flies low over the dust and down into the disk. This note reads
each finalist there. It judges; it changes nothing in the rings.

Tool: `references/sombrero/tools/dust_views.py` (imports the bench and the tracks' generators, edits
none). Output, not in git: `~/claude-workspace/sombrero/banc/504/` (one folder a finalist, and the
sheets `<track>-above.jpg`, `-time.jpg`, `-time-hubble.jpg`, `-grazing.jpg`).

```bash
dust_views.py prepare c f1 references/sombrero/dust-tracks/c/f1.json   # also a, b; or a grain file:
dust_views.py prepare x f1 grains.f32 --bench f1.json [key=value] [--curve vc=350,vslope=0,spin=1]
dust_views.py run c f1 --rigid 20,40      # seven times: from above, frame at Hubble's angle, score
dust_views.py volume c f1                 # grazing view and vertical cut
dust_views.py reverse c f1                # reverse recipe and velocity dispersion
dust_views.py sheets c
```

A new track is one `prepare` per finalist: a grain file of 7 float32 a grain (x y z opacity vx vy vz,
kpc, velocities in Sillage's units as `dust_bench.py --grains` reads them) and the bench parameters.
Grains with no velocities turn on the flat 350 km/s curve (`--curve` to change it). `prepare` for tracks
A, B and C draws the grains exactly as the track's own render does (checked on C: the frame at t = 0 is
the track's own render within one display level; the bench's `myr` turns the grains as `run` does
within 3 micro-kpc).

## The readings

- **From above.** The column seen from the zenith at 10 pc a pixel, 20 kpc across, drawn three ways:
  dust over light (the light is `light_model.py`'s fitted emissivity integrated vertically: an
  axisymmetric bulge and smooth disk, no arms, no young stars, fitted on the edge-on frame, so only a
  rough stand-in; each grain dims the share of the light under it, about half for a mid-plane layer),
  the same divided by the dust-free light (transmission, 0.8 black to 1 white), and the optical depth
  k N linear 0 to 1 as `dust_bench.py --face-linear` draws it, plus a 4 kpc zoom on the near side.
- **Numbers from above**, in the ring (where the azimuthal mean of k N stays over 15 % of its peak):
  - structure tensor of log(1 + 10 k N) with the ring's envelope removed, at 50 pc and 200 pc:
    *coherence* (0 for round speckle, 1 for parallel streaks), *line of sight* (share of the oriented
    structure within 15 degrees of the sky's y axis, the line of sight laid on the plane; 0.17 for
    orientations at random), *trailing* (share of the oriented structure that trails the rotation),
    *>45 deg* (share steeper than 45 degrees of pitch: spokes, or noise when the coherence is low);
  - dark structures (k N minus its 0.3 kpc blur, over its 85th percentile, connected): length over
    width, median and 90th percentile, and length;
  - correlation lengths of the same high pass along the orbit and across it;
  - azimuthal profile of the ring's column: share of gaps (bins of 0.5 degree under a quarter of the
    median), m = 2 amplitude (an oval or two crescents).
- **Through time.** Each grain on its circular orbit: azimuth + Omega(R) t, Omega from its own velocity
  or the curve (track C: its stated curve, flat 350 km/s, f6 v ~ R^0.3; A and B carry no velocities: flat
  350 km/s, the sense of rotation C's). At t = -40, -20, -10, 0, +10, +20, +40 Myr: the view from above,
  the frame at Hubble's angle at 3072 px (`share=depth centre=nucleus blur=0.15 law=hubble`, as the
  finalists' commands) scored with `texture.py --grid 6144`, and the centre close-up. At 7 kpc a turn
  takes 123 Myr: 10 Myr is 29 degrees. *Holds*: the time span over which the summary stays within 0.5 of
  t = 0, the spread of track C's f1 over three seeds (3.18 to 3.67); under 0.3 is noise. A control turns
  the whole ring rigidly by the angle of 7 kpc (`--rigid`): the same dust passes through the view
  without being wound, so the gap between the two is the cost of the winding.
- **Volume.** At t = 0, an orthographic view 2.5 degrees above the plane looking along the ring's
  tangent at R 7.5 kpc on the near side (2 x 0.4 kpc, the grains of a slab 1 kpc deep, light behind), and
  a vertical cut (R 5 to 10.5 kpc against z, summed over 0.3 kpc of arc). For C and B the wedge round
  that point is drawn with six more realizations of the same field (other leaf seeds of the same clouds,
  other Sobol seeds of the same field), weights divided by seven: the same column, finer sand. A's
  stratified grains depend on its parameter seed only, so A keeps its own 48 M grains there. Numbers: the
  layer's rms and FWHM height against radius (all grains), the spread of the mid-plane's height in the
  cut, the height and radial size of the cut's dark clouds.
- **Reverse recipe.** The ring at -T unwound on the same orbits, then wound forwards by T, compared
  grain for grain; for C also through its own generator at -T (clump centres turned back, ages less T).
  Then the grains at -T get a random velocity sigma per component and are integrated forwards in the
  plane (flat curve, leapfrog, 0.25 Myr), with a harmonic displacement w / nu sin(nu T) in height
  (nu 0.1 per Myr, a vertical period of 63 Myr: an assumption, from a bulge-dominated potential at 7 kpc
  plus a disk of 0.1 to 0.3 solar masses per pc^3).

Scope: all 24 finalists from above at t = 0; through time, the rigid control and volume for C f1-f8, B f1,
f2, f4, f6, f8 (B f2 to f5 look alike at Hubble's angle) and A f1, f3, f4, f7 (A's eight look alike); the
reverse recipe on C f1, f2, f7. Grains: C and B 24 M, A 48 M with `strat=1`, A at seed 2 as its finalists.

## What all of them share

- **From the zenith the dust barely shows.** With `k` fitted at 6 degrees, the ring's median optical
  depth face on is 0.10 (A, C) and 0.02 (B), 0.25 and 0.6 at C's 90th and 99th percentiles, and a
  mid-plane layer can only dim the half of the light that lies under it: the dust over the model's light
  is a faint shadow (about 5 % at the median, up to about 30 % on C's inner rim). The second panel of `<track>-above.jpg` shows the same
  transmission stretched from 0.8 to 1 so the eye can read it. A zenith shot will need the dust drawn
  darker than this, or light under it that the bench's smooth, bulge-dominated model does not have (the
  disk's knots fall to 0.03 of the centre's by 7 kpc). This is the bench's light, not Sillage's.
- **Unwound, every ring leads.** None of the finalists carries a shear history that survives unwinding.
  The share of the oriented structure that trails the rotation, at 50 pc: C f1 0.04, 0.19, 0.53, 0.85,
  0.96, 0.98, 0.99 at -40 to +40 Myr; A f1 0.04, 0.13, 0.28, 0.51, 0.73, 0.88, 0.96; only C f6 (clouds
  sheared 0 to 80 Myr) stays trailing back to -20 (0.80) and is even at -40 (0.45). An opening that
  starts 20 Myr before the freeze shows clouds that lean the wrong way for a spiral and straighten as
  time runs; an astronomer would see it, Pierre may not.
- **The look one wants from above comes at the cost of the match.** Every finalist reads most like a
  spiral's dust at +40 Myr (coherence 0.65 to 0.79, 96 to 99 % trailing: fine combed feathers) and that
  is where its score at Hubble's angle is worst. Hubble's blotchy speckle needs young, nearly round
  clouds; fine spiral arms from above need clouds wound for 40 Myr or more (track C found the same from
  the other side: ages over 40 Myr score worse).
- **The winding costs, not the dust passing through the view.** The rigid control (the same angle, no
  winding) costs 0.1 to 0.7 at +-20 and +-40 on A and C; the winding 1 to 4 at +-40. Shapes tied to the
  view turn away with the ring: A's `off_y` and `m2` (denser towards the tips), C's `lop`, B's oval. On
  circular orbits they turn at Omega; a real oval or lopsided ring would precess at about Omega - kappa / 2
  (0.29 Omega on a flat curve), so this reading is harsh on them.
- **Reverse recipe.** Unwound by T and wound forwards by T on the same orbits, every grain lands on the
  tuned ring to 1e-10 pc (T 10, 20, 40). Through track C's own generator at -T (centres turned back,
  ages less T) the plane lands to 2e-11 pc, but the height does not where the layer is corrugated (f1,
  f2, f7: 28 pc rms, 133 pc at most): `corr` is a field fixed in space, so a film must carry each
  grain's height, not evaluate the generator again. 43 to 50 % of C's mass is younger than 10 Myr and 85
  to 100 % younger than 20: at -20 those clouds are not born yet in C's own story; unwound, they are
  sheared the other way (the leading streaks above).
- **Velocity dispersion erases the detail within the film's span.** Grains at -T given a random
  velocity per component, integrated to 0 (C f1, f2, f7, summary at the freeze, then the share of the
  power kept from above at 20-40 / 40-80 / 80-160 pc):

  | T, sigma | summary | power kept |
  |---|---|---|
  | 20 Myr, 0 (control) | 3.20 / 3.26 / 3.24 (tuned 3.19 / 3.26 / 3.23) | 1 / 1 / 1 |
  | 20 Myr, 2 km/s | 6.9 / 6.9 / 7.1 | 0.05-0.11 / 0.14 / 0.48 |
  | 20 Myr, 5 km/s | 9.6 / 9.9 / 9.9 | 0.04-0.09 / 0.02 / 0.08-0.09 |
  | 20 Myr, 10 km/s | 11.7 / 11.7 / 11.8 | 0.04-0.09 / 0.01-0.02 / 0.01 |
  | 10 Myr, 5 km/s | 9.1 / 9.4 / 9.2 | 0.04-0.10 / 0.08 / 0.35 |
  | 40 Myr, 5 km/s | 9.8 / 10.2 / 10.1 | 0.04-0.09 / 0.01-0.02 / 0.02-0.03 |

  sigma T is 41 pc for 2 km/s over 20 Myr, more than the clouds' median width from above (25 to 30 pc,
  length 50 to 60) and ten times the 3 to 8 pc cloudlets; in height w / nu sin(nu T) is 19 pc, half the
  layer. Keeping a 30 pc cloud sharp to 10 pc over 20 Myr needs under 0.5 km/s per grain. The dust layer
  of a Sillage take without sticky gas warmed from 0.02 to 0.077 kpc, about 7 km/s at this nu. So the
  opening cannot run the tuned dust as free N-body grains: it has to carry the ring kinematically
  (each grain on its circular orbit from the frozen field, as here) or as whole clouds whose inside is
  not dispersed. Cloud-to-cloud motions would shuffle clouds without blurring them; that is not modelled.

## Track C (clouds wound by differential rotation)

Summary at Hubble's angle (3072 frame, 6144 grid, `law=hubble`) through time, and the rigid control:

| | -40 | -20 | -10 | 0 | +10 | +20 | +40 | rigid -40 / -20 / +20 / +40 | holds |
|---|---|---|---|---|---|---|---|---|---|
| f1 | 5.25 | 3.81 | 3.46 | 3.19 | 3.35 | 3.66 | 4.88 | 3.90 / 3.58 / 3.32 / 3.33 | -10 to +20 |
| f2 | 4.45 | 3.83 | 3.51 | 3.26 | 3.60 | 3.56 | 5.14 | 3.86 / 3.48 / 3.38 / 3.34 | -10 to +20 |
| f3 | 5.30 | 4.05 | 3.79 | 3.50 | 3.94 | 4.45 | 7.17 | 3.98 / 3.69 / 3.71 / 3.75 | -10 to +10 |
| f4 | 4.52 | 3.86 | 3.88 | 3.61 | 3.95 | 4.45 | 7.32 | 4.02 / 3.81 / 3.77 / 3.85 | -20 to +10 |
| f5 | 4.34 | 3.98 | 3.75 | 3.66 | 4.38 | 5.35 | 8.22 | 3.96 / 3.76 / 3.78 / 4.02 | -20 to 0 |
| f6 | 4.23 | 4.01 | 4.08 | 3.83 | 4.39 | 4.79 | 5.89 | 4.05 / 3.83 / 3.91 / 4.02 | -40 to 0 |
| f7 | 4.20 | 3.67 | 3.45 | 3.23 | 3.50 | 3.53 | 4.04 | 3.80 / 3.95 / 3.51 / 3.31 | -20 to +20 |
| f8 | 4.50 | 3.79 | 3.61 | 3.19 | 3.40 | 3.87 | 4.21 | 3.87 / 3.48 / 3.53 / 3.45 | -10 to +10 |

- **What goes first.** Backwards, the depth distribution: histogram, profile and stationarity (f1 at
  -20: 3.9 to 5.1, 2.5 to 3.4, 3.3 to 4.3); the scalloped dense top edge goes smooth at -40. Forwards,
  the shape of the dark blobs: shape, blobs and spectrum along (f1 at +20: shape 1.5 to 3.1; at +40 the
  spectrum along 0.9 to 4.9, blobs 3.0 to 6.7): the knots become streaks along the lane.
- **From above** (`c-above.jpg`): a real round ring (no gaps, m2 0.01) with a dense knotted inner rim
  and a body of round knots (structures 1.7 to 2.3 long for wide, 50 to 60 pc), weakly oriented
  (coherence 0.37 to 0.53), trailing (80 to 95 %), with f1's old arcs as hair-thin lines; no spokes, no
  line-of-sight texture (0.17, random). It reads as the dust of a galaxy, cloudy rather than spiral:
  no fine arms at the freeze; f5 and f6 (older clouds) show short trailing feathers.
- **Volume** (`c-grazing.jpg`): clouds one would fly past. A wavy layer 38 to 43 pc rms at 7 kpc (FWHM
  80 to 96 pc), flaring to about 56 pc at 8.6 kpc, its mid-plane moving 17 to 35 pc; the cut's dark
  clouds are 14 to 35 pc high for 27 to 52 pc in radius, 0.3 to 0.5 height for radial length (from above
  they are 50 to 60 pc long). f3 and f4's sharp cloudlets show as round puffs; f1's arcs as streaks.

## Track B (Hubble's statistics on a thin-layer ring)

| | -40 | -20 | -10 | 0 | +10 | +20 | +40 | rigid -40 / -20 / +20 / +40 | holds |
|---|---|---|---|---|---|---|---|---|---|
| f1 | 10.94 | 7.47 | 3.64 | 2.10 | 3.63 | 8.19 | 10.08 | 11.15 / 10.82 / 13.01 / 11.79 | 0 |
| f2 | 11.49 | 10.62 | 3.51 | 2.01 | 3.83 | 7.77 | 11.02 | 12.35 / 12.05 / 12.38 / 12.32 | 0 |
| f4 | 11.47 | 9.61 | 3.55 | 2.01 | 3.82 | 7.88 | 10.92 | 12.35 / 12.11 / 12.03 / 12.27 | 0 |
| f6 | 9.49 | 6.08 | 3.85 | 2.53 | 3.86 | 6.04 | 9.23 | 11.40 / 11.60 / 11.73 / 11.82 | 0 |
| f8 | 11.07 | 7.62 | 3.56 | 2.17 | 3.83 | 8.40 | 10.37 | 11.62 / 11.21 / 11.28 / 12.87 | 0 |

f3, f5, f7 from above only (2.02, 2.02, 2.12 at the freeze).

- **The match holds for no time.** +-10 Myr costs 1.1 to 1.8 (shape 1.7 to 4.4-4.8, spectrum along,
  intermittency); +-20 costs 4 to 8; turned rigidly by 20 Myr's angle, with no winding at all, every B
  finalist scores 11 to 13. The texture belongs to the 6-degree view, not to the ring.
- **From above it is not a ring of dust.** 82 to 94 % of the oriented structure lies within 15 degrees of
  our line of sight at every azimuth (0.17 for any texture of the plane), coherence 0.67 to 0.82: streaks
  parallel to the line of sight, the across-lane speckle laid out in radius at the near side and in
  azimuth at the tips. f1 to f5, f7 and f8 are two crescents meeting in pinched tips (m2 0.43 to 0.46,
  8 to 10 % of the azimuth empty); f6 is round (m2 0.04, no gaps) with the same streaks. Through time the
  crescents turn with the ring and the streaks shear into combed bars (`b-time.jpg`).
- **Volume: a flat sheet.** 2 to 3 pc rms, 8 pc FWHM, no corrugation; at a grazing angle a single dark
  line (`b-grazing.jpg`); the cut's "clouds" are 9 to 12 pc high and 0.2 to 1.5 kpc long.

## Track A (a ring built from parts)

| | -40 | -20 | -10 | 0 | +10 | +20 | +40 | rigid -40 / -20 / +20 / +40 | holds |
|---|---|---|---|---|---|---|---|---|---|
| f1 | 5.43 | 2.80 | 2.33 | 2.13 | 2.40 | 2.82 | 4.85 | 2.53 / 2.37 / 2.71 / 3.13 | -10 to +10 |
| f3 | 4.26 | 2.40 | 2.53 | 2.32 | 2.43 | 2.54 | 4.52 | 2.49 / 2.38 / 2.40 / 2.75 | -20 to +20 |
| f4 | 3.88 | 2.49 | 2.31 | 2.05 | 2.72 | 2.43 | 4.09 | 2.45 / 2.36 / 2.33 / 2.56 | -20 to 0 (+20 2.43) |
| f7 | 4.93 | 3.04 | 2.44 | 2.35 | 2.35 | 3.01 | 5.31 | 2.46 / 2.37 / 2.21 / 2.83 | -10 to +10 |

f2, f5, f6, f8 from above only (2.15, 2.41, 2.21, 2.03 at the freeze).

- **The match holds 10 to 20 Myr each way and stays near the pass line**: at +-10 Myr 2.31 to 2.72, at
  +-20 2.40 to 3.04. What goes first: shape (f1 1.9 to 3.6 at -20, 3.4 at +20), then blobs and the
  spectrum along at +40 (shape 6.6, blobs 5.5): the speckle elements, 50 by 12 pc, are wound into
  streaks. f7's oval turns away from the view (symmetry 0.4 to 3.4 at -20).
- **From above** (`a-above.jpg`): a real round ring (no gaps; m2 0.11, the density `m2` puts towards the
  tips; f7 oval 0.07), evenly grained, with faint broad trailing bands (the orbit modulation). No
  spokes, no line-of-sight texture (0.14 to 0.18). Up close it is a fine even sand of speckle with a few
  dark dots, not clouds: coherence 0.33 to 0.37, no preferred sense (48 to 51 % trailing), correlation
  53 by 40 pc. The inner edge is a sawtooth of small teeth; f4 and f8 draw straight-edged polygons (the
  cell walls), f1, f2 and f5 to f8 the polyline filaments as faint straight hairs.
- **Volume** (`a-grazing.jpg`): clouds, puffier than C's mottling but with layered strata: 35 to 39 pc rms
  at 7 kpc (FWHM 56 to 90 pc), mid-plane moving 11 to 13 pc, cut clouds 22 to 24 pc high for 35 to 45 pc
  in radius. The strata of the `sheets` (4 layers 20 pc apart) show as horizontal bands in the cut.

## Verdict

| finalist | from above: a spiral's dust | match holds (Myr) | volume | what is wrong |
|---|---|---|---|---|
| A f1 | partly | -10 to +10 | clouds | even sand, no clouds or arms from above; sawtooth inner edge |
| A f2 | partly | (not run) | (not run) | as f1 |
| A f3 | partly | -20 to +20 | clouds | as f1; the steadiest score through time |
| A f4 | partly | -20 to 0 | clouds | straight-edged polygons from above (cell walls) |
| A f5 | partly | (not run) | (not run) | as f1, one layer |
| A f6 | partly | (not run) | (not run) | as f1 |
| A f7 | partly | -10 to +10 | clouds | its oval turns away from the view |
| A f8 | partly | (not run) | (not run) | polygons, as f4 |
| B f1 | no | 0 | flat | two crescents; streaks along our line of sight |
| B f2 | no | 0 | flat | as f1 |
| B f3 | no | (not run) | (not run) | as f1 |
| B f4 | no | 0 | flat | as f1 |
| B f5 | no | (not run) | (not run) | as f1 |
| B f6 | no | 0 | flat | round, but the same line-of-sight streaks |
| B f7 | no | (not run) | (not run) | as f1 |
| B f8 | no | 0 | flat | as f1 |
| C f1 | partly | -10 to +20 | clouds | round knots, no fine arms; 3.2 at the freeze |
| C f2 | partly | -10 to +20 | clouds | as f1 |
| C f3 | partly | -10 to +10 | clouds | as f1, 3.5 |
| C f4 | partly | -20 to +10 | clouds | as f1, 3.6 |
| C f5 | partly | -20 to 0 | clouds | short trailing feathers; 3.7, falls fast forwards |
| C f6 | partly, the most spiral-like | -40 to 0 | clouds | trails at every time; worst match of C (3.8) |
| C f7 | partly | -20 to +20 | clouds | as f1; the steadiest of C |
| C f8 | partly | -10 to +10 | clouds | stray dark dashes from above |

"Holds": within 0.5 of the freeze's summary. None reads "yes" from above: none has the many fine arms
of the film's opening at the freeze.

**Ranking for the film** (different from the ranking at Hubble's angle, where B leads):

1. **A f3**, then A f1: a real ring, the best match at the freeze (2.1 to 2.3) that stays within 0.5
   for 10 to 20 Myr each way, and a cloudy layer to fly over. What it lacks is the look from above:
   an even sand, no clouds, no arms. A f4 and f8 score as well but their polygons show from above.
2. **C f7**, then C f1 and f2: a real ring of clouds from above and in the flight, holding 10 to 20 Myr,
   but 3.2 at the freeze, far from the pass line, and leaning the wrong way before -10 Myr.
3. **C f6** if the opening must look like a spiral from above while time runs: it trails at every time
   and holds 40 Myr backwards, but it is the worst of C at the freeze (3.8).
4. **B, none**: its texture exists only at 6 degrees; it is a flat sheet; it does not hold for 10 Myr.

For the opening shot, only t <= 0 matters (time runs to the freeze); the +T side matters for the last
shot only. No finalist gives the three at once: A gives the match and the flight, C the clouds from above,
C f6 the spiral sense. The way through the tension is the reader's call; the numbers say the fine arms
from above and Hubble's young blotches need dust of two ages, which only C f1 tried (15 % old arcs) and
which shows as hair-thin lines, not arms.

## Not verified

- The light from above is the bench's model (no arms, no young stars, no thin bright disk), not
  Sillage's; the transmission panel shows the dust alone.
- Circular orbits only. Eccentric or oval rings (A's `off_y`, `m2`, `oval`; C's `lop`; B's crescents)
  would precess slower than they turn here.
- The dispersion test is in the plane on the flat curve with an assumed vertical frequency (nu 0.1 per
  Myr); cloud-to-cloud motions (whole clouds moving) are not modelled, only per-grain ones.
- Volume views are orthographic at one place (R 7.5 kpc, near side); a perspective flight was not drawn.
- A's volume has no extra realizations (its stratified grains depend on the parameter seed only): sand
  shows a little more there.
- Scores at 3072 px on the 6144 grid, one seed a finalist; the "holds" threshold is the seed spread of
  one C finalist.
