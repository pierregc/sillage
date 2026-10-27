# Scoring a palette, and the Auto palette

`PaletteScore` (#112) gives a palette from the generator (#111) a number from 0 to 1 without
drawing anything: the colours decide. `PaletteAuto` draws 48 candidates from the scene's seed in
the chosen world and keeps the best, so a scene always gets the same Auto palette. The score of
a palette on rendered frames is #124.

## The parts

Each part is 0 to 1; the total is their weighted mean.

| Part | Weight | What it measures |
| --- | --- | --- |
| separation | 0.30 | Smallest OKLab distance between two galaxies' colours at the common lightness 0.8 (the shader divides every tint by its luminance, so lightness does not show). 0 at none, 1 from 0.08, which is 1.6 times the generator's floor of 0.05. |
| harmony | 0.20 | Mean miss in degrees between the hues and the harmony's anchors, over every wheel turn that puts one colour on its anchor and every spread the generator draws (22 to 40). 1 at none, 0 at 30. Colours too grey for a hue are left out. |
| range | 0.15 | Per colour the lesser of lightness (0 at the generator's 0.72 and 0.96, 1 from 0.05 inside), chroma (0 at the grey floor, 1 from 0.03 above it, down to 0 at the 0.19 cap) and a flag for gamut and peak. Monochrome may be grey. |
| balance | 0.10 | One minus the absolute mean of cos(hue - 50°): orange is warm, blue is cool. One galaxy has nothing to balance. |
| reference | 0.25 | Telescope world only: mean distance of each colour, at the common lightness, to the nearest tone of its own family's set from #125 (the whole of them for a family that is not a set). 1 at none, one half at 0.035. |

Without the reference part (the free world, or no files) the other four are renormalised.

## The reference tones

The medians of #125's regions are nearly grey and tinting with them gives mud, so the tones are
the `vivid` medians (the most saturated sixth of a region's pixels), warm and cool, of every
region but the sky and the tails, and only those holding a tenth of the region's vivid pixels.
A set becomes a `PaletteFamily` with a hue arc of 20° either side of each tone and the chroma the
tones span (widened by 0.85 and 1.1). The reader written for #111 expected a `spread` the files
do not have, failed on all four, and the telescope world fell back to its placeholder without
saying so; it is replaced.

## What Auto picks

Best and mean score of 48 candidates over 40 scene seeds:

| Galaxies | Telescope best / mean | Free best / mean |
| --- | --- | --- |
| 1 | 0.99 / 0.86 | 1.00 / 0.98 |
| 2 | 0.93 / 0.70 | 0.99 / 0.83 |
| 3 | 0.82 / 0.66 | 0.98 / 0.80 |
| 4 | 0.78 / 0.65 | 0.98 / 0.81 |
| 5 | 0.76 / 0.63 | 0.97 / 0.83 |

- **With three galaxies or more the free world is almost always `spectrum`.** Keeping three
  colours apart with warm and cool shared needs hues from all round the wheel, which only the
  family that covers it can give. Variety then comes from the harmony and the hues, not the family.
- **The telescope world is almost always `hubble-visible` from three galaxies**: its tones span
  warm and cool, while the Webb sets are mostly coral and orange and cannot keep three apart.
- Lowering the separation target from 0.12 to 0.08 raised the mean score of the free world by
  about 0.1 and changed the families picked very little.

## Use

```
sillage-render look <scene> --palette auto [--world telescope|free] [--base <look>]
sillage-render look <scene> --palette ember
sillage-render look <scene> --palette my.palette.json
sillage-render palettes <scene> --best 3 --world telescope
```

The first three set the palette in `look.json`, promoted as `--promote` does, with the old look
kept as `look-raw.json` the first time; `paletteRecipe` records family, harmony and seed, and a
hand file with only colours records none. `--best` draws the best candidates on a frame of the
take, each labelled with its score, and prints the parts.
