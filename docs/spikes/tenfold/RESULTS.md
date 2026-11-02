# Tenfold study: measurements

Measured on 2026-11-02 between 22:25 and 22:46 CET on Pierre's Mac, build of `origin/main`
at d3c0be0 ("spike(render): why a render reads as sand, and what buys the halo (#182)") in a
detached worktree `~/claude-workspace/sillage-wt-tenfold`, now removed. Measurement only: no code
change, no commit, nothing on GitHub. GPU lock held from 22:26:57 to 22:45:58. Every timed run
started with the GPU at 0 %. Only one start (glint03-8M) saw another thread's `sillage-render`,
and it was gone within two seconds.

## Summary

- **Picture.** A single disk at 20M, 50M and 100M particles reads differently from 8M at 1:1 in
  4K and in the close-up, and the difference survives a downscale to 1080p. Shrunk to a 720 px
  wide frame, all counts look the same. In the close-up, 8M is a field of 5 to 10 px blots
  (bokeh) and 20M still has smaller ones; the blots are gone at 50M; 100M is a continuous surface
  with sharp dust lanes. At glint 1 the sparkle stays at every count (points 3.7 % at 8M, 3.1 % at
  100M); at glint 0.3 it halves (3.1 % to 1.5 %).
- **Drawing.** A 4K frame costs a GPU time roughly proportional to the count: 58, 135, 300 and
  670 ms at 8M, 20M, 50M and 100M for the full disk (close-up 94 to 914 ms), plus 13 to 215 ms
  of smoothing. 100M on the disk preset peaks at 22.5 GB, and during each 100M run the system
  compressed 16 to 18 GB of pages.
- **Solver.** Run a reproduces the reference: 565 ms a step at 10M visible / 25M simulated
  (gigantism note: 550 ms), 8.2 GB peak (note: 8.3). 50M simulated (20M visible, halo 1.5):
  1430 ms a step, 15.3 GB. 32M (20M, halo 0.6): 806 ms, 10.3 GB. 52M (40M, halo 0.3):
  1312 ms, 16.0 GB. So 25 to 29 ns and about 306 bytes per simulated particle.
- **The softening floor.** The softening is `max(0.03 kpc, 1.5 x disk spacing)`. Scene-0031
  reaches the 0.03 kpc floor at about 6.6M visible, so runs a to d all use the same softening and
  the same step (0.0575 Myr). Past about 7M visible, more particles neither shorten the step nor
  sharpen the force resolution. They still lower the particle noise.
- Nothing failed and nothing was skipped. 100M ran because the 50M disk runs peaked at
  12.4 GB (< 13 GB). Run d ran because b peaked at 15.3 GB (< 20 GB).

## Machine

| | |
| --- | --- |
| Chip | Apple M4 Max, 14 CPU cores, 32 GPU cores |
| Memory | 38 654 705 664 bytes (36 GB), unified |
| Disk | 1.8 TB, 1.3 TB free |
| macOS | 26.5.1 (25F80) |
| Metal `maxBufferLength` | 22 613 000 192 bytes (22.6 GB) |
| Metal `recommendedMaxWorkingSetSize` | 30 150 672 384 bytes (30.2 GB) |
| Swap at 22:32, before the 100M runs | 9.4 GB used of 10 GB, about 27 GB held in the compressor (mostly other apps) |

## How it was run

