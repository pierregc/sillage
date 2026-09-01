# Working notes

Read `README.md` for what the project is and how it works. This file is only the things a
fresh session cannot deduce from the code.

## This machine

**Xcode is not installed**, only the Command Line Tools. Two consequences:

- Metal shaders are compiled at runtime through `MTLDevice.makeLibrary(source:)`, so a syntax
  error in MSL only shows up when a pipeline is first built. `allShadersCompile` and
  `allBarnesHutShadersCompile` in the tests exist to force that early. There is no GPU frame
  debugger and no Metal shader profiler.
- **SwiftPM is broken**: the CLT ship a `PackageDescription` whose interface and dylib
  disagree, so every manifest fails to compile, including the one `swift package init`
  generates. `Package.swift` is kept correct for CI, which runs on a GitHub macOS runner where
  Xcode is present, but locally everything goes through `scripts/dev.sh`:

```
./scripts/dev.sh test     # builds and runs the whole suite through swiftc
./scripts/dev.sh lint     # swift-format, strict
./scripts/dev.sh render   # the headless renderer, takes the CLI flags
./scripts/dev.sh app      # builds and bundles Sillage.app
```

**Screen recording is not granted**, so `screencapture` fails and the app window cannot be
looked at directly. Seven modes replace it, and they are the only way to verify the app:

```
Sillage.app --selftest    # model, solver, renderer and preview offscreen; writes out/selftest.png
Sillage.app --verify      # opens the window and drives the view, reports frames drawn
Sillage.app --uishot      # renders the panels through ImageRenderer to out/
Sillage.app --presets     # cycles the setup presets with the window up
Sillage.app --responsive  # runs a self-gravitating scene, reports how long the main actor stalls
Sillage.app --qa          # walks the whole run flow and reports every check
Sillage.app --cinema N    # contemplation for N seconds, paced to 60 Hz, reports lateness
```

`--qa` is the one to run after touching anything in the app: it sets up a scene, launches it,
watches it capture, pauses it, stops it, replays it, scrubs it, picks it back up, starts over,
fills the memory budget, and does the last of it again on the self-gravitating solver.

A check that disappears is worse than one that fails. `--qa` used to give the memory budget a
fixed pause to bind in, and it landed just short often enough that three checks about thinning
skipped themselves while the run still printed everything green. It waits for the condition now.
Anything guarded by `if` in `QACheck` deserves the same suspicion.

`--presets` is the only mode that catches a stale index in the galaxy list: `--uishot` builds
the view tree once and never updates it, so a card that crashes on the *change* of a preset
renders perfectly there.

`--verify` drives the canvas itself rather than waiting on the display link, because a window
opened behind another application counts as occluded and MTKView parks its display link. A
report of zero frames means occlusion, not a regression.

## Conventions

- Conventional commits, small, minimal `-m`. **No `Co-authored-by` trailer.**
- Comments are sparse and explain why, never what.
- **Never push without explicit approval.** `origin` is `git@github.com:pierregc/sillage.git`
  and `main` tracks it. The milestones do not exist yet.

## Habits worth keeping

- Render previews small when the point is to judge a look. A 900 px image answers the question
  a 5000 px contact sheet answers, at a fraction of the context.
- Prefer targeted edits over rewriting whole files: rewriting through a shell heredoc makes the
  harness echo the entire file back as a diff.
- Editing the MSL strings by pattern is fragile because the formatter reindents them. Match on
  distinctive lines without assuming leading whitespace, and always assert the pattern was
  found; a silent no-op replacement has cost hours here.

## Takes on disk

A run costs minutes and six bytes a particle a frame, so a quarter of a million particles over
five hundred frames is three quarters of a gigabyte. `RecordingFile` keeps one: the scene, the
per-particle attributes, the frames and the quantised positions. Reopening it is not watching a
video — nothing about how it looks is in the file. Exposure, colour, the telescope and the
camera are all decided at draw time and stay live, and the take plays with no solver behind it.

A take that outlasts its budget thins itself rather than stopping: it keeps every other frame
and captures half as often from then on. A long run therefore comes back whole at a coarser
cadence, which is the useful thing when it was left running overnight. Halving in place keeps
the spacing uniform — existing frames double their spacing and new ones arrive at the new
stride — so playback never meets a seam.

Three measurements shaped how a take is held, none of them obvious from reading the code. At
1.7 GB captured: growing the buffer a frame at a time peaked at 3.5 GB, because the array
doubles and both copies are briefly resident, so the room is reserved from the budget up front.
Writing copied the whole run into a `Data` first, costing another 1.7 GB, so it goes out of the
take's own memory in bounded pieces. Reading copied twice, peaking at 3.4 GB, so a loaded take
now stays in the mapping instead. Write and read peaks are 1 MB and 4 MB.

Two things the format leans on. The bulk sits at the end so it reads as one run of bytes, and
the file is memory-mapped rather than loaded: a take is often larger than is comfortable to
hold twice. And frames are written field by field rather than as a struct, because a `SIMD3`
carries invisible padding and a file that depends on it breaks on the next compiler.

## Long runs

Verified rather than assumed, because every part of it had a surprise in it.

**Memory holds.** A take is bounded by its budget and nothing doubles around it any more: the
buffer is reserved up front, written out of its own memory, and read back through the mapping.
1.7 GB captured now peaks at 1.72 GB, writes at +1 MB and reads at +4 MB.

