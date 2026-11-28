# The Antennae, reproduced

NGC 4038 and NGC 4039 (Arp 244), the pair that started Sillage, reproduced from the published
orbits of two papers the way [the Cartwheel](cartwheel.md) and [NGC 2207](ngc2207.md) were: a
scene from the paper, previews scored against the wide picture, the best at 8 M, the freeze with
the picture beside it. Epic #521; everything is in `references/antennae/`. This note grows ticket
by ticket.

## The scene from the papers (#523)

`tools/make_scene.py <out> <karl|privon> [--template scene.json] [key=value ...]` writes
`scene.json` and `view.json` for either model; `karl/` and `privon/` hold them as written with no
override. Without a template the galaxies' look fields (arms, clumps, dust strands) take plain
spiral values; with one, its first two galaxies give them. Overrides: `pericentre`,
`eccentricity`, `pericentreTime`, `i1 w1 i2 w2` (degrees, the papers' angles), `node`, `turn`, `truncation`,
`haloExtent`, `q`, `seed`. `solver` is written `restricted`, so `explore --solver barnes-hut`
places the encounter again with the live halos ([NGC 2207](ngc2207.md) says why). NGC 4038 is
the primary, NGC 4039 the secondary, equal masses, both prograde.

### Karl et al. 2010

ApJL 715, L88 (arXiv:1003.0685), GADGET with live halos and SPH gas, matched on the HI cube of
Hibbard et al. 2001.

| | NGC 4038 | NGC 4039 | in Sillage |
| --- | --- | --- | --- |
| M_vir | 5.52 x 10^11 | same | see below |
| halo | Hernquist, c = 15, r_vir 168 kpc | same | Hernquist, a = 21.46 kpc |
| disk, bulge | 0.075 and 0.025 of M_vir | same | diskMassFraction 0.1154, bulgeFraction 0.25 |
| gas | a fifth of the disk | same | dustFraction and dustMassFraction 0.2 |
| disk scale length, height | 6.28, 1.26 kpc | 4.12, 0.82 kpc | as written |
| bulge scale | 1.26 kpc | 0.82 kpc | bulgeExtent 0.2 |
| (i, w) | (60, 30) | (60, 60) | inclination 60, argument 330 and 120 |

- The halo's Hernquist scale comes from Springel, Di Matteo and Hernquist 2005, eq. 2, the one
  whose inner density is the NFW halo's: a = r_s sqrt(2 (ln(1 + c) - c / (1 + c))) with
  r_s = r_vir / c, 21.46 kpc. Its peak circular speed with the disk and bulge is about the
  paper's 189 and 198 km/s.
- Sillage's live halo carries its whole mass inside `haloExtent` (12 scale radii, 257 kpc);
  Karl's runs on. The halo is given the mass Karl's holds inside that edge (85 %), so the profile
  inside it is his; the potential's mass is 47.85 and the disk's share is raised to 0.1154 to keep
  his 5.52 x 10^10 of stars and gas.
- The orbit: nearly parabolic (eccentricity 1), pericentre 10.4 kpc, from 168 kpc apart. The
  first passage about 600 Myr before the match, the second 560 Myr after the first, the match 40
  Myr after the second and 50 Myr before the centres merge.
- The view: rotations (93, 69, 253.5) degrees about x, y and z; Karl's length scale 1.4 puts the
  system at 30.8 Mpc against the 22 Mpc assumed for the HI data.

### Privon et al. 2013

ApJ 771, 120 (arXiv:1305.5865), Identikit (Barnes and Hibbard 2009): test particles in live halos,
then checked with self-consistent collisionless runs of 64k particles a galaxy. Simulation units
scaled by L = 19.7 kpc and V = 265 km/s, so a mass unit V^2 L / G = 3.22 x 10^11 solar masses and
a time unit L / V = 72.7 Myr.

| | each galaxy | in Sillage |
| --- | --- | --- |
| halo | NFW of scale 0.25 L (4.93 kpc), 80 % of the mass | Hernquist, a = 7.21 kpc |
| bulge | Hernquist, scale 0.02 L (0.39 kpc) | bulgeExtent 0.24 |
| disk | exponential, scale L / 12 (1.64 kpc) | diskScaleLength 1.64 |
| bulge and disk | 20 % of the mass, taken as 1 : 3 | diskMassFraction 0.2, bulgeFraction 0.25 |
| total | 1.25 units, 4.0 x 10^11 solar masses | potential mass 40.21 |
| (i, w) | (65, 345) NGC 4038, (70, 95) NGC 4039 | inclination 65 and 70, argument 15 and 85 |

- The paper gives the halo and baryon shares (80 and 20 %) and 8k bulge against 24k disk
  particles; with equal particle masses that is a bulge a third of the disk, Barnes' usual model.
  Its total, 8 x 10^11 for the pair, gives 1.25 units a galaxy, so the halo is one unit.
- Sillage has no NFW halo. The Hernquist halo holds the Identikit halo's mass inside its edge
  and, with the disk and bulge, the paper's circular speed at three disk scale lengths, 1.26 V =
  334 km/s at 4.93 kpc: a = 7.21 kpc. Beyond that the two profiles part; the NFW halo is tapered
  past a radius the paper does not give.
- The orbit: parabolic, pericentre 0.25 L = 4.9 kpc on the idealised Keplerian orbit of two
  point masses (the extended halos pass earlier and closer, the paper's footnote). Seen 3.62
  units, 260 Myr, after the first passage, around the second, 70 Myr before the merger.
- The disks: no thickness is given; 0.1 of the scale length is written. No gas in the runs; the
  sampler still draws a fifth of the disk as gas, which changes no force without sticky gas.
- The view: (theta_X, theta_Y, theta_Z) = (-20, 283, -5) degrees, read like Karl's.

Both scenes put the first pericentre at 200 Myr, for an approach in the film; `view.json` gives
the papers' moments in the run's time: Karl's view at 800 Myr (merger 850), Privon's at 460
(merger 530).

### The conventions

Toomre and Toomre (1972, section III and fig. 6a) give each disk's orbit as seen by that disk:
i the inclination of the companion's orbit to the disk, w "reckoned in the orbit plane itself
from one of the two nodes" to the pericentre, and "any two orbits whose w's differ by 180 degrees
are logically equivalent, except for a trivial reversal of the z-coordinate". Karl cites them;
Privon reads i as the angle from the orbit's axis to the disk's spin and w as the spin's
longitude from the line of nodes at pericentre, and points to the same figure. Neither says which
node. In a frame with z along the orbit's angular momentum and x towards the companion at
pericentre, w counted along the motion:

- from the descending node (where the companion goes down through the disk, away from the side
  its spin points to), s = (-sin i sin w, -sin i cos w, cos i);
- from the ascending node, s = (sin i sin w, sin i cos w, cos i), the same disk turned half a turn
  about z. Seen from near the orbit plane, as both papers see the Antennae, it draws nearly the
  mirror image.

The descending node is the default (`node=ascending` gives the other), on the first look below.
Each disk has its own companion, so the secondary's frame is the primary's turned half a turn
about z: TT72's own Antennae, (60, -30) for both disks, makes two equal tails only so. Sillage
counts both disks' `argument` from the line that runs from the primary to the secondary at
pericentre, with the axis (sin i sin a, -sin i cos a, cos i): a = -w for the primary and
180 - w for the secondary (from the ascending node, 180 - w and -w). Prograde at 60 degrees is a
spin half along the orbit's angular momentum, cos 60, turning with the orbit; Sillage's
`prograde` is the axis's own sense.

`Tests/SillageCoreTests/ToomreAnglesTests.swift` checks it: w = 0 and w = 90 worked by hand for
both disks and both nodes, the stars of a sampled disk turning about the spin and half along the
orbit, and the two scenes on file giving the papers' spins.

### The view

Both papers turn the simulation about x, then y, then z (R = Rz Ry Rx) and project on (x', y').
Both draw their sky panels with x' to the right and y' up, north up, and in both the southern
tail's tip lies to the right, to the west as on the sky (Hibbard et al. 2001: the tail's base in
the south-east, its tip by ESO 572-G045 to the south-west). So x' is west and z' is towards the
viewer: the `sky` view in `view.json`. `mirror` reads x' as east and z' away, its mirror image.

Neither paper says where its pericentre lies in its frame. `turn` in `view.json` is the angle
about z from Sillage's pericentre line (NGC 4038 to NGC 4039) to the paper's x: 0 for Privon,
180 for Karl, both from the first look (with 0, Karl's NGC 4038 throws its material north, not
south). It is the least sure of the guesses: `match --view` with a wide `--span` should search
round it.

| | elevation | azimuth | roll |
| --- | ---: | ---: | ---: |
| Karl, sky | -1.1 | 69.0 | -70.7 |
| Karl, mirror | 1.1 | 249.0 | 70.7 |
| Privon, sky | 12.2 | 85.5 | -64.5 |
| Privon, mirror | -12.2 | 265.5 | 64.5 |

Both look along the orbit plane, within 12 degrees of it.
`Tests/SillageRenderTests/PaperViewTests.swift` projects a lopsided set of points the papers' way
and through `match`'s camera at each guess, and checks they draw the same picture and that the
two readings do not.

### A first look in the cloud

The engine runs on the CPU in the cloud at 7 s a frame for 20 k particles, too slow for a whole
story, so `tools/first_look.py` stands in: test particles in the two galaxies' rigid mass profiles
(the scene's), the centres on their mutual orbit with a drag inside 80 kpc that brings the second
passage near the paper's (260 Myr after the first for Privon, 560 for Karl), drawn from the
paper's view on its sky. It is only there to catch a tail on the wrong side; the live halos'
orbit is #524's.

- Privon, descending node: NGC 4038's tail runs south and NGC 4039's north, slightly east, as in
  his figure 6a; the turn to the west at the southern tail's end is missing. The ascending node
  draws them south-east to north-west and south-west to north-east, the mirror.
- Karl: his large disks (6.3 kpc in scale length) spread into fans under the crude drag; with the
  pericentre line turned by 180 degrees NGC 4038's material lies south and NGC 4039's north, as
  in his figure 1, the descending node a little closer (the southern fan leans west). Neither
  reading draws his long thin tails; the live halos have to.

The sheet, the papers' sky panels on the left: project file
`antennes/premier-coup-d-oeil-523.jpg`. #524 should run both nodes for both models at 200 k (four
previews) before choosing.

### What Sillage cannot hold as written

- No gas pressure, shocks or star formation feedback: Karl's overlap starburst and his timing
  argument, which rest on them, are out of reach. The gas is particles that move like stars.
- Halos: Hernquist only, cut at `haloExtent`; Karl's mass beyond 257 kpc and Privon's NFW shape
  beyond a few scale lengths are not there.
- Softening: Sillage's comes from the sparsest disk at the run's particle count, near a
  kiloparsec at a preview's, against Karl's 35 pc; Privon's 1.64 kpc disks will be soft at 200 k.
- Live halos drag: a placed pericentre lands closer and later than asked; the papers' times
  since the first passage are measured on their own runs, so the moment is found by the match,
  not set.
- The look fields (arms, dust strands, clumps) are not in either paper.

## The orbit's clock in live halos (#524)

Both scenes as written by #523, both readings of the node, explored at 200 k as whole stories
(`--story-cap 3000`) and run at 500 k with `--sticky-gas on`, then the adjustments, one change a
run. Each run costs about four minutes on the M4 Max (explore 30 to 80 s, hires 2 to 4 min).
`tools/clock.py` reads every pericentre, the merger (the separation stays under 3 kpc) and the
settling (the extent within 5 % of its final value from then on) off `curves-hires.csv`.

| run | change | 1st passage | between the passages | merger after the 1st | settled | window match | free match |
| --- | --- | ---: | ---: | ---: | ---: | --- | --- |
| Karl, descending | as written | 202 (8.8 kpc) | 820 | 986 | 1348 | 0.563 at 1067 | 0.550 at 197 |
| Karl, ascending | node | 203 (9.2 kpc) | 836 | 1004 | 1372 | 0.549 at 1096 | 0.550 at 159 |
| Karl | `haloExtent` 20 | 202 | 893 | 1060 | 1312 | | |
| Karl | eccentricity 0.9 | 202 | 377 | 499 | 759 | | |
| **Karl** | **eccentricity 0.95** | 202 (8.6 kpc) | **533** | 672 | 929 | **0.572 at 779** | 0.566 at 798 |
| Privon, descending | as written | 201 (3.7 kpc) | 150 | 165 | 659 | 0.442 at 241 | 0.578 at 440 |
| Privon, ascending | node | 201 (4.0 kpc) | 153 | 168 | 814 | 0.469 at 352 | 0.562 at 412 |
| Privon | `haloExtent` 6 | 200 | 134 | 146 | 662 | | |
| Privon | `haloExtent` 20 | 200 | 149 | 162 | 584 | | |
| Privon | eccentricity 1.05 | 200 | 210 | 228 | 636 | | |
| Privon | eccentricity 1.2 | 200 | 1655 | 1693 | 2216 | | |
| **Privon** | **eccentricity 1.1** | 200 (3.9 kpc) | **334** | 358 | 753 | 0.458 at 364 | 0.559 at 612 |

Times in Myr of the run. The papers: Karl 560 Myr between the passages, the picture 40 after the
second and about 90 before the merger; Privon the picture 260 after the first, 70 before the
merger (330 after the first).

- **As written, both clocks are far off, in opposite directions.** Karl's pair swings out to
  64 kpc and comes back 820 Myr later; Privon's falls together within 165 Myr. The node
  changes neither clock by more than 2 %, nor the scores by more than 0.03.
- **The halos' extent is not the lever.** Karl's halo cut at 20 scale radii instead of 12 (the
  mass Karl holds past 257 kpc) slows the return by 9 %; Privon's at 6 or 20 moves its merger
  by 10 %. The eccentricity is: Karl at 0.95 gives 533 Myr between the passages (the paper's
  560), Privon at 1.1 a merger 358 Myr after the first passage (the paper's 330). Neither paper
  is strictly parabolic in live halos: Karl's GADGET halos run on past the virial radius and
  bind the orbit more than Sillage's cut halo, and Privon's Identikit orbit is parabolic for two
  point masses, while his halos pass closer and earlier.
- **Karl's clock holds the match.** At 0.95 the window match lands 43 Myr after the second
  passage, the paper's 40, and the free match over the whole take also chooses a moment after
  the second passage (798 Myr), not the plain disks before the first: the trap of the NGC 2207
  note does not catch it. Its view, (21, 86, -109), is 24 degrees from the paper's sky guess.
- **Privon's free match prefers the merged remnant.** Every Privon free match picks a moment after
  the merger, one body with two tails; inside the window it scores 0.44 to 0.47, the two bodies
  with short tails.
- **The future.** Karl at 0.95 merges 95 Myr after the paper's moment and settles 150 Myr after it
  (929 Myr, 31 kpc across), the tails still falling back; the take ends 294 Myr after the paper's
  moment. #526 records up to the settling, 929 Myr.

### The tails

`tools/tails.py` bins the take's stars on the wide map's grid from the match's view and scale and
reads the two tips the same way on both (the bins 1.6 decades under the 99.5th percentile, joined
to a nucleus; the farthest 1 % of them north and south of the nuclei). The picture: north tip 48
kpc at position angle 34, south tip 67 kpc at 218 (from the nuclei's middle).

| run | moment | north tip | south tip |
| --- | --- | --- | --- |
| Karl 0.95, window | 779 | 11 kpc at 298 | 28 kpc at 160 |
| Karl 0.95, free | 798 | 30 kpc at 44 | 16 kpc at 250 |
| Privon 1.1, window | 364 | 27 kpc at 35 | 45 kpc at 190 |
| Privon 1.1, free | 612 | 24 kpc at 43 | 23 kpc at 228 |

Karl's tails are long (99 % of each galaxy's stars within 114 and 99 kpc of the middle) but
spread thin, so above the picture's threshold they read short; Privon's point the right way and
are bright but short, from disks of 1.64 kpc. The figures are rough: the picture's tone curve is
not the binned count's.

### The choice: Karl at eccentricity 0.95, descending node

Pierre left the choice to the night (2026-11-27). The sheet (`sheet-524-models.jpg` on the
`assets/antennae` branch) shows each model at its matched moment from its matched view beside
the wide picture, then a strip from the paper's view: the approach, both passages, the merger,
the settled remnant.

- Karl draws the Antennae's two long thin curved tails; Privon draws two compact bodies with
  short ones, and its Antennae-like tails only after the merger.
- Karl's clock matches its paper with one change, and its match falls at the paper's moment.
- What is wrong with Karl: the heart is too big, about 30 kpc against the picture's 12, from
  disks of 6.3 and 4.1 kpc in scale length, and the tails curve too wide. #525 varies round it;
  the disks' size and truncation are the first levers.

Scripts: `tools/clock.py`, `tools/tails.py`, `tools/view2key.py` and `tools/photokey.sh` (a still
from a match, cropped to the panel), `tools/sheet.py`.

## Hundreds of previews, a preselection of the score (#525)

Round Karl at eccentricity 0.95 (#524), over the eight parameters that move the tails: the
pericentre (7 to 14 kpc), the eccentricity (0.92 to 0.98), both disks' inclinations (40 to 80
degrees) and arguments (0 to 60 and 30 to 90), the mass ratio (0.8 to 1) and both disks' size
(`diskScale`, 0.5 to 1, a new override of `make_scene.py` with `massRatio`). The halos' extent is
left out: #524 found it moves the clock by a few percent.

**The size.** On three scenes, 200 k gives the 500 k clock within 2 %, and the free match's
moment within 6 Myr and its view within a few degrees, with the same ranking; 100 k moves the
second passage by 6 % and its match off. Each scene is explored at 200 k as a whole story, run at
200 k with sticky gas and matched: 1.6 minutes, the matches off the GPU while the next scene runs.

**The rounds**, one night on the M4 Max (2026-11-27 to 28), by `tools/sweep.sh` and
`tools/rounds.sh`, rows in `sweep.csv`:

| | scenes | rule 1 drops (free match outside the window) | rule 2 drops (turns the wrong way) | kept |
| --- | ---: | ---: | ---: | ---: |
| round 1, a Latin hypercube | 220 | 81 (7 plain disks, 74 the merged remnant) | 62 more | 114 |
| round 2, 10 round each of the best 5 families | 50 | 0 | 6 | 44 |
| the best 30 again at 500 k, another seed | 30 | 1 | 0 | 29 |

The window runs from 20 Myr after the first pericentre to the merger, so the picture's two nuclei
are still apart. Rule 2: seen from the matched view, the disk on the north nucleus turns clockwise
and the southern one counter-clockwise, as both papers' models do from their own views (the
spin's share towards the viewer: Karl -0.33 and +0.60, Privon -0.11 and +0.91). Rule 3: the 29
survivors are grouped in families (closer than 0.25 rms in the unit hypercube), at most four a
family; a scene whose score moved between its 200 k and 500 k runs by more than its lead over the
last one kept is flagged noisy. Seven families at four a family give 17, not 25: round 2 packed
its scenes round five families.

**What the score follows** (`plots-525.png`): the pericentre above all, closer is better (0.62 to
0.66 under 9 kpc, under 0.58 past 12), then a lower eccentricity. The inclinations, arguments,
mass ratio and disk size spread the score without a trend. The best scenes sit at the bottom of
the pericentre's range, so a round below 7 kpc is worth a try. Every finalist lands 43 to 54 Myr
after the second passage, Karl's 40.

### The choice: number 2, r2-2-03-05

Pierre left the choice to the night. The sheet (`sheets/sheet-525-25.jpg` on `assets/antennae`):
the panel, the 17 finalists at their matched moments and views, and the approach, the first
passage and the matched moment of the best five.

Number 2 rather than number 1 (0.663, same family): its score holds between the two seeds (0.661
at 200 k, 0.660 at 500 k, against 0.643 and 0.663), and it draws the same thing: the northern tail
rising and bending as in the picture, the southern one long and curving west, two bodies apart in
the heart. Pericentre 8.03 kpc, eccentricity 0.931, inclinations 67.2 and 47.3, arguments 13.2
and 39.0, mass ratio 0.859, disks 0.826 of Karl's, seed 20261128. In its run: first passage 202
Myr (6.0 kpc), second 562, matched at 608 (46 after the second; elevation 18, azimuth 103, roll
-85), merger 636, settled 709. Its tails: north 30 kpc at position angle 55, south 46 kpc at 191,
against the picture's 48 at 34 and 67 at 218. Written as `references/antennae/scene.json`.

What it still misses: the heart is rounder and bigger than the picture's two bright bodies, the
southern tail opens into a fan on its outer side, and the second passage comes 360 Myr after the
first, not Karl's 560: the closer, more bound orbit that matches best is also faster.

## The 8 M take (#526)

`references/antennae/scene.json` (#525's number 2) at 8 M visible, all massive, and 12 M of halo,
sticky gas, from 148 to 847 Myr: the approach, the first passage at 202, the second at 565, the
merger at 635 and the remnant settled at 704 (23 kpc across), the tails still falling back. The
whole story fits; no coarser cadence was needed. Cost on the M4 Max (2026-11-28): 4 312 s (the run
estimated 1.2 h), peak 6.1 GB, a 14.4 GB take, step 0.088 Myr. The take is on the Mac in
`~/claude-workspace/antennae/lib/antennae-8m`.

At 8 M the clock moves little: the first pericentre at 6.14 kpc against 6.0, the second 3 Myr
later, the merger 1 Myr earlier.

**The match** (`match.json`), scale held at 102.5 kpc, from the 500 k match's moment and view
with `--within 100`: 0.663 at 614.5 Myr, 6 Myr later than at 500 k, elevation 20.7, azimuth
102.2, roll -83.2 (2 degrees from the 500 k view). The free match over the whole take lands on
the same frame and view.

**Hubble's framing** (20.9 kpc across). Held at the wide match's moment and within 20 degrees of
its view, `heic0615a` scores 0.609: the heart from there is one round body with its dust. Free
within 60 Myr, it scores 0.770 at 592 Myr from another view (elevation -8, azimuth 133, roll -48;
`match-hubble.json`): two bodies apart, NGC 4039's below with its lane, as in the picture. The
film's close-up (#527, #528) has to choose: freeze on the wide match and close in on a heart that
does not look like Hubble's, or freeze about 22 Myr earlier, where the wide picture scores
lower and the heart matches. The stills of both went to Pierre.

The stills (`assets/antennae`, `stills-526/`): the wide match in the `photograph` look beside the
panel, both Hubble framings beside `heic0615a`, and the merger, halfway and the settled remnant
from the wide view.

## Both pictures at once (#525, #526 again)

Pierre (2026-11-28): the right candidate matches both pictures, the wide one and Hubble's, each at
its own zoom and framing, at the same moment. `tools/both.py` scores the 30 finalists' 500 k takes
so: Hubble's `heic0615a` (20.9 kpc across) matched over the same window as the wide panel, the
moment where the mean of the two curves peaks, then both matched again there, Hubble's within 15
degrees of the wide view's direction. The two pictures look from the same place, and Hubble's frame
turns 30.6 degrees on the sky (#522); the match takes the roll freely, so the roll difference is the
check: 8 of the 29 land within 12 degrees of it, the other 21 fit Hubble's frame only turned some
other way. Rows in `both.csv`.

Among the 8, **B, r2-2-03-02** (same family as number 2, pericentre 7.1 kpc, eccentricity 0.930,
inclinations 67.6 and 46.1, arguments 8.4 and 31.8, mass ratio 0.856, disks 0.888, seed 20261128)
has the best wide score, 0.604, with Hubble at 0.728: two bodies one above the other, both tails.
A (r1-1-140) has the best mean, 0.669, but on Hubble's score (0.778) with the wide one at 0.559.
The sheet is `sheets/sheet-525-both.jpg` on `assets/antennae`. `scene.json` is B's now.

**B's 8 M take**: 148 to 823 Myr, 2 956 s, 13.9 GB, in `~/claude-workspace/antennae/lib/antennae-8m-b`
on the Mac; first passage 201 Myr (5.4 kpc), second 535, merger 601, settled 675. Alone, the wide
panel matches best at 580 Myr (0.667, the free match agrees) and Hubble best at 564 (0.773), but
neither with the other's direction. Scanned between them, the moments where Hubble's frame lands
at the sky's turn are 570 and 573 Myr; **573.3** is kept (`match.json`: wide 0.650, elevation 8.8,
azimuth 121.9, roll -97.8; `match-hubble.json`: 0.673 within 15 degrees of it, roll -59.9, 38
degrees from the wide one), 38 Myr after the second passage (Karl's 40) and 28 before the merger.
The film freezes there. Stills in `stills-526b/` on `assets/antennae`.

A match option that holds Hubble's roll to the wide one's plus the sky's 30.6 degrees would make
this a single search instead of a scan.