Build, once (80 s, binary dated 22:26, linked to the worktree's own dylibs by absolute path):

    cd ~/claude-workspace/sillage-wt-tenfold && ./scripts/dev.sh build

Every run went through `tenfold-out/run.sh <log> <command...>`, which logs the GPU utilisation and
any other `sillage-render` or `Sillage` process before and after, then runs:

    script -q /dev/null /usr/bin/time -l <command...> </dev/null 2>&1 | <timestamper>

- **Two changes to the brief's command line.** First, `script` gives the binary a terminal.
  Piped, Swift's `print` is block-buffered, so every timestamp would land at the exit. Second,
  the timestamper counts from a time taken just before launch, not from Python's own start.
- **File names.** They write the halo ratio as `1p5`, `0p6` and `0p3`. The renderer names the
  sidecar files after the output's first dot, so `10000000-1.5.png` would give
  `10000000-1.scene.json`.
- **Columns.** "Sampling" is the time between the `scene` line and the `solver` line: drawing the
  particles plus building the solver, renderer and smoothing buffers. "First frame" is when the
  `frame 0000` line printed. It also includes the first step, framing (a sort of every radius)
  and the first draw.

Environment for every run: `BIN=.build/dev/sillage-render`,
`DYLD_LIBRARY_PATH=$PWD/.build/dev`, `OUT=~/claude-workspace/tenfold-out`, run from the worktree.

## Step 1: one disk, restricted solver, t = 0, 4K

Looks made from `library/2026-10-30-b/scene-0031/look.json` (copied to
`looks/scene-0031.base.look.json`). Every look uses the camera
`{"mode":"fixed","elevation":1.35,"azimuth":0.4,"zoom":1.0,"percentile":0.98,"radius":0}`:

- `glint1`: the look unchanged (no `glint` field, so 1)
- `glint03`: `look.glint` = 0.3
- `close`: glint 0.3 and camera zoom 3.0

Command, for N in 8000000 20000000 50000000 100000000 and L in glint1 glint03 close:

    $OUT/run.sh $OUT/logs/disk-$L-$N.log $BIN --preset disk --particles $N --steps 2 --frames 2 \
        --seed 7 --width 3840 --height 2160 --look $OUT/looks/$L.look.json \
        --out $OUT/disk/$L-$N.png --no-sidecars

The disk is about 1460 px across in the full frame (radius about 730 px). Frame 0 carries the
warm-up; frame 1 is the cost. "Step" is the restricted solver's step, which says nothing about a
real run.

| look | N | sampling (s) | first frame (s) | frame 0: render gpu / smoothing / step (ms) | frame 1: render gpu / smoothing / step (ms) | done in (s) | real (s) | peak footprint (GB) | max RSS (GB) |
| --- | ---: | ---: | ---: | --- | --- | ---: | ---: | ---: | ---: |
| glint1 | 8M | 4.9 | 6.9 | 203.4 / 77.2 / 7.7 | 58.8 / 13.2 / 2.7 | 1.7 | 7.3 | 3.47 | 1.54 |
| glint1 | 20M | 11.4 | 14.2 | 386.6 / 54.2 / 11.6 | 134.7 / 34.9 / 8.0 | 3.1 | 14.8 | 6.10 | 3.78 |
| glint1 | 50M | 29.1 | 35.5 | 1181.9 / 125.0 / 24.5 | 291.7 / 100.4 / 17.0 | 6.9 | 36.4 | 12.39 | 9.11 |
| glint1 | 100M | 58.4 | 71.6 | 1712.2 / 1294.0 / 42.9 | 687.8 / 205.7 / 173.8 | 14.5 | 73.5 | 21.74 | 18.12 |
| glint03 | 8M | 4.4 | 6.0 | 224.7 / 23.9 / 6.6 | 58.2 / 13.4 / 2.7 | 1.7 | 6.4 | 3.47 | 1.54 |
| glint03 | 20M | 11.4 | 14.3 | 481.6 / 55.4 / 12.0 | 135.7 / 34.3 / 6.7 | 3.1 | 14.8 | 6.10 | 3.78 |
| glint03 | 50M | 29.3 | 35.3 | 837.8 / 129.2 / 25.0 | 302.4 / 101.8 / 16.6 | 6.6 | 36.2 | 12.40 | 9.11 |
| glint03 | 100M | 62.8 | 76.8 | 1590.7 / 1011.9 / 359.0 | 671.5 / 214.9 / 179.2 | 15.2 | 78.6 | 22.47 | 15.69 |
| close | 8M | 4.4 | 6.0 | 278.2 / 24.0 / 6.5 | 94.2 / 13.6 / 2.6 | 1.7 | 6.4 | 3.47 | 1.54 |
| close | 20M | 11.4 | 14.5 | 715.2 / 53.3 / 12.1 | 180.2 / 42.0 / 8.7 | 3.4 | 15.1 | 6.10 | 3.78 |
| close | 50M | 29.4 | 36.0 | 1432.7 / 131.0 / 24.9 | 449.3 / 101.7 / 17.9 | 7.3 | 37.0 | 12.39 | 9.11 |
| close | 100M | 58.8 | 72.8 | 2130.8 / 1339.3 / 44.7 | 913.5 / 206.4 / 174.5 | 15.4 | 74.7 | 22.47 | 18.12 |

- **Sampling** is linear: about 0.59 µs a particle (single-threaded, 58 to 63 s at 100M).
- **Memory** is about 1.7 GB plus about 205 bytes a particle (+219 B a particle from 8M to 20M,
  +210 from 20M to 50M, +202 from 50M to 100M).
- **Render GPU on frame 1.** The full disk costs about 6 to 7 ms per million particles (5.8 to
  7.4), the close-up 9 to 12 ms. Glint 0.3 costs the same as glint 1. The 8M frame (58.8 ms)
  matches the gigantism note's 55 ms.
- **100M is at the edge of the machine.** During the glint1 and close runs the system compressed
  15.9 and 18.1 GB of pages, decompressed 6.0 and 6.7 GB, and swapped out 0 and 0.7 GB (from
  `vm_stat`; not recorded for glint03-100M, which saw +106 page-outs). The restricted step jumps
  from 17 ms at 50M to 174 to 179 ms at 100M, a single GPU dispatch with nothing else in it, and
  frame-0 smoothing jumps from 130 ms to 1.0 to 1.3 s. I read both as memory pressure, not as
  scaling. Render and frame-1 smoothing stay close to linear (2.0 to 2.4 times the 50M cost).

Grain scores (`python3 scripts/grain.py score $OUT/disk/*.0001.png > $OUT/disk-scores.tsv`):

| look | N | grain | structure | points | body | mean |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| glint1 | 8M | 0.1026 | 0.0566 | 3.67 % | 0.193 | 0.477 |
| glint1 | 20M | 0.1108 | 0.0511 | 3.60 % | 0.193 | 0.477 |
| glint1 | 50M | 0.1126 | 0.0485 | 3.38 % | 0.193 | 0.476 |
| glint1 | 100M | 0.1086 | 0.0476 | 3.09 % | 0.193 | 0.477 |
| glint03 | 8M | 0.0895 | 0.0552 | 3.06 % | 0.192 | 0.464 |
| glint03 | 20M | 0.0907 | 0.0505 | 2.59 % | 0.192 | 0.465 |
| glint03 | 50M | 0.0865 | 0.0483 | 1.97 % | 0.192 | 0.465 |
| glint03 | 100M | 0.0801 | 0.0476 | 1.47 % | 0.192 | 0.466 |
| close | 8M | 0.0262 | 0.0423 | 0.38 % | 0.826 | 0.613 |
| close | 20M | 0.0328 | 0.0336 | 0.43 % | 0.821 | 0.615 |
| close | 50M | 0.0382 | 0.0276 | 0.41 % | 0.820 | 0.613 |
| close | 100M | 0.0402 | 0.0244 | 0.34 % | 0.819 | 0.614 |

As the gigantism note warned, grain and structure cannot rank the counts. In the close-up, grain
rises (0.026 to 0.040) and structure falls (0.042 to 0.024) because a particle shrinks from a 4 to
16 px blot into a pixel. Of the three, "points" (sparkle) is the column to read.

### What the sheets and crops show

Sheets: `sheet-glint03.jpg`, `sheet-close.jpg` and `sheet-glint1.jpg`, made with `grain.py sheet
--crop auto`. Each row is one count, from 8M to 100M: the frame shrunk to 720 px, then a 1:1
640x420 crop chosen on the 8M frame and kept for every row. Crops: 800x800 px at 1:1, JPG
quality 92. `crop-close-8M.jpg` and `crop-close-100M.jpg` are taken at the frame centre (box
1520,680-2320,1480). `crop-glint03-8M.jpg` and `crop-glint03-100M.jpg` are centred 360 px to the
right of the disk's light centre (1916, 1090), halfway to the edge at about 720 px (box
1876,690-2676,1490); being 800 px wide, they run from the core at the left edge to past the rim.

