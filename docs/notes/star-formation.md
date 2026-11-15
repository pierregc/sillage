# Star formation, and why density alone gives no burst

The HII regions were decorative and the notes said so. They were placed by the sampler and
then lit by the *painted* spiral pattern — `alive = forming`, where `forming` came from the
texture — so the pink knots followed a picture rather than the physics: they sat wherever the
sampler had left them an orbit earlier, and none appeared anywhere new however violently the
galaxy was disturbed.

They now come from a rule. Gas turns into stars where the tree says it has been compressed,
and each knot announces itself in Halpha for a few million years, fades blue over a few
hundred, and settles into the disk.

**The tree already holds the density.** A leaf is a cell of known width holding known mass,
which is a density estimate for free — no neighbour search, no second tree, and the same
estimator everywhere so a nucleus and a tail are compared on the same footing. Only the visible
material is counted: dark matter is three particles in five and most of a leaf's weight, and
including it made the rate follow the halo rather than the disk.

**Density alone gives no starburst, and that is the whole reason the compression term exists.**
Star formation eats the densest gas first, so a merger driven by density arrives at pericentre
with its nucleus already spent. Measured on the way to finding this out: forty knots a megayear
at the start, nine at coalescence, monotonically falling, with nothing at pericentre at all.
Real mergers burst because tidal torques drive *fresh* gas inward and shock it, and there is no
inflow here — but the shock is visible in the flow itself, as the convergence of the velocity
field over a leaf's own particles.

**Rectifying a noisy estimator turns its noise into a rate.** `max(-div v, 0)` over sixteen
particles is not zero on average even where nothing is happening, and with no floor a quiescent
disk burned ninety-six per cent of its gas before its encounter arrived. The noise sits at order
unity — a disk in equilibrium has its dispersion over its scale height comparable to its own
free-fall rate — so only convergence well above that counts. Fifteen.

**The observed efficiency is the wrong number to use here, and using it was worth a control
run.** One to two per cent per free-fall time is right for the dense molecular phase on the
free-fall time *of a cloud*. What is available here is the mean density of a whole leaf over
gas that is mostly not in that phase. Applied directly it gave a depletion time of 950 Myr
against the two to three gigayears a real disk shows. Calibrated against what a quiescent disk
does instead: 1.2 Gyr.

**Always run the isolated disk as the control.** Every wrong calibration above looked fine on
the merger alone — there was always a bump somewhere. What exposed each of them was the same
scene with nothing to collide with, which burned its gas just as fast. The two runs together
are the measurement; either one alone is not.

Where it ended up, per forty-megayear window at sixty thousand particles:

    quiet   330  355  366  351  271  266      peak 1.11x the first window
    merger  213  261  544  210  437  739      peak 3.5x, at pericentre and coalescence

**One static array carries the whole history.** A formation time is written once, by the solver,
and never rewritten. So a take stores it once and replaying at any moment shows exactly the
knots that had formed by then — no per-frame colour, no per-frame component. That invariant is
what `gasFormsStarsExactlyOnce` guards, and it is why the take format went to version 2 rather
than growing a per-frame field. Version 1 is still read: those runs have no history, so their
sampled knots are given the spread of ages the sampler would give them now, which replays closer
than making the whole galaxy uniformly old.

**A test that passes on one realisation is not passing.** `liveHalosConserveMomentumFarBetterThanARigidOne`
asserted a ratio under 0.25 and got 0.32 the moment an unrelated change added a draw to the
sampler's random stream and moved every particle. Nothing was wrong: across five seeds the ratio
runs 0.05, 0.07, 0.17, 0.23, 0.32, because the rigid halo's leak depends on the details of the
encounter and swings fourfold. It sums three seeds now. Anything here whose threshold was fitted
to a single run deserves the same suspicion.

## The step does not change the rate (#306)

