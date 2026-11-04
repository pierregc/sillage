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

**A fit is held to where it starts (#217).** The fit moves the pericentre it asks the backward
construction for while it holds the drawn eccentricity, and a hyperbolic orbit through a
pericentre q at eccentricity e carries an energy of (e - 1) M / 2q: asked for less, it gains
energy without limit. Passages the others' pull kept wide, out of the orbital plane where no
pericentre in it can bring them in, drove it to ask 5 pc and 0.005 pc. Place 12 of batch
20261030 (`--pair-share off`) started three galaxies 61 000 kpc out at 100 000 km/s and the
fourth 355 000 kpc out at 600 000 km/s, its preview black; place 1 brought its dwarf from
4 700 kpc at 8 200 km/s.

Every centre now starts within 1000 kpc of the centre of mass and 1500 km/s of its rest
(`Encounter.startDistanceLimit`, `startSpeedLimit`): a group's extent, and a rich cluster's
fastest galaxy, where pairs and groups meet at a few hundred km/s. Of 1 061 scenes as `explore`
places them (40 batches of 16 places without the pair share, 30 with it), 22 started beyond,
14 of them farther than 2 000 kpc and up to 584 000 kpc at 850 000 km/s: groups of three to
five, never a pair, which the construction places exactly. Left to the construction alone, one
orbit of the 1 061 started faster than 1 300 km/s and none farther than 913 kpc. A fit that
starts beyond is taken again holding the drawn orbit's energy instead: the speed at an asked
pericentre is then the one that energy gives, asking less only aims the pair more nearly head
on, and the refit tries no start beyond the limits and no pericentre under a hundredth of the
one drawn. Its passages land within a few times the distance asked: 5.5, 11.6 and 3.1 kpc for
the 6.2, 5.2 and 4.4 of place 12, 27.1, 2.7 and 3.2 kpc for the 28.3, 2.3 and 3.1 of place 1.
An orbit the draw itself makes too fast or too far is slowed, its excess over parabolic halved
up to three times and then taken away. None of the 22 needed it, the refit cost 77 s over the
1 061, and the other fourteen places of the batch place to the bit as they did.

**The dwarf's ring was the tree, not its speed.** A light galaxy far out on a diagonal from
where the mass is can take the root cell whole: the opening test compares the cell's width
with the distance to its centre of mass, not with the particle's place in it, and the root's
centre of mass sat with the group 4 700 kpc away while the cell was 4 070 kpc wide. Every one of
the dwarf's stars counted the whole scene, itself included, as a point at the group, felt no
pull of its own galaxy and flew off along its orbit: an expanding ring, its median radius
1.5 to 4.1 kpc in the first 20 Myr and 53 kpc by 300 Myr, measured in the whole scene. Alone,
at the same distance and speed, the dwarf keeps its radii; it does too with one far, light
particle stretching the root as wide. The cell shrank with the distance, so by the centres it
lasted until about 370 Myr, most of the way in, and came back on the way out after 820. Within
the start limits no scene of the review batch takes the root whole at the start, but a light
galaxy far out on a diagonal still could, at the start or on its way out after a fly-by, until
the walk opened every cell that holds the particle (#221, [a cell around the
particle](cells-around-the-particle.md)).
