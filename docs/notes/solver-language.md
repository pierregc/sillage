# Another language would not make a step faster

Asked on 2026-10-28: would moving the simulation out of Swift, to C++, Rust or Metal alone, make
it faster? No. Measured alone on the M4 Max (14 cores, 32-core GPU) at c9e2022, on scenes of the
2026-10-25 night.

## Swift only orchestrates

Every computation in a step is a Metal kernel, written in MSL (a C++ dialect) and compiled by
Apple's own compiler: star formation, drift, tree build, force pass, kick, cooling. Swift encodes
them and waits; between two passes it computes the galaxy centres and disk frames, while the GPU
builds the tree.

From the logs of the 2026-10-25 night, `solver.step` is 98.2 to 99.1 % of the frame loop of every
explore (35 scenes, four at once) and 99.2 to 99.5 % of every hires (four at 2M). Drawing and the
video take 0.2 to 1.7 %, the curves and the take the rest.

Inside a step, submitted as explore and hires submit it, scene-0018 at theta 0.6:

| visible (simulated) | step | GPU busy | idle a step | command buffers | process CPU |
| --- | ---: | ---: | ---: | ---: | ---: |
| 400k (1M) | 47.4 ms | 98.7 % | 0.6 ms | 3 | 0.07 cores |
| 2M (5M) | 252.3 ms | 99.4 % | 1.6 ms | 7 | 0.09 cores |
| 5M (12.5M) | 659.9 ms | 99.5 % | 3.7 ms | 15 | 0.07 cores |
| 10M (25M) | 1374 ms | 98.0 % | 28 ms | 27 | 0.06 cores |

GPU busy sums the GPU clock of every command buffer the solver waited on, through a counter added
for the measurement and not kept. Profiled, the force pass is 90 % of a step at 400k and 93 % at
2M; the tree build is 4 %.

A hires run instrumented the same way, 2M, 24 frames with video, curves and take: the solver is
98.5 % of the frame loop and the GPU is busy for 99.3 % of it; drawing and the video take 1.0 %,
the take and the curves 0.5 %. Sampled for 8 s, the main thread waits in `waitUntilCompleted`
97 % of the time, computes centres and disk frames 2.2 % (while the GPU builds the tree, so off
the critical path) and encodes 0.1 %. Sampling the initial conditions is Swift on one core, 0.5 s
at 400k and 13 s at 10M, under 0.2 % of any run.

So a perfect host, in any language, would win what the CPU holds the GPU back for: about 1.5 % on
a hires, and nothing on an explore batch, where scenes share the GPU and fill each other's gaps.
That idle is mostly command buffer round trips, about 0.2 ms each, which belong to the driver:
C++ through metal-cpp or Rust through objc2-metal call the same API and wait the same way. Taking
them out means a step that never waits (centres and disk frames on the GPU, one command buffer a
frame), which can be written in Swift, for 1 to 3 %.

## The CPU is ten times slower than the GPU at the force pass

The force kernel ported line for line to C and to Swift, run on all 14 cores over a sample of
slots, agrees with the GPU to 5e-6 and costs, scaled to a whole pass:

| force pass | 400k, 0.6 | 2M, 0.6 | 2M, 0.9 |
| --- | ---: | ---: | ---: |
| GPU, Metal | 46 ms | 243 ms | 86 ms |
| CPU, C (clang -O3) | 428 ms, 9.2x | 2482 ms, 10.2x | 855 ms, 9.9x |
| CPU, Swift (-O) | 698 ms, 15x | 3936 ms, 16x | 1373 ms, 16x |

C beats Swift by 1.6x on the CPU, which matters for nothing that runs today. No other language
reaches the GPU better: CUDA does not run on a Mac, and the other routes to an Apple GPU (Slang,
WGSL, SPIR-V) are translated to MSL or Metal IR and go through the same compiler.

## Where the time is: the opening angle

Explore and hires run at theta 0.6, the app at 0.9. 0.6 was `sillage-render`'s default before the
quadrupoles; #60 moved the app to 0.9 on 2026-10-21, and the scene files (#66, two days later)
kept 0.6 for generated scenes. Every scene of the 2026-10-25 night says `"openingAngle" : 0.6`,
and `hires` reads it back. With the quadrupole, that is a force error five times smaller than at
the angle the quadrupole was brought in for.

scene-0018 at 2M visible, mean force error against direct summation at t = 0:

| theta | step | speed | mean error | p99 error |
| --- | ---: | ---: | ---: | ---: |
| 0.6 | 252 ms | 1.00x | 0.07 % | 0.21 % |
| 0.7 | 173 ms | 1.46x | 0.13 % | 0.35 % |
| 0.8 | 126 ms | 2.00x | 0.21 % | 0.57 % |
| 0.9 | 100 ms | 2.53x | 0.37 % | 1.16 % |

From 0.6 to 0.9 a step is 2.48x and 2.60x faster at 400k on two scenes, 2.54x at 5M and 2.58x at
10M. The four 2M hires of that night (52 to 78 min) would take 21 to 31 min, a 10M hires about
3 h instead of 8, and a night of explore about 2.5 times the scenes. The error at 0.9 is the
app's, 0.3 to 0.5 % in [the quadrupole note](quadrupoles.md).

Switched to 0.9 the same day, after the #21 fidelity check: two scenes of the 2026-10-24
fidelity batch replayed at 200k a galaxy and 0.9, against their 1M-a-galaxy reference at 0.6,
land as close as the replays at 0.6 did. Centres rms 0.69 against 0.68 kpc and 1.70 against
1.76, pericentre within 0.8 Myr and 0.6 kpc, same tails and density maps, in 96 and 98 s against
265 and 255. The local library's scene files were moved to 0.9 with it.

## What is left in the force pass

The kernel sustains 30 to 32 G node evaluations a second at every size and angle
(`traversalCosts`). That it stays flat while the mix of cells and leaves changes says the walk is
bound by its own loop, memory latency and lanes of a SIMD group waiting on each other's leaves,
rather than by arithmetic: by a rough count it uses 5 to 15 % of the GPU's arithmetic peak. The
known way past that is a group walk that builds interaction lists in threadgroup memory (Bonsai,
Bédorf et al. 2012). Sharing a walk across a SIMD group gave 1.05x
([state note](state-and-known-limitations.md)), so 1.3 to 2x on the force pass is plausible and
unproven, and it would be MSL again.
