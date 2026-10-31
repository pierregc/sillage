# Why settled arms stay lumpy and wobbly (spike #171)

The question: once a disk has settled, why do its arms stay lumpy and deformed and the galaxy
keep wobbling, and which levers make it calmer while still looking real. Measured with the
calm-disk probe (`calm-disk-probe.md`) on the first galaxy of library `2026-10-30-b/scene-0031`
(Première: scale length 5.55 kpc, clumpiness 0.25, Q 1.33, two painted arms of contrast 0.96 at
pitch 15 degrees, irregularity 0.55, dissipation 306 Myr, disk mass fraction 0.22, halo scale
radius 1.65 scale lengths) for every lever alone, on the second galaxy for the main ones, at
the explore count (108 000 stars, 270 000 particles with the halo) for 1 Gyr, 253 frames each,
and judged against what Hubble and Webb show of real spirals. The runs are in
`library/2026-10-30-b/scene-0031/probe/`, one folder each, and `scripts/probe-report.py table`
lays them side by side. Every amplitude below is in the probe's convention, half the sinusoid's.

## What a real spiral looks like at this scale

Gathered from the literature and ten reference frames (NGC 1300, M51, M74, M101, NGC 5468
from Hubble; NGC 628, M51, M100, NGC 1566 from Webb; M74 from Spitzer), at the 31 pc per pixel
of a 960 px frame holding 30 kpc:

- The old stars, which are what the simulator's particles are, carry broad, soft, low-contrast
  arms: an arm to interarm ratio of 2 to 3 at most, an m = 2 amplitude of 0.15 to 0.3 for a
  grand design and 0.1 for an isolated two-armed spiral (Elmegreen et al. 2011; Kendall et al.
  2015), and no knots at all. All the knots, holes and ragged edges belong to the young
  tracers, which are a small share of the light and a tiny share of the mass.
- Two dominant arms inside about two scale lengths, continuous over at least half a turn; past
  that, three to five unequal segments that branch off the convex side. Never four or five
  arms of equal spacing and contrast.
- Knots of 100 to 300 pc, no larger than a fifth of the arm width, a handful of giants of
  500 to 1000 pc in the whole galaxy, strung along arm fragments and never floating alone.
- The outskirts are lopsided (an m = 1 of 0.06 to 0.1 beyond two scale lengths in this
  convention, growing outward), but the pattern is centred on the bulge to a few pixels. A
  camera that follows the bulge sees a still galaxy with breathing outskirts; a camera that
  follows the light centroid sees the whole thing wobble.

## What the particles do

**The baseline, in numbers.** Première alone, at the explore count, two samplings:

| Myr | a2 mid | a1 mid | sigma_R / v_c mid | lump stars | coh pattern / material | omega_p / omega(2h) |
| --- | --- | --- | --- | --- | --- | --- |
| 0 | 0.36 | 0.21 | 0.135 | 0.23 | | |
| 100 | 0.53 | 0.20 | 0.18 | 0.10 | 0.25 / 0.36 | 0.9 |
| 400 | 0.55 | 0.38 | 0.24 | 1.0 | 0.28 / 0.38 | 0.9 |
| 700 | 0.50 | 0.39 | 0.17 | 1.0 | 0.0 / 0.24 | 0.9 |
| 1000 | 0.46 (seed 2: 0.29) | 0.41 (0.19) | 0.16 | 0.8 | 0.16 / 0.31 | 0.9 |

