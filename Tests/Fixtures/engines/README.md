# The engines' reference outputs (#281)

Small outputs the Metal engine gives and the CUDA engine has to give too: a tree, the
accelerations of one walk, three frames. Under 2 MB in all.

Everything is little endian, byte for byte as Metal holds it: a `float3` takes 16 bytes, its
fourth float 0. `manifest.json` (`sillage-engine-fixtures`, version 1) lists the tree's files
with their type, stride and count, as a walk dump's manifest does; a C++ reader needs nothing
else.

`./scripts/dev.sh fixtures` writes them again on the Mac, from `scene/` and the three look files
of `frames/`. The same code gives the same bytes: nothing in them depends on the run, the date or
the commit. On every `./scripts/dev.sh check`, `EngineFixtureTests` requires Metal to give each
output again to the bit, and `TreeLayoutTests` requires it of the portable `BarnesHutTree`, on
Linux too. A PR that changes them on purpose regenerates them and says so; the tolerances of
the other engines are in `docs/notes/one-kernel-source.md`.

## The level order

Metal lays the cells of one level out in an order that changes from run to run (the blocks of
children are reserved by an atomic add), so every tree here is in one layout: the root is node
0, then level by level, a level's cells in their parents' order, a parent's children contiguous
and in octant order. A branch's `range` is the index of its first child in that layout. It is
what `GPUTreeBuilder` writes with that freedom removed, and the walk does not tell the
difference. `BarnesHutTree.levelOrder(of:)` gives it for any layout; a tree in another layout
can also be compared by walking both from the root.

## `tree/`: a tree of 20,000 particles

A disk, a tight clump inside it, debris far out, and 400 points on 8 places, so that leaves at
the depth limit hold more than a leaf's worth. Leaf capacity 16, depth 20, quadrupoles on. The
first 16,000 particles are the drawn ones (`drawnCount`), each standing for 4 (`ratio`), as
with light tracers; the others weigh and are not drawn, as a halo's.

| file | type | stride | count | |
| --- | --- | ---: | ---: | --- |
| `positions.bin` | `float3` | 16 | 20,000 | in: x, y, z, 0 |
| `mass.bin` | `float` | 4 | 20,000 | in |
| `order.bin` | `uint` | 4 | 20,000 | particle indices in Morton order |
| `nodes.bin` | `BHNode` | 32 | 3,890 | `comMass` (centre of mass, mass) then `packed`: width squared, `range`, the signed count, the digit, the last three as bit patterns |
| `moments.bin` | `float4` | 16 | 7,780 | two a node, about its centre of mass: (xx, yy, zz, xy) then (xz, yz, 0, 0) |
| `frame.bin` | `float` | 4 | 8 | the root's origin (x, y, z), the codes' scale, the root's half width, 0, 0, 0 |
| `levels.bin` | `uint` | 4 | 22 | where each depth starts in `nodes`, 0 to 20, then the node count |
| `smoothing.bin` | `float` | 4 | 16,000 | `gtSmoothing`: the smoothing length of each drawn particle |
| `spacing.bin` | `uint2` | 8 | 3,890 | `gtSpacing*`: a node's spacing length as a float's bits (0 with nothing drawn in it), then, for a branch, its first child shifted left by 8 over the mask of the octants that have one |

A leaf's `range` is the start of its particles in `order`, and its count is negative. The
lengths go through `pow`, which no two math libraries round alike: outside Metal they are held
to a tolerance, the rest to the bit.

## `walk/`: the walk of 1,000 light tracers

A `sillage-walk-dump` of version 1, as `docs/notes/cuda-walk-spike.md` gives it, with its own
`manifest.json`: every buffer `bhTracerStep` binds, Metal's accelerations on that state
(`accelerations.bin`) and the motions after one more mode 1 pass (`motions-mode1.bin`). Its
`nodes.bin` and `moments.bin` are in the level order and its `commit` is left empty, the only
differences with the dump a run writes.

It is frame 0 of a small hires of the scene in `scene/` (scene-0031 of 2026-10-30-b):

```
sillage-render hires scene --particles 3013 --massive 2000 --frames 1 --width 256 --height 144 \
    --dump-walk walk --dump-walk-frames 0:fixture
```

1,000 tracers walk a tree of 5,012 massive particles (2,013 visible, 2,999 of the live halos)
in 1,314 nodes, 63 steps in, with both disks cooling. The halos are live and the scene has no
black hole, so `haloCount` and `holeCount` are 0: the walk reads neither `halos.bin` nor
`holes.bin`.

## `frames/`: three frames of 256 x 144

`take.sillage` is the take of that same run, one captured frame of its 3,013 drawn particles.
Each `<look>.rgba` is that frame as `export` draws it with `<look>.look.json`: 256 x 144 pixels,
8 bits a channel in the order R, G, B, A, rows from the top, 147,456 bytes.

| look | what it draws |
| --- | --- |
| `red-vs-cyan` | each galaxy in its own colour, bloom, no noise, no sky |
| `ember` | the dust web, the stars of the sky, noise |
| `webb` | the telescope world: Webb's spikes and its sky |
