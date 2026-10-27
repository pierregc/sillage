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
