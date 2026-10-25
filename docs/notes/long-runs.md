# Long runs

Verified rather than assumed, because every part of it had a surprise in it.

**Memory holds.** A take is bounded by its budget and nothing doubles around it any more: the
buffer is reserved up front, written out of its own memory, and read back through the mapping.
1.7 GB captured now peaks at 1.72 GB, writes at +1 MB and reads at +4 MB.

**Nothing diverges.** A gigayear of a self-gravitating merger at 200 000 simulated particles
leaves no non-finite position and a sane mean radius throughout.

**The cost per step used to climb, and that was the real limit. It no longer does.** A merger
at 750 000 simulated particles went from 57 ms a step at 50 Myr to 257 at 450, and the interval
of simulated time bought by a minute of wall clock fell with it. Three faults, all in the
traversal, all now fixed — see "[Why a step no longer gets slower](step-cost-growth.md)". The same run is flat at
31 to 35 ms across the whole stretch, and 7.3x faster at the far end.

The running panel's Myr/s is measured, not predicted, and the setup screen's estimate is taken
at t = 0. Both were honest before and are simply steadier now.

**Beware of measuring under contention, and of your own leftovers.** A run launched alongside
the app crawled at a thirtieth of its speed and looked exactly like a solver regression. It was
not. Twice. The second time an orphaned probe from half an hour earlier was still on the GPU,
and worse, it held its own executable open: `swiftc -o` failed with "Text file busy" and the
stale binary ran on, so three rounds of "I reduced the particle count" changed nothing at all.

Before timing anything: kill the app, `pgrep -f scratchpad/` for leftovers, and check that the
compile actually succeeded rather than trusting that it did.