**Full frame (glint 0.3 and glint 1)**

- Shrunk to 720 px, the four counts cannot be told apart, at either glint.
- At 1:1, glint 0.3:
  - 8M: fine sand with residual pinpoints. The HII knots are dissolved into the speckle; the dust
    lanes are visible but broken.
  - 20M: finer sand and fewer points. The knots start to separate as soft lilac smudges.
  - 50M: a continuous fine texture, few points, continuous lanes.
  - 100M: a smooth light with film-like grain at the pixel, sharp continuous dust filaments
    (more of them in the inner disk), and a clean rim.
- The biggest single step is 8M to 50M; 50M to 100M refines it.
- Something 8M hid: from 50M the HII knots become the most visible small-scale feature, a string
  of elongated lilac-white smudges of near identical shape along the arms. They read a little
  stamped, like brush strokes. They may be the next thing to look at.
- Glint 1: the compact sources stay as glitter at every count. They get finer and denser, but
  the disk still sparkles at 100M. More particles do not remove the sparkle; the glint does.

**Close-up (zoom 3, the inner disk fills the frame)**

- The difference shows even in the 720 px column. 8M is speckled toward the corners. From 50M
  the knots and the many thin dust lanes stand out, and 100M is the smoothest.
- At 1:1 in the outer disk (the sheet's crop, top left):
  - 8M is a field of 5 to 10 px blots, like bokeh, with pink and blue mottling.
  - 20M still shows blots, smaller.
  - 50M is fine 2 to 4 px grain.
  - 100M is fine sand, with the arm readable as a soft band.
- The blots go between 20M and 50M in this framing (between 4M and 8M in the full frame, per the
  gigantism note).
- Centre crop:
  - 8M is sugary and washed out, with sparse pink and blue specks. The inner spiral is faint
    and the lanes barely show.
  - 100M is a continuous surface, with the inner spiral and dozens of thin dark lanes drawn
    sharply around the core.
- A faint rectangle (about 8x16 px) sits at the exact centre of every close-up, identical at 8M,
  20M, 50M and 100M. It does not come from sampling. Not investigated.

**At 1080p.** `extra-1080p-8M-vs-100M.jpg` is not in the brief: the same regions after
downscaling the 4K frames by two. The 8M to 100M difference survives in both framings.

The 4K PNGs (24 files) were deleted after the sheets and crops were made.

## Step 2: the self-gravitating solver past 10M visible

Scene `library/2026-10-30-b/scene-0031/scene.json`, copied to `$OUT/scene-0031.scene.json` (two
spirals, live halos at 1.5, opening angle 0.9, `timeStepScale` 3.5). Commands, in this order:

    a  $OUT/run.sh $OUT/logs/solver-10000000-1p5.log $BIN --scene $OUT/scene-0031.scene.json --particles 10000000 --steps 30 --frames 3 --width 1280 --height 720 --out $OUT/solver/10000000-1p5.png
    b  $OUT/run.sh $OUT/logs/solver-20000000-1p5.log $BIN --scene $OUT/scene-0031.scene.json --particles 20000000 --halo 1.5 --steps 30 --frames 3 --width 1280 --height 720 --out $OUT/solver/20000000-1p5.png
    c  $OUT/run.sh $OUT/logs/solver-20000000-0p6.log $BIN --scene $OUT/scene-0031.scene.json --particles 20000000 --halo 0.6 --steps 30 --frames 3 --width 1280 --height 720 --out $OUT/solver/20000000-0p6.png
    d  $OUT/run.sh $OUT/logs/solver-40000000-0p3.log $BIN --scene $OUT/scene-0031.scene.json --particles 40000000 --halo 0.3 --steps 30 --frames 3 --width 1280 --height 720 --out $OUT/solver/40000000-0p3.png

| run | visible | halo | simulated | sampling (s) | first frame (s) | ms a step, frames 0 / 1 / 2 | ms a step, last two | smoothing, last two (ms) | render gpu, last two (ms) | done in (s) | real (s) | peak footprint (GB) | max RSS (GB) | softening (kpc) | timeStep |
| --- | ---: | ---: | ---: | ---: | ---: | --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| a | 10 000 000 | 15 000 000 | 25 000 000 | 18.8 | 27.0 | 564.8 / 565.3 / 564.0 | **564.6** | 3.9, 4.3 | 38.2, 40.4 | 19.4 | 38.5 | 8.18 | 4.81 | 0.0300 | 0.012208 = 0.0575 Myr |
| b | 20 000 000 | 30 000 000 | 50 000 000 | 38.0 | 57.0 | 1419.4 / 1403.8 / 1455.4 | **1429.6** | 8.3, 8.2 | 103.6, 106.0 | 47.7 | 86.0 | 15.28 | 9.59 | 0.0300 | 0.012208 = 0.0575 Myr |
| c | 20 000 000 | 12 000 000 | 32 000 000 | 35.2 | 47.0 | 870.0 / 776.1 / 835.6 | **805.9** | 7.3, 7.6 | 80.7, 92.6 | 28.0 | 63.5 | 10.31 | 6.29 | 0.0300 | 0.012208 = 0.0575 Myr |
| d | 40 000 000 | 12 000 000 | 52 000 000 | 68.7 | 89.6 | 1591.0 / 1308.6 / 1315.2 | **1311.9** | 15.8, 18.8 | 170.1, 161.4 | 47.5 | 116.5 | 15.97 | 10.10 | 0.0300 | 0.012208 = 0.0575 Myr |

- **Softening and time step are not in the sidecar scene file.** It is identical to the input for
  a and b. For c and d it only spells out default fields the original left implicit
  (`armMassContrast`, `massLopsidedness`, `youngClumpiness`, the re-rounded `particleShare` and so
  on) and the new halo ratio. The galaxies' positions and velocities are unchanged, so the four
  runs start from the same orbits. Both values are derived at run time from the counts
  (`SceneFile.scene(particleCount:)`, then `retune()`). I computed them with `tools/softening.swift`,
  linked against the same build, which follows main.swift's path. The frame lines agree: 10 steps
  = 0.575 Myr (t = 0.6, 1.1, 1.7).
- **Reference.** a against the gigantism note at 10M: 565 against 550 ms a step (+2.7 %),
  8.18 against 8.3 GB.
- **Per particle.** 22.6, 28.6, 25.2 and 25.2 ns per simulated particle step (a, b, c, d);
  56.5, 71.5, 40.3 and 32.8 ns per visible one. Peak memory 327, 306, 322 and 307 bytes per
  simulated particle.
- **Per simulated megayear** (step / 0.0575 Myr): 9.8, 24.9, 14.0 and 22.8 s.
- **The halo is the cheap lever.** At 20M visible, halo 0.6 instead of 1.5 takes 44 % off the step
  and 33 % off the memory. 40M visible at halo 0.3 costs less a step than 20M at 1.5. What a
  lighter live halo does to the dynamics was not measured here.
- **Sampling.** About 1.65 µs per visible particle and about 0.15 µs per halo one (single-threaded).
- **Steadiness, with nothing else on the GPU.** a holds within ±0.1 % and b within 4 % across
  its three frames. c spreads 12 % (8 % over its last two). d's frames 1 and 2 agree within
  0.5 %, but its frame 0 is 21 % slower.
- **Frames.** All 12 PNGs (1280x720, kept in `solver/`) show a normal frame (mean luminance 0.06,
  10 to 11 % of pixels above 0.1): no run blew up.

**The softening floor.** `SceneConfig.recommendedSoftening` is
`min(max(0.03, max over galaxies of 1.5 * sqrt(pi * edge^2 / N_galaxy)), 1)`, with edge =
diskScaleLength x diskTruncation. On scene-0031 the second galaxy (46 % of the particles,
edge 19.7 kpc) sets it, and it reaches the floor at about 6.6M visible. Probe values:

| visible | softening (kpc) | step (Myr) |
| ---: | ---: | ---: |
| 2M | 0.0546 | 0.1047 |
| 5M | 0.0346 | 0.0662 |
| 8M | 0.0300 | 0.0575 |
| 10M, 20M, 40M, 50M | 0.0300 | 0.0575 |

Without the floor, 100M visible would get 0.0077 kpc and a step 3.9 times shorter. The library's
own 2M hire of this scene is recorded as softening 0.0546 and step 0.0989 Myr, 8968 steps (settle
included) over 887 Myr, in 1003 s (112 ms a step on average, its 960x540 frames included).
For scene-0030 the floor is not reached at 8M (softening 0.0415): the floor depends on the
disks' size.

## What the numbers say about 10x (extrapolation, not measured)

- **Memory.** At about 306 bytes per simulated particle, 100M visible with a halo at 0.3 (130M
  simulated) needs about 40 GB: it does not fit in this Mac. The 26 GB guard allows about 85M
  simulated, for example 60M visible at halo 0.3. Metal's buffer limit is not what binds: the
  largest buffer at 130M is 2.1 GB, against a 22.6 GB cap.
- **Time.** A full run of scene-0031 (887 Myr at 0.0575 Myr, 15 426 steps), at the t = 0 cost
  measured here, would take:

  | run | full run |
  | --- | ---: |
  | a | 2.4 h |
  | b | 6.1 h |
  | c | 3.5 h |
  | d | 5.6 h |

  Against 17 min for today's 2M hire. At 25 to 29 ns a particle step, 130M simulated would be 3.3
  to 3.8 s a step, 14 to 16 h a hires with the floor. Lowering the floor would multiply the steps
  by 3.9.
- **Drawing is not what decides.** At 100M visible a 4K frame is about 0.7 to 0.9 s of GPU plus
  0.2 s of smoothing, about 15 min for a 923-frame export. It does rule out real-time playback in
  the app at those counts.
- **Takes.** At the gigantism note's six bytes a particle a frame, a take grows in proportion to
  the count: about 28 GB at 20M visible and 142 GB at 100M for this scene's 923 frames, interval 4
  (the 2M take is 2.84 GB).

## Other processes, failures, deviations

- **Other processes on the Mac.** Four other threads (worktrees 184 to 187) were compiling at the
  start (CPU only). WindowServer and the Claude app used about 50 % of a core each at both checks
  (22:24 and 22:43). No headless Chromium or other GPU benchmark was found.
- **Short Sillage processes from other threads while I held the lock** (watcher log
  `logs/process-watch.log`: 5 s polling until 22:29:43, then 1 s):

  | time | process | what it overlapped |
  | --- | --- | --- |
  | 22:28:16 | `sillage-render` pid 84697, under 2 s, GPU at 0 % | between my runs |
  | 22:31:25 to 27 | `look .../scene-0031 --grid --stills` | sampling of close-50M |
  | 22:32:56 to 57 | the same | sampling of glint03-100M |
  | 22:34:23 to 25 | the same | sampling of glint1-100M |
  | 22:33:13 to 27 | `Sillage.app --nightcheck` | the end of glint03-100M's setup and its frame 0 |
  | 22:42:29 to 33 | `Sillage.app --nightcheck` | sampling of run c |
  | 22:36:45, 22:37:55, 22:38:11, 22:40:13 to 17 | five more `look` processes (two from `sillage-wt-186`, one on scene-0030) | between my runs |

  None overlapped a frame used in the tables, as far as the watcher's polling can tell. The
  frame 0 of glint03-100M that one overlapped is not used, and the other two 100M runs, which saw
  no overlap, give the same frame-1 numbers.
- **Failures.** Nothing failed. The only hiccup was outside the runs: a shell quoting slip in
  the probe loop, rerun at once.
- **Skips.** None. Every run in the brief ran, 100M and d included.
- **Deviations from the brief.**
  - The `script` wrapper and the launch-time timestamps (see "How it was run").
  - The `1p5`, `0p6` and `0p3` file names.
  - Softening and timeStep computed with a probe, because the sidecar does not hold them.
  - `vm_stat` deltas added to the 100M disk runs (all but glint03-100M) and to the solver runs.
  - One extra JPG at 1080p.
- **Wrap-up.** GPU lock released at 22:45:58. The worktree
  `~/claude-workspace/sillage-wt-tenfold` was removed with `git worktree remove --force` after this
  file was written.

## Files in ~/claude-workspace/tenfold-out

- `RESULTS.md`: this file. `run.sh`: the runner. `build.log`.
- `looks/`: the base look and the three variants.
- `scene-0031.scene.json`: the copied scene.
- `logs/`: one log per run (`disk-<look>-<N>.log`, `solver-<N>-<halo>.log`) and
  `process-watch.log`.
- `disk-scores.tsv`.
- `sheet-glint03.jpg`, `sheet-close.jpg`, `sheet-glint1.jpg`.
- `crop-close-8M.jpg`, `crop-close-100M.jpg`, `crop-glint03-8M.jpg`, `crop-glint03-100M.jpg`.
- `extra-1080p-8M-vs-100M.jpg`.
- `solver/`: the 720p frames and the sidecar scene and look files of runs a to d.
- `tools/`: `limits.swift` (the Metal limits probe) and `softening.swift` (the softening and
  step probe; build with
  `swiftc -O -I .build/dev -L .build/dev -lSillageCore softening.swift` from a checkout).
