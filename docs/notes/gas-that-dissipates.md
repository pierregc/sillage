# Gas that dissipates

A study on paper, 2026-11-21. Nothing was run on a GPU, drawn or rented for it. Figures about
Sillage are quoted from the notes and the code that hold them, and from the check of the Mice's
flight made the same day, which no note holds yet. Figures about real galaxies and about other codes
were read in the papers listed at the end, where what was read only as an abstract, quoted through
another paper or cited from memory is marked. The arithmetic is in the text so that it can be
checked, and what is an estimate is called one.

Pierre's question: can gas be brought into Sillage to make it more real? What set it off is the
first gap of [State and known limitations](state-and-known-limitations.md), "No gas", seen on film
for the first time. On the Mice's flight (#358) the dust lanes go out between 520 and 620 Myr. And
620 Myr is about 170 Myr after the first passage, the moment at which the real Mice are seen, with a
dust lane right across NGC 4676A.

**In short.**

- **The gas is there already. What it cannot do is lose energy.** About a fifth of the visible
  particles are gas (1.8 M of 8 M at the defaults). They are drawn as dust and they turn into stars,
  but they move exactly as stars do: two streams of gas pass through each other. Real gas cannot.
  That is why the lanes come apart after an encounter, where real ones sharpen.
- **What real gas does in a collision is known, and the models that showed it carried no
  temperature.** It stays in a thin cold layer, it shocks where its streams cross, and what has
  shocked sinks to the centres within a couple of hundred Myr. Barnes's model of the Mice (2004) and
  the mergers of Mihos and Hernquist (1996) hold their gas at 10^4 K from end to end. The lane
  across NGC 4676A is what comes of it: 5.5 × 10^9 suns of molecular gas in a disk 1.8 kpc in radius
  and 250 pc thick (Yun and Hibbard 2001).
- **The drawing alone cannot bring the lanes back.** At 620 Myr half of the larger galaxy's gas lies
  more than 46 kpc from its centre, a veil over the same shapes as the stars. No thin layer is left
  to sharpen, and holding the painted lanes longer would draw a disk that is gone.
- **Two ways of making gas dissipate fit this code. One costs a few percent, the other a scene three
  times over.** Sticky gas, which loses its motion against the gas around it above the speed of
  sound: 2 to 3 % a step, no shorter step, one kernel of the shape star formation already has.
  Isothermal SPH, the literature's standard: about 20 % a step, and steps two to four times shorter
  wherever gas piles up, so a Gyr at 20 M goes from 2.2 hours to between 4 and 9 on the M4 Max and
  twice that on the next Mac, for two or three epics of work. All of these are estimates.
- **Recommended: a spike of sticky gas carried by the tree's own cells**, judged on criteria written
  here before it runs. SPH stays in reserve, on rented GPUs only, for the case where the spike fails
  on a point that pressure would fix. Meshless finite mass, and gas with cooling and feedback, are
  not for Sillage.
- **What none of this gives**: a new disk in a merger's remnant (that takes galaxies that are mostly
  gas), the inside of a shock, clouds and what their stars do to them.

## What stands in for gas today

Five things, of which only the last loses energy by itself.

1. **Gas particles.** The `dust` component is the gas: 14 to 38 % of a disk's particles
   (`dustFraction`, 0.26 by default, so 22 % of the visible ones behind a bulge of 15 %: 884,000 of
   a galaxy of 4 M, 1.8 M of a scene of 8 M, 1 to 2.6 M over the range the generator draws). The
   sampler lays them along the arms' inner edge, on a disk one and a half times as wide as the
   stars' (`DiskSampler.dustScaleMultiplier`), in a layer 0.45 of the disk's thickness (72 and 86 pc
   for the Mice). A gas particle weighs what a star does, or less in a large spiral, whose gas is 10
   to 20 % of the disk's mass (#218): 17,000 to 29,000 suns on the Mice take. It pulls and is pulled
   as every massive particle is, and nothing else acts on it.
2. **Disk cooling** (`bhCool` and `massiveDissipate`; [Why settled arms stay lumpy and
   wobbly](lumpy-arms.md), [Why a merged disk stays merged](merged-disk.md)). Stars, young stars and
   gas alike are drawn toward the circular orbit about their disk's measured axis, down to a floor
   of random motion, over no less than 1.8 turns. It keeps the arms alive, in the place of the gas a
   real disk cools through. It lets go as the tide rises (`tidalStress` between 0.7 and 1.4) and for
   good once a disk has lost its ordered rotation. So when gas would matter most nothing dissipates
   at all, and the rest of the time what is cooled toward is a disk's axis, which gas in a tail or
   in a remnant does not have.
