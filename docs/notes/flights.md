# Flights

#295, part of #294. An export's camera used to be a function of the take: the look's camera plan
at each captured frame (`ShotReplay`). A flight gives the video a camera path of its own, written
by hand as keys at seconds of the video, over a time track of its own (#305's
`TimeTrack(times:)`), so the camera keeps moving while the take's time runs, slows, stops and
starts again.

```bash
./scripts/dev.sh render flight <scene> --at 300,430,452,520 --look photograph   # coordinates to write keys from
./scripts/dev.sh render flight <scene> --at 452 --look photograph --arms 6,9    # and where the arms are
./scripts/dev.sh export <scene> --look photograph --flight dive --flight-keys out/dive   # one PNG a key, in seconds
./scripts/dev.sh export <scene> --look photograph --flight dive                  # exports/dive-1080p.mp4
```

## The file

`flights/<name>.flight.json` in the scene folder, or any path ending in `.json`. Versioned and
strict as `LookFile` is: a field this build does not know is an error, and so is a key that
cannot be read the one way it means.

```json
{
  "version": 1,
  "near": 0.001,
  "inside": {"stars": 128, "exposure": 0.16, "subframes": 8},
  "keys": [
    {"at": 0, "myr": 300, "look": true},
    {"at": 10, "myr": 430, "eye": [-10, -50, 110], "aim": [-0.5, -1, 0.3]},
    {"at": 14, "myr": 452, "eye": [-25, -32, 62]},
    {"at": 26, "eye": {"galaxy": 0, "offset": [0, -14, 9], "disk": true}, "aim": {"galaxy": 0}, "exposure": -1.5},
    {"at": 33, "myr": 452, "eye": {"galaxy": 0, "offset": [6, 2, 4], "disk": true}},
    {"at": 46, "myr": 620, "eye": [0, -110, 120], "aim": [2, -1, 0], "exposure": 0}
  ]
}
```

- `at`: seconds into the video. The first key is at 0, and the video lasts to the last.
- `myr`: the take's moment then. Required on the first and the last key; on any other, it pins
  time there, and a key without it leaves time to the cubic through the others. Two keys with
  the same `myr` freeze time between them. A moment outside the take is refused with the take's
  span.
- `eye` and `aim`, in kiloparsecs: a point `[x, y, z]` fixed in the world, or a point carried by a
  galaxy, `{"galaxy": 0, "offset": [x, y, z]}`, the offset from its centre in the world's axes or,
  with `"disk": true`, in its disk's: x and y in its plane, z along its spin. `aim` may be
  `{"galaxy": 0}` alone, the centre; an eye on a galaxy needs an offset. A key that gives one of
  the two keeps the other from the key before.
