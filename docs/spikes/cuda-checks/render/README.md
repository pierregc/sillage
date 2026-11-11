# Metal's side of the renderer check (#276)

What the Metal renderer's particle passes leave in their targets, before any post-processing,
on three frames of a small take in five looks, with everything they drew from, for the CUDA
renderer to draw the same frames on the CPU target and compare. Written by
`sillage-render export --dump-targets` on an Apple M4 Max; `manifest.json`
(`sillage-render-targets`, version 1) lists every file with its type, stride and count, and a
reader goes by it, not by the paths below.

`compare/` is the CUDA side's: the difference maps of #276's cloud session. `tracers/` is a
frame drawn with light tracers, in the same format.

## The take

`take/take.sillage`, 20.0 MB: scene `2026-10-30-b/scene-0031` (`take/scene.json`, from
`docs/spikes/tenfold/scene-0031.scene.json` on `assets/tenfold`), 200 k drawn from 50 k massive
(150,207 light tracers, 49,793 massive visible, 75,000 halo particles the take does not hold),
30 captured frames of 40 steps of 0.19782 Myr after a settle of 750 steps, 156.3 to 385.7 Myr,
through the first pericentre (6.59 kpc at frame 19).

```
sillage-render hires <scene folder> --particles 200000 --massive 50000 --dt-scale 3.5 --frames 30
```

with `take/clip.json` in the scene folder, beside `scene.json` and the scene's own look
(`take/look.json`): a 50 k preview, 40 steps a frame, a settle of 750 steps, 480 x 270, and 3
frames a second. The low rate is for the director: its shortest shot is 2.5 s, so at 3 frames a
second its plan holds a close shot, a wide one and the pericentre in 30 captured frames, where
30 frames a second would need 225 of them and a take over 100 MB.

The director's plan on this take, the same for every look here (they share the camera plan and
the lens):

| captured frames | shot | frame kept | name | time |
| --- | --- | ---: | --- | ---: |
| 0 to 7 | disk 0, close | 4 | `close` | 187.9 Myr |
| 8 to 16 | wide | 12 | `wide` | 251.2 Myr |
| 17 to 23 | pericentre 0-1, close | 19 | `pericentre` | 306.6 Myr |
| 24 to 29 | wide | | | |

## The looks

`looks/<name>.look.json` is the look as drawn. Each is a look of the catalogue (`looks/` on
main) with its `camera` replaced by the scene's own (`director`, from
`docs/spikes/tenfold/looks/scene-0031.base.look.json`): the catalogue's cameras are `fixed` or
`auto` and would frame the three moments alike.

| look | what it draws |
| --- | --- |
| `hubble` | the dust web (`dustWeb` 1, `dustStrength` 0.45), 1,500 field stars, supersampling 2 |
| `red-vs-cyan` | no web, no field star, `dustStrength` 0: its dust target is all zeros |
| `raw` | plain points, supersampling 1: its light target is 480 x 270, and it has no dust target |
| `red-vs-cyan-column` | not in the catalogue: `red-vs-cyan` with `columnSmoothing` 8, for the column pass, which no look of the catalogue turns on |
| `hubble-noweb` | not in the catalogue: `hubble` with `dustWeb` 0, for the dust drawn without the web (`dustStrength` 0.45), which every look of the catalogue with dust draws through it |

No target here has `mapped` set: no palette of the catalogue has a ramp. None draws a light
tracer either, since an export of a take has none: `tracers/` holds one frame of a run drawn
with its own, with a README.

## The files

Little endian, rows from the top, bytes as the GPU holds them.

