# Sombrero dust, track A: a ring made of parts (#489)

Part of #485. One generator, `references/sombrero/tools/dust_track_a.py`, builds the ring as a sum of
parts, each a 3D density in ring coordinates (radius, azimuth, height) with its own grains; the bench
(`dust_bench.py`, imported, not changed) projects them and lays them on the light. Finalists:
`references/sombrero/dust-tracks/a/f1.json` to `f8.json`. Trials, sheets and frames:
`~/claude-workspace/sombrero/banc/489/` (`trials.csv`, `finalists/fN/`, `contact.jpg`).

```bash
python3 references/sombrero/tools/dust_track_a.py references/sombrero/dust-tracks/a/f1.json seed=2 law=hubble \
    --width 6144 --out f1.png --score f1.json --top f1-top.jpg --panel f1-panel.jpg
python3 references/sombrero/tools/dust_track_a.py base.json --sweep variants.jsonl --csv trials.csv --family veil
```

## The parts, and what each buys

Measured by taking one part out of the finalists' common base (f2, seed 2, 3072 px frame scored on the
6144 grid; summary 2.19 with it, the worst bars after):

| part | what it is | without it | so it buys |
|---|---|---|---|
| speckle | 200 000 small elements (50 pc along, 12 pc radial, 6 pc thick) with lognormal masses (sigma 1.0) | 4.43: shape 6.1, filaments 4.6, blobs 4.5, phase 4.2 | the texture itself: the speckle, the dark knots, the flat-topped phase |
| lognormal width | spk_sig 1.0 against 0.3 | 3.22: spectrum along 4.3, across 3.9 | the power at every scale: narrow masses leave the lane too smooth |
| thin layer | elements 6 pc thick, 5 pc spread | 7.64 at three times thicker: anisotropy 10, spectrum across 9.8 | everything across the lane; 40 pc smears it all |
| inner rim | a scalloped dense band, 0.6 kpc deep from the cut | 2.71: phase 3.7, profile 2.8, edges | the top edge and the dense top of the profile |
| outer radius 9.3 kpc, density rising outward | against 8.8 and a density decaying outward | 2.74 (histogram 3.5) and 2.38 | the tips: they are dark only if dust lies far out, in front of the light |
| m2 (outer part denser towards the tips) | 1 + 0.3 outward cos 2 azimuth | 2.32: profile 2.9, histogram 2.7 | the balance between centre and tips |
| veil | an even lognormal layer | 2.11 | nothing the score sees; kept for the look of an even ground |
| filaments | 12 000 polylines, 0.3 kpc, wandering in pitch and height | 2.17 (f3 against f2) | nothing the score sees |
| cell walls (web) | grains on the walls of a cellular noise | 2.2 to 2.4 (f4, f8) | nothing beyond the speckle; from above, a foam of bubbles |
| sheets | elements in 4 layers 20 pc apart | 2.20 / 2.50 on seeds 2 / 3 (f5) | a little on one seed |
| orbit modulation | elements' masses times exp(0.3 n(azimuth)) along trailing spirals | 2.25 (f6) | nothing on the score; left and right differ more with it |
| outer height (z_out) | the outer part's elements spread 80 pc in height | 2.20 | nothing the score sees |

So, for Pierre: the speckle is the lane's texture, the thin layer is what makes it read as fine
filaments at 6 degrees, the inner rim is the dense top band, the far-out dust makes the tips. The veil,
the filaments as polylines, the web, the sheets and the orbit modulation do not move the score; they
change what one sees (left against right, from above) more than what is measured.

## What failed, and two findings about the score

- **Sand.** With grains drawn at random, the score at 24 M grains is flattered by sand: one setting
  scores 2.04 at 24 M, 2.55 at 48 M, 3.09 at 96 M. `strat=1` gives each element its expected count of
  grains on a shifted low-discrepancy set; the frame then converges by 24 M (2.10 at 24 M, 2.19 at 48 M,
  scores within 0.1 to 96 M). Every finalist is drawn that way. Trials s01 to s19 used random grains.
- **One lucky seed.** Tuned on seed 1, the first base scored 2.05 there and 5.8 and 7.7 on seeds 2 and 3:
  the orbit modulation, with all its power in the longest waves, made the centre dense on seed 1 and
  thin on the others. Band-limited (1.5 to 6 kpc, then 4 to 6) and weaker (0.3), it no longer decides.
  Everything after s18 was tuned on seeds 2 and 3 and checked on 1.
- **Radial spokes.** A modulation of the azimuth alone is a stripe across the whole ring from above;
  read along trailing spirals (15 degrees) it is not.
- Ringlets (long, tightly wound arcs, s07): blobs 7.6 to 12.7. Hubble's strata are not long coherent arcs.
- Wide lognormal masses on random grains (s01-10, s21-b): phase 7 to 19, spiky; sigma 1.0 is the top.
- A thresholded veil (s10): no gain over the lognormal one; a veil carrying most of the mass: 5 to 6.
- More rim mass, or a smoother rim (s08-05/06, s11-05/06): blobs and phase, 2.9 to 4.9.
- The score passes for frames that still look procedural: see below.

## Finalists

Scored at 6144 px (frames rendered at 6144, `share=depth centre=nucleus blur=0.15`, 48 M grains,
`strat=1`), mean over seeds 1 to 3, old colour law; the frames shown are seed 2 with `law=hubble`.

FINALISTS_TABLE

## What the close-ups show that the score does not

CLOSEUPS

## Porting to Swift

The recipe is a function of (radius, azimuth, height) and a seed: the element catalogues are drawn from
the seed (200 000 speckle elements of 2 nodes, 12 000 filaments of 8 nodes: about 7 MB as floats, or
regenerated at load in well under a second); the rim and veil are 4- and 5-octave gradient noises; the
orbit modulation is a sum of a few cosines. Per grain: an element pick (alias table), a lerp along its
nodes and three Gaussian offsets (about 50 flops), or one fBm for the rim and veil grains (about 40
corner gradients); the web, where used, costs a 9-cell cellular noise for each of about five candidate
grains it keeps one of. Grains: the detail converges by 24 M grains in the lane at 4.3 pc a pixel
(f2 scores 11.6 at 1.2 M, 3.9 at 6 M, 2.1 at 24 M, 3072 px frames). The real takes carry 1.2 M dust
grains: they would need about twenty times more in the ring, or grains drawn as splats about four
times wider, which loses the 5 to 10 pc filaments.

## Not verified

The far half and the tips by eye at Hubble's native scale; any Swift or GPU render; the finalists'
colour beyond the lead's `law=hubble`; seeds beyond three.
