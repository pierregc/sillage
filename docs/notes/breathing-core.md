# A breathing core, and a bulge with no edge

A viewer, watching contemplation: the core of a galaxy bounces, like a balloon being inflated
and let down, and there are dark yellow stars very far out, sometimes almost at the ends of
the arms. Three separate faults, all in the initial conditions, all found by measuring rather
than by looking — the probes are a direct sum over the particles the sampler had just placed,
against the curve `DiskEquilibrium` hands the disk, and a five-hundred-megayear run tracking
the bulge's own quantiles.

**The bulge had no edge.** Drawn from a Hernquist cut at *twenty* scale radii, which holds
nine tenths of the profile: the ninetieth percentile stood at 8.2 scale radii and the last
star at 20. At the extents a galaxy is given — 0.06 to 0.18 disk scale lengths — that put a
tenth of the bulge more than a disk scale length out, which is the yellow speckle among the
arms, exactly as reported. Cut at six now, which keeps three quarters of the mass and brings
the ninetieth percentile to 4.3. The half-light radius of a Hernquist is 1.8 scale radii, so
that is the usual two to three of those, and the mass the tail carried is laid down inside
rather than lost.

**A flattened bulge with isotropic random motion rounds off, and that is the balloon.** Nothing
holds a flattening that rotation is not carrying, so it inflates until it is a sphere:
measured, the vertical spread went from 1.30 kpc to 2.77 over five hundred megayears, more
than doubling, and the half-mass radius grew a fifth. A real flattened bulge is flattened
because it rotates, and the tensor virial theorem for an oblate isotropic rotator says how
fast — streaming at sqrt(e / (1 - e)) times the dispersion for a flattening e. The support the
Jeans equation asked for is now **split** rather than added to: the random part cools by
exactly what the streaming takes up, or the bulge is simply hotter and expands instead. Same
run: 0.60 kpc to 0.67, flat after the first thirty megayears. `theBulgeKeepsItsShape` guards
it and fails at 1.22 with the streaming removed.

**And the disk was launched three per cent fast, so it rang.** This is the same fault as gap 3
below, one layer down. The curve was rebuilt from the components once — Freeman's disk term
instead of the analytic sphere — but it models the disk as *one* exponential, and the sampler
lays that mass down as three: the gas disk at 1.5 scale lengths, the thick disk at 1.4, the
thin stars at 1, each cut at five of its own and renormalised so the tail's mass sits inside.
Against a direct sum over the particles, the curve ran 1.023 to 1.039 everywhere between half
a scale length and three. Every star was therefore launched at the pericentre of the same
epicycle; they ran out together and fell back together, and the median disk radius went 8.30
to 8.88 to 7.62 kpc — fifteen per cent peak to trough, with a period near a hundred and forty
megayears, which at contemplation's five megayears a second is a breath every half minute.
Summed over the three populations, with the truncation renormalisation and the thick component
treated as the spheroid it is rather than as a sheet, the same comparison sits at 1.01.

Two things that comparison taught, worth keeping:

- **Cutting the bulge's tail makes the curve's own bulge term wrong.** A sphere holding all of
  its mass inside six scale radii pulls a third harder there than the profile it was cut from,
  and the inner curve went to 0.964 of the truth until the term was given the same truncation.
  Any change to how a component is sampled is a change to the curve it is balanced against.
- **The ring is not all of it, and the rest is the arms.** With the arms turned off the first
  excursion is 5.9 %; with them at full strength it is 11 to 13 % whatever the rotation curve
  does. The sampler imposes a strong m = 2 *density* wave and gives every star an axisymmetric
  circular orbit, so there is no wave in the velocity field for it to match, and the disk
  responds to its own initial conditions. Making that self-consistent is a real piece of work
  and is not done.
