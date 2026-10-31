# Why a generated disk takes several turns to settle (spike #170)

The question: why does a freshly sampled galaxy look unnatural at the start of a clip and take
a few turns to find its shape, and what is the cheapest way to start the clip on a settled
galaxy. Measured with the calm-disk probe (`calm-disk-probe.md`) on the two galaxies of
library `2026-10-30-b/scene-0031`, the Antennae draw the complaint came from, at the explore
count (108 000 and 92 000 stars) for 1 Gyr, with the levers of `lumpy-arms.md` run alongside.
The runs are in `library/2026-10-30-b/scene-0031/probe/`.

## What the start is made of

Three things happen at once in the first 300 Myr, and the viewer sees their sum.

1. **The sampler builds Jeans-moment initial conditions**, the same recipe as Hernquist 1993
   and Springel, Di Matteo & Hernquist 2005: the density is laid down exactly, the velocities
   from the second moments (Toomre's radial dispersion, the epicyclic ratio, the asymmetric
   drift, an isothermal vertical dispersion), each Gaussian. Such a model is not a solution of
   the collisionless Boltzmann equation, and every code that builds them sees the same
   transient: density ripples running out through the disk and a readjustment over the first
   100 to 300 Myr (Yurin & Springel 2014; Springel 2005; Cox et al. 2006). The rotation curve
   fix of `breathing-core.md` took the worst of it out; what is left with no arms in the
   particles is a first excursion of the median radius of 6.6 to 6.9 % (`arms-0.0`,
   `smooth-start`), against 5.9 % measured there.
2. **The painted arms have no velocity field.** The stars are placed on a two-armed density
   wave of contrast 0.96 and every one of them is launched on an axisymmetric orbit. A density
   wave in a real disk comes with streaming of a few tens of km/s, inward at the crest inside
   corotation and faster ahead of the arm than behind; without it the wave is an overdensity
   the disk has to answer. It answers by sharpening it (a2 in the middle zone 0.36 at t = 0,
   0.53 at 100 Myr, 0.55 at 400), by winding it into a bar, by heating (sigma_R / v_c 0.135 to
   0.24 at 400 Myr against 0.14 with no arms) and by contracting: the median radius falls from
   8.5 to 7.2 kpc in 400 Myr and 6.0 in a gigayear, 10 % with no arms. The first excursion is
   15 % with the arms (14.5 % with another seed), 10.7 % at contrast 0.6, 14.4 % at 0.8.
3. **The pattern is lopsided on purpose**, 0.30 x irregularity on the ridge, which puts the
   disk's centre of mass off its halo's and an m = 1 of 0.21 in the mass at t = 0. With the
   term off (`irr-0.0`) the first excursion is 8.3 %, half the baseline's; at 0.3, 9.8 %.
4. **The seeded clumps are gone in fifteen megayears** (they carry the disk's dispersion, see
   `lumpy-arms.md`), so they are part of the first frame and of nothing after: clumpiness 0
   still gives a 12.4 % excursion.

The second galaxy (contrast 0.74, irregularity 0.39) breathes by 8.8 and 7.7 %, in proportion.
The knots do not burst at the start: 1 185 form in the first 300 Myr and 812 per 100 Myr late,
when the bar gathers the gas. And "settled" does not arrive: the median radius keeps falling
for the whole gigayear in every run with painted arms (the summary's `settledMyr` is 780 to
1000 Myr or never), so a clip can start on a disk that has stopped ringing, never on one that
has stopped changing.

| run | first excursion | breathing | r50 at 0 / 300 / 1000 Myr | sigma_R / v_c at 300 |
| --- | --- | --- | --- | --- |
| base (Première) | 15.1 % | 16.1 % | 8.52 / 7.25 / 6.04 | 0.21 |
| base, seed 2 | 14.5 % | 14.5 % | 8.19 / 7.48 / 6.90 | 0.18 |
| arms off | 6.9 % | 7.2 % | 8.13 / 7.70 / 7.30 | 0.12 |
| smooth start (arms off, clumpiness 0.12) | 6.6 % | 7.0 % | 8.20 / 7.73 / 7.16 | 0.12 |
| irregularity 0 | 8.3 % | 8.3 % | 8.33 / 7.78 / 7.05 | 0.19 |
| clumpiness 0 | 12.4 % | 12.6 % | 8.30 / 7.39 / 6.44 | 0.21 |
| Toomre Q 2.0 | 14.3 % | 14.3 % | 8.52 / 7.29 / 7.13 | 0.16 |
| disk mass fraction 0.40 | 23.1 % | 25.0 % | 8.52 / 7.55 / 6.38 | 0.30 |
| Deuxième | 8.8 % | 9.8 % | 6.99 / 6.43 / 6.25 | 0.15 |

## The candidates

