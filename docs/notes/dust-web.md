# A web of dust that turns without tearing (spike #173)

Pierre pictures dust as fine interlaced filaments, like a spider web, turning with the galaxy
(faster near the centre) without tearing all the time, so the overall structure holds. On the
2026-10-30-b night it read as coarse blobs. The question: can dust be drawn as such a web, and
still follow the material where an encounter tears a disk, at a frame cost worth paying.
Three candidates were built and compared: a web of filaments carried by the rotation curve and
renewed before it shears (1), finer particle dust (2), and the web where the disk is intact with
particle dust where it is torn (3). Answer: (3), merged behind the look field `dustWeb`, off by
default. The sheets and 1:1 crops are on the branch `assets/173-dust-web`.

## What the dust is made of now, and why it reads as blobs

A disk draws 14 to 38 % of its particles as dust (`dustFraction`), laid down on the inner edge
of the arms in a layer under half the disk's thickness. Each grain is a Gaussian splat 1.3 times
a star's kernel, whose width is the three-dimensional spacing read off the solver's tree, and
its opacity is multiplied by the lane factor read at the grain's centre: one, plus seven times
the squared arm wave, times `laneDetail` (two octaves keyed on the wound angle, in the pattern
frame, see [gas filaments](gas-filaments.md)). So the finest dust there is, is one grain. Seen
face-on a thin layer stacks few grains per kernel ([gigantism](gigantism.md)), and at 2 M a dust
clump comes out as a dark blot ringed with orange specks, each speck a star dimmed by one grain;
along the arms the lanes are broad orange smears.

What failed before, and what a web has to avoid (`gas-filaments.md`): filaments taken from the
complexes made a mat that lost the arms; strands stretched round the azimuth made rings; strands
laid along the spiral were sheared away within an orbit, as anything carried by the material
must be. Hence the bounded-shear construction: a texture carried by the flow only for a bounded
time and cross-faded with a fresh one (Max and Becker 1995, Neyret 2003).

## The test bed

- **An isolated calm disk.** Première of `2026-10-30-b/scene-0031` alone, moved onto the calm
  disk of #172 (clumpiness 0.05, the young population at 0.5, mass contrast 0.3, streaming,
  a tenth of the lopsided term, the paint at 0.9 of the circular rate), Toomre Q 1.33, scale
  length 5.55 kpc, a third of its disk drawn as dust, laid face-on in the xy plane. 2 M particles
  and a live halo of 3 M, a step of 0.074 Myr, 2000 steps settled (149 Myr) and 4200 captured
  over 312 Myr, 300 frames, one in two kept (1.9 GB). 38 min on a GPU shared with five other
  jobs. It turns once in 45, 70, 117, 217, 334 and 471 Myr at 0.25, 0.5, 1, 2, 3 and 4 scale
  lengths, so the captured stretch is a turn and a half at two scale lengths. Seen face-on
  (elevation 1.52), at 60 degrees and edge-on, framed 22 kpc.
- **The encounter** `2026-10-30-b/scene-0031` at 2 M, and `scene-0030` at 8 M for what more
  grains buy. Both are scenes from before the calm disk.
- **Hand-made looks**: Hubble (dust 0.45), Webb (0.08) and Braise poussière (`ember-dust`,
  0.35), drawn at 4K. #174 keeps dust out of the generated styles meanwhile.

`scripts/dust-web-sheet.py` lays the stills out, `scripts/dust-web-metrics.py` splits a still's
dust structure by scale against the same still drawn with no dust.

## Candidate 1: the web

**The field.** A lace in each disk's own plane, in cells of 0.18 scale lengths (1.0 kpc for
Première, held between 0.4 and 1.6 kpc): the plane is warped by a slow noise (up to 1.1 cells),
then ridged noise of three octaves, each weighted by the ridge above it, gives threads that
branch, Voronoi walls drawn each at a strength of its own give membranes that never close into a
honeycomb, and a slow noise opens clear holes. Divided by its mean. Crackle glaze, soap foam and
plain ridged veins were tried on the CPU first and read as exactly that; the mix is what reads as
dust. A quarter of the dust is kept even under it: without that, a dense clump opens onto
whatever bright knot it holds and the inner disk burns white. What is left puts 40 % of the dust
in the densest fifth of the area, a median of 0.81 of the mean and a 95th percentile of 2.2.

**Carried round, never wound up.** Each point of the lace is turned back by the disk's own angular
rate at its radius times the time since its copy rested, so the web turns with the material, the
centre faster than the edge. The rate is the equilibrium rotation curve of the galaxy
(`DiskEquilibrium.circularSpeed`) sampled at eight radii from a quarter to nine and a half scale
lengths; the probe's measured rate of the material in the middle zone sits at 0.83 to 0.97 of
the curve at two scale lengths, and the zone is centred a little further out, where the curve is
lower, so the two agree to a few per cent and the web drifts from the matter by a tenth of a
radian at most before it is renewed. Two copies run half a period apart, each fading in and out
as sin squared, so their weights always sum to one; dividing their mixed deviation by the root
sum of the squared weights keeps the contrast through the cross-fade. A copy rests unsheared a
quarter of the way into its life: both copies of any cross-fade then lean the same way, where a
rest at half life made them cross-hatch at the half-way blends. Every renewal draws the lace
from a fresh offset, so no moment repeats. The period is a quarter of a turn at two scale lengths
(54 Myr for Première, a renewal every 27 Myr): a third left long straight streaks in the inner
disk, where the shear is strongest, and a fifth made the web boil.

