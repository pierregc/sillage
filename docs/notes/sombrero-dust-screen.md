# The Sombrero's dust as a screen in the engine (#506)

Stage 2 of #506 (epic #485): track B's ring, and track C's f7, on the film's freeze frame, drawn by
Sillage itself. Images in `~/claude-workspace/sombrero/banc/506/` (`03` to `06`), working files in
`~/claude-workspace/sombrero/out/506/s2/`.

## Why not the grains

A take carries 1.2 M dust grains at 8 M (15 % of the visible particles, all in the ring). Whatever
detail they hold lives in their positions. At 12 Myr, v6's threads stand in a layer 24 pc rms thick
(the smooth sheet of `scene-screen.json`: 7 to 15 pc); at 6 degrees from edge on a height shows as
itself and a radius as a tenth of itself, so a layer that thick smears the 10 to 20 pc of sky detail
Hubble's lane holds, and 2 km/s of dispersion erases what is left in 20 Myr (#504). The grains also
carry the sampler's own pattern: the smooth sheet (`sheet` 1, `cotton` 0) still draws combed
strata, the coherent lift of its layer seen edge on (`03-smooth`).

## The screen

`inside.dustScreen` in a flight file (`DustScreen.swift`, Metal only, off unless given): a polar
tile of the dust's column across the plane, read where each pixel's ray meets the galaxy's
mid-plane, at every angle, turned by the disk's rotation from `rest`, over the pixel's footprint
(mipmaps, anisotropic). The column along the ray is the tile's over the cosine of the ray's angle
to the axis. The galaxy's grains go into the dust web's carrier, at the frame's resolution and
whatever the angle; they no longer say how much dust there is, only how it is shared among the
four slabs, and where there is none. So the layer's thickness and the grains' noise leave the
freeze frame alone: a sheet in the mid-plane at 6 degrees is exactly what track B is.

