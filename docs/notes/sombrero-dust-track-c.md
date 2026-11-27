# Sombrero dust, track C: clouds wound by differential rotation (#491)

Part of #485, wave 2. The ring is a list of clouds, not a noise formula:
`references/sombrero/tools/dust_track_c.py` (generator, render through `dust_bench`, score, trial log),
finalists in `references/sombrero/dust-tracks/c/f1.json` to `f8.json` (each holds its command).
Output, not in git: `$SOMBRERO/banc/491/` (`trials.csv`, `trials/`, `finalists/fN/`,
`contact.jpg`). Wave 2 settings throughout: `share=depth centre=nucleus blur=0.15`, 24 M grains.

## The generator

Each cloud has a birth place (radius, azimuth, height), a mass (power law, alpha 1.8 over a range of
300), an in-plane size `s0 m^0.4`, a height `qz s` with a cap, an age, and a fixed hierarchy of
sub-clumps (4 a level, 2 levels, each 0.4 of its parent, masses log-normal). A grain picks a cloud, a
path down its hierarchy, its offset, and is then wound for the cloud's age at its own radius:
azimuth + Omega(R) age. Curve: flat, 350 km/s (a turn in 123 Myr at 7 kpc), or v ~ R^0.3 for f6.
Births: a scalloped inner rim, a body out to the rim, a log-normal intensity along the orbit, clouds
gathered in complexes. Holes: bubbles push the older clouds inside them to the shell, then the shell
is wound with the rest, and new clouds are born on it. `dust_bench`'s `myr` rotates every grain of a
grain file by its own v / r, all at one age; per-cloud ages need the winding done here. Everything is
a function of (radius, azimuth, height) and a seed.

## What the search found

214 rows in `trials.csv`: 190 search trials (166 screened at 3072 px and scored on the 6144 grid, 24 at
6144) in 17 families, plus 3 seeds of each finalist at 6144. More than the 150 asked for, because the
6144 check overturned the 3072 ranking (see sampling).

