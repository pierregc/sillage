# Flights

#295, part of #294. An export's camera used to be a function of the take: the look's camera plan
at each captured frame (`ShotReplay`). A flight gives the video a camera path of its own, written
by hand as keys at seconds of the video, over a time track of its own (#305's
`TimeTrack(times:)`), so the camera keeps moving while the take's time runs, slows, stops and
starts again.

```bash
./scripts/dev.sh render flight <scene> --at 300,430,452,520 --look photograph   # coordinates to write keys from
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
  "near": 1,
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
- `near`, for the whole file: the camera's near distance in kiloparsecs, 1 when absent, as every
  camera has. Particles nearer than it in depth are dropped; #297 decides what a flight inside a
  disk needs.

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

## The export

`export --flight` resolves the flight once per size (`TakeExport.makeFlight`): a look key asks the
look's camera through a `ShotReplay` without a track, in the order of the take's time, as a
replayed camera must be asked, and keeps the cameras of every captured frame a stretch between two
look keys crosses. Each frame then takes its moment from the flight's track, the arms, time and
exposure there through `TakeFraming` (the look's per-shot changes, which only the immersed camera
has, are not applied), and the camera from the flight. The look's camera plan is ignored but for
look keys, and the export says so. The video is `exports/<flight>-<preset>.mp4`, beside the plain
exports; `--speed` does not go with a flight, which has its own time.

`--flight-keys <dir>` draws only the frame at each key as a PNG and encodes nothing: on the 8 M
Mice take, the 11 keys of the example at 960 x 540 in 2.3 s.

`Flight`, `FlightFile` and `FlightTake` are portable Swift beside `TakeFraming`, built by
`scripts/linux.sh`, so the CUDA engine's stills (#277) and full pass (#278, #300) can follow a
flight by asking `Flight.shot(atSeconds:look:)` and `Flight.captured(atSeconds:)`.

## A worked example: the Mice

The README's Mice take (`scene-0067` of the 2026-11-04 batch, 8 M drawn), with the `photograph` look.
From the curves the pair is 68 kpc apart at 297 Myr and closest, 13 kpc, at about 452 Myr.
`flight --at 300,430,452,520 --look photograph` gave the photograph framing (eye 178 kpc above and
south of the origin, aim the origin, 0.6 rad) and the centres and spins at each.

- 0 to 4 s, two look keys from 300 to 360 Myr: the photograph export itself.
- 4 to 14 s: in from 178 to about 70 kpc, from above the pair (looking along the mean of the two
  spins less its part along the separation, so neither disk is edge on), time slowing into 452 Myr.
- 14 to 33 s, time frozen at 452 Myr: round the pair from below the plane of the encounter, then in
  on galaxy 0's disk, keys in its disk's axes, 16 then 7 kpc from its centre, 3.5 kpc above its
  plane, exposure -1.5 to -2.5.
- 33 to 46 s: out to 160 kpc while time runs again, to 620 Myr.

The whole file, `flights/dive.flight.json`:

```json
{
  "version": 1,
  "keys": [
    {
      "at": 0,
      "myr": 300,
      "look": true
    },
    {
      "at": 4,
      "myr": 360,
      "look": true
    },
    {
      "at": 10,
      "myr": 430,
      "eye": [
        -10,
        -50,
        110
      ],
      "aim": [
        -0.5,
        -1,
        0.3
      ]
    },
    {
      "at": 14,
      "myr": 452,
      "eye": [
        -25,
        -32,
        62
      ],
      "aim": [
        -0.3,
        -1.1,
        0.4
      ]
    },
    {
      "at": 18,
      "eye": [
        -55,
        15,
        22
      ]
    },
    {
      "at": 22,
      "eye": [
        -25,
        40,
        15
      ]
    },
    {
      "at": 26,
      "eye": {
        "galaxy": 0,
        "offset": [
          0,
          -14,
          9
        ],
        "disk": true
      },
      "aim": {
        "galaxy": 0
      },
      "exposure": -1.5
    },
    {
      "at": 30,
      "eye": {
        "galaxy": 0,
        "offset": [
          3,
          -5,
          3.5
        ],
        "disk": true
      },
      "aim": {
        "galaxy": 0,
        "offset": [
          -2,
          2,
          0
        ],
        "disk": true
      },
      "exposure": -2.5
    },
    {
      "at": 33,
      "myr": 452,
      "eye": {
        "galaxy": 0,
        "offset": [
          6,
          2,
          4
        ],
        "disk": true
      },
      "aim": {
        "galaxy": 0
      },
      "exposure": -2
    },
    {
      "at": 39,
      "myr": 520,
      "eye": {
        "galaxy": 0,
        "offset": [
          -10,
          -60,
          45
        ]
      },
      "aim": [
        1,
        -1,
        0
      ],
      "exposure": 0
    },
    {
      "at": 46,
      "myr": 620,
      "eye": [
        0,
        -110,
        120
      ],
      "aim": [
        2,
        -1,
        0
      ]
    }
  ]
}
```

Drawn in 1080p at 30 fps, 1 381 frames in 206 s (6.7 a second, the GPU shared with #296's spike),
64 MB of HEVC.

The first try looked from the south-west and found galaxy 1 edge on across galaxy 0 at 430 and
452 Myr; the up-close keys at -0.5 and -1.2 stops were paste. Both were seen on the key stills and
changed in a minute.