**Per fragment, thinner than a grain.** Each grain's splat reads the lace at the point where the
ray through each of its pixels meets the disk's mid-plane, which is the same point whichever
grain the pixel belongs to, so overlapping grains draw one web and an inclined disk shows it
foreshortened. Past 75 degrees the stretch is capped. Where a wall would be under two
accumulation pixels the lace fades to its mean rather than shimmer. Sparse grains would show the
web only inside their own blots, so a grain under the web is drawn twice as wide (its column
kept): the grains merge into one layer and the lace, not the grains, says where the dust is thin.

**Only on a disk.** The web is weighted by how intact the solver says the disk is (`1 -
disruption`, the measure that already fades the painted arms), by how near the plane a grain is
(full within 0.3 scale lengths, none past 0.8: a disk an encounter has begun to warp keeps it), by
being inside 5 to 7 scale lengths, and by the view: it fades out between 70 and 83 degrees of
inclination, so edge-on draws what it always drew. Its own pipeline (`dustWebVertex`,
`dustWebFragment`), chosen only when `dustWeb` is above zero.

## Candidate 2: finer particle dust

Grains drawn at half a star's kernel at the same count (a spike-only knob, not merged): the
same column on a quarter of the area, so fewer pixels see dust and each sees four times more.
Face-on the clumps turn to sand, the lanes thin out and the frame brightens, since
`exp(-tau)` rewards the gaps; at 1:1 it is the speckle of today, finer. More grains are the other
half of this candidate and need a run: the 8 M take of scene-0030, before its passage, draws
grains 1.6 times finer and four times denser. The speckle is finer and the dust gathers into
compact dark knots, but it is still grains, and it still shears with the matter, which no count
changes (`enc8.jpg`).

## Candidate 3: the web where the disk is intact

Candidate 1 as built is already this: the web is weighted by intactness and the envelopes, and
where they fall to zero the grains are back to their own width and their painted lane, which is
today's dust. In scene-0031 the solver flags the two disks disrupted from 270 and 280 Myr, fully
by 285 and 292 Myr, before the pericentre at 304 Myr, and the web fades out over those 15 Myr
with the painted arms. Drawn on the torn disks anyway (candidate 1 strictly, a spike-only switch),
at the pericentre the web lays a clean swirl over the collision, a rotation the torn material no
longer has; by 400 Myr the envelopes alone drop most of the torn dust and it changes little.

**Takes written by `hires` carried no disk state.** The command line handed the take its
positions and centres but not the solver's `diskFrames`, so every take of the library reads as
intact on every frame (the app's own takes were fine). The painted arms never faded in a look,
an export or the editor, and the web would not either. Fixed here for every take written from
now on; the takes already in the library still read as intact, and the encounter sheets of this
spike read the disruption back from `curves-hires.csv`, which the same run wrote correctly.

## What they look like

- **Face-on and at 60 degrees** (`disk-angles.jpg`, `disk-crops.jpg`): the web turns the blots
  and specks into dark filaments with tendrils, a fine brown lace over the inner disk and loops
  round clear holes; the lanes along the arms become filamentary. The inner disk is brighter
  and less orange than today, since uniform dust reddens everything a little and a web leaves
  gaps. At 60 degrees the inner filaments are stretched along the major axis by the shear and the
  foreshortening together, which is how inclined real disks show their lanes.
- **Edge-on**: the same as today by construction.
- **Depth slabs**: the web writes into the same four slabs, so a star behind a filament is dimmed
  and one behind a hole is not, at the pixel; nothing else changes.
- **Télescope renderings** (`disk-looks.jpg`): Hubble shows the web best, its dust being the
  strongest; Webb's dust (0.08) is faint either way, and its glowing dust is still not drawn
  (dust here only absorbs). Braise poussière takes it as Hubble does.
- **Over a rotation** (`disk-rotation.jpg`, the camera turning at the material's rate at two
  scale lengths, 8 frames 16 Myr apart): today's dust holds where the paint holds it and its
  grains shear into arcs between; the web keeps the same character through the turn, gathered in
  the arms, its filaments fading and coming back every 27 Myr, never stretched past a quarter turn
  of shear.
- **The cross-fade does not show**: over 80 consecutive frames (83 Myr, three renewals), face-on
  with no film noise, the frame-to-frame change is 13.3 levels with the web against 13.1 today
  (the particles' own motion), and its largest step from one frame to the next 0.12 either way.
- **The encounter** (`enc.jpg`, `enc-crops.jpg`): before the passage the approaching disks show
  the web where today shows orange speckle; from 285 Myr the hybrid draws exactly today's dust,
  and the web on the torn disks a swirl that does not belong there.

## What it costs

TODO

## Recommendation

Candidate 3, the web where the disk is intact, as merged: `dustWeb` (0 to 1, default 0, the
editor's and the panel's "Toile des poussières", `sillage-render --dust-web`). It is the only one
that draws dust as a web, it holds its structure over a turn because nothing it draws lives
longer than a quarter of one, and it gives the torn material back to the particles, which follow
the tear. Finer grains alone make sand; more grains (8 M, now the night's hires) make finer
grains, not a web. Whether the look is right is Pierre's call on the sheets, or in the editor on
any take.

What it does not do: the web is not the material, so it does not tear with an encounter; it
fades out instead, as the painted arms do, and torn dust stays as coarse as the grains. And the
brighter inner disk is a real effect of clumpy dust (the same column lets more light through
in filaments than spread evenly), which a style that turns the web on may want to take back with
its brightness or white point.

Follow-ups, opened under #168: TODO
