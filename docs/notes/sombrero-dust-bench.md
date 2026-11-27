# The Sombrero's dust: a procedural sheet and a bench to tune it

The plan for #478's dust. Read [the Sombrero's note](sombrero.md) first
(what was done, the figures, the wrong turns) and [reproducing a galaxy](reproducing-a-galaxy.md)
(the traps). This note is the plan for the one problem left that matters: the dust lane.

## What the lane needs, and what the pictures say

The lane is judged by eye. The criteria, set on 23-24/11:

- The dust reads as **one continuous, cottony cloud layer**, not thin separate concentric threads
  ("spaghetti"), not blots, not tori, with no pattern that repeats around the ring.
- **Thick and dense at the rim, thinning inward**, sparse about halfway in, gone well before the core.
- **No light sources with halos in the lane** (the "garlands"). If stars show through the dust,
  they are small independent points with no halo.
- Not too smooth either: complex, dense and random, yet inside a strict frame (ring radii,
  thickness, width).

The pictures, in `references/catalogue/images/heic2506a.jpg` (Hubble, visible) and
`references/sombrero/images/sombrero-infrared-1600.jpg` (Spitzer + Hubble, the dust's own glow):

- Infrared: a **ring, not a disk**. Inner edge at about 0.56 of the outer edge, densest just outside
  it, fairly flat to about 0.95, falling to nothing at the tip, almost nothing inside the inner
  edge. With the outer edge on Hubble's lane end (8.8 kpc): inner edge about 4.9 kpc, dense band 5 to
  8.4 kpc. Bendo et al. 2006 fit 6.7 kpc, sigma 1.06.
- Hubble, at the frame's figures (`references/sombrero/tools/measure.py`): near lane 0.46 of the
  light left, 0.27 kpc wide, red over green 1.34; **rim solid 0.68** (the share of the near lane at
  5 to 7 kpc darker than 0.7 of the light round it: a veil scores high, separate threads low); far
  lane 0.97. Scene v6 scores 0.44, 0.27, 1.38, rim solid 0.57, far 0.95.

## Why the current dust fails

The v6 scene lays the ring's grains as 700 long threads (`dustRing.threads`, in
`Sources/SillageCore/DiskSampler.swift`), each a few tens of parsecs across, with gaps between them.
Seen 6 degrees from edge on they stack into parallel lines. The look cannot fix it: `dustWidth`
(PR #483) widens the grains into a band but turns the texture into coarse blots, and the dust web
(`dustWeb` 1) ignores it. The fix belongs where the grains are placed.

## The method: density = envelope × noise

Place the ring's grains by sampling a density that is a smooth **envelope** times a **noise**:

- **Envelope** (the frame, from the measured figures): in radius, zero inside about 0.56 of the
  rim, a quick rise, nearly flat to 0.95, a soft fall at the rim; in height, a layer whose
  thickness is largest at the rim and about a third of it inside. Gaussian in height, not a slab.
- **Noise** (the texture): fractal noise (fBm), the sum of 6 to 8 octaves of gradient noise
  (simplex or Perlin), each twice finer and about half as strong; optionally domain-warped (the
  noise read at a position shifted by another noise) for wisps instead of round lumps. Turn it into
  density with a contrast curve, e.g. `max(0, n - threshold)^gamma` or `exp(k n)`, which sets how
  much empty space there is. One seed per galaxy, no period, so nothing repeats round the ring.
- **Shear**: the disk turns differentially (flat rotation, about 350 km/s), so any lump is stretched
  along the orbit within a few Myr. Either evaluate the noise in coordinates already sheared
  (radius, angle + shear × ln r) or let the run do it. Hubble's lane shows that stretched texture.
- A minority of thin threads on top may still help the fibrous look at the rim; their share is a
  parameter to test, 0 included.

Two `dustRing` fields do this on the sampler side: `sheet` (the
share of the ring's grains laid as the continuous sheet, start 0.75) and `cotton` (how uneven, 0 to
1, absent 0.6), the sheet `thickness` at the rim and a third of it inside (PR #481).

## The bench: tune the dust without the galaxy

A full loop (scene, 2 M take, still, crops) costs several minutes and burns tokens. The dust can be
tuned on its own in seconds. Build `references/sombrero/tools/dust_bench.py` (NumPy, Pillow, no GPU):

1. **Background light, once.** Draw the v6 8 M take at Hubble's framing with the dust off
   (`key.sh` with `dustStrength=0`, at 12 Myr, 3072 px wide) and keep it as `bench/light.png`. It is
   the stars without dust. Keep a second one drawn with dust strength 0 from the far side's view if
   the far lane is tuned too.
2. **Grains or a grid.** Generate the dust from the formula above, as particles (the same way the
   sampler will) or as a 3D density grid over the ring; parameters on the command line or in a small
   JSON (envelope radii, thickness at rim and inside, octaves, base scale, warp, contrast, shear, the
   threads' share, seed).
3. **Project.** Rotate into Hubble's view (6 degrees from edge on, roll 5.63 degrees, core at
   (504, 312) of 1024 by 606, 26.5 kpc across) and integrate the column density per pixel, near half
   and far half separately (the far half sits behind the bulge's light, the near half in front: for
   a fair lane, attenuate only the share of the light that lies behind the dust; a first bench can
   take the near lane's light as half behind).
4. **Attenuate.** transmission = exp(-k N), stronger in blue and green than red (the reddening of
   `look.dustReddening` 2), multiplied onto `light.png`.
5. **Show.** The full frame, then `closeup.py`'s crops (the lane's left end and under the core)
   **beside Hubble's at the same scale**, labelled in French ("Hubble", "Banc", the
   variant), and the `measure.py` figures (lane depth, width, colour, rim solid) on each.
6. **Grids.** One call draws a sheet of 6 to 12 variants over one or two parameters, under a minute.

What the bench is not: the renderer's dust is splatted grains, not an exponential column, and the
run moves the grains. So a variant that wins on the bench is then checked in Sillage proper: the
sampler fields, a 2 M take 0 to 15 Myr, the still at 12 Myr and the same crops. If the two disagree,
calibrate the bench's `k` and kernel on that one take and keep going on the bench.

Optional, if a section is enough: the bench can draw only the left half of the lane or only the
part under the core, at full resolution, for a faster look.

## Steps

1. The bench: `dust_bench.py`, the light image, the crops and the figures. As a first check it
   reproduces v6's lane from the v6 sampler's own grains (near 0.44 / 0.27 / 0.57).
2. Grids on the bench over envelope, octaves, warp, contrast and the threads' share; two or three
   candidate sheets, with the winning parameters as JSON.
3. An independent scoring of every sheet against Hubble, on the figures and on the criteria above
   (threads visible? halos? repetition? edge too sharp?), and a review of the sampler and bench
   code.
4. The winner ported into the sampler (`DiskSampler.swift`, the `sheet` and `cotton` fields or
   their successors, with tests), checked at 2 M as above, its crops compared with the bench's.
5. Once that sheet is accepted: the 8 M take, the photo, the flight stills, the 4K film.

Images for sheets go on the orphan branch `assets/478-sombrero`.

## Done when

- The lane reads as Hubble's on the left-end and under-core crops, by eye.
- Figures at 12 Myr within reach of Hubble: near lane 0.42 to 0.50 of the light left, width 0.22
  to 0.32 kpc, rim solid 0.62 to 0.75, red over green 1.25 to 1.45, far lane 0.95 or more.
- No halo around any light in the lane; no repetition visible round the ring.
- The texture holds to the flight's last close pass (18 Myr); later it may wind, seen from far.
