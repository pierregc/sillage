# Sombrero dust, track B: Hubble's statistics imposed on the 3D field (#490)

Code: `references/sombrero/tools/dust_track_b.py`. Finalists: `references/sombrero/dust-tracks/b/`.
Trials, frames and sheets: `~/claude-workspace/sombrero/banc/490/` (`trials.csv`, `finalists/`,
`contact.jpg`). Read with `sombrero-dust-sheet.md` (the bench, `texture.py`) and the brief of wave 2.

## What was built

- **The exemplar.** Hubble's near-lane opacity map from `texture.py` (6144 grid, 4.3 pc a pixel, point
  sources removed), centre (|u| < 4.7 kpc) and tips apart, rows 0.28 kpc under to 0.18 kpc over the centre
  line (where the lane holds dust).
- **Sky to ring.** The bench's projection maps the plane one to one onto the sky for a thin layer, sky
  (u, sy) = (x + dx, y sin 6 + dy), so the near half of Hubble's band IS a patch of the plane, 4.3 pc
  along x by 41 pc along y. `deproject` reads it there; laid back through the bench as 24 M grains on a
  2 pc layer it scores 1.73 at 6144 (the pixel-exact round trip of #487 is 1.08; the rest is the grain
  path's resampling). That is the ceiling of the thin-layer reading.
- **Local one-point statistics.** Hubble's opacity quantiles by window along the lane (1.875 kpc, 8
  windows) and sky row (4.3 pc, smoothed over two rows): 8 x 179 x 65 numbers. A texture's rank, cell by
  cell, is turned into opacity through the quantiles of the sky place the cell takes on the near side (the
  far half reads its mirror image, 0.85 kpc further out at theta 90, so its inner rim lands on the far
  line). The exemplar is gaussianised through the inverse of the same map, so the two cancel on Hubble.
- **Carriers.** `cart`: the texture lies on the plane in (x, y), cells 4.3 pc by 41.3/c pc. `polar`:
  (azimuth, radius). `c` > 1 makes the plane texture c times shorter in radius than the sky implies, and
  the layer's thickness (`sz0`, `sz1`) or a corrugated mid-plane (`corr`) must give back the across-lane
  structure.
