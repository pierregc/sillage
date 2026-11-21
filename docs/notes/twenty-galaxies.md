# Twenty galaxies to reproduce

Pierre wants the most famous galaxies and collisions that Sillage can plausibly rebuild, so that
a scene can be computed to match the real photograph, then run, frozen and flown through, arms
and all. This note is the shortlist he picks three from. Nothing is reproduced yet.

The catalogue itself is `references/catalogue/catalogue.json`: names, identifiers, approximate
J2000 coordinates, distances, the published models, the archetype that comes closest, and the
picture with its page, credit and licence. The pictures are in `references/catalogue/images/`
and on one sheet in `references/catalogue/contact-sheet.jpg`.

## What already existed

- Epic #318, named scenes: #319 (the Antennae from Karl et al. 2010 or Privon et al. 2013, not
  started), #320 (the measured match, done in PR #372), #321 (side by side and the dissolve to
  the photograph, waiting for #319).
- [A match that is measured](photo-match.md): `sillage-render match` scores a take against a
  picture's isophotes. The Mice archetype reaches 0.82 on the Mice; no Antennae archetype draw
  passes 0.66 on the Antennae, because a family of look-alikes does not make its two curved tails.
- [What would give Sillage its dimension](next-dimension.md) listed the published orbits for the
  Antennae, the Mice and M51, and the 62 pairs of Galaxy Zoo: Mergers (Holincheck et al. 2016).
- `references/telescope/marks.json` already held twelve Hubble and Webb pictures with credits,
  eight of them of objects below.
