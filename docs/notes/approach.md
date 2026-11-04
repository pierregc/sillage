# How fast a companion comes in

Pierre asked whether the exploration varies how fast two galaxies meet, and whether they only
run into each other head on or can also come in on offset orbits and turn round each other,
which he finds the more beautiful of the two (#252).

## What the draw did

The free draw varied speed only through the eccentricity, 0.7 to 1.6 for a large companion and
0.8 to 2.2 for a dwarf or a globular, drawn apart from the pericentre (2 to 30 kpc, 1.5 to 20).
Far out a hyperbolic pair moves at sqrt((e - 1) M / q), so one draw of e is a 1 100 km/s pass
at 2 kpc and a 300 km/s one at 30. Read back from the 96 distinct scenes explored on 2026-10-24,
10-25, 10-30 and 10-30-b, from their scene files and `curves.csv`, the first encounter of each:

| first encounter | scenes | came back or merged | ended far apart | mean score |
| --- | --- | --- | --- | --- |
| bound | 24 | 18 | 0 | 0.74 |
| parabolic | 8 | 4 | 0 | 0.77 |
| under 250 km/s far out | 15 | 2 | 6 | 0.68 |
| 250 to 500 km/s | 27 | 4 | 19 | 0.70 |
| over 500 km/s | 22 | 0 | 21 | 0.69 |

"Came back" is a second dip of the separation in the run, or less than 30 kpc apart at its
end; "far apart" more than 100 kpc at the end. Of the 70 free scenes half came in faster than
300 km/s far out, the median at 307, where pairs and groups meet at a few hundred; one in five
was bound, and one in eleven had been drawn bound and opened to parabolic by the placement. The
scenes rated 9 or 10, or kept, were mostly the slow ones: the Antennae, a polar ring that had
been opened to parabolic, a pair at 271 km/s.

Head on was there: a large pair passes as close as 2 kpc, well inside both disks. A truly
radial passage only comes from `ring` and the black hole's plunge.

## What it draws now

The eccentricity's axis is the approach (`FreeDraw.orbit`):

- **Two in five captured.** A bound orbit by its apocentre, 25 to 60 kpc by Kepler and at least
  one and a half pericentres, its first passage in the first fifth of the clip so the pair has
  room to come back round.
- **Three in ten falling in from rest or nearly,** 0 to 120 km/s far out. Under 120 the live
  halos explore runs with bring the pair back: of the hyperbolic passes above, only those under
  about 100 km/s came back within the run.
- **The rest fast,** 120 to 900 km/s far out, logarithmic, with the pericentre held under
  4 500 kpc km/s over the speed: 30 kpc at 150 km/s, 5 at 900. A fast pass far out barely
  touches either disk; close in it is the splash and the rings.

The eccentricity is what the placement still reads, with M the two masses as it weighs them,
the companion's taken from its primary. The stream is consumed in the same order as before, so
a batch keeps every galaxy it drew and only the orbits move; which point a place takes can
still change, since the signature reads the approach where it read the eccentricity.

## A captured pair stays captured

Explore asks for a first passage 230 to 600 Myr after the start, and a bound orbit has to fall
in from its apocentre for that long, or the passage asked for would be a second one. One that
cannot used to be opened straight to e = 1. `placeEncountersGivingWay` now first widens it, its
distance to one shrunk by a quarter up to eight times (0.6 comes to 0.96), and opens it only
past that. Each widening is one backward construction, a millisecond for a pair. On a model of
the pair alone in its live potential, with the explore timing, 300 captured draws of two large
galaxies: 28 % need no widening, 38 % one, 23 % two, 11 % three; half the apocentres land
between 54 and 69 kpc, and half the second passages, without the friction of the live halos,
between 0.94 and 1.14 Gyr after the start. In the runs above the halos brought bound
pairs back far sooner, 140 to 300 Myr after the first passage at 7 to 17 kpc.

The archetypes drawn bound gain from it too: the polar ring rated 10 on 2026-10-30-b had been
opened to parabolic.

A generated scene is placed twice, once when it is drawn and again for the clip it is explored
in, and the eight widenings hold for each placement: place 20 of batch 20261105 was widened ten
times in all, 0.90 to 0.994.

## Measured

Batch 20261105, places 0 to 59 as `explore` draws them (`--check-only`, 200 000 particles,
`--dt-scale 3.5 --settle 400 --steps 3600`), main against this change:

| | main | approach |
| --- | --- | --- |
| first passage bound / parabolic / hyperbolic, 58 places | 11 / 6 / 41 | 25 / 3 / 30 |
| free scenes bound, of 43 | 5 | 18 |
| speed far out, unbound: Q1 / median / Q3 / max, km/s | 140 / 279 / 516 / 1 144 | 71 / 135 / 359 / 809 |
| under 120 / 120 to 300 / 300 to 500 / over 500 km/s | 9 / 16 / 10 / 12 | 15 / 7 / 4 / 7 |
| drawn bound: kept / widened / opened to e = 1 | 11 / 0 / 6 | 13 / 12 / 1 |
| refused by the sanity check | 0 | 0 |

The three parabolic first passages of the change are slow falls, under 10 km/s far out. The
polar ring of place 47, drawn at e 0.56, was opened on main and stays bound at 0.67. Ten fast
passes of 43 free scenes where the share is three in ten: a batch's worth of noise.

The one bound orbit still opened is in a group of four, place 25: its captured pair 0-1 is
not too short for its time, but the pair turns galaxy 0 round their common centre, so galaxy 2,
hyperbolic and stepped back from that moving primary, seems to make a second passage. Widening
only touches bound orbits, and the fallback then opens them all. Opening only the failing orbit
changed nothing over the 60 places. Only groups meet it.

Explored on the GPU, the first 12 places at 50 000 particles a galaxy, `explore-batch.sh`'s
own settle of 750 steps, none refused:

| place | drawn | first encounter | approach, km/s | passes, Myr | apart at the end | score |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | free, disk and spiral | 3.3 kpc, e 1.002 | slow, 46 | 456, 609, 640 | merged | 0.84 |
| 2 | free, spiral and disk | 4.6 kpc, e 1.012 | slow, 96 | 553, 845, 913 | merged | 0.62 |
| 3 | minor-merger | 10.7 kpc, e 0.66 | bound, 311 | 336, 544, 637 and five more | merged | 0.76 |
| 4 | free, two spirals | 7.6 kpc, e 0.75, widened once | captured, 365 | 335, 451 | merged | 0.72 |
| 5 | free, group of five | 8.8 kpc, e 0.72, widened twice | captured, 231 | 387, 760 | 251 kpc | 0.58 |
| 6 | free, spiral and disk | 15.0 kpc, e 1.002 | slow, 21 | 631, 1 396, 1 532 | merged | 0.72 |
| 7 | ring | 1.5 kpc, e 1.14 | fast, 534 | 441 | 126 kpc | 0.66 |
| 8 | free, elliptical and dwarf | 14.3 kpc, e 0.56 | captured, 262 | 312, 827 | 24 kpc | 0.56 |
| 9 | free, elliptical and globular | 13.2 kpc, e 1.000 | slow, 8 | 458 | 9.9 kpc | 0.09 |
| 10 | free, one disk | | | | | 0.14 |
| 11 | mice | 8.5 kpc, e 1.037 | 135 | 473, 746, 793, 820 | merged | 0.99 |
| 12 | free, spiral and dwarf | 1.9 kpc, e 0.945, widened twice | captured, 260 | 407, 525, 597 | merged | 0.66 |

Every captured free pair came back: three merged, the dwarf of place 8 passed again 515 Myr
later, and the dwarf of place 5 came back to 13 kpc before, torn apart, it left while galaxy 4
merged with the primary. Three slow pairs of four came back and merged, place 6 765 Myr after
its first passage, its story running to 1 890 Myr; the globular of place 9 swung out to 92 kpc
and was back at 9.9 when the run ended. None of these twelve was a fast free pass; the ring
stood for them.

## Open

- Stories run longer when more pairs come back, so `STORY_EXTRA` in `explore-batch.sh` and
  `Story.extraShare` may want measuring again on the first night drawn with it.
- A batch started before resumes with the new orbits for the places it has not explored.
