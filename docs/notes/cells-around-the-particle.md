# A cell around the particle (#221)

The walk takes a cell whole when its width subtends less than the opening angle from the
particle, `s² <= θ² (d² + ε²)`, with `d` the distance to the cell's centre of mass. Nothing
asked whether the particle was in the cell. Inside a cube the centre of mass can be up to √3
widths away, past the 1.11 widths θ 0.9 asks, so a particle in the far corner of a lopsided cell
took it as one point: its own neighbours, or its own galaxy, pulling from wherever the cell's
mass was. Only the leaf holding a massive particle was kept out (`holdsMe`), and a light tracer
(#187) had no guard at all. The softening lets more through: a cell under θε across passes the
test at any distance, from inside as well.

**The dwarf of #217.** Place 1 of batch 20261030 put a dwarf 4 700 kpc out on a diagonal from
its group. At t = 0 every one of its 36 877 particles, stars and halo, took the root (4 070 kpc
wide) as a point at the group, and their force against direct summation was 97 % wrong on
average: the group's pull and nothing of their own. Run in the whole scene as placed before
#220, at 400 000 visible, the median radius of its stars about their centre of mass:

| Myr | 0 | 21 | 52 | 104 | 208 | 298 |
| --- | --- | --- | --- | --- | --- | --- |
| before | 1.52 | 4.23 | 9.58 | 18.8 | 37.2 | 52.8 kpc |
| after | 1.52 | 1.54 | 1.50 | 1.38 | 1.23 | 1.13 |
| alone, same softening and step | 1.51 | 1.52 | 1.49 | 1.36 | 1.22 | 1.09 |

Before, all its particles took the root until about 100 Myr and the last of them at 224; the
other three galaxies' radii agree between the two runs to 1.5 %.

**A cell that holds the particle is now always opened.** Each node carries in `packed.w` its own
octant digit and where that digit sits in a Morton code (`BHNode.digit`), the stack carries down
with each range of siblings whether their parent holds the particle, and a node holds it when its
parent does and the particle's code has the node's digit there. A massive particle reads its code
from the sort, so the test is exact and, for a leaf, the old `holdsMe`; a tracer computes its code
in the tree's frame as its star formation does, and outside the root nothing holds it. No read is
added to a node, and a particle no cell held gets its force to the bit: 951 156 of the dwarf
scene's million at t = 0, and the whole cluster of
`aWalkThatNeverTookACellAroundAParticleIsUnchanged`. `opensHoldingCells: false` keeps the old
walk to measure against.

**Not the sphere the issue proposed.** Accepting a cell only from outside a sphere about its
centre of mass that holds it (the distance to the cell's centre plus 0.87 widths) was expected to
change only cells around the particle. About a lopsided centre of mass that sphere reaches up to a
width out of the cell, over the next cell, where the angle accepts at 1.1 to 1.7 widths. On the
dwarf scene at t = 0 it rejected a cell for 96 % of the particles (98 % with the true distance
instead of the softened one) and changed nearly every force, for a median error of 0.32 % against
0.34 %, and about 8 % more a step at the explore count; opening the cells that hold the
particle changed 4.9 % of them, the dwarf's 3.7 % among them.

## How often, and what it did

Counted with a throwaway build that ran the old walk and noted, for every particle, the cells it
took whole that held it, and every thousand steps compared both walks with direct summation on
the GPU for a sample of them. A cell counts as wide when it is wider than the softening; one under
0.9 softening lengths passes the angle from anywhere, inside or out.

**An ordinary explore batch**, seed 20261104, 16 scenes at 100 000 a galaxy over their whole
clips, counted every tenth step: no particle took the root, but every count found some in a
wide cell. Share of particle-steps with a held cell, any size and wide:

| inside a galaxy | disk | bulge | thick disk | dark halo |
| --- | --- | --- | --- | --- |
| held | 4.1 % | 23 % | 0.9 % | 2.0 % |
| wide | 0.55 % | 2.2 % | 0.17 % | 0.28 % |

Outside them (beyond one and a half disk edges: tails, bridges, the outer halo) 0.29 % of the
stars and 0.19 % of the dark matter, nearly all in wide cells. 3.2 % of every particle-step in
all, 0.42 % wide. What it did, over 109 samples: the particles in a wide cell, about 0.5 % at a
time, had a mean error of 0.67 % against 0.56 % opened, a median of 0.57 % against 0.29 %, a
99th percentile of 5.2 % against 1.2 %, and at worst 222 % against 10.5 %, late in mergers, in
debris. In a cell within the softening they lost nothing (0.72 % against 0.71 %): the
softened expansion converges there. The 60.6 million other forces were the same to the bit.

**A hires**, scene-0031 of 2026-10-30-b drawn at 8 M from 2 M massive, counted every 40 steps
over its first 230 Myr, the settle and the approach (twice the whole run was killed before the
passage, a victim of a GPU recovery another process caused): 4.0 % of the particle-steps were in a
held cell, 2.0 % wide, and nearly all of them tracers, 7.3 % of those inside a galaxy, mostly
in the leaf around them. For the massive particles the bulge again (12 %, 0.9 % wide), the disk
0.2 %, the halo and everything outside under 0.2 %. The tracers lost nothing (0.64 to 0.66 %
either way): a leaf is too light to matter from inside. The massive particles in a wide cell had
0.62 to 0.79 % against 0.25 % opened.

## Cost

A step of scene-0031 from t = 0, alone on the GPU, median of three runs of 60 steps after four:

| | main | branch | |
| --- | --- | --- | --- |
| explore count, 200 000 visible | 10.44 ms | 10.58 ms | +1.3 % |
| 8 M drawn from 2 M massive | 228.9 ms | 237.2 ms | +3.6 % |

The cells opened on top are a few hundredths of a per cent of the walk. The rest is the walk
carrying the code and the flag, mostly the tracers', which had no test at all: about 1.1 ns a
tracer step on the 20 the cost model falls back on. Reading the digit only along the particle's
own path changed nothing (237.3 ms), and two 32-bit words in place of the 64-bit code cost more
(240.6 ms). The cost model is left as it is: a night refits it on its own runs, and its fitted
tracer step, 22 ns, already sits farther from the fallback than this moves it. The sphere,
timed in the counting build, where both walks pay the same counting, cost 8 % more than the old
walk at the explore count.

## Disks

They do not move. Four small spirals of #216 and the knotty disk of #218 (2026-10-30-b place
11, its primary), each alone in the probe for 1 Gyr at the explore count, run by main and by
the branch from the same sampling and by main from a second one; late arms, inner a2 and late
lumpiness of `probe-report.py`:

| | main | branch | main, seed 2 |
| --- | --- | --- | --- |
| free-1, five arms | 0.174, 0.13, 0.15 | 0.183, 0.12, 0.15 | 0.150, 0.11, 0.15 |
| free-0 | 0.224, 0.17, 0.40 | 0.242, 0.17, 0.35 | 0.199, 0.19, 0.16 |
| free-12 | 0.276, 0.34, 0.30 | 0.211, 0.22, 0.26 | 0.203, 0.18, 0.16 |
| scene-15 g0 | 0.293, 0.18, 0.77 | 0.258, 0.25, 0.72 | 0.232, 0.17, 0.40 |
| place 11, knots | 0.301, 0.54, 0.74 | 0.313, 0.47, 0.69 | 0.407, 0.28, 1.10 |

The first excursion is the same with either walk to the printed digit (4.5, 6.6, 8.2, 8.9 and
7.1 %) and the knotty disk's lumpiness tracks to 475 Myr (0.408 and 0.395); later the two runs
part as two samplings do, the late arms by less than the second sampling differs. free-12 bars
late on main's run (0.34 from 770 Myr) and not on the branch's, as it did on one sampling of
three in #216. #218 has not landed: these are the numbers to hold its disks to.
