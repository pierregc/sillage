# Scoring rendered frames, and the Auto style

`PaletteScore` (#112) judges a palette on its colours alone. `FrameScore` (#124) judges what
the viewer sees: a key frame of the take drawn at the clip's size with a rendering and a
palette, then scaled down to 480 pixels wide. `StyleAuto` uses it to choose the rendering and
the palette together, so a night can be left on Auto.

## The parts

Each part is 0 to 1; the total is their weighted mean. "Lit" pixels are those with a display
luma of 0.1 or more; the rest is sky.

| Part | Weight | What it measures |
| --- | --- | --- |
| clipping | 0.10 | Share of lit pixels with a channel at 250 or more. 1 up to 1 %, 0 from 13 %. |
| exposure | 0.15 | Mean luma of the lit pixels against 0.3 (0 at 1.2 octaves either side), times one half plus one half of how close the brightest twentieth of them comes to white. |
| colourfulness | 0.20 | Hasler and Süsstrunk's M on the lit pixels. Rises to 1 at 40, falls from 80 to 0.3 at 150: neon. |
| separation | 0.20 | Smallest distance between two galaxies' colours as drawn, at the common lightness 0.8. 1 from 0.06. |
| noise | 0.10 | Median deviation of a sky pixel from its eight neighbours, ×255. 1 up to 1.5, 0 at 5.5. The looks' own grain sits near 2. |
| detail | 0.10 | Mean local contrast of the lit pixels against the 7 × 7 box around them. 1 from 0.12, so sparkle earns nothing more than structure. Glow that washes arms and knots into a blob scores low. |
| reference | 0.15 | Telescope world only: mean distance of the drawn colours to the nearest tone of #125's set for the palette's family. One half at 0.035. |

A galaxy's colour "as drawn" is the mean, in OKLab, of the most saturated sixth of its lit,
unclipped pixels, which is how #125 measured the pictures. Which galaxy a pixel shows comes
from projecting a sample of the visible particles with the shot's camera: the galaxy holding
three quarters of a pixel's particles owns it, mixed pixels are left out.

## Auto

`StyleAuto.ranked` draws three key frames (pericentre, tails and approach first, from
`KeyFrames.pick`) in two rounds:

1. every rendering of the world (`LookCatalogue.renderings`: Hubble and Webb, or the forty free
   looks) with the scene's best palette from `PaletteAuto`;
2. the best four renderings with the next three palettes.

That is 8 pairs in the telescope world and 52 in the free one instead of 8 and 160. A pair's
total is 0.8 × the mean frame score + 0.2 × the palette's own score, since harmony does not
show on a frame. `StyleAuto.apply` puts the rendering and the palette on the scene's look and
keeps its camera and field of view, so the framing does not change with the style.

## Cost

Measured on the M4 Max, whole process, clips of 960 × 540:

| Scene | Particles | Telescope (8 pairs) | Free (52 pairs) |
| --- | --- | --- | --- |
| night 18, 23, 31, 34, 4k-b 1 | 2 M | 1.4 to 1.6 s | 7.2 to 8.1 s |
| night 4, 5, 6, 13, 21 | 150 k | 0.5 to 0.6 s | 2.4 to 3.4 s |

Well under the 30 s asked for at 2 M.

Replaying the camera for every look was half the time at first: cameras are now replayed once
per camera plan, since outside the director's modes the look does not move the camera.

## What Auto picks

Since #119 drew several colours per galaxy, the free world's picks vary: glint, gloss,
gas-whisper, observatory and pointillist across ten scenes (glint five times), mostly with the `spectrum` family.
The telescope world picks Webb eight times in ten: its spikes and warmer sky score higher on
colourfulness and detail than Hubble's. Before the detail part, lone galaxies washed into a
blob by `dream` won; they now lose.

## Use

```
sillage-render look <scene> --style auto [--world telescope|free] [--keep]
```

Promotes the best pair into `look.json` (the old one kept as `look-raw.json` the first time),
unless `--keep`. Writes `looks/auto-<world>.png` (the best three on the key frames) and
`looks/auto-<world>.json` (every pair with its parts and measures). The night's style step
(#115) and the style editor's Auto button (#113) call `StyleAuto.ranked` the same way.
