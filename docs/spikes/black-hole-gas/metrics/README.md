Metric rows of `sillage-render black-hole run --metrics` for docs/notes/black-hole-gas.md, columns
as `TidalMeasure.Row.header`; P* is 699 time units at 1 M tracers. Built before #332's fixed-point
grid, so two runs differ in the late columns by about 0.05.

| file | tracers | to | every | options |
| --- | --- | --- | --- | --- |
| f-ref | 1 M | 5000 | 50 | the defaults: stickiness 50, crossing speed 0.1, viscosity 2500, 32 layers |
| f-spike | 1 M | 5000 | 50 | `--grid-heights 1 --stickiness 2 --crossing-speed 0.3 --viscous-orbits 40` |
| f-flat | 1 M | 5000 | 50 | `--grid-heights 1` |
| f-k2, f-k20, f-k200 | 1 M | 5000 | 50 | `--stickiness 2`, `20`, `200` |
| f-c005, f-c02, f-c03 | 1 M | 5000 | 50 | `--crossing-speed 0.05`, `0.2`, `0.3` |
| f-w40, f-w160, f-w400 | 1 M | 5000 | 50 | `--viscous-orbits 40`, `160`, `400` |
| f-r12 | 2 M | 8400 | 100 | the defaults, to 12 P* |
| g-n250k, g-n4m | 250 000, 4 M | 5000 | 50 | the defaults |
| g-h16, g-h64 | 1 M | 5000 | 50 | `--grid-heights 16 --height-cell 0.03125`, `64 0.0078125` |
| p-flat-C, p-tall-C | 1 M | 100 | 10 | `--viscous-orbits 0 --crossing-speed C`, with `--grid-heights 1` for flat |
