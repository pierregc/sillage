# Checkpoints: a long run that survives a restart (#240, #377)

Step 4 of epic #236. A full pass at 200 M runs 10 to 20 hours, and until now a restart or a
shutdown of the Mac lost all of it: nothing could resume a hires. A full pass now saves itself
about every hour, and `hires --resume` picks it up from its last checkpoint, to the bit, with
the same videos. Since #377 (epic #375) the pass that writes a take does too:
[its section](#the-pass-that-writes-a-take-377) says what its checkpoint holds on top.

## What is kept, and what is rebuilt

**The solver saves and restores itself** (`MetalBarnesHutSolver.state`, `writeParticles`,
`restore`), so a change to the solver touches one place. It keeps what changes of every
particle, as its buffers hold it: each position and velocity, a light tracer's formation time and
attributes packed in their w (32 bytes a particle, [compact tracers](light-tracers.md#compact-tracers-238)),
and each massive particle's formation time (4 bytes more). And its counters: the time, the steps
since the tree and since the last star formation draw (which seeds it), the halo and mass
centres, each galaxy's motion and the whole state of each disk.

It does not keep what the positions give back exactly:

- **The accelerations.** A step kicks half, drifts, builds the tree, computes the forces and kicks
  the other half, so the accelerations at the end of a step are the forces of a tree built on the
  positions it ends with. A restore builds that tree again (the build alone, without the centres
  and disk frames a rebuild moves on) and computes the same forces, black holes included. A
  tracer keeps none: its fused pass closes a step and opens the next, so its saved velocity is
  half a kick ahead already, and the solver over a resumed run's tracers gives them no first half
  kick (`LightTracerStore(capacity:awaiting:)`).
- **The tracers' walk order**, sorted afresh: it only decides how fast neighbouring tracers walk.
- **The cameras.** The full pass films through `ShotReplay` over the massive take, which replays
  the frames before the one asked for by itself; only each renderer's grain is moved on by the
  frames already drawn (`Renderer.skipFrames`).

**The massive pass leaves its massive set too** (#278): `massive.bin` in the scene folder, the
same bytes a full pass writes into its checkpoint, so that a full pass on another machine reads
the Mac's massive particles rather than sampling them again ([cuda-engine.md](cuda-engine.md#the-full-pass-278)).

**A resumed run samples nothing.** The rest of a massive particle (mass, kind, galaxy, light,
kernel, birth radius) never changes, and the massive set is written once as sampled, beside the
checkpoints (`massive.bin`, 64 bytes a massive particle, first positions and velocities
included), so the resumed run builds its solver over it and leaves the tracers' buffers for the
checkpoint to fill. Sampling again would cost 1.5 us a drawn particle, five minutes at 200 M.

**`RunCheckpoint` writes it.** A checkpoint is `particles-<n>.bin` and `state-<n>.json` (the
solver's counters, the next frame or settle step, where the videos and key frames stand, the run's
identity), each written aside and renamed into place, then `current` names it, and only then is
the one before removed. A restart at any moment leaves a whole checkpoint to read; a crash while
one is written leaves the one before. `massive.bin` is written the same way when the run starts.

**The videos are written in segments**, one a checkpoint interval, since a half-written movie
cannot be reopened: at each checkpoint every format's segment is closed whole, and the next opens.
At the end the segments are joined without encoding them again (their compressed frames copied,
their timestamps moved on), and the video is checked to hold every frame drawn. A resumed run
draws the segment it was writing again from its first frame; the segments before are whole.

**The key frames** go to disk as they are taken, their quantised positions and frame records, and
the key frame take is put together from them at the end, the same take as one held in memory
(byte for byte past its JSON header, whose keys come in no fixed order).

**The run's identity.** A checkpoint records the run's command line (the step `--dt`, the counts,
the export presets, the take interval, the scene file), the scene and the look as read, the size
and date of the massive take, and a digest of the binary. `--resume` refuses a checkpoint whose
command line, scene, look or massive take differ, rather than resuming another step or another
style; a binary rebuilt since is told, not refused, since it is most often the same code.

## The pass that writes a take (#377)

A scene of today is one pass of every particle, 8 M visible on 12 M of dark matter: 2 to 4 hours
on the M4 Max, all of it lost to a restart while only the full pass checkpointed. That pass is
`TakePassRun` since #376, the flow every engine runs
([scenes-on-rented-gpus.md](scenes-on-rented-gpus.md), "Where it lives"), and its checkpoints
are written there, once for all of them. The checkpoint sits where the full pass's does, in the
scene's `.checkpoint/`, and holds on top of it what a run that writes a take carries:

- **The solver: nothing new.** `state`, `writeParticles`, `restore` and `massive.bin`, as above:
  a resumed run samples nothing. The massive set a massive pass leaves in its folder (#278) is
  written again from the checkpoint's.
- **The take, on disk as it is taken.** Without a checkpoint a take fills a quarter of the
  machine's memory, then spills to a scratch file. With one, each kept frame's quantised
  positions are appended to `take.positions` as the frame is taken (`Recording(file:)`), and
  only their records stay in memory (time, box, centres, disks: a few tens of bytes a frame).
  A checkpoint flushes the file and records the frames offered, the kept frames' records and
  the file's length; a resumed run cuts the file back to that length and carries on, and
  refuses a file that holds less. A frame the interval passed over is not kept: the run goes on
  past it. At the end `RecordingFile.write` puts the take together as it always did, the
  positions streamed in after the header: the file of a take held in memory, byte for byte past
  its JSON header.
- **The curves** are written beside the checkpoint (`curves.csv`) and flushed with it; the
  checkpoint records their length, a resumed run cuts them back to it, and the end copies them
  where the run was asked them. A run that follows its story (`--story-cap`) reads them again
  to judge it.
- **A journal of the stretches done** (`FrameJournal`): for each chunk of the settle and each
  captured frame, the run's own steps and its time, centres and disks once stepped, exactly. A
  resumed run replays over it what the CPU carries from frame to frame, rather than saving the
  inside of each: the step scheduler takes each stretch again (`StepScheduler.replay`: the same
  scale, the same switch, the centres shown to its judge), and the cameras move on a frame at a
  time (`TakePassFraming.replay`: the director, or `AutoCamera`). The radius the scene is
  framed at, fixed on the particles of the first frame, is kept as a number, and the time star
  formation counts from is the solver's. The curves could not serve: they print four decimals.
- **`hires.mov` in segments**, one closed at each checkpoint, joined without encoding again at
  the end (`RunVideoSegments`, with the join the full pass's videos use); the renderer's grain is
  moved on by the frames a resumed run drew before.
- **The identity** is #240's: the command line (the counts, the step, its schedule and its
  judge's margin, the take interval), the scene and the look as read, the engine, and the
  binary's digest, told when it changed. `--resume` refuses another run's checkpoint and says
  what differs; a full pass's checkpoint is not a take pass's.

A run with a measuring option (`--density`, `--dump-walk`, `--dump-targets`, `--take-v6`,
`--take-massive`, `--sf-leaves`) is refused with a checkpoint rather than half saved, as is a
solver that keeps no state.

## Which runs checkpoint

Every pass of a hires from a scene folder: the full pass, and the pass that writes a take, one
pass or `--pass massive`. By default about every hour of its run as the cost model prices it
(`--checkpoint-every <minutes>`, 0 for none; `--checkpoint-frames` and `--checkpoint-steps` give
the interval exactly), its settle included. In its settle a take pass checkpoints at the end of
the chunk that crosses the interval: the chunks are where a step schedule switches and shows
its judge the centres, so they stay those of a run without checkpoints. Exploration does not
checkpoint (minutes), nor a plain render that is not given `--checkpoint <dir>`.

A night run again after a restart, and a hires put in the queue again, pick a pass up from its
checkpoint when the checkpoint is that run's own (`SceneFolder.resumesHires`), and start it
over otherwise, which clears it, as does a hires run by hand without `--resume`. A pass that
ends removes its checkpoint.

## Whether it holds, and what it costs

**To the bit at 2 M.** scene-0031 of 2026-10-30-b drawn at 2 M from 500 k massive (1.5 M
tracers, 750 k halo), its first 60 frames after a settle of 792 steps, checkpointed every 250
steps of the settle and every 20 frames: a full pass never stopped, against one killed in its
settle just after its first checkpoint (step 250), resumed, killed again a second after the
checkpoint at frame 40 (its next segment open), and resumed to the end.

- What a checkpoint keeps of the particles at the end, 93 MB, and the solver's counters, centres
  and disks are the same to the bit.
- The 16 stills both runs drew (frames 0, 19 to 21, 39 to 41 and 59, in both formats) are the
  same to the bit, and so is every frame of both videos once decoded, 60 of 60 in 1080p and
  vertical. The videos themselves are the same byte for byte but for a note the encoder writes at
  the start of each segment, an unregistered SEI message of VideoToolbox's that decoders skip,
  which changes from one encoding session to the next: 4 bytes of 5.1 MB differ in 1080p, 5 of
  3.7 MB in vertical.
- The key frame take holds the same three frames to the bit, with the same formation times. Both
  runs report 60 frames, key frames 0, 32 and 59, and no drift from the massive take; the resumed
  one says it was resumed twice.
- The resumed runs read their massive set in 0.1 s at most where the first run sampled the scene
  in 3.2 s, and restored the solver in 0.10 to 0.14 s.

The same check passed on the layout before #238, which kept every field of a tracer.

**At 8 M**, 6 M tracers drawn from 2 M massive and 3 M halo, 11 M particles: scene-0031 again,
alone on the GPU, drawing 4K and vertical, a checkpoint at frame 3, killed, resumed.

- A checkpoint is 0.37 GB, written in 0.10 s with the flush to the disk itself. The massive set,
  0.32 GB, is written once in 0.07 s when the run starts.
- The resumed run read its massive set in 0.1 s, restored the solver in 0.15 s and was stepping
  again 0.6 s after it started, where the first run spent 12.6 s sampling the scene. It peaked at
  a footprint of 4.8 GB.

**At 200 M**, #241's run: 198 M tracers drawn from 2 M massive, 203 M particles with the halo.

- A checkpoint is 6.52 GB, the massive set 0.32 GB once. A file that size written and read as a
  checkpoint is: 1.0 s to write, flushed (6.4 GB/s), and 2.4 s to read back into the buffers from
  the page cache; after a restart the disk's own read comes on top, about a second.
- So an hourly checkpoint costs about a second an hour, and a resume a few seconds where sampling
  again would take five minutes. A restart loses the hour since the last checkpoint at most.
- On disk, until the run ends and removes them: two checkpoints while the next is written
  (13 GB), the massive set, the key frames taken so far (1.6 GB each at 200 M, eight bytes a
  particle since #237) and the video segments.
- One write of 2 GB or more fails on macOS (`EINVAL`), and a buffer of 200 M positions is 3.2 GB:
  the buffers are written 256 MB at a time. The test at the size of 200 M is what found it.

### The take pass, measured (#377)

**To the bit at 2 M.** scene-0031 again, explored at 50 k, then one pass of every particle at
2 M visible on 3 M of dark matter: 60 frames of 76 steps after a settle of 1,501, the standard
step schedule (twice the step through the settle, the run's own from frame 0, twice again from
frame 53, where its judge let it), the director's cameras, checkpointed every 250 steps of the
settle and every 20 frames. A run never stopped, against one killed (`kill -9`) just after its
first checkpoint, in the settle, resumed, killed again a second after the checkpoint before
frame 20, a segment of its video open, and resumed to the end.

- The take (0.31 GB) is the same file, header included, and so are the curves, the particles a
  checkpoint keeps at the end (180 MB) with the solver's counters, centres and disks, and
  `hires.json` but for its durations and its `resumes`, 2: the same switches, 5,073 steps run
  for 6,061 of the run's own.
- The frames handed to the video's encoder are the same: the same check with every frame also
  written as a PNG (`--out`, 24 frames, killed in the settle and after the checkpoint before
  frame 8) gives the same 24 PNGs, to the byte. `hires.mov` itself is not held to its bits:
  it holds 60 frames in both runs and their first 49 decode the same, across both resumes, but
  the last 11 differ by what the encoder made of them, 41 to 51 dB apart. With other runs on
  the GPU, as there were, VideoToolbox puts key frames in places that change from one run to
  the next (one at frame 51 of the run never stopped; in the PNG check, run under a heavier
  load, three in the run never stopped and none in the resumed one), and a preview of #376
  differed the same way. So the test compares the stills read off the frames, not the video.
- A checkpoint is 0.18 GB and takes 0.05 to 0.08 s in all, the take and the curves flushed and
  the video's segment closed. The massive set, 0.32 GB, is written once in 0.07 s. A resumed
  run had read it and restored its solver in 0.8 to 0.9 s.

**At 8 M visible on 12 M of dark matter**, a scene of today, every particle massive:
scene-0031 at 20 M particles, 80 frames of 7 steps after a settle of 140, every frame kept (a
take of 5.3 GB), checkpointed every 20 steps of the settle and every 20 frames; then the same
run with `--checkpoint-every 0`, and one killed after the checkpoint before frame 20 and
resumed. Not alone on the GPU: a full pass at 50 M and two other threads' runs were on it, so
the times are upper bounds. They are the disk's more than the GPU's.

- A checkpoint is 0.72 GB, 32 bytes a particle and 4 a massive one, and takes 0.16 to 0.21 s
  in all, the 1.3 GB of take written since the one before flushed with it. The massive set,
  1.28 GB, is written once in 0.25 s. An hourly checkpoint costs a fifth of a second an hour.
- The resumed run had read its massive set and restored its solver in 3.6 s, where the first
  run spent 17 s sampling the scene and building its solver before its first step.
- The peak footprint is 6.5 GB with checkpoints against 10.8 GB without: the take is no longer
  held in memory. Without a checkpoint a take holds up to a quarter of the machine (9 GB on the
  M4 Max's 36) before it spills, which a whole scene's take of 15 to 25 GB reaches.
- Both runs wrote the same take, to the byte, and the same curves. `hires.mov` is not the same
  video: with checkpoints it is four segments, each starting on a key frame, joined.
- On disk until the run ends: two checkpoints while the next is written (1.4 GB), the massive
  set, and the take so far with the curves and the video's segments.

**What the end costs.** Putting the take together copies its positions once from
`.checkpoint/take.positions` into the take: 1.7 s for 5.3 GB (3 GB/s), so 5 to 8 s for a scene's
15 to 25 GB, during which the disk holds the take twice; the checkpoint is removed once the
take, the curves and the video are in place. A layout that spares the copy needs no version of
the format for a hires: its frames are counted before it starts (the story's frames, one in
`--take-interval`, and the last), so the length of the header and where the positions begin are
known, and they could be written in place in the take, the header and the records filled in at
the end. Only a run that follows its story past its planned frames does not know its count,
and that is exploration, which does not checkpoint. Seconds at the end of hours do not ask for
it on the Mac; a rented box's disk, sized for the take twice, may (#380).

