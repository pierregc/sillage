# Immensity inside an arm

A study on paper, 2026-11-21. Nothing was run on a GPU, drawn or rented for it. Figures about
Sillage are quoted from the notes that measured them. Figures about real galaxies and about other
codes were read in the papers listed at the end, where what is cited from memory is marked. The
arithmetic is in the text so that it can be checked.

Pierre's questions, the day after #357 gave a flight its fine stars:

1. #357 draws about 32 M fine points where there were 20 M large ones, when 20 M particles (8 M
   visible, 12 M dark) had been called the ceiling. How do the two fit?
2. Now that the camera flies inside the arms, can the count of visible particles usefully grow,
   and to what order of magnitude?
3. Stars are immensely far apart. Would the galaxies have to grow to leave room between more
   points, and what system would give that sense of immensity, with the stars grouped as in a
   real galaxy?
4. Twelve million particles of dark matter for eight million seen: is that what the literature
   does, and can less of the GPU go to what is never drawn without leaving the state of the art?
5. More particles are more memory and more disk. What can be done about the size of a snapshot?
6. Tracers: what they cost, whether the picture turns uniform, whether they need some
   randomness, how they compare.

**In short.**

- **The two twenties are different things.** 20 M is what is simulated (8 M drawn, 12 M dark,
  never drawn). The 20.5 M that became 31.7 M are point stars, laid by the renderer around the
  particles near the eye (160,000 of the 8 M on the frame measured), made again at every frame
  and stored nowhere. It is how the literature looks at a simulated galaxy star by star (Galaxia,
  Ananke, Aurigaia).
- **A frame is already at what a screen can hold.** A 4K frame is 8.3 M pixels. In a real disk
  every star within about 500 to 750 pc of the eye would have a pixel of its own, and 32 M points
  is every real star within about a kiloparsec of the field. Within a hundred parsecs #357's
  points stand 3 pc apart where real stars stand 1.4 to 2.2. No count of particles changes that.
