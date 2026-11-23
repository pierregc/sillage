# A camera that flies like a ship

Spike #474. Flights asked for in plain words come out robotic: the camera whips round, looks back
over its shoulder, slides sideways. What is wanted is a camera that moves as a spaceship does,
thrusters behind, always under way, able to slow on retro-rockets without turning round, never
spinning on itself, and a way to ask for such a flight in plain words that an agent turns into a
flight plan reliably.

Nothing in the Swift package changed. The measurements and the prototype are
`scripts/spikes/ship-flight.py` (numpy, Pillow, ffmpeg; no take, no GPU), with the plans it flies in
`scripts/spikes/ship-flight-example.plan.json`, `ship-flight-head.plan.json` and
`ship-flight-pilot.plan.json`, one for each version shown to Pierre.

```bash
scripts/spikes/ship-flight.py measure references/ngc2207/flights/film.flight.json --from 97 --to 179 --tilt 0.85
scripts/spikes/ship-flight.py fly scripts/spikes/ship-flight-example.plan.json --out ship.flight.json --myr 300
scripts/spikes/ship-flight.py animatic references/ngc2207/flights/film.flight.json \
    scripts/spikes/ship-flight-example.plan.json out.mp4 --from 97 --to 179 --tilt 0.85
scripts/spikes/ship-flight.py animatic scripts/spikes/ship-flight-example.plan.json \
    scripts/spikes/ship-flight-head.plan.json out.mp4
```

## What makes today's flights robotic

