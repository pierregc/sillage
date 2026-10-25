# Encounters placed from their pericentre

A scene's encounters are geometry (`Encounter`), and the starting positions are worked out
backwards from each pericentre (#13). Three things worth knowing before touching it.

**The centre model is what the solver does, not Kepler.** Each galaxy pulls with the mass it
holds inside the separation: its stars as a Plummer sphere of 1.3 disk scale lengths, its halo
as its own profile, cut and renormalised at `haloExtent` when the halo is live. With a rigid
halo a centre feels the other's whole field and gives no reaction, because that is what a halo
riding on its disk does; with a live one the pull is equal and opposite. The eccentricity is
taken against that potential at pericentre, so "bound" really is bound.

**A third galaxy has to be aimed at where its primary actually is.** Placing each secondary
relative to its primary's *starting* state put a group's later passages twice as far as asked,
and no correction of distance and time could fix it, because the primary had been thrown
somewhere else by the first passage and the error was in the aim. Each secondary is now set at
its pericentre beside the primary's position at that moment, the galaxies already placed run
forward to it, then stepped back through them, with the primary's recoil put on the secondary
so a pair stays exact. Levenberg-Marquardt on the asked-for distances and times then closes
the rest. Pairs land to the bit; three galaxies to a few per cent; four, whose first galaxy is
thrown about by three others, typically to five to twenty, and the generator orders a group by
mass so the heaviest is the one the others pass. A group of four costs up to two seconds to
place, a pair two milliseconds.

**Against the real thing, no calibration was needed.** Twelve generated scenes at 700 000
particles with live halos, `--settle 400 --dt-scale 6 --steps 3600`, first pericentre read off
`curves.csv` against the one asked for:

| scene | kind | e | distance | time |
| --- | --- | --- | --- | --- |
| 6 | disks | 1.15 | 28.9 to 29.5 kpc | 157.1 to 158.4 Myr |
| 6 g2 | disks | 0.95 | 11.5 to 11.8 | 157.1 to 159.2 |
| 7 | disks | 1.00 | 5.7 to 6.9 | 772.9 to 774.7 |
| 8 | disks | 1.21 | 15.7 to 15.4 | 555.3 to 558.5 |
| 11 | disks | 0.79 | 8.3 to 7.6 | 355.1 to 369.5 |
| 13 | disks | 0.93 | 10.9 to 9.7 | 340.1 to 345.8 |
| 14 | disks | 1.14 | 9.9 to 9.0 | 212.7 to 209.4 |
| 16 | disks | 1.00 | 6.7 to 6.7 | 511.3 to 511.7 |
| 1 g2 | companion | 1.42 | 2.9 to 2.8 | 338.9 to 339.3 |
| 3 g2 | companion | 1.78 | 3.3 to 3.7 | 391.6 to 390.8 |
| 5 g2 | companion | 1.27 | 8.1 to 8.1 | 502.5 to 503.2 |
| 12 | companion | 1.96 | 5.9 to 5.4 | 214.8 to 214.7 |

Time within 3.3 Myr in ten of twelve and 14.4 at worst, on the most bound orbit; distance
within 11 % but for one close pair of disks at 22 %, where the disks are already deformed and a
centre of mass is not a point. A Chandrasekhar drag was written and taken out again: the
residual is late, not early, and a drag only brings a passage earlier. Scenes 7 and 16 show
e 1.00 because their bound draws could not fall in for that long and were opened to parabolic.