- **Syntheses.** Statistics only: `gauss` (random phases, the gaussianised exemplar's spectrum and
  histogram), `hb` (Heeger-Bergen: a complex steerable pyramid, 6 octaves x 4 orientations, every band's
  histogram matched), `ps` (also, as Portilla and Simoncelli, the magnitudes' histograms `mag`, their
  correlation with the parent band `corr`, and the relative phase with the phase-doubled parent `rel`,
  each imposed by projection; `keys` picks which). The tips get their own statistics (measured on |u| >
  4.7) and blend in over |x| 4.2 to 5.2 kpc. Exemplar (Hubble's pixels, labelled so): `zquilt`
  (Efros-Freeman quilting of the gaussianised exemplar, 64 px blocks, mirrored at random, one candidate
  among those within `tol` of the best overlap), `quilt` (radial blocks of the de-projected map placed
  round the ring), `paste` (the de-projected map in place, near half only, a reference).

## The hypothesis, tested

"The layer is thin, so across the lane is radius": **right for the sky, wrong from above.**

- On the sky it is the only reading the score accepts. Every lift away from it costs: with a Gaussian
  texture at 3072, c = 2 scores 3.3 to 3.7 against 2.6 at c = 1, c = 4 scores 4.3 to 7.2, a corrugated
  mid-plane 11; a flare to 6 pc at the rim 2.9 against 2.3; the polar carrier (texture following the ring)
  8.6, the radial quilt 8.6 (see below). At 6144 a mild lift is free: c = 1.5 with a 3 pc layer scores
  1.68 to 1.71 on three seeds, better than c = 1; c = 2 scores 2.11, c = 3 3.0.
- From above the thin reading draws **streaks along our line of sight, not radial spokes**: Hubble's
  across-lane speckle (correlation 22 pc on the sky) becomes 210 pc in y against 50 pc in x, at every
  azimuth, the same direction (`top-zoom.jpg` of any c = 1 finalist; `look/deproj-top20.jpg` in the output folder for Hubble's own
  map). A plane texture would not line up with the observer: the fine across-lane structure is not radius.
  At c = 1.5 the streaks are 1.5 times shorter; c = 2 to 4 (round clumps from above) is what a real
  ring would want, and the score refuses it at the bench's resolution.
- Radial blocks carried round the ring (`quilt`, `polar` carrier) score 8.6: placed at another azimuth,
  the line-of-sight streaks of the source turn with the ring and show as tilted streaks on the sky (the
  shape index bar 12 to 16). The texture is tied to the view; that is the same finding.
- **The tips.** Hubble's lane is flatter than a 6-degree circle: its centre line de-projects to 6.6 kpc
  at the near side and 8.4 kpc at u = 6.5, and nothing shows near the major axis at the tips. Three
  readings: an oval ring (the local quantiles do this by themselves: from above the ring is two crescents
  with gaps at the tips, `top.jpg`); a warp (a round ring whose mid-plane sinks 0.2 kpc at the tips,
  Fourier fit of order 4, residual 5 pc; it costs the bench's tips their contrast, 2.4 to 4.2 at 3072,
  because dust lower at the tips has more of the light model in front of it); a round flat ring with a
  profile by radius (the bench's depth shares hide the tangent region; 2.48 at 6144, histogram 3.3).

## Which statistics matter

Map screens (thin layer read straight into lane coordinates, no bench; `trials.csv` rows `S`, width 0),
summary against Hubble at 6144:

| | summary | worst bars |
|---|---|---|
| Gaussian phases, spectrum and per-radius histogram (round ring) | 3.6 to 4.2 | profile, skewness |
| the same with local quantiles (8 windows x sky row) and the tips' own spectrum | 1.95 to 2.38 | multiscale 2.5, skewness 2.5 |
| local quantiles in 0.94 kpc windows / 3.75 / 7.5 / one window | 1.85 / 2.0 / 2.25 / 2.04 | 0.94 copies Hubble's strata; wide windows lose edges, intermittency |
| no separate statistics for the tips | 1.85 against 1.78 | shape 2.5 |
| + Heeger-Bergen band histograms | 2.05, 2.31 | multiscale, skewness |
| + magnitude histograms only / parent correlation only / both | 2.09 / 2.17 / 2.2 | no gain |
| + **relative phase with the parent band only** | **1.52 to 1.78** (3 seeds) | multiscale 1.9 to 2.4 |
| + all of P-S's (rel, corr, mag) | 1.81 to 1.87 | phase, skewness |

1. **Where the dust is, by place**: the one-point statistics as a function of position along and
   across the lane (local quantiles). They carry the profile, the dense top band, the depth, and the
   left-right difference; with them a Gaussian-phase field goes from 3.6 to 2.0. They are not the
   picture: 8 windows of 1.9 kpc; at 0.94 kpc they start to copy Hubble's strata.
2. **The relative phase between scales** (a band against its phase-doubled parent, P-S): the only
   pyramid statistic that helps every seed (0.2 to 0.5); it is what puts fine dark speckle on the
   coarse structure's edges. Magnitude statistics (correlation with the parent, histograms) and band
   histograms add nothing on this score.
3. **The tips' own statistics**: a little (shape).
4. Through the bench at 6144 the families sharing a seed land within 0.05 of each other (seed 3: gauss
   1.67, hb 1.68, ps 1.67, ps-rel 1.65): the syntheses start from the same Gaussian field and change it
   little; the seed moves the score more (0.5) than the family. What still separates every one of them from
   Hubble: `multiscale` (entre échelles, 1.9 to 2.5), the spectrum across (2.0 to 2.3) and anisotropy (2):
   too little coupling of fine speckle to coarse structure, and too few long thin filaments.

## Finalists

Scores at 6144 (`share=depth centre=nucleus blur=0.15`, 24 M grains), the old colour law, one row per
seed; `law=hubble` is the drawing Pierre sees (column re-derived from the same opacity field through the
new law, inner cut 5.32 kpc = `inner` 0.6045 x `rim` 8.8, the near band's top edge). Colour is not summed.
Pass line: summary under 2.3, no bar over 3, phase under 3.

| | recipe | kind | seeds 3 / 2 / 1 | mean | worst bars (seed 3) | `law=hubble` (seed of the folder) |
|---|---|---|---|---|---|---|
| f1 | `ps` relative phase only, c 1.5, layer 3 pc | statistics | 1.71 / 1.68 / 1.69 | **1.69** | phase 2.0, spectrum along 2.0, multiscale 2.0 | 1.64 (multiscale 2.0) |
| f8 | `zquilt` tol 0.5, c 1.5, layer 3 pc | EXEMPLAR | 1.74 / 1.74 / 1.83 (s3, s1, s2) | 1.77 | spectrum along 2.1, across 2.0, multiscale 2.0 | 1.69 |
| f7 | `zquilt` tol 0.5, c 1 | EXEMPLAR | 1.76 / 1.98 (s1, s2) | 1.87 | spectrum across 2.3, intermittency 2.2 | 1.72 |
| f5 | `gauss`, local histograms, c 1 | statistics | 1.67 / 1.87 / 2.27 | 1.94 | multiscale 2.2, spectrum across 2.0; s1 phase 3.1 | 1.66 |
| f2 | `ps` relative phase only, c 1 | statistics | 1.65 / 1.82 / 2.61 | 2.03 | spectrum across 2.1, anisotropy 2.1; s1 phase 3.6 | 1.62 |
| f3 | `hb`, c 1 | statistics | 1.68 / 1.88 / 2.55 | 2.04 | spectrum across 2.1, anisotropy 2.0; s1 phase 3.5 | 1.67 |
| f4 | `ps` rel, corr, mag, c 1 | statistics | 1.67 / 1.82 / 2.65 | 2.05 | anisotropy 2.1, spectrum across 2.1; s1 phase 3.6 | 1.64 |
| f6 | `gauss`, round ring (profile by radius) | statistics | 2.48 / 2.95 (s3, s1) | 2.72 | histogram 3.3, multiscale 2.9 | 2.49 |

All but f6 pass the line on their folder's seed and on average; f1 and f8 pass on every seed. Seed 1 breaks
the phase bar for every c = 1 recipe and for none of the lifted ones. Far half (bench figures, Hubble 0.45 /
0.09 / 0.039): offset 0.36 to 0.39, width 0.19 to 0.24, depth 0.036 to 0.039; f6 0.42 / 0.47 / 0.030.

**First for Pierre: f1**, statistics only, best on every seed, and the least streaky from above of the
statistics-only rings. f8 beside it as the ceiling: Hubble's own (gaussianised) pixels quilted score
about the same, so on this score the statistics have caught up with the exemplar; what separates both
from Hubble is seen, not scored (below).

## Constraints the score does not see

- **Up close they look procedural** (`finalists/fN/closeup*.jpg`, `look/f1-law-zoom.jpg`): soft mottled
  speckle in horizontal smears, few crisp thin filaments, a straight ruled top edge, no scalloped clumps on
  the dense band. They pass the line anyway: a finding about the score. Part of the softness is the bench's
  grain path: Hubble's own map pasted in place (1.73) is visibly softer than Hubble too
  (`look/cmp3-zoom.jpg`). `law=hubble` gives them the grey-blue top band over orange, in the right place.
- **Seeds share a look.** The families start from the same Gaussian field and the iterations change it
  little: f2, f3, f4, f5 are near twins on the contact sheet. They differ from one another less than from a
  second seed.
- **Tips.** The near lane's tips follow Hubble's height and profile by construction (local histograms by
  sky place), but the left tip is narrower than Hubble's fanned one, with a thin separate streak above it:
  the far half's mirror seen over the near lane. f6 (round ring) has the broadest, most mottled tips, the
  closest in character to Hubble's left tip, but too light (histogram 3.3).
- **Far half**: a faint thin line where Hubble has one, near-invisible over the core, a straight edge; no
  grey slab. It is twice Hubble's width (0.19 to 0.24 against 0.09; `far_scale`, a thinner far profile,
  did not change it).
- **From above** (`top.jpg`, `top-zoom.jpg`): f1 to f5, f7, f8 are two crescents (the oval the tips ask for
  leaves gaps at the major axis) with streaks along y; c 1.5 shortens them by a third. f6 is a round ring,
  same streaks. None looks like a galaxy's dust ring up close; c 2 to 3 would (2.11 and 3.0 at 6144).
- **Left and right differ** (the local histograms are Hubble's by window; symmetry bar 0.2 to 0.6), and
  nothing repeats (the ring is one non-periodic texture; quilting draws among all candidates within 50 %
  of the best seam).

## Port to Swift

Every finalist is a stored field; the syntheses (pyramid iterations, quilting) stay offline in Python.

- **Stored data.** The texture's rank on its carrier, 8 bits: 536 x 5120 cells at c = 1 (2.7 MB), 804 x
  5120 at c = 1.5 (4.1 MB), 1072 x 5120 at c = 2 (5.5 MB); the tips' texture is blended in already. The
  local quantile table, 8 windows x 179 sky rows x 65 quantiles (93 k values, 190 kB in half floats). Or,
  simpler and larger, the final opacity on the polar grid, 312 x 21504 half floats (13 MB).
- **Per grain.** One bilinear fetch in the texture at (x, y / (41.3 pc / c)), the grain's sky window and
  row on the near side (one line of the projection formula, the far half mirrored and shifted 0.85 kpc),
  one trilinear fetch in the table, the opacity turned into a column by a 1D table (a_to_n, per colour law).
  A few ns a grain; no noise evaluation.
- **Grains.** The detail lives in 4.3 pc x 41 pc cells on a 2 to 3 pc layer; the bench needs 24 M grains to
  carry it at 6144 px. At the takes' 1.2 M grains the lane would be sand: drawing grains where the field is
  dense (importance sampling) buys about a factor of two. A take would want 10 M or more dust grains, or the
  field drawn as a texture rather than as grains.
- **In a flight.** The field is a function of (x, y) and radius only, on a layer 2 to 3 pc thick: from
  inside the layer it is a painted sheet, and from above it shows the streaks along y described above.
  The exemplar finalists carry Hubble's pixels (gaussianised, quilted): ESA/Hubble's CC BY 4.0 credit applies.

## Dropped

- The warped mid-plane (round ring, centre line by height): good from above, the bench's tips lose
  their contrast (light model in front of the low dust).
- Corrugated mid-plane (folds of a thin sheet) and thick layers: the sky loses its sharp speckle (8 to 11).
- The polar carrier and the radial quilt: the line-of-sight streaks turn with the ring (8.6).
- A per-window jitter of the profile to rag the straight top edge: it tears the texture vertically (2.1
  to 2.7 against 1.5).
- The column calibrated by the local share of light behind (`calib=share`): the tips saturate and turn
  red (4.6 at 3072).
- Quilting blocks of 128 px (taller than the exemplar's 107 dusty rows) and 32 px (3.7 at 3072).