3. **Star formation** (`massiveFormStars`; [Star formation, and why density alone gives no
   burst](star-formation.md)). A gas particle forms with a chance per free-fall time of its leaf's
   baryon density, raised where the leaf converges, and that note found the convergence to be mostly
   the estimator's noise. A formed particle stops being dust. Nothing flows in to replace it.
4. **Painted lanes and the dust web** (`laneDetail`, `DustWeb`; [When the painted arms
   fade](painted-arms-fade.md), [Inside a galaxy](inside-a-galaxy.md)). Texture laid over the gas
   particles in the disk's own frame, faded as the disk stops being one.
5. **The black hole's gas** ([A gas for the black hole close up that can be
   trusted](black-hole-gas.md), #334). The close-up's tracers leave their velocities on a grid in
   three dimensions, and each is pulled toward the mean flow of the others, only above a crossing
   speed, at 50 e-foldings an orbit. It is sticky gas, set against four papers on disrupted stars,
   and the one place where gas in Sillage loses energy. It lives in its own scene and its own
   kernels (`holeDepositTracer`, `holeStepTracer`), on a grid fitted to one hole.

**What the flight measured** (the check of frame 2516, 2026-11-21, on the flight's take; the flight
is at 520 Myr on frame 2340 and at 620 Myr on frame 2520). The renderer does the same thing at both
moments: at equal optical depth the dimming is the same. The painted lanes' fade (#210) is over by
490 Myr. The gas is not used up. It has spread:

| | 520 Myr | 620 Myr |
| --- | ---: | ---: |
| pixels the dust dims by more than a fifth, from frame 2516's camera | 20 % | 2 % |
| pixels with an optical depth over 0.3 | 1.9 % | 2.7 % |
| pixels with an optical depth over 2 | | ten times fewer |
| median distance of the larger galaxy's gas from its centre | 25 kpc | 46 kpc |
| gas that has not formed stars | 77 % | 73 % |

Along the flight itself the share of dimmed pixels goes 17, 16, 13, 11, 8, 4, 2 and 2 % at frames
2280, 2340, 2370, 2400, 2430, 2460, 2490 and 2516, with no step anywhere. A thin dark band has
become a thin veil, a little wider than before, lying where the stars lie. A veil mixed with the
stars draws no lane.

This settles the condition that [What would give Sillage its dimension](next-dimension.md) put on
its tenth recommendation, sticky gas "only if what is still missing then is where the gas is rather
than how it is drawn". It is where the gas is.

## What the real Mice show, and what their models needed

**The pair.** NGC 4676 is seen about 170 Myr after its first passage (Barnes 2004; Wild et al. 2014
take the same figure).

- NGC 4676A's molecular gas is "confined to a nearly edge-on disk" 1.8 kpc in radius and 250 pc
  thick at half maximum, 5.5 × 10^9 suns, 80 % of the pair's CO (Yun and Hibbard 2001). Spread face
  on that is 5.5 × 10^9 / (π × 1,800² pc²) = 540 suns a pc², some fifty times the gas of a quiet
  disk at the Sun's distance from its centre (about 10, from memory). Wild et al. find it "rich in
  dust, molecular and atomic gas", dimmed by up to about 7 magnitudes at 5,500 Å near the centre,
  "consistent with the dust lane visible in the HST images".
- NGC 4676B is "a strongly barred, inclined disk, with a lower gas mass fraction" (Wild et al.),
  with only weak CO along its bar (Yun and Hibbard).
- NGC 4676A "appears to be bulge free, with a strong bar" (Wild et al.).
- The star formation the passage induced "has not contributed significantly to the global star
  formation rate" (Wild et al.).

So the lane a photograph of the Mice shows is a compact, thin, heavy disk of gas near a nucleus.
Sillage's gas at the same moment has a median radius of 46 kpc.

