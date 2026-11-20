# The black hole close up's reference outputs (#336)

What Metal gives for a small close up, which the CUDA engine has to give too: a moment of the
run, the run 40 steps on from it, and three stills of that later moment. `manifest.json`
(`sillage-hole-fixtures`, version 1) names the files; everything is little endian.

- `scene.json`: the scene, a `HoleSceneFile` of 4,000 tracers, seed 336, the defaults otherwise.
- `start.bin`: the run `startStep` (6,000) steps after the release, past the stream's first
  return: the tracers' positions, a `float4` each (x, y, z, the light it gives), then their
  velocities, a `float4` each (vx, vy, vz, the tracers per unit area round it, -1 once
  swallowed). 128 kB.
- `end.bin`: the same, `steps` (40) steps on, as Metal's `TidalRun` steps it with the default
  `GasGrid`.
- `physics.rgb`, `ring.rgb`, `straight.rgb`: `end.bin` drawn as `black-hole still` draws it with
  the look file beside each (`<view>.hole.json`), 256 by 144, 8-bit RGB, rows from the top, the
  exposure measured on the frame itself: the physics look with three images, the photon ring at
  20 r_s with a thin disk's temperatures, and the hole drawn straight with its shadow.

`./scripts/dev.sh fixtures` writes them again on the Mac (`sillage-render hole-fixtures`), and
`TidalRunTests` requires Metal to give each again to the bit. `CUDAHoleTests` holds the CUDA
engine to them on the CPU target within the tolerances of `docs/notes/cuda-engine.md`.
