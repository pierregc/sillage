# The CUDA side of the full pass comparison (#278)

The full pass of `../mac/` run again by the CUDA engine on the CPU target, in a cloud session
(Linux x86_64, four cores, no GPU), from commit 72e5a60 of `feat/278-cuda-full-pass`, whose full
pass is the branch's last but for the flush of the settle's log lines.
The scene folder is `../mac/scene/` as the Mac left it after its massive pass: the CUDA engine
reads the Mac's massive particles from `massive.bin`, samples the light tracers itself (a draw on
Linux is the Mac's to rounding, #272), and frames its videos on the Mac's massive take.

```
scripts/linux.sh tool
.build/linux/sillage-cuda check --fixtures Tests/Fixtures/engines
.build/linux/sillage-cuda hires <scene> --particles 200000 --massive 50000 --dt-scale 3.5 \
    --frames 24 --take-interval 1 --pass full --export 4k,vertical --draw-divisor 8 \
    --draw-stills 0,4,12,19,23 --draw-stills-dir <stills> --checkpoint-every 0
```

The run: the same draw (150,207 light tracers, 49,793 massive visible, 75,000 halo), the same
step, settle, 24 frames and director's shots as the Mac's, the key frames picked alike (start 0,
approach 11, pericentre 19, end 23). 57 minutes on the CPU target: the settle's 750 steps in 26
minutes, then 1.8 to 2.1 s a step and 1 to 3 s a frame for both presets (38 s each for the
first frame).

## The stills

PSNR of each still against the Mac's, over the red, green and blue of every pixel, the mean
absolute difference in levels of 255 and the share of the pixels over 8 levels apart
(`scripts/still-pairs.py ../mac/full/stills stills --out pairs --looks 4k,vertical`):

| frame | Myr | shot | 4K at 480 x 270 | vertical at 134 x 240 |
| ---: | ---: | --- | --- | --- |
| 0 | 156.3 | disk 0, close | 50.9 dB, mean 0.076, 0.09 % | 50.1 dB, mean 0.069, 0.11 % |
| 4 | 188.0 | disk 0, close | 51.9 dB, mean 0.097, 0.07 % | 50.6 dB, mean 0.083, 0.08 % |
| 12 | 251.2 | wide | 50.1 dB, mean 0.066, 0.10 % | 48.4 dB, mean 0.095, 0.13 % |
| 19 | 306.6 | pericentre | 43.3 dB, mean 0.485, 0.93 % | 45.4 dB, mean 0.375, 0.59 % |
| 23 | 338.3 | pericentre | 40.9 dB, mean 0.738, 1.80 % | 42.4 dB, mean 0.593, 1.12 % |

Up to frame 12 the frames stand where the renderer alone puts them: #277 drew the frames of a
take of this scene from the same positions on both engines, and the looks with film grain, as
Webb has, came within 49 to 53 dB of Metal's, the grain setting it. From the pericentre on, the
dynamics parting shows: the same picture (`pairs/`, Metal's frame, the CUDA frame, their
difference white at 32 levels), its stars a fraction of a pixel to a few pixels elsewhere.

## The drift

`drift.csv`: on each of the 24 stored frames of the massive take, the largest gap between a
galaxy's centre in the CUDA run and in the Mac's massive pass, in kpc (`hires.json`, `full.gaps`).

| frames | gap |
| --- | --- |
| 0 to 3 | 0.02 to 0.7 pc |
| 4 to 13 | 0.6 to 1.9 pc |
| 14, 15 | 4.2 and 3.4 pc |
| 16 to 22 | 0.8 to 2.3 pc |
| 23 | 19.6 pc |

The largest, 0.0196 kpc, is under the run's bound of 0.062 kpc (`FullPassRun.driftBound`, three
times what Metal parts from itself after a one-bit change over #274's run), so the run did not
warn. A centre moves by the gap of a whole galaxy's centre estimate, which a few particles
crossing its radius shift at once: frame 23, 32 Myr past the pericentre, is where that happens.

## Particle by particle

`keyframes-distance.txt`: every drawn particle of the CUDA run's key frames against the same
particle in the Mac's (`../mac/full/keyframes.sillage`), in kpc, the takes' 21 bits an axis
included:

| key frame | Myr | tracers: median, 99 %, largest | massive visible |
| --- | ---: | --- | --- |
| start, 0 | 156.3 | 0.2 pc, 2.9 pc, 0.036 kpc | 0.2 pc, 3.0 pc, 0.029 kpc |
| approach, 11 | 243.3 | 1.4 pc, 24 pc, 0.29 kpc | 1.4 pc, 24 pc, 0.13 kpc |
| pericentre, 19 | 306.6 | 4.9 pc, 0.107 kpc, 0.88 kpc | 4.9 pc, 0.106 kpc, 1.27 kpc |
| end, 23 | 338.3 | 9.7 pc, 0.25 kpc, 2.4 kpc | 9.6 pc, 0.24 kpc, 5.5 kpc |

The tracers part from the Mac's exactly as the massive particles do, so the light stays on the
mass on CUDA as on Metal. At the pericentre they are as far from the Mac's as #275 measured
(5.1 pc in the median, 0.11 kpc at the 99th percentile, from a draw of tracers the two runs
shared).

## Files

| file | what |
| --- | --- |
| `stills/` | frames 0, 4, 12, 19 and 23 of both presets, as ffmpeg took them |
| `pairs/` | each beside the Mac's with their difference, and `comparison.md` |
| `drift.csv` | the centres' gap on every stored frame |
| `keyframes-distance.txt` | the particles' distance at the key frames |
| `hires.json`, `keyframes.json` | the scene folder's record after the CUDA full pass, and its key frames |
| `exports/` | `4k.mp4` (480 x 270) and `vertical.mp4` (134 x 240), HEVC by libx265, tagged `hvc1`, 24 frames each |
| `engine-check.json` | `sillage-cuda check`'s record for the build that ran |
| `full.log` | the run's output, the scene folder written `<scene>` |