`law` (in the same block) is #499's colour law, `law=hubble`: each channel's optical depth a share
of the green's that tends to one as the green's passes `t`; the rim, within `rimRadii` of the
centre where the pixel's ray meets the plane, takes a law of its own. The bench's numbers redden
1.8 times too much in the engine (its light is not the bench's); fitted on the lane's colour excess
by depth: diffuse red 0.55, blue 1.47, t 10; rim 0.7, 1.2, 0.25; rim radii the inner cut plus 0.77
to 1.54 kpc (6.09 to 6.86 for B, 6.57 to 7.34 for C7, whose cut is at 5.8). The colour excess then
follows Hubble's to an opacity of 1.7; past it Hubble greys and the engine does not quite.

## Making a freeze frame

- Tile: `references/sombrero/tools/screen_tile.py b dust-tracks/b/f6.json OUT` (B6; `f1` for B1),
  `screen_tile.py c dust-tracks/c/f7.json OUT` (C7: the bench's grains drawn at Hubble's angle,
  near and far halves read back onto the plane apart, so the clouds' heights come through as the
  sky shift they make at 6 degrees; from any other angle it is a flat sheet).
- Take: `scene-screen.json` (v6 with the smooth sheet, no threads, no young regions), 8 M to
  60 Myr, 7 minutes.
- Camera: **800 kpc away**, field of view a tenth of the 80 kpc one. From 80 kpc the near half is
  9 % nearer than the centre and the lane lands 50 to 60 pc lower than Hubble's.
- `depth`: 0.45 for B6, 0.5 for B1, 0.32 for C7, set so the near lane's mean opacity across it
  (|u| < 4.7 kpc) sums as Hubble's.
- The look is v6's untouched; every dust setting is in the flight's `inside` block.

## Where it stands (texture.py at grid 3072, the bench's frames beside)

| | engine | bench |
|---|---|---|
| B6 | 3.97 | 2.69 |
| B1 | 3.90 | 1.93 |
| C7 | 3.25 | 3.27 |
| v6 threads (stage 1) | 3.71 | |

The engine draws the same clouds in the same places (correlation 0.8 with the bench's opacity map,
0.89 smoothed over 2 px), but with 1.3 times the contrast at every scale: darker clumps, clearer
gaps (phase 5.6, skewness 3.5). C7, whose clumps are compact and sharp-edged anyway, goes through
unchanged. Inverting the engine's opacity row by row against the field's (`remap` in the working
files) took B6 to 3.16 and drew horizontal stripes; not kept. What is left between the engine and
the bench is the light the dust lies in front of, not the field.

## Dabs in place of the tile (#508)

B1's tile is ten times longer along the radius than round, because it was drawn from the front
view, where a radius shows as a tenth of itself: right at the front, strokes from the core at the
tips and from above. `dabs` in the same block (`{"size": [120, 70, 35], "cell": 100, "octaves": 4,
"ratio": 0.55, "gain": 0.8, "shape": 2}`) draws the screen's scores from dabs instead: Gaussian
blobs in the layer, widths in parsecs along the rotation, the radius and the height, centred in
the mid-plane, and their column taken along the ray in closed form. A blob projects round from any
angle, so a dab as tall as it is wide keeps its shape at 6 degrees, at the tips and from above;
height is what the front sees, the radius what the tips see. Dabs sit one to a cell on rings one
cell wide, each ring turned rigidly at its own rate: a dab moves with the dust and is never
sheared, and independent dabs look the same however far their rings have slipped, so nothing needs
renewing. Each octave is `ratio` the size, `gain` the amplitude; a dab's depth is gamma of shape
`shape`. The sum is turned into a normal score from its mean and variance where the ray falls
(Wilson-Hilferty, checked by Monte Carlo at 6, 30 and 89 degrees: sd 1.04 to 1.06) and read through
the tile's lut, so the column keeps B1's statistics radius by radius; octaves narrower than a pixel
fade out. It costs nothing measurable (a 4K still in 1.8 s either way). Images in
`~/claude-workspace/sombrero/banc/508/`.

Close to the disk the dabs are read along the ray's whole line, which may cross the plane behind
the eye: each dab counts for its share ahead of the eye, the statistics for the layer's share
ahead, so the eye can stand in the layer and a ray leaving the plane sees only what is above it.
Below 3 degrees to the plane the dabs give way to the grains, as `front` does for a tile: edge on,
the lane is the grains' own. What still breaks: inside the layer the screen is laid on the grains'
carrier, and near the eye the grains are separate kernels, so the dust shows as grey discs; the
screen would need a carrier of its own there. `smooth` lays a share of each radius's mean column
smooth (gaps filled, mean kept); `rings` ([radius, sigma, column], up to four) add column mottled
as the radius's own, for the outer rings that make the tips: `smooth` 0.3, rings 7.9 and 8.75 kpc
(sigma 0.4 and 0.35, column 0.25), depth 0.39 give Hubble's lane depth at the front and the tips.

### From inside the layer

The grey discs were the grains' kernels: the screen's column is shared among the slabs a pixel's
grains fill, divided by what they carry, so any grain at all gets the whole column and none gets
nothing; near the eye the grains are separate kernels and each showed as a flat disc. `volume` 1
lays the column where the dabs themselves lie: each dab's share between the slab boundaries along
the ray (a difference of the normal distribution function), the smooth share by the layer's
Gaussian, wherever the grains are or not. Below `volumeHeight` (3 kpc, from a third of it) it
takes over from the grains, so frames from afar are unchanged to the byte. `fade` (150 pc) weighs
the dust by a ramp ahead of the eye, in the dabs and in their statistics alike, so the layer thins
round a camera inside it as the grains do. In the layer the grazing band the grains take showed as
a bright seam along the horizon; with `grazing` below 1 the dabs take it too as the eye nears the
plane (from four dab heights), rays flatter than `0.07 x grazing` read at the band's two edges and
blended across it, so up and down meet unseen and no footprint outgrows the 64 cells a ray reads.
0.45 with dabs of 95 x 55 x 28 pc (cell 80) holds from 250 pc above the plane to 30 pc below it.

The film's approach (#511) showed three thresholds. The dabs' slab shares were placed with the
export's stack round the aim point, not the frame's own slabs the grains and stars are drawn in
(the resolve was bound the plain splat uniforms), and kept whole in the slab a dab lies in: the
dust just past a boundary shaded almost none of the light just behind it, a straight band empty of
dust along the line where the boundary meets the plane. `softSlabs` binds the frame's slabs and
spreads each dab's share over a slab's depth, a ramp between the middles of the two slabs round
each boundary, as the grains' dust is. The grazing band went over from the grains to the dabs
between 112 and 28 pc of eye height, the dust at the horizon coming in over a second of the
descent; `grazingHeight` 3 hands it over between 1 and 3 kpc, with `volume`. The far side of the
ring shades the bulge in the eye's slabs and not in the matter's, and the approach crossed
`slabsWithin` (1.5 to 6 kpc of nearness) in under a second; `slabsLog` with [0.5, 800] dissolves
them over the whole approach.

## Not done

The flights (zenith, low pass, inside, core, wide): the screen is read at the mid-plane from any
distance, so close to the disk it is a painted sheet until it is carried through the layer as the
web's lace is (#354). The tile winds with the rotation away from `rest`, untested while time runs.
CUDA.
