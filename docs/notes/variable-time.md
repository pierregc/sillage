# Time that runs faster when nothing happens

Pierre, 2026-11-13: a collision is over quickly, and what follows can take a long time to settle.
A burst flings the arms far out and they take hundreds of megayears to fall back. He would like
the video to speed up when nothing much is happening and keep its pace when something is, chosen
intelligently, and asked whether the run itself could be computed with a time that varies too,
since a run that spends gigayears on a stretch the video then plays fast is a lot of computing
for little to show.

Nothing was built or run for this note. It reads the code, the earlier notes, and the curves of
the twenty explore stories and the 8 M hires kept on `assets/225-doubled-step`; the prototype
that measured them is on `assets/variable-time` (`docs/spikes/variable-time/story-pace.py` and its
output).

**In short.**

- **A video whose speed varies is cheap.** The take and the curves already hold everything it
  needs: a time track from the video's time to the take's, chosen by hand or from the story's own
  curves, and cameras that follow the video's time rather than the take's. On the twenty stories
  a pace read off the curves leaves every collision at 1x, plays the aftermath at 2x to 7x, and
  shortens the videos by a fifth on average and by over a third for the longest aftermaths.
- **Speeding the video up does not make the run cheaper by itself.** The step is set by the
  fastest stars, which keep orbiting the cores whatever the tails do, and steps are over 92 % of
  a hires; frames are the rest. What can be saved is in the integration: a coarser step before
  the story and late in the aftermath (about a fifth of the steps), and the light tracers on steps
  of their own (2 to 35 % of a 200 M run in a model, to be measured), both judged on frames first.

## What there is today

**A video always plays its take at one speed.** An export shows the take from `--start` for
`--duration`, one captured frame per video frame at the captured rate, and lasts the take's
captured frames divided by that rate whatever `--fps` asks: a higher rate only draws more frames
between the captured ones (`TakeExport.positions`). The x0.25 to x4 of the style editor only play
the take in the app. A captured frame is `stepsPerFrame` steps after the one before, the same all
through the run, about 0.79 Myr at a night's cadence.

**The step is the same from the first step to the last.** A hires runs at 3.5 times
`recommendedTimeStep` (`SceneFolder.hiresTimeStepScale`), which is 0.15 softening lengths over the
fastest disk's circular speed at its scale length, from the first step to the story's end: it
settles through everything before the story's first frame without capturing, then captures the
story (`Story`, `clip.json`; [whole stories](whole-stories.md)). Exploration runs at 7
([a doubled step](doubled-step.md)).

**Every camera is a function of the take's time.** `ShotReplay.shot(atCaptured:)` gives each
captured position its camera: the orbit plan turns with `frame / span`, the auto camera eases
once a captured frame, the immersed director advances by one captured frame's seconds, and
`ShotPlan` cuts its shots in captured frames, turning seconds into frames with the captured rate
(a shot lasts at least 2.5 s, the opening and closing at most 8). The full pass of a hires draws
its videos at the captured frames as the solver reaches them ([the videos drawn during the hires
run](render-during-hires.md)).

**#295 adds a time track for flights.** A flight's keys give the take's time at chosen seconds of
the video, on a monotone cubic (Fritsch and Carlson) that can slow, stop and start again but never
runs backwards. A speed that varies is the same function written another way, which is why the
two should share one piece of code (below).

## Where a story's time goes

Each run's curves were cut into three stretches: before the story (everything a hires simulates
before its first frame, settling included), engaged (from the story's start, 150 Myr before the
first pass of a pair closer than its reach, to the moment the last pair either merges or leaves
its reach for good), and after (to the story's end). Without the scene files the reach `Story`
uses is not known, so a pair counts as close below 45 kpc, about 1.5 times two typical disks'
reach, and as merged once its centres stay within 10 kpc to the end; a pass needs the pair to
separate again by half its distance or 5 kpc, so the debris centres of a remnant wobbling by a
few kiloparsecs are not taken for passes.

The twenty stories of the #225 exploration at 7 (100 000 particles a galaxy, nineteen with a
collision) and the 8 M hires of scene-0031 at 3.5:

| | before the story | engaged | after |
| --- | ---: | ---: | ---: |
| share of the simulated time, all 20 | 23 % | 40 % | 37 % |
| range over the stories | 8 to 35 % | 23 to 92 % | 0 to 59 % |
| scene-0031, the 8 M hires | 18 % | 34 % | 48 % |
| share of the story's own frames | | 52 % | 48 % |