**Nothing diverges.** A gigayear of a self-gravitating merger at 200 000 simulated particles
leaves no non-finite position and a sane mean radius throughout.

**The cost per step used to climb, and that was the real limit. It no longer does.** A merger
at 750 000 simulated particles went from 57 ms a step at 50 Myr to 257 at 450, and the interval
of simulated time bought by a minute of wall clock fell with it. Three faults, all in the
traversal, all now fixed — see "Why a step no longer gets slower". The same run is flat at
31 to 35 ms across the whole stretch, and 7.3x faster at the far end.

The running panel's Myr/s is measured, not predicted, and the setup screen's estimate is taken
at t = 0. Both were honest before and are simply steadier now.

**Beware of measuring under contention, and of your own leftovers.** A run launched alongside
the app crawled at a thirtieth of its speed and looked exactly like a solver regression. It was
not. Twice. The second time an orphaned probe from half an hour earlier was still on the GPU,
and worse, it held its own executable open: `swiftc -o` failed with "Text file busy" and the
stale binary ran on, so three rounds of "I reduced the particle count" changed nothing at all.

Before timing anything: kill the app, `pgrep -f scratchpad/` for leftovers, and check that the
compile actually succeeded rather than trusting that it did.

## The picture is not free

The setup screen's preview was taking most of the GPU while nobody touched anything: it never
steps, and it was redrawing three hundred thousand particles sixty times a second to show the
same still. It draws on demand now — `--presets` went from 353 draws over its walk to 7.
Anything that changes what the preview shows has to say so, through `redrawPreview()`.

The running canvas draws at sixty rather than a hundred and twenty, and can be switched off
entirely while a scene is computed: `showCanvasWhileRunning` takes the `MTKView` out of the
hierarchy, and `draw(in:)` refuses anyway, because the view outlives its removal by a frame or
two. With a finish and a destination set, `quitWhenFinished` closes the application once the
take is on disk.

## What a played-back frame costs

Playback stuttered at five million particles with the GPU only half busy, which is the
signature of a stall rather than of a shortage of throughput. It was a memcpy on the main
thread: every displayed frame copied *both* surrounding snapshots into a staging buffer —
sixty megabytes, measured at 33 ms against a 16.7 ms budget — and on a take larger than the
page cache the copy went to the disk as well. Most of it was wasted twice over, because at the
default speed the playhead crosses a snapshot only every other frame, so half the copies were
of data that was already there.

`SnapshotStream` copies each snapshot once, on a background queue, before it is wanted, into a
direct-mapped cache (`index % slots`) that the expand kernel reads in place — the kernel takes
the two snapshots as separate bindings so neither has to be moved next to the other. On
save01.sillage at 5.2 M particles, a whole frame including a 2560x1440 render: 35.2 ms to
8.7 ms median, 109 frames a second, nothing over budget in 206 frames.

Two things were suspected and measured innocent, so do not go after them again without new
evidence. The smoothing refresh looks alarming — 130 ms of tree build over five million
particles every twenty frames — but it already runs on the simulation queue and is entirely
CPU: frame times with it are 9.2 ms against 9.1 without. And `expand`'s `waitUntilCompleted`
costs about 2 ms; it is what lets the reader overwrite slots without racing the GPU, and it is
worth keeping until something needs those two milliseconds.

## Flying rather than orbiting

`FlyCamera` is a position and a direction, alongside the orbit rig rather than replacing it:
one answers "look at this galaxy from there", the other "go inside it". `F` swaps them, and
each adopts the other's view so the picture never jumps — `theTwoRigsHandOverWithoutJumping`
guards that in both directions.

Two things make it watchable rather than merely working.

- **Keys are held, not handled.** `keyDown` only records that a key is down; the frame reads
  the set and integrates a velocity against the real frame interval. Moving the camera from
  the events themselves would move it at the key repeat rate, which arrives in irregular
  bursts and reads as judder however smoothly the scene is drawn.
- **The rig is not `@Published`.** It changes sixty times a second, and publishing that would
  rebuild the whole control panel at frame rate — which is the very thing the section above is
  about. Only `isFlying` is published.

The flight advance sits ahead of every guard in `draw` that can decline to render: an occluded
window hands back no drawable, and a camera that stopped dead whenever that happened would be
worse than one that flies with nothing to show for a frame. That is also why the `--qa` checks
can see it at all, since the window there is always occluded.

## Keeping the machine usable

Three things, all measured, none of them the renderer.

- **Dark matter was being drawn, recorded and smoothed.** It is three particles in five in a
  self-gravitating scene and reaches no pixel. The sampler now puts visible particles first, so
  the draw call, the take and the smoothing field all stop at `visibleCount`. At three million
  stars a take frame went from 43 MB to 17, and replay from 14.7 ms to 11.8 — 85 frames a
  second at three million.
- **The simulation queue runs at utility.** The tree build fans out over every core through
  `concurrentPerform`, which inherits the calling thread's class, and at default priority a big
  scene makes the whole machine unusable rather than just this window. Measured at a million
  particles: 112.7 ms a step against 116.7. It is free. Background would cost 70 %.
