# State and known limitations

Both solvers work. Level 1 is tracers in rigid potentials, level 2 is self-gravitating
Barnes-Hut with live halos, and level 2 is the default. Galaxies merge, and the orbital decay
is measured in the README.

Standing gaps, in the order they matter:

1. **No gas.** There is a star formation rule now — see "Star formation, and why density alone
   gives no burst" — and it puts knots where the material is compressed, consumes the reservoir,
   and bursts at pericentre and coalescence. What is still missing is the gas itself: no inflow,
   so a merger's nucleus is never resupplied and the burst is the shock's alone; no pressure, so
   nothing shocks properly; and the dust distribution is still the sampler's. Adding SPH is a
   project of its own and would cost another order of magnitude in speed.
2. **Colour is not derived.** Stellar populations are a hand-made ramp rather than luminosities
   in real bands composited like telescope filters. This is the next lever for making the
   interior of a galaxy legible.
3. **Disk stability, now measured and mostly fixed.** An isolated self-gravitating disk used
   to spread its mean radius by 23 % over the first 40 Myr, identically at every time step
   from a quarter of the tuned one to eight times it: the initial conditions, not the
   integrator. The sampler took its rotation curve from the analytic potential the galaxy is
   written as, while laying the mass down as a flattened exponential disk, a bulge and a
   truncated halo, none of which pull like that sphere. The disk came out turning at 0.81 of
   what the real field asks. The curve is now built from the components themselves, Freeman's
   Bessel form included, and the halo's dispersion is solved against the same composite.
   Drift over 40 Myr: 23 % to 2 % with a live halo, 11 % to 0.3 % without. `aSelfGravitatingDiskHoldsItsRadius`
   guards it. What is still unmeasured is what happens over many orbits rather than half of one.

   Over many orbits it rings, and a second layer of the same fault is why — see "A breathing
   core, and a bulge with no edge". What remains after that is the disk answering the m = 2
   density wave the sampler paints into it with no matching velocity field, which is worth
   5.9 % of the first excursion with the arms off and 11 to 13 % with them on.

   The tuned step itself is roughly sixteen times more conservative than it needs to be. Up to
   16x the radial profile after 40 Myr stays within 0.3 % of a reference run at a quarter of
   it, 32x is within 1 %, 64x within 3 %, and 128x visibly wrong. A 100 Myr self-gravitating
   merger at 200 k particles renders indistinguishably at 16x, in 5.8 s against 92 s. Hence
   `timeStepScale`, which is that multiplier; the default stays 1 because a close encounter
   reaches speeds an isolated disk does not.

   That caution is now measured rather than assumed. A 300 k merger run *through* pericentre
   to 300 Myr, disk deciles against the tuned step: 0.66 % at 2x, 1.31 % at 4x, 0.93 % at 8x,
   1.45 % at 16x, 4.01 % at 32x. The figure is not monotonic below 16x, which is the useful
   part — between 1x and 16x it is measuring the encounter's own chaotic divergence, not
   integration error, and two neighbouring runs separate by about a percent whatever the step.
   32x leaves that band. So 8x is comfortable for a long run and 16x is defensible; the default
   is still 1 because that is the number every rendered comparison here was made at.

   Particle count costs more than it looks. The softening follows the mean interparticle
   spacing, so it falls as 1/sqrt(N), and the step follows the softening. Going from 300 k
   visible to 2 M costs about 4x per step *and* 2.4x more steps for the same simulated time.
4. **Force traversal is still where the time goes**, but it no longer grows with the run, and
   the two things this file used to name as the wins left are both measured and neither is one.

   **Sharing a traversal across a SIMD group buys 1.05x, not the several-fold this note used
   to promise.** The promise was written before the Morton ordering, and the ordering is what
   killed it: neighbours in a group are neighbours in space and walk nearly the same path.
   The traversal is a flat stack machine, one node an iteration, so a group stays active for
   as long as its slowest lane and the waste is exactly the lane imbalance — measured across a
   merger at 400 000 particles, from t = 0 to 480 Myr, the longest lane in a group runs 4 to
   6 % above the group's mean and never more. A cooperative traversal would recover that and
   nothing else: both schemes walk the union of the group's paths, so it does not reduce the
   node-steps executed at all. `traversalCosts` is the instrument, and it stays: one uint a
   particle against fifteen hundred node evaluations for the same particle.

   The split is flat with scale, which is what makes it worth quoting: at one million
   simulated particles a step is 66.7 ms, and at 3.75 million it is 264.2, both of them
   36 % tree build and 64 % force pass. The drift is 1 ms and never worth a thought.

   **Individual time steps are not the win they look like here, and the measurement is worth
   keeping so nobody starts it twice.** The prize would be a dense core taking a hundredth of
   the step while the outskirts take all of it — but the softening floors the accelerations by
   construction, since it follows the mean interparticle spacing precisely to stop two-body
   spikes, and `dt = eta sqrt(softening / |a|)` therefore cannot collapse. Measured across a
   merger at 200 000 particles, the whole population fits in five or six rungs and the bulk
   sits in the middle of them: the saving on the force pass runs 1.9x to 2.8x, never more,
   including through pericentre and coalescence. Against a pass that is 64 % of a step, that
   is 1.6x overall — for the deepest structural change the solver could take, a per-particle
   rung, an active list, and indirection through it in the one kernel everything depends on.
   A GPU tree build attacked the other 36 % and handed back every CPU core besides: 1.17x a
   step with quadrupoles, since #57. Beyond that, the
   force pass costs about fifteen hundred node evaluations a particle at theta 0.6, which is
   ordinary for a monopole tree. Quadrupole moments bought the wider angle (#37): 0.9 now,
   see "[Quadrupoles, and why the orbit chose the angle](quadrupoles.md)".

   The bulge costs 13 % of a step, all of it in traversal: 98.6 ms against 111.3 ms at 400 k
   visible particles. Concentrating a seventh of the stars into half a kiloparsec deepens the
   tree exactly where the lanes of a SIMD group have to walk it.
5. **Graininess in the outskirts** comes from the clumpiness of the initial conditions, not
   from sampling. It is deliberate, but it reads as noise now that the render is sharp.
6. **A merger remnant is as spheroidal as the encounter makes it, and no more.** Disks are now
   left heated rather than rebuilt, but nothing here models the gas that would later settle a
   new disk out of the remnant over a few gigayears, so a run that goes on long enough shows a
   remnant that only ever gets hotter. Same root as gap 1.
