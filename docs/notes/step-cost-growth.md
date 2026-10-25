# Why a step no longer gets slower

A merger used to cost 57 ms a step at 50 Myr and 257 at 450, on the same number of particles.
The node count *falls* over that stretch, which is what made it confusing: the tree is not
growing, it is getting coarser, and the traversal pays for that. Three separate faults, each
measured on its own.

- **A leaf was always summed particle by particle, however far away it was.** The opening
  criterion was tested for branches only, so a distant cell holding two thousand particles
  cost two thousand evaluations instead of one. Testing leaves the same way as branches: 2.6x
  on a concentrated cluster, and it is worth more the further a run has gone, because that is
  when leaves grow. Mean force error against direct summation moves from 0.106 % to 0.128 %.
- **The tree could not go deeper than ten levels**, because a 32-bit Morton code holds ten
  bits an axis, and a collision hits that ceiling on the first step. Meanwhile the root box
  grows — 179 to 382 kpc over 450 Myr as debris is thrown out — so the cells at the bottom
  cover more space every step while the disks concentrate into them. The largest leaf reached
  3363 particles. Codes are 64-bit now, twenty-one bits an axis, and the build costs 6 ms more
  and the force pass 70 ms less.
- **The traversal stack could overflow, and overflowing meant silently dropping cells** and
  their mass out of the sum. It pushed one entry per pending sibling, so up to seven a level:
  sixty-four slots were already not enough at ten levels, let alone twenty. It now pushes one
  entry per *range* of siblings — they are contiguous — which is one entry a level, bounded by
  the depth of the tree. Thirty-two slots, provably enough, and half the thread-private storage
  of the old sixty-four.

That last one supersedes an old note here warning that shrinking `int stack[64]` looks like a
4x speed-up and is worthless because the error explodes. It was right at the time. The stack is
small *and* correct now, because what bounds it changed.

Sixty-four bit codes then made the build the next thing to look at — 178 ms against 244 for the
force pass at five million particles, two thirds of it in the sort. The sort carried indices
and read the key back through them, so every count and every scatter was a random access into
forty megabytes. It now sorts the codes themselves with the index alongside: twelve bytes moved
in order beats four moved at random, the sorted codes fall out of the last pass instead of
needing a gather, and one array of the three is gone. 113 ms to 46, and the build back to
109 ms — near where it was before the codes grew.

Together: flat at 31 to 35 ms from 50 to 450 Myr, against 57 rising to 257. The whole run to
450 Myr takes 449 s against 930, and the instantaneous step at the far end is 7.3x faster —
an advantage that keeps widening, since the old curve was still accelerating.