- **The force pass is dispatched in pieces of a million.** One kernel over seven million
  particles holds the GPU for the best part of a second. `splittingTheForcePassChangesNothing`
  guards it, and it has to: without the chunk offset the second piece recomputes the first
  one's particles and leaves the rest of the scene carrying stale accelerations, which no test
  at one chunk can see. Verified by breaking it on purpose.

A run also has a finish now. `stopAtMyr` ends it and switches to replay, and a destination
armed beforehand writes the take out with nothing to press.

Exposure divides by the particles that reach a pixel now, not by every particle simulated, so
switching live halos on no longer dims a scene by the halo ratio. The warning that used to sit
here — that fixing it would brighten every self-gravitating scene by two and a half and mean
retuning everything — was right about the linear factor and wrong about the picture. The
logarithmic stretch and the filmic shoulder absorb almost all of it: mean luminance of a
rendered frame went from 18.19 to 21.19, sixteen per cent, and nothing needed retuning. The
galaxies now carry their own diffraction spikes, which they could not reach before.

## The model, and why it is still one file

`SimulationModel` carries eight concerns at once — camera and flight, the pace of the solver,
capture, playback, the setup preview, the picture's settings, files, contemplation, telemetry —
and it is a single main-actor `ObservableObject` that every view observes. It is the one place
in the app that is genuinely too big.

**Two thirds of it cannot be split with extensions, and finding that out is worth not repeating.**
Swift's `private` is file-scoped, so a member moved into `extension SimulationModel` in another
file loses access to everything private the type holds. Measured on the actual split: moving the
stepping, capture, playback and preview groups out would force **twenty-nine** `private(set)`
properties open — `elapsedMyr`, `mode`, `capturedFrames`, `recording`, the preview's whole
renderer, and so on. Those private setters are the only thing stopping a view from writing the
clock or the capture counters, so that is a real guarantee traded for moving text between files.
Not worth it.

What did move cleanly is what writes nothing protected: `CameraControl.swift` and
`SceneDraft.swift`. The rest is bounded by state, not by code, so the honest fix is extracting
owned objects rather than extensions — `ScenePreview` first, since the setup preview is an
entirely separate renderer with an entirely separate lifetime. That is a bigger change: it moves
view bindings and needs its own republishing.

**What did come out of the model is the picture's settings, and that was worth doing on its own.**
There were three copies of the same numbers: ten `@Published` knobs each with a `didSet` calling
a one-line setter on `Renderer`, a `lookExtras` holding the eight fields with no slider, and
`RenderSettings.init`'s own defaults. Adding a setting meant editing three places and the third
was easy to miss. It is one `RenderLook` now, and `Renderer.apply` — which already existed and
already covered every field — replaced the ten setters.

Two things that surfaced while collapsing it, both pre-existing:

- **The panel's opening values were never `.observatory`, though the picker said so from the
  first frame.** Choosing Observatoire from the picker visibly changed the picture it claimed to
  already be showing. Kept exactly as it was, as `SimulationModel.openingLook`, because every
  rendered comparison in these notes was made there — but the picker still lies, and reconciling
  the two is a look-tuning decision, not a refactor.
- **The setup preview ignored the eight fields with no slider.** It matched at startup only
  because `RenderSettings`'s defaults happened to equal the model's, and diverged the moment a
  named look was chosen: kernels, bloom knee, diffraction pattern and star size never reached it.
  It builds from `renderSettings` now, so the preview is a preview.

A render is the only proof a change like this is neutral. `--selftest` writes `out/selftest.png`
and is deterministic to the byte; both commits here left it identical.

## Star formation, and why density alone gives no burst

The HII regions were decorative and the notes said so. They were placed by the sampler and
then lit by the *painted* spiral pattern — `alive = forming`, where `forming` came from the
texture — so the pink knots followed a picture rather than the physics: they sat wherever the
sampler had left them an orbit earlier, and none appeared anywhere new however violently the
galaxy was disturbed.

They now come from a rule. Gas turns into stars where the tree says it has been compressed,
and each knot announces itself in Halpha for a few million years, fades blue over a few
hundred, and settles into the disk.

**The tree already holds the density.** A leaf is a cell of known width holding known mass,
which is a density estimate for free — no neighbour search, no second tree, and the same
estimator everywhere so a nucleus and a tail are compared on the same footing. Only the visible
material is counted: dark matter is three particles in five and most of a leaf's weight, and
including it made the rate follow the halo rather than the disk.

**Density alone gives no starburst, and that is the whole reason the compression term exists.**
Star formation eats the densest gas first, so a merger driven by density arrives at pericentre
with its nucleus already spent. Measured on the way to finding this out: forty knots a megayear
at the start, nine at coalescence, monotonically falling, with nothing at pericentre at all.
Real mergers burst because tidal torques drive *fresh* gas inward and shock it, and there is no
inflow here — but the shock is visible in the flow itself, as the convergence of the velocity
field over a leaf's own particles.

**Rectifying a noisy estimator turns its noise into a rate.** `max(-div v, 0)` over sixteen
particles is not zero on average even where nothing is happening, and with no floor a quiescent
disk burned ninety-six per cent of its gas before its encounter arrived. The noise sits at order
unity — a disk in equilibrium has its dispersion over its scale height comparable to its own
free-fall rate — so only convergence well above that counts. Fifteen.