A flight is a list of keys, each an `eye` and an `aim`, and the two run on two splines that know
nothing of each other ([flights](flights.md#interpolation)). The path of the eye is smooth, and
so is the path of the aim, but the line of sight is the difference of the two: nothing ties where
the camera looks to where it goes, and nothing bounds how fast it turns.

**How it was measured.** `measure` ports `Flight.swift`'s path (the Hermite curve, the centripetal
tangents, the horizon rule) and samples the camera sixty times a second. It works on stretches
where time is frozen and every key is on one galaxy, in that galaxy's disk axes, where anchors are
fixed points and no take is needed. `"pace": "nearness"` is approximated on a model disk of 20 kpc
(its ramps left out), and the horizon is the scene's natal tilt, so the roll figures are the
least sure. The Cartwheel's one minute film (`film3`), the one that turns ugly after 49 s, is not
in the repository; NGC 2207's film was written after it and is measured in its place, with the
Cartwheel's four earlier flights.

| | NGC 2207 film, 97 to 179 s | NGC 2207 film, 50 to 63 s | Cartwheel 1-collision, 0 to 17 s | Cartwheel 2-centre | Cartwheel 3-edge | Cartwheel 4-again |
|---|---|---|---|---|---|---|
| seconds | 82 | 13 | 17 | 13 | 12 | 31 |
| view turn, peak (deg/s) | 149 | 2 | 9 | 49 | 4 | 56 |
| view turn, 95th percentile (deg/s) | 24 | 2 | 9 | 46 | 2 | 34 |
| seconds turning faster than 10 deg/s | 22 | 0 | 0 | 6 | 0 | 11 |
| view turned in all (deg) | 634 | 10 | 51 | 184 | 11 | 281 |
| turn pick-up, peak (deg/s2) | 249 | 7 | 5 | 153 | 28 | 42 |
| looking over 30 deg off its course (share of time) | 68 % | 0 % | 31 % | 83 % | 0 % | 99 % |
| looking over 90 deg off its course (share of time) | 46 % | 0 % | 22 % | 18 % | 0 % | 76 % |
| seconds the view swings over 10 deg/s against its course | 22 | 0 | 6 | 5 | 0 | 7 |
| roll about the line of sight, peak (deg/s) | 36 | 0.8 | 1.5 | 180 | 0.1 | 30 |

A calm camera turns at about 8 degrees a second: the cinematographers' rule of thumb is that
something should take seven seconds to cross the frame, and a frame 0.6 rad high is 58 degrees
wide. The films are four to twenty times over it, for a quarter of their length.

**Where it happens**, on NGC 2207's stretch, second by second:

- 155 to 159 s, 147 degrees a second. The camera skims the plane looking 30 kpc ahead; the next
  key aims at the centre, which it has just passed. The view goes right round in two seconds.
- 105 to 107 s, 41 degrees a second. The dive's aim is 8 kpc under the disk and the eye runs
  into it: an aim close to the eye turns the view on almost nothing.
- 111 to 117 s, 20 to 27 degrees a second while looking up to 160 degrees off the course: out
  under the disk, looking back up at it.
- 165 to 177 s, 12 to 18 degrees a second, looking 80 to 100 degrees off the course: the turn low
  over the arms is flown sideways, the aim on the centre. The Cartwheel's `4-again` does the same
  over the ring at 18 to 34.
- The Cartwheel's `2-centre` goes down the disk's axis, which is 6 degrees from the world's z:
  the horizon rule lets the picture turn about the line of sight at half a turn a second as it
  comes off the vertical.

Where the keys happen to look where they go (97 to 105 s, 141 to 153 s, the dive into IC 2163,
the Cartwheel's `3-edge`) the view turns under 4 degrees a second: those stretches are already a
ship's.

**The causes**, in the order they weigh:

1. The aim is a point, chosen for the picture at each key, and it jumps from one subject to the
   next between two keys. The view turns as fast as it takes.
2. The eye's path has hairpins of its own: each key is a place worth seeing, and the way from one
   to the next is whatever the spline makes of it.
3. Roll, field of view and exposure are eased to a stop at every key, and the horizon is the
   world's z, which a flight through the vertical flips.
4. Seconds are written by hand on each key, so the speed is whatever distance over time gives.
5. An agent writes some twenty five keys of six numbers from a sentence and sees nothing before
   the GPU draws: `--flight-keys` shows the frames at the keys, where everything is right, not the
   motion between them.

**Two cheap repairs that do not work**, measured on the same stretch:

| | as written | the view smoothed over 4 s | the same path, looking ahead |
|---|---|---|---|
| view turn, peak (deg/s) | 149 | 79 | 155 |
| seconds turning faster than 10 deg/s | 22 | 24 | 16 |
| looking over 90 deg off its course | 46 % | 46 % | 0 % |
| seconds with under a tenth of the frame lit | 2 | 2 | 54 |

Smoothing spreads the whips without removing them. Looking ahead along today's path shows what the
path is: it turns as hard as the view did, and it points at empty space for 54 of its 82 seconds.
The keys were placed to be looked from, not to be flown through. The route itself has to be a
ship's.

## What a ship is

Four rules, each a number the prototype holds:

1. **The view is the course.** The camera looks where it goes. Its gaze may lean towards a place
   by a bounded angle (25 degrees in the example), slowly, as a pilot's head does.
2. **The turn is bounded**, 8 degrees a second, and so is how fast a turn picks up. The gaze's
   lean is taken out of the same allowance.
3. **Always under way.** The speed is a share of the distance to the nearest matter, as #406's
   pace, never under a floor, and it changes by a bounded share of itself each second (0.5):
   thrust and retro-rockets. A stop is something a plan asks for (the hold on a picture), and
   backing away is the same line flown on the retro-rockets, the one case where the view is
   opposite the course.
4. **Up is carried.** The ship keeps its own up through a manoeuvre, banks a little into a turn,
   and comes level on the nearest disk at 4 degrees a second at most. It is never snapped to the
   world's z.

**The prototype** (`fly`). The route is a list of waypoints in a disk's axes. The path is a
uniform cubic B-spline over them, so it passes near each one and its curvature is continuous;
three control points in a line make it pass through a point exactly, on a given heading, which is
what joining a picture's view takes. The speed along it is the lesser of the pace (share of the
nearness, times the leg's tempo) and the turn allowance over the curvature, held to the thrust
both ways along the path, and one factor on the pace is solved when the plan asks for a length in
seconds. Then the gaze, then the up vector.

The same visit of NGC 2207's disk, as the keys make it and as the ship flies it:

| | keys | ship |
|---|---|---|
| seconds | 82 | 102 |
| view turn, peak (deg/s) | 149 | 8 |
| view turn, 95th percentile (deg/s) | 24 | 6 |
| seconds turning faster than 10 deg/s | 22 | 0 |
| view turned in all (deg) | 634 | 493 |
| turn pick-up, peak (deg/s2) | 249 | 7 |
| looking over 30 deg off its course (share of time) | 68 % | 0 % |
| seconds the view swings over 10 deg/s against its course | 22 | 0 |
| roll about the line of sight, peak (deg/s) | 36 | 1.7 |
| seconds with under a tenth of the frame lit | 2 | 0 |

`animatic` draws the two side by side on a model disk of dots, with the turn rate under each.

**What the rules cost**, found by flying, not by thinking:

- **Turns are a budget.** At 8 degrees a second a film of T seconds can turn 8 T degrees at the
  very most, and a half turn costs 22 s and more. The keys turned the view 634 degrees in 82 s.
  A ship's minute holds one half turn and a little more. A ship's film is longer, or visits less.
- **A ship that looks ahead films the void.** The first route kept the keys' order (through the
  centre, out under the disk, round its edge, back along the plane). Every number was a ship's and
  half the frames were black: past a galaxy there is nothing ahead. The route that works stays
  over the disk's footprint when it turns, low enough that the disk fills the lower frame, and
  leans its gaze to the centre. With two galaxies the natural leg after crossing one is towards
  the other. So "is there something in the frame" has to be measured, as the turn is.
- **Up is part of the state.** A dive that starts facing away from where it will pull out goes
  through the vertical the wrong way and the ship comes out on its back; at 4 degrees a second it
  takes 45 s to come level. A dive has to start on the side it pulls out towards.

## A livelier ship, turning its head

Pierre on the first animatic, the same day: smoother, no longer a roller coaster, but too soft,
too much of a spaceship, almost boring. No need to think of a mass that is hard to stop and hard
to turn. The camera may turn its head to look at something, may speed up and slow down harder,
and may turn faster than 8 degrees a second, without becoming brutal.

So rule 1 changes and the numbers move (`ship-flight-head.plan.json`):

1. **The course is the ship's, the gaze is a head's.** The path is still flown forward and bounded
   in turn, 12 degrees a second. The gaze turns to a place named on a leg, up to an angle off the
   course that the leg gives (60 to 150 degrees here, so it can look back at the galaxy it
   leaves), or comes back ahead. It is a tracker in the world's frame: the view never turns faster
   than 22 degrees a second and picks its turn up at 22 degrees a second each second, whatever the
   course does under it.
2. The thrust is doubled (the speed changes by up to its own value each second), the pace is half
   the nearness a second, and the up vector comes level at 8 degrees a second.

The head's rate has to be above the course's: at 16 against 14 the head could not gain on a turn
it was inside, and the frames stayed empty.

| | the ship, looking where it goes | the livelier ship, turning its head |
|---|---|---|
| seconds | 102 | 59 |
| kiloparsecs flown | 147 | 223 |
| view turn, peak (deg/s) | 8 | 22 |
| seconds turning faster than 10 deg/s | 0 | 20 |
| view turned in all (deg) | 493 | 601 |
| turn pick-up, peak (deg/s2) | 7 | 22 |
| looking over 30 deg off its course (share of time) | 0 % | 61 % |
| looking over 90 deg off its course (share of time) | 0 % | 26 % |
| roll about the line of sight, peak (deg/s) | 1.7 | 8 |
| seconds with under a tenth of the frame lit | 0 | 3.5 |

It visits more in less time: down onto the disk with the whole spiral in view, a fast pass low by
the bulge with the head following it, a climbing turn that looks back down at the galaxy, back
down through an arm, out under the disk looking back. The head removes most of what the first
rules cost: a turn no longer empties the frame, since the head stays on the subject while the
course comes round, and a half turn of the course is 15 s. The view still turns seven times
slower at its peak than the keys' 149 degrees a second, and it never jumps: every turn is picked
up and let go.

What the head makes necessary: each leg says what is looked at, so "look at" joins the pace and
the time among a leg's adverbs, and the check on the lit share of the frame is what finds a leg
where the head was left looking ahead at nothing.

## Between the two, flown as a pilot would

Pierre on the second animatic: the right place is between the two. The system should be open,
up to a limit that sits between them. What he does not want from the second: the moments where
the camera "goes off sideways", which he cannot read as a movement at all. What he wants added:
to be able to ask for a hedge-hop, a dive, a turn on the left wing or the right as if pressed by
centrifugal force, the manoeuvres of a pilot (not loops), natural and never abrupt, and none of
the rolls about the line of sight of the films before the spike.

"Sideways" is the head turned far from the course: at 60 to 150 degrees off it, the picture
slides across or backwards while nothing says the camera turned. So the third version
(`ship-flight-pilot.plan.json`) is an aircraft's:

- **The head stays near the course**, 35 degrees at most, at 14 degrees a second. What is in the
  frame is always where the camera is going, give or take a glance.
- **The turn is 10 degrees a second**, the thrust between the two versions (0.75), the speed
  capped at 9 kpc/s.
- **It banks.** The up vector leans into a turn by 3.5 rad for each rad a second of the course's
  turn, 35 degrees at most, eased over 3 s: the horizon tilts as the turn comes on and comes back
  as it ends. That is the only roll there is, and it is tied to the turn.
- **The route is written as manoeuvres**, not waypoints: `dive` and `climb` (a height reached over
  a distance), `skim` (a length at a height), `bank` left or right (degrees of turn, a radius, a
  height reached). `expand` turns them into waypoints from where the camera is and where it
  heads, so a plan holds one point, its start. Each manoeuvre carries its pace and what the head
  looks at.

```json
{"start": {"at": [-44, -24, 26], "toward": [0, -3, 0]},
 "manoeuvres": [
  {"dive": 2, "over": 30, "look": [0, 0, 0]},
  {"skim": 22, "height": 1.5, "look": [0, 0, 0]},
  {"bank": "left", "turn": 180, "radius": 10, "height": 4.5, "look": [0, 0, 0]},
  {"dive": 1.5, "over": 8},
  {"bank": "left", "turn": 150, "radius": 9, "height": -2.5},
  {"skim": 20},
  {"bank": "left", "turn": 220, "radius": 7, "height": 4},
  {"dive": 1.2, "over": 6}
 ]}
```

A dive onto the disk, a hedge-hop past the bulge, a half turn on the left wing over the arms,
down again, a turn on the wing that sinks through the plane, a pass under the bulge, a turn back
up and a last dive on the bulge.

| | the livelier ship | flown as a pilot would |
|---|---|---|
| seconds | 59 | 83 |
| view turn, peak (deg/s) | 22 | 11 |
| seconds turning faster than 10 deg/s | 20 | 14 |
| view turned in all (deg) | 601 | 595 |
| turn pick-up, peak (deg/s2) | 22 | 14 |
| looking over 30 deg off its course (share of time) | 61 % | 33 % |
| looking over 90 deg off its course (share of time) | 26 % | 0 % |
| roll about the line of sight, peak (deg/s) | 8 | 16 |
| seconds with under a tenth of the frame lit | 4 | 12 |

With the head held near the course the frame is again what lies ahead, and the turn over the
outer disk shows little for 12 s: a manoeuvre has to be placed where there is matter to turn
over, which is the planner's work, and the lit share is how it knows.

The bank is the one thing here that today's keys do not carry (below): a compiled flight has to
write it as `roll`, and a roll eased to a stop at each key would pulse.

## Laid over today's file

A ship's flight compiles to today's keys: an eye and an aim every half second, on the galaxy's
disk. Drawn back through the ported interpolation, 206 keys for 102 s give the view within
0.03 degrees and the eye within 30 pc of the ship's, away from the two ends. The livelier one gives 120 keys for 59 s and the pilot's 167 for 83 s,
the view within 0.6 degrees. So the renderer, the
export, the app and the CUDA engine draw it as they are, and `FlightRecorder` already knows how to
choose keys against a sampled path within a tolerance (#298).

What today's file cannot say:

- **Under way at the ends.** A flight is at rest on its first and last key. Compiled keys start
  from rest and catch up within half a second: 0.7, then 14, then 9 kpc/s, where the ship
  holds 11 to 9. A ship's flight needs
  its ends moving.
- **The roll.** It is eased to a stop at each key and counted from the world's z. A steady bank
  written every half second would pulse, and a dive near the world's vertical has no horizon to
  count from. The prototype's compiled flight carries no roll and takes the world's horizon.
- **Time that runs.** Everything here is with time frozen. A path in one galaxy's frame is carried
  with it as keys are today; a leg from one galaxy to the other while they move is not worked out.

## From plain words to a flight

The agent should never invent a coordinate. Three layers, each closed:

**Places**, read from the take: a galaxy, its centre, its disk and spin, its edge, its arms by
radius (`flight --arms` finds them), a ring, the other galaxy, the look's view, a picture's view
(`match`). Today `flight --at` prints these as text for a person; a chart of the scene as JSON
would let a plan name them.

**Manoeuvres**, each with a few numbers in the subject's own units and a default for every one.
The prototype's four (`dive`, `climb`, `skim`, `bank`) are the pilot's words; the table adds the
ones that name a place:

| manoeuvre | what the ship does | what it costs |
|---|---|---|
| open on a view | starts on the look's or a picture's framing, already moving in | nothing |
| approach | heads for a place, slowing as it nears | no turn |
| pass over | levels above a disk at a height, the disk in the lower frame | a pull out, 5 to 10 s |
| skim | crosses a disk just above its plane, through arms or a ring | no turn |
| follow an arm | flies along an arm's ridge for a length | a gentle turn |
| turn over | a banked turn above the disk, gaze to the centre | 22 s a half turn |
| dive through | crosses the plane at a place, at an angle | no turn, then matter is behind |
| cross to | heads for the other galaxy | a turn, then a long straight |
| join a view | lines up behind a view and arrives on it, exactly | an approach on its axis |
| hold | stops on a view for some seconds | the only stop |
| back away | retro-rockets, on the line of sight, the subject shrinking | no turn |

**Adverbs**: the pace of a leg (slow, cruise, fast), what the head looks at on it (ahead, a
place, and how far round it may turn), the take's time on a leg (runs, slows, frozen, a moment
pinned where a manoeuvre starts), and the film's length.

A sentence becomes five to ten manoeuvres. The pilot works every number out, and the check
answers in words an agent can act on or pass on: this turn does not fit in the seconds asked, the
frame is empty for 12 s after the dive, the ship is on its back at the pull out.

"Come in on the picture's view, hold it, dive on the ring, skim through it, turn over the disk
and leave towards the companion" would read:

```json
{"version": 1, "seconds": 90,
 "legs": [
  {"open": "picture", "myr": 394.5},
  {"hold": 9},
  {"approach": {"galaxy": 0, "ring": true}, "pace": "cruise"},
  {"skim": {"galaxy": 0}, "height": 1.5, "pace": "slow"},
  {"turn over": {"galaxy": 0}, "radius": 13, "turn": 180},
  {"cross to": {"galaxy": 1}, "myr": 420}
 ]}
```

This vocabulary is a proposal. It is not tested against real requests: three of Pierre's, written
as plans by hand, would show what is missing before any of it is built.

## Seeing it before the GPU draws it

1. **The check**: `measure`'s table, with limits. It works on any flight file, a hand written one
   included, and takes no GPU.
2. **The animatic**: dots from the camera, drawn on the CPU. The 102 s side by side took four
   minutes in a cloud container with 157 000 points. On a take thinned to that many particles it
   shows the real scene's motion, and an agent can look at its frames itself before a GPU hour is
   spent.
3. **Stills in the real look**, `--flight-at`, then the export.

## Bricks

In the order they pay:

1. **`flight --check`**: the measures and their limits, as text and JSON, for any flight. Small.
   It stops a whipping flight today, whoever wrote it.
2. **The pilot**: a plan file flown into `flights/<name>.flight.json`, in Swift beside `Flight`,
   with the take's own nearness and `FlightRecorder`'s choice of keys, tested on Linux. First with
   waypoints, as the prototype. The largest brick.
3. **The flight file, for a ship**: ends under way, a roll that does not stop at each key, a
   horizon carried or taken from a disk. Small to medium; it touches `Flight`, so both engines.
   The bank needs the roll, so this comes with the pilot, not after it.
4. **The chart**: a scene's places at a moment, as JSON. Small.
5. **The animatic**: the prototype's, on a thinned take. Small.
6. **Manoeuvres and the guide's recipe**: the table above on top of the pilot and the chart, and
   the section of `AGENTS.md` that says how words become a plan. After 2 and 4, and after the
   three requests written by hand.

Left for later: the same inertia in the app's free flight, so a flight can be flown by hand and
come out as calm; legs between two galaxies while time runs.

Not recommended: smoothing today's keys, or an `"aim": "ahead"` on them (the table above); a
parser of plain words in Sillage (the agent is the parser; the plan file is what it writes).