- **The galaxies are at their real size, and growing them would change nothing**: gravity has no
  scale, so the same frame comes out. Immensity is ratios: a star is a point 29 million of its
  own widths from the next, and a disk is 14,000 star spacings across. The first is drawn
  (#357). The second is covered by the stars drawn inside the particles, and is felt through the
  flight: a speed that follows the distance to the nearest matter, and the stars grouped as real
  ones are, the young in clusters, the old spread evenly.
- **The simulated count can usefully grow 4 to 12 times, to about 10^8 drawn, and no further.**
  The spacing goes as the cube root: 50 pc at 8 M, 31 at 32 M, 21 at 100 M. Today's take is
  already finer in mass than TNG50 or Auriga at level 4; 32 M is FIRE-2's Latte. The next real
  step, one particle a star, is 3 × 10^11 particles and nearly all of Fugaku (2025).
- **Dark matter: Sillage is inside what the literature does.** The largest N-body models of the
  Milky Way give the halo 92 to 95 % of their particles, the 2025 star by star run 60 %, the
  cosmological codes half; Sillage 60 %. A collision needs a live halo. The credible economy is
  to hold the halo at 12 M while the visible count grows: its share falls to 27 % at 32 M and
  11 % at 100 M.
- **Disk: keep 8 M for the whole story and the full count only where a flight goes.** Tracers
  already work that way. A coding that predicts each frame from the ones before would take a
  take down two to three times; fewer frames or fewer bits would not hold.
- **Tracers are drawn at random from the same distribution as the particles: no rows, nothing to
  jitter.** What is too even is the scatter of the drawn stars of a young particle, which real
  young stars are not.

## Two counts that share a number

| | what it is | where it lives | today |
| --- | --- | --- | --- |
| simulated particles | 8 M visible and 12 M dark, each pulling on all the others | the solver | 20 M |
| drawn particles | the visible ones, each a soft kernel | the take, every frame | 8 M |
| point stars | the light of a near particle, handed to points scattered in its kernel | one frame of a flight | up to 20.5 M a frame before #357, 31.7 M since |

The dark particles were never among the twenty million points: they are never drawn. What #357
changed is the third row ([inside-a-galaxy.md](inside-a-galaxy.md#what-a-point-is-357)): a
particle near the eye stands for 128 stars beyond 600 pc and up to 4,096 within 110 pc, finer,
capped so that a star stays a point.

- **A point star is not simulated and not stored.** Its place is worked out from its particle's
  index at each frame. It costs drawing time alone: 5 to 9 % more a render inside the arm for
  half as many stars again.
- **It is the literature's own method.** Galaxia (Sharma et al. 2011) spawns stars from each
  N-body particle and disperses them so that their density in phase space is the particles'.
  Ananke (Sanderson et al. 2020) turns each 7,070 solar mass star particle of FIRE-2's Latte
  galaxies into the stars of one population for mock Gaia surveys, and Aurigaia (Grand et al.
  2018) does the same for Auriga. Nobody simulates the stars of a spiral one by one, with one
  exception below.
- **"Past 8 M nothing changes" was true and still is**, of three other things. The softening
  sits at its 30 pc floor from about 7 M visible on, so the force resolves the same scales and
  the step is the same ([ten-times-the-particles.md](ten-times-the-particles.md)). From outside,
  a galaxy that covers 1 to 5 % of the frame has tens of particles to a pixel and the count
  cannot be told ([gigantism.md](gigantism.md)). And the Mac's memory and hours end there. None
  of the three binds a point star.
- **How the two meet.** A frame lists at most 128 M stars. At 50 M particles and 128 stars each
  a render inside the arm asks for 66 M and holds; at 100 M it would ask for 130 M, so a visit
  there takes 64 a particle, the same light in half the points
  ([flights.md](flights.md#key-frames-and-visits)). #379 measured what that buys: at 50 M, 128,
  64 and 32 stars a particle draw in 181, 148 and 138 ms in 1080p. A 50 M frame pays for its
  particles, not for its stars. More particles therefore means fewer stars to each for the same
  light, and their product is bounded by the screen.

## The real scale, and what a frame can hold

A spiral like the Milky Way, in round numbers:

| | |
| --- | --- |
| stars | a few 10^11, 5 × 10^10 suns of them (Hirashima et al. 2025 model 5.4; Fujii et al. 2019, 4.3) |
| disk | 30 kpc across, scale length 2.6 kpc, the thin disk 0.3 kpc high (Bland-Hawthorn and Gerhard 2016, as Fujii et al. quote them) |
| stars near the Sun | about 0.1 a cubic parsec: 540 stars, brown dwarfs and planets in 339 systems within 10 pc (Reylé et al. 2021) |
| from a star to the next | 2.2 pc on average between neighbours (density to the power -1/3), 1.2 pc to the nearest; the Sun's is 1.30 pc away |
| a star's width | 4.5 × 10^-8 pc for the Sun: the next star is 29 million diameters away, 29 km for a grain of sand of a millimetre |
| the disk in star spacings | 14,000 |

**What a frame can hold.** A flight's default field is 0.6 rad high, so 1.0 rad wide in 16:9:
0.57 steradian, 4.5 % of the sky. A pixel of a 4K frame is 57 arc seconds, and there are 8.3 M of
them (2.1 M in 1080p). A cone of that field out to a distance D holds 0.57 n D³ / 3 stars at a
density n:

| out to | at 0.1 a cubic parsec (the Sun's surroundings) | at 0.4 (the arm of the Mice take) |
| ---: | ---: | ---: |
| 10 pc | 19 | 76 |
| 100 pc | 19,000 | 76,000 |
| 300 pc | 0.5 M | 2.1 M |
| as many stars as a 4K frame has pixels | 760 pc | 480 pc |
| 32 M stars | 1,190 pc | 750 pc |

(The 0.4 is this note's reading of [inside-a-galaxy.md](inside-a-galaxy.md#what-a-point-is-357):
50,000 real stars a particle, particles 50 pc apart. Past about 500 pc a field looking along the
plane is taller than the thin disk, so the last two rows are a little short.)

- **The screen is the bound.** A 4K frame cannot show more separate stars than those within half
  a kiloparsec to 750 pc; everything farther is several stars to a pixel, a glow. The 31.7 M
  points #357 draws are the real count of stars within about a kiloparsec of this field. Ten
  times the points would add nothing a pixel could show.
- **What a traveller would see is far fewer.** About 9,000 stars are brighter than magnitude 6.5
  over the whole sky (the Bright Star Catalogue, from memory), so about 400 in this field. The
  rest of the Milky Way's 10^11 is the band: unresolved light. A camera goes deeper than an eye
  and is still bound by its pixels. The sense of space in a real sky is a few hundred sharp
  points of very unequal brightness over a glow, not a carpet.
- **Where #357 stands.** Within 110 pc a particle draws 4,096 points, 3.1 pc apart, each the
  light of 12 real stars; the real spacing at that density is 1.4 pc (2.2 near the Sun). So the
  nearest field is within a factor of two or so of a real one in spacing. Farther out a point
  stands for more stars (400 at 128 a particle), as a pixel does.

So the feeling Pierre is after does not come from more points. It comes from three things a real
sky has: stars that stay points however near (done, #357), a steep hierarchy of brightness with
room between the bright ones (partly done: shares in rank to the minus one, a Pareto tail), and
depth read through motion, the near stars streaming past a far field that barely moves.

## Would larger galaxies leave more room?

**They are at their real size.** A length unit is a kiloparsec. A generated spiral has a scale
length of 1.8 to 4.6 kpc and ends at four of them, 14 to 37 kpc across: the Milky Way's size.

**Growing them would draw the same frame.** Gravity has no scale of its own. Multiply every
length by k and every mass by k³: the densities are the same, so are the orbital times, and the
run is the same run. A camera path grown by k then draws the same frame, pixel for pixel, with
another number on the scale bar. What a frame shows depends on ratios alone:

- **the spacing over the galaxy's size**, which is the count's: a disk 30 kpc across is 600
  spacings of 50 pc at 8 M, 1,400 at 100 M, 14,000 for the real one. To close that with particles
  takes (50 / 2.15)³ times 8 M, 10^11, the real number of stars;
- **a point's size over the distance to its neighbour on screen**, which is the drawing's.

**More points are not points too close.** A real arm holds fifty thousand times the take's
particles in the same volume and its stars do not crowd, because each is a point. Two things make
points crowd on a screen: more of them than pixels, and points drawn wider than one. The first is
the screen's bound, above. The second was #357's: a star is held to a pixel and a half, which is
still twelve thousand times the width of the nearest star as the Sun's place sees it. Neither is
the galaxy's size.

**The system exists, in embryo: the stars inside the particles.** 8 M particles of 50,000 stars
each is 4 × 10^11, the real count. No frame needs them all: a frame needs those near enough to
tell apart, a few tens of millions, and #357 draws that many from the right particles. What
would complete it, in the order of what it shows:

1. **Stars grouped as real ones are.** A particle's stars walk an even sequence through its
   kernel, so that its brightest are spread out rather than clumped at random. That is right for
   old stars, which have had gigayears to mix: an old field is even. It is the opposite of what
   young stars do. Stars form in clusters within giant clouds, and under 4 to 7 % of those
   clusters are still bound at the age of the Pleiades (Lada and Lada 2003); young clusters and
   associations are grouped in a hierarchy that fades in 40 to 60 Myr over a few hundred parsecs
   (Grasha et al. 2017). A young particle of 29,000 suns is a large OB association: its few
   hundred massive stars are what a flight sees from afar. So the scatter could follow the age
   every particle already carries: a few parsecs at birth, growing by about a parsec a megayear
   (a group that comes apart at a kilometre a second, order of magnitude, from memory), the
   kernel's own size past 50 Myr, and around three or four centres of the particle's own rather
   than one. The blue stars would then come in knots along the arm and the yellow field stay
   even, which is how an arm looks from inside and what "grouped as in a real galaxy" means. It
   costs nothing a frame. The age is there in both its kinds: what the run forms ages as it
   goes, and a sampled star keeps the age it was drawn with
   ([kernel-width-per-population.md](kernel-width-per-population.md)). That note widens the
   young stars' splats so that they do not read as sand from outside; this is the other side of
   it, on the point stars of the near field alone.
2. **A speed that follows the scale.** A star at distance d crosses the frame at 1,750 v / d
   pixels a frame in 1080p ([inside-a-galaxy.md](inside-a-galaxy.md#motion)). To watch the
   nearest real star, 1.2 pc away, take two seconds to cross the frame, the eye must move 0.6 pc
   a second, two light years: at that pace an arm a kiloparsec wide takes half an hour to cross
   and the disk fourteen hours. That is the immensity, and no film has the time. Speed is the
   author's today: 50 to 150 pc a second is a drift to a glide among the stars, an arm in 7 to
   20 s, and the 10 s dive of #296 averages 2 kpc a second. The flight already measures how near
   matter is (`Nearness`, 160 pc inside an arm of the Mice). A speed held at a set share of it
   each second (an option of a flight, or of the app's throttle) keeps the near field drifting
   at one rate on screen from 20 kpc out to the arm: at a third of the nearness a second, 7 kpc
   a second at the start, 50 pc a second at the end, and a dive of 15 s that never stops
   slowing. The viewer reads the scale in how long it keeps slowing.
3. **The scale in words.** The scale bar exists (#317). Among the stars the same line can say
   what the eye cannot judge: the 10 s dive covers 6,500 light years each second, 2 × 10^11 times
   the speed of light, and a drift of 50 pc a second is still 160 light years a second.
4. **The real census for the nearest particles.** `nearStars` stops at 4,096 where a particle
   holds 50,000. Two particles of a frame lie within 110 pc; drawing their real count is 10^5
   points among 32 M. It takes the nearest field from 3.1 pc to the real 1.4. It asks one thing
   of the renderer first. A frame multiplies world positions by one single precision matrix
   (`Camera.viewProjection`), and 20 kpc from the scene's origin a float holds 0.002 pc: a pixel
   or two of a 4K frame for a star 3 pc from the eye, a tenth of that at 30 pc. Today's nearest
   stars are at the edge of it; stars at their real spacing, passed slowly, would shake unless
   their places are taken from the eye before they are rounded. That is arithmetic on the code
   as read, not a defect seen. A small step, last.

## How far the simulated count can go

What more particles buy is the scale under which the field has no structure of its own, the
stars and the dust being drawn below it. On the Mice take (a galaxy of 1.36 × 10^11 suns over
4.7 M of the 8 M particles), in the field of a frame inside an arm:

| visible | suns a particle | spacing in an arm | particles within 300 pc | within 3 kpc | the same mass resolution in the literature |
| ---: | ---: | ---: | ---: | ---: | --- |
| 8 M | 29,000 | 50 pc | 40 | 11,000 | finer than TNG50 (85,000) and Auriga level 4 (50,000) |
| 32 M | 7,200 | 31 pc | 165 | 43,000 | FIRE-2 Latte (7,070), Auriga level 3 (6,000) |
| 50 M | 4,600 | 27 pc | 260 | 68,000 | Fujii et al. 2019, standard runs (4,500) |
| 100 M | 2,300 | 21.5 pc | 510 | 136,000 | toward Auriga level 2 (800), the finest cosmological zoom of a Milky Way |
| 10^9 | 230 | 10 pc | 5,100 | 1.4 M | |
| 10^10 | 23 | 4.6 pc | 51,000 | 14 M | Bédorf et al. 2014: 51 × 10^9 at 10 suns |
| 4 × 10^11 | 0.6 | 1.4 pc | | | Hirashima et al. 2025: 3 × 10^11 at 0.75 suns |

(Counts in the field of a frame at the 50 pc of
[inside-a-galaxy.md](inside-a-galaxy.md#what-a-point-is-357), the disk taken 300 pc thick. Where
#379's flight ends, 800 particles lie within 159 pc of the eye, 28 pc apart, and the counts are
up to six times these.)

- **The stars of a frame hang on about 160,000 particles** (20.5 M points at 128 a particle, 2 %
  of the take), and the nearest few hundred parsecs, where a star can be told from its
  neighbour, on a few dozen to a few hundred. That is why the drawing had to supply the stars,
  and why four times the count is not the change of scale it sounds like.
- **Each step is a cube root.** Four times the particles shorten the spacing by 37 %, twelve
  times by 57 %. What that shows is not more stars but finer support for them: thinner lanes and
  spurs, sharper edges to shells and tails, smaller dust grains (a grain is a particle, and they
  stand 41 pc apart at 8 M: 26 at 32 M, 18 at 100 M). #379 has drawn the first rung: at 50 M the
  same lanes are in the same places, finer (sheets on `assets/379-visits`).
- **Yardsticks for a particle** (from memory, orders of magnitude): the Pleiades are 800 suns,
  the Orion Nebula Cluster about 2,000, a giant molecular cloud 10^4 to 10^6. A particle of
  today's take is a small cloud, or fifteen Orions. At 100 M it is one Orion. No count short of
  10^10 makes a cluster out of several particles.
- **A model without gas makes no fine structure of its own.** In a disk of stars, gravity builds
  at wavelengths of kiloparsecs (the arms); below that the random motions of the stars smooth
  everything. With the solar neighbourhood's 30 km/s and 33 suns a square parsec (McKee et al.
  2015), the length under which stars alone cannot gather is the dispersion squared over G times
  the surface density, 6 kpc. The clouds, filaments and clusters of a real arm are cold gas:
  hydrodynamics, cooling, feedback, which is where FIRE, Auriga and the Fugaku run spend their
  resolution. Sillage's dust is particles that cool, and it does gather into lanes that sharpen
  with the count; clusters it cannot make at any count. Below the lanes, structure has to be
  drawn, as #356 and #357 draw it.
- **Even a hundred million stars are smooth.** D'Onghia et al. 2013 ran a disk of 10^8 stars
  and found that at that count it grows no prominent arms unless something seeds them. Fujii et
  al. 2011 put at 3 × 10^6 the count from which a disk of stars keeps its arms for 10 Gyr rather
  than heating them away. The grain of a low count is noise, not detail, and 8 M is past the
  count where the arms are sound.
- **The softening stays where it is.** At these masses the literature softens at 10 pc (Fujii et
  al. 2019) to 184 and 369 pc (Auriga); the 30 pc floor is inside that. Lowering it multiplies
  the steps for a force finer than anything the model can form.

**What bounds it in practice** is no longer the computing. By the estimates of
[scenes-on-rented-gpus.md](scenes-on-rented-gpus.md), 100 M visible on a halo held at 12 M is
16 GB of a 32 GB card and about 4 hours a gigayear on a rented 5090, a few dollars a story (3.0 s
a step on the M4 Max, divided by 3.5, not measured). What bounds it is the take (187 to 307 GB
at 100 M) and the Mac that draws afterwards (a visit at 100 M peaks near 31 GB). Both are the
next section's.

**So: one order of magnitude, to about 10^8 drawn, massive or tracers.** That is where the best
zooms of a single galaxy stand. Between 10^8 and 10^11 no new scale appears, and the far end is
3 × 10^11 particles on 148,900 nodes of Fugaku at 2.8 hours a megayear (Hirashima et al. 2025).
The gap is filled the way the literature fills it: by the stars drawn inside the particles.

## Dark matter

**What others spend on it.**

| | visible particles | dark particles | dark share | a dark particle over a star's |
| --- | ---: | ---: | ---: | ---: |
| Sillage, a scene of today | 8 M | 12 M | 60 % | 2.4 |
| Bédorf et al. 2014, Milky Way, stars only | 4 × 10^9 | 47 × 10^9 | 92 % | 1 |
| Fujii et al. 2019, Milky Way, stars only | 9.5 M | 194 M | 95 % | 1 |
| Hirashima et al. 2025, star by star, with gas | 1.2 × 10^11 | 1.8 × 10^11 | 60 % | 8 |
| FIRE-2 Latte (Hopkins et al. 2018) | as many gas as dark at the start | | 50 % | 5 to 6 |
| Auriga levels 3 and 4, EAGLE, TNG50 | the same | | 50 % | 5.3 to 6.7 |
| AGORA isolated disk (Kim et al. 2016) | 212,500 | 100,000 | 32 % | 36 |
| D'Onghia et al. 2013, one disk alone | 10^8 | none: a fixed potential | 0 | |

- **More than half of the particles going to what is never seen is the norm.** The two models
  nearest to Sillage in kind (stars and a halo, no gas, a tree code on GPUs) give every particle
  the same mass, "in order to avoid numerical heating caused by unequal mass" in Bédorf et al.'s
  words, so the halo, most of the mass, is nine particles in ten or more; they add that it takes
  "at least five times more dark matter than disk particles" to model the halo and its exchange
  with the disk. The cosmological codes start with as many dark particles as gas cells, each five to
  seven times heavier, the cosmic ratio. At 2.4 Sillage is between the two conventions.
- **Where Sillage is light is the halo's mass, not its particles.** Its halo holds 3.5 times the
  visible mass (`diskMassFraction` 0.22), inside 12 scale radii. That is the halo of the classic
  merger models (Barnes 1988: 16 parts of halo for 4 of bulge and disk, from memory), under
  today's Milky Way models (11 in Bédorf et al., 17 in Hirashima et al., 20 in Fujii et al., 23
  in AGORA). Long tails are what a light or compact halo gives (Dubinski, Mihos and Hernquist
  1996: under 10 to 1 for the Antennae's tails; Springel and White 1999: the ratio matters less
  than the disk's size against the halo's). A truer halo would be heavier and wider, and cost
  more particles, not fewer. Not proposed: the orbits and the tails of every scene are tuned on
  this one.
- **A collision needs the halo live.** A fixed potential has mass and no inertia: it raises no
  wake, so there is no dynamical friction and the pair never merges (the code's own comment on
  `haloParticleRatio`), and it cannot be stripped or respond. Even alone, a disk in a fixed halo
  grows the wrong bar: it is the halo's resonant stars that take the bar's angular momentum
  (Athanassoula 2002). The fixed halo is the accepted choice for one case, a disk alone studied
  for its arms (D'Onghia et al. 2013). A scene of one galaxy with nothing near it could run that
  way and put all of the GPU on what is seen. No scene of the nights is that.
- **Or show it.** The halo is computed and thrown away. A key frame could keep it (96 MB for
  12 M particles) and a look draw it as the faint scaffold the visible galaxies sit in, as the
  pictures of the cosmological runs do. An idea for one shot, outside this note's questions.

**What can be saved without leaving the literature.**

- **Hold the halo's count as the visible count grows** (already the advice of
  [ten-times-the-particles.md](ten-times-the-particles.md#the-levers)). Spurious heating of a
  disk is set by the mass of a halo particle, linearly, and by the time, linearly; it is
  "largely insensitive to the stellar particle mass" (Ludlow et al. 2021, Wilkinson et al.
  2023). Held at 12 M, a dark particle stays at 68,000 suns whatever is drawn; the dark share of
  the GPU falls to 27 % at 32 M visible and 11 % at 100 M, and the mass ratio rises to 9 and 29,
  AGORA's order. What a large ratio adds is segregation, slow against a story (Ludlow et al.
  2019); the calm-disk probe measures it before a run relies on it.
- **Fewer dark particles today: possible, small.** Ludlow et al. give, for a Milky Way: a rise
  of 5 km/s in the vertical dispersion of a thin disk over 10 Gyr at 55,000 suns a dark
  particle, 16 km/s at 590,000. Scaled linearly in the variance to a story of 1.5 Gyr and added
  to a disk at 20 km/s:

  | halo of a pair | suns a dark particle | over a star's, at 8 M | added in a story | the disk's 20 km/s become |
  | ---: | ---: | ---: | ---: | ---: |
  | 12 M (today) | 68,000 | 2.4 | 2.2 km/s | 20.1 |
  | 6 M | 136,000 | 4.7 | 3.0 | 20.2 |
  | 3 M | 272,000 | 9.4 | 4.3 | 20.5 |
  | 1.2 M | 680,000 | 23.5 | 6.8 | 21.1 |

  An estimate: their halo is not this one, and the local density of dark matter enters. It
  agrees with what this project measured on a disk alone, where halo particles 3.3 times lighter
  changed the heating by 4 % ([disk-heating.md](disk-heating.md)). A halo of 6 M puts the ratio
  at the cosmological codes' 5 and takes 30 % off a step. It is defensible, it is the loose end
  of the convention, and at 8 M it saves an hour of the Mac a story, or a quarter of an hour of
  a rented card. Worth one run of the probe when the count goes up, not a change of today's
  scenes.
- **Not worth it here.** A halo with heavier particles far out (Zemp et al. 2008) gains little:
  this halo is compact, two thirds of its particles lie inside the disk's own radius, where they
  must be fine. A halo carried by a basis expansion instead of a tree (EXP, Petersen et al.
  2022) is research code for one halo, harder for two that merge. Individual time steps,
  standard in the CPU codes, are not what GPU tree codes of this family do (Fujii et al. share
  one step of 0.6 Myr among 8 × 10^9 particles), and a compact halo lives at the disk's
  accelerations anyway. Softening the dark particles more buys nothing either: the heating does
  not depend on the softening while it stays under the disk's height (Ludlow et al. 2021).

## Memory and disk

What a particle weighs today:

| | bytes | from |
| --- | ---: | --- |
| a visible particle in a stored frame of a take (one frame in four is stored) | 8 | [takes-on-disk.md](takes-on-disk.md) |
| the same, a captured frame | 2.026 | measured |
| its attributes, once a take | 28 | [flights.md](flights.md#key-frames-and-visits) |
| a simulated particle in a checkpoint | 36 | [checkpoints.md](checkpoints.md) |
| a massive particle on the GPU, with its tree (CUDA) | 144 | [cuda-engine.md](cuda-engine.md#memory) |
| a tracer on the GPU | 36 | the same |
| a drawn particle in a visit, at the peak | 290 | [flights.md](flights.md#key-frames-and-visits) |

| visible, halo held at 12 M | 8 M | 32 M | 50 M | 100 M |
| --- | ---: | ---: | ---: | ---: |
| a stored frame | 64 MB | 256 MB | 400 MB | 800 MB |
| the take, 923 frames | 15 GB | 60 GB | 94 GB | 187 GB |
| the take, 1,514 frames | 24.5 GB | 98 GB | 153 GB | 307 GB |
| a checkpoint | 0.72 GB | 1.6 GB | 2.2 GB | 4.0 GB |
| the solver on the GPU | 2.9 GB | 6.3 GB | 8.9 GB | 16.1 GB |
| drawing a visit, peak | 5.7 GB (measured) | 12.5 GB | 17.5 GB (measured) | 31 GB |

The solver's memory is not the problem at any count worth running. The take is, and the Mac's
memory when it draws. In the order of what they give for what they cost:

1. **A master at 8 M for the whole story, the full count only where a flight goes.** From
   outside 8 M is enough, and a flight is authored on it. A flight near matter wants time frozen
   or at a hundredth of the take's speed, so a visit of thirty seconds is ten frames kept whole:
   5.4 GB at 50 M, 10.8 GB at 100 M with the attributes. With tracers this is already how it
   works: the take holds the massive particles, #379 keeps whole frames where asked and cuts
   them out of a larger take. For a run with every particle massive the same split is missing:
   the take pass would keep one particle in four (or in twelve) as the master, a fair sample lit
   four times as much, and every particle on the frames a visit asks for. A story at 100 M is
   then today's 15 to 25 GB and 11 GB a visit, where the whole take is 187 to 307.
2. **The same cut in space.** A visit needs the full count only within the stars' window, 8 kpc
   of its path; farther, the master's particles do. A tenth to a fifth of a galaxy lies there:
   a visit at 100 M is 1 to 2 GB on disk and near 10 GB to draw instead of 31, so it holds on a
   32 GB Mac. Without it 50 M is the most such a Mac draws from inside (17.5 GB measured). It is
   how Gaia Sky flies through the 1.8 × 10^9 stars of Gaia's catalogue: a tree of cells whose
   far ones give their brightest stars alone (from memory).
3. **Checkpoints as the archive.** A run resumes to the bit (#377, #378), so a checkpoint, its
   command line and its binary are every frame after it. A visit decided after the run costs the
   steps from the checkpoint before it: 1,740 for 100 Myr, half an hour of a 5090 at 100 M by
   the estimate above. A checkpoint is 4 GB at 100 M, so one every 100 Myr of a story is 60 GB,
   to keep on the box or to bring home for the moments that matter. It resumes on the engine
   that wrote it only: a box's checkpoint needs a box.
4. **Predict each frame from the ones before, and store the difference.** A take "does not
   compress" under a general compressor because the low bits of a position are noise. They are
   not noise against the frame before: a star 8 kpc out lands within 63 pc of the straight line
   through its last two stored positions (v²/R times the 3.2 Myr between them, squared), 126 pc
   at 4 kpc, 209 at 2. On a grid of 1 to 1.5 pc that is 7 to 9 bits an axis where 21 are
   stored: two to three times smaller, exact on the grid, more with a predictor that knows the
   orbit is nearly a circle about its galaxy's centre. Molecular dynamics stores its
   trajectories that way (GROMACS's XTC and TNG formats: positions on a fixed grid, coded
   against their neighbours and, in TNG, against the frame before; from memory). The price is a
   take that no longer opens at any frame (a whole frame every so many, the others decoded in
   order) and a decoding step in the app, the exports and both engines. An estimate until a
   script has measured it on a take, which takes minutes and no GPU, and should come before any
   new version of the format.
5. **Fewer stored frames: no.** Between two stored frames a take draws a cubic through four. On
   a circular orbit of radius R and angular speed Ω the middle of the cubic falls short by
   (3/128) (Ω Δt)⁴ R:

   | radius | one frame in four (3.2 Myr) | one in eight |
   | ---: | ---: | ---: |
   | 8 kpc | 0.01 pc | 0.2 pc |
   | 2 kpc | 0.5 pc | 8 pc |
   | 1 kpc | 4 pc | 65 pc |
   | 0.5 kpc | 21 pc | 340 pc |

   One in four is already at its limit in the inner kiloparsec. One in eight would make every
   bulge pulse inward between stored frames.
6. **Fewer bits: no.** 21 bits an axis is 1 to 1.5 pc late in a story, an error of 0.3 to
   0.4 pc rms an axis, against the 98 pc a star's random motion covers between two stored
   frames. It does not depend on the count. A coding about each galaxy's centre at 6 bytes
   ([ten-times-the-particles.md](ten-times-the-particles.md)) would take a quarter off and cost
   the tails.

## Tracers

**What they cost** ([light-tracers.md](light-tracers.md), [200m-preview.md](200m-preview.md)):
23.4 ns a tracer a step on the M4 Max over today's 20 M massive, as much as a massive particle's
walk; 36 bytes on the GPU where a massive particle takes 144; 8 bytes a key frame and nothing in
the take. The full pass that left eleven frames of the Mice at 50 M took 4 h 34 min on the Mac
for 5.8 GB. Memory is not what bounds them: beside today's 20 M massive a 32 GB card holds
800 M. Time is: every 100 M add 2.3 s to a step of 0.45 s.

**Uniformity, and randomness.** Tracers are not laid on a grid. They are drawn by the same
sampler as the massive particles, from the same distribution, with independent random numbers:
they are a second, larger sample of the same galaxy, with the noise any sample has, and they
then move under gravity for the whole story. There are no rows to break up and nothing to
jitter. Over a story they stay on the mass to within the noise of counting them. Three
things are behind the worry all the same:

- **From outside, more points do look smoother, and that is right.** At 200 M the previews read
  "very fine, milky". The grain of a low count is sampling noise, and a real galaxy seen whole
  is smooth light. What gives a real picture its texture is not grain: it is dust, pink knots
  and blue clusters, which have to be put in for themselves.
- **The stars drawn inside a particle are more even than chance**, by choice (#357). For young
  stars that is the wrong way round: see the grouping proposed above.
- **Pierre's earlier dislike of tracers** was seen on 2 M massive, softened at 55 pc: the shapes
  were coarse because the mass was. On today's 20 M the shapes are today's exactly.

**Against making every particle massive**, at 100 M drawn:

| | every particle massive | tracers on today's 20 M massive |
| --- | --- | --- |
| who pulls | all of them | the 20 M alone |
| force resolved | the 30 pc floor | the same |
| noise in the field | lower | today's |
| a gigayear on the M4 Max | 14.5 h | 12.3 h, after a massive pass of 2.2 h |
| on the GPU | 16.1 GB | 6.2 GB |
| on disk | 187 to 307 GB, or a master and whole frames, to be built | today's take and 0.8 GB a key frame, built (#379) |
| seen | at any moment, if the take holds it | at key frames |
| the same story as the 8 M master | no: its own sample, its own knots and satellites, unless the master is cut from it | yes, the massive part to the bit |

At the softening floor the two cost about the same time. What tracers save is memory, disk, and
the master: a flight flown on the 8 M take holds at 50 M (the nearest matter 159 and 160 pc from
the eye on the same frame). What every particle massive gives is any moment of the story, at the
price of the storage work above. Which one looks better from inside is #381's question, on
frames.

**An idea to test, beyond the usual.** A full pass with tracers starts at the beginning of the
story to reach one moment of it. Tracers could be seeded late instead: at a checkpoint 50 to
100 Myr before a visit, each massive particle near the flight's path handed children placed and
given velocities from its neighbours in phase space (Galaxia's way of spawning stars, here
followed by the solver), then carried as tracers through the last megayears. A hundred megayears
are 1,740 steps, an hour and twenty minutes for 100 M tracers on the M4 Max where the pass from
the start took four and a half hours for 50 M; and put on the tenth of a galaxy a flight crosses,
100 M tracers have the density of a galaxy of 10^9: 10 pc. The price is honesty about what they
are: a smoothed sample at the moment of seeding, so only what forms afterwards (a lane compressed
at the passage, a shell's edge) is real below the particles' spacing. Splitting particles is
common for gas and unusual for stars. A candidate for #381 if passes from the start prove too
slow, not a plan.

## What to do, in order

The thread through all of it is Pierre's own: more points where the camera goes, and only there.
The stars inside the particles, whole frames where a flight passes, tracers seeded along a path:
none of them asks a whole story to carry what one visit needs.

1. **Nothing changes for whole stories.** 8 M visible on 12 M dark stays the master: the
   ceiling of 2026-11-19 holds for what is simulated and stored, and #357's defaults for what is
   drawn.
2. **Immensity first through the drawing and the flight**, on the takes there are, with no
   rental: young stars in clusters and associations by the particle's age; a flight speed that
   follows the distance to the nearest matter; the scale and the speed in words.
3. **More simulated detail inside an arm is the ladder's to judge** (#381: 8 M, 32 M massive,
   tracers to 50 and 100 M, on frames). This note adds three things to it: hold the halo at 12 M
   on the 32 M rung and run the probe; the first rung is drawn (#379's 50 M sheets); stop at
   100 M drawn.
4. **Before any run above 8 M with every particle massive**: the take pass keeps a master and
   whole frames where asked, as the full pass does for tracers, and a visit is cut in space. And
   a script that measures what predicting frames would save on a take, before a format is
   touched.
5. **Dark matter stays as it is.** One probe run at 6 M when the count goes up.
6. **Not worth it**: larger galaxies; a fixed halo for a collision; a multi-mass halo; fewer
   stored frames or fewer bits; any count above 10^8; jitter on tracers.

## Sources

Read for this note (arXiv numbers; the text for the first eleven, the abstract for the others):

- Hopkins et al. 2018, FIRE-2, MNRAS 480, 800 (1702.06148): m12i at 7,070 suns a baryonic
  particle, dark particles "about 5" times heavier in its text and 43,000 suns, six times, in
  its table 3, 1.4 × 10^8 particles, dark matter softened at 30 pc in Milky Way mass halos.
- Grand et al. 2017, Auriga, MNRAS 467, 179 (1610.01159): level 4 at 5 × 10^4 and 3 × 10^5 suns
  softened at 369 pc, level 3 at 6 × 10^3 and 4 × 10^4 at 184 pc.
- Schaye et al. 2015, EAGLE, MNRAS 446, 521 (1407.7040): 1504³ of each, 1.81 × 10^6 and
  9.70 × 10^6 suns.
- Pillepich et al. 2019, TNG50 (1902.05553): 2160³ of each, 8.5 × 10^4 and 4.5 × 10^5 suns,
  288 pc.
- Kim et al. 2016, AGORA II, ApJ 833, 202 (1610.03066): 10^5 halo particles of 1.254 × 10^7
  suns, 10^5 disk stars of 3.437 × 10^5, 10^5 of gas at 8.593 × 10^4, 12,500 of bulge, 80 pc.
- Hirashima et al. 2025, SC '25 (2510.23330): 1.8 × 10^11 dark particles of 6 suns, 7.2 × 10^10
  stars and 4.9 × 10^10 gas particles of 0.75, 148,896 nodes of Fugaku, 20 s a step of 2,000
  years; it quotes 800 and 5,000 suns for the finest cosmological zoom (Grand et al. 2021).
- Bédorf et al. 2014, SC14 (1412.0659): 51 × 10^9 particles of equal mass, 1, 3 and 47 × 10^9 in
  the bulge, the disk and the halo, about 10 suns each.
- Fujii et al. 2019, MNRAS 482, 1983 (1807.10019): model MWa at 8.3 M, 1.2 M and 194 M, up to
  8 × 10^9 of equal mass, one shared step of 0.6 Myr, softening 10 pc, opening angle 0.4.
- Fujii et al. 2011, ApJ 730, 109 (1006.1228): arms that last 10 Gyr in a disk of stars from
  3 × 10^6 particles.
- D'Onghia, Vogelsberger and Hernquist 2013, ApJ 766, 34 (1204.0513): 10^8 stars in a fixed
  halo, softening 5 pc.
- Ludlow et al. 2021, MNRAS 508, 5114 (2105.03561): the heating figures above.
- Wilkinson et al. 2023 (2208.07623); Ludlow et al. 2019 (1903.10110) and 2023 (2306.05753).
- Sharma et al. 2011, Galaxia (1101.3561); Sanderson et al. 2020, Ananke (1806.10564); Grand et
  al. 2018, Aurigaia (1804.08549).
- Reylé et al. 2021, the 10 pc sample (2104.14972); McKee, Parravano and Hollenbach 2015
  (1509.05334).
- Lada and Lada 2003, ARA&A 41, 57 (astro-ph/0301540); Grasha et al. 2017 (1704.06321).
- Dubinski, Mihos and Hernquist 1996, ApJ 462, 576 (astro-ph/9509010); Springel and White 1999,
  MNRAS 307, 162 (astro-ph/9807320); Athanassoula 2002, ApJ 569, L83 (astro-ph/0203368).
- Zemp et al. 2008, MNRAS 386, 1543 (0710.3189); Petersen, Weinberg and Katz 2022, EXP
  (2104.14577).

From memory, not read again: Barnes 1988 (ApJ 331, 699) for the 1:3:16 model; the Bright Star
Catalogue's count; the masses of the Pleiades, of the Orion Nebula Cluster and of molecular
clouds; the speed at which young groups come apart and the few hundred massive stars 29,000 suns
of young stars hold; Gaia Sky's tree of cells (Sagristà et al. 2019); the XTC and TNG formats
of GROMACS (Lundborg et al. 2014 for TNG).
