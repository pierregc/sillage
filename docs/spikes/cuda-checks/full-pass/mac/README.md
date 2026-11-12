# Metal's side of the full pass comparison (#278)

What the CUDA engine's full pass on the CPU target is compared with: scene-0031 drawn at 200 k
from 50 k massive, its massive pass, then its full pass over 24 frames through the first
pericentre, as `sillage-render` runs them on the Mac. Written on an Apple M4 Max on 2026-11-12
from commit 34e97b2 of `feat/278-cuda-full-pass`, whose full pass gives main's bits (7bfae60):
the 623 tests of `./scripts/dev.sh check` pass, and a 30 frame full pass of this scene (4K and
vertical, checkpoints, stills, the particles at the end) is the same to the byte as on main, run
twice and when killed after a checkpoint and resumed. Nothing here is a timing.

## The scene folder

- `scene.json`: `docs/spikes/tenfold/scene-0031.scene.json` of `assets/tenfold`.
- `look.json`: the repository's `looks/webb.look.json` with the camera of
  `docs/spikes/tenfold/looks/scene-0031.base.look.json` (`director`).
- `clip.json`: written for the check, since the library's own no longer exists: a 50 k
  preview at 3 frames a second, 90 frames of 40 steps, a settle of 750 steps, 480 by 270. At 3
  frames a second the director's plan, whose shots last 2.5 s at least, fits in 24 frames.

## The commands

```
sillage-render hires <scene> --particles 200000 --massive 50000 --dt-scale 3.5 --frames 24 \
    --take-interval 1 --pass massive
sillage-render hires <scene> --particles 200000 --massive 50000 --dt-scale 3.5 --frames 24 \
    --take-interval 1 --pass full --export 4k,vertical --draw-divisor 8 \
    --draw-stills 0,4,12,19,23 --draw-stills-dir <scene>/stills --checkpoint-every 0
```

## The run

| | |
| --- | --- |
| drawn | 200,000: 150,207 light tracers and 49,793 massive visible particles, with 75,000 halo particles (live halos) |
| step | 0.042 (0.19782 Myr), the 50 k massive count's at a time step scale of 3.5 |
| softening | 0.34548503 kpc |
| settle | 750 steps, to 148.4 Myr |
| frames | 24 of 40 steps, 960 steps, 156.3 to 338.3 Myr |
| shots | disk 0 frames 0 to 7, wide 8 to 16, pericentre 17 to 23 |
| key frames | start 0, approach 11, pericentre 19 (306.6 Myr, the centres 6.59 kpc apart), end 23 |
| presets | `4k` at 480 by 270 and `vertical` at 134 by 240 (`--draw-divisor 8`) |

The full pass repeats the massive pass to the bit on all 24 stored frames: the log says so, and
`full/hires.json` has `drift` 0 and every entry of `gaps` at 0 kpc.

## Files

| file | what |
| --- | --- |
| `scene/scene.json`, `scene/clip.json`, `scene/look.json` | the scene folder as both runs read it |
| `scene/take.sillage` | the massive pass's take: the 49,793 massive visible particles on every frame (`--take-interval 1`), which frames the full pass and which a CUDA run's drift is measured against |
| `scene/curves-hires.csv` | the massive pass's curves, from which the key frames are picked |
| `scene/massive.bin` | the massive set as sampled, 124,793 particles, visible first, in the format of a checkpoint's `massive.bin` (`RunCheckpoint.writeMassiveSet`), for a full pass elsewhere to read rather than sample again |
| `scene/hires.json` | the folder's `hires.json` after the massive pass |
| `full/hires.json` | the same after the full pass, with its `full` section |
| `full/keyframes.sillage`, `full/keyframes.json` | every drawn particle at the four key frames |
| `full/stills/` | frames 0, 4, 12, 19 and 23 of both presets as PNGs, as the encoders took them |
| `full/exports/` | `4k.mp4` and `vertical.mp4`, HEVC, 24 frames each |
| `massive.log`, `full.log` | the two runs' output, the scene folder's path written `<scene>` |
| `digests.txt` | SHA-256 of every file here |

## Run after run

The same two commands run twice from an empty scene folder gave the same bytes in every file but
the videos, the timings and memory of `hires.json` and the logs: the take, the curves, the
massive set, the key frames and the PNGs. The videos come from the Mac's hardware HEVC encoder,
which does not always encode the same frames to the same bytes: compare the stills, not the
videos. The massive set is also, to the byte, the one the full pass keeps in its checkpoint
(`.checkpoint/massive.bin`), checked on a088fe4 and on 34e97b2.
