# A match that is measured (#320)

Part of epic #318. A paper gives a moment and a viewing direction, fitted to another code's
galaxies; "it looks like the Antennae" needs a number. `sillage-render match` (or
`sillage-cuda match` on Linux) takes a scene folder's take and a real picture, and finds the
moment and the view where the take overlaps the picture best, with a score from 0 to 1 and a
sheet to see whether the best is a sharp peak or a plateau. Everything runs on the CPU: no
renderer, no GPU. How to run it is in [the reference](../reference.md#photo-match).

## The picture's side

`scripts/photo-match.py picture` reduces a photograph to a map of its extended light:

1. Linear luminance (sRGB undone, Rec. 709 weights) at 1 200 px wide.
2. Compact sources masked: a pixel whose detail between 1 and 4 px stands four times above a bar
   is masked and grown by 3 px, or by 10 px when it stands sixty times above it. The bar is the
   detail's own noise plus a tenth of the local light, so the grain of a bright tail does not
   count as stars. Nothing is masked where the light blurred at 30 px is above 8 % of its
   maximum: that is a galaxy's body, and a knot there is the galaxy's. This catches the
   foreground stars, their spikes and bleed trails, and the small background galaxies.
3. Binned to 256 px wide; a bin more than 60 % masked is masked.
4. The sky removed: the median of the bins after six rounds of clipping at three sigma.
5. The depth: decades between the light the brightest half percent of bins reach and twice the
   sky's noise. It is the picture's own, and the take is cut at the same depth, so the take is
   not asked for tails fainter than the picture shows.

Nuclei can be marked by hand (`--nuclei`, or `--marks` from `references/telescope/marks.json`).

On the two deep ground cutouts of the Legacy Surveys (CC BY 4.0, Legacy Surveys / D. Lang,
Perimeter Institute, in `out/ground-images/`, see
[a frame that passes for a photograph](a-frame-that-passes-for-a-photograph.md)):

| picture | map | depth | bins masked |
| --- | --- | ---: | ---: |
| The Antennae, whole system and tails | 256 x 213 | 2.56 decades | 23.7 % |
| The Mice | 256 x 171 | 2.02 decades | 9.5 % |

What the mask leaves: faint rings around the brightest stars, where the halo is wider than
the 10 px grown, and the JPEG's own stretch, which linearising the sRGB curve does not undo.
Both sit near the floor of the log map and weigh little.

## The take's side

The stars that shine (star, bulge, outskirt, HII; not dust, dark matter or a hole), one in so
many, each weighed by its `luminosity`, and a knot only once it has formed. Projected
orthographically, since the galaxies are tens of megaparsecs away, into the picture's grid with
a cloud in cell splat and a Gaussian of 1.5 px at 256 px wide, the same blur the picture gets.
Both maps go to log brightness the same way: against the light their brightest half percent of
seen pixels reach, floored at the picture's depth.

The view is the look camera's: elevation and azimuth in degrees, z up, the viewer at azimuth 0
and elevation 0 standing on -y; then the roll, clockwise on the picture; the kiloparsecs
across the picture's width; and where the scene's origin lands, in fractions of the width,
x right and y down, as `marks.json` places things. #321 places the picture with these.

## The score

The ticket asks for light rewarded where the picture has light and penalised where it has
none, on the faint parts (tails, bridge) as much as on the bodies. Three measures were tried:

- **correlation**: Pearson's correlation of the two log maps, each capped at the ceiling, one
  decade below the reference, so the bodies' insides (knots, dust lanes, saturated cores)
  weigh nothing;
- **balanced**: the same with the sky, the faint light and the bodies weighed a third each;
- **isophotes**: the overlap of the two maps' isophotes, intersection over union, averaged over
  six levels from 0.45 decades above the picture's floor to the ceiling, each edge softened
  over a quarter of a decade so the search sees a slope.

Held against the cases where the eye is sure, on a synthetic picture: frame 100 (500 Myr) of an
Antennae archetype run at 60 000 stars on the restricted solver at five times its step, one star
in two projected from elevation 35, azimuth 140, roll 25 at 300 kpc across into 128 px, with
noise and one pixel in twenty masked; the other star in two searched, from a guess 19 degrees,
20 degrees of roll and 60 Myr off.

| measure | truth | 100 Myr earlier | the opposite side | found | the mirrored picture |
| --- | ---: | ---: | ---: | --- | ---: |
| isophotes | 0.707 | 0.446 | 0.346 | 0.719, 2 frames (10 Myr) and 3.7 degrees off | 0.507 |
| correlation | 0.941 | 0.692 | 0.439 | 0.945, 4 frames and 4.0 degrees off | 0.840 |
| balanced | 0.960 | 0.692 | 0.650 | 0.963, 2 frames and 6.0 degrees off | 0.852 |

All three find the view again. The isophotes separate what the eye separates by the widest
margin: the wrong moment loses 37 % of the score, the opposite side 51 %, the mirrored picture
29 %, against 26, 53 and 11 % for the correlation. On the real Antennae the correlation
preferred a frame before the passage, two plain disks over the bright bodies, and the balanced
correlation a diffuse cloud lying over the tails: a correlation still pays for light that is
merely near the right level. The isophotes count light outside the picture's outline as
union and not as intersection, which is what the ticket asks. **isophotes is the default**;
`--measure` keeps the other two for comparison. Its truth is 0.71 and not 1 because the two
halves of the take are different stars: the faint isophotes are noisy at 30 000 stars, and a
take with more stars scores higher at the same view. Scores compare between takes of one
picture and of similar sizes, not across pictures.

## The search

Coarse, then fine.

- **Coarse**: the picture averaged down to 64 px wide, 20 000 stars a frame, at most 24 frames
  spread over the window (the whole take, or `--within` Myr of the guess), and directions 12
  degrees apart over the whole sphere or within `--span` degrees of the guess. For each frame
  and direction, the scale and the shift come from the centres of light and the radii holding
  90 % of it, the roll is tried every 20 degrees, then roll, scale and shift are climbed.
- **Fine**: the four best that are not neighbours, at 256 px and 200 000 stars (`--stars`):
  every frame within a coarse step of each, all six numbers climbed from it, then the best
  climbed again to a fifth of a degree.
- **Nuclei**: when the picture marks two, the roll, the scale and the shift follow from putting
  the first two galaxies' centres on them, both pairings tried, and only the moment and the
  direction are searched.
- **Known scale**: a named scene knows its distance (#319), so `--kpc-across` holds the scale.
  Without it, the scale trades against time: a structure that grows looks the same a little
  later and a little smaller. On the synthetic case of the tests (4 000 stars, frames 10 Myr
  apart) the free search lands within 3 frames and the held scale within 1.

A whole take of 200 frames over every direction is about 390 000 trials, 55 s on the four cores
of a cloud container; with a guess, a few seconds.

**The opposite side is the mirror.** Seen from the opposite direction, an orthographic picture
is the mirror image, so the search never mistakes one for the other. A mirrored picture is
matched just as well from the opposite side over the whole sphere: what tells a system from its
mirror image is which way its stars turn, which no picture shows. The mirrored picture scores
lower in the tests only because the search is held around the guess; a named scene starts from
its paper's view, which the velocities settled.

## On real pictures

The explored library on the Mac went with the workspace on 10 November and #319 is not done, so
the takes were run in the cloud with the archetypes on the restricted solver: Antennae draws 0
(60 000 stars) and 1 to 3 (40 000), Mice draw 0 (60 000), batch seed 1, a frame every 5 Myr.
Every search over the whole take and every direction.

| take | the Antennae | the Mice |
| --- | ---: | ---: |
| Antennae draw 0 | 0.661, at 35 Myr, before the passage | 0.734 |
| Antennae draws 1, 2, 3 | 0.630, 0.602, 0.583 | 0.775, 0.778, 0.780 |
| Mice draw 0 | 0.592 | **0.815** |

With the scale held (169 kpc across the Antennae cutout at 22 Mpc; the tip of the red giant
branch gives 13 to 14 Mpc, which would make it about 100 kpc; 290 kpc across the Mice at 95 Mpc):

| take | the Antennae | the Mice |
| --- | ---: | ---: |
| Antennae draw 0 | 0.589 | 0.639 |
| Mice draw 0 | 0.584 | **0.770**, 127 Myr after the pericentre |

The Mice archetype is recognised: 0.77 to 0.82 on its own picture against 0.58 to 0.59 on the
Antennae's, and with the scale held the score along time is one sharp peak, while the tails are
long and straight, which is how the archetype describes the Mice. None of the four Antennae
draws makes the Antennae's two long curved tails: their best is a frame before the passage, or
a moment that scores better on the Mice. Their tails come out as wide fans that read as tails
only edge on.

**The floor a named scene has to beat**: about 0.77 on the Mice cutout with the scale held, 0.82
without; on the Antennae cutout no look-alike was found, and anything below 0.66 is what two
plain disks already get.

## Limits

- **A picture is light, a take is stars.** Dust lanes, star forming knots and the shocked gas
  of the Antennae's heart are in the picture and not in the take. The ceiling flattens the
  bodies so that their insides do not count, and the isophotes compare outlines; a better
  match inside the bodies needs the renderer and #315's photograph look, not this.
- **Stars per pixel.** A take of tens of thousands of stars draws its faint isophotes noisily,
  and the score is lower at the right view than an 8 M take would give. The fine pass uses up
  to 200 000 stars; `--stars` raises it.
- **Time against scale**, as above, until the distance holds the scale.
- **One picture, one depth.** Two pictures of the same system at different depths give
  different scores for the same view: compare scores on one picture.
- **The mirror**, as above: the picture alone cannot tell a system from its mirror image.