**The models.** Barnes (2004) fits the Mice with a parabolic orbit and 24,576 gas particles a galaxy
of 2.6 × 10^5 suns each, an eighth of the disk's mass, softened at 446 pc. The gas has one fixed
sound speed, "mimicking a warm ISM" at about 10^4 K (17.4 km/s once his units are scaled to the
Mice), so the energy of every shock is lost at once. In his words such models capture "large-scale
shocks, nuclear inflows, and the formation of extended gas disks in merger remnants". By the second
passage "much of the gas originally populating these disks was driven into the nuclei or converted
into stars", while "gas returning from the tidal tails settled back into the disks". Mihos and
Hernquist (1996), with gas of 16,384 particles at a tenth of the disk's mass and 10^4 K, find the
same and say that "simulations with an isothermal equation of state differ little from those
employing more 'realistic' ones". In their disks without bulges the strongest inflow comes about 200
Myr after the first collision, as a bar grows, and "approximately half of all the gas has been
driven into the inner few hundred parsecs" before the galaxies merge. A dense bulge holds the inflow
back until the galaxies merge. Either way about three quarters of the gas has become stars by the
end. The inflows "are generally driven by gravitational torques from the host galaxy (rather than
the companion)": the gas, which shocks, and the stars, which do not, take slightly different shapes
under the same tide, and the stars' bar pulls the gas back along its orbit (the mechanism as Barnes
and Hernquist 1996 give it, from memory).

NGC 4676A fits that reading: no bulge, a strong bar, and its gas already in the middle 170 Myr on.

That mechanism is the whole point. Gas in Sillage takes the same shape as the stars, to the
particle, so nothing torques it and nothing sinks. What it needs is to stop where it meets itself.
It does not need a temperature that varies, a cooling curve or feedback: the reference models of
this very pair have none of them.

## What the gas has to do, in Sillage's numbers

Stay cold and thin, refuse to cross itself, and so sink where an encounter drives it.

**Speeds.** Gas at 10^4 K has a sound speed near 10 km/s, 0.048 in code units (the unit of velocity
is 207.4 km/s). Disks turn at 200 km/s and pass through each other at 300 to 600. Barnes reads Mach
10 to 30 in his shocks. At such speeds pressure moves nothing across a galaxy. It only holds the
layer up and sets the size of the smallest clump. What shapes the gas is the energy it loses where
it collides.

