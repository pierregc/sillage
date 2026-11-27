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
