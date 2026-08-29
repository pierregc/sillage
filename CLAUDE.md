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

**The cost per step climbs, and this is the real limit.** Measured at 100 000 simulated
particles, from 250 Myr to 2 Gyr: an isolated disk goes from 15 to 43 ms a step, a merger from
15 to 136. The node count *falls* over the same stretch, so it is not the tree growing — it is
the traversal. As the core densifies and the halo spreads, more cells fail the opening
criterion and have to be walked. Dissipation adds about 40 % on top of that by keeping the disk
tight, which is a fair price for it still having arms.

Nothing in the interface hides this: the running panel's Myr/s is measured, not predicted, so
it falls as the run goes. The setup screen's estimate is taken at t = 0 and is honest over the
500 Myr it quotes, where the drift is still small.

**Beware of measuring under contention.** A run launched into the background alongside the app
crawled at a thirtieth of its speed, both fighting for the GPU, and it looked exactly like a
solver regression. It was not: the same loop in the foreground ran at 25 ms a step. Kill the
app before timing anything.

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
4. **Force traversal is where the time goes.** Measured on an M4 Max at 400 k visible
   particles with live halos, so a million simulated: 95 ms a step, of which 76 ms is
   `bhAcceleration` and 18 ms the CPU tree build. Sharing one stack across a SIMD group is
   still the remaining large win.

   Do not reach for the obvious shortcut: shrinking the per-thread `int stack[64]` looks like
   a 4x speed-up on the clock and is worthless. At 16 entries the traversal silently drops
   the children it cannot push, and `accelerationMatchesDirectSummation` goes from 2 % mean
   error to 34 %. That the timing moves that much for a change in stack size alone is still
   worth knowing: the cost is thread-private storage as much as it is divergence.

   The bulge costs 13 % of a step, all of it in traversal: 98.6 ms against 111.3 ms at 400 k
   visible particles. Concentrating a seventh of the stars into half a kiloparsec deepens the
   tree exactly where the lanes of a SIMD group have to walk it.
5. **Graininess in the outskirts** comes from the clumpiness of the initial conditions, not
   from sampling. It is deliberate, but it reads as noise now that the render is sharp.
