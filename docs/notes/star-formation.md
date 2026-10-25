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
