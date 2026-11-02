# Director shots that fill the frame

#186, part of the gigantism epic (#183). The spike measured the nights' galaxies at 1 to 5 % of
the frame, 150 to 250 px across in 4K ([gigantism](gigantism.md)): nothing that small reads as
gigantic, and the particles a hires pays for do not show. This is what the director does about
it on a take, and what was found on the way.

## Who was filming the nights

Not the director. Explore writes the raw look, whose camera is `auto` (every galaxy in frame,
following them apart and together), and the style step keeps the scene's camera, so 107 of the
108 looks in the library were `auto`. The one director look, scene-0031's, had been switched by
hand for an export. And on a take the director ran at contemplation's pace: shots of 40 to 130
s, framed on the whole scene's radius at the first frame (divided by the plan's zoom, 0.44
there). A 31 s clip was one slow push on the whole scene, which is where the spike's 1 % came
from. `auto` does better, 40 % of the height for a disk in the approach, and never more.

So the director now plans its shots when it has a take (`ShotPlan`, through `ShotReplay`: the
look grid, `look --stills`, the export, and the style editor's playhead), and the night's style
step films new scenes with it (`style.camera`, Auto `director`; `scene` keeps what explore
wrote). A live run has no future to plan from and keeps contemplation's director; so does
`immersed`.

## The plan

A take is all there before the first frame is drawn, so the plan reads the whole story and
cuts it into shots, each a slow move:

- **The calmer disk**, from the start to the middle of the approach, nearly face on (1.15 to
  1.35 rad over its plane, the spike's single disk was at 1.35), its reach (nine tenths of the
  light of an exponential disk) at 85 % of the frame's smaller side, a slow turn about its axis
  and a push of 12 %.
- **Wide** through the rest of the approach, framed exactly as `auto` frames it: the plan's
  elevation, azimuth and zoom still apply here, and only here.
- **The pericentre**, from a little before the closest moment of the pair that comes closest
  against their disks, for 14 % of the clip (2.5 to 6 s): the eye above their orbital plane,
  the line between them across the frame, the two cores and 0.6 of the larger reach around
  them. The frame is held for the shot and sized on where they are three fifths of the way
  through, rather than widening with them: they part fastest there, and following them out
  was a pull back of a sixth of the frame a second.
- **Wide** for the tails.
- **The survivor**, the last 20 % (2.5 to 8 s): the least disrupted galaxy, then the one whose
  light has spread least since the start, then the one with the most particles.

That is 37 to 42 % of the clip close on the two takes measured. A lone disk gets close, wide,
close; a clip under 7.5 s stays wide. No shot is shorter than 2.5 s.

**Shots join by a cut.** Contemplation eases between framings over a minute; a clip has 30 s in
all, and going from a frame-filling disk to the whole scene in the second or two it could spare
is a zoom of ten times, the speed that destroys the sense of size. Inside a shot nothing moves
more than 1 % of the camera's distance a frame (`theCameraOnlyJumpsAtCuts`). A position between
two captured frames across a cut is drawn as the nearer one, so an export at a higher rate than
the take never shows a blend of two shots.

**The look is the file's.** Contemplation's director moves eight oscillators of 53 to 311 s over
the look and calms the spikes; a clip covers a fraction of the slowest period, so that is a
drift rather than a breath, and it would move a style the style step chose by scoring its
frames. On a take the director draws the file's look as it is.

## Measuring the subject on the take

Three things the scene file cannot say, read off one particle in several of a stored frame
(400 000 at most, 0.8 to 0.9 s for a whole plan at 2 M and at 8 M):

- **Where the core is.** After an encounter the centre the solver follows can sit out in the
  debris while the core it was the centre of has gone on: scene-0030's survivor shot was framed
  on sparse debris with the remnant in a corner. A sphere shrunk onto the densest point, counted
  rather than weighted by light so a knot in a tail does not pull it, measured every second and
  a half across the shot.
- **The plane its light lies in**, the axis of least second moment of the light within the body.
  The disk states a take carries would have said it, but see below.
- **How far the light reaches.** A disk as it was laid down is framed on its reach. The survivor
  is framed on the radius holding three fifths of its light, between one and 1.6 reaches: the
  reach it began with showed scene-0031's remnant as a featureless core, and four fifths took
  in so much debris that the remnant was a speck.

A galaxy with under a quarter of the largest one's particles is not filmed close: scene-0030's
small disk has 289 000 of 8 M and, framed as large, was soft blots, which is the spike's 250 000
disk.

## The takes carried no disk states

`sillage-render` never handed the solver's disk states to the take, so every hires take holds
the placeholder, axis (0, 0, 1) and nothing disrupted, for every galaxy on every frame. Replayed,
that paints every disk's arms in the xy plane and never fades them, whatever the disk does: the
very thing the live run had stopped doing (`DiskFrame`). The take now gets them, and a file that
holds only the placeholder is read as holding none, which paints the natal planes as a take
before version 3 did. That changes the picture of every export from an existing take, for the
better.

## What the frames show

`look <scene> --grid --stills <dir> --base <a director look> --frames shots` prints the plan
and draws the middle of each shot.

On scene-0030 (8 M, three galaxies, 1514 frames) in 4K: the opening disk is 1 885 px across,
face on, the arms and the dust lanes whole; the pericentre fills the height with the two disks
crossing; the survivor is the remnant of the two spirals. On scene-0031 (2 M) the opening disk
has its companion coming in at the corner, and the survivor is a remnant that fills the frame.

Exposure needs nothing. Flux is conserved as a kernel widens, so a disk's surface brightness
does not change with distance, and the closeness trim contemplation applies (brightness and
stretch down as the camera nears) is for being inside the disk, where every line of sight runs
through it. At two thirds of the frame, the file's look as it is: mean luminance 0.097 on the
opening disk against 0.043 wide, 0 % clipped on the disk shots and 0.5 % at the pericentre
(the two cores). The kernel floor does not show either: at 8 M the inner disk is a fine
continuous texture at 1:1, and the outskirts, where a particle stands alone, are the dots.

## Left open

- The 4K measurement the issue asks for is on scene-0030, the one 8 M hires: #185 sets the
  count for the nights.
- A take quantises its positions to sixteen bits over the frame's bounding box, which ejected
  particles inflate late in a long take (scene-0030: 10 to 33 pc a step). A frame-filling disk in
  4K is about 20 pc a pixel, so the survivor shot, the latest and closest, may show the grid. Not
  seen on the frames above. A box robust to outliers only gains two or three times; more bits a
  axis is the fix (#192).
- Eased transitions, or a dissolve, in place of the cuts: a dissolve draws two frames for each
  one it shows.
