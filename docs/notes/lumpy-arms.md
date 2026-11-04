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
the first frame and little after: while they dissolve the clumps order sigma_R / v_c by the knob
between 16 and 47 Myr, by 0.02 at most, and by 100 Myr the order is inside the seed spread.
From about 500 Myr the lumpiness is 0.5 to 1.0 for every clumpiness, with no order: self-made
structure (bar, fragments, sharpened arms). The heating at 300 Myr does not follow the knob:

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
painted wave has gone is not arms at all: by 300 to 600 Myr the spectrum is flat from m = 1
to m = 8 at 0.2 to 0.55 (the strongest order over the weakest: 8 at t = 0, 3 at 160 Myr, 1.4 at
600 on Première), the signature of compact knots, and it scales with the cooling, which
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
formed grow faster than the count (0.9 % of the stars in 300 Myr at 54 000, 1.1 % at 108 000,
3.0 % at a million) and the floor under the amplitudes falls with it, nothing else moves.

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
not an implementation ticket. Measured since (#180, "A steady drive at the disk's own rate"):
neither does.

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
- **Toomre Q**: with the old sampling 1.25 bars hard (a2 0.41, lumpiness 1.3) and 2.0 is the
  calmest run (a2 0.15, lumpiness 0.13) but starts hot at 0.20. With the calm disk the answer
  turned out the other way, see "What was done": 1.25 to 1.45.
- **Dissipation 300 to 600 Myr**: 600 keeps a2 0.24 with lumpiness 0.38; 150 fragments the
  disk; none cooks it.
- **The camera and the cooling on the nucleus**.
- **Clumps**: stars at 0.05 or under, the young population at 0.5.
- The drive at a few per cent, the arm count, a heavier disk and the particle count are not
  levers.

For #172, as first proposed: clumpiness of the stars 0.02 to 0.08 (default 0.05), of the
young population 0.4 to 0.6, the mass contrast 0.2 to 0.35 with `armStrength` 0.6 to 1.0 kept
for the light, lopsidedness a tenth of what it is, two to four painted arms, disk mass fraction
left at 0.22. What was applied after the pictures is in "What was done": the mass contrast
0.3 to 0.45 and Toomre Q 1.25 to 1.45, the dissipation left as drawn.

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
  the disk material and the bulge inside one and a half scale lengths of where it was. A rigid
  analytic halo stays on the centre of mass: put on the nucleus, it pulls on its own lopsided
  stars with nothing pulling back and the galaxy pushes itself along (found in review).
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
| first excursion | 15.1 % at 289 Myr | 12.0 % at 241 | 8.8 % at 91 | 7.0 % at 273 |
| r50, 0 to 1000 Myr | 8.52 to 6.04 kpc (-29 %) | 8.40 to 7.57 (-10 %) | 6.99 to 6.25 (-11 %) | 7.00 to 6.37 (-9 %) |
| sigma_R / v_c at 300 Myr, worst | 0.213, 0.258 | 0.159, 0.208 | 0.150, 0.172 | 0.140, 0.143 |
| a2 mid, peak and late | 0.61 at 475 Myr, 0.49 | 0.42 at 111, 0.22 | 0.56 at 55, 0.21 | 0.32 at 408, 0.15 |
| a2 inner, worst; frames over 0.3 | 0.57 at 510 Myr; 56 of 254 | 0.46 at 625; 55 of 254 | 0.34 at 32; 10 of 254 | 0.22 at 388; 0 of 254 |
| a1 mid, t = 0 and late | 0.21, 0.38 | 0.09, 0.30 | 0.10, 0.17 | 0.08, 0.13 |
| nucleus to the reported centre, late | 0.91 kpc | 0.13 | 0.27 | 0.09 |

On the sheets Première no longer turns into a bar with a dislocated outer disk: the painted
arms soften into a pattern of three to four arms that holds through the gigayear, with a weak
inner oval (a2 0.30 to 0.32 for a fifth of the frames, 0.46 at worst, against the old bar's
0.57), the outskirts stay with the disk and the app's framing sits on the nucleus. Deuxième
keeps two clean arms through the whole gigayear.

**Twelve generated spirals** of batch 20261031 (the first spiral of each scene drawn with the
new ranges, at the explore count, 1 Gyr): first excursion 2.9 to 7.3 % (median 5.0), heating
at 300 Myr 0.08 to 0.13 (median 0.105), late a2 0.06 to 0.26, the median radius 1 to 10 %
smaller after the gigayear (median 4), the reported centre within 0.14 kpc of the nucleus
(median 0.06); eleven of twelve stay under an inner a2 of 0.3 on every frame, the twelfth at
0.32. Six of them run again after the last two fixes to the streaming (its phase on the
wandering crest, no net radial flow) moved by 2 to 3 points of excursion either way, the
chaotic spread. On the sheets the six larger ones (mass 46 to 64, scale length 4.3 to 5.5 kpc)
keep clear spiral arms through the gigayear; **the six smaller ones fade to a nearly smooth
disk** after 100 to 300 Myr (late amplitude 0.11 to 0.18 against 0.19 to 0.33), which a Toomre
Q of 1.2 improved only a little. That is the airbrushed look the epic warns against, left for
#181 with its suspects: the softening, set by the scene's sparsest disk, the particle count, the
faint paint of three to five arms, the cooling.

## The small spirals (#181)

The six smaller spirals of that batch (mass under 50, scale length under 4.2 kpc: the first
spiral of scenes 0, 1, 2, 9, 10 and 12, written `free-0` and so on, from the scene files the
#179 acceptance drew; the batch draws other scenes since #176) through the probe again, each
alone for 1 Gyr at 200 000 a scene as that acceptance ran them. The figure is `armsL`
of `probe-report.py table`: over the last 500 Myr, the mean of each frame's largest of a2 to a6
in the middle zone, whatever the arm count, the figure the 0.11 to 0.18 against 0.19 to 0.33
above was. Its own noise over one run is 0.007 to 0.02, the late frames being correlated over
30 to 150 Myr; another sampling of the same galaxy moves it by 0.01 to 0.02. Run at the
explore step (`--dt-scale 3.5`, 0.198 Myr) and at the scene's own (0.04 to 0.06 Myr) every
galaxy tried read the same within 0.012, so most runs here are at the explore step, which is
what a night runs and four to five times cheaper.

| | late arms | first excursion | inner a2, worst | stars | eps / h | z0 / h, drawn | Q | turn at 2 h |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| free-0 | 0.168 | 6.3 % | 0.18 | 162 k | 0.045 | 0.100 | 1.33 | 119 Myr |
| free-1 | 0.108 | 4.0 % | 0.11 | 154 k | 0.038 | 0.128 | 1.43 | 130 Myr |
| free-2 | 0.154 | 5.2 % | 0.11 | 51 k | 0.059 | 0.102 | 1.42 | 198 Myr |
| free-9 | 0.111 | 5.1 % | 0.11 | 108 k | 0.065 | 0.135 | 1.35 | 110 Myr |
| free-10 | 0.129 | 3.6 % | 0.10 | 47 k | 0.067 | 0.040 | 1.29 | 184 Myr |
| free-12 | 0.191 | 7.1 % | 0.16 | 40 k | 0.073 | 0.042 | 1.27 | 104 Myr |
| larger six (#179 runs) | 0.185 to 0.274 | 4.5 to 6.2 % | 0.15 to 0.30 | 87 k to 200 k | 0.028 to 0.043 | 0.037 to 0.114 | 1.26 to 1.40 | 149 to 202 Myr |

**No suspect explains the fading alone, and each moves a small disk by less than the gap.**
On the galaxy each suits best:

| suspect | run | late arms | first excursion | inner a2, worst |
| --- | --- | --- | --- | --- |
| softening, half the scene's | free-10, eps 0.258 to 0.129 kpc | 0.129 to 0.172 (scene step: 0.123 to 0.175) | 3.6 to 4.7 % | 0.10 to 0.11 |
| | free-2, 0.241 to 0.120 | 0.166 to 0.144 | 5.3 to 6.0 % | 0.12 to 0.13 |
| softening, the galaxy's own spacing | free-9, 0.222 to 0.130 | 0.111 to 0.123 | 5.1 to 5.7 % | 0.11 |
| | free-12, 0.193 to 0.128 | 0.184 to 0.181 | 7.2 to 9.4 % | 0.19 to 0.20 |
| particles, four times | free-10, 47 000 to 189 000 stars at eps 0.129 | 0.172 to 0.151 | 4.7 to 3.8 % | 0.11 to 0.09 |
| paint, `armStrength` 0.53 to 0.85 | free-10 | 0.129 to 0.159 | 3.6 to 3.3 % | 0.10 |
| cooling, 1.4 turns | free-12, 258 to 150 Myr | 0.191 to 0.228 | 7.1 to 10.7 % | 0.16 to 0.31 |
| | free-9, 222 to 154 Myr | 0.111 to 0.130 | 5.1 to 5.6 % | 0.11 to 0.12 |
| Toomre Q (not a suspect) | free-1, 1.43 to 1.20 | 0.108 to 0.149 | 4.0 to 3.9 % | 0.11 |
| | free-2, 1.42 to 1.25 | 0.154 to 0.179 | 5.2 to 5.1 % | 0.11 to 0.13 |
| | free-9, 1.35 to 1.20 | 0.111 to 0.131 | 5.1 to 5.4 % | 0.11 to 0.09 |
| thickness (not a suspect) | free-9, own eps and z0 0.135 to 0.04 h | 0.111 to 0.133 | 5.1 to 6.2 % | 0.11 to 0.12 |

- **The softening another galaxy sets**, the suspect as the ticket put it, is worth 0.01 at
  most: free-9 and free-12 run at 1.7 and 1.5 times their own spacing and gain nothing that
  shows when given it. The softening of a sparse disk at its own spacing matters on the
  thinnest one, free-10 (0.067 h against a thickness of 0.04 h), whose disk grows four arms
  late once it is halved; not on free-2, which is thicker. With the step shortened along with
  the softening, as a cap in the scene would do it, free-10 gained 0.027 and, on a second
  sampling, 0.005.
- **Particles**: free-1 (154 000 stars) and free-9 (108 000) fade with more stars than free-7
  (88 000) keeps its arms with, and four times free-10's count at the halved softening reads
  0.151 against 0.172: more particles seed less, and the lumps they make go from 0.25 to 0.15
  (the metric's own noise accounts for under 0.01 of it). Not a lever.
- **The paint is not what makes the pictures smooth.** On the stills, the late light contrast
  of the small disks (the azimuthal amplitude of the face-on luminance at 1.5 to 3 scale
  lengths, 0.03 to 0.10, a 90th to 10th percentile ratio of 1.4 to 2.0) is what their particles
  hold, against 0.08 to 0.15 and 2.0 to 3.2 for the larger ones; lifting free-10's
  `armStrength` from 0.53 to 0.85 moved it from 0.053 to 0.057 (its particles gained 0.03, the
  young population being placed at that contrast). A floor on the painted contrast would not
  change the look.
- **The cooling** is drawn in megayears (180 to 320) and the small primaries turn in 104 to
  130 Myr against 150 to 200 for the larger ones, so they cool less for each turn. At 1.4 turns
  free-12 holds 0.27 to 0.32 from 150 to 600 Myr, but contracts 15 % and passes the excursion
  and the bar limits; at its turn-scaled 189 Myr it gains nothing and still passes the
  excursion (10.1 %).

**Together they move a disk a long way, and tip a compact one into a bar.** free-1 with Q 1.25,
a disk of 0.04 h, 182 Myr of cooling and a softening of 0.035 h reads 0.216 (first excursion
4.8 %, inner a2 0.13), twice its baseline, with clear arms through the gigayear on the stills;
free-9 the same way reads 0.158. A patch that capped every generated scene's softening at
0.035 of its smallest spiral's scale length (never under half the spacing's, the step
following) and shortened a spiral's cooling in proportion to its turn below 150 Myr gave, on
the six: free-0 0.168 to 0.226, free-1 0.108 to 0.130, free-2 0.154 to 0.151, free-9 0.111 to
0.141, free-10 0.129 to 0.156, free-12 0.191 to 0.255 with a bar (inner a2 0.37 and 0.39 on two
samplings, five and six frames over 0.3, the excursion 11.0 and 9.8 %). One of six reaches
0.18 within the limits, compact free-12 bars, and the softening cap costs a night 14 % more
explore steps on average (up to twice for a scene with a small companion), so it was not
merged.

**What the twelve share is how much of their own gravity is left where arms grow.** Plummer
softening on a thin disk weakens the pull of a wave of wavenumber k by exp(-k eps), the way a
sech^2 layer of height z0 does by about 1 / (1 + k z0), and a disk answers as an unsoftened
razor-thin one would at Q over that factor. At the wavenumber that grows fastest near Q 1.2,
k = 1.39 X_2 / h (X_2 of the probe's `facts`), with the thickness a disk has over its last
500 Myr (the cooling thins a thick one to about half of what it was drawn at), Q over the
factor sorts the twelve:

| | eps / h | z0 / h, late | gravity left, softening x thickness | Q / left | late arms |
| --- | --- | --- | --- | --- | --- |
| free-9 | 0.065 | 0.070 | 0.70 x 0.72 = 0.50 | 2.70 | 0.111 |
| free-2 | 0.059 | 0.064 | 0.75 x 0.76 = 0.57 | 2.51 | 0.154 |
| free-1 | 0.038 | 0.069 | 0.81 x 0.72 = 0.58 | 2.47 | 0.108 |
| free-10 | 0.067 | 0.041 | 0.69 x 0.82 = 0.56 | 2.30 | 0.129 |
| free-12 | 0.073 | 0.041 | 0.68 x 0.82 = 0.56 | 2.27 | 0.191 |
| free-0 | 0.045 | 0.053 | 0.80 x 0.79 = 0.64 | 2.09 | 0.168 |
| free-13 | 0.028 | 0.045 | 0.86 x 0.80 = 0.69 | 2.04 | 0.263 |
| free-8 | 0.030 | 0.053 | 0.86 x 0.79 = 0.67 | 2.01 | 0.220 |
| free-4 | 0.039 | 0.047 | 0.80 x 0.79 = 0.63 | 2.00 | 0.185 |
| free-3 | 0.035 | 0.027 | 0.81 x 0.86 = 0.70 | 1.89 | 0.230 |
| free-7 | 0.043 | 0.029 | 0.80 x 0.87 = 0.69 | 1.84 | 0.224 |
| free-11 | 0.038 | 0.031 | 0.82 x 0.86 = 0.71 | 1.78 | 0.274 |

Over 2 the disks fade, under it they keep arms (free-8 and free-13 are two-armed, carried by a
painted wave the streaming holds); the combined runs above sit at 1.77 and 1.78. It is not the
whole story: free-9, at 1.77 when combined, still reads 0.158, its inner disk stiffened by the
largest bulge of the twelve (0.20 of its stars) and a concentrated halo (X_2 3.64 at one scale
length against 3.0 for free-11), and free-12, bulgeless, bars at 1.87 once it also cools
faster. Size enters twice: through the softening, since the particles go by mass and a small
disk gets few of them, and through the turn, since a small primary is denser; the thickness and
Q enter with any size, and the small six happen to hold the two thickest disks and the two
highest Q of the twelve.

**What to try next.** Draw the response rather than Q: give a spiral the effective Q the keepers
have, 1.75 to 1.95, from its drawn thickness, with the softening held to about 0.035 of the
smallest spiral's scale length so that the factor does not depend on the count; count the bulge
and the halo's concentration in, or leave a stiff disk to read as an early type carried by its
paint; and measure it on the twelve with the larger ones watched for bars. Multi-galaxy scenes
explore at 100 000 a galaxy, more than the 200 000 a scene used here, so free-1, free-9 and
free-12 run there at 0.7 to 0.8 of the softening measured; the twelve are the #179 sample, two
samplings were run only for free-10 and free-12.

## The response drawn instead of Q (#181, second round)

**What changed.** A spiral of three to five arms is now drawn for its response rather than its
Toomre Q: the generators (free and archetypes, through `FreeDraw.galaxy`) draw an effective Q of
1.75 to 1.95 and solve Q for it (`DiskResponse`, the one place the figure is computed). The
effective Q is the first round's: Q over `exp(-k eps) / (1 + k z)` at `k = 2 / 1.2^2 kappa^2 /
(2 pi G Sigma)` at two scale lengths, under the live halo the runs give a generated scene. The
softening is the one the scene explores at with 100 000 visible particles a galaxy, shared by
mass, a black hole counting for none: a pair's 200 000, as the first round probed, and the
middle of what Auto sizes a night at. The thickness is the one a disk keeps late, modelled from
the drawn one as `0.023 h + 0.32 z0` (31 runs of the first round, 0.005 h rms; the drawn
thickness alone does not sort the twelve). Q is solved once alone in the draw and again in
`finishGenerated`, once a companion has its mass from its ratio and its share of the particles,
and never goes under 1.05, since a scene is refused under 1. The draw takes the old draw's place
in the stream, so nothing else of any scene moves and a batch gives the same scenes: scenes 0 to
19 of batch 20261031, drawn by main and by the branch, differ in `toomreQ` and nothing else. A
stored scene reads as written (scene-0031, 0 to 40 Myr, 847 of 847 cells identical). Two-armed
spirals, lenticulars and dwarfs keep their draw of Q, and `contemplation`, which never drew Q,
keeps its 1.4. The probe reports the effective Q at the run's softening in `facts`, and
`--effective-q` solves a galaxy's Q for one the same way.

**How it was measured.** The twelve of the first round, from its scene files, and fresh draws of
the current batch, at 100 000 a galaxy (pairs at 200 000; free-1, free-9, free-12 and free-4 at
300 000 to 500 000, more particles than the first round gave them; free-13, alone, at 100 000)
and the explore step, 1 Gyr. The old draw put Q at 1.25 + 0.2 u and the new one puts the
effective Q at 1.75 + 0.2 u for the same u, so a galaxy's new draw is its old Q plus 0.5, applied
with `--effective-q`; a second sampling (`--seed 2`) for anything near a limit. 86 runs at the
explore count and 10 at 2 M, kept in `sillage-wt-181/out/181b/runs`.

**The keepers' range in the code's own terms.** With the modelled thickness, at 100 000 a
galaxy, the old draw already sorted the twelve: the keepers at 1.83 to 2.07, the faders at 2.08
to 2.43 (the first round's 1.77 to 2.04 and 2.09 to 2.70 used each run's measured late thickness,
at 200 000 a scene). Under it, the measured Q of every small disk settles at 1.0 to 1.2, drawn at
1.05 or at 1.43: the cooling pulls each star's random motion down to the drawn equilibrium's and
no further, so a disk that grows only weak arms sits there, cold and smooth.

**At equal response a large disk answers more than a small one**, by more than the chaotic
spread. Drawn at 1.75 to 1.95 for every spiral, the small six gained 0.01 to 0.06 while the
large ones gained up to 0.17 and three of them left the limits: free-8's first excursion 10.0
and 10.3 % on two samplings (8.3 and 9.6 % at its old draw), free-7 an inner a2 of 0.31 on both
(0.30), free-13 0.31 and 0.26 (0.18 and 0.19). Lower still, 1.70 to 1.75, the large three-armed
free-11 barred (0.29 and 0.42) and the four-armed free-3 once (0.31 and 0.22), while the small
ones kept their arms with no bar down to 1.71 (free-1 at the floor 0.212, free-12 0.232 and
0.188). Whatever separates them is not in the effective Q: the shear at two scale lengths is
1.02 to 1.13 for all of them, the two-armed paint does not (free-4 is two-armed and never bars),
and the cooling per turn sorts most of them, a disk that cools in 1.1 to 1.6 of its turns
answering at 1.9 to 2.1 and one that cools in 2.2 to 2.5 only under 1.75, but not free-13, which
bars at 2.06 where free-2, cooling faster still, keeps clean arms at 1.79. A range that keeps
every large disk off its limits gives the small ones what they had; one that lifts free-1 bars
free-11.

**Two-armed spirals keep the old draw.** They sit in a narrow window: lower they bar, higher
they fade. Drawn at 1.85 to 2.30 (their old spread in the new terms), the large two-armed four
were where they had been, but the small fresh scene-12 lost its arms (0.209 at its old draw,
0.149). At their own old draw, six of the eleven two-armed spirals measured reach an inner a2 of
0.30 or more (fresh scene-5 g1 0.38, scene-14 g1 0.33, scene-16 g1 0.37, scene-19 g0 0.48 with a
first excursion of 14.4 %): a bar the generator draws with the two-armed paint, before #181 and
not changed by it.

The twelve and the fresh spirals the rule changes, before and after, each line one or two
samplings:

| | arms | h, bulge, halo / h | effective Q | late arms | inner a2, worst | first excursion |
| --- | --- | --- | --- | --- | --- | --- |
| free-0 | 4 | 3.20, 0.06, 1.65 | 2.10 to 1.83 | 0.168 to 0.225, 0.219 | 0.18 to 0.20, 0.19 | 6.3 to 5.5, 5.7 % |
| free-1 | 5 | 4.10, 0.11, 1.01 | 2.32 to 1.93 | 0.129 to 0.145 | 0.10 to 0.10 | 3.8 to 3.6 % |
| free-2 | 3 | 4.10, 0.15, 1.57 | 2.43 to 1.92 | 0.154 to 0.198, 0.185 | 0.11 to 0.14, 0.17 | 5.2 to 4.8, 5.0 % |
| free-12 | 3 | 2.66, 0.02, 1.50 | 2.08 to 1.77 | 0.167 to 0.179, 0.181 | 0.15 to 0.20, 0.17 | 7.5 to 6.7, 9.2 % |
| free-9 | 3 | 3.43, 0.20, 1.11 | 2.39 to 1.86, floor | 0.117 to 0.152 | 0.11 to 0.13 | 5.4 to 6.0 % |
| free-10 | 3 | 3.87, 0.16, 1.12 | 2.25 to 1.82, floor | 0.129 to 0.172 | 0.10 to 0.13 | 3.6 to 3.2 % |
| scene-15 g0 | 3 | 4.18, 0.06, 0.94 | 2.12 to 1.81 | 0.191 to 0.311 | 0.17 to 0.28 | 7.8 to 8.6 % |
| free-3 | 4 | 5.40, 0.06, 0.95 | 1.98 to 1.83 | 0.266, 0.269 to 0.328, 0.325 | 0.20, 0.18 to 0.20, 0.25 | 5.8, 4.0 to 6.1, 3.8 % |
| free-11 | 3 | 5.36, 0.03, 1.43 | 1.83 to 1.76 | 0.263 to 0.262, 0.262 | 0.20 to 0.20, 0.27 | 6.0 to 5.6, 7.9 % |
| scene-9 g0 | 4 | 5.68, 0.02, 1.12 | 2.26 to 1.90 | 0.165 to 0.222 | 0.13 to 0.16 | 6.4 to 6.4 % |
| scene-14 g0 | 3 | 4.89, 0.18, 1.34 | 2.07 to 1.91 | 0.218 to 0.237 | 0.21 to 0.19 | 6.7 to 7.8 % |

**The disks let smooth.** free-9 and free-10 hold the largest bulges of the small ones (0.20 and
0.16 of their stars) inside the most concentrated halos (scale radius 1.1 scale lengths), soft and,
for free-9, thick: their Q stops at the floor and they read 0.15 and 0.17, an early-type disk
carried by its paint. For #181 a spiral is small when its scale length is under 4.2 kpc (the
first round's six, free-1 at a mass of 51 included, and the fresh small ones), and is let smooth
when its bulge holds 0.15 of its stars or more inside a halo of scale radius under 1.2 scale
lengths; no other small spiral of the twelve or the fresh draws meets both.

**Explore against 2 M.** The draw solves Q at the explore count, and a run with more particles
is softened less: at 2 M the four measured run at a third of explore's softening, their
effective Q 0.22 to 0.34 lower (free-12 1.77 to 1.46, free-2 1.92 to 1.58, free-0 1.83 to 1.57,
free-11 1.76 to 1.54). With the same Q they carry 0.03 to 0.16 more late arms (free-12 0.18 to
0.248, free-2 0.19 to 0.357, free-0 0.22 to 0.258, free-11 0.262 to 0.321), an inner a2 of 0.27
to 0.29 and a hotter disk (sigma_R / v_c 0.13 to 0.19 late, 0.10 to 0.13 at explore), and free-2
tears into knots by 1 Gyr. Hires answering more is not new: at their old draw free-12, free-11
and free-0 went from 0.167, 0.263 and 0.168 at explore to 0.274, 0.334 and 0.213 at 2 M, the
first two barred there (inner a2 0.37 and 0.38, against 0.29 and 0.27 with the new draw); free-2
alone looked alike at both counts (0.154 and 0.145), and the new draw parts it. Solving Q at
each count for the same response would hold the look: free-2 at 2 M with the Q its explore
response asks there (1.38) reads 0.177, a clean disk of soft arms, against 0.198 at explore.
free-12 bars at 2 M at every Q but the lowest (0.37 at its old 1.27, 0.38 at 1.31, 0.29 at
1.08). Storing the response in the scene file instead of Q changes what a scene file holds, so
it is left for Pierre with the softening cap.

**What is left.** Of the small spirals the rule draws, free-0, free-2 and fresh scene-15 keep
0.18 or more on every sampling with no bar and under 10 %; free-12 sits on the line (0.179 and
0.181) and free-1 under it (0.145): free-1 reached 0.212 at an effective 1.71, the floor, where
the large free-11 bars. The small two-armed ones are where they were, fresh scene-12 keeping its
arms (0.209), scene-1 g1 at 0.175, scene-17 at 0.145 with an inner a2 of 0.30 and scene-5 g1
barred. So the done-when is not met. What would separate a small disk from a large one is the
second channel the first round named, the cooling drawn in megayears against turns of 104 to 210
Myr, or the softening cap it measured (14 % more explore steps a night); both are Pierre's call,
as is solving the response at each count so that explore and hires agree, and the two-armed bar
is a ticket of its own.

## The response kept at every count (#181, third round)

**What changed.** The scene file keeps the response a disk was drawn for, `effectiveToomreQ`
beside `toomreQ`, and every run that reads it, explore, hires and the probe, gives the disk the
Toomre Q that holds that response at the softening it runs at (`SceneFile.scene`,
`SceneConfig.solveToomreQ`; a `--massive` run at its massive count's). A hires disk is softened
less and gets more Q: free-12 1.08 at explore, 1.31 at 2 M and 1.40 at 8 M. The response kept is
the drawn one or, where the floor of Q stops a soft disk at 100 000 particles a galaxy, the
stiffer one the floor leaves there, so no run at that count or above finds the floor and all of
them give the disk the same response. A generated scene solves Q at the count it is drawn at,
and the `toomreQ` a scene file holds is the one it last ran at. A file without the field, every
scene in the library, runs Q as written.

**Checked.** Library scene-0031 (a copy), read by main and by the branch: the probe of both
galaxies over 40 Myr, 847 of 847 cells identical each, and a six-frame render, curves 102 of 102,
the six frames and the scene file it writes identical byte for byte (the file also to the stored
one). Scenes 0 to 19 of batch 20261031 drawn at 100 000 a galaxy differ from main's by the
twelve responses now written and by the Q of eight small spirals (the rules below), nothing
else. Read at the explore count, a file holding round 2's response
for free-12 reproduces round 2's run cell for cell (18 865 of 18 865), so the second round's
explore runs stand for this one's.

**Explore against 2 M**, the response kept, two samplings each (late arms; inner a2 at worst;
first excursion):

| | Q at explore, 2 M | explore | 2 M |
| --- | --- | --- | --- |
| free-0 | 1.15, 1.34 | 0.225, 0.219; 0.20, 0.19; 5.5, 5.7 % | 0.195, 0.226; 0.17, 0.22; 6.8, 6.6 % |
| free-2 | 1.13, 1.38 | 0.198, 0.185; 0.14, 0.17; 4.8, 5.0 % | 0.177, 0.197; 0.14, 0.18; 6.7, 6.9 % |
| free-11 | 1.21, 1.38 | 0.262, 0.262; 0.20, 0.27; 5.6, 7.9 % | 0.303, 0.248; 0.45, 0.29; 6.1, 7.6 % |
| free-12 | 1.08, 1.31 | 0.179, 0.181; 0.20, 0.17; 6.7, 9.2 % | 0.238, 0.208; 0.38, 0.20; 9.2, 9.1 % |

Where the softening was what parted the two counts, the response kept holds the look: free-0
and free-2 read at 2 M as at explore, within what two samplings of either spread, and on the
sheet with the same arms. free-12 and free-11 still answer more at 2 M, and one sampling of each
bars late (free-12 from 500 Myr, free-11 from 900). free-12 at 8 M (Q 1.40, one sampling) reads
0.233 with an inner a2 of 0.23 and 7.6 %, like its second sampling at 2 M. Taken apart on
free-12, one change at a time from its explore run (one sampling each):

| from explore: 61 000 stars, 0.157 kpc, Q 1.08, 0.195 Myr | late arms | inner a2 | first excursion |
| --- | --- | --- | --- |
| none | 0.179 | 0.20 | 6.7 % |
| the step of 2 M, 0.0755 Myr | 0.181 | 0.23 | 6.4 % |
| the softening of 2 M, 0.061 kpc, Q solved there (1.31), that step | 0.193 | 0.23 | 7.1 % |
| the stars of 2 M, 407 000 | 0.190 | 0.30 at 240 Myr | 10.3 % |
| the stars and the step | 0.202 | 0.30 | 10.3 % |
| all of them (2 M) | 0.238, 0.208 | 0.38, 0.20 | 9.2, 9.1 % |

The step does nothing and the softening, with Q solved for it, 0.014: the response does what it
was built for. What is left is the particle count itself: sampled by 6.7 times the stars at the
same softening, Q and step, the disk answers its painted wave harder over its first 300 Myr (the
first excursion 6.7 to 10.3 %, the inner a2 0.30 at 240 Myr against 0.20) and keeps a little
more late. No Q per count holds that, since it is not the disk's response that differs but what
it is seeded with. free-11, large, still tears into kiloparsec knots by 1 Gyr at 2 M with Q 1.38,
as it did in round 2 at 1.21 and 1.26.

**The small spirals get a window of their own.** At equal response a small disk answers less
than a large one (second round), and the small ones sit in a narrow window between a bar and a
smooth disk. Measured at 100 000 a galaxy on the five small spirals of three to five arms the
rule draws, late arms of each sampling, all with an inner a2 under 0.3 and an excursion under
10 % but where said:

| response | free-0, 4 arms | free-1, 5 | free-2, 3 | free-12, 3 | scene-15 g0, 3 |
| --- | --- | --- | --- | --- | --- |
| 1.68 | 0.308 (a bar from 985 Myr, 0.33), 0.201 | | | | 0.230, 0.250 |
| 1.71 to 1.72 | 0.221, 0.200 | 0.212 (the floor, 1.711); 0.172, 0.153 | | 0.232, 0.188 (the floor, 1.716) | 0.261, 0.215 |
| 1.73 to 1.745 | 0.227, 0.194 (1.739) | 0.183 (1.73); 0.185, 0.170 | | 0.259, 0.213 (1.74) | |
| 1.76 to 1.79 | | 0.170, 0.175 (1.788) | 0.248, 0.245 (the floor, 1.788) | 0.179, 0.181 (1.77) | 0.268 (1.76) |
| as main draws it | 0.225, 0.219 (1.827) | 0.145 (1.926) | 0.198, 0.185 (1.925) | 0.179, 0.181 (1.770) | 0.221 (1.940) |

free-0 bars under 1.70 on one sampling of two, free-12 has its arms back from its floor up to
1.74, and free-1 reads 0.15 to 0.21 anywhere from its floor to 1.79, 0.17 on average. Hence a
spiral of three to five arms whose scale length is under 4.2 kpc, the done-when's category, once
its companion has its size, is given the place of its draw in 1.72 to 1.76 instead of 1.75 to
1.95 (`DiskResponse.smallRange`): free-0 1.735, free-1 1.755, free-12 1.724, scene-15 1.758 and
free-2 its floor, 1.788, as before.

**Small two-armed spirals are drawn for a response too.** Drawn at their Q they sit at 1.92 to
2.03 at the explore count, and three of the four fade or bar. Given the place of their draw of Q
in 1.80 to 1.86 (`DiskResponse.smallTwoArmedRange`; large two-armed spirals keep their Q):

| | as main draws it | 1.80 to 1.86 | 1.87 to 1.89 |
| --- | --- | --- | --- |
| scene-1 g1 | 0.173, 0.151 (2.03) | 0.216, 0.198 (1.807); 0.190, 0.203 (1.847) | 0.182, 0.178 (1.88) |
| scene-12 g0 | 0.209 (1.915) | 0.219, 0.184 (1.831); 0.239 (1.85) | 0.187, 0.175 (1.871) |
| scene-17 g0 | 0.145, inner a2 0.30 (2.02) | 0.162, 0.220, inner a2 0.31 both (1.847) | 0.181, 0.172, 0.31 (1.887, 1.88) |
| scene-5 g1 | 0.359, a bar of 0.38 (2.01) | 0.426, a bar of 0.38 (1.831) | 0.402, a bar of 0.48 (1.871); 0.278 and 0.63 at 2.2 |

scene-17's inner a2 passes 0.3 only between 55 and 111 Myr, in the settle the clip never shows:
the painted arms' first wind-up at a pitch of 40 degrees, at any response; from 150 Myr on it is
0.26 at most. scene-5 g1 bars at every response from 1.83 to 2.2. It cools in 0.92 of its turns
(193 Myr against 210), the fastest of all: at its own Q with the cooling at two turns, 420 Myr,
it keeps arms of 0.242 and an inner a2 of 0.17. The cooling paced to the turn is what it needs,
not the response.

**The rule as the branch draws it**, read from the scene files (late arms; inner a2; first
excursion, two samplings):

| | before | after |
| --- | --- | --- |
| free-0 | 0.225, 0.219; 0.20, 0.19; 5.5, 5.7 % | 0.220, 0.199; 0.28, 0.19; 6.6, 5.7 % |
| free-1 | 0.145; 0.10; 3.6 % | 0.174, 0.150; 0.13, 0.11; 4.5, 4.2 % |
| free-2 | 0.198, 0.185; 0.14, 0.17; 4.8, 5.0 % | 0.234, 0.210; 0.17, 0.16; 4.9, 4.7 % |
| free-12 | 0.179, 0.181; 0.20, 0.17; 6.7, 9.2 % | 0.276, 0.203, 0.200; 0.34 (from 770 Myr), 0.18, 0.18; 8.2, 9.9, 9.1 % |
| scene-15 g0 | 0.221; 0.16; 8.1 % | 0.293, 0.232; 0.18, 0.17; 8.9, 8.5 % |
| scene-1 g1 | 0.173, 0.151; 0.13, 0.12; 7.1, 5.2 % | 0.216, 0.198; 0.15, 0.15; 6.8, 5.3 % |
| scene-12 g0 | 0.209; 0.19; 6.8 % | 0.219, 0.184; 0.20, 0.18; 6.9, 6.1 % |
| scene-17 g0 | 0.145; 0.30; 5.2 % | 0.162, 0.220; 0.31, 0.31; 5.8, 6.9 % |
| scene-5 g1 | 0.359; 0.38; 6.9 % | 0.426; 0.38; 6.3 % |

**Out of sample**, the small spirals of scenes 20 to 39 of the same batch, which no range here
was tuned on, at 100 000 a galaxy, one sampling each (the response before and after; late arms
before and after; inner a2 and excursion after):

| | arms, scale length | response, main to branch | late arms, main to branch | inner a2, excursion |
| --- | --- | --- | --- | --- |
| scene-22 g1 | 4, 3.83 kpc | 1.794 to 1.729 | 0.278 with a bar of 0.43, to 0.262 | 0.26, 3.0 % |
| scene-33 g0 | 3, 3.60 | 1.947 to 1.759 | 0.162 to 0.194, 0.184 | 0.15, 7.4 % |
| scene-20 g3 | 3, 3.11 | 1.909 to its floor, 1.754 | 0.163 to 0.217 | 0.16, 5.3 % |
| scene-35 g3 | 5, 4.16 | 1.912 to 1.752 | 0.240 to 0.218 | 0.21, 3.9 % |
| scene-36 g1 | 4, 3.02 | its floor, 1.867, both | 0.219 | 0.17, 6.6 % |
| scene-37 g1 | 3, 2.99 | 1.897 to its floor, 1.794 | 0.225 to 0.218 | 0.22, 6.9 % |
| scene-26 g0 | 5, 2.92 | 1.904 to 1.751 | 0.164 to 0.164, 0.167 | 0.16, 6.0 % |
| scene-37 g0 | 5, 3.49 | 1.802 to 1.730 | 0.143 to 0.169, 0.170 | 0.14, 7.6 % |
| scene-31 g1 | 4, 1.98, mass 9.8 | its floor, 1.925, both | 0.165 | 0.14, 4.8 % |
| scene-35 g1 | 2, 3.68 | its Q (2.26) to its floor, 1.860 | 0.284 to 0.324 | 0.29, 7.1 % |
| scene-20 g2 | 2, 2.11, mass 13.1 | its Q (2.58) to its floor, 2.022 | 0.136 to 0.143 | 0.29, 4.2 % |

Seven of the eleven keep their arms against four before; scene-21 g1 and scene-20 g0 (free-9)
are let smooth (a bulge of 0.15 of the stars or more in a halo under 1.2 scale lengths).

**What is left.** Of the small spirals measured, the rule keeps free-0, free-2, scene-15 g0,
scene-1 g1 and scene-12 g0 over 0.18 with no bar on every sampling, free-12 on two of three, and
seven of the eleven drawn out of sample. What still fails is of three kinds, none of them the
response:

- Five-armed small disks stay at 0.15 to 0.18 at every response from their floor up: free-1
  (0.174, 0.150), scene-26 g0 (0.164, 0.167), scene-37 g0 (0.169, 0.170), while scene-35 g3,
  five-armed and as small, keeps 0.218. They stay cold (a late measured Q of 1.1 to 1.3) with
  their power spread over three to five arms. A third of the particles at the same softening
  gives free-1 less, not more (0.156).
- Small companions held stiff by the floor: scene-31 g1 (mass 9.8, 31 000 stars, floor 1.925)
  0.165, scene-20 g2 (13.1, two arms, floor 2.022) 0.143. At 100 000 a galaxy shared by mass the
  softening of so few stars leaves their Q at 1.05 however low the response drawn; the softening
  cap of the first round is what would reach them.
- Two-armed disks the response does not reach: scene-5 g1 bars from 500 Myr at every response
  from 1.83 to 2.2, and keeps its arms without a bar at its own Q with its cooling at two turns;
  scene-17 g0 passes an inner a2 of 0.3 only in the settle, the painted arms of a 40 degree pitch
  winding up, and keeps late arms of 0.162 and 0.220.

free-12, compact and bulgeless, bars late on one sampling of three at the window, as on one of
two at 2 M. The done-when is not met: the cooling paced to the turn and the softening cap are
the levers these point at, and nothing measured here moves the five-armed ones.

## A steady drive at the disk's own rate (#180)

The question the drive above left: does a drive turning at the disk's own preferred rate (0.8
to 1.0 of the material's at two scale lengths, corotation at 2 to 2.5 scale lengths), or a far
stronger one, lock the particles' pattern (coherence in the pattern frame above 0.6 at a 50 Myr
lag, pattern speed within 10 % of the drive's) at a heating the cooling holds (sigma_R / v_c
under 0.18 late), and does it still read as real. Measured on both galaxies of scene-0031 moved
onto the calm disk (`--calm`), at the explore count and step (200 000 a scene, 0.198 Myr) for
1 Gyr, with a second sampling (`--seed 2`) of everything that looked like a gain: 52 runs of
33 to 55 s, written outside the library and not kept.

**The port** is on branch `spike/180-prototypes`, not on main: the prototype on the calm disk,
with a speed of its own. Three `GalaxyConfig` fields whose absence reads as no drive,
`driveStrength` (zero), `driveShare` (the speed as a share of the circular frequency at two
scale lengths, like `patternShare`; zero turns it with the paint) and `driveRampMyr` (400, on
Dehnen's quintic); `SpiralDrive`, the kernel in a library of its own, dispatched after the
cooling and gated by the same tide and disruption; probe options `--drive`, `--drive-share`,
`--drive-ramp`, `--drive-olr` (the window out to the outer Lindblad resonance instead of
corotation) and `--pattern-share`. One step with the drive and one without, from the same
particles, put its kick within 0.1 % of a CPU evaluation of the same potential, the strongest
in-plane pull at two scale lengths at 5.2 % of the axisymmetric one for 5 % asked, nothing but
disk material touched, and the stars between one and three scale lengths on its crest at
t = 0 (mean cosine of its phase 0.16, what a mass contrast of 0.3 gives). With no drive the
probe reproduces #179's runs to the printed digits (first excursion 12.0 % at 241 Myr, 7.0 % at
273). As in the prototype the drive is a clean logarithmic spiral: the ridge's wander, up to a
radian of arm phase with short leading stretches, is left to the paint.

Where the speeds put the resonances, in scale lengths (inner Lindblad, corotation, outer
Lindblad): Première 0.68, 3.75, 5.35 at 0.5; 0.28, 2.50, 3.80 at 0.8; 0.18, 2.05, 3.20 at 1.0.
Deuxième 0.92, 3.70, 5.25; 0.47, 2.50, 3.75; 0.38, 2.05, 3.15. The drive's pull over the
axisymmetric one, set at two scale lengths, is 1.4 times that near one scale length and 0.6
times at three. Every run drives between the inner Lindblad resonance and corotation, as the
prototype did, but those marked "to the OLR", and the sampler's streaming stays at the painted
0.9 in all of them, so the drive's speed moves alone. In the tables the speed and the strength
are the drive's (0.8 x 10 %: 0.8 of the material's rate, 10 % of the pull); the pattern speed
is the measured m = 2's over the drive's or, with no drive, in brackets, over the material's;
late is the last 500 Myr; late arms is `armsL` and inner a2 `a2in` of `probe-report.py`.

Première:

| drive | coherence, pattern frame | pattern speed / drive's | sigma_R / v_c late | late arms | inner a2, worst | r50, 1 Gyr |
| --- | --- | --- | --- | --- | --- | --- |
| none | 0.05 | (0.90) | 0.153 | 0.268 | 0.46 | -10 % |
| none, seed 2 | 0.02 | (0.90) | 0.173 | 0.371 | 0.44 | -19 % |
| 0.5 x 2 % | 0.04 | 1.53 | 0.154 | 0.290 | 0.33 | -11 % |
| 0.5 x 5 % | 0.01 | 1.75 | 0.157 | 0.274 | 0.38 | -15 % |
| 0.5 x 10 % | 0.17 | 1.38 | 0.170 | 0.338 | 0.43 | -25 % |
| 0.5 x 20 % | 0.13 | 1.26 | 0.182 | 0.398 | 0.40 | -37 % |
| 0.8 x 2 % | 0.11 | 0.92 | 0.167 | 0.361 | 0.32 | -17 % |
| 0.8 x 5 % | 0.11 (2 % over 0.6) | 0.91 | 0.178 | 0.380 | 0.34 | -18 % |
| 0.8 x 10 % | 0.08 | 1.02 | 0.163 | 0.393 | 0.36 | -22 % |
| 0.8 x 20 % | 0.11 | 1.00 | 0.168 | 0.455 | 0.47 | -36 % |
| 1.0 x 2 % | 0.16 | 0.94 | 0.172 | 0.354 | 0.41 | -13 % |
| 1.0 x 5 % | 0.07 | 0.93 | 0.168 | 0.313 | 0.63 | -10 % |
| 1.0 x 10 % | 0.18 | 0.77 | 0.197 | 0.495 | 0.43 | -28 % |
| 1.0 x 20 % | 0.37 (6 % over 0.6) | 0.85 | 0.270 | 0.654 | 0.49 | -26 % |

Deuxième:

| drive | coherence, pattern frame | pattern speed / drive's | sigma_R / v_c late | late arms | inner a2, worst | r50, 1 Gyr |
| --- | --- | --- | --- | --- | --- | --- |
| none | 0.04 | (1.03) | 0.121 | 0.216 | 0.22 | -9 % |
| none, seed 2 | 0.06 | (0.95) | 0.124 | 0.257 | 0.21 | -8 % |
| 0.5 x 2 % | 0.06 | 1.54 | 0.127 | 0.227 | 0.23 | -11 % |
| 0.5 x 5 % | 0.19 | 1.22 | 0.145 | 0.315 | 0.28 | -21 % |
| 0.5 x 10 % | 0.34 | 1.08 | 0.176 | 0.412 | 0.38 | -38 % |
| 0.5 x 20 % | 0.54 (26 % over 0.6) | 1.07 | 0.234 | 0.509 | 0.45 | -47 % |
| 0.8 x 2 % | 0.04 | 1.22 | 0.122 | 0.202 | 0.36 | -10 % |
| 0.8 x 5 % | 0.08 | 1.09 | 0.137 | 0.321 | 0.40 | -22 % |
| 0.8 x 10 % | 0.17 | 1.01 | 0.137 | 0.405 | 0.55 | -29 % |
| 0.8 x 20 % | 0.14 | 1.05 | 0.145 | 0.489 | 0.63 | -59 % |
| 1.0 x 2 % | 0.04 | 0.90 | 0.125 | 0.240 | 0.27 | -12 % |
| 1.0 x 5 % | 0.07 | 0.87 | 0.136 | 0.282 | 0.42 | -19 % |
| 1.0 x 10 % | 0.14 | 0.94 | 0.145 | 0.358 | 0.55 | -29 % |
| 1.0 x 20 % | 0.11 | 0.98 | 0.138 | 0.355 | 0.58 | -51 % |

Second samplings, the window out to the outer Lindblad resonance (OLR), the painted speed, no
cooling (`--dissipation 0`) and a drive ramped in over 100 Myr:

| drive | coherence, pattern frame | pattern speed / drive's | sigma_R / v_c late | late arms | inner a2, worst | r50, 1 Gyr |
| --- | --- | --- | --- | --- | --- | --- |
| Première 0.8 x 5 %, seed 2 | 0.03 | 1.07 | 0.164 | 0.357 | 0.33 | -17 % |
| Première 0.8 x 10 %, seed 2 | 0.05 | 0.99 | 0.161 | 0.389 | 0.38 | -26 % |
| Deuxième 0.8 x 5 %, seed 2 | 0.25 | 1.04 | 0.122 | 0.261 | 0.38 | -20 % |
| Deuxième 0.8 x 10 %, seed 2 | 0.25 | 1.01 | 0.133 | 0.422 | 0.48 | -32 % |
| Deuxième 0.5 x 10 %, seed 2 | 0.34 | 1.08 | 0.177 | 0.410 | 0.36 | -37 % |
| Deuxième 0.5 x 20 %, seed 2 | 0.56 (46 % over 0.6) | 1.14 | 0.241 | 0.472 | 0.55 | -47 % |
| Première 0.8 x 5 %, to the OLR | 0.16 | 0.95 | 0.189 | 0.462 | 0.32 | -20 % |
| Première 0.8 x 10 %, to the OLR | 0.05 | 1.09 | 0.168 | 0.373 | 0.48 | -17 % |
| Première 1.0 x 10 %, to the OLR | 0.08 | 0.92 | 0.161 | 0.373 | 0.43 | -23 % |
| Deuxième 0.8 x 5 %, to the OLR | 0.18 | 1.01 | 0.132 | 0.296 | 0.44 | -22 % |
| Deuxième 0.8 x 10 %, to the OLR | 0.27 | 0.99 | 0.156 | 0.509 | 0.51 | -38 % |
| Deuxième 1.0 x 10 %, to the OLR | 0.21 | 0.96 | 0.139 | 0.462 | 0.49 | -30 % |
| Première 0.9 x 5 % | 0.19 (5 % over 0.6) | 0.90 | 0.187 | 0.465 | 0.35 | -22 % |
| Première 0.9 x 10 % | 0.15 | 1.01 | 0.197 | 0.481 | 0.61 | -25 % |
| Deuxième 0.9 x 5 % | 0.15 | 1.01 | 0.130 | 0.294 | 0.39 | -18 % |
| Deuxième 0.9 x 10 % | 0.15 | 0.95 | 0.147 | 0.448 | 0.51 | -28 % |
| Première, no cooling | 0.30 | (0.55) | 0.200 | 0.141 | 0.27 | -6 % |
| Première 0.8 x 10 %, no cooling | 0.34 (6 % over 0.6) | 0.91 | 0.204 | 0.160 | 0.34 | -8 % |
| Deuxième, no cooling | 0.03 | (0.78) | 0.171 | 0.077 | 0.17 | -3 % |
| Deuxième 0.8 x 10 %, no cooling | 0.57 (55 % over 0.6) | 0.92 | 0.196 | 0.189 | 0.39 | -9 % |
| Première 0.8 x 10 %, ramp 100 Myr | 0.07 | 0.92 | 0.158 | 0.398 | 0.39 | -26 % |
| Première 0.9 x 5 %, ramp 100 Myr | 0.13 | 1.05 | 0.189 | 0.424 | 0.50 | -25 % |
| Deuxième 0.8 x 10 %, ramp 100 Myr | 0.25 | 1.01 | 0.131 | 0.440 | 0.52 | -37 % |
| Deuxième 0.9 x 5 %, ramp 100 Myr | 0.12 | 0.98 | 0.137 | 0.305 | 0.44 | -19 % |

- **Nothing locks the whole disk.** With the cooling on, the coherence in the pattern frame
  stays at 0.01 to 0.37 late on Première and 0.04 to 0.56 on Deuxième, against 0.02 to 0.06
  with no drive. Past a stray frame (6 % of them at most), it reaches 0.6 only at 20 % and half
  the material's rate on Deuxième (a quarter and nearly half of the late frames on two
  samplings), at a heating of 0.23 and 0.24, with a bar (inner a2 0.45 and 0.55) and the disk's
  half-mass radius down by 47 %. The m = 2 the drive raises carries at most two thirds of the
  middle zone's non-axisymmetric power late (13 to 18 % with no drive); the rest is the disk's
  own pattern, which turns with the material.
- **The m = 2's speed follows a strong drive, not a weak one.** At half the material's rate,
  far from the disk's own 0.90 to 1.03, Première's pattern does not follow even at 20 % (1.26
  to 1.75 times the drive's speed: pulled from 0.90 of the material's rate to 0.63 at most),
  and Deuxième's comes within 7 to 14 % of the drive's from 10 % up. At 0.8 and 1.0 a match
  within 10 % is partly the disk's own speed, which sits there already; on Deuxième it holds on
  most late frames from 10 % (on all of them at 0.8 x 10 %), on Première on 0 to 74 % of them
  at any strength.
- **A lock costs the disk its size.** From 5 % the half-mass radius shrinks beyond what two
  samplings of the undriven disk give over the gigayear (-8 to -19 %): -19 to -22 % at 5 % on
  Deuxième (Première's -10 to -18 % at 5 % is inside its own spread), -22 to -38 % at 10 % on
  either galaxy, -26 to -59 % at 20 %, once the drive is in full, after 300 Myr. Deuxième bars
  (worst inner a2 0.48 to 0.63 at 0.8 and 1.0 from 10 %, 0.36 to 0.55 at 0.5, against 0.21 and
  0.22); Première goes lopsided at 1.0 (late a1 0.38 and 0.55 against 0.23 and 0.30). The
  heating stays under 0.18 on Deuxième except at 0.5 x 20 % (0.23 and 0.24); on Première it
  passes 0.18 at 1.0 from 10 % (0.20 and 0.27), at 0.5 x 20 % and at the painted 0.9 (0.19 and
  0.20), and stays under at 0.8.
- **It is the cooling.** Without it the same 0.8 x 10 % drive shrinks the disk by -8 and -9 %,
  as little as the cooled disks do with no drive and close to the uncooled ones (-6 and -3 %),
  and Deuxième's pattern holds (coherence 0.57, 55 % of the late frames over 0.6, the speed
  within 8 %), in a disk that is hot (0.20) and all but featureless (late arms 0.16 to 0.19):
  the cooked disk the cooling was put in against. A
  disk the cooling pulls back towards circular orbits every turn answers a rigid spiral the way
  gas does: its stars lose angular momentum to the pattern inside corotation and fall in, while
  the cooling keeps feeding the disk's own flocculent pattern.
- **Neither the window, the painted speed nor a quick ramp changes it.** Out to the outer
  Lindblad resonance the coherence is 0.05 to 0.27 and the radius -17 to -38 %; at the painted
  0.9, the drive that would ship with the paint, 0.15 to 0.19 and -18 to -28 %. Ramped in over
  100 Myr instead of 400, a 10 % drive raises two arms by 150 Myr (coherence 0.33 and 0.45 then,
  against 0.09 to 0.27 with no drive) and the shrinking starts with them: -9 % at 150 Myr, -12
  to -14 % at 300 and -20 to -21 % at 450, against -2 to -8, -5 to -10 and -2 to -16 % with no
  drive. A drive before a scene's first passage buys a few hundred megayears of two arms on a
  shrinking galaxy.
- **At 2 % nothing moves outside the seed spread**, at any speed on either galaxy (coherence
  0.04 to 0.16, late arms between or next to the two undriven samplings', the radius -10 to
  -17 %), as #171 found at the old painted speed.

**On the sheets** (the disk's own frame from 0 to 1000 Myr, and the last 250 Myr turned back
with the drive so that a pattern turning at its speed stands still), against what "What a real
spiral looks like at this scale" gathered (the reference frames are not in the repository, only
their colours in `references/telescope/`):

- Deuxième driven at 10 to 20 % holds a clean two-armed grand design for the whole gigayear,
  its arms standing still in the drive's frame where the undriven disk's re-form from frame to
  frame: the one look a drive buys, and from a distance an M51 or an M81 without the companion.
  Up close it is neither: its old stars carry arms of 0.36 to 0.51 late, above the 0.15 to 0.3
  of a real grand design, two of them continuous over a whole turn out to the edge where a real
  one breaks into segments past two scale lengths, wound around a core that swells as the disk
  shrinks by a third to a half. At 0.5 x 20 % it reads as a machined early type.
- Première at 10 to 20 % keeps two arms for a few hundred megayears, then goes compact and
  lopsided, with the kiloparsec clumps its second undriven sampling also forms.
- At 5 % and under both read as their undriven selves, Deuxième a little more two-armed.

**Decision: the drive is dropped, and the painted pattern speed stays where #179 put it.** No
speed or strength locks the disk's pattern in the probe's sense. What follows a drive, from
10 % up and on Deuxième, is the m = 2's speed, and at that strength a cooled disk loses a fifth
to a half of its half-mass radius in a gigayear, bars, and carries arms stronger than a real
old disk's. The paint needs no move: the undriven disks turn their own pattern at 0.90 of
the material's rate (Première, both samplings) and 0.95 to 1.03 (Deuxième), within 10 % of the
paint's 0.9. A drive holds a pattern only in a disk nothing cools, which is not the disk
the scenes show; the port stays on its branch should one be wanted there. Whether the driven
grand design would be worth its shrinking for the look alone is Pierre's call, on the sheets of
the pull request.

## Large cool disks break into knots (#218)

The #172 review found the primary of place 11 (seed 20261030, `--pair-share off`: three arms,
scale length 6.15 kpc, response 1.80, Q 1.34 at the explore count) breaking into kiloparsec
knots from 300 Myr, place 3's primary and place 8's second spiral turning flocculent late, and
free-11 knotted at 2 M. The probe now counts the knots (`knots`, `knot_share`,
`calm-disk-probe.md`): peaks of the disk material three times over their ring that still hold
half their members within 0.5 kpc a lag later. A smooth or armed disk keeps 0 to 0.6 % of its
material in them, place 11's primary 12 to 14 %; from about 1 % they show on the stills as
fuzzy kiloparsec blobs strung on the outer arms, and from 5 % as the bright knots of the #172
sheet. Below, knots is the largest share within the 800 Myr of an explore clip and late arms is
`armsL`, which counts a knotted disk's lumps as arms.

**What fragments them is the cooling, drawn in megayears against a turn that grows with size.**
The generators draw a disk's cooling in 180 to 320 Myr whatever its size, and a large disk turns
in 155 to 220 Myr at two scale lengths: place 11's primary sheds its random motion in 185 Myr,
0.85 of its turn. A disk that cools about as fast as it turns behaves as a gas disk that does,
and fragments the way one does: Gammie (2001) puts the line at a cooling time of three over the
angular speed, which for the random velocity this cooling damps is 0.95 of a turn, and later
work found it moving to slower cooling as the resolution grows. The swing-amplified arms are
cooled while they are dense, go unstable along their length and collapse into bound knots the
cooling then binds tighter. #181 had seen the other face of it, a large disk answering more than
a small one at equal response. Place 11's primary, main's draw, one lever at a time:

| place 11 g0 | knots | late arms | lumpiness late |
| --- | --- | --- | --- |
| as drawn, two samplings | 12.2, 14.2 % | 0.467, 0.440 | 1.52, 1.50 |
| arm mass contrast 0.41 to 0.2 | 12.0 % | 0.375 | 1.36 |
| young clumpiness 0.41 to 0.1 | 12.3 % | 0.394 | 1.36 |
| gas 0.29 to 0.15 of the particles | 12.6 % | 0.421 | 1.47 |
| response 2.0 (Q 1.34 to 1.49) | 7.5 % | 0.406 | 1.20 |
| cooling 390 Myr (1.8 turns) | 0.2 % | 0.210 | 0.17 |
| cooling 550 Myr (2.5 turns) | 0.15 % | 0.180 | 0.13 |

The contrast in the mass, the young population's clumps and the gas leave its knots where they
are and a stiffer disk halves them; cooled over 1.8 turns it keeps a multi-armed spiral through
the gigayear with no knot, and over 2.5 turns its arms start to fade.

**Cooled over 1.8 turns, the gas-rich ones still knot in their outskirts.** The gas is 14 to 38 %
of a spiral's particles, each weighing what a star does, laid down 1.4 times wider than the stars,
and the sampler sets every particle's dispersion from one exponential of the stellar scale
length holding the whole disk: by its own profiles, a disk with 0.3 of its particles in gas is
denser at four scale lengths and at its edge than its dispersion was drawn for, its Toomre Q
there 10 to 30 % under the one drawn. Without cooling place 3's primary keeps no knot and no arm
either (late arms 0.08); cooled, its outskirts fragment. Per galaxy, cooled over 1.8 turns
(knots; late arms):

| | gas | as cooled, two samplings | gas 0.15 to 0.2 | response 1.95 to 2.0 | cooled 2.5 turns |
| --- | --- | --- | --- | --- | --- |
| place 3 g0, 5 arms | 0.31 | 4.6, 2.7 %; 0.256, 0.210 | 0.8 %; 0.209 | 2.9 %; 0.250 | |
| place 7 g0, 3 arms | 0.31 | 3.0, 2.4 %; 0.222, 0.289 | 0.16 %; 0.211 | 1.6 %; 0.256 | 1.2 %; 0.209 |
| place 11 g4, 4 arms | 0.35 | 2.3, 2.6 %; 0.236, 0.257 | 0.2 %; 0.207 | 2.2 %; 0.216 | |
| place 4 g2, 4 arms | 0.37 | 2.7, 3.0 %; 0.205, 0.221 | 1.4 %; 0.216 | 0.97 %; 0.184 | 1.8 %; 0.201 |

Lighter gas takes the knots out where a stiffer disk or a slower cooling only thins them, at no
cost to the arms. Drawing less dust would do it too and change the light; the gas is weighed
apart instead.

**What changed**, for the scenes the batch generators draw (`finishGenerated`, `draw` set), once a
companion has its size:

- The cooling drawn in 180 to 320 Myr is held to at least 1.8 turns at two scale lengths
  (`DiskResponse.coolingTurns`, `turn(of:)`, `dissipationTime(drawn:of:)`), with the live halo the
  runs give. A disk turning faster keeps its draw, as half of #181's small spirals do (turns of
  94 to 139 Myr); the light ones among them turn in 175 to 220 Myr and are cooled more slowly too.
- A large spiral of three to five arms (scale length 4.2 kpc or more, #181's line) carries 0.10 to
  0.20 of its disk mass in gas, at the place of its dust draw in 0.14 to 0.38
  (`GalaxyConfig.dustMassFraction`, `DiskResponse.dustMassFraction(of:)`): its dust particles stay
  as many for the light and weigh that share between them, the stars the rest, and the rotation
  curve counts the gas where it lies (`DiskEquilibrium`, `DiskSampler`). A large spiral holds a
  tenth to a fifth of its disk in gas. Two-armed ones keep their gas: weighed apart, the late
  arms of place 10's primary fell from 0.218 to 0.174 and 0.198 and place 16's from 0.168 to 0.146
  and 0.178, the gas carrying the painted wave their arms ride, and none of them knotted once
  cooled over 1.8 turns.

Nothing moves in the stream: places 1 to 16 of seed 20261030 and scenes 0 to 39 of batch
20261031 differ from main's draw by the cooling of the disks held to their turns, the gas share
of the large spirals and, through the curve, a Q solved 0.3 to 0.6 % lower for those of them
drawn for a response. A scene file written before has neither, its gas weighs what its dust does
and it runs its cooling as written.

**At the explore count**, the large spirals of places 1 to 16 and free-3 (batch 20261031 scene
23 g0) and free-11 (scene 11 g0), main's draw against the rule (knots; late arms):

TABLE-EXPLORE

**At 2 M** (one sampling; the explore preview's softening a third, Q solved there for the same
response):

TABLE-2M

**The small spirals of #181** the cooling floor reaches (the gas rule does not), main against the
rule, one sampling each:

TABLE-SMALL

**What is left.** TODO