- The eight archetypes in `Archetype.swift` are families: Antennae, Mice, ring (Cartwheel),
  tadpole, polar ring, minor merger, compact group (Stephan's Quintet), black hole pass.

## How they were chosen

What Sillage holds today: stars, a bulge, a live dark matter halo, gas that is collisionless
(a sticky gas spike is running), star formation knots, a dust web drawn by the renderer, and a
ceiling of 8 M visible and 12 M dark particles. So the shape it can own is the one the stars'
tides make: tails, bridges, rings, warps, a disk torn by a companion. Shocked gas, starburst
knots and the dust's own structure it can only draw over.

Three questions for each candidate:

1. **Is it iconic?** A picture most people have seen, or the system textbooks show for its kind.
2. **Is there a published model of this very object?** An orbit, masses, inclinations, the moment
   and the direction it is seen from, fitted to the real picture. That is what turns an archetype
   into the object, as #319 sets out.
3. **Is its look made by the stars?** If the picture is mostly gas and dust, a faithful run of
   the stars still will not look like it.

The tiers on the sheet:

- **A**: a published orbit fitted to this object, and its shape is the stars' tides.
- **B**: a model or an archetype exists, but part of the look is gas, or the fit is loose.
- **C**: no fitted model. The look can be approached, not reproduced.

Fourteen are encounters and six are galaxies on their own, because Pierre asked for both; the
isolated ones rank lower because nothing fixes where their arms are.

## The twenty

| # | object | distance | tier | model of this object | archetype | picture |
| ---: | --- | ---: | :---: | --- | --- | --- |
| 1 | Antennae, NGC 4038/9, Arp 244 | 22 Mpc | A | Karl 2010, Privon 2013, Galaxy Zoo: Mergers | antennae | heic0615a |
| 2 | The Mice, NGC 4676, Arp 242 | 90 Mpc | A | Barnes 2004, Privon 2013, Galaxy Zoo: Mergers | mice | heic0206h |
| 3 | Whirlpool, M51 and NGC 5195 | 8.6 Mpc | A | Salo and Laurikainen 2000, Theis and Spinneker 2003, Dobbs 2010 | | heic0506a |
| 4 | Cartwheel, ESO 350-40 | 150 Mpc | B | Horellou and Combes 2001 | ring | weic2211a |
| 5 | Stephan's Quintet, HCG 92 | 90 Mpc | A | Renaud 2010, Hwang 2012 | compact-group | weic2208a |
| 6 | Arp 273, the Rose | 90 Mpc | A | Galaxy Zoo: Mergers | | heic1107a |
| 7 | Arp 142, the Penguin and the Egg | 100 Mpc | A | Galaxy Zoo: Mergers | | weic2420a |
| 8 | Tadpole, UGC 10214, Arp 188 | 130 Mpc | B | Briggs 2001 | tadpole | heic0206a |
| 9 | NGC 2207 and IC 2163 | 35 Mpc | A | Elmegreen 1995, Struck 2005 | | heic2414a |
| 10 | Arp 148, Mayall's object | 150 Mpc | A | Galaxy Zoo: Mergers | ring | heic0810ae |
| 11 | Arp 87, NGC 3808A/B | 100 Mpc | A | Galaxy Zoo: Mergers | | heic0717a |
| 12 | NGC 4650A, polar ring | 40 Mpc | B | Bournaud and Combes 2003 | polar-ring | opo9916a |
| 13 | M81, with M82 and NGC 3077 | 3.6 Mpc | B | Yun 1999, Oehm 2017 | | heic0710a |
| 14 | Andromeda, M31, M32, NGC 205 | 0.78 Mpc | B | Fardal 2006, 2013 (the giant stream) | minor-merger | heic2501a |
| 15 | Pinwheel, M101 and NGC 5474 | 6.9 Mpc | B | Linden and Mihos 2022 | | heic0602a |
| 16 | Triangulum, M33 | 0.85 Mpc | C | McConnachie 2009 (its orbit round M31) | | heic1901a |
| 17 | NGC 1300, barred spiral | 19 Mpc | B | none | | opo0501a |
| 18 | Sombrero, M104 | 9.5 Mpc | B | none | | heic2506a |
| 19 | Phantom, M74 | 10 Mpc | C | none | | potm2208a |
| 20 | Hoag's Object | 180 Mpc | C | Brosch 2013 (origin open) | | opo0221a |

Distances are the usual round figures; the Antennae are 14 Mpc by the tip of the red giant
branch, which changes the kiloparsecs across the frame, not the orbit's shape.

## Each in a few lines

1. **Antennae.** The most famous collision: two long curved tails and two bodies merging, 40 Myr
   after the second passage. Two fitted orbits and the viewing angles are published; #319 already
   describes the scene. The tails are stars, the pink heart is gas and starburst. Hubble's frame
   holds only the bodies, so the match uses the wide Legacy Surveys cutout.
2. **The Mice.** Two disks just past their first passage, each with a long straight tail. Barnes
   built his model for exactly this picture, Privon fitted it again, and the archetype already
   scores 0.82. The safest of the twenty.
3. **Whirlpool.** The galaxy everyone has seen. Its two arms are the companion's tide: Salo and
   Laurikainen and Dobbs reproduce them with a bound companion on two passages, so the painted
   arms would be switched off and the tide asked to draw them. A strong claim if it works.
4. **Cartwheel.** The ring a companion makes by falling through a disk near its centre, the
   textbook case Lynds and Toomre explained with stars alone. The `ring` archetype is the
   family. Webb's spokes and colours are dust and gas, which Sillage draws, not computes.
5. **Stephan's Quintet.** Four galaxies close together and an intruder arriving fast. Renaud
   et al. ran it in N-body, which is Sillage's level 2. NGC 7320, the bluish one at the bottom,
   is a foreground galaxy at 12 Mpc and is not in the scene. Five galaxies share the ceiling.
6. **Arp 273, the Rose.** A large spiral wound into a rose by a smaller companion below it. In
   Galaxy Zoo: Mergers, with an orbit fitted by a restricted three body code, the physics of
   Sillage's level 1. Pure tides: a good test of the method on a picture with no famous paper.
7. **Arp 142, the Penguin and the Egg.** A spiral stretched into a bird by an elliptical.
   Galaxy Zoo: Mergers fitted it. Webb's colours are near infrared; the shape is the stars'.
8. **Tadpole.** One tail 100 kpc long thrown out by a small intruder passing the disk. The
   `tadpole` archetype is the family; Briggs et al. traced the intruder's path in HI, which is a
   looser constraint than a fitted orbit. The clusters along the tail are star formation.
9. **NGC 2207 and IC 2163.** A grazing encounter that turned IC 2163 into an eye. Elmegreen et
   al. and Struck et al. fitted it in detail against velocities. The Webb and Hubble picture
   glows with dust; a visible light frame is the fairer target.
10. **Arp 148, Mayall's object.** A ring and a spike, the aftermath of a head-on hit, in Galaxy
    Zoo: Mergers. The 2008 Hubble picture is small (1 027 px), enough for a match.
11. **Arp 87.** A bridge of stars pulled from one spiral and wound round the other. Galaxy Zoo:
    Mergers fitted it. Graceful and entirely tidal.
12. **NGC 4650A.** A ring of stars and gas across the poles of a lenticular. The `polar-ring`
    archetype builds it by tearing a dwarf; Bournaud and Combes show both an accretion and a
    merger can, and the accretion is a gas story, so the ring's blue light is partly drawn.
13. **M81.** A grand design spiral whose arms M82 and NGC 3077 raised 200 to 300 Myr ago. Yun's
    model is of the HI bridges, and Oehm et al. constrain the orbits. M82's smoke is a starburst
    wind, out of reach. A scene of the group seen wide, rather than M81 alone, is the honest one.
14. **Andromeda.** The nearest big spiral, with M32, NGC 205 and the giant stream to the south.
    Fardal's models of the stream are collisionless N-body: a satellite falling in, exactly what
    the `minor-merger` archetype does. The disk's ring of dust and the inclination can be set;
    its exact arms cannot. Hubble's panorama covers the northern half of the disk.
15. **Pinwheel.** A lopsided face-on spiral; Linden and Mihos modelled its passage with NGC 5474
    and show the lopsidedness is that tide. Its many arms are gas and young stars as much as
    tides, so the shape can come out, the detail cannot.
16. **Triangulum.** A flocculent spiral that Andromeda may have grazed (McConnachie et al.).
    Flocculent arms are local and change every orbit: no run will put them where Hubble saw them.
17. **NGC 1300.** The classic barred spiral. Sillage's disks grow bars on their own (see
    [calm disk probe](calm-disk-probe.md)), so a bar and two arms are reachable; their pattern
    is the disk's choice, matched by orientation and time, not dictated by a paper.
