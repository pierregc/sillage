# Walk dumps of scene-0031 (#271)

Two dumps of the light tracers' walk, written by Metal during a `sillage-render hires` run, for
`cuda/spike/walk.cu`. The format is in `docs/notes/cuda-walk-spike.md` (section "The dump") on
the branch of #271.

| folder | label | frame | step | time | what the walk does there |
| --- | --- | ---: | ---: | ---: | --- |
| `frame-00000/` | settled | 0 | 754 | 149.16 Myr | first frame after the settle; both disks cooled (`diskCount` 2) |
| `frame-00200/` | pericentre | 200 | 1554 | 307.41 Myr | first pericentre: the closest the centres come (6.58 kpc) in `curves-hires.csv`, the same run carried to frame 259; both disks too disturbed to cool, so `coolingDisks()` binds the placeholder (`diskCount` 0) |

## The run

Scene `2026-10-30-b/scene-0031`: `docs/spikes/tenfold/scene-0031.scene.json` and
`docs/spikes/tenfold/looks/scene-0031.base.look.json` on `assets/tenfold`. The library's own
`clip.json` no longer exists, so the scene folder was given `clip.json` here: a 50 k preview, 4
steps a frame and a settle of 750 steps. The scene's `timeStepScale` is 3.5, so the hires step is
the 50 k massive count's at 3.5: 0.19782 Myr (0.042 in the solver's units), and the settle 148.4
Myr.

```
sillage-render hires <folder> --particles 200000 --massive 50000 --dt-scale 3.5 --frames 201 \
    --width 640 --height 360 --dump-walk <dir> --dump-walk-frames 0:settled,200:pericentre
```

200 k drawn: 150,207 light tracers and 49,793 massive visible particles, with 75,000 halo
particles (live halos, so `haloCount` is 0). Opening angle 0.9, softening 0.3455 kpc,
quadrupole on, cells holding a particle opened, no black hole, walk order sorted 4 steps before
each dump. Built from commit 7406c86 on an Apple M4 Max. `hires.log` is the run's output without
its per frame lines; another render held the GPU throughout, so its times measure nothing.

## What surprises

- `halos.bin` holds the list Metal binds, one halo per galaxy (2), while `haloCount` is 0: with
  live halos the walk reads none of them.
- `holes.bin` is the one zero placeholder Metal binds when the scene has no black hole.
- Two runs of the same command give the same bytes in every file but `nodes.bin` and
  `moments.bin`: the tree is the same, but the builder lays out each level's nodes in an order
  that changes from run to run, so child indices and the moments that follow them differ. The
  accelerations and the motions do not.
