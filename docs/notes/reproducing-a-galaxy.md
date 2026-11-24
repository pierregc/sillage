# Reproducing a known galaxy

How to make Sillage draw a galaxy someone has photographed, so that the frames stand beside the
picture: written for an agent that starts from an issue and a picture and has not seen the earlier
work. Three galaxies were done this way, each with its note: [the Cartwheel](cartwheel.md) (a
collision ring), [NGC 2207 and IC 2163](ngc2207.md) (a grazing pair) and [the Sombrero](sombrero.md)
(a lone galaxy with a dust ring). [Twenty galaxies to reproduce](twenty-galaxies.md) lists the
candidates and their pictures. Read the note closest to your object first; this one gives the
order that worked and the traps, not the details again.

## The order that worked

1. **Fix the picture's physical scale and view first.** Read the field of view from the
   archive's page (esahubble.org and esawebb.org list it in arcminutes) and the distance from a
   recent paper, and work out the frame's width in kpc. The Sombrero's frame was taken as 21 kpc
   from its ring until the archive gave 26.5; every figure measured before that was off. Then the
   view: the inclination, the roll of the picture, where the core sits. A flight key that frames
   exactly the picture (`references/sombrero/tools/key.sh` makes one) lets every still be laid
   over the picture.
2. **Gather the published numbers** that set the scene: distance, masses or rotation speed, disk
   and bulge sizes, for a pair the orbit (pericentre, its time, the mass ratio, which disk is
   prograde). Keep the references in a few lines for the note. Where a paper's model is rigid and
   Sillage's halos are live, expect the moment to differ ([NGC 2207](ngc2207.md)).
3. **Turn the picture into numbers.** A script that reads the same figures off the picture and off
   a frame, in display values (0 to 1), point by point: light at set distances over the core and
   along the disk, the dust lanes' depth, width and colour, the sky, how much is white. See
   `references/sombrero/tools/measure.py` and `crown.py`. Never judge a profile's shape on ratios of
   display values: the tone curve is not linear. Judge the eye's criteria too (the person asking
   will), but put a number on each where you can.
4. **Previews at 2 M, one fault at a time.** A 2 M take of a short stretch costs a couple of
   minutes. Draw diagnostic stills as well as the picture's view: face on with the dust off (the
   look's dustStrength 0, no dustSlabs) shows the stellar disk alone; an edge-on close-up of the lane
   beside the picture's own close-up shows the dust. Change one thing per take.
5. **Read the take, not only the frames.** A take holds every particle's position at every kept
   frame, its component and its formation time. The scripts in `references/sombrero/tools`
   (`dust_radii.py`, `ring_rms.py`, `ring_ripple.py`, `thread_census.py`, `take_q.py`) read it
   straight from the file: radius percentiles and layer height of a component, the disk's
   lumpiness face on, the Toomre Q a run actually used. The Sombrero's ring was found falling
   inward this way, and its specks were found to be grains forming stars.
6. **The 8 M take only once 2 M passes**, recorded over the whole stretch the film needs (hires
   at 8 M runs about 1 Myr of simulation a second on an M4 Max, a take of 450 Myr is 29 GB).
7. **Look and flight on the 8 M take.** Tune the look against the figures on the picture's view,
   then draw one still per step of the flight at full size and judge them before any export. A
   4K export of a flight that passes close to matter costs several seconds a frame.

## A pair instead of a lone galaxy

For the Antennae, the Mice and the other pairs most of the above holds; what changes:

- **The scene has encounters.** Write them in `scene.json` (pericentre, eccentricity, mass ratio,
  the time of pericentre, each disk's inclination and node, prograde or retrograde) and let
  `explore --solver barnes-hut` place them; see `encounters` in [the reference](../reference.md)
  and the two pair notes. The archetypes (`--preset antennae`, `mice`) are a starting point to
  copy and resize, as both pair notes did.
- **The moment and the view are found, not set.** `scripts/photo-match.py picture` maps the
  picture and `sillage-render match` searches the take for the moment and the view that overlap
  it best, with a score. Hold the scale (`--kpc-across`) to the picture's, and the search window
  to after the first passage where the model puts the picture, or a plain pair of disks before the
  passage wins ([NGC 2207](ngc2207.md)).
- **Grids, not single runs.** The pairs were settled by grids of 27 to 54 previews over the orbit's
  parameters, each explored, run at 500 k and matched, about two minutes each. Scores separate
  families, not neighbours: judge the sheets.
- **Tails and bridges rather than rings**: the tidal features need the encounter right far more
  than the look; a disk's dust and bulge matter less than for the Sombrero.
- **The film** freezes on the match's view and splits the screen with the picture
  (`scripts/picture-film.py film`).

## Traps, on one screen

- The picture's frame width: from the archive's field of view, not from a feature in it.
- A scene's `effectiveToomreQ` is solved every run and overwrites the `toomreQ` written in the
  file; to set Q, remove it.
- A disk under a large bulge needs `bulgeApart`, or it is launched too hot and its dust falls in.
- Live halos drag: a placed pericentre lands closer and later than asked.
- A disk with a low Q, sticky gas or clumps grows arms within a few hundred Myr; face-on stills
  with the dust off show it.
- Particle noise heats a thin dust layer; draw close passes early in the take.
- `starFormation` (scene) is on by default: dense cold dust forms stars during the run, and each
  formed grain is drawn as a bright knot. If bright points follow the dust, count the grains whose
  formation time falls inside the run.
- A frame's brightness is normalised over every formation time, so a take where stars formed draws
  darker than a short one at the same look.
- The look's painted density wave (`armPersistence` above 1) invents arms; turn it off for a
  galaxy without a grand design.
- Narrow kernels for young stars or knots make sparkle; wide ones hide sparkle without curing it.
- When a light has no explanation, count the particles that emit it by component and formation
  time before touching the renderer.
- A dust strength of 1 saturates: lanes go black and wide. Tune it against the lane's measured
  depth.
- `inside.dustSlabs` (about 1.2) keeps a ring's far side from shading the core in flight keys.
- Reference pictures cannot be downloaded from a cloud session: fetch them on the Mac, keep the
  credit and licence beside them.
- Show the person close-ups beside the picture before any long take or export. The eye catches
  what the figures miss: the Sombrero's dust passed every figure as threads and still read as
  spaghetti beside Hubble's veil.

## Tools worth moving to scripts/

`references/sombrero/tools` holds the Sombrero's tools. These are general and should move to
`scripts/` one day, with the picture's parameters taken as arguments instead of written in:
`key.sh` (a flight key at a picture's framing, cropped and labelled), `tiles.py` and
`closeup.py` (crops beside the picture), `measure.py` (a frame's figures beside a picture's, which
needs its regions made configurable per galaxy), `dust_radii.py`, `thread_census.py`,
`ring_rms.py`, `ring_ripple.py` and `take_q.py` (readers of a take; they decode the version 7
file directly and should share one reader). `make_scene.py` and `film_flight.py` are the
Sombrero's own.