Two stories never stop being engaged: 0008 and 0012 are bound pairs that keep coming back until
the end, and nothing in them is an aftermath. Every other story, merged or parted, runs 320 to
640 Myr past its last engagement: what Pierre sees as a long settling is half of the video and
over a third of the run.

**What a hires costs is its steps.** At 8 M drawn from 2 M massive, drawing 4K and vertical during
the full pass added 7.5 % to the frames ([render during hires](render-during-hires.md)); at 200 M
drawn on 8 M massive a step is about 5 s and a 4K frame 1.7 s, so the frames are 3 to 4 % of a
22 h story ([200 M previews](200m-preview.md)). Of a step, the light tracers are about half at
8 M from 2 M (21 ns each), 60 % at 50 M on 20 M massive and 90 % at 200 M (23.4 ns each over
192 M tracers).

## Part 1: a speed that varies along the video

### A time track

A time track maps each moment of the video to a moment of the take, and its slope is the speed:
1x is today's one captured frame per video frame at the captured rate. It is written either as
speeds at moments of the take (`{"myr": 560, "speed": 4}`), as #295's keys of video seconds and
megayears, or computed from the curves (Part 2). Either way it is integrated once into a
monotone table, video frame to captured position, and `TakeExport.positions` reads that table
instead of its straight line.

- **Speeds change smoothly**, in proportion rather than in steps: at most a doubling or a halving
  over a few seconds of video, which is how a speed ramp reads as a choice rather than a jump. The
  prototype allows one doubling per 3 s; the spike lets Pierre pick.
- **The track is written beside the export** (`exports/<name>.time.json`), so a video can be
  drawn again exactly and edited by hand.
- **One piece of code for both epics.** `TimeTrack`, portable Swift beside `TakeFraming` as #295
  asks, so the CUDA full pass can follow it. Whichever of #295 and this epic's first ticket
  lands first builds it, and the other reads its keys into it.
- **Nothing changes without a track.** A constant 1x track gives the same positions as today, so
  every export keeps its bytes.

### What has to follow the video's time

With a track, the take's time is no longer the video's, and everything that moves the camera has
to choose. The rule is that the camera moves in the video's time and looks at the take's:

- the orbit plan and the zoom keys (`CameraPlan`, progress from the first frame to the last)
  turn with the video's progress, so a turn does not whip round when time speeds up;
- the auto camera and the immersed director advance once a video frame, framing the centres at
  that frame's moment of the take;
- `ShotPlan` plans on the track resampled at the video's frames, so its shortest shot and its
  openings stay seconds of video: a closing shot of 8 s at 1x would otherwise last one second at
  8x, and a pericentre shot of 4 s sixteen at 0.25x;
- the painted arms, the dust web and the exposure are read at the take's moment, as now, and the
  grain and the scintillation stay per video frame.

**Slowing down** below 1x draws between captured frames, which an export already does with its
four-frame blend. A hires take keeps one frame in four (`SceneFolder.hiresTakeInterval`, about
3 Myr), so slowing a pericentre to 0.25x shows sixteen video frames drawn between two stored ones:
smooth, but no more detail than 1x had. Only the full pass can show more: between two steps the
leapfrog moves every particle in a straight line at its half-kicked velocity, so a copy of the
positions drifted to any moment between two steps is exactly what the integrator would have
given, for one drift pass, a few milliseconds against a step of 250 ms at 8 M.

**Speeding up** skips captured frames: at 8x a video frame is 6.3 Myr, in which a star 2 kpc out
at 200 km/s turns about 36 degrees, and a bright knot in a remnant jumps rather than moves.
Holding the default top speed at 8x keeps that rare (with the prototype's pace, five of the
nineteen stories reach 4x, on 2 to 27 % of their frames); a motion blur, drawing k moments of the
take into each video frame at speed k, would cost exactly what drawing that stretch at 1x costs.
The spike decides whether it is needed.

## Part 2: knowing when it is interesting

### From the curves: the story's pace

A run writes, each frame, the galaxy centres, the share of stars in tails, the extent, each disk's
disruption and the stars formed (`curves.csv`, `curves-hires.csv`), and `Story` already judges
from them whether anything is still changing, with thresholds measured on 35 scenes: over 150 Myr,
2 % of the stars into tails, 15 % of extent, 0.05 of disruption. The same thresholds give a pace:

- the activity of a frame is the largest of the three changes over the 150 Myr around it, in
  thresholds (1 is the edge of quiet);
- a frame where a pair is engaged, or where stars form at more than twice their rate before the
  story, plays at 1x;
- elsewhere the speed is 4 over the activity, held between 1x and 8x, and ramped as above.