**The observed efficiency is the wrong number to use here, and using it was worth a control
run.** One to two per cent per free-fall time is right for the dense molecular phase on the
free-fall time *of a cloud*. What is available here is the mean density of a whole leaf over
gas that is mostly not in that phase. Applied directly it gave a depletion time of 950 Myr
against the two to three gigayears a real disk shows. Calibrated against what a quiescent disk
does instead: 1.2 Gyr.

**Always run the isolated disk as the control.** Every wrong calibration above looked fine on
the merger alone — there was always a bump somewhere. What exposed each of them was the same
scene with nothing to collide with, which burned its gas just as fast. The two runs together
are the measurement; either one alone is not.

Where it ended up, per forty-megayear window at sixty thousand particles:

    quiet   330  355  366  351  271  266      peak 1.11x the first window
    merger  213  261  544  210  437  739      peak 3.5x, at pericentre and coalescence

**One static array carries the whole history.** A formation time is written once, by the solver,
and never rewritten. So a take stores it once and replaying at any moment shows exactly the
knots that had formed by then — no per-frame colour, no per-frame component. That invariant is
what `gasFormsStarsExactlyOnce` guards, and it is why the take format went to version 2 rather
than growing a per-frame field. Version 1 is still read: those runs have no history, so their
sampled knots are given the spread of ages the sampler would give them now, which replays closer
than making the whole galaxy uniformly old.

**A test that passes on one realisation is not passing.** `liveHalosConserveMomentumFarBetterThanARigidOne`
asserted a ratio under 0.25 and got 0.32 the moment an unrelated change added a draw to the
sampler's random stream and moved every particle. Nothing was wrong: across five seeds the ratio
runs 0.05, 0.07, 0.17, 0.23, 0.32, because the rigid halo's leak depends on the details of the
encounter and swings fourfold. It sums three seeds now. Anything here whose threshold was fitted
to a single run deserves the same suspicion.

## What the window costs

Anything on the main actor is the interface's frame budget. Three things were spending it and
none of them looked expensive:

- **Launching.** Sampling four million visible particles takes 4 s and building the solver 5 s
  more. Both ran on the main actor, so a large scene froze the window for nine seconds with a
  black rectangle to look at. Both are on the simulation queue now, `isPreparing` says so, and
  `--responsive` measures the stall a launch still costs: 85 ms at two million.
- **Placing the camera.** `frameCamera` sorted every particle's radius to take a percentile:
  400 ms at five million, to point a camera. Fifty thousand of them answer the same question.
- **The setup preview.** 140 ms of resampling on every slider release, twenty sliders deep.

Anything that walks every particle belongs off the main actor. That includes the smoothing
refresh and the first captured frame, both of which look like bookkeeping and are not.

## Why a disk keeps its arms

A disk of stars and nothing else can only heat. Every spiral it raises stirs it further, the
Toomre parameter climbs past what can be amplified, and the arms stop coming. Measured here
on an isolated self-gravitating disk: real structure at 300 Myr, a featureless spheroid by
1200. Real disks escape that because their gas radiates the motion away and forms new stars
on circular orbits faster than the spirals heat them.

`dissipationTime` puts that back: each step, disk material is pulled a little towards the
circular orbit it would be on, on a time constant in Myr. Three things make it work rather
than wreck the galaxy.

- **The target comes from the force field**, not a table. The solver has just computed the
  acceleration, and a circular orbit is what balances it, so `v = sqrt(|a_r| r)` is
  self-consistent with whatever mass is actually there.
- **It stops at the Toomre dispersion.** Cooling the whole way drops Q below one and the disk
  fragments into clumps, which is exactly what the first attempt did. The floor is the full
  three-dimensional equilibrium dispersion; flooring at the radial component alone still
  fragments, because the radial part then sits below what Toomre asks.
- **It only touches the disk.** Halo and bulge are excluded by component, and the weight fades
  out past four scale lengths and four scale heights. A tidal tail is material thrown clear on
  no circular orbit at all, and cooling it would quietly erase what an encounter is watched
  for.

## Why a merged disk stays merged

Everything above is right for a galaxy left alone and wrong for one in a collision, and the
three faults it had were all invisible in an isolated run. What it was doing, found in a
three-galaxy take and measured out of the take itself: the steeply inclined disk heated from
0.24 kpc thick to 11.7 through the encounter and was **back to 1.04 four hundred megayears
later**, still within five degrees of the plane it was born in and eighty-three degrees from
the remnant it had supposedly joined. A cold thin disk sitting inside an elliptical, refusing
to mix. The primary did the same thing less visibly — 0.046 flattening to 0.152 and back to
0.042 — because its natal plane was already z = 0.

- **The plane cooled towards has to be measured, not configured.** `galaxy.orientation` is
  where the disk *started*, and pulling stars towards a circular orbit about it is a spring
  back to the natal plane, which is the one thing a collisionless system cannot do. The axis
  is now the mass-weighted angular momentum of the galaxy's own disk material about its own
  moving centre, taken on every tree rebuild, so it tumbles, precesses and warps with the disk.
  It carries the sense of rotation in its direction, so the separate spin sign is gone.
