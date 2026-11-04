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

## Open

- Measured on the centres and on past runs only. A batch drawn with it has yet to be explored.
- Stories run longer when more pairs come back, so `STORY_EXTRA` in `explore-batch.sh` and
  `Story.extraShare` may want measuring again on the first night drawn with it.
- A batch started before resumes with the new orbits for the places it has not explored.