#225 measured a hires at twice the step forming 15 % fewer stars and the exploration a third
fewer, in every window and in quiet disks too, and step schedules (#312) waited on knowing which
of the rule's two readings moves with the step. Neither does. What moved was the count.

**The curves lost the first step of every frame.** A knot carries the time at the start of the step
that lit it, and `curves.csv` counted, at the end of each frame, the knots stamped after the frame's
start and up to its end. The first step's knots carry the frame's start itself: outside their own
frame, and inside the one before, which had been counted already. A frame of k steps showed its last
k - 1, so the curves held three quarters of the stars at the exploration's 3.5 (four steps a frame),
a half at 7 (two), and none at all at 14 (one step a frame, a column of zeros); in a hires seven
eighths at 3.5 (eight steps a frame) and three quarters at 7. The ratios are 0.667 and 0.857: the
third and the 15 % #225 read, 0.673 and 0.853. Read off the take of #225's 3.5 hires, each of its
923 frames counted exactly the knots of its last seven steps, and the first steps' 65 907 stars,
12.6 % of them, never showed. `probe-disk` always counted from the frame's start to just before its
end, which is why the isolated disk never showed it. The curves count that way now
(`MetalBarnesHutSolver.formed(since:before:)`), and `aFrameCountsEveryStarItsStepsLit` holds every
frame's count to the knots its own steps lit, at one step a frame and at three; the hires below at 7
and 14 count, frame by frame, exactly what their takes say each frame's steps lit. Nothing else
moves: the formation times a take keeps were always right, and so were the young stars on screen.

Counted in full, off the takes, which keep every knot's time, the hires of scene-0031 (8 M drawn
from 2 M massive) forms the same stars at 7 as at 3.5, and within a few percent at 14:

| Myr | stars a Myr at 3.5 | floor | 7 | 14 |
| --- | ---: | ---: | ---: | ---: |
| 0 to 157, settling | 414 | 0.997 | 0.994 | 0.997 |
| 157 to 305 | 725 | 1.003 | 0.995 | 0.974 |
| 305 to 420 | 1 202 | 0.995 | 1.005 | 1.037 |
| 420 to 510 | 1 097 | 0.996 | 0.973 | 1.062 |
| 510 to 700 | 564 | 1.004 | 0.990 | 1.002 |
| 700 to 887 | 387 | 1.005 | 1.006 | 0.995 |
| all, stars | 588 955 | 1.000 | 0.994 | 1.014 |

3.5 and its floor are #225's runs, which #307 ran again to the bit; the 7 run is #225's to the bit
for 345 frames, then a run of its own, most likely for the test suite it shared the GPU with from
about then, under which `theMassiveParticlesRepeatTheRunWithoutTracersToTheBit` fails the same way.
A window holds about 100 000 stars, so a count is good to 0.3 %. At 7 every window is within a
percent of 3.5 but the merger's, which the run completes 0.8 Myr later (511.2 against 510.4 Myr),
its burst coming later with it. At 14 the encounter itself moves, the first passage 6.72 kpc deep
against 6.13 and the merger 2.4 Myr earlier, and the bursts move with it; before it the two disks
form 2.6 % fewer stars, the one place where the step reaches the rate, through the compression term
(below). #225's exploration, counted in full, agrees as well: the median scene forms 1.01 times its
3.5 stars at 7 (10 to 90 %: 0.95 to 1.04), the floor's 1.01 (0.94 to 1.06).

### What the rule reads, leaf by leaf

`--sf-leaves <file>`, on any run or on `probe-disk`, writes after each frame what the next step's
pass will read on every leaf of the tree, summed: the gas not formed yet, what the density term and
the compression term are worth in stars a megayear, the free-fall rate of the dense leaves weighted
by their gas, and how that gas spreads over the convergence, `-div v` over the free-fall rate. It
reads the buffers on the CPU the way the kernel reads them and moves nothing. The stars formed in a
window come off the same file, from the gas the leaves still hold: a star that forms takes its gas
particle out for good, so the reservoir counts every one whatever the curves do.
`scripts/sf-leaves.py` lays runs side by side, window by window, and `theLeavesGiveTheRateThatForms`
holds the reading to the pass: the gas falls by exactly the stars formed, and the rate it gives is
the rate seen.

