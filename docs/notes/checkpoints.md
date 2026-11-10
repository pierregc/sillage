# Checkpoints: a long run that survives a restart (#240)

Step 4 of epic #236. A full pass at 200 M runs 10 to 20 hours, and until now a restart or a
shutdown of the Mac lost all of it: nothing could resume a hires. A full pass now saves itself
about every hour, and `hires --resume` picks it up from its last checkpoint, to the bit, with
the same videos.

## What is kept, and what is rebuilt

**The solver saves and restores itself** (`MetalBarnesHutSolver.state`, `writeParticles`,
`restore`), so a change to the solver touches one place. It keeps every particle's position,
velocity and formation time, as its buffers hold them (36 bytes a particle), and its counters:
the time, the steps since the tree and since the last star formation draw (which seeds it), the
halo and mass centres, each galaxy's motion and the whole state of each disk.

It does not keep what the positions give back exactly:

- **The accelerations.** A step kicks half, drifts, builds the tree, computes the forces and kicks
  the other half, so the accelerations at the end of a step are the forces of a tree built on the
  positions it ends with. A restore builds that tree again (the build alone, without the centres
  and disk frames a rebuild moves on) and computes the same forces, black holes included.
- **Every other field of a particle**: mass, component, galaxy, population, light, birth radius.
  They never change, and the resumed run samples the same scene with the same seed.
- **The cameras.** The full pass films through `ShotReplay` over the massive take, which replays
  the frames before the one asked for by itself; only each renderer's grain is moved on by the
  frames already drawn (`Renderer.skipFrames`).

**`RunCheckpoint` writes it.** A checkpoint is `particles-<n>.bin` and `state-<n>.json` (the
solver's counters, the next frame or settle step, where the videos and key frames stand, the run's
identity), each written aside and renamed into place, then `current` names it, and only then is
the one before removed. A restart at any moment leaves a whole checkpoint to read; a crash while
one is written leaves the one before.

**The videos are written in segments**, one a checkpoint interval, since a half-written movie
cannot be reopened: at each checkpoint every format's segment is closed whole, and the next opens.
At the end the segments are joined without encoding them again (their compressed frames copied,
their timestamps moved on), and the video is checked to hold every frame drawn. A resumed run
draws the segment it was writing again from its first frame; the segments before are whole.

**The key frames** go to disk as they are taken, their quantised positions and frame records, and
the key frame take is put together from them at the end, the same bytes as a take held in memory.

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

## With #238

#238 moves the tracers out of the solver's full buffers into buffers of their own. Those buffers
join `writeParticles` and `restore`, and nothing else changes: what a checkpoint keeps of a
particle is still what the solver writes during a step.
