# A black hole close up

Spike #314: a cloud torn apart by a black hole, the stream it becomes winding round and settling
into a hot disk, drawn with the light the hole bends. One scene, a take, stills and a clip, so
that Pierre can choose whether it becomes an epic. Nothing it adds changes an existing export:
the scene, the run and the drawing are new files behind `sillage-render black-hole`, and the
renderer only gained a way to run its post stages over a light target another pass draws.
The stills, the clip and the story video are on the branch `assets/314-black-hole`, under
`docs/spikes/black-hole/`. Since #332 the close up is a scene folder that `hires` runs and
`export` draws, as a galaxy scene is: see [In the exports](#in-the-exports-332).

**In short.**

- **The tear works on tracers, and costs nothing.** Six million massless tracers in
  Paczyński and Wiita's potential, a whole story of 5000 time units in a minute on the M4 Max,
  alone on the GPU. The cloud stretches into a stream, a third of it leaves, the rest comes back
  after one orbit of its most bound part, swings round the hole, crosses itself and builds an
  eccentric disk that turns round over the next few orbits.
- **Gravity alone does not settle anything.** Tracers pass through each other, so a stream that
  crosses itself only winds round. Something has to take energy where streams meet: here a grid
  of the mean flow that each tracer is pulled towards when it moves against it faster than a
  share of the orbit's speed, its loss turned into heat, and a slow viscosity that carries the
  ring in to the last stable orbit. Crude, cheap, and enough to show the story; it is the part
  of the model most worth a better one, and #334 made it
  [one that is calibrated](black-hole-gas.md): that viscosity bound the first passage on its own.
- **The bent images stay in the particle renderer.** A table computed once per camera distance,
  half a second on the CPU and 12.6 MB, gives each tracer where it shows directly, round the
  far side of the hole and once more round; the pass draws every tracer once per image. The far
  side of the disk rises over the shadow, the image that went under it closes the ring, the shadow
  needs no disc of its own and the near side crosses in front of it. It agrees with Einstein's
  weak-field lens within 4 % on positions and 5 % on brightness where that formula holds, and
  its photon ring lies within a millionth of a radian outside the shadow's edge.
- **Heat from the crossing tells the story; heat from the radius makes the textbook disk.** With
  a thin disk's law, the stream is cold and the disk white-hot whatever the gas does. With the
  run's own heat, the stream stays dark until it comes back, and the light is where it hits
  itself; the settled disk is hot inside and orange outside. Recommended: the crossing, coloured
  at 6500 K at the hottest, which is about Interstellar's gold.
- **The risk is in the gas, not in the lens**: the gas is a sketch that nothing calibrates, and
  the scene is a second subject to keep. The lens's own limits are a table per camera distance
  and a second image that costs three times the first until it is drawn for fewer tracers.

## The scene

Gravity has no scale but the hole's, so the scene lives in its units rather than in
kiloparsecs: G, the hole's mass and its Schwarzschild radius r_s are one, light goes at √2, and
the time unit is √2 r_s / c: 14 s for a hole of a million suns, 23 minutes for a hundred million.
`TidalDisruption` holds it.

**The hole** pulls as Paczyński and Wiita's -GM / (r - r_s): the last stable circular orbit at
3 r_s and the marginally bound one at 2, as in general relativity, and an eccentric orbit that
precesses (36° a turn at a pericentre of 8, against general relativity's 43°), which is what
makes the stream cross itself. A tracer is swallowed inside 1.5 r_s.

**The cloud** is six million tracers, denser in the middle as (1 - r²/R²)², of radius 1.5 r_s,
whose centre falls on a parabolic orbit with its pericentre at 6 r_s. Tracers have no gravity of
their own, so the cloud is carried whole until its centre is 10 r_s from the hole, then every
tracer is released with the centre's velocity from where it stands: its own gravity, which
tracers do not have, holds a cloud together until the tide wins, and the spread of energies is
set there. Released closer, the debris is more bound and the disk smaller. 48 % of the tracers
are bound at the release.

**The gas** of the spike, as #314 left it (#334 changed it: see [A gas that can be trusted](black-hole-gas.md)),
is what tracers lack: they pass through each other, so a stream that crosses itself
only winds round and never settles. Each step, the tracers deposit their velocities on a grid of
the mean flow, 192 rings in log r from 1.5 to 200 r_s by 384 sectors, over the orbit's plane, and
each is pulled towards the mean flow round it at two e-foldings an orbit, but only for the part
of its motion against that flow faster than three tenths of the circular speed: a crossing. A
stream's own stretch and shear is slower than that and stays cold. What the pull takes is heat.
At a tenth of the circular speed instead of three tenths, the squeeze of the cloud through its
first pericentre already counts as a crossing: 81 % of the tracers came out bound instead of
66 %, the disk formed before the stream had come back, and the story was lost. A slow viscosity,
a loss of angular momentum over forty orbits, carries the ring the stream settles into down to
the last stable orbit, where Paczyński and Wiita's potential lets nothing circle and the gas
plunges. Its loss is heat too. Each tracer's light is the heat it radiates, kept over ten time
units, so a crossing glows where it happens and a stream flung out goes dark.

**The step** is the restricted solver's kick-drift-kick, a quarter of a time unit, cut into
sub-steps by radius: a fiftieth of a radian of the orbit at the tracer's radius, up to 512, which
`TidalDisruption.advance` takes on the CPU and the Metal kernel takes for each tracer on its own.
A circular orbit at 4 r_s keeps its radius within 0.5 % over ten turns, and an eccentric one
precesses as the potential has it by quadrature, within 1 %. The grid is summed in 64-bit fixed
point, 2^24 to the unit, with integer atomics: integers add the same in any order, so a run
repeats to the bit (#332), where the spike's float atomics did not.

| | |
| --- | --- |
| tracers | 6 000 000 |
| clock | 0 at the centre's pericentre, released at -21, stops at 5000 |
| steps | 20 084 of 0.25 |
| take | a frame every 250 time units, 192 MB each (two `SIMD4<Float>` a tracer) |
| run | 60 s alone on the GPU: 3.0 ms a step, half a nanosecond a tracer |
| bound | 48 % at the release, 66 % after the first passage, the gas having taken some energy |
| first return | at 700, the Kepler period at the release of the most bound part, 2π a^3/2 with a = 23 |
| settled, t 2979 | 814 000 tracers within 20 r_s, half of them within 0.18 r_s of the plane; 8.5 % swallowed |
| t 4979 | 27 % swallowed, 5.5 % within 20 r_s: the viscosity carries the disk in faster than it is fed |

## The tear

![The tear](https://raw.githubusercontent.com/pierregc/sillage/assets/314-black-hole/docs/spikes/black-hole/tear.jpg)

Above, the take seen from over the orbit's plane, drawn straight and coloured by the run's heat,
and from 30° with the light bent. **The first return** (t 729): the cloud went through its
pericentre at t 0 and was drawn out into a stream a hundred r_s long that leaves to the lower
left, its far half for good. Its most bound part has come back round, swung round the hole on an
orbit turned 46° from the cloud's, and is crossing the stream still falling in:
the white knot where it does is the only hot gas in the frame. **Settled** (t 2979): returns
after it cross again and again, the gas loses what they bring against each other, and a disk
builds up, round inside and a nest of ellipses outside, fed by the stream that still comes in.
The ellipses are the debris' own orbits, as eccentric as the cloud's, which real disruptions
keep too: the inner part circularises first.

The run's video, from 25° and 75 r_s with the exposure and temperatures held at the settled
frame's, so the light grows with the disk: `story.mp4` on the branch.

## Heat: from the radius, or from what happens

![Temperature](https://raw.githubusercontent.com/pierregc/sillage/assets/314-black-hole/docs/spikes/black-hole/temperature.jpg)

Both colour a tracer by a black body at its temperature, through the shader's own `blackbody`,
with its light growing as the fourth power, and both are normalised on each frame: the hottest
reaches the look's `hottest`, and the mean light sets the exposure.

- **From the radius**: Shakura and Sunyaev's thin disk, T as r^-3/4 times (1 - √(3/r))^1/4, zero
  at the last stable orbit and hottest at 4.1 r_s, whatever the gas is doing.
- **From the crossing**: the run's own heat. A tracer's light is what the gas's pull and the
  viscosity took from it over the last ten time units, and its temperature the fourth root of
  that light times the tracers per unit area round it, as a black body's flux would have it.

At the first return the two read differently. From the radius, the loop near the hole is hot
because it is near the hole, and the whole of it glows. From the crossing, only the place where
the returning head runs into the stream glows, which is the event the scene is about; the stream
is a dull red either way. Settled, the radius gives a white disk with little in it, the crossing
a hot inner disk, where the viscosity works hardest, under orange ellipses that still glow where
they cross. The law from the radius is the safer textbook picture for a still of the disk alone;
the crossing is Sillage's own, comes for free with the gas, and makes a video tell what happens.
Both are a look's choice over the same take.

The hottest temperature is a look's too: a disk round a hole of a million suns peaks in the far
ultraviolet, which no palette shows. 11 000 K gives a white and blue disk, 6500 K a gold one with
a white core, close to Interstellar's (`looks.jpg` on the branch).

## The bent images

![Straight and bent at 80°, 60° and 10°](https://raw.githubusercontent.com/pierregc/sillage/assets/314-black-hole/docs/spikes/black-hole/lensing.jpg)

**The table.** Every image of a point lies in the plane of the hole, the camera and the point,
and depends only on the point's distance r from the hole and the angle φ at the hole between it
and the camera. `HoleLens` traces light back from the camera through the Schwarzschild metric:
drawn on a flat plane in r and φ, a ray is the path of a particle pulled by -3/2 h² x / r⁵, h its
angular momentum, which is Binet's equation for light. Each ray crosses every half-line from the
hole once at most, at a radius that grows with the ray's angle α from the hole, so for each φ the
table inverts r(α) between neighbouring rays. It holds, for three images over 512 radii from 1.2
to 5000 r_s on a log scale and 512 angles: α; the direction the light leaves the point in, for
its Doppler shift; and how much brighter the point shows than without the hole, from how wide
the bundle of rays the camera sees in a solid angle reaches it, which is surface brightness
kept. 8000 rays evenly over the half turn and 26 000 either side of the shadow's edge, where the
images that go round lie within a hair of each other, integrated with RK4 on fourteen cores.

| | |
| --- | --- |
| built | 0.50 s per camera distance, on fourteen cores |
| size | 3 images × 512 × 512 × 16 bytes, 12.6 MB |
| filled | between 1.5 and 100 r_s: 99.94 % of image 0, all of images 1 and 2 |
| shadow's edge | image 2 within 3 × 10^-7 rad outside asin(b_c √(1 - 1/r_o) / r_o), b_c = 3√3/2 |
| inside the shadow | nothing from more than 100° behind the hole and 2.5 r_s out; gas closer in can show there, as it should |
| a point 800 r_s behind, camera at 400 | both images within 4 % of Einstein's lens, their brightness within 5 % |
| a point 30 to 45 r_s aside | within 5 % of the straight angle, brightness 1 ± 5 % |

**The pass.** `holeSplatVertex` looks a tracer up and draws it where the table puts it, once per
image, in one draw each: image 1 on the far side of the hole, the side flipped. Its light is
weighted by the table's brightness, and by the fourth power of the shift from its motion along
the light's last direction and of climbing out of the hole; the shift multiplies its
temperature too. Paczyński and Wiita's speeds pass light's where the gas plunges, so the shift
reads them held at 0.62 c, about what general relativity gives at the last stable orbit. A
tracer is a splat of fixed size in r_s, its flux spread over it. The light goes into the
renderer's own light target and through its post stages: bloom, the stretch and the tone curve
of Sillage's frames. Drawn straight instead, the hole hides what is behind it within the
shadow's angle, as `holeShadow` does.

What the sheet shows. From 80° and 60°, image 1 is a thin ring hugging the shadow, the ring of
the Event Horizon Telescope's pictures, and the disk inside it is pushed out of the shadow it
would otherwise cover. From 10°, the far side of the disk arches over the shadow, the near side
crosses in front of its lower half, image 1 of the far side closes the ring below, and image 1 of
the near side is the hair-thin arc above, as in the reference look. Straight, the same frame is
a flat disk with a dark dome where the shadow hides what is behind it.

![The look's choices at 10°, and the photon ring close up](https://raw.githubusercontent.com/pierregc/sillage/assets/314-black-hole/docs/spikes/black-hole/looks.jpg)

**The photon ring.** Image 2, the light that went round once more, is a full circle a pixel wide
just outside the shadow's edge, tens of times thinner than image 1: e^-2φ as thin, by the strong
field's rule. At the distance of a still it is barely there; close up it closes the circle round
the shadow and reads as the line the eye expects (the bottom row). Drawing it from the table, as
the third image, reads better than a line drawn at the critical angle would, since it keeps the
disk's own brightness round the circle, and costs a third draw. Kept off by default, on for
close ups.

**Beaming.** The side of the disk that comes towards the camera is brighter and bluer, up to ten
times at the inner edge, the other dimmer and redder, and all of it redshifted by climbing out:
at 10° the approaching side is a bright bar. Interstellar took it out for the film. Kept, as
`--beaming 1`; 0 takes it out.

**Field stars.** 60 000 stars on a sphere 2000 r_s out go through the same table, so the sky
behind the hole is bent into arcs and doubled round the shadow. Faint on purpose: the disk is
the subject.

**Cost.** At 1920 × 1080, supersampled twice, 6 M tracers: the direct image alone 17 ms on the GPU,
straight 15 ms, two images 65 ms. The second image is the dear one because every tracer lands
in the thin ring round the shadow, a few thousand pixels drawn over thousands of times each.
Image 1 has a hundredth of image 0's brightness for most tracers, so drawing it for one tracer
in ten, ten times brighter, would make the same ring for a tenth of the work; not tried.

## In motion

![The orbit, every 25 frames](https://raw.githubusercontent.com/pierregc/sillage/assets/314-black-hole/docs/spikes/black-hole/orbit-tiles.jpg)

Ten seconds, `orbit.mp4` on the branch: the camera goes once round the disk 10° above its plane
and 35 r_s from the hole while the run goes on from the settled frame, a step a frame, 75 time
units, a turn and a half of the inner disk. One table serves every frame, since the distance
does not change. The images slide: as the camera turns, the far side flows over the top of the
shadow and the ring below turns with it, and the stream far behind the hole sweeps across the
sky above the disk as a wide bent arc when the camera faces it. Nothing pops at the shadow's
edge: in the middle 480 × 360 pixels, frame to frame, the mean change stays between 10.5 and 13.4
grey levels over the 300 frames, the grain of the particles and the camera's own motion, with no
frame standing out. 300 frames in 15 s, stepping included.

## In the exports (#332)

The close up is a scene folder like a galaxy scene's, and goes through the same stages:

- **The scene**, `scene.json`, holds a `TidalDisruption` under `"kind": "blackHole"`
  (`HoleSceneFile`). A file of galaxies has no kind and reads as it always did; a reader of
  galaxies refuses a close up by name. Unlike a galaxy scene, the tracer count is the scene's:
  a run repeats only at the count it ran at.
- **The take**, `take.sillage`, is written by `hires` (`HoleStage.run`): a header with the scene
  and the step of each frame kept, then the frames whole, every tracer's position and light and
  its velocity and density as the run holds them (`HoleTakeFile`). A frame every 250 time units,
  22 frames with the last, 192 MB each at 6 M: 4.2 GB. They are not quantised as a galaxy take's
  positions are, because an export draws a moment between two of them by going on from the one
  before and stepping the run to it, which gives the run's own frame only if nothing was rounded
  on the way. That is what the run repeating to the bit is for, and a test holds it: a run that
  goes on from a frame it kept ends where one that never stopped does, to the bit.
- **The look**, `look.json` in the folder, else `physics`, or `--look`: a file, a look kept in
  the folder's `looks/<name>.hole.json`, or one of the two shipped in `looks/`, `physics.hole.json`
  and `film.hole.json` (`HoleLookFile`, strict as a galaxy look file). It holds the temperature
  law, the hottest, beaming, the images, the stars, the exposure, the moment whose light sets the
  exposure and the temperatures for the whole video (`exposureAt`, 3000 by default: the settled
  disk, so the light rises with it; null normalises each frame on its own), the post stages'
  tone, and the camera: elevation, azimuth, distance, field of view and turns round the hole.

  | | physics, the default | film |
  | --- | --- | --- |
  | temperature | the run's, from the crossings | the thin disk's, from the radius |
  | hottest | 6500 K | 6500 K |
  | beaming and redshift | on | off, as Interstellar |
  | images | 3, the photon ring with them | 2 |

  Both keep 6500 K at the hottest, the gold Pierre chose: physics is about where the light
  comes from and how the motion shifts it, not about the far ultraviolet a real disk peaks in.
- **The export**, `export <folder>`, draws `exports/<preset>.mp4`, or `<look>-<preset>.mp4` for
  a look other than the scene's, with `--preset`, `--codec`, `--from` and `--to` in the hole's
  time units (the whole run by default), `--seconds` (40) and `--fps` (30). The galaxies'
  `--speed`, `--flight`, `--palette` and `--overlay` are refused rather than ignored. Each frame
  lands on a step of the run: a video of the whole run at 40 s is 4 time units, 16 steps, a
  frame. The lens table is rebuilt when the camera's distance changes, so a camera that comes in
  or goes away already works, at half a second a frame until #333 builds the table on the GPU.
- **The queue** runs `hires` and `export` on a close up's folder as on a galaxy scene's, and
  checks them when they are added. A night makes them with the recipe's `closeUps` (#349, see
  [the night manager](../night-manager.md)).

**The sample** (M4 Max, 6 M tracers, the default scene, alone on the GPU): `hires` 114 s, the
spike's minute of stepping and the frames copied out and written; `export` of the whole run at
1080p, 1200 frames, 295 s with physics, three images, and 239 s with film, two, 62.6 MB each.
A frame is about 50 ms of stepping and 140 to 190 ms of drawing. The videos and four stills,
the first return (t 729) and the settled disk (t 2979) from 10° and 35 r_s in both looks, are on
the branch `assets/332-black-hole`, under `docs/spikes/black-hole-exports/`.

## A camera that moves, and a cheaper second image (#333)

**Tables over distances.** `HoleLensSet` keeps the tables at camera distances 1.1^n r_s apart,
builds each the first time a camera comes near it, keeps the twelve last used (150 MB), and a
camera between two reads both. What it blends is not α. The direct image blends its bend, α
less the angle the point would show at without the hole, and adds back the straight angle at
the camera's own distance: a point the camera passes by moves as it should, and only the small
bend is interpolated. The images round the hole blend the light's impact parameter,
b = r_o sin α / √(1 - 1/r_o), which hardly moves with the camera and is 3√3/2 on the shadow's
edge whatever it is, so the photon ring stays on the edge. An image one table has and the other
not fades in with the first one's share. Closer than 2 r_s the camera reads the tables at 2.

Half way between two tables, against the table built there (256 × 256, 60 radii by 90 angles,
leaving out points within a fifth of the camera's distance and on the axis):

| camera | direct image: mean, worst | image 1 worst | image 2 worst | α blended instead, worst |
| --- | --- | --- | --- | --- |
| 4 r_s | 3.7e-4, 6.0e-3 rad | 1.6e-4 | 4.5e-6 | 3.5e-2 |
| 9.4 | 1.5e-4, 2.5e-3 | 5.3e-5 | 1.4e-6 | 3.0e-2 |
| 24 | 6.2e-5, 6.6e-4 | 1.5e-5 | 2.9e-7 | 2.6e-2 |
| 70 | 2.3e-5, 2.2e-4 | 1.1e-5 | 4.5e-8 | 2.7e-2 |

A pixel at 1080p and 45° is 7e-4 rad: the mean is a tenth of one, the worst few pixels at 4 r_s
for points beside the camera. At a ratio of 1.2 the errors grow about four times, at 1.4 ten. The
brightness of the further images is within 9 to 15 % near the axis, where it changes fastest.
`HoleLensTests` hold at distances between tables (`HoleLensSetTests`).

**The test clip.** The settled disk, time all but frozen, the camera flying from 200 to 20 r_s
in 10 s at 10° and a quarter turn, exported in ProRes through a look whose camera has
`toDistance`. Mean change frame to frame over the grey levels, 480 × 270: blended, the largest
change of that change between neighbouring frames is 0.07 grey levels and no frame differs from
its ten neighbours by more than 1 %; with the nearest table instead, 2.7 grey levels and 45 %,
where the camera crosses from one table to the next. A flight from 60 to 4 r_s at 70° draws
without a jump too (0.2), the ring opening round the camera as it comes in.

**The further images, thinned.** Every tracer's image round the hole lands in the thin ring round
the shadow, each a hundredth as bright as its direct image, and drawing them all cost twenty
times the direct image on the settled disk, not three as the spike measured on a first frame.
One tracer in k, k times brighter, makes the ring sparse dots wherever image 1 is not squeezed,
close up above all (PSNR 26 dB at 12 r_s for k = 8). So the share follows the table: an image the
table makes fainter than `thinning`, 0.5 by default, is drawn for that share of the tracers, as
many times brighter, chosen by a hash of the tracer's index so that it does not flicker. Its
splats then lie at least twice as close as the direct image's, and none is brighter than half a
direct splat. Images that are not squeezed are all drawn.

At 1080p supersampled twice, 6 M tracers, 35 r_s and 45°, alone on the GPU, median of 25 frames
(the first frame of a still costs 4 to 18 ms more, building pipelines and touching the tables):

| frame, elevation | one image | two, all tracers | two, thinned 0.5 | ratio |
| --- | --- | --- | --- | --- |
| settled (t 2979), 10° | 2.5 ms | 50 ms | 3.4 ms | 1.36 |
| settled, 30° | 2.3 | 38 | 3.1 | 1.35 |
| settled, 80° | 2.2 | 23 | 2.8 | 1.27 |
| first return (t 729), 10° | 1.1-1.3 | 55 | 1.7-2.7 | 1.3-2.4 |
| first return, 30° | 1.0-1.4 | 30 | 1.7-2.3 | 1.6-1.7 |
| first return, 80° | 0.9-1.0 | 22-26 | 1.5-1.6 | 1.6-1.7 |

On the first return the direct image is a millisecond, and the further images' half
millisecond is the vertex pass over every tracer, culled after its table lookup and before its
colour. Against all tracers, the thinned stills differ by 0.01 to 0.2 grey levels on the mean
(PSNR 42 to 59 dB), 0.18 at 12 r_s with the photon ring and 0.15 at 5 r_s; 0.25 takes a third
off those for a little more cost, 1 doubles them.

## Cameras that fly (#335)

**A flight round the hole is a galaxy's flight file.** `export <folder> --flight <name>` draws
`flights/<name>.flight.json` from the close up's folder, the format #295 gave the galaxies, so
that the free flight the epic aims at, and the flights #298 records in the app, have one file.
Two things differ: its points are in Schwarzschild radii round the hole, fixed in the world, and
its keys pin the hole's `time` rather than `myr`. A file gives one or the other, and a reader
refuses a galaxy's flight for a close up and a close up's for galaxies, as it does galaxy anchors
and `inside` round the hole. The run's steps stand for the take's captured frames, so #305's
track does the rest: time runs between two keys, slows, or holds where two keys give the same
moment, and every frame lands on a step that stepping on from a kept frame reaches exactly. A
`look` key takes the look's camera where an export of the whole run would have it. The video
is `<flight>-<preset>.mp4`, after the look's name when it is not the scene's; `--from`, `--to`
and `--seconds` are refused with a flight, which has its own. `black-hole still --flight <name>
--second s` draws one moment of it, to write one by hand.

**Between two steps.** A frame of a flight is drawn at the moment its time has, not on the step
before it: the renderer carries each tracer on from that step along its velocity for the fraction
of a step left, a quarter of a time unit at most, whose curve is a few thousandths of a radius at
the last stable orbit. On steps alone, time slowing into a hold moved the disk one frame in two:
on the descent's last second, in ProRes at 960 × 540, the change from frame to frame went 2.1, 3.0,
2.1, 3.0 grey levels, a stutter, and its largest second difference was 1.56; carried, it falls
evenly from 3.3 to 1.2, and the largest second difference over the whole descent is 0.39, no
frame differing from its ten neighbours by more than 16 %, through 26 lens tables.

**Three samples**, which `black-hole new` writes in the folder's `flights/` (`HoleFlight.samples`)
and leaves alone once there, each looking at the hole:

| flight | path | time |
| --- | --- | --- |
| `orbit` | once round at 35 r_s, from 8° over the plane up to 20° and back, 17 keys | runs, t 2600 to 3400, the settled disk turning |
| `descent` | from 300 r_s and 40° down to just over the disk's edge, 24 r_s out and 1.5 above the plane, a quarter turn in 34 s | the story, from the first return (t 700) to the settled disk (3000), then held for 6 s |
| `plane` | from 47 r_s and 20° over the plane down through the disk 14 r_s from the hole and out below it, 24 s | frozen at t 3000 |

![The three flights in both looks](https://raw.githubusercontent.com/pierregc/sillage/assets/335-hole-flights/docs/spikes/hole-flights/flights-sheet.jpg)

The videos, at 1080p in both looks, are on the branch `assets/335-hole-flights` under
`docs/spikes/hole-flights/`. Each took 18 to 89 s for 721 to 1201 frames on the M4 Max, the
descent the dearest for its 9200 steps of the run and its 26 lens tables; up to twice that with
another export on the GPU.

**Through the plane.** The pass crosses the disk's plane 14 r_s from the hole at about 1.3 r_s a
second, 1.1 of it downward, so some 0.6 s within the disk's ±0.33 r_s there. Edge on, it is the
classic picture: the disk a line through the shadow, the image of its far side a full ring round
it. At the
crossing the nearest tracer is 0.54 r_s from the camera, 57 lie within one r_s, 300 within two
and 1.8 % of the light within five. A splat that near would be some 240 pixels wide and stops at
24 with its flux spread, so the near disk is a dim haze along the horizon, with neither a flare
nor a flicker: in ProRes at 960 × 540, the change from frame to frame stays between 1.3 and 4.1
grey levels, no frame differs from its ten neighbours by more than 14 %, and the largest change
of that change is 0.7, two frames before the crossing. A camera deeper in a thicker disk would
see more of it as haze; what it would want is a splat whose flux falls with its size, as #297
gave the galaxies, not tried.

**What looks like a fault and is not.** The descent's first frame and the orbit's quarter show a
large soft orange arc: the unbound half of the stream, 230 r_s from the camera at the start of
the descent and 23 at the orbit's quarter, wide, cold and drawn at the ambient light. Nothing in
the samples comes within 20 r_s of the camera but the plane pass.

## Risks

- **The gas was a sketch.** A grid over the orbit's plane, a pull towards the mean flow above a
  speed and an angular momentum loss, calibrated against nothing: what the scene's credibility
  rests on, more than the lens. #334 has it in three dimensions and set against four published
  disruptions ([A gas that can be trusted](black-hole-gas.md)); what still differs is there too.
  Sticky particles done properly (recommendation 10 of
  [What would give Sillage its dimension](next-dimension.md)) would serve both subjects.
- **The tables are built on the CPU** (#333), half a second each as a camera first comes near
  their distance: 24 between 200 and 20 r_s. An export pays it inside its frames; a camera
  steered live would want them built ahead, on a background queue or from a cache on disk.
- **Near the camera.** A splat's flux is spread over its size, which stops at 24 pixels, so a
  tracer near the camera is a dim blob rather than a flare (#296); a camera through the disk
  sees it as a haze along the horizon, without a flicker (#335).
- **What the lens leaves out.** The images of a tracer are drawn at the same moment, though light
  that goes round the hole arrives a few time units after the direct light: invisible on a disk
  that turns slowly, wrong on a fast flare. The hole does not spin: a Kerr hole flattens one side
  of the shadow. Paczyński and Wiita's speeds pass light's inside the last stable orbit, held at
  0.62 c for the Doppler shift.
- **The step near the hole** is the restricted solver's with sub-steps by radius, and the gas
  plunging inside 2 r_s takes the most; the whole run is still a minute.
- **A second subject.** About 1600 lines outside the galaxies' pipeline, and 250 of tests: its
  own scene, take format, kernels and renderer pass. Since #332 it has a scene file, a take, look
  files and the `hires` and `export` stages, so the queue runs it; no app and no nights yet.
  Metal only: the six kernels are listed `metal-only` in `cuda/kernels.txt`.

## If it becomes an epic

What the stills suggest it would hold, in the order a viewer would see it:

1. **A scene and a look of its own** in the exports: `TidalDisruption` in a scene file, the take
   in the takes' format, a look file with the temperature law, the hottest, beaming and images,
   and `export` and the queue drawing it, so a night can make one.
2. **The camera.** Orbits and flights from #295, with a table per distance, built on the GPU or
   interpolated between a few (done, #333 and #335).
3. **The gas.** A better crossing than the grid's: three dimensions and a calibration against a
   published disruption (done, #334), or sticky particles shared with the galaxies.
4. **The cheap second image**, drawn for a share of the tracers (done, #333).
5. **CUDA**, through the one kernel source.
6. Later: a spinning hole, and the time the light takes round it.

## How to run it

    ./scripts/dev.sh build
    SR="env DYLD_LIBRARY_PATH=.build/dev .build/dev/sillage-render"
    $SR black-hole new library/holes/hole-0001 --tracers 6000000
    $SR hires library/holes/hole-0001
    $SR export library/holes/hole-0001
    $SR export library/holes/hole-0001 --look film --preset 4k
    $SR black-hole still library/holes/hole-0001 out/10.png --at 2979 --elevation 10 --distance 35
    $SR export library/holes/hole-0001 --flight descent --look film
    $SR black-hole still library/holes/hole-0001 out/plane.png --flight plane --second 12

`black-hole new` takes the scene's options (`--tracers`, `--pericentre`, `--cloud`, `--release`,
`--stickiness`, `--crossing-speed`, `--viscous-orbits`, `--cooling-time`, `--duration`,
`--frame-interval`, `--step`, `--seed`), and `black-hole run` is `new` then `hires`. `still`
draws one moment, `--at` in the hole's time units, with the look's camera or `--elevation`,
`--azimuth`, `--distance` and `--fov` over it, and `--straight`, `--images`, `--temperature`,
`--hottest`, `--beaming`, `--exposure`, `--stars`, or `--flight` and `--second` for a flight's
camera and moment.

## Sources

What the spike's physics and drawing rest on. They were used from memory of the papers and
textbooks, not read again for the spike: read them before the epic (#331) leans on a number.

- **The hole's pull.** Paczyński B., Wiita P. J. 1980, "Thick accretion disks and supercritical
  luminosities", A&A 88, 23: the potential -GM / (r - r_s), its last stable orbit at 3 r_s and
  marginally bound one at 2 r_s.
- **The tear.** Rees M. J. 1988, "Tidal disruption of stars by black holes of 10^6-10^8 solar
  masses in nearby galaxies", Nature 333, 523; Phinney E. S. 1989, "Manifestations of a massive
  black hole in the galactic center", IAU Symposium 136, 543: half the debris bound, the return
  of its most bound part after one Kepler period, the fallback rate as t^-5/3. Lodato G.,
  King A. R., Pringle J. E. 2009, "Stellar disruption by a supermassive black hole: is the light
  curve really proportional to t^-5/3?", MNRAS 392, 332: the spread of energies frozen in where
  the star is torn, which the release at 10 r_s stands in for.
- **The disk's heat.** Shakura N. I., Sunyaev R. A. 1973, "Black holes in binary systems.
  Observational appearance", A&A 24, 337; Novikov I. D., Thorne K. S. 1973, "Astrophysics of
  black holes", in Black Holes (Les Houches 1972): T as r^-3/4 times (1 - √(r_in / r))^1/4, zero
  torque at the last stable orbit.
- **The colour of a black body.** Kang B. et al. 2002, "Design of advanced color temperature
  control system for HDTV applications", Journal of the Korean Physical Society 41, 865: the
  chromaticity fit `Blackbody` and the shader already use.
- **Light round the hole.** Synge J. L. 1966, "The escape of photons from gravitationally intense
  stars", MNRAS 131, 463: the shadow's critical impact parameter 3√3/2 r_s. Luminet J.-P. 1979,
  "Image of a spherical black hole with thin accretion disk", A&A 75, 228: the direct and
  secondary images of a disk, its flux and redshift, the picture the bent stills reproduce.
  Bozza V. 2002, "Gravitational lensing in the strong field limit", Physical Review D 66, 103001:
  the logarithmic deflection near the critical ray, why each further image is e^-Δφ as thin.
- **Magnification.** Paczyński B. 1986, "Gravitational microlensing by the galactic halo", ApJ
  304, 1: a point lens's two images and their magnifications, the formula the weak-field test
  holds the table to.
- **Doppler beaming and redshift.** Rybicki G. B., Lightman A. P. 1979, Radiative Processes in
  Astrophysics, Wiley: I_ν / ν³ invariant along a ray, so a bolometric intensity shifted by g goes
  as g⁴.
- **The reference look.** James O., von Tunzelmann E., Franklin P., Thorne K. S. 2015,
  "Gravitational lensing by spinning black holes in astrophysics, and in the movie Interstellar",
  Classical and Quantum Gravity 32, 065001: how Interstellar's disk was drawn, and why the film
  left out the Doppler shift and beaming.
