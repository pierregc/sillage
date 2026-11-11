# A frame drawn with its light tracers (#276)

An export of a take draws no light tracer: every particle of a take is drawn as a massive one.
The tracer vertex functions (`splatTracerVertex`, `countTracerVertex`, `plainTracerVertex`,
`webCarrierTracerVertex`, `dustWebTracerVertex`) run only when a hires run draws its own frames.
So here is one frame of such a run, in three looks, in the format of the folder above
(`manifest.json`, `sillage-render-targets` version 1, its `source` naming `hires`).

The run is the take's own, stopped after 5 frames: scene-0031, 200 k drawn from 50 k massive,
its frame 4 at 187.9 Myr, named `early`. It draws 49,793 massive particles and 150,207 light
tracers (`drawn` and `tracers` in each target), through the director's live camera, which holds
the whole scene: not the close shot the take's plan gives frame 4.

```
sillage-render hires <scene folder> --particles 200000 --massive 50000 --dt-scale 3.5 --frames 5 \
    --dump-targets <this folder> --dump-targets-frames 4:early
```

once a look, the look being the scene folder's `look.json`: `hubble` (the web's two tracer
functions, the star field), `red-vs-cyan-column` (the column pass) and `raw` (the plain points).
The three runs give the same bytes for every file of `frames/early/` and of `particles/`.

What a frame adds to the folder above, in `frames/early/`:

| file | what |
| --- | --- |
| `positions.f32x4`, `smoothing.f32` | the 49,793 massive particles drawn, as in a take's frame |
| `states.f32x4` | a `float4` a tracer: its position, and its formation time in w |
| `words.u32x4` | four 32-bit words a tracer: its velocity, and its `TracerWord` last |
| `scales.f32` | each galaxy's scale length, 16 floats |

and what a target adds, in `targets/<look>/early/`, beside `tracers` and `tracerDepth` in the
manifest:

| file | what |
| --- | --- |
| `cells.u32x2` | the massive tree's spacing records, the whole buffer as bound (63,420 cells) |
| `treeFrame.f32` | the frame the tree's codes are taken in, 8 floats |

The spacing goes with the target and not with the frame: a run lays its tree's cells out in an
order of its own, so `cells.u32x2` differs between `hubble` and `red-vs-cyan-column` while the
spacing a tracer reads in it is the same. `raw` sizes no kernel and builds no spacing: its
`cells.u32x2` and `treeFrame.f32` are the 16 byte stand-in Metal binds then, and its
`tracerDepth` is 0.

`particles/` holds the massive particles' attributes (49,793 entries), a tracer's being in its
word. The take of this run is not here: `take.file` is empty, and `take.particles` counts the
75,000 halo particles too (275,000), which no pass draws.