- **It has to stop while the galaxies are inside each other.** The cooling stands for gas
  sitting in a quiet cold layer and forming stars on circular orbits; during an encounter that
  gas is being shocked, driven inward and burned. The gate is the disk's radius over its tidal
  radius in the companion's field, `r_t = d (M / 3 M_companion)^(1/3)`, faded between 0.7 and
  1.4. Scale-free on purpose: a small satellite passing close must not switch a large disk's
  cooling off the way an equal-mass companion does. It comes back on if the two separate again
  without wrecking each other, which is what a fly-by is.
- **And it must not come back once the disk is gone.** A ratchet on the ordered-rotation
  fraction, |sum m l| / sum m |l| over the same material the cooling touches: never given back
  once earned. Without it a merged remnant keeps a little net spin, that reads as a disk, and
  the cooling starts rebuilding whichever galaxy it belongs to.

**The threshold for that ratchet cannot be picked for a non-rotating spheroid.** A merger
remnant inherits the pair's orbital angular momentum, so it settles at 0.60 to 0.72 and never
goes near zero; anything tuned for 0.2 simply never fires. The margin is elsewhere and it is
wide: an isolated spiral sits at 0.997 and stays within a thousandth of that for nine hundred
megayears, and a fly-by host dips only to 0.95 and recovers. Hence 0.75 to 0.92.

**The obvious scene does not catch any of this, and that cost a first round of tests.** On
`SceneConfig.merger` — equal masses, coplanar — the two disks coalesce so completely that the
cooling has nothing left to rebuild, and a test there passes with the fault fully in place.
The fault needs an encounter the smaller disk *survives* as an entity: an unequal pair, a third
the mass, steeply inclined. `aMergerLeavesTheDisksHeated` is that scene, and it watches the
primary rather than the companion, because "a galaxy of a third your mass plunged through you
and your disk is no thicker for it" is the cleanest statement of what was wrong. Ungated:
0.62 kpc thick before, 0.81 at worst, 0.69 at the end. Now 1.13 and 1.12.

Three hundred thousand particles a galaxy is not what any of this is measured on. Fifty
thousand answer it, and the whole pass costs 0.7 ms of an 82 ms tree rebuild at three million
simulated particles.

Replaying the same three-galaxy geometry through the fix, against the numbers at the top of
this section: the inclined disk goes 0.24 to 21.5 kpc thick and stays there, its plane wanders
sixty degrees off where it was born, and its half-mass radius grows to five times the
primary's. It is an envelope around the remnant rather than a disk inside it.

## Why a step no longer gets slower

A merger used to cost 57 ms a step at 50 Myr and 257 at 450, on the same number of particles.
The node count *falls* over that stretch, which is what made it confusing: the tree is not
growing, it is getting coarser, and the traversal pays for that. Three separate faults, each
measured on its own.

- **A leaf was always summed particle by particle, however far away it was.** The opening
  criterion was tested for branches only, so a distant cell holding two thousand particles
  cost two thousand evaluations instead of one. Testing leaves the same way as branches: 2.6x
  on a concentrated cluster, and it is worth more the further a run has gone, because that is
  when leaves grow. Mean force error against direct summation moves from 0.106 % to 0.128 %.
- **The tree could not go deeper than ten levels**, because a 32-bit Morton code holds ten
  bits an axis, and a collision hits that ceiling on the first step. Meanwhile the root box
  grows — 179 to 382 kpc over 450 Myr as debris is thrown out — so the cells at the bottom
  cover more space every step while the disks concentrate into them. The largest leaf reached
  3363 particles. Codes are 64-bit now, twenty-one bits an axis, and the build costs 6 ms more
  and the force pass 70 ms less.
- **The traversal stack could overflow, and overflowing meant silently dropping cells** and
  their mass out of the sum. It pushed one entry per pending sibling, so up to seven a level:
  sixty-four slots were already not enough at ten levels, let alone twenty. It now pushes one
  entry per *range* of siblings — they are contiguous — which is one entry a level, bounded by
  the depth of the tree. Thirty-two slots, provably enough, and half the thread-private storage
  of the old sixty-four.

That last one supersedes an old note here warning that shrinking `int stack[64]` looks like a
4x speed-up and is worthless because the error explodes. It was right at the time. The stack is
small *and* correct now, because what bounds it changed.

Sixty-four bit codes then made the build the next thing to look at — 178 ms against 244 for the
force pass at five million particles, two thirds of it in the sort. The sort carried indices
and read the key back through them, so every count and every scatter was a random access into
forty megabytes. It now sorts the codes themselves with the index alongside: twelve bytes moved
in order beats four moved at random, the sorted codes fall out of the last pass instead of
needing a gather, and one array of the three is gone. 113 ms to 46, and the build back to
109 ms — near where it was before the codes grew.

Together: flat at 31 to 35 ms from 50 to 450 Myr, against 57 rising to 257. The whole run to
450 Myr takes 449 s against 930, and the instantaneous step at the far end is 7.3x faster —
an advantage that keeps widening, since the old curve was still accelerating.

## Contemplation

Full screen, no panel, nobody at the keyboard: `Cinematographer` frames and lights a generated
scene and replaces it with another through a fade. Two paces — brisk, a whole encounter in a
minute, and slow, five minutes to breathe — and the choice drives everything: the oscillator
periods, the length of a shot, how fast the camera turns, the rate of simulated time, and how
close together the galaxies start. Space moves on now; escape leaves.

