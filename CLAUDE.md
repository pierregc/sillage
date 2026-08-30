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
looked at directly. Six modes replace it, and they are the only way to verify the app:

```
Sillage.app --selftest    # model, solver, renderer and preview offscreen; writes out/selftest.png
Sillage.app --verify      # opens the window and drives the view, reports frames drawn
Sillage.app --uishot      # renders the panels through ImageRenderer to out/
Sillage.app --presets     # cycles the setup presets with the window up
Sillage.app --responsive  # runs a self-gravitating scene, reports how long the main actor stalls
Sillage.app --qa          # walks the whole run flow and reports every check
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
- **Never push and never create the GitHub repository without explicit approval.** Nothing has
  been pushed. The repo does not exist on GitHub yet, and neither do the milestones.

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

Exposure still divides by every simulated particle rather than every drawn one, so switching
live halos on dims a scene by the halo ratio. That is wrong and deliberately left: correcting
it brightens every self-gravitating scene by two and a half and means retuning the defaults and
every rendered comparison at once.

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
scene, and a new one replaces it every eleven and a half minutes through a fade. `--cinema N`
runs it through the real draw path for N seconds and reports the frame times, which is the only
way to check a mode whose whole promise is "no stutter" on a machine with no screen recording.
Measured at 1.6 M particles: median 5.5 ms, one frame of 12 913 over 33 ms, and that one is the
renderer being rebuilt for the next scene while the screen is already black.

Level 1 throughout, deliberately. Contemplation has to hold its frame rate for hours and the
tree solver gets slower as a merger concentrates; tracers in rigid potentials cost one kernel a
step and leave the GPU to the picture. Tidal bridges and tails are Toomre's 1972 result and
need no self-gravity. Nothing is captured either: hours of take to record what nobody will
replay.

`RenderLook` is the subset of the settings a frame may change on its own — everything that is
already a per-frame uniform. Resolution, supersampling, bloom levels and the starfield are not
in it because they own textures and buffers, and changing one of those means building a new
renderer, which recompiles the shader library. Five named looks are crossfaded shot to shot and
modulated by eight sine waves of prime period, so the combination does not come round again.

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
radius, so changing the field of view moves the camera instead of shrinking the galaxy.

## State and known limitations

Both solvers work. Level 1 is tracers in rigid potentials, level 2 is self-gravitating
Barnes-Hut with live halos, and level 2 is the default. Galaxies merge, and the orbital decay
is measured in the README.

Standing gaps, in the order they matter:

1. **No gas.** HII regions are decorative: placed by the sampler, not produced by collapse.
   No shocks, no starbursts in the right places, no dust distribution from physics. Adding SPH
   is a project of its own and would cost another order of magnitude in speed.
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

   The bulge costs 13 % of a step, all of it in traversal: 98.6 ms against 111.3 ms at 400 k
   visible particles. Concentrating a seventh of the stars into half a kiloparsec deepens the
   tree exactly where the lanes of a SIMD group have to walk it.
5. **Graininess in the outskirts** comes from the clumpiness of the initial conditions, not
   from sampling. It is deliberate, but it reads as noise now that the render is sharp.
