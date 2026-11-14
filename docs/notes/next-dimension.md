# What would give Sillage its dimension

Pierre, 2026-11-14: two months of work, and an export looks about as it did six weeks ago. A
viewer said he did not even see galaxies, only points moving on a screen, in the telescope looks
as in the fanciful ones. The named scenes are too far from the real objects to be shown as "the
Antennae". He asked for a pass over the open tickets, new directions, a comparison against real
galaxies, and how to reproduce known scenes credibly.

Nothing was built or run for this note. It reads the code, the earlier notes, the open issues,
the frames kept on the `assets/` branches and in the project files, and the papers listed at the
end. The reference images could not be downloaded from where it was written, so the comparison
rests on the side by side kept on `assets/126` (`telescope-vs-sillage.jpg`: three published
images beside three Sillage frames at the same size) and on the regions measured in
`references/telescope/`.

**In short.**

- **The complaint is fair, and the cause is in what the work was aimed at.** Since the end of
  October nearly everything went into the pipeline and the scale: nights, the generator, takes,
  checkpoints, tracers, 200 M, CUDA. The notes themselves measured that the count only shows at
  1:1 in a 4K close-up. Little of it changed what a viewer recognises.
- **What makes a frame read as a galaxy is mostly not physics.** Seven of the eight cues below
  are the renderer's and its settings, and can be tried on takes that already exist: an 8 M take
  exports again in about six minutes. Only the gas needs a new solver.
- **The scores push the styles away from realism.** `PaletteScore` and `FrameScore` reward two
  galaxies in two different colours and a colourful frame. Real interacting galaxies share one
  colour scheme, and four fifths of their pixels are nearly grey.
- **Recommended order:** one frame that passes for a photograph, then what a video needs to be
  understood (clock, scale, captions), then one named scene matched to its real picture, with
  the black hole spike alongside since it depends on none of it. More particles and rented GPUs
  bring nothing a viewer sees until the first of these is done.

## Why a frame does not read as a galaxy

The top row of `telescope-vs-sillage.jpg` is Hubble's Antennae beside scene 23 in the `hubble`
look. The same crude measure was run on both halves and on three frames of the README film's
look (`readme-v4`, in the project files), all at 960 px: lit pixels are those 0.10 in OKLab L
above the sky, saturated ones have a chroma above 0.05, grain is the contrast under 1.5 px
against the light at 8 px. It is a ruler held up to JPEGs, good for orders of magnitude only.

- Hubble's Antennae: 60 % of the frame lit; L of the lit pixels 0.51 at the median and 0.94 at
  the 99th centile; 20 % saturated; grain 0.44.
- Scene 23, `hubble` look: 16 % lit, field stars and noise included; L 0.27 and 0.71;
  3 % saturated; grain 0.74.
- README film look, first passage and tails: 34 and 51 % lit; L 0.59 and 0.89 at the first
  passage; 83 and 85 % saturated; grain 0.23 and 0.14.

The cues, in the order they seem to matter:

1. **One colour scheme for every galaxy, and little colour.** A real galaxy is gold in the
   middle, pale and slightly blue outside, with pink knots and brown dust, and so is the galaxy
   next to it. `docs/notes/telescope-colour.md` already says it: medians are nearly grey, the
   colour is in a minority of pixels. Sillage gives each galaxy a hue (`color`, `galaxyTint`,
   `telescopeIdentity`), which is what makes stars pulled into the other galaxy legible and
   also what makes the frame read as a diagram: an orange object against a blue one, saturated
   over four fifths of its surface where Hubble has a fifth.
2. **A hierarchy of light.** A bulge is two orders of magnitude or more above its outer disk,
   and a photograph keeps both: a core that reaches white and a body that fades into the sky
   without an edge. The film frames stop at L 0.89 with a median of 0.59: one flat tone,
   nothing that shines. The `hubble` frame never passes 0.71.
