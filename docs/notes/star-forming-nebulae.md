# Star forming regions as nebulae (#529)

Hubble's `heic0615a` of the Antennae shows red star forming regions gathered into trails and dense
knots, and a walk inside (#528) should go through them. The measure
([antennae.md](antennae.md#do-the-young-stars-gather-into-a-network-529-the-measure)) says the
network is in the run: on B's 8 M take with sticky gas, the knots younger than 5 Myr put 1.00 of
themselves in the densest tenth of the area against 0.83 by chance (Hubble's red: 1.00), and the
ones younger than 25 Myr 0.51 against 0.42. What was missing was the drawing: a knot was a pink
point from far and a cluster of point stars from inside, never a cloud.

## What is drawn

`look.nebulae` turns on one more draw after the stars, on both engines (`nebulaSplat` in
`Shaders`, `nebulaVertex` on Metal and in `cuda/src/render.cu`, `SC_RENDER_NEBULAE`):

- **Which knots.** Gas the run turned into stars, and the HII regions the sampler placed, as the
  knots' Halpha already decides it. Its light fades as `exp(-age / nebulaMyr)`, 5 Myr by default,
  the life of the O stars; past a hundredth it is not drawn. On B at 573 Myr that is the 3,146
  knots under 10 Myr, of 8 M particles.
- **Its size.** It grows from a third of `nebulaSize` (0.15 kpc, a radius) to all of it as it
  fades: the stars clear the cloud they formed in.
- **Its shape.** Six puffs a knot, one on it and five scattered over its radius by the knot's
  index, so a region is lumpy and keeps its shape from frame to frame. Where knots are dense the
  puffs of neighbours overlap into trails; nothing is painted where the run formed no knot.
- **Its light.** The knot's own light per unit mass at its age, times the fade, times
  `nebulae`, spread over each puff as a surface brightness, as every splat is, in
  `nebulaColour` (Halpha with Hbeta and [OIII], `hiiColour`'s default). A few tens makes the
  regions read from far; at 1 they are as bright as the knot itself.
- **Through the dust.** Each puff is laid with the light, behind the dust slabs in front of it
  and half of its own, as a star is; from inside, through the inside slabs. A region inside a
  lane is dimmed and reddened by it.
- **From inside.** The same draw. A puff the eye comes within its own diameter of fades, so the
  camera passes through a cloud rather than into a ball; its size is capped at 511 pixels, the
  largest point Metal draws.

Metal compiles the draw only into the libraries of a look that asks for it
(`#define SILLAGE_NEBULAE`); a look without it draws from the libraries it always had, and every
existing export is unchanged to the byte: the engine fixtures give their frames again to the bit.

## On B, at Hubble's framing

![](https://raw.githubusercontent.com/pierregc/sillage/assets/antennae/nebulae-529.jpg)

Stills in `nebulae-529.jpg` on `assets/antennae`, all from B's 8 M take at 573.3 Myr with the
`hubble` look and `nebulae` 30, `nebulaSize` 0.25, `nebulaColour` [1, 0.3, 0.55]: Hubble's framing
(20.9 kpc across), the wide view, a dense region of knots 4 kpc from the nearer nucleus, from 2 kpc, and the same
region from 120 pc inside it, each beside the same view without.

- **The network shows.** The regions follow the arcs and the ring of NGC 4038 and the southern arc
  of NGC 4039, where the measure put the youngest knots. From 2 kpc a region is a lumpy pink cloud
  a few hundred parsecs long with its stars in it.
- **The knots crowd the nuclei**, so NGC 4039's bulge goes pink, where Hubble's red avoids the
  cores. That is the run, as the measure found: the renderer draws what it is given.
- **Many regions sit inside the lanes**, since the knots form from the same sticky gas the dust
  is; the lane dims and reddens them, which is right, but makes them orange there with the
  default colour. Hubble's regions are pink, light linear [1, 0.41, 0.56] measured on its red
  pixels; `nebulaColour` [1, 0.3, 0.55] gives that.
- **From inside it does not hold yet.** The puffs read as bright pink balls: six gaussian puffs a
  knot carry no finer structure, and at 4K the near ones pass the 511 pixel cap, so they shrink
  into discs at full surface brightness instead of spreading into a haze around the eye (at
  1080p, under the cap, they read as lumpy clouds). The far views are what this spike gives; the
  walk (#528) needs the near puffs drawn past the cap and with structure in them, or dimmer
  (`nebulae` 10 to 15).

## Cost

At 4K (supersample 2) on the M4 Max, from B's take: Hubble's framing 1.1 s a frame, the region
from 2 kpc 1.5 s, from inside 1.4 s, the same with and without the nebulae to the tenth of a
second the export reports. The draw is a vertex a puff over all 8 M particles, most of them
dropped at once for not being a young knot.

## Engine agreement

`Tests/Fixtures/engines/frames/nebulae.rgba` is the fixture take in `webb` with an HII region round
every knot, which the CUDA engine is held to as it is held to `glow` (`CUDAPostTests`, PSNR 48 dB
at least). It was written on the M4 Max, which gives the other five frames to the bit.

## Left

- From inside: puffs wider than 511 pixels drawn as screen quads rather than capped points, and
  a noise in them, as the near dust has.
- Regions shaped by the gas around the knot rather than scattered by its index.
- The nuclei: fewer knots there is a matter for the run (star formation's rule near the
  bulges), not the renderer.
