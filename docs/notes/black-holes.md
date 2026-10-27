# A black hole outside the tree

A galaxy can meet a lone black hole (#93): `GalaxyKind.blackHole`, drawn by the
`black-hole-pass` archetype and by 4 % of the free scenes that have a companion. It is one
particle, `ParticleComponent.hole`, carrying the hole's whole mass, with no stars, disk or
halo of its own. Three things worth knowing before touching it.

**It pulls outside the tree.** A hole of a tenth of its host weighs about a hundred thousand
stars at 200 000 a galaxy. Summed through the tree it would be softened at the stars' length,
fold into every cell's centre of mass and quadrupole, and stretch the float node ranges by
five orders of magnitude. Instead the tree sees it with no mass, and two passes after the
force pass (`bhHolePull`, `bhHoleSettle`) add its pull on every particle directly, at its own
softening, and give it the exact reaction back, summed in a fixed order so a run repeats. The
pair forces stay equal and opposite, the hole's acceleration matches direct summation to a few
parts in a million, and the tree questions the ticket raised (a heavy particle in a cell, next
to one, and the node ranges) do not arise. Up to four holes a scene; there is one today.

**Its softening is its own.** `GalaxyConfig.blackHoleSoftening`: a quarter of a kiloparsec at
10^10 solar masses, growing as the cube root of the mass, which is also how
`Encounter.massRatio` stretches a companion, so placing the encounter keeps the rule. The
solver never lets it fall under the stars' softening. From 0.2 kpc for a hole of a hundredth
of its host to 0.65 for three tenths. Measured at three tenths of the host, 50 000 a galaxy,
live halo, no cooling, `--dt-scale 3.5`:

| case | hole softening | total energy | fastest star | the hole |
| --- | --- | --- | --- | --- |
| plunge at 0.5 kpc, 600 Myr | the stars' (0.37 kpc) | jumps +0.16 % at pericentre and stays | 6.5 (1350 km/s) | |
| | the rule (0.67 kpc) | within ±0.03 %, back after | 3.5 | |
| | 1.2 kpc | within ±0.03 %, drifts to -0.13 % | 3.5 | |
| bound capture, 900 Myr | the stars' (0.19 kpc) | climbs to +56 % | 13.5 (2800 km/s) | heated back out to 13 kpc |
| | the rule (0.65 kpc) | within ±0.05 % | 7.4 | sinks to 3 kpc |

At the stars' softening a passage flings stars out at twice what anything else reaches, and a
hole orbiting inside the disk pumps energy into it without end: its stars cross a softening
length several times in one step. At 200 000 a galaxy the stars' softening is half again, so it
would be worse. The fastest stars under the rule are the ones bound to the hole, at its own
escape speed. Above the rule nothing more is gained.

**The step needs nothing new.** The automatic step is still set by the disks: a hole is
softened at several times the stars' length, so it is never the fastest thing against its own
length. Total energy over the clip, live halos, cooling off (it removes energy on purpose),
measured against the same host alone:

| scene | ratio | `--dt-scale 1` | `--dt-scale 3.5` |
| --- | --- | --- | --- |
| plunge at 0.5 kpc, e 1.1 | host alone | 0.023 % | 0.022 % |
| | 0.01 | 0.029 % | 0.030 % |
| | 0.1 | 0.115 % | 0.115 % |
| | 0.3 | 0.116 % | 0.111 % |
| capture, bound, 900 Myr | host alone | 0.054 % | 0.118 % |
| | 0.03 | 0.097 % | 0.108 % |
| | 0.3 | 0.052 % | 0.053 % |

The worst excursion is the same at both steps, and the host alone wanders as far, so it is not
the step's: it is the tree's force error and the noise of the energy sum itself. Through the
plunge, sampled every 5 Myr, energy swings by up to 0.3 % and comes back. Force error against
direct summation with the hole inside the disk: 0.39 % mean over all particles at the plunge's
pericentre, 0.12 % within 2 kpc of the hole, where its exact pull dominates; 0.35 % and 0.09 %
for the capture. `--dt-scale 3.5` stays the exploration step.

**What it does.** A hole of three tenths on a bound orbit falls from 26 kpc to 3 kpc within
450 Myr and stays in the core carrying three thousand stars inside 2 kpc of it: dynamical
friction against the live halo, which is why a scene holding a hole keeps a live halo round its
host even where generated scenes otherwise take a rigid one (`finishGenerated`). A rigid halo
would take no reaction from a mass a tenth of its own. A tenth of the host from 66 kpc comes
back for its second passage 800 Myr after the first, so the capture variant draws at least a
twentieth, and swings out to 40 to 70 kpc before its first passage: a bound orbit has to be
falling in for as long as the clip waits for the passage (about 250 Myr after the 150 Myr
lead), or the placement opens it to parabolic. Drawn from 25 to 45 kpc, as the other bound
archetypes are, 28 of 39 captures were opened; from 40 to 70, none.

**At 200 000 a galaxy.** Six scenes of batch 20261027 explored as `explore-batch.sh` runs them (live
halo, `--settle 400 --dt-scale 3.5`, 3600 steps and the story after), first pericentre read off
`curves.csv` against the one asked for, and the contact sheet over each story in
[`docs/black-holes.jpg`](../black-holes.jpg):

| place | variant | ratio | e | distance | time | what follows |
| --- | --- | --- | --- | --- | --- | --- |
| 95 | slow in-plane | 0.17 | 1.05 | 7.1 to 6.4 kpc | 433 to 433 Myr | caught: back to 2.4 kpc at 758 Myr |
| 271 | fast polar | 0.21 | 1.41 | 4.4 to 3.8 | 455 to 456 | gone, disk torn |
| 163 | plunge | 0.26 | 1.13 | 2.0 to 2.2 | 359 to 360 | caught, 12 kpc at the end |
| 119 | capture | 0.07 | 0.79 | 5.3 to 5.0 | 266 to 262 | sinks: 1.2 kpc at 381 Myr, 0.8 at 638 |
| 51 | plunge | 0.03 | 1.16 | 0.8 to 0.5 | 415 to 416 | gone |
| 15 | fast polar | 0.01 | 1.32 | 2.8 to 2.4 | 324 to 324 | gone, barely a ripple |

Times within 4 Myr, distances within 13 %, but for the plunge asked at 0.8 kpc that passed at
0.5: the host's centre is its stars' and leans towards a hole going through it, and the
difference is under the hole's softening. Above a tenth of the host the disk is wrecked or the
hole caught, `interest.py` 0.83 to 0.99; at a hundredth to three hundredths it ripples a disk
that stays a disk, 0.41 and 0.55. The two extra passes are one sum over the particles each, beside
a tree walk; their cost was not measured, the GPU being shared at the time.

**Mass range.** A hundredth to three tenths of the host, log-uniform: 10^9 to 10^11 solar
masses against 10^11 to 10^12. Past about a tenth it is heavier than any black hole known, more
a massive intruder, and kept because it is where the disk answers most.

**Drawn.** Stars only by default: the hole emits nothing and shows by what it drags.
`holeShadow` in a look draws it as a dark dot of that radius in kpc, absorbing like dust that
lets nothing through, so it darkens what lies behind it and shows nothing against the empty
sky. No lensing. A take records the hole
among the visible particles, so a replay has it. Stars the hole carries off count as torn from
their host: `tidal_fraction` measures distance from the hosts only, and the hole has no disk to
be disrupted, so its `disruption_` column stays at zero and the scores read the host. A camera frames the hole only while it is within one to two of its host's reaches,
eased out between the two (`SceneConfig.framedCentres`): before that, a hole leaving on a
hyperbolic orbit dragged the auto camera three hundred kiloparsecs out with it.

**Batches.** `black-hole-pass` makes the round of archetypes eight long instead of seven, so
in a batch drawn before it, the archetype at a given place may now be another. A free scene's
hole is swapped in after the batch has chosen its scenes by signature, from a stream of the
scene's own, so every other free scene is the one it was. A hole is not a galaxy for the
particle count: `explore-batch.sh` and `ExploreProbe` give the host a galaxy's worth and the
hole its one.
