# Checkpoints: a long run that survives a restart (#240)

Step 4 of epic #236. A full pass at 200 M runs 10 to 20 hours, and until now a restart or a
shutdown of the Mac lost all of it: nothing could resume a hires. A full pass now saves itself
about every hour, and `hires --resume` picks it up from its last checkpoint, to the bit, with
the same videos.

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

## Which runs checkpoint

The full pass, by default about every hour of its run as the cost model prices it
(`--checkpoint-every <minutes>`, 0 for none; `--checkpoint-frames` and `--checkpoint-steps` give
the interval exactly), its settle included. A run that writes a take does not: the massive pass
holds its take in memory until it ends and costs 18 minutes at 8 M drawn (20 to 40 at 200 M), and
a night's one-pass hires about an hour, which a restart loses whole as before.

A night run again after a restart picks its full pass up from its checkpoint when the checkpoint
is that run's own (`SceneFolder.resumesFullPass`), and starts it over otherwise, which clears it.
A full pass that ends removes its checkpoint.

MEASURED

