# Why a disk keeps its arms

A disk of stars and nothing else can only heat. Every spiral it raises stirs it further, the
Toomre parameter climbs past what can be amplified, and the arms stop coming. Measured here
on an isolated self-gravitating disk: real structure at 300 Myr, a featureless spheroid by
1200. Real disks escape that because their gas radiates the motion away and forms new stars
on circular orbits faster than the spirals heat them.

`dissipationTime` puts that back: each step, disk material is pulled a little towards the
circular orbit it would be on, on a time constant in Myr. Three things make it work rather
than wreck the galaxy.

- **The target comes from the force field**, not a table. The solver has just computed the
  acceleration, and a circular orbit is what balances it, so `v = sqrt(|a_r| r)` is
  self-consistent with whatever mass is actually there.
- **It stops at the Toomre dispersion.** Cooling the whole way drops Q below one and the disk
  fragments into clumps, which is exactly what the first attempt did. The floor is the full
  three-dimensional equilibrium dispersion; flooring at the radial component alone still
  fragments, because the radial part then sits below what Toomre asks.
- **It only touches the disk.** Halo and bulge are excluded by component, and the weight fades
  out past four scale lengths and four scale heights. A tidal tail is material thrown clear on
  no circular orbit at all, and cooling it would quietly erase what an encounter is watched
  for.