**Counts.** Take a galaxy of 4 M visible particles, 884,000 of them gas, on an exponential disk of
4.5 kpc (stars at 3 kpc, the gas one and a half times wider) in a layer 150 pc thick. One scale
length out there are 884,000 / (2π × 4.5²) × e^-1 = 2,560 a kpc², 17,000 a kpc³, so 39 pc between
gas particles, and 54 pc two scale lengths out. Forty neighbours, what an SPH kernel wants, lie
within 2.12 spacings: 83 to 115 pc, more than the layer's half thickness. Barnes was no better
placed ("only half of the disk particles have smoothing radii h_i less than the vertical scale
height") with 36 times fewer particles, each 9 to 15 times heavier. The previews, at 50,000 to
200,000 particles a galaxy, hold 11,000 to 44,000 of gas a galaxy: Barnes's count lies between. So a
hires take resolves the gas far better than the reference model of the Mice did, and a preview about
as well.

**A nucleus.** If dissipation brought to a nucleus what NGC 4676A's holds, 5.5 × 10^9 suns would be
190,000 to 320,000 gas particles in 2.5 kpc³, 20 to 24 pc apart: under the softening's 30 pc. There
the limit is gravity's resolution, not the count of gas.

**Thickness.** A layer with random motions σ under a surface density Σ of all matter is σ² / (π G Σ)
tall: at 10 km/s, 148 pc under 50 suns a pc², 99 under 75, 74 under 100 (G is 4.30 × 10^-3 pc
(km/s)² a sun). That is the thickness of real gas layers, and near the 72 to 86 pc the sampler gives
the Mice's.

**Clumps.** A gas disk fragments when Q = c κ / (π G Σ) falls under about one. Where a disk turns at
220 km/s at 8.4 kpc (κ = 37 km/s a kpc), Q is 2.7 at 10 suns a pc² of gas, 1.4 at 20, 0.9 at 30. The
Jeans length at 10 km/s is 1,470 pc at one atom a cm³, 470 at 10 and 150 at 100, always above the
softening, so gravity sees every clump the gas wants to make. Cold gas that dissipates fast will
knot wherever it is dense: it is what #218 met when the disk's cooling ran as fast as a turn (Gammie
2001 puts the line at a cooling time of three over the angular speed). In a real disk those knots
are clouds, and the stars they form blow them apart. Without that, the literature at this resolution
either stiffens the gas as it gets dense (Springel and Hernquist 2003: an effective pressure steep
enough can "stabilise gaseous disks against rapid break-up into clumps") or dissipates gently (Di
Matteo et al. 2008 chose collisions that make "a cool enough medium for thin spiral arms to form in
isolated disks but without making the disk unstable", and softer ones for gas rich disks "to limit
the formation of clump instabilities").

**Opacity.** With the 1.87 × 10^21 hydrogen atoms a cm² for a magnitude in V of Bohlin et al. (1978,
in Draine 2003) and helium at 1.36 of the mass, one sun a pc² of gas is 9.2 × 10^19 atoms a cm²,
0.049 magnitude, an optical depth of 0.045. A quiet disk at 10 suns a pc² is 0.45 face on, beside
the 0.76 at the centre that the lanes are already set against (De Geyter et al. 2014, in [Inside a
galaxy](inside-a-galaxy.md)). NGC 4676A's disk is 24 face on by the same rule: black, whatever the
angle.

## The options

| | what the gas gains | a step | steps | a Gyr at 20 M on the M4 Max | work |
| --- | --- | ---: | ---: | ---: | --- |
| the drawing alone | nothing after an encounter | 0 | the same | 2.2 h | days |
| today's cooling kept on for the gas | a disk about its old axis, right or wrong | 0 | the same | 2.2 h | days |
| **sticky gas on the tree's cells** | a thin layer, fronts where streams cross, inflow | + 2 to 3 % | the same | 2.3 h | a spike, then one epic |
| sticky gas between neighbours | the same, with momentum kept exactly | + 5 to 10 % | the same | 2.4 h | the same and a neighbour walk |
| isothermal SPH | the same and pressure: the literature's gas | + 5 to 40 % | × 1.5 to 3.5 | 4 to 9 h | two or three epics |
| meshless finite mass | SPH's, with cleaner rotation and mixing | twice SPH's share | as SPH | 7 to 11 h | more than SPH |
| cooling, feedback, several phases | clouds and winds | | | not at 29,000 suns a particle | a code of its own |

Every cost under the second row is an estimate, built on the measures of [milestone
7](../perf-milestone-7.md) and of [Whole scenes on rented GPUs](scenes-on-rented-gpus.md): a step of
0.45 s at 20 M, 17,400 steps a Gyr, 2.2 hours a Gyr on the M4 Max, half that speed on the next Mac,
an estimated 0.6 hour on a rented RTX 5090, where the CUDA engine has yet to run (#283).

### The drawing alone

The cheapest lead, raised when frame 2516 was checked: draw the dust darker where the gas is denser
than the stars. It has little to work on. The gas moves as the stars do, so after an encounter it is
nowhere much denser than they are: the pixels over an optical depth of 0.3 have grown from 1.9 to
2.7 %, and those over 2 are a tenth of what they were. A steeper law makes the veil darker. It does
not make a lane. Holding the painted lanes and the web past their fade would draw the lanes of a
disk that has become a tail and a bar.

One sheet is still worth its hour: frames 2340 to 2516 with the opacity raised with density, as the
baseline that any gas which moves must beat.

### Today's cooling, kept on for the gas

Lifting the tidal gate of `massiveDissipate` for gas alone would keep the gas of each galaxy near
circular orbits about the axis its disk had. That is the answer written in advance. It would pull a
tail's gas back out of the tail, give the gas of a merger two disks that no longer exist, and has
nothing to say where the two galaxies' gas meets. The cooling was tuned to keep arms (#218), not to
be a gas.

### Sticky gas on the tree's cells

**The rule.** Every cell of the tree keeps the mass and the momentum of the unformed gas it holds:
one `float4` a node, folded from the leaves to the root as the quadrupoles are. Each leaf looks up
to the smallest cell around it that holds enough gas particles, 16 to 32 (the spacing kernels
already fold a count of the drawn particles up the tree, for the tracers, #238). Each gas particle
of the leaf, of mass m and velocity v, then takes its velocity w against the mean of the others in
that cell, whose gas has mass M and momentum P, and loses what exceeds the sound speed c:

    w = v - (P - m v) / (M - m)
    if |w| > c:  v = v - w (1 - c / |w|) (1 - exp(-k dt))

It is the line the hole's kernel already runs on its grid (`holeStepTracer`), with the sound speed
where the hole has its crossing speed. Two numbers: c, 10 km/s, and the rate k, tens of e-foldings a
turn. The hole's spike found that 2 e-foldings an orbit let streams through each other and that from
20 up a disk forms. The energy each particle loses is known as it is lost.

**Why the tree and not a grid.** The hole's grid fits one object of known size. A collision is 300
kpc across with lanes 100 pc thick. The tree's cells follow the density, exist on both engines, and
are built every step. A cube that holds 16 to 32 gas particles is 2.5 to 3.2 spacings wide, and the
tree's cells go by factors of two, so the cell is 100 to 350 pc in the disk above, the reach of an
SPH kernel there (2.12 spacings of radius, 170 to 230 pc across).

**What it gives.** Above c, two streams that meet at 50 to 600 km/s stop against each other in a
fraction of a turn: a shock, as wide as a cell. Below c nothing happens, so the gas keeps random
motions of up to c, the stand-in for pressure. The dissipated energy can feed the star formation
rule and the drawing.

**What it costs.** The pass has the shape of `massiveFormStars`: one thread a leaf, a loop over its
particles, a read of a node. That pass is 6.49 ms of a step of 264.5 ms, 2.5 %. The fold is one more
`float4` in a pass that exists. So 2 to 3 % a step, an estimate. Nothing limits the step: the rule
is a decay, stable at any dt, and it does not try to resolve what happens inside a front. On the GPU
it adds 16 bytes a node, 80 to 160 MB beside 2.9 GB.

**What it cannot do, by construction.**

- **It is a ceiling on random motion, not a floor.** The hole's gas settled at 0.02 of its radius
  where its crossing speed alone would hold 0.1, since "nothing keeps it hot" (the hole's gas note).
  A galaxy's gas is stirred by the arms and by the grain of the particles around it, which may hold
  it near c, or may not. Too thin a layer is a layer that knots.
- **It is a viscosity where the shear is strong.** A particle at the edge of a cell 200 pc wide
  moves against the cell's mean at 100 pc × V / R: 2.75 km/s at 8 kpc for 220 km/s, 11 at 2 kpc, 22
  at 1 kpc. Outside about 2 kpc the threshold hides the shear. Inside, the rule eats it, and the gas
  drains inward at a rate the method sets. Bournaud and Combes (2002) say it of their own schemes,
  which "suppress local vortices" and do not keep angular momentum exactly, and find their results
  unchanged when they make them keep it. The levers are the threshold, the cell, and acting only
  where the cell's gas converges, which the star formation pass already measures.
- **It does not push.** Gas squeezed in a front stays squeezed until gravity or shear undoes it.
  There is no pressure gradient, so nothing expands and no wave travels.
- **Momentum is kept on average only.** Each particle is pulled toward the others' mean, and with a
  threshold the pulls do not cancel exactly. The error has no preferred direction.
- **The cell follows the count.** At 200,000 particles a galaxy the cell is 300 to 900 pc, where a
  galaxy of 4 M has 100 to 350. A preview and its hires take must tell the same story.
- **Cold gas knots**, as above.

**Sticky gas between neighbours** is the reserve of the same family, and the classical one: gas
particles that collide in pairs and keep a fraction of their relative velocity, 0.65 along and
across in Bournaud and Combes (after Schwarz 1981), 0.7 and 0.5 on a grid of 330 pc in Di Matteo et
al. Pairs keep momentum exactly, and angular momentum when the velocity across is left alone. It
needs what Sillage does not have, a walk of the tree that returns a particle's neighbours, at an
estimated 5 to 10 % a step. That walk is the first half of SPH.

One comparison speaks for the whole family. Di Matteo et al. (2008) ran the same survey of
encounters with a Tree-SPH code and with a sticky code on a grid, "extensively compared for the
first time", and found their conclusions on starbursts "robust, independent from the numerical
techniques and star formation models": strong bursts, over five times the quiet rate, in about 15 %
of encounters with either.

### Isothermal SPH

The literature's gas for these scenes: Barnes, Mihos and Hernquist, GADGET. Each gas particle finds
its 40 or so neighbours, takes a density from them, and feels the gradient of a pressure c² ρ and an
artificial viscosity that turns converging motion into lost energy. Bédorf and Portegies Zwart
(2020) added exactly this to Bonsai, the GPU tree code other notes here already lean on: the
neighbours come from the tree, the density walk runs three times a step and the force walk once, in
single precision, with one step for all particles.

**A step.** Sillage has no neighbour walk, so this is an estimate. Gravity's walk costs 17.6 ns a
particle and is 83 % of a step. Four neighbour walks a gas particle, three for the density and one
for the force, each between a quarter of a gravity walk and one and a half, come to between one and
six. Gas is 8.8 % of the 20 M, so each gravity walk's worth adds 7 % to a step: + 5 to 40 %, + 20 %
in the middle.

**The steps.** This is where SPH costs. A step may not exceed the time a signal takes to cross a
kernel: dt = C h / (2c + 3w) for gas closing at w, GADGET's rule, here with C = 0.15 on the kernel's
radius h.

| where | kernel radius | approach | step allowed | today's 0.0575 Myr is |
| --- | ---: | ---: | ---: | --- |
| quiet disk | 85 pc | 7 km/s | 0.30 Myr | 5 times shorter than needed |
| front along an arm | 80 pc | 50 km/s | 0.069 Myr | enough |
| nuclear disk, the kernel held at the softening | 30 pc | 60 km/s | 0.022 Myr | 2.6 times too long |
| disks passing through each other | 50 to 30 pc | 300 to 600 km/s | 0.008 to 0.0024 Myr | 7 to 24 times too long |

Barnes's smallest step was 1/32768 of his time unit, 0.006 Myr, against 0.38 Myr for his stars: 64
times shorter, given only to the particles that needed it. Sillage has one step for every particle,
and its walk, its tree, its checkpoints and its tracers count on it. With one step following the
gas, a Gyr of a merger is about 75 Myr of crossings at 0.005 Myr (15,000 steps), 400 Myr with gas in
the nuclei at 0.022 (18,200) and 525 Myr at today's step (9,100): 42,300 steps against 17,400, ×
2.4. With 20 % more a step, **a scene costs about three times as much, between two and four**: 4 to
9 hours a Gyr on the M4 Max, 9 to 18 on the next Mac, an estimated 1.2 to 2.4 on a rented 5090, $0.3
to $1.5. For the same hours it is a scene of 7 M instead of 20 M. Barnes noted that his slowest run
was the one without star formation, "since its gas attained the highest densities".

**What it adds over sticky gas.** Pressure: a floor under the layer, gas that pushes back and
expands, waves. Momentum and angular momentum kept pair by pair. A density of the gas's own for the
star formation rule. A method every referee knows.

**What it brings with it.** Its own viscosity, which also eats the shear of a cold disk unless a
switch turns it off away from shocks (Cullen and Dehnen 2010). Mixing and instabilities at contacts
done poorly (Agertz et al. 2007), which a film of colliding disks would not show. A smoothing length
for every gas particle, a neighbour walk and a step that changes, all twice, on Metal and on CUDA,
with fixtures. Tests of its own before any galaxy: a shock tube, a collapse, a disk that must stay a
disk. Two or three epics.

### Meshless finite mass

GIZMO's method (Hopkins 2015) solves a Riemann problem between each pair of neighbours in place of
an artificial viscosity. Its abstract claims hundreds of orbits for a gas disk where SPH breaks down
in a few. It is about twice SPH's work a step (an estimate), so three to five times a scene, with
gradients and limiters to keep on two engines. A Sillage film is five turns at the Sun's distance.
What it would improve is not what the films lack.

### Cooling, feedback and several phases

Clouds, winds and bursts born of fragmentation need parsecs, a cooling curve below 10^3 K and
recipes for what stars give back: Teyssier et al. (2010) at 12 pc and 4 × 10^4 suns, Hopkins et al.
(2013) at about a parsec. Sillage's particle and softening are not far from Teyssier's. But the
recipes are the work of whole groups, their free numbers are tuned against surveys, plain heating of
the gas "is ineffective at regulating star formation" (Cox et al. 2006), and the steps fall to
thousands of years. Not for a side project, and the Mice do not ask for it.

## Star formation

Whatever makes the gas dissipate changes what the rule sees, in three ways.

- **Density rises where gas piles up**, and the rule goes as density to the 1.5. It has to be set
  again on a quiet disk, so that a disk left alone still forms what it formed.
- **The compression term can read something real.** Barnes's point in 2004 is that a rule on density
  alone forms its stars late and in the nuclei, and that a rule on the energy lost in shocks forms
  them earlier and along the bridge and the tails, as the Mice do: 28 % of the new stars in the
  tidal features against 13 %. His rule is a chance per step proportional to the heating by shocks.
  Sillage's compression term reaches for the same thing and reads noise. Sticky gas knows the energy
  each particle has just lost, and SPH's viscosity knows it too.
- **The nucleus is fed.** Gap 1 says the burst is "the shock's alone", the nucleus never resupplied.
  Inflow is that supply. Mihos and Hernquist see about three quarters of the gas turned into stars
  by the end of a merger.

Two guards. The real Mice show "no substantial increase in global star formation rates" since their
first passage (Wild et al. 2014), so a burst there must stay modest. And strong bursts are rare
whatever the method (Di Matteo et al. 2008).

## The drawing, once the gas moves

The dust stays what it is, the gas that has not formed stars, and gains nothing new to store.

- **Opacity can be anchored**: 0.045 of optical depth for a sun a pc² of gas, checked against the
  lanes' present setting on a quiet disk.
- **Nuclei go black.** A disk like NGC 4676A's is 24 face on. That is true of the real one, whose
  lane is seven magnitudes deep, but only as a thin band across a bulge that stands above it. If the
  gas does not come out thin, the drawing will show a blot. It is a criterion below.
- **The painted lanes and the web could follow the gas** instead of the memory of a disk (`intact`):
  where the gas is thin and dense there is a lane, wherever that is. Later, and only if the layer
  holds.
- **Fronts could glow.** The energy lost a step is the place real galaxies light up in Hα. Optional.

## Checkpoints, takes and the two engines

**Sticky gas on cells** stores nothing. The cells' gas is made again each step from positions and
velocities, as the quadrupoles are, so a checkpoint and a take keep their sizes and their formats
([Checkpoints](checkpoints.md)). A scene asks for it by an option, absent in every scene that
exists, so those replay to the bit and a checkpoint's identity still holds. One thread writes each
leaf's particles and the fold goes level by level, so a run repeats itself without the fixed-point
sums the hole's grid needed. It is one case more in `BarnesHutPass`, which the CUDA engine cannot
build without handling, one line in `cuda/kernels.txt`, one fixture on the CPU target. The CUDA
engine has not yet run on a GPU (#283): better that this kernel lands after that first run than
widens it.

**Tracers** carry gas too. A tracer's gas would need the same pull, from the cell's flow written
into its slot as the chances of forming already are (`bhWriteChances`). Only where a scene uses
tracers.

**SPH** adds a smoothing length to every gas particle in a checkpoint, or the certainty that it is
found again identically, a step that varies through the run, which `SolverState` already carries,
and two or three kernels on each engine.

## Recommendation and order

1. **A baseline sheet** (an hour or two, optional): frames 2340 to 2516 with the opacity raised with
   density. What the drawing alone can do, to hold the rest against.
2. **A spike: sticky gas on the tree's cells**, on Metal only (its kernel listed as pending in
   `cuda/kernels.txt`), behind an option, with the rule above and nothing else changed. It answers
   whether the idea deserves an epic, on these measures:
   - **A quiet disk, 1 Gyr, with the [calm-disk probe](calm-disk-probe.md).** The gas layer stays
     between 50 and 200 pc. The gas's half-mass radius and its mass inside 1 kpc move by less than a
     tenth, so the viscosity is not draining it. Under 1 % of the gas in knots. The arms keep their
     contrast. Nothing lines up with the tree's axes.
   - **The Mice, at a preview's count and at 2 M.** At 170 Myr after the first passage the gas
     within 2 kpc of each nucleus has grown, the pixels over an optical depth of 2 at frame 2516's
     camera are at least what they were at 520 Myr, and the tails are as long as without it.
   - **The two numbers do not rule.** The same picture with the rate four times up and down and with
     c from 5 to 20 km/s. Bournaud and Combes found their rate had "no major influence"; if this one
     does, the method is drawing, not modelling.
   - **The count does not rule.** The gas's half-mass radius follows the same curve at 200,000 a
     galaxy and at 2 M, within 15 %.
   - **The cost** stays under 5 % of a step.
3. **If it holds, an epic**: the cells' gas and the kernel on both engines with their fixture,
   behind the scene option; the gas left out of `massiveDissipate` when the option is on; the star
   formation rule set again on the quiet disk and its compression term read from the energy lost;
   the opacity anchored and the nucleus kept from a blot; the tracers' gas; the generator's choice
   of when to turn it on; the Mice as a named scene on Barnes's orbit, held against the real pair
   with the measured match of epic #318; and gap 1 rewritten.
4. **If it fails**, how it fails names the next step. Drained by viscosity, or momentum going
   astray: sticky gas between neighbours, which needs the neighbour walk. A layer that will not stay
   up, or gas that knots for want of a push: that is pressure, so isothermal SPH on the same walk,
   on rented GPUs only, and a decision of its own, since it triples the cost of every scene that
   uses it. Nothing built on the way is thrown out: the option, the star formation coupling, the
   drawing and these measures serve all three.

Not recommended at all: lifting the cooling's gate for the gas, meshless finite mass, cooling with
feedback, and steps of its own for each particle, which would undo what the walk, the checkpoints
and the tracers rest on.

## What this note does not settle

- **Whether frame 2516 gets its lane back.** The mechanism is the literature's. That this rule, on
  these cells, at these counts, produces it is what the spike is for.
- **Whether a cell's mean is a good enough neighbourhood.** No paper read here runs sticky gas on a
  tree's cells. The nearest are the grid of Bournaud and Combes, far gentler (a decay over 5 to 10
  Gyr), the collisions on a grid of Di Matteo et al., and Sillage's own hole.
- **Every cost of SPH and of the neighbour walk.** No such walk exists here to measure, and
  Bonsai-SPH's paper gives ratios against other codes, not seconds a step.
- **The rented GPU's hours**, until #283 has run.
- **Remnants.** Gas at 10 to 20 % of a disk does not rebuild a disk after a merger: that takes
  galaxies that are mostly gas (Springel and Hernquist 2005; Robertson et al. 2006). Gap 6 stays,
  with a small gas disk in the middle at best.
- **How much gas each archetype should carry** once the gas matters to the motion and not only to
  the picture.

## Sources

Read in their text for this note:

- Barnes 2004, MNRAS 350, 798 (astro-ph/0402248): the Mice, isothermal SPH, the shock-induced rule,
  the counts, the steps, the orbit.
- Mihos and Hernquist 1996, ApJ 464, 641 (astro-ph/9512099): inflows, bulges, the isothermal
  equation of state.
- Yun and Hibbard 2001, ApJ 550, 104 (astro-ph/9903463): the molecular gas of NGC 4676.
- Wild et al. 2014, A&A 567, A132 (1405.7814): the Mice in CALIFA, the attenuation, the star
  formation.
- Bournaud and Combes 2002 (astro-ph/0206273): a pull toward the mean velocity of a grid's cell,
  sticky particles in three dimensions, what they do to angular momentum.
- Di Matteo et al. 2008 (0809.2592): Tree-SPH against sticky particles on a grid, on the same
  encounters.
- Bédorf and Portegies Zwart 2020 (1909.07439): Bonsai-SPH.
- Springel 2005, MNRAS 364, 1105 (astro-ph/0505010): GADGET-2's time step rule and neighbour search.
- Springel and Hernquist 2003, MNRAS 339, 289 (astro-ph/0206393): the effective equation of state.
- Cox et al. 2006, MNRAS 373, 1013 (astro-ph/0503201): feedback in mergers.
- Teyssier, Chapon and Bournaud 2010 (1006.4757): what a burst by fragmentation needs.
- Draine 2003, ARA&A 41, 241 (astro-ph/0304489): gas for a magnitude of extinction.

Abstracts only:

- Hopkins 2015, MNRAS 450, 53 (1409.7395), GIZMO; Hopkins et al. 2013, MNRAS 430, 1901 (1206.0011).
- Agertz et al. 2007, MNRAS 380, 963 (astro-ph/0610051); Cullen and Dehnen 2010, MNRAS 408, 669
  (1006.1524).
- Springel and Hernquist 2005, ApJ 622, L9 (astro-ph/0411379); Robertson et al. 2006, ApJ 645, 986
  (astro-ph/0503369).

Quoted through the papers above, not read: Schwarz 1981 for sticky particles, Jungwiert and Palouš
1996 for their 0.65, Barnes and Hernquist 1996 and Barnes 2002 for what isothermal gas captures.

From the notes of this repository, not read again: Gammie 2001 ([lumpy arms](lumpy-arms.md)); De
Geyter et al. 2014 ([Inside a galaxy](inside-a-galaxy.md)). From memory: the 10 suns a pc² of gas
near the Sun, the thickness of real gas layers, and the way a bar of stars torques the gas that
leads it (Barnes and Hernquist 1996).