The painted two-armed pattern sharpens over the first 100 Myr, turns into a bar with two
arms attached by 300 to 400 Myr (a2 in the inner zone 0.26 to 0.37, one rigid pattern: the
spread of the rings' rates is 0.005 rad/Myr), and the disk comes out of its first gigayear
barred, lopsided, 30 % smaller (median radius 8.5 to 6.0 kpc) with a dislocated outer disk.
Two samplings agree on the first 300 Myr to within a percent on the radii and 0.03 on the
amplitudes, and diverge after the bar forms (a2 at 1 Gyr 0.46 against 0.29): that is the
chaotic spread, and everything compared below is compared against it.

**The seeded clumps evaporate in fifteen megayears and heat nothing.** The sampler places a
share of the stars in clumps but gives every star the disk's own velocity dispersion, forty
kilometres a second, so a clump a hundred parsecs across is gone in a few megayears. Measured
on the stars' lumpiness (structure below a fifth of a scale length): at clumpiness 0.44 it
reads 0.38 at t = 0, 0.21 at 8 Myr and 0.13 at 16; the baseline's 0.23 is 0.08 by 16 Myr; the
young population's 0.55 is 0.15 by 16 Myr whatever the clumpiness. The start reads
`lump_stars` = 0.06 + 0.72 x clumpiness over the whole sweep, so the knob does what it says on
the first frame and nothing after. The late lumpiness is 0.5 to 1.0 for every clumpiness,
self-made structure (bar, fragments, sharpened arms), and the heating does not follow the knob
either:

| clumpiness | 0 | 0.06 | 0.12 | 0.18 | 0.25 (base) | 0.35 | 0.44 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| sigma_R / v_c at 300 Myr | 0.21 | 0.17 | 0.18 | 0.19 | 0.21 | 0.18 | 0.20 |
| a2 mid late | 0.36 | 0.26 | 0.27 | 0.27 | 0.49 (0.24) | 0.20 | 0.30 |
| first excursion | 12.4 % | 14.0 % | 14.6 % | 13.3 % | 15.1 % | 16.1 % | 16.5 % |

`disk-heating.md` read the clumps as the heater (0.156, 0.185, 0.309 at clumpiness 0, 0.12 and
0.30 at 300 Myr). That run had the arms painted at the default contrast too, and the three
figures sit inside the chaotic spread of what is measured here with the arms on; what the
clumps do cost is on the first frame, where a flocculent speckle reads as graininess.

**The painted contrast is what heats and deforms the disk.** With the arms left out of the
particles (`arms-0.0`) the same disk stays at sigma_R / v_c 0.12 to 0.14 for 400 Myr against
0.24 with them, its median radius drops 10 % over the gigayear instead of 30 %, and it grows
its own structure: a flocculent pattern of three to five arms by 300 to 500 Myr, a2 0.17 at
400 Myr and 0.23 at 1 Gyr, a1 0.06 at the start and 0.19 late, no bar. The painted contrast
is 0.96, an m = 2 amplitude of 0.36 in the middle zone and 0.5 in the outer one, two to four
times what any old stellar disk carries; given no velocity field to hold it, the disk answers
by winding it up, scattering off it and contracting. At contrast 0.6 the heating at 300 Myr
is 0.18 and the excursion 10.7 %; at 0.8, 0.19 and 14.4 %. The density wave the viewer sees
at the start is paid for over the next 300 Myr.

**The disk prefers three to four arms, and the particles turn their pattern twice as fast as
the paint.** Toomre's swing-amplification parameter for two arms is 2.75, 3.65 and 5.3 at one,
two and three scale lengths (the probe's `facts`), so two arms are only marginally amplified
and the disk's own preference at two scale lengths is 3.6 arms; what it makes on its own with
no paint is exactly that. The pattern the particles carry turns at 0.025 to 0.029 rad/Myr, 0.8
to 1.0 times the material's own rate at two scale lengths, with its corotation at 2.1 to 2.3
scale lengths, where real spirals have theirs; the renderer paints the wave at 0.012 rad/Myr
(half the analytic rate, corotation at 4.3 scale lengths, inner Lindblad resonance at 1.0).
Paint and matter therefore turn against each other at a quarter turn per 100 Myr, and the
"deformed" look of a settled disk is two patterns beating. What the particles hold once the
painted wave has gone is not arms at all: within 60 to 160 Myr the spectrum is flat from m = 1
to m = 8 at 0.2 to 0.5, the signature of compact knots, and it scales with the cooling, which
pulls the thin-disk stars themselves towards circular orbits (late lumpiness 0.05 with no
dissipation, 0.38 at 600 Myr, 1.0 at the default 306, and fragmentation at 150). Three or four painted arms (`m3`,
`m4`) peak lower (a2 0.40 and 0.37) and end as many-armed disks of a2 0.23, no calmer. A
heavier disk (`dmf-0.30`, `dmf-0.40`) starts hotter by construction (0.17 and 0.21), bars
harder (a2 in the inner zone 0.51 to 0.54 for 0.40) and breathes more (18 and 23 %).

**Particle number changes none of it.** From 54 000 to 1 078 000 stars (the hires count for
this scene) the heating at 300 Myr reads 0.185, 0.213, 0.233, 0.213 and 0.224, the late a2
0.24, 0.49 (0.24 with the other seed), 0.23, 0.22 and 0.33, the late a1 0.22, 0.38, 0.23, 0.18
and 0.31, the late lumpiness 0.76, 1.0, 0.76, 0.90 and 1.16, the first excursion 18, 15, 13, 15
and 13 %; Deuxième from 46 000 to 921 000 reads 0.137, 0.150, 0.137 and 0.162 at 300 Myr and
8, 9, 11 and 11 %. What varies between counts is within the seed spread. The structure is the
initial conditions' physics, not shot noise, and explore shows what hires shows: the knots
formed scale with the count (1 185 in 300 Myr at 108 000 stars, 32 000 at a million) and the
floor under the amplitudes falls with it, nothing else moves.

**A hotter disk is calmer, and the cooling decides what is left.** Toomre Q 2.0 starts at
0.20, cools to 0.14 under the dissipation and ends with a soft two-armed pattern of a2 0.15,
lumpiness 0.13, the calmest run of the sweep and the one judged closest to a real old disk;
1.25 bars at a2 0.41 with lumpiness 1.3. Without dissipation the disk stays at 0.20 and goes
featureless (a2 0.12, lumpiness 0.05, the old "cooked" disk); at 150 Myr it fragments into
clumps massive enough to carry the measured nucleus 20 kpc off (not a lever); at 600 Myr it
keeps a2 0.24 with lumpiness 0.38, between the two.

**The sampler paints a lopsided disk on purpose, and the lopsidedness grows.** The pattern's
`lopsided` term (0.30 x irregularity on the ridge, `SpiralPattern.ridge`) puts a1 = 0.21 in
the middle zone at t = 0 at the default irregularity 0.55, 0.15 at 0.3, 0.05 at 0 and 0.10 on
the second galaxy (irregularity 0.39): two to four times the 0.06 real inner disks show. It
grows to 0.16 to 0.38 by 400 Myr in every run, with or without the term (the bar and the
sloshing of a disk whose centre of mass started off its halo's), and the term alone is worth
7 points of the first radial excursion (8.3 % at irregularity 0 against 15.1 %).

**The wobble is in the framing as much as in the disk.** The nucleus, the centre of mass of
the disk material inside one and a half scale lengths, moves by 0.06 to 0.10 kpc between
frames 4 Myr apart, 15 to 25 km/s of real sloshing of a disk about its halo, the m = 1 motion
the literature expects at a few hundred parsecs and a rotation period. The centre the app's
camera follows (`updateHaloCenters`: the centre of mass of every visible particle, outskirts
and thrown-off material included) sits 0.3 to 1.1 kpc from that nucleus late in the baselines of both galaxies,
3 to 5 kpc in a third of the runs (clumpiness 0.12, 0.35 and 0.44, disk mass fraction 0.40,
431 000 stars), and drifts at 0.02 to 0.04 kpc a frame. On Première it grows with the count,
0.45, 0.91, 2.1, 4.3 and 5.6 kpc late from 54 000 to a million stars, because the centre of
mass follows the stars thrown past six scale lengths and more particles reach there. The
motion of either centre from frame to frame is smooth, 10 to 25 km/s with periods of 100 to
450 Myr, not a shimmer: nothing to filter, only the wrong point to follow. In the two-pane clips the galaxy sits still in its own frame while
the app's framing slides a few hundred pixels over 500 Myr. The outer zone's centroid sits
0.3 to 1.3 scale lengths from the nucleus: the outskirts are lopsided, as real ones are, and a
camera on the nucleus is what makes that read as natural.

**A steady spiral drive does nothing at the strengths the literature uses.** The prototype
(commit eb2ece9 on `spike/167-prototypes`): one harmonic of the Cox & Gómez 2002 potential in
each disk's measured frame, turning at the painted pattern speed, phased on the sampled ridge
at t = 0, 0.5 to 4 % of the axisymmetric radial force at two scale lengths, ramped over
400 Myr (100 in one run), between the inner Lindblad resonance and the corotation of that
speed. Nothing moved outside the seed spread: first excursion 13.6 to 14.9 %, heating 0.21 at
300 Myr, a bar at 400 Myr (a2 in the inner zone 0.33 to 0.35), coherence in the pattern frame
0.04 to 0.17, the particles' pattern still at 0.87 to 0.93 of the material's rate against the
painted 0.42. On a smooth start the disk grew its own flocculent pattern exactly as without
the drive (a2 0.21 late, coherence 0.07), and on a calm start (contrast 0.3, clumpiness 0.12)
likewise. The disk's own swing-amplified modes, corotating at 2.1 to 2.3 scale lengths, win
against a few per cent of forcing at a speed whose resonances lie elsewhere. Whether a drive
at the disk's own rate, or a far stronger one, takes over is a measurement not made; it is
not an implementation ticket.

**Clumps in the young population only change the first frame, which is the point.** With the
stars at clumpiness 0.05 or 0 and the young population at 0.5 to 0.55 (`stars-0.05-young-0.55`,
`stars-0.00-young-0.50`, the prototype's `youngAttachment` knob) the first frame reads
`lump_stars` 0.02 to 0.05 against 0.23, while `lump_young` stays at 0.55 to 0.57: the knots
are where the references put them and the old disk is smooth. Nothing else moves outside
the seed spread (heating 0.196 and 0.231 at 300 Myr, a2 0.27 and 0.32 late; the first
excursion, 18.1 and 11.7 %, brackets the baseline's 15.1). Attaching the young population at
the stars' clumpiness, or at 0.6, changes nothing either (12.4 and 12.9 %, 0.18 at 300 Myr).
The two knobs are independent and only the first frame sees them.

## Recommendation

The settled arms stay lumpy and deformed, and the galaxy wobbles, because:

1. the mass carries a two-armed wave of contrast 0.96 with no velocity field, two to four
   times what a real old disk holds; it sharpens into a bar within 300 Myr, heats the disk to
   sigma_R / v_c 0.24 and contracts it by 30 %;
2. the renderer paints that wave at 0.42 of the material's rate while the particles' own
   pattern turns at 0.8 to 1.0 of it, so paint and matter beat at a quarter turn per 100 Myr;
3. the pattern's lopsided term puts an m = 1 of 0.21 in the mass from the first frame;
4. the app's camera follows a centre that sits 0.3 to 5 kpc off the nucleus.

Not the cause: the seeded clumps (gone in 15 Myr, visible on the first frame only) and the
particle count (54 000 to a million alike). What is left after the fixes is a disk that makes
its own three to four arms, corotating and short-lived, which is what a live disk at this
mass fraction does and what the references show outside two scale lengths.

The levers, measured:

- **The contrast in the mass at 0.3, with the streaming** (`old-stars-smooth`,
  `arm-streaming`): no bar, heating 0.14, a2 0.26 late, a1 0.20, first excursion 10 %, the
  app's centre within 0.3 kpc of the nucleus; the light keeps its arms from the young
  population and the paint. The calmest and most real-looking runs of the sweep on the sheets.
- **The lopsided term out of the mass**: a1 0.05 at t = 0 instead of 0.21, 7 points of
  excursion.
- **The painted pattern speed follows the particles** (0.8 to 1.0 of the material's rate at
  two scale lengths, corotation at 2 to 2.5 scale lengths, where real spirals have it) or the
  paint fades once the particles carry a wave; today's half rate is what beats.
- **Toomre Q 1.5 to 1.8**: 1.25 bars hard (a2 0.41, lumpiness 1.3), 2.0 is the calmest run
  (a2 0.15, lumpiness 0.13) but starts hot at 0.20; the cooling brings it back to 0.14.
- **Dissipation 300 to 600 Myr**: 600 keeps a2 0.24 with lumpiness 0.38; 150 fragments the
  disk; none cooks it.
- **The camera and the cooling on the nucleus**, smoothed over a rotation
  (`camera-nucleus`).
- **Clumps**: stars at 0.05 or under, the young population at 0.5.
- The drive at a few per cent, the arm count, a heavier disk and the particle count are not
  levers.

For #172: clumpiness of the stars 0.02 to 0.08 (default 0.05), of the young population 0.4 to
0.6, Toomre Q 1.4 to 1.8, the mass contrast 0.2 to 0.35 with `armStrength` 0.6 to 1.0 kept
for the light, dissipation 300 to 600 Myr, lopsidedness a tenth of what it is, two to four
painted arms, disk mass fraction left at 0.22.

## What was done

Implemented in the same pull request as the probe, for every galaxy drawn after it:

- `GalaxyConfig.armMassContrast` (0.3, never above `armStrength`): the old stars are placed
  on the pattern at that contrast, the young population and the gas at `armStrength` as
  before; and the old stars see the pattern's lopsided term at a tenth
  (`GalaxyConfig.massLopsidedness`, 0.03 against the light's 0.30).
- `GalaxyConfig.armStreaming` (1): the linear streaming field of the wave, between the inner
  Lindblad resonance and the corotation of the painted speed.
- `GalaxyConfig.youngClumpiness` (0.5) for the gas and the young stars; `clumpiness` (0.05)
  is the old stars' alone.
- The painted pattern turns at `DiskEquilibrium.patternSpeed()`, `GalaxyConfig.patternShare`
  (0.9) of the circular frequency at two scale lengths, the one expression the paint, the
  streaming and the probe read; it used to be half the analytic sphere's.
- The centre the solver reports, which the camera and the cooling follow, is the nucleus:
  the disk material and the bulge inside one and a half scale lengths of where it was.
- The generators draw the old stars' clumpiness in 0.02 to 0.08, the young population's in
  0.4 to 0.6, the mass contrast in 0.3 to 0.45 and Toomre Q in 1.25 to 1.45; lenticulars and
  dwarfs in proportion.
- **A scene file or a take written before reads as it was written**: every star at the painted
  contrast, no streaming, the young population at the clumpiness plus 0.3, the full lopsided
  term and the old pattern speed (`GalaxyConfig.legacy`), so a scene explored before replays
  the same at hires and an old take exports the same. `--calm` on a render, an explore or the
  probe moves every galaxy of a stored scene onto the calm disk (its clumpiness is left
  alone), and explore writes the fields into `scene.json`, so its hires follows.

**The Toomre Q of the generator was the last lever, and it was found on the pictures.** With
the contrast in the mass lowered, the generated spirals drawn at Q 1.4 to 1.8 kept their arms
in the particles for 100 Myr and then went smooth and stayed so, the painted wave alone too
faint to carry them: the airbrushed disk the epic warned of. The same galaxies at Q 1.3 grow
flocculent arms of their own, two to five of them, visible through 400 Myr and more, with a
first excursion of 4.4 to 6 % (`qtest` runs: a five-armed, a four-armed and a two-armed
spiral of batch 20261031). Hence 1.25 to 1.45.

Measured again with the probe on the same two galaxies moved onto the calm disk (`--calm`:
their clumpiness stays what the file says, 0.25 and 0.22, their Q 1.33 and 1.34):

| | Première before | after | Deuxième before | after |
| --- | --- | --- | --- | --- |
| first excursion | 15.1 % at 289 Myr | 9.8 % at 123 | 8.8 % at 91 | 6.2 % at 269 |
| r50, 0 to 1000 Myr | 8.52 to 6.04 kpc (-29 %) | 8.40 to 7.56 (-10 %) | 6.99 to 6.25 (-11 %) | 6.86 to 6.00 (-13 %) |
| sigma_R / v_c at 300 Myr, worst | 0.213, 0.239 | 0.146, 0.175 | 0.150, 0.155 | 0.125, 0.166 |
| a2 mid, peak and late | 0.61 at 475 Myr, 0.49 | 0.41 at 107, 0.24 | 0.56 at 55, 0.21 | 0.45 at 977, 0.20 |
| a2 inner, worst | 0.37 (a bar from 300 Myr) | 0.39 for one frame, 0.12 to 0.3 otherwise | 0.25 | 0.32 at the end |
| a1 mid, t = 0 and late | 0.21, 0.38 | 0.09, 0.20 | 0.10, 0.17 | 0.05, 0.14 |
| nucleus to the reported centre, late | 0.91 kpc | 0.07 | 0.27 | 0.08 |

On the sheets Première no longer bars: the painted arms soften into a flocculent pattern of
three to four arms that holds through the gigayear, the outskirts stay with the disk, and the
app's framing sits on the nucleus. The twenty generated spirals: TBD_GENERATED
