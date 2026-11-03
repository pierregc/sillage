# When the painted arms fade

The painted arms and the dust web fade with `DiskState.torn`, the share of a disk's material
still in its layer, and no longer with `disruption` (#210). The cooling, the story and the
director keep `disruption`.

## What was wrong

`disruption` fades the arms once the disk material is three to six times thicker than it
started, as sqrt(sum z^2 / sum r^2) about one plane. A large disk bends long before it tears: its
outskirts warp out of its plane and the whole disk tilts, and about one plane that reads as a
thick disk. On `2026-10-30-b/scene-0031` (two spirals of 5.5 and 4.3 kpc scale length, edges at
20 kpc, pericentre 9.6 kpc at 307 Myr) the thickness criterion fired from 27 kpc apart and the
paint was gone by 284 and 290 Myr. The order criterion never came near: the coherence stayed at
0.92 to 0.97 of its start. Seen edge-on the disks were two thin sheets at an angle, and face-on
their stars still held their arms.

## What the stars do

Measured on the takes' own positions, per stored frame (scripts in the #210 thread):

- the stars' own arms: the log-spiral amplitude, m = 2 to 6 at the best pitch, of the stars still
  in the disk, in the natal plane between 0.5 and 4.5 scale lengths, over all the stars there,
  shot noise taken out, as a share of its level 40 to 100 Myr before the pericentre;
- the share of the disk still in its layer: the disk material inside the edge and within twice
  the layer's thinnest rms height of a plane fitted to its own ring, half a scale length wide.

Fade times, in Myr, where the arms are measurable (the paint at 50 %):

| encounter | pericentre | stars' arms at 2/3, 1/2 | main | this change |
|---|---|---|---|---|
| 2026-10-30-b/scene-0031 disk 0, spiral at 9.6 kpc | 307 | 297, 306 | 273 | 302 |
| 2026-10-30-b/scene-0031 disk 1 | 307 | 305, 310 | 285 | 307 |
| 2026-10-30-b/scene-0044 disk 1, globular at 3.4 kpc | 325 | 335, 339 | 308 | 326 |
| 2026-10-25-night/scene-0031, globular at 0.8 kpc | 265 | 277, 296 | 264 | 292 |

On scene-0044 the measure reads high past 330 Myr: what is left in the layer, a fifth of the
disk or less, carries tidal arms. Its face-on frames show the spiral going between 329 and 336 Myr.

Elsewhere the arms measure does not separate arms from debris or from a collisional ring, so
frames decide. 2026-10-30-b/scene-0044 disk 2 is wrecked at the pericentre, 548 Myr: main faded
it at 538, this change at 548. Where a globular punches a ring into the disk
(2026-10-25-night/scene-0023, 2026-10-30-b/scene-0030 disk 2), main went to half at once and
held there for 40 to 50 Myr; this change fades as the ring grows, at 292 and 671 Myr. While the
companions are further than 30 kpc away, the share stays at 0.93 or above on all fifteen disks.

## The measure

`DiskLayer` lays rings half a scale length wide out to the disk's edge, in the plane of the
axis it is given, and fits each a plane by least squares, so a warp, a tilt or a centre pulled
off the rim's plane is absorbed. `DiskState.foldLayer` takes the rms height about those planes,
keeps the thinnest it has been, and counts the material within twice that height: over the most
it has held, that is `layered`. The arms start to fade at 0.7 and are gone at 0.45, and `torn`
never comes back down. Judged against the thinnest and fullest rather than the first reading,
because a take starts after the settle and a run at its first step: on the same 400 k run of
scene-0031, the solver's live reading and the take's agree within 2 Myr.

The layer needs positions only. A take stores no velocities and none of this, so
`RecordingFile.read` measures it on every take that has disk states (its own, or the curves'
since #198): the first 10 000 disk particles of each galaxy, which the sampler draws one by one,
so any run of them is a fair sample, one contiguous span per frame. Frames run in parallel and
the running state folds them in order: 10 to 25 ms added to a warm read. The solver measures it on
the particles it already walks for the disk state, a second pass over the same sample once the
planes are known. The curves carry `torn_<galaxy>` from now on.

## Limits

- A take without disk states and without curves is left as it was: natal planes, no fade.
- The arms of an old take are still painted in the natal plane (#198); the layer is measured
  in it, which the ring planes absorb up to the tilts seen here, 30 degrees.
- The thresholds were set on these seven takes, all at 2 M or 8 M.
