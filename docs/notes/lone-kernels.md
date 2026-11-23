# Kernels that show alone

Pierre's feedback on the Cartwheel's third film, 2026-11-23: at mid distance the particles of
sparse regions read as blobs, the outer arms of the small galaxy around 50 s and the inner disk
at 21 and 23 s. Measured on the film's take (`cartwheel2`, 8 M and 12 M tracers) with its look and
its flight, stills in 4K.

## What the blobs are

At those moments the eye is 35 to 60 kpc from the disk, past the near field (`field` 8 to
20 kpc), so nothing is a point star yet and every particle is its splat. In the sparse stretches
each one is a disk 10 to 15 pixels across with dark sky round it.

- **The kernel is a volume's.** Its width is the tree's spacing times the look's
  `smoothingScale` (1.2 here), and its profile falls as `exp(-4.5 r²)` to the point's edge: a
  sigma of a sixth of the width, so half its height 0.39 of the width across, less than half a
  spacing. In a dense arm the disk's thickness stacks several spacings along a line of sight and
  the kernels overlap in projection. Where the disk is sparse and seen near face on nothing
  stacks, and a kernel covers less than one neighbour ([gigantism](gigantism.md) measured the
  same on the grain of a whole frame).
- **The glow's grains are the worst.** A look's `dustGlow` draws the grains of dust a second
  time into the light. A grain's point is 1.3 times its kernel, sized from the spacing of every
  particle, and the grains are a sixth of them: against their own kind they stand twice as far
  apart again. With the glow alone drawn, the grains are pebbles even in the arms. Red on a dark
  sky, they are what the eye sees first; without the glow the stars' blobs are still there, softer.
- **Mid distance is where it shows.** From far a kernel is a pixel or two and reads as a point;
  in the near field the stars take the light (#357) and the glow is spread into a haze
  (`glowHaze`). Between the two a kernel is wide enough to be seen as a disk and nothing merges it.

Two things a look could already do were tried and do not answer it. `columnSmoothing` 40 and 120
widen the stars' kernels in projection everywhere: the stars' blobs go, the dense arms lose their
grain with them, and the grains' glow is not touched. `dustWeb` 0.8 draws the glow along the web's
filaments in the arms (#458) and leaves the grains of the sparse stretches, which the web's
carrier does not take, as ragged blobs.

## What a flight does about it

`inside.neighbours`, in a flight's file: a kernel that shows alone is widened until it covers that
many particles of its kind in projection, its light kept. 0, the default, draws every frame as
before.

- **The count.** The column pass counts what emits and the grains of dust apart, into the two
  channels of a texture of cells eight accumulation pixels across, and a pyramid is built over
  it. A particle's density on screen is read at the finest level whose cell holds six of its
  kind, blended into the next where it holds fewer: in a sparse stretch a cell of the first level
  holds less than one particle and its count is the particle's own, which is what makes the
  column of `columnSmoothing` an estimate of nothing there.
- **The width.** A kernel's profile holds its light within 2 π sigma², so it is drawn
  `6 sqrt(neighbours / (2 π density))` wide, never narrower than the tree's width and at most
  `loneWidest` (120 pixels of a frame 2160 high). The light per area follows the width as it
  always did, so the flux is kept.
- **A star's from a size on screen.** Between `loneFrom` and `loneFull` (5 and 12 pixels of a
  frame 2160 high) a star's kernel goes over to that width. Under the first it is a point and
  stays one: the fine grain of a dense arm and the points of a sparse one are left alone, and a
  dense arm whose kernels already overlap is never widened whatever their size.
- **A grain's glow at any size.** What the dust gives off is never a point. The dust's own
  opacity keeps the tree's kernel: only the glow's draw is widened.
- **The near field keeps its own.** The stars' cross-fade, the fade at the near plane and the
  capped kernels' law read the tree's width as before; a point star is not widened; a near
  grain's glow takes the wider of its haze and this.

The Cartwheel's flight asks for 8. Its stills at 21, 23 and 50 s lose every blob: the glow is a
continuous red with the arms' shape, and the stars that were points stay points over it. The
photograph the film holds on gains the same, its inner disk a diffuse red where it was a stipple.
Without `neighbours` the film's stills are the bytes main draws, in the near field and out of it.
With it, the point stars of the near field are the same stars: at 62 s, 2.5 kpc over the small
disk, the frame moves by 1.4 levels rms in the red, and on the way in, at 58 and 100 s, the glow
between the stars is smoother too (15 and 19 levels), the red blobs beside the Cartwheel's nucleus
gone with the rest.

| 4K still | render before | with `neighbours` 8 |
| --- | --- | --- |
| 21 s | 89 ms | 91 ms |
| 23 s | 75 ms | 94 ms |
| 50 s | 44 ms | 56 ms |
| 62 s | 82 ms | 85 ms |
| 100 s | 190 ms | 215 ms |

Between two frames a thirtieth of a second apart (1080p, at 21.5 and 50.5 s) the rms of the
difference falls, 17.4 to 15.0 levels and 15.3 to 12.3: the widths follow a count read through
bilinear cells and blended between levels, and nothing pops.

## Limits

- Flights only. An export without a flight draws from the library it always had.
- Under a `dustWeb` the glow of the painted strands' grains goes through the web's own vertex
  function and is not widened.
- Metal only for now: the CUDA engine ignores `neighbours` (#459).