The whole take is known before the video is drawn, so unlike `Story` the pace may look ahead: the
change is measured over the window centred on the frame, and a slowdown starts before the event
that calls for it.

| | at 1x | paced | top speed |
| --- | ---: | ---: | ---: |
| scene-0031, 8 M hires (merger) | 30.6 s | 22.2 s (73 %) | 3.6x |
| scene-0006 (merger, long aftermath) | 47.3 s | 29.9 s (63 %) | 7.0x |
| scene-0014 (merger) | 29.1 s | 19.6 s (67 %) | 4.4x |
| scene-0002 (one pass, parting) | 27.8 s | 22.5 s (81 %) | 2.6x |
| scene-0008 (bound pair, passes to the end) | 109.1 s | 109.1 s (100 %) | 1.0x |
| all 19 with a collision, mean | | 81 % (62 to 100 %) | |

In scene-0031, which merged near 460 Myr, the tails' share stops rising at 0.33 by 550 Myr, and
the extent then grows from 38 to 54 kpc over the last 330 Myr while the debris spreads: two
thresholds a window falling to half of one, played at 2x rising to 3.6x. That is the stretch
Pierre describes.

The curves do not see the camera. A satellite torn apart outside the frame keeps the pace slow,
and a close shot of a quiet disk while tails form elsewhere plays at 1x for nothing. That is what
the pictures would answer.

### From the pictures: a constant visual pace

Video summarisation has asked the same question for twenty years: play a video fast where little
changes and slowly where much does, so that the change per second of video stays constant
(Peker and Divakaran's constant pace skimming; SmartPlayer, Cheng and others, 2009). Here it would
be a pre-pass drawing the take at 256 px wide with the export's own camera, measuring the change of
the log luminance between frames one megayear apart, and setting the speed so that it stays near a
target. It costs about a tenth of the export, and it measures what is on screen.

It has one trap here: a disk that turns changes every pixel while nothing happens, and a remnant
with spiral debris turns for ever. The curves do not confuse turning with changing, which is why
they come first, and the pictures are a check on them in the spike.

### By hand

Speed keys in megayears, written in the track file or set in the app, always win over the
automatic pace: Pierre may want a pericentre at 0.5x, or a part he finds dull faster than its
curves say.

## Part 3: computing less

### Why a faster video is not a cheaper run

The step is set by the fastest stars (0.15 softening lengths over the circular speed at the disk's
scale length, times 3.5), not by what the story is doing. After a merger, the remnant's core keeps
stars on orbits of 10 to 30 Myr whatever its tails do, and the run must step them as finely as it
did during the collision. Steps are over 92 % of a hires, and their cost is flat over the run
([step cost growth](step-cost-growth.md)), so a stretch the video plays at 8x still costs what it
costs at 1x.

**Fewer frames is not the lever.** Capturing only the frames a track needs would save the drawing
of the frames skipped, 1 to 2 % of a hires, and a fifth of a take on disk, and a take thinned to
one track could not be exported again at another. Takes keep their cadence.

### A coarser step where nothing fast happens

The step's own margin has been measured three times. An isolated disk keeps its radial profile
within 0.3 % up to sixteen times the tuned step, more than four times a hires's
([state](state-and-known-limitations.md)). At 7, twice a hires's, the story holds (the passes, the
merger and the tails within a few times the chaos floor) but star formation falls by 15 % and
compact knots move ([a doubled step](doubled-step.md)). At 14 the 200 M previews heated and
thickened their disks ([200 M previews](200m-preview.md)).

So a schedule rather than one step: the stretch before the story, where the disks are far apart
and settling, and the late aftermath, from 250 Myr after the last engagement (tails form within
250 Myr of a pericentre), at twice the hires step; the engaged story and the formation of its
tails at 3.5 as now. On the twenty stories:

| | share of the steps | saved at 7 | saved at 14 |
| --- | ---: | ---: | ---: |
| before the story | 23 % | 11 % | 17 % |
| after the last engagement + 250 Myr | 17 % | 9 % | 13 % |
| both | 40 % | 20 % | 29 % |

A 22 h story at 200 M would take about 18 h at 7, if the frames show no seam where the step
changes. Margins of 100 or 150 Myr instead of 250 would save 26 or 24 %.

What a schedule needs:

- **Star formation that does not depend on the step.** It falls by 15 % at twice the step in a
  hires, a third at the explore count, and uniformly over the story, quiet disks included
  ([a doubled step](doubled-step.md)): changing the step mid-run would change the rate of young
  stars at the switch, which shows. Which of the rule's two readings moves, the leaf's density or
  the convergence of its flow, was never measured; that comes first.