- **Ages (the track's question).** With everything else fixed (3072): ages up to 20 Myr 3.02, to 40
  3.04, to 80 3.49, to 150 4.33, only 200-500 Myr 5.9. Long arcs make ridges too long (filament length
  at the 90th percentile 34 against 22 log-pc units), too many 1 px ridges, and Minkowski perimeters
  too high. A single generation is best almost unwound. The exception came at 6144 once sampling was
  fixed: young clouds plus **15 % old arcs (100-300 Myr)** rank first (f1, 3.42 over three seeds,
  against 3.77 for the same clouds alone). The arcs add the coherence along the lane that young clouds
  lack. At 25 % or more the arcs fail on filaments and Minkowski. The crossing pitches did not make a
  web: at 6 degrees an arc of any age projects within 2 degrees of the lane.
- **Thin layer of flat clouds: refuted by the score.** Flat clouds (5-20 pc thick, 50-200 pc wide)
  project as horizontal streaks. Hubble's dark blobs are 2.1 to 1, which needs a cloud's height to be
  about half its length. Tall, young clouds (`qz` 0.5-1, 20-40 pc high) took the summary from 4.5 to
  3.6. The layer of centres stays thin (8 pc at the inner cut), flaring to about 55 pc at the rim.
- **Cloud laws.** Power law, alpha 1.8 to 2.2 over 300, size 20 pc m^0.4 (20 to 200 pc in the
  plane), growing ×2 towards the rim. Log-normal masses were worse (blobs). Bigger clouds (`s0`
  0.05-0.08) failed filaments and Minkowski. Without uneven sub-clumps (`subsig` 0) blobs went to 19:
  the hierarchy is what makes the speckle.
- **Holes and shells.** Neutral (2.94 to 3.19 against 3.02). At this resolution a shell of clouds looks
  like any other clouds and links nothing into a web.
- **Clustering.** Strong clustering along the orbit (1.5 kpc stretches, 0.3 kpc complexes) made the
  lane patchy: stationarity and strata +3 spreads, gaps that Hubble does not have. 8000 complexes of
  80 pc with a weak intensity (0.3) work.
- **Envelope.** Rim 9.8 kpc, not 8.8. With a thin layer each pixel of the tips' core rows maps to
  radius 7.8-10 kpc. A rim at 8.8 left the tips too light (histogram 5-6, stationarity +11 spreads),
  and moving it to 9.8 halved both. Inner cut 5.8 kpc, shifted 0.2 kpc away from us (near side 6.0,
  far 5.6, after #495's 5.9 against 5.5), flat body, faded over its last 1.5 kpc. This contradicts the
  planned 8.8: either the outer dust is thicker than this flare, or there is dust past 8.8.
- **Sampling.** Grains of very unequal weight left 1 px "ridges" of sand at 6144. The 3072 screen
  could not see them: 2.94 at 3072 became 4.59 at 6144. Drawing each sub-clump in proportion to its
  mass (`pick` 1, equal-weight grains) brought filaments from 6.4 to 3.6.
- **Dropped:** a diffuse share (blobs, spectrum), hub-and-branch clouds (no gain, and stray dotted
  trails above the lane, see f8), radial bands for strata (strata fell but phase rose), stronger flare.

## Finalists (6144, default colour law, mean of seeds 1-3)

| | recipe | summary (seeds) | phase | worst bars |
|---|---|---|---|---|
| f1 | young clouds + 15 % old arcs 100-300 Myr | 3.42 (3.18, 3.40, 3.67) | 1.9 | Minkowski 4.2, histogram 4.0, filaments 3.9, multiscale 3.7 |
| f2 | young clouds, holes and shells, corrugation, sharp cloudlets | 3.45 (3.27, 3.49, 3.60) | 1.8 | filaments 4.1, multiscale 4.0, histogram 4.0 |
| f3 | young clouds (0-20 Myr), sharp cloudlets | 3.77 (3.42, 3.94, 3.94) | 2.2 | filaments 4.8, Minkowski 4.6, multiscale 4.0 |
| f4 | holes and shells, Gaussian cloudlets | 3.92 | 2.4 | filaments 5.1, Minkowski 4.9, histogram 3.9 |
| f5 | sheared 0-40 Myr, flat curve | 3.94 | 2.3 | Minkowski 5.0, filaments 5.0, histogram 3.9 |
| f6 | sheared 0-80 Myr, rising curve | 3.99 | 2.1 | filaments 5.1, Minkowski 5.0, blobs 3.8 |
| f7 | holes and shells, alpha 2.2 | 4.13 | 2.3 | Minkowski 5.5, filaments 5.1, histogram 3.8 |
| f8 | hub-and-branch clouds | 3.99 | 2.0 | Minkowski 5.3, filaments 4.9 (stray trails: shown last) |

With `law=hubble` (#500, seed 1; inner cut read as `r_in` 5.8 kpc, `inner` = r_in / rim in the bench):
f1 3.24, f2 3.32, f3 3.48, f4 3.79, f5 3.71, f6 3.88, f7 3.85, f8 3.79. Colour (not summed) falls
from 4.4-4.9 to 2.6-3.2. The grey band falls where Hubble's is, on the top storey: these rings have a
dense inner rim. It reads as a charcoal band, a little thicker than Hubble's grey-blue one. Those
frames (`frame-6144-hubble-law.png`, `closeup-hubble-law*.jpg`) and `contact.jpg` are the ones to show.

None reaches the pass line (2.3). Phase passes everywhere (1.8 to 2.4) and the spectrum along passes
(0.6 to 1.3), so this is not Gaussian-phase noise. What resists:

- multiscale (3.4 to 4.0): fine speckle not tied to the coarse structure enough;
- filaments and Minkowski (3.9 to 5.5): too many short thin ridges, fragmented tips;
- histogram (about 4): the centre still too dark (median 1.41 against 1.14), the tips too light (0.61
  against 0.99);
- skewness (3.4) and stationarity (about 3).

Measured on seed 1: near lane 0.57 left (Hubble 0.46), rim solid 0.60-0.69 (0.81). Far line at 0.47
(0.45), but 0.17 wide (0.09) and 0.050 deep (0.039).

By eye (close-ups): the lane reads as brush dabs, flakes of dust, not Hubble's thin dark web. The two
storeys are missing (the dense grey-blue top band over an orange zone crossed by filaments). The
lane runs lower than Hubble's (the rim at 9.8). The tips are broad fluffy fans, and the right one is
not narrower or darker. The far half is a faint line at the right height but broad at the sides.
Top views: a dense knotted inner rim and a mottled body, no spokes. f8 shows a few short dark
dashes there, the same stray branches. f1 comes first. It is the most varied along
the lane and the one track C idea that helped. What still separates it from Hubble is the web of
crisp 5-10 pc filaments and the dense top band; the second likely needs a separate rim component
(track A's idea).

## Swift port

Per grain: pick a cloud from a prefix table (or an alias table), 2 levels × (4 weight hashes + 3
Gaussian hashes), one leaf Gaussian, two Omega(R) evaluations: about 20 hashes, some 200 flops.
Corrugation (f2) costs 48 cosines a grain, or a 256 × 4096 table (4 MB), or can be dropped (it was
neutral). Stored: the cloud table, 200 k clouds × 8 floats = 6.4 MB, or rebuilt from the seed in
milliseconds (rejection sampling and a loop over 1000 bubbles). The detail needs about 24 M grains,
because each cloud's 3-8 pc cloudlets need tens of grains. At today's 1.2 M dust grains a cloud gets
about 6 and the pattern turns to sand. A port should instead draw the 3.2 M level-2 sub-clumps
(200 k × 16) as anisotropic Gaussian splats, with the same table. Not verified: any Swift or GPU
render, flight behaviour, more than three seeds.
