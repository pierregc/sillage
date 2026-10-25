# A step was serial, and the overlap is not free

`submit` is `commit` then `waitUntilCompleted`, so a step ran the GPU while every core waited,
then the CPU while the GPU slept, then the GPU again. The three add up to the whole step to
within a tenth of a millisecond — 23.5 + 42.9 = 66.8 ms at a million simulated particles,
91.0 + 170.8 = 262.9 at 3.75 million. A third of every step had fourteen cores working and the
GPU idle.

The overlap left the solver with the CPU build (#57). What follows stays because it applies to
any tree built a step ahead, on whichever processor.

Nothing can overlap *inside* a step: the chain is acceleration, drift, tree, acceleration, and
every link is real. What can overlap is across one, by building the tree from this step's
positions for the next step to use. `overlapTree` does that — two sets of node and order
buffers, the build on its own queue, joined at the top of the next step. 66.8 ms to 46.0 and
262.9 to 196.1, so 1.45x and 1.34x. The GPU is then busy 93 % of a step and the CPU 47 %, and
the force pass itself slows by 7 % because both are pulling on the same unified memory.

**It is off by default, because the staleness it buys with is not free and the notes used to
say it was.** The claim here was that reusing a tree costs nothing at these step sizes, since a
particle crosses a fraction of a leaf cell in the interval. That is true of the radial profile,
which is what it was checked on, and false of small-scale structure. Star formation is a
density-threshold measure and therefore a clumping measure, and it says so plainly — knots
formed per window on an isolated disk:

    tree rebuilt every step     353  371  337  337  266  270
    tree reused for two          215  222  191  187  143  137

That is a serial run with no threading in it at all, so the cost belongs to the staleness and
not to the overlap. Forces computed on an out-of-date grouping smooth the field, the disk
clumps less, and forty per cent of the structure goes. Contemplation runs at `treeReuse` 5.

**One pass does need a tree that matches the positions exactly, and it is not the force pass.**
Star formation reads a velocity gradient across a single leaf — sixteen particles — and one
step of drift blurs it below the threshold a shock has to clear. On the stale tree it lost two
thirds of its rate and the whole merger burst with it, 213, 261, 536, 199, 456, 727 becoming
107, 84, 110, 68, 46, 42. It is encoded ahead of the drift now, in the same command buffer, so
it runs on the positions the live tree was built from. That costs nothing and is right whether
the overlap is on or off.

**Measured again once the build went parallel (#33), and it stays off.** The build is now 25 ms
of a 168 ms step at five million simulated particles and 60 of 435 at 12.5 million, so the
overlap is worth 1.15x and 1.14x, not 1.45x. What it costs, at the default time step against
the synchronous build, two seeds each: a merger's primary disk is twice as thick at the second
passage (1.26 and 0.99 kpc against 0.53 and 0.49) and makes 27 % more knots, because the
encounter runs ahead of itself; an isolated disk makes 10 % fewer and its core thins instead
of concentrating. Seed to seed, the same numbers move by 1 to 8 %. At `timeStepScale` 8 it is
ruinous — the disk loses five sixths of its core — while the synchronous merger at 8 keeps
the thickness it has at 1 to within 2 %. One step of drift moves the forces 0.13 to 0.29 % on
average, the size of the Barnes-Hut error itself, but always in the same direction, so it
accumulates.

It also halves the frame rate of a live run, 16 frames a second to 8 at five million: the
build is the gap a frame gets into the GPU through, and the overlap closes it. Nothing else
around a step is worth overlapping. The take and the hop back to the main actor cost 1 to 2 %
of a step, the smoothing refresh and the disk frame upload well under that, and rendering
competes for the same GPU rather than an idle one. The 13 % the build still costs is for a GPU
build (#38) to take, not for staleness — see "The tree on the GPU, and the gap the frames were
using".