`--cinema N [slow]` is the only way to check this on a machine with no screen recording, and
**what it measures matters more than that it exists**. The first version ran draws back to back
and reported a healthy median while the real thing visibly stuttered: the cost of a draw is not
what a viewer sees. It now paces itself to sixty hertz and measures *lateness* — and reports
separately how many late frames landed while the screen was actually showing something, since
the swap between scenes happens under a fade already at black.

Level 2. Level 1 has nothing inside it to fly through: painted arms look right from far off and
go flat the moment the camera enters the disk. Self-gravity is what makes structure that holds
up close, and four things together are what make it affordable at sixty hertz.

- **The solver is paced, not run flat out.** It steps only as often as the asked rate of
  simulated time needs, so it takes that share of the GPU and no more. Above capacity the
  pacing stops protecting anything, so the rate has to sit well under it — at 450 k particles
  the solver can do 13 Myr/s and is asked for 5.
- **Fewer, larger steps.** A step costs a tree built across every core as much as it costs the
  GPU, so halving their number is worth twice what tuning the force pass is. 20x to 26x the
  tuned step, which through pericentre sits inside the encounter's own chaotic scatter.
- **A wide opening angle.** 0.85 against the usual 0.6 is most of a factor of two off the force
  pass for half a percent of error. Nothing here is being measured.
- **Compiled libraries are cached.** `makeLibrary` is a full compile of a source string that
  never changes, and rebuilding the renderer for a new scene did it on the main thread: one
  frame a full second late, every scene. `ShaderCache` holds them for the life of the process.

**Three separate things were called "the stutter", and only the last two were.** The order
they were found in is the useful part, because the first two were measured, fixed, and turned
out not to be it.

- **The galaxies jumped while the starfield glided.** A viewer said exactly that, and it names
  the cause: the background follows only the camera, so a smooth background with jerky galaxies
  is not dropped frames at all — it is the simulation advancing in leaps. Large steps are
  cheaper for the same simulated time and that is precisely the wrong trade here. What the eye
  reads as motion is how *often* positions change, not how far they move. Two steps a second at
  four megayears each became sixty at a fifth of one, by taking small steps and reusing the tree
  across five of them (`treeReuse`) — the build is most of what a step costs, and a particle
  crosses a fraction of a leaf cell in that interval.
- **Kernels are sprites, so their size is squared in fill rate.** Raising the ceiling six-fold
  to hide the graininess of a close shot had particles painting a 384 pixel square each: 27 ms
  of GPU a frame against 1.8 for an ordinary run of four times the particles. Capped in
  absolute pixels as well as in multiple.
- **Full screen on a retina panel is 7.5 million pixels** against 2.3 for a window, and every
  stage — splatting, six levels of bloom, the composite — is paid per pixel. `pixelBudget` caps
  the drawable at four million and lets the compositor scale.

Together: 26.9 ms of GPU a frame to 4, and the solver's burst from 173 ms to 6.

**Measure a frame's cost over a whole scene, never at a moment.** The GPU time of one frame
says almost nothing: a particle is a sprite whose area goes as the square of its kernel, so a
close shot costs several times a wide one at the same particle count, and a single reading
picks up whichever shot happened to be running. Reading one is how 450 000 particles looked
free and 700 000 looked impossible when the difference was the shot. Across a full 62 s scene:
250 000 costs 3.9 ms a frame and misses one slot in 3 675, 400 000 costs 9.2 and misses
sixteen, 700 000 costs 34.7 and misses one frame in two. The kernel ceiling is capped at 70
pixels for the same reason — at 140 the close shots alone took the median from 4.7 ms to 20.

**Leaving contemplation must not happen inside the key handler.** Escape crashed the app:
`stopContemplation` changes `stage`, which tears down the very view whose `keyDown:` is still
on the stack, and takes the window out of full screen while AppKit is mid-transition. Both are
deferred to the next turn of the run loop now. `--cinema` exercises the teardown on every run
rather than behind a flag, because it only happens when somebody presses a key and no check
went near it.

A trap worth naming, met while fixing that: `pause()` compiles anywhere Foundation is imported
and resolves to the **POSIX** call, which suspends the thread until a signal arrives. It is not
a method on anything here. Check that a symbol you did not write exists before trusting that it
compiled.

The bank's depth is the thing to get right, not its wiring. At a fifth either side it was
working and could not be seen: the frame's mean luminance moved thirty per cent between the
extremes of a three minute period, which nobody notices while the camera is also moving. At
roughly half either side the colour in the frame moves by a factor of three and the bloom by
five. When somebody says a modulation is not reaching the picture, measure the picture — same
scene, same camera, several moments — before touching the plumbing.

`I` shows what the oscillators are doing, live. Two things about it that were wrong first.

A `ZStack` does not reliably put SwiftUI content above an `NSViewRepresentable` whose view is
layer-backed: the Metal layer draws over it and the overlay is simply never seen, which is what
happened. Everything drawn over the scene is a subview of the canvas now
(`PassThroughHostingView`), where the ordering is AppKit's own. `--uishot` renders the overlay
offscreen so it can be looked at at all on this machine.

And it runs on a `TimelineView` at ten hertz rather than on the model's publishers: the values
change sixty times a second, and republishing them would rebuild every view observing the model
at frame rate, which is the whole of what makes a picture stutter. The visibility flag lives on
the model rather than in the view, because a `@State` flag cannot be seen from outside and
there was then no way to tell a key that never arrived from an overlay that never drew.