**Start the orbit earlier, or relax each galaxy alone first.** Both buy the same thing, the
first 200 to 300 Myr run before the clip; the companion's tide at the start of scene-0031 is
weak (Kendall's tidal parameter 0.006 and 0.009 against the 0.01 that makes a grand design,
tidal stress 0.2 against the cooling gate's 0.7), so the galaxies settle alike with it or
without it, and relaxing alone only adds the plumbing of a cached state per particle count. The
cost of settling is the cost of steps: at the explore count a step is 9.3 ms for Première
(15.5 ms at 216 000 stars, 29 ms at 431 000), 5 steps a megayear, so 300 Myr more are 14 s a
galaxy; at the hires count (2 M a scene, 1 078 000 stars for Première) a step is 63 ms for
0.105 Myr, so 300 Myr are 3.0 min a galaxy, 5.5 min for the pair run together (this scene's
own hires record: 112 ms a step for both); at 8 M a scene, where the step stops shrinking at
the solver's floor of 0.044 Myr and costs about four times as much, roughly 28 min a galaxy
(extrapolated). What it buys: a disk past its first excursion (the peak is at 265 to 290 Myr on the
baseline) but already barred and 15 % smaller, still contracting, still heating until 400 Myr.
The pipeline today gives a galaxy 80 Myr of settle and at least 150 Myr of approach before
its first passage: 230 Myr, in the middle of the transient.

**Velocities that carry the painted arms.** The prototype (`DiskSampler.armStreaming` on branch
`spike/167-prototypes`, commit 5ce55af) adds to every disk particle the linear tight-winding
response to the painted wave at the renderer's pattern speed, between the inner Lindblad
resonance and the corotation of that speed, scaled by a knob. At the full painted contrast the
formulas are out of their range (a contrast of 0.96 is not small) and ask for 40 to 50 km/s;
applied at a quarter, a half and in full:

| | base | streaming 0.25 | 0.5 | 1.0 |
| --- | --- | --- | --- | --- |
| first excursion | 15.1 % at 289 Myr | 15.4 % at 297 | 13.2 % at 131 | 10.7 % at 297 |
| r50 at 150 / 400 Myr | 7.53 / 7.18 | 7.49 / 7.71 | 7.46 / 7.57 | 7.74 / 7.60 |
| sigma_R / v_c at 150 / 300 / 400 Myr | 0.199 / 0.213 / 0.239 | 0.202 / 0.158 / 0.181 | 0.193 / 0.145 / 0.170 | 0.175 / 0.140 / 0.159 |
| a2 mid at 400 Myr / late | 0.55 / 0.49 | 0.32 / 0.37 | 0.27 / 0.34 | 0.19 / 0.22 |
| a2 inner at 400 Myr (the bar) | 0.37 | 0.18 | 0.21 | 0.10 |
| a1 mid late | 0.38 | 0.23 | 0.28 | 0.21 |

The field does what the theory says: the wave is held instead of sharpened, no bar forms, the
heating past 300 Myr is halved and the disk stops contracting (r50 7.5 to 7.7 kpc from 150 to
400 Myr instead of 7.5 to 7.2); the first 150 Myr are the same (r50 7.5 at 150 Myr in every
case, the first dip of the excursion), because the field is linear and the painted contrast is
not. With the contrast in the mass lowered to 0.3 (a2 0.15 at t = 0, what a real grand design
carries) the excursion is 8.2 % alone and 9.9 % with the full streaming (heating 0.144 at
300 Myr, a2 0.26 late, no bar, the app's centre within 0.32 kpc of the nucleus); on Deuxième
7.0 % with either against 8.8 (heating 0.118 against 0.150). It costs nothing at run time;
the probe reads the coherent field as 0.01 to 0.03 more dispersion at t = 0, which it is not.

**Start smooth and let the arms grow.** The cheapest calm start (6.6 % excursion, no heating,
no bar) and the one judged airbrushed on its first frame: a featureless exponential disk with
a speckle of knots. Its own structure arrives by 300 to 500 Myr as a flocculent pattern of
three to five arms (a2 0.17 to 0.23), the disk's preferred count, and the outskirts stay
textured; the clip would start on frame 300 to be shown, which is the first candidate again.

## Recommendation

The start looks unnatural for three reasons, in this order: the painted wave with no
velocity field, which sharpens into a bar and contracts the disk by 30 % (a 15 % excursion
against 6.9 with no arms in the particles); the lopsided term in the mass (7 points of it);
and the Jeans-moment ringing of the sampler, 6.6 to 6.9 % peaking at 100 to 240 Myr. The
clumps are a fourth thing only the first frame shows. Of the candidates:

- **Start earlier, or relax alone** buys the first excursion for 14 s a galaxy at explore and
  3 min at hires, and starts the clip on a barred, heated, contracted disk unless the sampler
  is fixed first; so it comes second, and the two are the same thing.
- **Equilibrium initial conditions**: the cheap part, the linear streaming at a lowered mass
  contrast, takes the excursion from 15 to 8 to 10 %, keeps the wave, removes the bar and the
  heating. Iterative builders (GalIC, Agama) would take the remaining 7 % of ringing and cost a
  solver project; not worth it until the rest is in.
- **Start smooth** gives 6.6 % and a first frame judged airbrushed; its own arms come at 300 to
  500 Myr, flocculent, which is the first candidate again.

So: the sampler tickets first (the contrast in the mass at 0.3 with the light keeping its
contrast, the streaming, the lopsided term out of the mass; `old-stars-smooth`,
`arm-streaming` under #167), then a settle of about 150 Myr before the clip at explore and at
hires (one rotation at two scale lengths is 160 to 217 Myr; the arms-off excursion peaks at
99 to 237 Myr), measured again with the probe on the night's draws before the settle is set.