3. **Two scales of light at once.** A photograph is a smooth continuum of unresolved old stars
   with sharp things on it: clusters, knots, dust. Sillage shows one or the other. With small
   kernels it is sand (grain 0.74 to 1.04 against Hubble's 0.44), with the film's smoothing of
   2.18 it is smoke (0.14 to 0.23) and the detail goes with the grain. The shader has the two
   scales in principle (wide kernels and a compact minority, `columnSmoothing`); they have never
   been balanced against a reference, and the width is not chosen by population.
4. **Dust as a silhouette.** In the Antennae the dust is a dark brown web in front of bright
   starlight, from broad lanes down to threads, over a good part of the body. Ours is right at
   1:1 since the dust web (#173, #200) and invisible at the size of a galaxy in the frame,
   because there is no smooth bright light behind it to cut into.
5. **Beads of pink and blue.** Hundreds of bright compact knots strung along arcs. The knots
   exist (star formation from the tree, the HII window) but they are few, pale and soft.
6. **The galaxy fills the frame.** 60 % of Hubble's frame is galaxy. In night scenes the
   galaxies cover 1 to 5 % (`docs/notes/gigantism.md`); the films are better.
7. **A quiet sky.** Our field stars are larger and brighter than the galaxies and carry spikes
   as long as a disk. In a photograph they are points, and in a Webb field the background is
   small distant galaxies, which is what says "telescope" at a glance.
8. **Gas.** The heart of the Antennae, the overlap between the two disks, is shocked gas and
   the starburst in it. Stars alone give the tails and the bodies, not that. This is the only
   cue that needs physics Sillage does not have.

**Which real pictures to aim at.** At the Antennae's distance a Hubble pixel is about 5 pc. An
8 M take has stars about 50 pc apart in the plane and a softening floor of 30 pc. So a Sillage
take has about the resolution of a deep photograph from the ground, where a second of arc is
100 pc, and a tenth of Hubble's. Hubble's close-ups are also pictures of gas and dust more than
of stars. The reachable reference is the deep wide photograph: the whole system with its tails,
smooth light, gold cores, pinpoint stars. That is also where a simulation of stars is right.
Hubble's and Webb's close-ups stay the reference for colour, as they are now.

## Known scenes, credibly

Today an archetype is a family, not an object. `Archetype.antennae` draws the pericentre from
5 to 11 kpc, the eccentricity from 0.8 to 1, the tilts from 34° to 72°, the two arguments
anywhere, and fixes neither the moment nor the direction it should be seen from. Nothing in it
can be held against the real picture, so it cannot be called the Antennae.

The published models give exactly what is missing, in the parameters `Encounter` already has
(pericentre, eccentricity, mass ratio, a disk's inclination and argument). As read from the
papers, to be read again when a scene is written:

- **Antennae**, Karl et al. 2010: equal masses, nearly parabolic, pericentre 10.4 kpc, both
  disks inclined 60°, arguments 30° and 60°, disk scale lengths 6.28 and 4.12 kpc, seen 40 Myr
  after the second passage, about 600 Myr after the first, 50 Myr before the centres merge; the
  viewing rotation is given. Privon et al. 2013 fit another one: parabolic, pericentre about
  5 kpc, disks (65°, 345°) and (70°, 95°), 260 Myr after the first passage and 70 Myr before the
  merger, viewing angles given.
- **The Mice**, Barnes 2004: parabolic, pericentre three disk scale lengths (8.9 kpc), disks
  (25°, -30°) and (40°, 60°), seen 170 Myr after the passage, bulge to disk to halo 1:3:16.
  Privon et al. 2013: pericentre about 15 kpc, disks (15°, 325°) and (25°, 200°), 175 Myr after.
- **M51**, Dobbs et al. 2010 on the orbit of Theis and Spinneker 2003: a companion a third of
  the mass, bound, two passages, today about 300 Myr after the start. The arms come out with the
  right shape and pitch, and they are the tide's: the painted arms would be switched off, which
  is a claim worth making. M51 is the galaxy everybody has seen.
- **A catalogue**, Holincheck et al. 2016 (Galaxy Zoo: Mergers): 62 pairs, most from Arp's atlas,
  each with a best fit by a restricted three body code, the physics of Sillage's level 1, and
  its picture from SDSS or Hubble. Arp 244 (the Antennae), Arp 242 (the Mice), Arp 273, Arp 142
  and Arp 148 are in it. The parameters are published online.

What a named scene would be:

- **A scene file per object**: the paper's galaxies and orbit, the citation, the moment of the
  match, the direction it is seen from, the scale on the sky, the reference picture and its
  credit. No draw.
- **A match that is measured.** A command that takes a take and the reference picture and
  searches the moment, the direction, the roll and the scale for the best overlap of the light,
  on a small histogram of the particles: hundreds of trials a second. The papers give the
  angles, so this refines and checks them, and gives a number to quote instead of an adjective.
- **A way to show it.** The frame of the match beside the photograph, and in the video the last
  frame dissolving into the real picture with its credit. That dissolve is the moment a viewer
  believes the rest.
- **An honest claim.** "The stars' tides: the tails, the bridge, where the two bodies are and
  how they move. Not the gas." The wide photograph is the reference for the tails, since
  Hubble's frame holds only the two bodies.

## The open tickets

- **Worth doing for what a viewer sees.** #315 (recognisable galaxies), turned into the protocol
  of recommendation 1. #314 (black hole), see recommendation 5. #295 (camera paths and a frozen
  time in exports) with #305 (the time track, which #295 shares): together they give the frozen
  orbit round a collision at its closest, the most cinematic thing the epics hold. #309 and #311
  (automatic pace) after them: fewer dull minutes.
- **Later, once a frame passes for a photograph.** #296 and #297 (inside a galaxy): close up the
  particles are blobs (`assets/237-closeups`), so this shows the weakness before the look is
  fixed. #299 and #300 (visits at 50 to 200 M).
- **Not for a viewer.** #283, #279, #280 (rented GPUs): good for learning CUDA and for a CV,
  nothing on the picture; the tenfold study measured that the count shows only at 1:1 in 4K.
  #306, #307, #308, #310, #312, #313 (a cheaper run), #235 (walk by groups).
- **Housekeeping.** #301 is a real bug (a run can go on from a wrong state) and should be fixed
  before any long run. #260, #261, #262 (citation, release, metadata) are cheap and better done
  after the look pass, so the release carries the new video. #224 to #234 change nothing seen.

## Recommendations, by what they show for what they cost

Cost is counted in Pierre's attention, hours of the Mac and risk: S is one session and one
choice on a contact sheet, M a few sessions and a few choices, L an epic.

1. **One frame that passes for a photograph** (S to M, no new run). #315 as a protocol: one 8 M
   take, three moments (a calm disk, the first passage, the tails), the frame filled, and the
   cues above taken in order on stills: one colour scheme and a fifth of the pixels saturated
   (identity tint at 0, the ramps of the Hubble set); a stretch that lets the core reach white
   and the edge fade; the old stars wide and smooth, the young ones compact; the dust raised
   until it cuts the light at the size of a galaxy; more and brighter knots; field stars as
   points and a few background galaxies, which can be thumbnails of other scenes. Each step is
   a contact sheet against the references, with the ruler above as a number, and Pierre chooses.
   What settings cannot do becomes a short list of renderer changes; the likely ones are a
   kernel width per population and a tone curve with headroom. In the telescope world the
   scores should stop rewarding separation and colourfulness and compare the frame's regions
   with the references' instead, as `scripts/telescope-colours.py` measures them.
2. **A video that says what it shows** (S). On the picture: a clock in millions of years, a
   scale bar in light years, a title, and captions at the story's events (approach, first
   passage, tails, merger), which `Story` and the curves already find. Nothing is drawn on the
   picture today. It answers "I did not know it was a galaxy" before the first frame is judged.
3. **One named scene, matched and shown** (M). The Antennae in the wide field first, since the
   tails are what stars alone get right, then the Mice and M51. The scene file, the match
   command, the side by side and the dissolve. It needs recommendation 1 only for close views.
4. **The frozen orbit** (M, already specified). #295 with #305: time stops at the closest
   approach and the camera goes round.
5. **A black hole that tears something apart** (M to L, independent). #314 is better than its
   own estimate on two points. The lensing does not need a second renderer: each particle can
   be drawn at its bent position, once for the direct image and once for the one that passes
   behind the hole, from a small table computed once for a Schwarzschild hole; the far side of
   the disk then rises over the shadow as in the reference look, and a factor per particle gives
   the brighter approaching side. And the subject can be Sillage's own, tides: a cloud or a
   cluster falling past the hole, stretched into a stream that winds round, crosses itself and
   settles into the disk. Gravity has no scale, so the restricted solver does it with one
   potential added (Paczyński and Wiita's, which gives the precession that makes the stream
   cross), and the shader already has a black body for the heat. First step as the ticket says:
   one still, with and without the bent images. Risks: the near field flares as in #296, the
   step near the hole, and it is a second subject to keep.
6. **The dark matter made visible** (S to M). Three particles in five are halo and never drawn.
   A faint veil that can be faded in shows the two halos merging round the galaxies, which no
   photograph can and few videos do. A take does not keep the halo, so a sample of it has to be
   stored or drawn during the run.
7. **Sound** (S). The curves of a story (separation, star formation, torn stars) written as
   automation a music program reads, so a drone can follow the collision. Pierre composes; a
   video with sound is another object than a silent one, and it costs a file format.
8. **The first minute of the app** (M, to be checked against what the app does today). Open on
   a collision already running and let one gesture throw a companion at a disk, on the
   restricted solver, which runs in real time. For someone shown the app rather than a video,
   doing it is the effect.
9. **The catalogue** (M, after 3). The 62 pairs of Galaxy Zoo: Mergers read into scenes, each
   beside its real picture: a library of real objects instead of drawn ones.
10. **Gas as sticky particles** (L, uncertain). Gas that loses its relative motion where it
    collides piles up in shocks and falls to the centres: lanes where the arms compress, a
    starburst in the overlap. Only after 1, and only if what is still missing then is where the
    gas is rather than how it is drawn.

**What to stop for now:** more particles, the rented GPUs and the cheaper run. A test for any
ticket until recommendation 1 is done: does it change a pixel a viewer sees.

## Sources

- Karl et al. 2010, "One moment in time: modeling star formation in the Antennae",
  <https://arxiv.org/abs/1003.0685>
- Privon et al. 2013, "Dynamical modeling of galaxy mergers using Identikit",
  <https://arxiv.org/abs/1305.5865>
- Barnes 2004, "Shock-induced star formation in a model of the Mice",
  <https://arxiv.org/abs/astro-ph/0402248>
- Dobbs et al. 2010, "Simulations of the grand design galaxy M51",
  <https://arxiv.org/abs/0912.1201>
- Holincheck et al. 2016, "Galaxy Zoo: Mergers, dynamical models of interacting galaxies",
  <https://arxiv.org/abs/1604.00435>, data at <http://data.galaxyzoo.org/mergers.html>
- The reference images and their credits are listed in
  [What Hubble and Webb pictures are made of](telescope-colour.md).