- **A schedule planned from the preview's curves** with margins (a hires diverges from its
  preview by a few megayears at a merger). The massive pass judges its own curves as it goes, as
  explore does, keeps the fine step while a pair is still engaged, and records in `hires.json`
  where it switched; the full pass and a resumed run (#240) follow that record to the bit.
- **Steps that stay whole fractions of a frame**: the coarse step a power of two times the hires
  step, no more than a frame holds, so the captured frames keep their cadence in megayears and the
  curves stay uniform.
- **The frames on either side of each switch compared** against a run at 3.5 throughout and its
  1 pc floor, as #225 did, with stills of the disks at the story's start and of the remnant.

### Light tracers on steps of their own

At 200 M nine tenths of a step is the tracers' walk. Tracers carry no mass, so each could step at
its own pace without touching the massive particles: no force to keep symmetric, and the massive
part of the full pass still repeats the massive pass to the bit. A tracer far out feels a pull ten
to a hundred times weaker than one at the disk's scale length, and the tails hold nearly a third
of the stars at the end of scene-0031.

What it would save is not known. In a model (an exponential disk of 3.5 kpc, 200 km/s, rungs of
powers of two allowed only above the hires step, at most 8x), the tracer walk shrinks 1.02x for
the disk alone and 1.23x with 30 % of the stars in tails if a tracer's step goes as the square root
of the softening over its acceleration (the usual criterion), and 1.23x and 1.64x if it goes as
its crossing time. At 200 M that is 2 to 35 % of a run. The individual steps measured for the
massive particles gave 1.6x at most for the deepest change the solver could take
([state](state-and-known-limitations.md)); for tracers the change stays in their own pass, but a
frame needs every tracer at its moment, so the ones not due are drifted to it. A spike measures
the rungs on a real run before anything is built.

### Not worth it now

- **A global step that adapts to the dynamics.** The core sets it all through the run, so it would
  only ever shrink, at pericentres.
- **Individual steps for the massive particles.** Measured at 1.6x at most, for a per-particle
  rung, an active list and indirection in the one kernel everything depends on.
- **A frozen or expanded potential for the aftermath.** Once merged, the remnant could be
  replaced by a basis expansion of its potential (the self-consistent field method, Hernquist and
  Ostriker 1992) or frozen, with every star a test particle in it, the way Quinn (1984) made shells
  around ellipticals: ten times cheaper or more, and the shells and the fall back of the tails
  would still come. But the knots would dissolve without their self-gravity and the remnant would
  stop evolving, both visible, and pairs that part need two expansions. Worth revisiting only if
  the aftermath becomes the bulk of a big run.
- **Tracers in their galaxy's analytic potential before the story.** They would not follow the
  massive disk's ringing and arms, and the two would disagree on screen at the switch.
- **Thinning takes to the track** (above).

## The plan

Epic #304, sub-issues in waves:

1. Wave 1, no dependency:
   - #305 A time track and constant speeds in exports: `TimeTrack`, `export --speed <x>|<file>`,
     the cameras on the video's time, the track written beside the export (shared with #295).
   - #306 Spike: star formation that does not depend on the step.
   - #307 Spike: a coarser step before the story and late in the aftermath (7 and 14, the seams).
   - #308 Spike: how many light tracers could step less often.
2. Wave 2:
   - #309 Spike: which automatic pace reads best, chosen by Pierre on videos (after #305).
   - #310 The full pass draws along a time track, exact between steps (after #305).
3. Wave 3:
   - #311 Automatic pace in exports, nights and the app (after #309 and Pierre's choice).
   - #312 Step schedules in hires (after #306, #307 and Pierre's choice).
4. Optional, on Pierre's go: #313 light tracers on steps of their own (after #308, if it promises
   at least a fifth of a 200 M run).

## References

- F. N. Fritsch and R. E. Carlson, Monotone piecewise cubic interpolation, SIAM Journal on
  Numerical Analysis 17 (1980).
- K. A. Peker, A. Divakaran and H. Sun, Constant pace skimming and temporal sub-sampling of video
  using motion activity, ICIP 2001.
- K.-Y. Cheng, S.-J. Luo, B.-Y. Chen and H.-H. Chu, SmartPlayer: user-centric video
  fast-forwarding, CHI 2009.
- L. Hernquist and J. P. Ostriker, A self-consistent field method for galactic dynamics, ApJ 386
  (1992).
- P. J. Quinn, On the formation and dynamics of shells around elliptical galaxies, ApJ 279 (1984).