- `"look": true`: the camera the export draws at that moment without a flight (eye, aim, field of
  view and roll from the look's camera plan). Between two look keys the camera *is* the look's,
  moving as it moves, so a flight opening on two look keys draws exactly the plain export's frames
  there, then flies off.
- `fov` (radians, vertical, as `Camera`'s), `roll` (radians about the line of sight, positive
  turns the camera anticlockwise, so the picture clockwise), `exposure` (stops, below). A key
  without one keeps the value before; the first key starts from 0.6, 0 and 0.
- A key with none of `eye`, `aim` and `look` only pins time, and may not carry `fov`, `roll` or
  `exposure`.
- `near`, for the whole file: the camera's near distance in kiloparsecs. A flight's camera takes a
  parsec when the file gives none (#297); every other camera keeps its kiloparsec. Particles fade
  out before it rather than being cut (below).
- `inside`, for the whole file: what the frames are drawn with once the camera is near matter
  (#297, "Inside a galaxy" below). Every field is optional and the block itself is; absent, the
  settings Pierre chose on #296's frames.

**Round a black hole close up (#335)** a flight is the same file with two differences: its keys
give `time`, the hole's moment in its own time units, in place of `myr`, and its points are
fixed in the world, in Schwarzschild radii round the hole. A file gives `myr` or `time`, never
both; galaxy anchors and `inside` are refused there, and an export of galaxies refuses a file
that gives `time`. Three samples come with every new close up
([the close up's note](black-hole-close-up.md#cameras-that-fly-335)).

## Where to read coordinates

`sillage-render flight <scene> --at <myr,...> [--look <look>]` prints, at each moment, every
galaxy's centre and disk axes as the take holds them, and the camera the export draws there with
that look, as a key ready to paste. The take's curves (`curves-hires.csv`, `separation_kpc`, `x_0`
to `z_1`) find the moments worth a key: the first passage is where the separation is least.

The centres are the ones the take holds, the same the painted arms and the director's framing use.
After a merger they can sit out in the debris (`docs/notes/director-shots.md`): a camera anchored
on a galaxy that has merged follows a point that may no longer be its light's middle. There,
`ShotPlan`'s measured core (`LightMeter`, a shrinking sphere) is the better anchor; a flight takes a
world point read off a still instead, until a key asks for it often enough to be worth a field.

The disk axes are the disk states the take holds (`DiskFrame`'s plane carried from the natal
pair), or the natal plane for a take written before disk states were kept.

`--arms <kpc,...>` adds, for each galaxy and each radius, the place on that circle of its disk where
the emitting particles within 300 pc of its plane are densest (over nine degrees of the circle), as
a point ready to paste, `{"galaxy": 0, "offset": [-7.42, 5.10, 0.00], "disk": true}`, with how many
times the circle's mean it holds: an arm to fly into. On the Mice at 452 Myr the tidal arm of
galaxy 0 holds nine times its circle's mean at 9 kpc.

## Interpolation

**Eye and aim** run through the keys against the video's time, as a cubic Hermite curve between
each two keys whose velocity at a key is shared by the curves on either side, so the path passes
through every key and its velocity is continuous there. The velocity at a key is the centripetal
Catmull-Rom tangent (Barry and Goldman's, the knots spaced by the square root of each chord), which
is what keeps a spline through uneven keys from looping, taken from the spline's own parameter to
seconds at the harmonic mean of the rates on either side, and held under three chords per interval
on each side: past that a cubic overshoots, and a key where the camera stops (two keys at one
point) gets a velocity of zero. The first and last keys are at rest, so a flight eases in and out.
A plain non-uniform Catmull-Rom against the video's time was the obvious other choice; it loops
between close keys far apart in time, which is exactly a camera parked during a freeze.

**Anchors** are placed at each frame's own moment: every key's point is worked out where its
galaxy is at that frame, and the curve runs through those. A path whose keys are all on one galaxy
is therefore the same path in that galaxy's frame, carried along with it; a world key stays put.
While time is frozen nothing moves and an anchored key is a fixed point.

**Field of view, roll and exposure** are eased between keys (smoothstep: still at each key), the
field of view on the logarithm of the tangent of its half angle, so a zoom feels even.

**Up.** The world's z, turned by the roll about the line of sight, exactly, wherever the camera
looks more than about 18 degrees off the vertical (`Flight.clear`, |forward . z| 0.95). Nearer the
vertical the world's z stops defining a horizon, so the up vector is carried from the frames before
by the smallest turn that follows the line of sight, wholly so within 6 degrees (`Flight.pole`), and
turns back to the world's z at up to half a turn a second (`Flight.righting`) once clear. A camera
looking straight down neither flips nor spins; one that goes over the top comes out upside down and
rights itself within a second. The carried vector is sampled once at 240 a second of video when the
flight is resolved, so any frame can be asked in any order.

**Time** is #305's track through the keys that give `myr`: Fritsch and Carlson's monotone cubic,
so it slows into a freeze, holds, picks up out of it, and never runs backwards
(`docs/notes/variable-time.md`). A frame at the same captured position as the one before reuses
its expanded positions and its smoothing (`TakeExport.expansions`), so a frozen stretch costs the
drawing only.

## Exposure

`exposure` multiplies the look's brightness by 2^stops and the stretch by 2^(1.46 stops), floored
at 0.09 of it: contemplation's closeness trim (`Cinematographer.modulated`) moves brightness as
closeness^1.3 and the stretch as closeness^1.9, because the logarithmic stretch is what saturates
when a disk fills the frame, and this is the same law in stops. Up close a disk needs -1.5 to -2.5
(the worked example below); without it the frame turns to the white paste contemplation measured.

A flight also has an **automatic exposure** (#297): from the photograph to the inside of an arm
the frame brightens by up to five stops within seconds, which no trim written by hand follows. It
is a second trim, by the same law without the floor, that only ever darkens: the frame's mean
luminance (linear, of the 8-bit picture) is held under `inside.exposure`, 0.16 unless given, and a
frame already under it is left alone. It is solved every quarter of a second along the whole
flight before the first frame is drawn, by a renderer of its own (`TakeExport.measureTrims`,
two to four draws a moment), and eased under a raised cosine `inside.exposureEase` seconds wide
either side (1 s), so it anticipates a dive as much as it follows it. On the look's own camera
there is none: at a look key and between two of them the frame is the export's, and when the
photograph itself is brighter than the target, the target is raised to it. The keys' `exposure`
stays on top. A look that measures its exposure on the frames (#340) measures it on the flight's
look keys, or on its first frame without any: measured along the whole flight, the inside of a disk
would darken the photograph.

## Inside a galaxy

#297, from #296's frames (`docs/notes/inside-a-galaxy.md` has them, the numbers and what each
piece costs). A flight's frames are drawn by a Metal library of their own, the renderer's text
with `SILLAGE_INSIDE` defined, so that an export without a flight compiles and draws what it
always did, to the bit. What that library adds is keyed on distances, and far from any matter it
adds nothing: on the photograph's framing a flight's frame is the export's within a level in 255.

- **Near plane at a parsec**, and a particle fades to nothing over the last three kernel lengths
  before it (`fade`), so nothing is cut and nothing pops.
- **No flare.** A kernel the look's ceiling caps keeps the surface brightness of its own size
  in the near field, for stars and for dust.
- **Point stars** (`stars`, 128 a particle): the light of a near particle goes over from its splat
  to a few bright stars over a crowd of faint ones (`starShare`, rank to minus one), scattered in
  its kernel (`starSpread`, in kernel lengths) from a hash of its index, coloured around its
  population (`starColours`), 1.5 output pixels each (`starSize`). The cross-fade runs from `starFrom` to `starFull` of the kernel
  ceiling (0.05 to 0.2), in the near field only.
- **The near field** (`field`, `[3, 8]` kpc of view depth): all of the above applies wholly nearer
  than the first distance and not at all past the second.
- **Dust slabs from the eye** once inside (`slabs`, `[0.3, 1.5, 7.5]` kpc), soft, and around the
  aim point as every export has them far away; they slide from one layout to the other as the eye
  comes within `slabsWithin` (`[1.5, 6]` kpc) of matter.
- **The dust web's lace flattens out** as the eye comes within `web` (`[3, 10]` kpc) of a disk,
  the rays that graze the plane first; the dust it carries stays, as an even layer.
- **Motion blur**: while the shutter is open (`shutter`, half of the frame's interval) a point
  star is drawn as the streak it leaves, and the frame is averaged from up to `subframes` renders
  (8), one for every four pixels the near matter crosses meanwhile, each drawing its share of
  every streak: one unbroken line a star, not a row of dots. A camera at rest, farther from matter
  than the near field reaches, or on the look's own path draws the frame once, as a still. The
  renders share the frame's moment of the take: only the camera moves.
- **Kernel lengths eased in time**: a flight's kernels are read off trees built at the take's
  captured frames and taken between them, so that time running a hundred times slower does not
  make them shimmer.

"Near matter" is measured, not written: the distance from the eye within which a ten-thousandth
of the drawn particles lie (`Nearness`, 800 of 8 M), which cannot change faster than the eye moves.
The export's last lines say what a flight took: the nearest it came, the deepest trim, the most
renders a frame was averaged from and the most particles drawn as stars.

Sizes in pixels are output pixels, as the look's are: a flight drawn in 4K and scaled down has
finer stars than the same flight drawn in 1080p.

**Speed is the author's.** A star at distance d crosses 1 750 x v / d pixels a frame in 1080p
(v the eye's path in a frame): at 2 pc a frame the stars 300 pc away drift by a dozen pixels and
the nearest streak past, at 5 the whole near field streaks, at 50 it is a tunnel of lines. Keys
50 to 150 pc of path apart for every second of video are a drift to a glide among the stars. Time
near matter wants a hundredth of the take's speed or less: at a tenth the nearest stars dart from
their own motions. The export's last line gives both, the most the eye moved in a frame within a
kiloparsec of matter and, when time ran faster than that there, how fast.

## The export

`export --flight` resolves the flight once per size (`TakeExport.makeFlight`): a look key asks the
look's camera through a `ShotReplay` without a track, in the order of the take's time, as a
replayed camera must be asked, and keeps the cameras of every captured frame a stretch between two
look keys crosses. Each frame then takes its moment from the flight's track, the arms, time and
exposure there through `TakeFraming` (the look's per-shot changes, which only the immersed camera
has, are not applied), and the camera from the flight. The look's camera plan is ignored but for
look keys, and the export says so. The video is `exports/<flight>-<preset>.mp4`, beside the plain
exports; `--speed` does not go with a flight, which has its own time.

`--flight-keys <dir>` draws only the frame at each key as a PNG and encodes nothing, and prints
what the GPU took for each; `--flight-at <s,...>` with it draws those seconds of the flight
instead of its keys (#353). A still is one render at its own exposure, solved for that moment
alone: the video's frame there is eased with its neighbours and may be averaged from several
renders.

`Flight`, `FlightFile` and `FlightTake` are portable Swift beside `TakeFraming`, built by
`scripts/linux.sh`, so the CUDA engine's stills (#277) and full pass (#278, #300) can follow a
flight by asking `Flight.shot(atSeconds:look:)` and `Flight.captured(atSeconds:)`.

## In the app

#298. The app flies already (`FlyCamera`, `docs/notes/fly-camera.md`); over a take of a scene it
also records the flight, plays it back on the canvas and hands it to Video… (the Camera section's
Flights, beside free flight). Nothing is written by hand: `flights/<name>.flight.json` is the
file above, with world points for the eye and the aim.

| key | does |
|---|---|
| `F` | free flight, from the view on the canvas (the plan's camera when the canvas follows it) |
| `W A S D`, `Space C`, `Q E`, arrows, drag, `⇧` `⌃` | fly, as before; `←` now turns left |
| `[` `]` | one step down or up the throttle: 5, 10, 20, 50 pc/s, 0.1, 0.2, 0.5, 1, 2, 5 ... 4 000 kpc/s |
| scroll | the throttle, continuously, from 5 pc/s to 4 000 kpc/s (it stopped at 2 kpc/s before) |
| `R` | Record, Stop |
| `K` | a key where the camera and the playhead are |

**Record.** The camera (eye, aim, field of view, roll) and the take's moment are sampled at every
frame the canvas draws, in real time, and laid on a grid of 30 a second when the recording stops.
A paused playhead is a freeze in the flight; playing again lets time run at the play rate.
Anything that moves the playhead, the slider, Restart or the take looping, ends the recording
there and keeps what it has: a flight's time never jumps. Leaving free flight ends it too. Record
from orbit starts free flight from the view on the canvas, so nothing jumps.

**Smoothing and keys** (`FlightRecorder`). Eye, aim, roll and field of view are smoothed under a
raised cosine half a second wide, which takes the hard starts and stops of held keys out; the
moment of the take is left as it was. The keys are then chosen against the flight they make, not
against a stand-in: the grid is cut every second (and where a freeze starts and ends), a flight
is made of those keys, and wherever it is further from the smoothed recording than the tolerance
it gets a key at the worst sample of that stretch, never closer than a tenth of a second, until
none is. So a straight stretch keeps a key a second, a bend, a freeze's edges or a camera moving
within a few parsecs of the stars come closer. The tolerance is

- the eye: half a percent of the distance to the nearest matter (`Nearness`, which the canvas
  measures anyway while flying; the distance to the aim when it is not known), never finer than 0.2
  pc;
- the line of sight 0.002 rad, the roll 0.02 rad, the field of view 1 % on the tangent of its half
  angle;
- the moment a quarter of a captured frame.

Roll and field of view are eased from key to key (smoothstep), which the smoothed recording is
not: a steady turn asks for more keys than a straight line. The aim is not a kiloparsec ahead of
the eye, as `FlyCamera` aims in orbit: it is as far ahead as the nearest galaxy's centre, so that
the dust's depth slabs, which are centred on the aim, are ordered as an export's are. The result
is written as the scene's next `flight-N`.

**Keys by hand.** `K` adds the camera and the playhead as a key, its `at` after the last by the
distance flown at the throttle's speed (the boost keys do not count), by the turn of the view at
0.8 rad a second when that is longer, and never under half a second. A path can be set paused,
with time frozen between two keys at one moment; time cannot run backwards from one key to the
next (the key is refused, with the two moments). Save path writes it as `path-N`, as it is, with
no smoothing: the keys are the ones chosen.

**Banking** (a toggle, off at first): the roll follows the view's turn about the vertical,
0.35 rad of bank for each rad a second, 0.6 at most, eased over a third of a second, and levels
when the turn stops. It is the roll a flight key writes, so a recorded bank is exported as flown.

**Play.** A flight plays on the canvas by its own time: the camera its keys give, the playhead
where its time puts the take (`SimulationModel.setPlayhead`), so the window shows what the
export draws; the slider scrubs it and Pause holds it. A key or a drag takes the controls from it
where it is, and so does its end. The canvas draws near matter as the export draws a flight, the
near plane at a parsec, the capped kernels without flare, point stars and the dust slabs from the
eye (`Renderer.inside`, set while the eye is within 12 kpc of matter and nil past it, where the
frame is the one drawn without it), and darkens the frame as the automatic exposure does, from the
frame itself rather than from a pass over the whole flight (`InsideExposure.Live`): a trim in
stops, eased, that only ever darkens, held to the file's `inside.exposure`. What the window does
not do is the motion blur (a frame is drawn once), the eased kernel lengths and the exposure's
anticipation of a dive, so a fast pass near the stars looks sharper there than in the video.

**Not built.** A draft quality while flying (less supersampling, the full one paused): the window
draws a frame near matter in the time #297 measured for an export's, a few tens of milliseconds at
the arm's edge to a few hundred in the bulge at 8 M, and the canvas's pixels are fewer than the
video's. It waits for a take of 8 M flown by hand to say whether it is needed.

**Video….** The export sheet lists the scene's flights next to the scene's own camera. A flight
chosen sets the video's length, the Speed row does not apply, and the job is the queue's export
with `--flight <name>`, written as `exports/<flight>-<preset>.mp4`. Its forecast counts a frame at
0.8 s in 1080p (the demo flight of #297 below, 2 521 frames in 34 minutes), scaled by the pixels:
a flight's frames cost ten or twenty times a plain export's.

## A worked example: the Mice

The README's Mice take (`scene-0067` of the 2026-11-04 batch, 8 M drawn), with the `photograph` look.
From the curves the pair is 68 kpc apart at 297 Myr and closest, 13 kpc, at about 452 Myr.
`flight --at 300,452 --look photograph --arms 8,9,10` gave the photograph framing (eye 178 kpc
above and south of the origin, aim the origin, 0.6 rad), the centres and spins, and galaxy 0's
tidal arm at 452 Myr: nine times its circle's mean at `[-7.42, 5.10, 0]` in its disk's axes,
running out towards `[-7.93, 6.09, 0]`. In those axes the companion's centre is at about
`[-12.3, 4.0, -0.4]`, five kiloparsecs past the arm and almost in the plane.

- 0 to 4 s, two look keys from 300 to 360 Myr: the photograph export itself.
- 4 to 12 s: in from 178 to 55 kpc above galaxy 0, time slowing into 452 Myr.
- 12 to 70 s, time frozen at 452 Myr, every key in galaxy 0's disk axes. Down across the disk to
  1.3 kpc above the bulge, the companion rising over the dust (30 s); into the arm, 80 pc above
  the plane, looking along it (42 s); a glide of 1.6 kpc along the arm in 12 s, 4.6 pc a frame,
  the near field streaking past; a drift of 440 pc in 8 s while the camera turns to the
  companion (62 s); up to 2.5 kpc above the plane, looking back at the bulge edge on (70 s).
- 70 to 84 s: out to 160 kpc while time runs again, to 620 Myr.

The whole file, `flights/dive.flight.json`:

```json
{
  "version": 1,
  "keys": [
    {"at": 0, "myr": 300, "look": true},
    {"at": 4, "myr": 360, "look": true},
    {"at": 12, "myr": 452, "eye": {"galaxy": 0, "offset": [10, -30, 45], "disk": true}, "aim": {"galaxy": 0}},
    {"at": 18, "eye": {"galaxy": 0, "offset": [6, -14, 12], "disk": true}, "aim": {"galaxy": 0, "offset": [-3, 2, 0], "disk": true}},
    {"at": 24, "eye": {"galaxy": 0, "offset": [3, -6, 4], "disk": true}, "aim": {"galaxy": 0, "offset": [-7.42, 5.10, 0], "disk": true}},
    {"at": 30, "eye": {"galaxy": 0, "offset": [-1, 0.5, 1.3], "disk": true}, "aim": {"galaxy": 1}},
    {"at": 36, "eye": {"galaxy": 0, "offset": [-4.5, 3.0, 0.4], "disk": true}, "aim": {"galaxy": 0, "offset": [-7.42, 5.10, 0], "disk": true}},
    {"at": 42, "eye": {"galaxy": 0, "offset": [-6.3, 3.9, 0.08], "disk": true}, "aim": {"galaxy": 0, "offset": [-7.93, 6.09, 0.05], "disk": true}},
    {"at": 54, "eye": {"galaxy": 0, "offset": [-7.42, 5.10, 0.05], "disk": true}, "aim": {"galaxy": 0, "offset": [-8.5, 7.2, 0.1], "disk": true}},
    {"at": 62, "eye": {"galaxy": 0, "offset": [-7.6, 5.5, 0.06], "disk": true}, "aim": {"galaxy": 1}},
    {"at": 70, "myr": 452, "eye": {"galaxy": 0, "offset": [-10.5, 7, 2.5], "disk": true}, "aim": {"galaxy": 0}},
    {"at": 78, "myr": 520, "eye": {"galaxy": 0, "offset": [-10, -60, 45]}, "aim": [1, -1, 0]},
    {"at": 84, "myr": 620, "eye": [0, -110, 120], "aim": [2, -1, 0]}
  ]
}
```

Drawn in 1080p at 30 fps: 2 521 frames in 34 min (1.2 a second), 123 MB of HEVC. The export's
last lines: nearest matter 165 pc from the eye, exposure down by up to 3.6 stops, up to 64 M point
stars a render, up to 8 renders a frame (11 797 in all), the eye moving up to 50 pc a frame within
a kiloparsec of matter (on the way into the arm). #295's first version of this flight stayed 3.5 kpc
above the disk with trims of -1.5 to -2.5 written by hand; this one writes none.

**The same flight with time flowing.** `dive-flowing.flight.json` keeps the keys and lets time run
from 452 to 456.8 Myr between 12 and 70 s, about 1/285 of the take's speed. The tidal arm turns by
2.7 degrees a megayear meanwhile (`--arms` at 452, 454 and 456.5 Myr), so each key in the disk's
axes is turned about the spin by the share of 12.9 degrees the arm has turned by then: the path
stays in the arm while the companion drifts three kiloparsecs across the sky.

Seen on the key stills first (`--flight-keys`, 13 keys in 1080p in a few seconds): an earlier
version aimed at the companion for the whole glide, and its core filled the frame for sixteen
seconds; aiming along the arm is what puts the camera among the stars.