scene-0031 of 2026-10-30-b at the exploration's count (200 000 visible), from the first step, a
frame every 0.79 Myr; the floor is the 3.5 run with the second galaxy moved by 1 pc. Stars formed,
read off the reservoir, against what the curves read before #306:

| Myr | stars a Myr at 3.5 | floor | 7 | 14 | the curves read at 3.5, 7, 14 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 0 to 157 | 4.91 | 1.01 | 0.96 | 0.99 | 3.77, 2.62, 0 |
| 157 to 305 | 7.13 | 0.99 | 0.95 | 0.91 | 5.39, 3.45, 0 |
| 305 to 420 | 7.34 | 0.97 | 1.06 | 0.97 | 5.48, 3.91, 0 |
| 420 to 510 | 13.28 | 1.04 | 0.99 | 1.03 | 9.86, 6.19, 0 |
| 510 to 700 | 10.19 | 0.98 | 1.01 | 0.99 | 7.57, 5.21, 0 |
| 700 to 887 | 8.50 | 1.06 | 1.10 | 1.06 | 6.27, 4.83, 0 |

All of it, 7 391 stars at 3.5 and 7 470 for the floor, 7 518 at 7 and 7 382 at 14. A window holds
about a thousand, so one run's count is good to 3 %, and two runs that draw independently differ by
4 %: the floor draws the same numbers as its twin until the two have drifted apart (a draw is a hash
of the particle and of the step's number), and is the tighter for it early on. The rule's two terms,
as the leaves gave them at each frame, against 3.5:

| Myr | density term at 3.5 | 7 | 14 | compression term at 3.5 | 7 | 14 | free fall at 7, 14 | gas past 45 (past -45) at 3.5 | 7 | 14 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 to 157 | 4.66 | 1.00 | 1.00 | 0.39 | 1.01 | 1.01 | 1.00, 1.00 | 0.23 % (0.22) | 0.99 | 1.00 |
| 157 to 305 | 6.42 | 1.00 | 1.00 | 0.48 | 1.03 | 1.02 | 1.00, 1.00 | 0.22 % (0.21) | 1.00 | 1.02 |
| 305 to 420 | 4.58 | 1.02 | 1.00 | 2.73 | 1.00 | 1.01 | 1.01, 0.99 | 1.41 % (1.39) | 0.98 | 0.99 |
| 420 to 510 | 3.05 | 1.01 | 1.00 | 10.49 | 0.97 | 1.00 | 0.99, 0.99 | 6.88 % (6.87) | 0.97 | 0.99 |
| 510 to 700 | 1.87 | 1.00 | 1.01 | 8.37 | 1.00 | 1.00 | 0.97, 0.99 | 7.81 % (7.86) | 1.01 | 1.01 |
| 700 to 887 | 1.43 | 1.01 | 0.99 | 7.46 | 1.04 | 0.99 | 0.98, 0.99 | 8.59 % (8.56) | 1.03 | 1.00 |

The pericentre is at 305 Myr and the merger complete by 510. Both terms, the free-fall rate of the
dense leaves and the share of the gas past the floor stay within a few percent of the 3.5 run at 7
and at 14, through the burst and in the remnant, as close as the floor run's (within 3 %). The burst
keeps its height: through the merger the rate is 2.7 times the first window's at 3.5, 2.8 for the
floor, 2.8 at 7 and 14; in the hires the pericentre's window is 1.66 times the one before it at 3.5,
1.68 at 7 and 1.77 at 14, the merger's 1.51, 1.48 and 1.65, 14's moved with its orbit. Counted in
leaves rather than in gas, the leaves holding gas whose flow converges past fifteen free-fall rates,
the floor the section above names, are 6.8 % of them before the pericentre, 13.7 % up to the second
passage and 25 % through the merger and in the remnant at 3.5, and within 0.4 of a point of that at
7 and 14; past 45, the floor in use, 0.3 %, 2.1 % and 9 to 12 %, likewise.

The isolated disks of scene-0031, each alone for a gigayear at its share of the 200 000
(`probe-disk`), drawn from four seeds, the scene's and three more, and run from each at 3.5, 7 and
14. Stars formed in the gigayear, read off the reservoir:

| | stars at 3.5, the four draws | 7 over 3.5 | 14 over 3.5 | density term at 7, 14 over 3.5 |
| --- | ---: | ---: | ---: | ---: |
| first galaxy | 6 448, 6 264, 6 300, 6 207 | 0.97, 1.04, 1.03, 1.00 | 0.95, 1.03, 1.00, 0.95 | 0.99 to 1.04, 0.95 to 1.03 |
| second galaxy | 1 835, 1 708, 1 651, 1 701 | 0.95, 1.01, 1.00, 0.91 | 1.01, 1.00, 0.97, 0.95 | 0.97 to 1.00, 0.98 to 1.03 |

All the draws together, 7 forms 1.000 of 3.5's stars and 14 0.983, against a spread of 3 to 5 % from
one draw to the next, wider than the draws alone give: a disk's knots come and go at random, and
where one run forms more or fewer stars than its 3.5, its density term moves with it. The quiet disk
keeps its depletion time at every step: the first galaxy's gas would last 10 to 11 Gyr at the rate
of its first 200 Myr and 3.4 to 4.3 Gyr at that of its last, the second's 7 to 10 and 5 to 7. The
1.2 Gyr of the calibration above belonged to the disk of its time, at sixty thousand particles,
before the disks and the floor changed; nothing here touches it.

### Why the rate does not follow the step

The rule is a rate per megayear already: the chance a gas particle forms in a step is 1 - exp(-rate
x dt), the rate read off its leaf at that step, so summed over the steps of a megayear it gives the
rate whatever dt is, provided the leaves look the same at any step and the chance stays small. At
the exploration's count both hold up to 14: the leaves' density and convergence agree within the
floor. The chance saturates only in the leaves a remnant squeezes hardest: at the exploration's
count it takes 0.4 % off the merger's rate and 0.6 % off the remnant's at 3.5, 0.8 and 1.1 % at 7,
1.6 and 2.2 % at 14, and 0.1 % or less off a quiet disk's; in the hires 0.3 % before the encounter
and 1 to 1.5 % after it at 7, 0.6 % and 2 to 3 % at 14.

In the hires, 14 is where the step starts to reach the leaves: a disk star crosses two softening
lengths a step there, and the flow comes out a little smoother at the scale of a leaf. Before the
encounter the compression term reads 4 % lower at 14 than at 7, the share of the gas past 45 2 %
lower and the spread of the convergence 1 % narrower, the density term 0.3 % lower: 2.6 % fewer
stars. At 7 nothing of the kind shows, 0.5 % within the draws.

### The floor of 45, and what the compression term reads

The section above says fifteen; the code has had 45 since the floor was swept against the quiet disk
and the burst (`StarFormation.compressionFloor`). Measured on every leaf, the converging tail and
the diverging one are the same size everywhere: 0.29 % of the dense gas of the first galaxy alone
converges faster than 45 free-fall rates and 0.30 % diverges as fast; before scene-0031's pericentre
0.22 % and 0.21 %, through its merger 6.9 % and 6.9 %, in the remnant 7.8 % and 7.9 %; in the hires
2.6 % and 2.6 % before the encounter, 10.7 % and 10.7 % through the merger. What lifts the rate at
the pericentre and the coalescence is the estimator's noise growing with the motions of a disturbed
or merged disk, not a flow converging: the floor rectifies noise, as the section above feared for
fifteen, only less of it. That does not depend on the step, and the burst it gives is the one the
films show, so it stays. A floor set against the noise each step gives, which #306 was asked to
weigh, would take the burst away with the noise: the burst is that noise growing.

The noise does depend on the particle count. Its spread over the dense gas is 22 free-fall rates in
the hires before the encounter and 10 at the exploration's count, as the estimator's geometry says
it should be: it goes as one over the cube root of a leaf's baryon mass, and a hires particle weighs
a tenth of a preview's, so 2.15 times wider. The compression term is half of the hires' rate before
the encounter and a fourteenth of the preview's, and a hires forms 2.6 times as many stars a gas
particle as its preview. Previews and hires do form different amounts, as #306's ticket said, but
because of the particle count and not of the step.