**Saturation has to be applied on both sides of the tone curve.** The filmic shoulder pulls
bright values toward white by design — right for a photograph, wrong for a galaxy whose core is
the most interesting colour in the frame. Doing all of it beforehand, as it was, does not
survive the curve: the cores came out white. Half the amount either side gives the same overall
push and leaves the highlights a hue.

Diffraction spikes are gathered from the already blurred bloom source, so past about forty
pixels they stop being spikes and become soft cones that sit still on the screen while the
stars slide underneath. `RenderLook.calm()` shortens them and shrinks the field stars for
contemplation, where nobody is there to be impressed by an instrument.

Two measurement lessons sit underneath all of that. `present` commits and returns, so timing
around it measures encoding and not drawing — `lastGPUMilliseconds` comes from the command
buffer's own clock, and until it existed half the frame was invisible. And a viewer's report
that a classic run of nine times the particles was smooth is what finally ruled out the solver:
`--cinema classic` runs an ordinary scene through the identical harness for exactly that
comparison, and showed classic with a 207 ms burst and contemplation with 24, the wrong way
round from the complaint.

The rest of this section is what was fixed before that, and still holds.

**The solver's uninterrupted burst matters too, though it was not the stutter.** A viewer reported half a second of picture followed by half
a second of freeze while `--cinema` reported a healthy median, and the two were consistent: a
step held every core for 173 ms and the pacing then idled for 370, which is that half-second
cycle exactly. What brought it to 30 ms, in the order the measurements found them:

- **The smoothing field builds a tree of its own**, and it was doing so three times a second on
  top of the solver's. That alone was most of a second of saturated cores per second. In
  contemplation it refreshes every 240 frames instead of every 20. An earlier note here had
  measured this same refresh innocent — during *playback*, where there is no solver competing
  with it. It is not innocent next to one.
- **Four steps a pump** is a burst four times as long for the same work. One.
- **The tree build is the step**, at 22 ms of the 30: bigger leaves (32 rather than 16, which
  only became affordable once leaves respected the opening criterion), a depth ceiling of 13
  rather than 20 — a merged core subdivides to the ceiling and the node split is serial — and
  fewer particles.
- **Background rather than utility priority.** The solver has ten times the throughput the
  paced rate asks for, so priority is bought with something that was not being used.

`--cinema` cannot see the last of this, and that limit is worth stating plainly: it drives an
*occluded* window, which is never throttled by the compositor, so `currentDrawable` never
blocks there and the failure mode a visible window has is invisible to it. The burst length is
the honest proxy, which is why it is reported.

The director's camera reached the renderer only after all of the above: `activeCamera` had
never consulted it, so every shot ever described here was being computed and thrown away while
the screen showed a motionless orbit rig. Anything that computes a camera has to be asked for
it somewhere.

Touching the camera in contemplation hands it over — drag, wheel, or a movement key, which also
turns flight on and takes the rig from wherever the director had it — and the director takes it
back twenty-five seconds after the last input.

One scene in three is **immersed** — the eye placed among the stars first and the aim following,
which is the opposite of the orbit rig and the only way to be inside anything. Out at the rim of
the disk, not in its middle: a few kiloparsecs from the centre puts the camera inside the bulge,
where four hundred thousand particles spread across a whole sky is not a galaxy but a brown fog,
and the wide kernels that hide the sparseness are what make it fog. From the rim the disk lies
across the frame with the companion beyond it.

A scene is built on one named look and the oscillators move around it, rather than crossfading
between five — a scene should have a character rather than an average. The same five are in the
viewing panel, since a look is a good place to start from by hand too. `RenderLook` is exactly
the subset of the settings a frame may change on its own; resolution, supersampling, bloom
levels and the starfield own textures and buffers and are not in it.

Three things about the choreography, each of which was a cut that did not work.

- **Every quantity is continuous.** Shots ease between framings with a smoothstep, and the
  azimuth drifts at a rate that never reaches zero, so shots join without either a kink or a
  stop. `theCameraNeverJumps` walks an hour at 60 Hz and caught the one field `mix` forgot to
  interpolate — the world-space point an orbit circles — which was a jump of a fifth of the
  scene at every shot boundary.
- **A shot that ends close may not change subject.** Crossing from one galaxy to the other
  while the camera closes in puts the aim on the midpoint exactly as the frame narrows: sixteen
  seconds of empty sky, measured. Nor may a close shot aim at the barycentre, which on a
  separated pair is the one place with no galaxy in it — that one was forty-five seconds.
  Easing in from the barycentre is fine, being half the distance and widening as it goes.
- **Coming in close needs its own exposure.** The mean luminance of the frame runs from 0.10 at
  a wide shot to 0.89 at a fifth of the framing distance. Trimming the brightness alone barely
  moves it, because the logarithmic stretch is what saturates, so the stretch comes down with
  it and the kernels widen — the ceiling on kernel size is what lets particles resolve into
  grains once the camera is near enough for their spacing to exceed it.

Distances are multiples of the distance at which the subject fills the frame, not of its
radius, so changing the field of view moves the camera instead of shrinking the galaxy. And the
opening shot starts at about one of those rather than two and a half: opening wide and turning
slowly meant a minute in which nothing appeared to move.

