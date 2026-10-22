# Milestone 7: single scene performance, final measurement

Same command and machine as the #26 baseline (M4 Max, macOS 26.5.1): `Sillage --baseline <visible> 100 [quiet]`, merger preset, seed 1, live halos at 1.5, 100 steps after warm-up. Measured on main at 67f8008.

What differs from the baseline run: the opening angle is now 0.9 (it was 0.7) and cells carry quadrupoles (#57, #60); the tree is built on the GPU (#57); the live app steps with `treeReuse` 1 as in the baseline.

## Per step, ms (quiet run, mean over 100)

| phase | 700k before | after | 2M before | after | 5M before | after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| star formation | 0.4 | 0.33 | 1.7 | 1.80 | 6.0 | 6.49 |
| drift | 0.4 | 0.32 | 1.3 | 1.08 | 6.5 | 2.82 |
| position snapshot | 0.4 | 0 | 1.8 | 0 | 3.9 | 0 |
| halo centres | 3.6 | 0.63 | 10.4 | 1.39 | 26.6 | 3.04 |
| disk frames | 0.7 | 0.50 | 1.1 | 1.00 | 1.4 | 1.32 |
| tree build (all phases) | 39.7 | 2.94 | 117.0 | 9.49 | 314.7 | 25.74 |
| buffer upload | 0.3 | 0 | 1.0 | 0 | 2.8 | 0 |
| force pass | 50.7 | 28.95 | 150.8 | 85.34 | 391.3 | 219.69 |
| kick + dissipation | 0.8 | 0.39 | 1.5 | 1.09 | 3.1 | 2.68 |
| **whole step** | **97.7** | **35.8** | **285.7** | **103.8** | **752.1** | **264.5** |
| speedup | | 2.7x | | 2.8x | | 2.8x |
| steps per second | 10.2 | 27.9 | 3.5 | 9.6 | 1.3 | 3.8 |

Tree build: 13.5x, 12.3x and 12.2x faster. Force pass: 1.75x to 1.78x (mostly the wider opening angle; the quadrupoles buy back the accuracy). The force pass is now 81 to 83 % of a step, against 51 to 53 %.

## Per frame, ms (run with frames)

| | 700k before | after | 2M before | after | 5M before | after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| smoothing refresh | 17.7 | 0.5 | 45.2 | 0.8 | 117.2 | 2.6 |
| render GPU, solver idle | 4.2 | 2.5 | 7.3 | 6.6 | 14.8 | 11.9 |
| render GPU, solver stepping, median / p95 | 4.1 / 54.8 | 13.6 / 21.1 | 9.0 / 159.6 | 36.2 / 91.1 | 14.4 / 44.0 | 34.6 / 238.2 |
| frame gap, median / p95 | 21.4 / 56.9 | 20.2 / 23.3 | 19.0 / 162.2 | 38.1 / 93.1 | 16.9 / 46.3 | 42.1 / 240.3 |

## Utilisation (quiet / with frames)

| | 700k before | after | 2M before | after | 5M before | after |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| process CPU, cores busy | 0.6 / 0.7 | 0.2 / 0.3 | 0.7 / 0.7 | 0.1 / 0.2 | 0.7 / 0.8 | 0.1 / 0.1 |
| solver GPU span, share of wall | ~52 % | 90 / 89 % | ~53 % | 94 / 93 % | ~52 % | 96 / 94 % |
| GPU idle share of a step | | 8 % | | 5 % | | 3 % |

## Largest interactive count (frame gap p95 under 33 ms)

- Before: none of the three sizes (p95 of 56.9 ms at 700k).
- After: 700k (p95 23.3 ms, max 32.8 ms). 2M and 5M fail.

## What it says, and what to attack next

- The gain is real on the solver: about 2.8x a step at every size, with the CPU out of the critical path (the GPU is busy 90 to 96 % of the wall clock, from 52 %).
- The frame gap did not follow at 2M and 5M. With the GPU saturated by the solver, frames queue behind force chunks and the median gap rose (19 to 38 ms, 17 to 42 ms) while the tail at 5M grew (46 to 240 ms). Frames per second with the solver running: 50, 19 and 10 at 700k, 2M and 5M. The step is faster; the interactivity at large counts is not better, and slightly worse. Full stalls of the baseline's kind (a million-particle chunk) are gone only at 700k.
- Next, in order: (1) give frames priority over the solver: smaller force chunks at large counts, or skip a batch when a frame is late; (2) the force pass, now 80 % of a step: tighter leaf grouping or a lower per-step cost with `treeReuse` where the scene allows; (3) render cost under load, which is 4 to 5x its idle cost at 2M and 5M, likely contention with the solver on the same GPU.