18. **Sombrero.** A huge bulge and a thin disk seen 6 degrees from edge on, with its dust lane.
    No encounter to compute: a scene that stands still, and a showcase of the bulge and the dust
    web. Flying round it is the point, not the run.
19. **Phantom.** A perfect face-on grand design spiral, isolated. Its arms would be the painted
    ones; Webb's frame is its heart in the infrared. Beautiful, not reproducible.
20. **Hoag's Object.** A near perfect ring round a round core. Its origin is still argued
    (accretion, a merger long ago, or a bar's resonance). Sillage could make a ring that looks
    like it, not the history.

## Pictures and licences

All twenty pictures come from ESA/Hubble and ESA/Webb. Both sites release their images under
Creative Commons Attribution 4.0 International, which allows reproduction and derivatives
without fee, provided the credit is shown clearly and unaltered (esahubble.org/copyright and
esawebb.org/copyright, read on 2026-11-21, no non-commercial clause). Each picture's page and
exact credit are in `catalogue.json`; the files are the agencies' screen size reduced to 1 024 px
on the long side, which is enough to see the shape and to match; the full resolution stays a
link.

Not stored, link only:

- The wide ground views heic0615d (Antennae) and heic0710k (M81 and M82): their credit includes
  the Digitized Sky Survey 2, whose plates carry their own terms. The wide Antennae reference
  stays the Legacy Surveys cutout (CC BY 4.0), as in [the match note](photo-match.md).
- heic0812c, the Antennae by Robert Gendler, a named photographer's work.

The M101 picture combines Hubble with CFHT and NOAO frames; ESA releases the whole under the
same licence with the three credits, kept together in the catalogue.

## After the pick

For each of the three, the recipe is #319's: read the paper again, write the scene file (the
galaxies, the orbit, the moment, the direction, the scale on the sky, the picture and its
credit), check the paper's angle conventions against `Encounter` with a test, run at 200 k and
compare with the paper's figures, `match` against the picture, then the 8 M take, the freeze and
the flight. Tier A objects can follow that recipe as written. Tier B and C objects need a word
in the scene file saying what is set by eye. A deep ground cutout (Legacy Surveys) for each,
fetched on the Mac, is the reference for the match where Hubble's frame is too tight.

## Sources

- Holincheck et al. 2016, "Galaxy Zoo: Mergers", <https://arxiv.org/abs/1604.00435>
  (systems 3, 26, 37, 49, 60, 62 above)
- Karl et al. 2010, <https://arxiv.org/abs/1003.0685>; Privon et al. 2013,
  <https://arxiv.org/abs/1305.5865>; Barnes 2004, <https://arxiv.org/abs/astro-ph/0402248>
- Salo and Laurikainen 2000, MNRAS 319, 377; Theis and Spinneker 2003, Ap&SS 284, 495;
  Dobbs et al. 2010, <https://arxiv.org/abs/0912.1201>
- Horellou and Combes 2001, Ap&SS 276, 1141; Renaud et al. 2018 (a Cartwheel-like ring),
  <https://arxiv.org/abs/1709.02826>
- Renaud et al. 2010, <https://arxiv.org/abs/1009.2740>; Hwang et al. 2012,
  <https://arxiv.org/abs/1109.4161>
- Briggs et al. 2001, A&A 380, 418
- Elmegreen et al. 1995, ApJ 453, 139; Struck et al. 2005,
  <https://arxiv.org/abs/astro-ph/0508660>
- Bournaud and Combes 2003, <https://arxiv.org/abs/astro-ph/0301391>
- Yun 1999, IAU Symposium 186, 81; Oehm et al. 2017, <https://arxiv.org/abs/1701.01441>
- Fardal et al. 2006, <https://arxiv.org/abs/astro-ph/0501241>; Fardal et al. 2013,
  <https://arxiv.org/abs/1307.3219>
- Linden and Mihos 2022, <https://arxiv.org/abs/2206.13219>
- McConnachie et al. 2009, Nature 461, 66
- Brosch et al. 2013, <https://arxiv.org/abs/1307.6368>
