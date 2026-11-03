# Light tracers (#187): the measurements

What `docs/notes/light-tracers.md` reports, scene-0031 of 2026-10-30-b on the M4 Max.

- `logs/bench.log`: the step cost of each count, alone on the GPU, with `--profile` breakdowns
  (`bench-first-pass.log` is the first pass, where other threads' tests got in).
- `logs/tracer-force-error.txt`: the tracers' force against their opening angle.
- `logs/tr09-run.log`, `tr13-run.log`, `real8m-run.log` and the curves: the whole hires drawn at
  8 M with 2 M massive (tracers at 0.9 and at 1.3) and the real 8 M.
- `drift/`: the density maps compared (`scripts/tracer-drift.py` in the repo), the sheets
  (tracers, massive, residual binned 4x4; one row per instant), the rms extent and the disks'
  thickness over every particle of the takes, against two random halves of the tracers.
- `sheets/`: 4K stills with 1:1 crops, rows `m2` (the massive particles of the tracer run
  drawn alone), `tracers` (all 8 M of it) and `real8m`, at captured frames 0, 192, 608 and 912
  (157, 309, 639 and 879 Myr); `close` is the scene's look on the auto camera, `close-glint0.3`
  the same with the glint #184 ships. `scores.tsv` from `grain.py` (#182).
- `looks/`, `scripts/`: what drew and measured them.