## State and known limitations

Both solvers work. Level 1 is tracers in rigid potentials, level 2 is self-gravitating
Barnes-Hut with live halos, and level 2 is the default. Galaxies merge, and the orbital decay
is measured in the README.

Standing gaps, in the order they matter:

1. **No gas.** There is a star formation rule now — see "Star formation, and why density alone
   gives no burst" — and it puts knots where the material is compressed, consumes the reservoir,
   and bursts at pericentre and coalescence. What is still missing is the gas itself: no inflow,
   so a merger's nucleus is never resupplied and the burst is the shock's alone; no pressure, so
   nothing shocks properly; and the dust distribution is still the sampler's. Adding SPH is a
   project of its own and would cost another order of magnitude in speed.
2. **Colour is not derived.** Stellar populations are a hand-made ramp rather than luminosities
   in real bands composited like telescope filters. This is the next lever for making the
   interior of a galaxy legible.
3. **Disk stability, now measured and mostly fixed.** An isolated self-gravitating disk used
   to spread its mean radius by 23 % over the first 40 Myr, identically at every time step
   from a quarter of the tuned one to eight times it: the initial conditions, not the
   integrator. The sampler took its rotation curve from the analytic potential the galaxy is
   written as, while laying the mass down as a flattened exponential disk, a bulge and a
   truncated halo, none of which pull like that sphere. The disk came out turning at 0.81 of
   what the real field asks. The curve is now built from the components themselves, Freeman's
   Bessel form included, and the halo's dispersion is solved against the same composite.
   Drift over 40 Myr: 23 % to 2 % with a live halo, 11 % to 0.3 % without. `aSelfGravitatingDiskHoldsItsRadius`
   guards it. What is still unmeasured is what happens over many orbits rather than half of one.

   The tuned step itself is roughly sixteen times more conservative than it needs to be. Up to
   16x the radial profile after 40 Myr stays within 0.3 % of a reference run at a quarter of
   it, 32x is within 1 %, 64x within 3 %, and 128x visibly wrong. A 100 Myr self-gravitating
   merger at 200 k particles renders indistinguishably at 16x, in 5.8 s against 92 s. Hence
   `timeStepScale`, which is that multiplier; the default stays 1 because a close encounter
   reaches speeds an isolated disk does not.

   That caution is now measured rather than assumed. A 300 k merger run *through* pericentre
   to 300 Myr, disk deciles against the tuned step: 0.66 % at 2x, 1.31 % at 4x, 0.93 % at 8x,
   1.45 % at 16x, 4.01 % at 32x. The figure is not monotonic below 16x, which is the useful
   part — between 1x and 16x it is measuring the encounter's own chaotic divergence, not
   integration error, and two neighbouring runs separate by about a percent whatever the step.
   32x leaves that band. So 8x is comfortable for a long run and 16x is defensible; the default
   is still 1 because that is the number every rendered comparison here was made at.

   Particle count costs more than it looks. The softening follows the mean interparticle
   spacing, so it falls as 1/sqrt(N), and the step follows the softening. Going from 300 k
   visible to 2 M costs about 4x per step *and* 2.4x more steps for the same simulated time.
4. **Force traversal is still where the time goes**, but it no longer grows with the run.
   The remaining large win is sharing one traversal across a SIMD group.

   The split is flat with scale, which is what makes it worth quoting: at one million
   simulated particles a step is 66.7 ms, and at 3.75 million it is 264.2, both of them
   36 % tree build and 64 % force pass. The drift is 1 ms and never worth a thought.

   **Individual time steps are not the win they look like here, and the measurement is worth
   keeping so nobody starts it twice.** The prize would be a dense core taking a hundredth of
   the step while the outskirts take all of it — but the softening floors the accelerations by
   construction, since it follows the mean interparticle spacing precisely to stop two-body
   spikes, and `dt = eta sqrt(softening / |a|)` therefore cannot collapse. Measured across a
   merger at 200 000 particles, the whole population fits in five or six rungs and the bulk
   sits in the middle of them: the saving on the force pass runs 1.9x to 2.8x, never more,
   including through pericentre and coalescence. Against a pass that is 64 % of a step, that
   is 1.6x overall — for the deepest structural change the solver could take, a per-particle
   rung, an active list, and indirection through it in the one kernel everything depends on.
   The SIMD-group traversal attacks the same 64 % for a change that stays inside one kernel
   and is guarded by `accelerationMatchesDirectSummation`, and a GPU tree build attacks the
   other 36 % and hands back every core besides. Both are better bets.

   The bulge costs 13 % of a step, all of it in traversal: 98.6 ms against 111.3 ms at 400 k
   visible particles. Concentrating a seventh of the stars into half a kiloparsec deepens the
   tree exactly where the lanes of a SIMD group have to walk it.
5. **Graininess in the outskirts** comes from the clumpiness of the initial conditions, not
   from sampling. It is deliberate, but it reads as noise now that the render is sharp.
6. **A merger remnant is as spheroidal as the encounter makes it, and no more.** Disks are now
   left heated rather than rebuilt, but nothing here models the gas that would later settle a
   new disk out of the remnant over a few gigayears, so a run that goes on long enough shows a
   remnant that only ever gets hotter. Same root as gap 1.
