# The tree on the GPU, and the gap the frames were using

Measured in #38, the solver's only build since #57. `GPUTreeBuilder` builds the same tree as
`BarnesHutTree` to the bit — order, cells, masses and quadrupole moments — so a run comes out
identical either way: 200 steps of a 500k merger, positions, velocities and formation times,
against main before the switch. `BarnesHutTree` stays as the reference the tests hold it to, and
for the setup preview's smoothing; playback builds the cells alone on the GPU since #39. It splits the octree
one level per dispatch rather than through a Karras radix tree: a cell is a run of sorted codes,
its octants are binary searches on that level's three bits, and a SIMD group reserves one block
of child slots with one atomic add, so siblings stay contiguous. Nodes are laid out by level
instead of depth first and the force pass does not notice, 362.1 against 362.6 ms at 5M visible.

The moments follow the CPU exactly: a leaf's are summed about its first particle, each branch
shifts its children's to its own centre of mass, children last to first, one dispatch a level
after the centres are normalised. Every product is added in a statement of its own, so nothing
is fused into a multiply-add the CPU never does; with `mathMode = .safe` that is enough for the
bits to agree.

The build goes from 26 ms on every core to 11 of GPU at 5M particles, the sort from 11 to 5, and
the whole step 1.17x at 2M and 5M visible with nothing drawn (#57: 120.8 to 103.1 ms and 314.3
to 267.1). More than the 1.09x to 1.11x #38 measured, because the quadrupole made the force pass
shorter and the build a larger share. The GPU sort's lead shrinks with size, 4.2x at 2M and 2.0x
at 10M: past the cache it is bound by memory traffic.

The node buffer starts at half the particle count, about twice what a merger needs (0.24 nodes a
particle at t = 0, 0.17 on the last frame of good01). A build that runs out sets a flag, every
pass after it stops, and the solver doubles the buffers and builds again before the force pass
reads anything.

**The frames were living in the build.** A frame queued behind the solver waits for the whole
command buffer, not for the next force piece encoded in it, so it reaches the GPU while the CPU
builds the tree. Take that gap away and the live frame rate halves, 13 to 15 a second down to 8 at
2M visible, exactly as the overlap did. Committing each `forceChunk` as its own command buffer lets
frames back in, and costs nothing with nothing drawn. As landed in #57, live at 2M visible:
23.4 to 24.3 frames a second against 19.8 to 22.2, p95 gap 66 to 71 ms against 98 to 106; at
5M, 16.2 to 16.4 against 12.5 to 15.6, p95 82 to 84 against 244 to 272. The median gap rises,
42 against 22 to 37 ms at 2M, because frames now land between pieces rather than in one long
hole, which is what p95 says.

**Measure with `plain` whenever frames matter.** Profiling submits every pass on its own, and
each submission is a gap a frame can use and the app never gives it.

**zsh does not split an unquoted variable.** `for extra in "quiet gputree"; do ... $extra`
passes one argument, `contains("gputree")` was false, and the run measured the CPU build under
the wrong label — half an hour of wrong conclusions here. Loop in a bash script, and read the
report's first line, which says what actually ran.
