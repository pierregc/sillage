# The Sombrero, reproduced

Rank 18 of [twenty galaxies to reproduce](twenty-galaxies.md), issue #478. A galaxy alone, no
encounter: what makes it hard is the dust ring, the bulge and the eye, not an orbit. Everything is
in `references/sombrero/`: the scene, the look, the flight and the tools that measured each step.
What it took is told in the order it was found, because almost every wrong turn looked right at
the time.

## What is known of the galaxy

- Distance 9.55 Mpc (McQuinn et al. 2016, TRGB): 1 arcsec = 46.3 pc.
- The dust ring: Bendo et al. 2006 (ApJ 645, 134, table 3) fit it at 145 arcsec, 6.7 kpc at this
  distance, with a Gaussian sigma of 23 arcsec, 1.06 kpc. The inner dust disk's scale length is
  2.2 kpc. Hubble's lane is darkest 0.71 kpc under the core and reaches 8.8 kpc at its ends.
- Flat rotation about 350 km/s (300 to 350 from the globular clusters, 376 asymptotic in Jardel
  et al. 2011).
- The bulge holds most of the light. Gadotti and Sánchez-Janssen 2012 show its share depends on
  whether a separate halo is fitted, so it was set on the picture, not on a paper.
- Seen 6 degrees from edge on.

## The picture

`references/catalogue/images/heic2506a.jpg` (ESA/Hubble & NASA, K. Noll, CC BY 4.0). The full
size (14 319 px) comes from esahubble.org. **Its field is 9.54 by 5.65 arcmin, so the frame is
26.5 kpc across, not the 21 a first estimate from the ring gave**: always read the field of view
from the archive's page before measuring anything. The flight keys frame it at 6 degrees above
the plane, rolled 5.6 degrees, the core at (504, 312) of 1024 by 606. A wider SDSS picture (23.4
by 14.7 arcmin, 65 by 41 kpc) gave the bulge's crown.

## The scene

`references/sombrero/scene.json` (first written by `tools/make_scene.py`, then edited by hand). One
spiral galaxy alone, a Hernquist halo of 10^12 solar masses and 20 kpc with a fifth of it in stars,
a bulge of 0.75 of the stars (bulgeExtent 0.98, 2.15 kpc for a 2.2 kpc disk; flattening 0.70), the
stellar disk cut at 3.9 scale lengths. Each field below was added or set to remove one fault:

