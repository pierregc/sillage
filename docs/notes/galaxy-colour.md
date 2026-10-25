# A galaxy that keeps its colour

A viewer asked for three things at once — less red, knots that light up rather than pop, and a
global colour that holds over a run — and the third turned out to be the only one with a
mechanism behind it.

**A sampled particle's age no longer advances.** It stands for tens of thousands of stars
already in steady state, not for a coeval group, so its colour has no business drifting; gas,
and anything the run itself forms, still ages. Ungated, the whole disk aged in lockstep, light
per unit mass fell as `age^-0.9`, and an isolated disk went sepia inside a gigayear while the
star formation the run does — 9 800 particles against 250 000, four per cent — could not
repaint it. Share of the disk gone frankly warm, over 1 Gyr: **0.19 % to 10.84 % before, 0.16 %
to 0.35 % after.**

**Three sweeps, not two, because two changes shipped together.** The HII change below and the
age freeze were both in the first comparison, and either could have been the whole effect. At
956 Myr: neither change 10.84 %, HII change alone 7.72 %, both 0.35 %. So the freeze is worth
22x and the HII rendering 1.4x, and neither number was guessable from the pair.

**A knot rises rather than arriving lit.** `alive` was a bare `exp(-age/150)`, so a region
appeared at its brightest in the frame its gas crossed the threshold — at thirty-seven
megayears of simulation a second that is a hard pop. It is `(1 - exp(-age/25)) * exp(-age/150)`
now, about fifty megayears to swell, a second and a half on screen. The product never reaches
one and tops out at 0.62, which is part of asking for less red rather than something to
normalise away; `ionisedStrength` takes another fifth off. Pink pixels at t = 0: 4.41 % to
0.90 %.

**No test guards any of this, and the attempts are worth recording so nobody repeats them.**
Three metrics were tried and all three passed with the fix taken back out. A mean over the
frame measures the sky. A mean over the galaxy measures the bright inner disk, which is old and
stable either way — what drifts is the dim, numerous outskirts. And counting warm pixels needs
the disk to have *spread* before it separates, so a render of frozen positions with the clock
wound forward moves half a per cent: the effect is not the clock alone, it is the clock over a
disk that has evolved. A stepping test at 40 000 particles then rendered a frame with no lit
pixel in its middle at all under the test bench's settings. The honest state is that the three
sweeps above are the measurement and nothing in the suite protects it.
