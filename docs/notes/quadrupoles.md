# Quadrupoles, and why the orbit chose the angle

An accepted cell adds its quadrupole to its monopole (#37, #60), and the default opening angle
is 0.9 rather than 0.7 at the same force error: mean error against direct summation at a million
simulated particles, monopole at 0.7 then quadrupole at 0.9, 0.43 and 0.48 % on a merger at
t = 0, 0.58 and 0.42 on a disk at 400 Myr, 0.63 and 0.37 at the second passage, 0.52 and 0.30
at coalescence. Force pass 139 to 89 ms at two million visible and 362 to 230 at five; the whole
step 1.39x.

**Momentum drift stopped being the criterion, and that was a decision, not a measurement.**
Between two cells of similar shape the monopole's leading error is a difference that cancels;
the quadrupole's is the octupole and nothing cancels it. So drift no longer follows the force
error: at 0.9 it is two to seven times what it was at 0.7, and the first pass of #37 dropped the
quadrupole on exactly that (#56). Pierre chose the orbit instead, because it is what a video
shows. Separation every 25 Myr to 400 Myr against a run at 0.4: the quadrupole at 0.9 stays
1.4 to 4 times closer than the monopole at 0.7, on every seed from 12 000 to 200 000 visible.
`theQuadrupoleKeepsAMergersOrbit` guards that, and `liveHalosConserveMomentumFarBetterThanARigidOne`
is pinned to the monopole at 0.7, where the tree's own drift is a tenth of the halo leak it is
about.

**A single seed's knot count is not a measurement either.** `anEncounterBurstsAndAQuietDiskDoesNot`
failed at 0.9 on seed 1 (quiet excursion 1.59 against a 1.5 bar) while seeds 2 to 4 gave 1.15,
1.38 and 1.10, and the monopole at 0.7 already reached 1.45 on seed 3. It sums two seeds now.

Three details: the six moments live in their own buffer, so the node stays 32 bytes for every
node that is opened, and the kernel takes them through a function constant (`monopole` on
`--baseline` measures the old pass). A leaf's moments are summed in the centre of mass pass about
its first particle — summing x x^T raw and subtracting M c c cancels away in single precision far
from the origin — which costs 2.5 ms a build at two million visible and 9 at five, a quarter of a
pass of their own. With softening the trace does not drop out of the force, so all six are kept.