| where | what |
| --- | --- |
| `particles/` | one value a drawn particle, the first 200,000 entries of the buffers the renderer binds: `population.f32`, `formation.f32`, `luminosity.f32`, `component.u32`, `galaxy.u32`, `traits.f32x2`, `rampKeys.f32`; and `stellar.f32x2`, `StellarPopulation.table` |
| `frames/<name>/` | what a frame draws from whatever its look: `positions.f32x4` (Metal's `float3`, 16 bytes) and `smoothing.f32`, the take's frame expanded and its smoothing lengths |
| `targets/<look>/<name>/` | `splat-uniforms.bin` (`SplatUniforms`, its whole stride, `pass` 1; for `raw`, the plain pass's, `pass` 0), `web-uniforms.bin` (`WebUniforms`), `disk-frames.bin` (`DiskFrame` a galaxy), `ramps.bin` (`GalaxyRamp` a galaxy), `starfield.bin` (`BackgroundStar` a field star); then the targets: `light.f16` (the accumulation, rgba16Float, raw half bits), `dust.f16` (the four depth slabs, rgba16Float), `column.f32` (the column density, r32Float, 120 x 67), `carrier.f16` and `tags.u8` (the web's coarse targets, rgba16Float and rgba8Unorm, 480 x 270) |
| `lace/` | the baked lace, r16Float: `level0-crop.f16`, 256 x 256 texels from the origin of level 0, and `level4.f16`, the whole of level 4 (256 x 256); its mean is `lace.mean` in the manifest |
| `stills/` | the 15 frames as the export draws them, 480 x 270 PNG, for the eye |

A target lists in the manifest: its look and look file, its frame (name, captured position,
time in code units and in Myr), the director's shot, `supersample`, `plain`, `starCount`,
`dustWeb`, `columnSmoothing`, `holeShadow`, `mapped`, `luminosityNormalisation`, `drawn`,
`galaxies`, `galaxySlots`, `laceMean`, the camera (`eye`, `target`, `up`, `fieldOfView`, `near`,
`far`, `aspect`) and its files, each with `file`, `type`, `stride`, `count` and, for a texture,
`width` and `height`.

```
sillage-render export <scene folder> --look <look> --width 480 --height 270 \
    --dump-targets <this folder> --dump-targets-frames 12:wide,19:pericentre,4:close
```

once a look, with the looks of `looks/` in `<scene folder>/looks/`. Each export adds its look to
the manifest. The frames an export draws are the same with and without the option, to the byte.

## What surprises

- `raw`, frame `wide`: the core reaches 2048 in `light.f16` and stays there. In half floats
  2048 + 1 is 2048, so Metal stops counting where an fp32 or a fixed point accumulation goes on.
  The large relative differences there are the half floats' plateau, not an error.
- `red-vs-cyan` has `dustStrength` 0: only `hubble` has dust, through the web, and
  `hubble-noweb`, without it.
- The light and the dust are blended in the order the rasteriser takes the fragments, in half
  floats: a sum of many splats in a pixel carries their rounding, a few ulp of a half.
- `splat-uniforms.bin` is the 176 bytes of the stride: the struct's 168 bytes, then 8 bytes
  of padding, zeros here.

## The byte reference

`digests.txt`: the SHA-256 of the 120 PNG stills (the 30 frames of the take in the first four
looks) that main at b41436f draws, twice the same; every head of #276 must give them again.

```
sillage-render export <scene folder> --look <look> --width 480 --height 270 \
    --stills <dir>/stills-<look> --still-frames 0,1,...,29 --out <dir>/<look>.mp4
```

The `.mp4` are not compared: the hardware HEVC encoder is not deterministic.

## The rasteriser probe

`raster-probe/`: what Metal's rasteriser does with a point, which the CUDA renderer has to do by
hand. `raster-probe.swift` draws one point a case into a cleared rgba32Float target with no
blending, the fragment writing `float4(point_coord.x, point_coord.y, 1, 0)`; each case is a
`.f32` file of the 64 x 64 target (the sweeps out of the frame are told by their counts alone)
and `manifest.json` gives its size, its centre in pixels, its clip position, how many pixels it
covers and the box they fill. `rules.py` checks the rules below against all 131 cases: none is
off, and `point_coord` is within 1.2e-6.

A point of size `s` at clip position `(x, y, z, w)` in a frame of `W` x `H` pixels:

1. is dropped whole when `z < 0` or `z > w`, when `|x| > 1.5 w` or `|y| > 1.5 w` (its centre
   more than a quarter of the frame out of it), or when `s <= 0`. A centre out of the frame by
   less still draws the part of its square that is in the frame;
2. has its size clamped to 511. A size under 1 is not raised: 0.5 covers a pixel only when a
   pixel centre falls in its square;
3. stands at `c = ((x / w + 1) W / 2, (1 - y / w) H / 2)`, and its square runs from
   `round(256 (c - s / 2)) / 256` to `round(256 (c + s / 2)) / 256` on each axis: its edges
   are rounded to 1/256 of a pixel, not its centre;
4. covers the pixels whose centre is in that square, the first edge included and the last not;
5. gives a pixel `point_coord = (pixel centre - first edge) / span` on each axis, where the span
   is the square's side with its two edges rounded to a sixteenth of a pixel instead:
   `(round(16 (c + s / 2)) - round(16 (c - s / 2))) / 16`. So `point_coord` is not the pixel's
   place in the square of size `s`: at a size of 1.3 the span is 1.25 or 1.3125 according to
   where the centre falls, and the two axes may differ.

Cases: sizes 0.5 to 1200 at four centres, sizes off the quarter pixel, points at the frame's
edges, in front of the near plane and behind the far one, through a perspective divide, of no
size, and their centres out of frames of four sizes around a quarter of the side.

```
swiftc -O raster-probe.swift -o raster-probe && ./raster-probe <dir> && python3 rules.py <dir>
```
