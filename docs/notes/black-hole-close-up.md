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
  of the model most worth a better one.
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

**The gas** is what tracers lack: they pass through each other, so a stream that crosses itself
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
  checks them when they are added. A night does not make one yet.

**The sample** (M4 Max, 6 M tracers, the default scene, alone on the GPU): `hires` 114 s, the
spike's minute of stepping and the frames copied out and written; `export` of the whole run at
1080p, 1200 frames, 295 s with physics, three images, and 239 s with film, two, 62.6 MB each.
A frame is about 50 ms of stepping and 140 to 190 ms of drawing. The videos and four stills,
the first return (t 729) and the settled disk (t 2979) from 10° and 35 r_s in both looks, are on
the branch `assets/332-black-hole`, under `docs/spikes/black-hole-exports/`.

## Risks

- **The gas is a sketch.** A grid over the orbit's plane, a pull towards the mean flow above a
  speed and an angular momentum loss: the threshold decides how much the first passage binds
  (66 % against 81 %), the stickiness how fast the disk forms, and nothing is calibrated against
  a hydrodynamic simulation of a disruption. It is what the scene's credibility rests on, more than
  the lens. Sticky particles done properly (recommendation 10 of
  [What would give Sillage its dimension](next-dimension.md)) would serve both subjects.
- **The table is per camera distance.** Half a second on the CPU each. An orbit is one table; a
  camera that comes in or goes away needs one per distance, a few interpolated, or the table
  built on the GPU.
- **Near the camera.** A splat's flux is spread over its size, which stops at 24 pixels, so a
  tracer near the camera is a dim blob rather than a flare (#296); a camera inside the disk was
  not tried.
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
   interpolated between a few.
3. **The gas.** A better crossing than the grid's: three dimensions and a calibration against a
   published disruption, or sticky particles shared with the galaxies.
4. **The cheap second image**, drawn for a share of the tracers.
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

`black-hole new` takes the scene's options (`--tracers`, `--pericentre`, `--cloud`, `--release`,
`--stickiness`, `--crossing-speed`, `--viscous-orbits`, `--cooling-time`, `--duration`,
`--frame-interval`, `--step`, `--seed`), and `black-hole run` is `new` then `hires`. `still`
draws one moment, `--at` in the hole's time units, with the look's camera or `--elevation`,
`--azimuth`, `--distance` and `--fov` over it, and `--straight`, `--images`, `--temperature`,
`--hottest`, `--beaming`, `--exposure`, `--stars`.

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
