# Why a merged disk stays merged

Everything above is right for a galaxy left alone and wrong for one in a collision, and the
three faults it had were all invisible in an isolated run. What it was doing, found in a
three-galaxy take and measured out of the take itself: the steeply inclined disk heated from
0.24 kpc thick to 11.7 through the encounter and was **back to 1.04 four hundred megayears
later**, still within five degrees of the plane it was born in and eighty-three degrees from
the remnant it had supposedly joined. A cold thin disk sitting inside an elliptical, refusing
to mix. The primary did the same thing less visibly — 0.046 flattening to 0.152 and back to
0.042 — because its natal plane was already z = 0.

- **The plane cooled towards has to be measured, not configured.** `galaxy.orientation` is
  where the disk *started*, and pulling stars towards a circular orbit about it is a spring
  back to the natal plane, which is the one thing a collisionless system cannot do. The axis
  is now the mass-weighted angular momentum of the galaxy's own disk material about its own
  moving centre, taken on every tree rebuild, so it tumbles, precesses and warps with the disk.
  It carries the sense of rotation in its direction, so the separate spin sign is gone.
- **It has to stop while the galaxies are inside each other.** The cooling stands for gas
  sitting in a quiet cold layer and forming stars on circular orbits; during an encounter that
  gas is being shocked, driven inward and burned. The gate is the disk's radius over its tidal
  radius in the companion's field, `r_t = d (M / 3 M_companion)^(1/3)`, faded between 0.7 and
  1.4. Scale-free on purpose: a small satellite passing close must not switch a large disk's
  cooling off the way an equal-mass companion does. It comes back on if the two separate again
  without wrecking each other, which is what a fly-by is.
- **And it must not come back once the disk is gone.** A ratchet on the ordered-rotation
  fraction, |sum m l| / sum m |l| over the same material the cooling touches: never given back
  once earned. Without it a merged remnant keeps a little net spin, that reads as a disk, and
  the cooling starts rebuilding whichever galaxy it belongs to.

**The threshold for that ratchet cannot be picked for a non-rotating spheroid.** A merger
remnant inherits the pair's orbital angular momentum, so it settles at 0.60 to 0.72 and never
goes near zero; anything tuned for 0.2 simply never fires. The margin is elsewhere and it is
wide: an isolated spiral sits at 0.997 and stays within a thousandth of that for nine hundred
megayears, and a fly-by host dips only to 0.95 and recovers. Hence 0.75 to 0.92.

**The obvious scene does not catch any of this, and that cost a first round of tests.** On
`SceneConfig.merger` — equal masses, coplanar — the two disks coalesce so completely that the
cooling has nothing left to rebuild, and a test there passes with the fault fully in place.
The fault needs an encounter the smaller disk *survives* as an entity: an unequal pair, a third
the mass, steeply inclined. `aMergerLeavesTheDisksHeated` is that scene, and it watches the
primary rather than the companion, because "a galaxy of a third your mass plunged through you
and your disk is no thicker for it" is the cleanest statement of what was wrong. Ungated:
0.62 kpc thick before, 0.81 at worst, 0.69 at the end. Now 1.13 and 1.12.

Three hundred thousand particles a galaxy is not what any of this is measured on. Fifty
thousand answer it, and the whole pass costs 0.7 ms of an 82 ms tree rebuild at three million
simulated particles.

Replaying the same three-galaxy geometry through the fix, against the numbers at the top of
this section: the inclined disk goes 0.24 to 21.5 kpc thick and stays there, its plane wanders
sixty degrees off where it was born, and its half-mass radius grows to five times the
primary's. It is an envelope around the remnant rather than a disk inside it.
