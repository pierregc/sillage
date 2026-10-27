# Several colours per galaxy

Spike #118 (prototype on `spike/galaxy-colours-118`, clips and sheets in the issue) chose what
#119 builds. Each particle gets a static key, each galaxy a ramp of colours from its world, and
the shader blends the looked-up colour with the population colour.

| | Telescope | Free |
| --- | --- | --- |
| Mapping | bulge = core colour, HII and stars formed in the run = young colour, disk stars on a radial ramp | radial ramp on the birth radius |
| Colours | core (vivid warm), disk (median), outskirts (tails vivid cool), young (knots vivid cool), knot glow (knots vivid warm), 30 % of the galaxy's palette colour on top | pale core toward gold, the palette colour, outskirts from the family's other arc |
| Stops | 0, 1.0, 2.4, 4.5 scale lengths | same |
| Blend | `mix(population, mapped, 0.75)` | 0.75, chroma × 1.8 |

- **The free colours need their chroma raised.** Blending a #111 palette colour into the
  population colour lowers saturation where today's multiplied tint raises it: at the palette's
  own chroma, colourfulness fell from 95 to 47 on night scene 23. × 1.8 brings it to 89 with no
  clipping, and the tails read in the outer colour.
- **Population mapping loses in both worlds**: ages are mixed inside a disk, so it gives the
  salt and pepper the physical colouring gave. Component alone gives flat zones.
- **Cost**: not measurable at 2 M with `--replay` (6.9 ms GPU median either way).
- **Birth radius**: store it in the take. Rebuilt from the frame-0 centres it ranks at Spearman
  0.85 to 0.96 against the sampler; the distance to the origin that takes use today ranks at
  0.40 to -0.04 and also breaks the metallicity gradient of every replay. Old takes fall back to
  the frame-0 centres.

## What #119 built

- **The look file holds the colours.** A palette entry is `[r, g, b]` as before, or an object:
  the galaxy's own colour, the mapping (`radius` in the free world, `mix` in the telescope one),
  core, disk, outskirts, young and knot colours, and the blend. `look --palette` and `palettes`
  write ramps; a file with plain colours renders as it always did, so nothing old changes.
- **The shader looks the colour up per particle.** A static key per particle (birth radius in
  its galaxy's scale lengths) and one `GalaxyRamp` per galaxy; gas, knots and the stars the run
  forms are recognised on the GPU, so a live run's new stars take the young colour as they form.
  A galaxy without a ramp keeps the one-colour shading, and so does the plain look.
- **Takes are version 6** and carry the birth radius. An older take keeps the radius it always
  replayed with (distance to the origin) for the metallicity, so it renders byte for byte as
  before; only the ramps read the frame-0 centres. Checked on night scenes 23 and 18 with
  `nebula-soft` and `hubble`: grids identical to `main`.
- **Cost**: night scene 23, 2 M particles, `--replay` at 2560×1440 with `nebula-soft`, three
  alternated runs: GPU median 42.8 / 43.7 / 43.5 ms with ramps, 43.1 / 43.7 / 43.9 ms without.
- `--selftest` is not byte-deterministic on `main` either (two runs differ by 7.8 on average),
  so it cannot prove a neutral change; a look grid on a take can.