| field | value | fault it removes |
|---|---|---|
| `bulgeApart` | true | the disk was launched on the bulge's surface density too, four times too high, so the ring fell 2 kpc inward during the settle (#482); with the bulge counted as flattened, the last 0.7 kpc |
| `bulgeReach` | 9 | the bulge cut at 6 scale radii showed as an elliptical edge; cut at 9, faded from 0.4 of the reach to nothing, no edge in the 65 kpc wide frame |
| `nucleus` | 0.006 | no point core: that share of the bulge drawn as compact old stars (component star, kernelScale 0.75, a third of the bulge's speeds), so `bulgeWidth` does not spread it |
| `recentStars` | 0 | the disk's young stars, drawn at narrow young kernels, sparkled; the Sombrero's disk is old |
| `dustRing.innerWidth` | 2.0 | a hoop of dust; now dust that thickens to its rim and thins inward |
| `dustRing.thickness` | 0.02 kpc | the dust layer was launched with the stars' height, so threads smeared into a band seen 6 degrees from edge on |
| `dustRing.threads` | 700 | 700 short squiggles stacked into bands; now long threads that cross and part |
| `dustRing.young` | 1.0 | the young regions stand on the threads' rim, not scattered over the disk |
| `dustMassFraction` | 0.004 | cold, heavy threads beaded under their own gravity by 30 Myr |
| `toomreQ` | 3.5, no `effectiveToomreQ` | the scene's effectiveToomreQ was solved every run to the floor of 1.05 under bulgeApart and the disk grew arms; written plainly, and hot enough that the disk stays smooth over 450 Myr |
| `clumpiness` | 0 | the 110 complexes seeded the swing amplification |
| `starFormation` | 0 | a third of the dust grains formed stars and were drawn as bright knots along the threads |
| `armCount`, `armStrength` | 0 | no grand design |
| `diskTruncation`, `outskirtFraction` | 3.9, 0 | a white fringe of stars outside the dust ring |

No sticky gas: it grew arms with the low Q, and is not needed once the disk is hot.

**The threads.** A threaded ring draws its dust as long threads (40 to 125 degrees along the
ring, 4 to 26 pc across) whose radius and height wander slowly with the angle, a kink on top, so
two threads cross and part. A third are short steep trailing spurs between lanes, and the threads
carry unequal shares of the grains: a few heavy lanes and many wisps. Each grain is launched cold,
on a circle at the circular speed with none of the stars' random motion in the plane, which would
smear a thread tens of parsecs across in a few megayears. Its lift out of the plane is two waves
running opposite ways along the thread, each grain at its own phase, with a vertical speed set by
`DiskEquilibrium.verticalFrequency` (from Poisson's equation at the mid-plane). The first threads
were lifted all at one phase: they fell through the plane together a quarter swing later, about
12 Myr, and read as a band at 15. Even so, particle noise heats the layer: 0.025 kpc on the ring
to 15 Myr, 0.04 at 100 Myr, 0.075 at 440. Hence a take recorded from 0 Myr with no settle, and
close passes early.

## The take, the look and the flight

8 M visible and 12 M of halo, recorded from 0 Myr with no settle to 450 Myr (lib/sombrero-8m-v6
on the Mac, 58 minutes, 28.8 GB). The flight (`sombrero.flight.json`, written by
`tools/film_flight.py`) flies its close passes between 12 and 18 Myr, while the dust layer is still
0.025 kpc thin, and lets time run fast only on the way out, seen from far. Look
`sombrero-hubble.look.json`: stretch 1.1, whitePoint 13, brightness 0.075, bloom threshold 0.6
and intensity 0.25, saturation 1.1, glint 0.25, bulgeWidth 3, painted arms off (armPersistence 0,
armStrength 0), dust 0.045 with dustReddening 2, the young and knot colours at zero; the flight's
inside block carries dustSlabs 1.2, starColours 0.3 and starYoungK 6500.

## What changed in Sillage

On PR #483 (`slabs-479`), each off by default and drawing or running every other scene as before:

- `inside.dustSlabs` (flight file): the four dust slabs laid on the dust grains in the frame, not
  on all the matter. A bulge 30 kpc deep made each slab 22 kpc deep, and the ring's far side
  shaded the core: the far lane went from 0.85 to 0.90 and more.
- `look.dustReddening`: how much more the dust takes from blue and green than from red. The
  look's saturation could not make a brown lane, and `dustGlow` made it shine gold. Metal only;
  its fragments are compiled with it only when a look sets it (a function constant), since a
  uniform in place of the constant moved a few pixels by one unit.
- `inside.starOldK`, `inside.starYoungK`: the point stars' mean temperatures, so the stars near the
  eye read cream instead of blue white.
- `starFormation` (scene): a factor on star formation's efficiency; 0 forms nothing.

On PR #481 (the sampler, written alongside): `dustRing` innerWidth, thickness, young and threads;
`bulgeApart` (a disk under a large bulge launched on its own surface density); `bulgeReach`;
`nucleus`; `recentStars`.

## Wrong turns

Most of the work went into faults that looked like rendering and were not. Each cost hours.

- **The tree's spacing, guessed twice.** Stars near the dust threads looked like tight points, so a
  star's kernel was thought to take the grains' tiny spacing from the tree of all particles. A
  floor on the stars' spacing (`starSpacingFloor`) and kernels sized from a second tree of the
  emitting particles alone (`emittingSpacing`) were both built, tested to the bit and reverted:
  the second changed nothing visible, the first only helped by widening the real cause.
- **Glint for the specks.** Glint 0, 0.1 and 0.25 left the specks as they were.
- **The painted wave.** The look's two-armed density wave (armPersistence 1.6, above 1 is
  invention) drew the dust ring as concentric tori before any physics was at fault.
- **Knots tuned against a fault that was not there.** Knot and young kernel widths and colours
  were tuned for hours against sparkle and arcs that were dust grains forming stars during the
  run. Counting them took one script.

The rule they teach: **when a light has no explanation, count the particles that emit it, by
component and by formation time, from the take, before touching the renderer.**
`tools/thread_census.py` and a few lines on the take's formation array would have saved most of
the above.

## What is still not faithful

- The fibres are coarser and fewer than Hubble's hundreds; at 8 M a thread is 4 to 8 px wide at
  4K.
- No solid dark band at the rim: Hubble's near lane is dense and nearly black at the edge.
- No core spindle: the core is a point with cream round it.
- The rim knots are hidden (young and knot colours at zero) rather than drawn as a few small blue
  points.
- Some threads seen edge on show their lift wave as a regular zigzag.
- By 200 Myr the threads wind into near circles, faint in the far views.

## Figures and costs

Against Hubble at the frame's figures (`tools/measure.py`, values 0 to 1), v6 at 12 Myr: halo 1 to
7 kpc over the core 0.82, 0.66, 0.52, 0.43, 0.37, 0.30, 0.24 (Hubble 0.78, 0.66, 0.52, 0.41, 0.33,
0.26, 0.20); side 3 to 12 kpc 0.45, 0.38, 0.29, 0.19, 0.13 (0.46, 0.37, 0.26, 0.17, 0.10); disk 0.68
(0.76); near lane 0.44 of the light left, 0.27 kpc wide, red over green 1.38 (0.46, 0.27, 1.34); far
lane 0.95 (0.97).

On an M4 Max: a 2 M check to 60 Myr, 2 minutes; 2 M to 450 Myr, 12 to 15 minutes; 8 M to 30 Myr,
4 minutes; 8 M to 450 Myr, 58 minutes and 28.8 GB; a 4K flight key, about 40 seconds; the 4K film (100 s,
3 001 frames, HEVC), 5 to 8 seconds a frame, the close passes drawing up to 100 M point stars a
frame.
