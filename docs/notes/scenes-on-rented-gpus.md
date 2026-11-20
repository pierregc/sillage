# Whole scenes on rented GPUs, and more stars from inside

A study on paper, 2026-11-20, from the code and the notes as they stand. Nothing was run, rented
or measured for it; every figure is quoted from the note that measured it, or worked out from
those and marked as an estimate. It prepares two things Pierre asked for the same day:

1. **Computing a scene on a rented NVIDIA GPU.** `sillage-cuda hires` runs only the second pass
   of a hires, the one with light tracers ([cuda-engine.md](cuda-engine.md#the-full-pass-278)).
   The pass that writes the take, which is all a scene of today is (8 M visible particles on
   12 M of dark matter, every one of them massive), runs on the Mac alone and has no checkpoint.
2. **More points of light from inside a galaxy.** Flown through, an arm shows stars that look
   large and close together. Pierre wants many more of them, smaller, with room between: the
   sense of a galaxy's size. Renting could pay for more particles; massless tracers, set aside
   on 2026-11-19, are back on the table if they give density without losing what he sees.

**In short.**

- The take pass can move to CUDA without a new kernel: every kernel it runs is `cuda` in
  `cuda/kernels.txt` already. What is missing is the run around them, which lives in
  `sillage-render`'s `main.swift` and reads Metal types. It moves into a flow both engines run,
  as the full pass did (#278), and gains checkpoints there, once, for Metal and CUDA alike.
- A scene of today is then about an hour on a rented RTX 5090 for about a dollar, against 2 to
  4 hours on the M4 Max and an estimated 4 to 8 on the next Mac. Nothing large goes up: the box
  samples the scene itself. The take (15 to 25 GB) comes down.
- **The number of points on screen inside an arm is set by the renderer, not by the particle
  count.** A frame there already draws up to 20 M point stars from 8 M particles at a calm
  moment and up to 67 M at a passage. Their size and their spacing are drawing choices, which
  #357 reworks on the takes Pierre has, at no cost. That comes first.
- More particles buy something else: the scale under which the field has no structure, 50 pc
  today, shrinks as the cube root of the count. Tracers on today's massive set give that for the
  least, and lose nothing of today's dynamics; but a take does not hold them, so they show only
  in visits drawn from key frames. All massive at 32 M is the other route, with a take four
  times the size. Which one Pierre prefers is decided on frames of one scene drawn each way,
  about 10 € of rented time, not on paper.

## What runs where today

| | Mac (Metal) | Linux (CUDA) |
| --- | --- | --- |
| explore, look, style, exports from a take, the app | yes | no, and not planned |
| hires, one pass, every particle massive (today's scenes) | yes, no checkpoint | **no** |
| hires `--pass massive` (the massive particles of a draw with tracers) | yes, no checkpoint | **no** |
| hires `--pass full` (tracers, videos drawn as it runs, key frames) | yes, checkpoints | yes, checkpoints (#278) |
| stills from a take, stills of a flight | yes | yes (#277, #347) |
| a flight's video | yes | **no** |

On a GPU the CUDA engine has never run: phase 1 of #269 compiled it with `nvcc` and ran it on
the CPU target. Seven kernels of the tree (`cuda gpu-only`) and 17 tests wait for #283, the
bring-up on a rented card ([cuda-engine.md](cuda-engine.md#what-waits-for-a-gpu-283)).

## The pass that writes a take, on both engines

**What it is.** `sillage-render hires <scene>` builds a command line (`SceneFolder.hiresArguments`:
`--video`, `--curves`, `--take`, the counts, the step, its schedule) and falls into the one loop
of `Sources/sillage-render/main.swift`: sample, settle, then for each frame step the solver,
refresh the smoothing, move the director, draw `hires.mov`, offer the positions to the take,
write a row of curves. At the end the take is written whole, `hires.json` records the run and
`commitHires` puts the files in place. `--pass massive` is the same loop over the massive
particles of a draw with tracers, and leaves `massive.bin` for the full pass.

**What ties it to the Mac** is not the physics. `MetalBarnesHutSolver` has its twin,
`CUDABarnesHutSolver`, with the same step (`BarnesHutStep`), the same CPU side (`BarnesHutHost`),
star formation, cooling, black holes, step changes (`StepChangingSolver`) and checkpoint files
(#274). The loop itself is the tie: 1,300 lines of top level script that hold a `Renderer`, a
`SmoothingField` and a `VideoWriter`, read the positions through `MTLBuffer.contents()`, and
carry a dozen measuring options (`--density`, `--dump-walk`, `--dump-targets`, `--take-v6`).
`Recording`, `RecordingFile`, `Cinematographer`, `AutoCamera`, `Story`, `StepScheduler` and
`SceneFolder` are portable and build on Linux already ([linux-build.md](linux-build.md)).

**The move** is the one #278 made for the full pass. `FullPassRun` is the flow, `FullPassEngine`
what an engine gives it (the solver, the smoothing, a preset's drawing and its encoder, the
positions, the solver's state), `MetalFullPassEngine` and `CUDAFullPassEngine` the two engines.
The take pass gets the same shape, sharing what the two flows have in common (the scenes built
from the options, the settle in chunks, the frame's steps, a video drawn through
`RunVideoDrawing`, the checkpoint's identity) rather than a third loop:

- the flow, portable: the settle, the frames, the step schedule and its judge, the director or
  the automatic camera, the take, the curves, `hires.json`, `commitHires`;
- an engine: the solver, the smoothing lengths, the positions as the CPU reads them, the drawing
  of `hires.mov`, the encoder (VideoToolbox on the Mac, ffmpeg on Linux);
- `main.swift` keeps the plain renders and the measuring options, which stay Metal's.

A CUDA take pass samples the scene on Linux. A sample drawn there is the Mac's to rounding and
not to the bit (#272), which matters only when one engine has to continue the other's run. A
scene run whole on the box is its own sample; its full pass, if it has one, then repeats its
massive pass to the bit: the drift is 0 on one engine, which
`aFullPassWritesWhatTheMacsWritesAndRepeatsItsMassivePass` already holds on the CPU target with
a take the CUDA solver made.

**What must hold.**

- The Mac keeps its bits: a short hires of the reference scene gives the same take, curves,
  video frames and `hires.json` (but for durations) before and after the move, as #278 checked
  for the full pass.
- A CUDA run is deterministic and resumes to the bit, on the CPU target in the workflow and on a
  GPU once #283 has run.
- CUDA against Metal is held as #274 holds the solver: to rounding on one force evaluation,
  and along a run within what chaos parts two Metal runs by. Two takes of one scene from the two
  engines are the same story, not the same bytes.
- No kernel is added. `cuda/kernels.txt` does not change.

## Checkpoints for the take pass

Today "a run that writes a take does not" checkpoint
([checkpoints.md](checkpoints.md#which-runs-checkpoint)): when that was written the massive pass
took 18 minutes. A scene of today takes hours, on a laptop that sleeps and on boxes that can be
taken back. What a checkpoint has to hold, on top of what the full pass's already holds:

- **The solver**: nothing new. `state`, `writeParticles` and `restore` exist on both engines and
  resume to the bit: 32 bytes a particle and 4 a massive one, so 0.72 GB at 20 M, written in a
  fraction of a second on the Mac's disk (6.4 GB/s measured at 200 M).
- **The take so far.** `Recording` fills a memory budget (a quarter of the machine), then spills
  to a scratch file, and `RecordingFile.write` streams all of it into the take at the end. For a
  checkpoint the kept frames must be on disk as they are taken, as the full pass's key frames
  are (`KeyFrameTake`: blocks written as they come, the take put together at the end). A
  checkpoint then records how many frames the file holds and its length; a resumed run cuts the
  file back to that and carries on. The last frame offered that was not a keeper (`tail`) needs
  nothing: the run goes on past it. Putting the take together at the end copies it once, so the
  disk holds it twice for a moment; a layout with the frame records after the positions would
  spare the copy and is the ticket's to weigh.
- **The curves**: the CSV is cut back to the checkpoint's frame.
- **What the CPU carries from frame to frame**: the director (`Cinematographer`, advanced a
  frame at a time on the run's centres), `AutoCamera`, the framing radius frozen on the first
  frame, the step scheduler with its judge and its switches, the time the last frame ended at
  (star formation counts from it), the renderer's grain. Rather than saving the inside of each,
  the checkpoint keeps **a journal**: the exact centres, time and disk states of every frame
  done, a few tens of bytes a frame. A resumed run replays the director, the camera and the
  judge over it, which costs nothing and cannot disagree with a first run. The curves cannot
  serve: they print four decimals.
- **`hires.mov`**: in segments joined without encoding again, as the full pass's videos are
  (`RunVideos`, #240), on both engines.
- **The run's identity**, as #240: the command line, the scene, the look, the engine, the
  binary's digest. `--resume` refuses another run's checkpoint. A CUDA checkpoint is not Metal's,
  and the reverse.

Not checkpointed: exploration (minutes), and a run with a measuring option, which is refused
with `--checkpoint-every` rather than half saved.

**The interval** is the full pass's option, `--checkpoint-every <minutes>`: 60 by default on the
Mac, 15 on a rented box, where a checkpoint costs about a second and an interruption is expected.

**The test** is #240's: a run never stopped against one killed after a checkpoint in its settle
and again in its frames, a segment open: the same take to the byte past its header, the same
curves, the same frames of `hires.mov` decoded, the same solver state. On Metal on the Mac, on
the CPU target in the workflow, on a GPU in the first rented run.

## A scene on a rented box

[gpu-rental.md](gpu-rental.md) holds the providers, the step by step and the watchdog; #283
turns it into `scripts/gpu-box.sh`. What changes now that the whole scene runs there:

**Nothing large goes up.** The full pass needed the Mac's massive take and `massive.bin` on the
box (3 to 5 GB). A take pass needs the scene folder as exploration left it: `scene.json`,
`clip.json`, the look, the preview's curves, a few hundred kilobytes.

**What comes down** is the take: 2.026 bytes a particle a captured frame at one frame in four
([takes-on-disk.md](takes-on-disk.md)), so 15 GB for 8 M over 923 frames and 24.5 GB over 1,514,
with `hires.mov`, the curves and `hires.json`. The Mac pulls it with `rsync` over SSH: 20 to
35 minutes at 100 Mbit/s, 2 to 4 at a gigabit. A take does not compress. On Vast.ai a host
charges the bytes, from nothing to 0.05 $/GB: at the top that is 1.25 $ for a take, more than
the GPU time, so the offer is filtered on its bandwidth price and its upload speed as well as on
its card. Nothing is opened anywhere else: no port on the VPS, no store in between.

**Disk on the box.** The take while it is written, once more while it is put together, two
checkpoints, the video's segments, the build: about 60 GB for the largest 8 M scene. 100 GB of
disk leaves room; at 0.20 $/GB a month it costs a cent an hour. A 32 M take (60 to 100 GB) would
want 250 GB, or the layout that spares the copy.

**Interruptible boxes.** Pierre leans to the interruptible tier, about half the on-demand price.
On Vast.ai an interruptible instance is a bid: outbid, it is paused, its processes killed, its
disk kept, and it starts again when the bid wins ([gpu-rental.md](gpu-rental.md)).
With checkpoints that is survivable, given three things `gpu-box.sh` has to do:

- **Start the run so that it restarts itself.** The instance's start command (to be checked on
  the day, with the rest of the provider's CLI) runs the same `sillage-cuda hires ... --resume`
  line: it resumes the run's own checkpoint when there is one and starts the run otherwise, as a
  night does on the Mac (`SceneFolder.resumesFullPass`).
- **Bound what a paused box costs.** A paused instance still pays for its disk, and may wait
  hours for its GPU. The watchdog counts wall time since the rental, not the run's time, and the
  ledger records the pauses.
- **Optionally keep the run off the box too.** A host can vanish with its disk. While the Mac is
  on, a `sync` pulls the checkpoint and the take's new frames (`rsync --append-verify`, the file
  only grows); if the box is lost, the folder ships to another and resumes there. A checkpoint
  written on one NVIDIA card resumes on another: the build takes no contraction and no fast
  math, so the bits do not depend on the model ([cuda-engine.md](cuda-engine.md#the-kernels)).

For an hour's run none of this is worth much: an interrupted scene of today can simply start
again. It earns its keep on the runs of the last section, 2 to 5 hours each.

**Bring-up is not an interruptible job.** #283 debugs kernels that have never run on a GPU; a box
that pauses in the middle wastes the session. On demand for the bring-up, interruptible for the
runs.

**Who drives**: a session on the Mac, over SSH, as [gpu-rental.md](gpu-rental.md) concluded. A
cloud session has no SSH. The keys stay on the Mac, the box deletes itself with the key the
provider gave that box alone, the balance is prepaid without automatic top-up.

## What a scene costs, here and there

The M4 Max's figures are measured ([ten-times-the-particles.md](ten-times-the-particles.md),
[200m-preview.md](200m-preview.md), [light-tracers.md](light-tracers.md)). The 5090's are those
divided by 3.5, the estimate of [gpu-rental.md](gpu-rental.md) for a tree walk (2.5 to 5,
nothing measured on NVIDIA before #283). The next Mac is put at half the M4 Max, #269's estimate.
A gigayear is 17,400 steps at the softening floor's step (0.0575 Myr); a night's story runs 0.9
to 1.6 Gyr with its settle. Dollars are for a gigayear at 0.25 to 0.63 $/h, the interruptible
and on-demand prices of a 5090 quoted in the project on 2026-11-20 (not read again for this
note; on a marketplace they move by the hour).

| route | simulated | tracers | a step, M4 Max | a Gyr, M4 Max | a Gyr, 5090 (est.) | $ a Gyr | GPU memory | the take, 923 frames |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| today: 8 M visible, halo 12 M | 20 M | | 0.45 s | 2.2 h | 0.6 h (0.4 to 0.9) | 0.2 to 0.4 | 2.9 GB | 15 GB |
| 20 M visible, halo held at 12 M | 32 M | | 0.81 s | 3.9 h | 1.1 h | 0.3 to 0.7 | 4.6 GB | 37 GB |
| 32 M visible, halo held at 12 M | 44 M | | 1.1 s (est.) | 5.4 h | 1.5 h | 0.4 to 1.0 | 6.3 GB | 60 GB |
| 32 M visible, halo 48 M | 80 M | | 2.4 s (est.) | 11.6 h | 3.3 h | 0.8 to 2.1 | 11.5 GB | 60 GB |
| today's 20 M massive, 50 M drawn | 20 M | 42 M | 1.43 s (est.) | 6.9 h | 2.0 h | 0.5 to 1.2 | 4.4 GB | 0.4 GB a key frame |
| today's 20 M massive, 100 M drawn | 20 M | 92 M | 2.5 to 2.6 s | 12.3 h | 3.5 h | 0.9 to 2.2 | 6.2 GB | 0.8 GB a key frame |

- The step of the first, second and last rows is measured; the third is 25.2 ns a simulated
  particle, what 40 M on a halo of 12 M measured (1.31 s for 52 M); the fourth 30 ns, the trend
  of the table past 50 M; the fifth 23.4 ns a tracer (measured on 8 M massive) on today's step.
- A run with tracers is two passes: its massive pass first (the first row), then the full pass
  (the row). The take it leaves is the massive pass's, 15 GB; the tracers are kept at key frames
  only, 8 bytes a drawn particle each.
- GPU memory is 144 bytes a massive particle with its tree and 36 a tracer
  ([cuda-engine.md](cuda-engine.md#memory)), without the renderer's 4 GB or so when a video is
  drawn. Every row fits a 32 GB card, and a 24 GB one.
- Around the run a box adds about twenty minutes that do not shrink: booting, building (ten to
  fifteen minutes the first time), sampling (1.5 µs a particle, half a minute at 20 M), pulling
  the take.
- Since #312 a hires follows a step schedule that saves about a fifth of the steps; the table
  ignores it.

**Read plainly.** A scene of today is 2 to 4 hours of M4 Max (the library's 8 M runs took 2 h 20
to 4 h with their drawing and their take), 4 to 8 on the next Mac, and about an hour of 5090 with
the box's overhead: under a dollar. Every route of the table is a few dollars for a whole story.
At these prices the rental is not what limits the count. What does: the take's size, what the
Mac can play back and draw afterwards, and whether the extra particles show.

## More stars from inside

### What is on screen today

From [inside-a-galaxy.md](inside-a-galaxy.md) and #357, on the Mice take (8 M visible):

- A particle stands for about 6,000 suns. In an arm the particles are about 50 pc apart.
- Near the eye a particle's light goes to 128 point stars scattered at random in its kernel, a
  few bright over many faint (`stars`, `starShare`), 1.5 output pixels wide (`starSize`, never
  under a pixel of the render), brighter as they near until a cap, with the look's bloom on top.
- So the points stand about 10 pc apart where real stars stand 1 to 2, each carries the light of
  a hundred stars, and in 1080p each is twice as wide against the frame as in the 4K frames
  Pierre chose on.
- A frame inside an arm draws up to 20 M of them at a calm moment and up to 67 M at the passage.
  The list holds 128 M. **The points on screen are bounded by what a frame can afford to draw,
  not by the particles behind them.**

The frame Pierre holds up as the target (frame 700 of #297's flight: "fine grains, like dust,
exactly the sense of scale") is the same points seen from 3 to 8 kpc. What he dislikes at frame
1104 is those points from a few hundred parsecs: larger, brighter, bloomed, in visible clumps of
one particle's kernel.

### Three levers

**1. The drawing (#357, open).** What makes a point large and its neighbours close is drawn, so
it can be drawn otherwise, on the takes there are:

- a point stays a point: a footprint under a pixel with its coverage accounted for, no growth
  as it nears, its brightness alone following the distance; sizes set against the frame's
  height so 1080p and 4K give one picture;
- the look's bloom cut hard for point stars, so a bright star gains a glint and not a disk;
- brightness drawn from a steep luminosity function: a handful of bright stars in a frame, a
  crowd at the limit of sight, and the rest left to the splat as the unresolved glow a real sky
  has. Space between stars reads from that hierarchy more than from their number;
- more and fainter points for the nearest particles (thousands within a few hundred parsecs),
  fewer far off, inside the frame's budget of points, which is unchanged;
- the scatter stratified rather than uniform at random, over more than one kernel length, so a
  particle's stars do not read as a clump.

It costs no rented hour and no new take, and it answers "too large, too close" directly. Its
limit is written in the same note: the stars are drawn, not simulated. Under the particles'
spacing the field has no structure of its own: no cluster, no filament of young stars, no sharp
edge to a dust lane, and the dust is grains of that size (#356).

**2. More massive particles.** The spacing follows the cube root of the count:

| visible | suns a particle | spacing in an arm | against today |
| ---: | ---: | ---: | ---: |
| 8 M | 6,000 | 50 pc | 1 |
| 20 M | 2,400 | 37 pc | 0.74 |
| 32 M | 1,500 | 31 pc | 0.63 |
| 50 M | 960 | 27 pc | 0.54 |
| 100 M | 480 | 21.5 pc | 0.43 |

- Four times the particles shorten the spacing by a third; a real field is 30 times finer than
  today's and out of reach of any count. So the count never replaces lever 1. It refines what
  lever 1 scatters its stars over: thinner arms and spurs, finer dust, smaller clumps.
- The dynamics gain nothing past today's count: the softening sits at its 30 pc floor from about
  7 M visible on (on scene-0031; a larger disk reaches it a little later), so the force resolves
  the same scales and the step is the same. Lowering the floor would multiply the steps (four
  times at 100 M) for a force finer than anything drawn.
- Every particle is in the take, so any flight at any moment sees it, time frozen or running.
- The take grows with the count: 60 GB at 32 M for a short story, 100 for a long one. The box
  makes it; the Mac still has to live with it: a far 4K frame drawn in about 0.30 s where 8 M
  takes 0.10 (the cost model's line), the app's playback about four times slower, on a machine
  half as fast as the one those were measured on.
- The halo should not grow with the stars ("cap the halo, not the ratio",
  [ten-times-the-particles.md](ten-times-the-particles.md#the-levers)): held at today's 12 M it
  halves the step of a 32 M run. A halo particle is then about ten times a star's mass, against
  2.4 today; what that does to a disk over a story was never measured, and the calm-disk probe
  measures it before a run relies on it.

**3. Light tracers on today's massive set.** The same 8 M visible and 12 M dark particles carry
the mass; 42 or 92 M more are drawn from the same distribution and move in their field.

- **They lose nothing of today's scenes.** Pierre's two reservations (they only smooth the
  picture, and too much precision is lost) are what the 200 M previews on 2 M massive showed
  ([200m-preview.md](200m-preview.md)): shapes modelled coarsely, because 2 M massive particles
  soften at 55 pc, and a milky look from outside, under looks tuned for grain. On today's 20 M
  the softening is at the floor and the shapes are today's exactly.
  A tracer follows the same gravity as a massive particle with the same error; it only does not
  pull. Over a whole story the tracers stay on the mass to within the noise of counting them
  ([light-tracers.md](light-tracers.md#whether-the-light-stays-on-the-mass)).
- **From inside they are not a smoothing.** Each one is a place to scatter stars from, as a
  massive particle is. At 100 M drawn the field has structure down to about 21 pc.
- **The catch is the take.** It holds the massive particles alone; tracers are kept only at the
  full pass's key frames. So a flight sees tracers only where a key frame is: time frozen at a
  chosen instant, or flowing slowly through a few consecutive frames kept whole. Near matter
  that is what a flight does anyway: time there wants a hundredth of the take's speed or less
  ([inside-a-galaxy.md](inside-a-galaxy.md#motion)), so thirty seconds among the stars cover a
  megayear or two, a handful of frames, 0.8 GB each at 100 M. This is #299's idea (key frames
  where asked, a visit drawn from them), closed on 2026-11-19 with the 200 M goal, plus short
  runs of frames for slow time.
- A flight would be flown on the 8 M take, whose massive particles are the key frame's to the
  bit, and drawn at 50 or 100 M. On the Mac a far 4K frame at 100 M is 0.87 s
  ([200m-preview.md](200m-preview.md)); the box can draw the stills of a flight today (#347),
  not its video.

### Recommendation

1. **Lever 1 first**: #357, on the 8 M takes, on the Mac, now. It may be all the dive needs.
2. **Then one scene drawn each way, and Pierre chooses on frames** (the ladder, about 10 €): the
   same scene and instant, the same inside views, drawn with #357's stars from (a) today's take,
   (b) 32 M visible, every particle massive, the halo held at 12 M, (c) today's massive set with
   tracers to 50 M and to 100 M. Sheets at 1:1, and a short frozen flight of each. The earlier
   comparisons were made from outside, at t = 0, or on 2 M massive: none answers the question he
   is asking now.
3. **The expected outcome**, to be confirmed or not by the ladder: the 8 M take stays the master
   (exports, the app, authoring flights), and visits inside a galaxy are drawn at 50 M from key
   frames with tracers. It keeps the take and the Mac's work where they are and puts the cost
   where it is cheapest. All massive at 32 M is the fallback if tracers disappoint again; it
   then needs the halo measured, a way to draw flights on the box, and a lighter take for the
   Mac to author on.

## The work, in order

Epic #375, with what each ticket waits for:

1. **#376, the take pass in the shared flow** (Mac, Metal's bytes kept). Nothing before it.
2. **#377, checkpoints and `--resume` for the take pass** (Mac for Metal, the portable parts in
   the workflow). After #376.
3. **#378, the take pass on CUDA**: `sillage-cuda hires` without `--pass full`. After #377. A
   cloud session can write and test it on the CPU target.
4. **#379, key frames where asked, an extract of a take, and a visit drawn from them.** After
   #376; #381 needs it to see tracers from inside.
5. **#283, bring-up and timings on a rented GPU**, updated for today's scenes. Independent of the
   four above; only on Pierre's go, 10 €.
6. **#380, a whole scene on an interruptible box**: it restarts on its own, its take comes back,
   the first scene is compared with the Mac's. After #378 and #283, 5 €.
7. **#381, the ladder**: one scene at 8 M, at 32 M massive and with tracers, Pierre's verdict.
   After #380, #379 and #357, 10 €.
8. **#382, a flight's video on CUDA.** After #369. Needed once a flight is drawn at 50 M or
   more, or from a take the Mac does not hold.

#357 is not part of the epic: it is the free camera's, it needs no GPU but the Mac's, and it
should start first.

Not planned here: nights on a rented box (a scene folder goes and comes back, by hand), several
GPUs, lowering the softening floor, and anything above 100 M drawn.
