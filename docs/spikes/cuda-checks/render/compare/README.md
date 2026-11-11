# The CUDA side of the renderer check (#276)

The particle passes of the CUDA renderer against Metal's, on the twelve frames of the folder
above: `hubble`, `raw`, `red-vs-cyan` and `red-vs-cyan-column` on the close shot, the wide shot
and the pericentre. Drawn on the CPU target of the CUDA engine (no GPU, the same kernels compiled
by `g++`) in a cloud session, at commit a630372 of `feat/276-cuda-renderer-particles`, from the
bytes Metal drew from: its attribute buffers, positions, smoothing lengths, disk frames, field
stars, stellar table and uniforms.

```
git worktree add ../checks origin/assets/cuda-checks
SILLAGE_CUDA_RENDER_TARGETS=../checks/docs/spikes/cuda-checks/render \
    SILLAGE_CUDA_RENDER_MAPS=/tmp/maps scripts/linux.sh test-cuda --filter theParticlePassesAgreeWithMetal
python3 pictures.py /tmp/maps .
```

Two minutes for the test, which also holds the agreement (`CUDARenderTests`); the maps it writes
are 193 MB of floats and are not kept here.

## The pictures

`<look>-<frame>.png`, four panels, each half the size of the supersampled target:

| | |
| --- | --- |
| Metal's light | the CUDA light, in fixed point |
| their relative difference, fixed point | their relative difference, half floats |

The light is the sum of red, green and blue on a log scale, the same scale for both. The
difference of a pixel is `|CUDA - Metal| / max(CUDA, Metal)` of that sum, on a log scale from
1e-4 (black) through 0.2 % (red) and 5 % (yellow) to 1 (white); 1 % is orange.

- **Fixed point** is how the CUDA renderer accumulates: 64-bit integers, 2^40 a unit, the same
  bits whatever the order. Its difference with Metal is what Metal's `rgba16Float` targets round
  away: the faint surroundings turn yellow and white (Metal holds a few half float steps there,
  or nothing), the galaxies stay red (under 1 %).
- **Half floats** is the same frame accumulated as Metal does, a half float a value blended one
  fragment after another in Metal's order. What is left is what the two engines do differently
  with the same arithmetic: the last bits of the vertex arithmetic, the lace's filter along the
  web's lanes in `hubble`, single pixels under a compact star.

## The numbers

`comparison.txt` is the test's output, every line of it: for each frame the totals (CUDA over
Metal), the median, the 90th and 99th percentile and the largest relative difference of the
light in both accumulations, of the coverage (the light's alpha), of the dust, the web's carrier
and tags, the column's cells and the lace; the light's difference by decade of what Metal holds
on the pixel; then the same frames drawn from the take alone, every input made on Linux, with
how far each input is from Metal's bytes.

| look | frame | fixed point: total | median | 99 % | half floats: total | median | 99 % |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `hubble` | close | 1.0017 | 0.66 % | 10.6 % | 1.00009 | 0.18 % | 4.1 % |
| `hubble` | wide | 1.0017 | 57 % | 100 % | 0.99992 | 11 % | 100 % |
| `hubble` | pericentre | 1.0024 | 0.76 % | 8.9 % | 1.00003 | 0.16 % | 3.3 % |
| `raw` | close | 1.0001 | 0.02 % | 0.20 % | 1.00000 | 0 | 0 |
| `raw` | wide | 1.0282 | 0.02 % | 3.7 % | 1.00001 | 0 | 0 |
| `raw` | pericentre | 1.0004 | 0.02 % | 0.28 % | 1.00002 | 0 | 0 |
| `red-vs-cyan` | close | 1.0014 | 0.36 % | 8.5 % | 0.99993 | 0.06 % | 4.2 % |
| `red-vs-cyan` | wide | 1.0060 | 30 % | 100 % | 0.99985 | 5.3 % | 100 % |
| `red-vs-cyan` | pericentre | 1.0028 | 0.36 % | 6.1 % | 0.99991 | 0.07 % | 2.9 % |

`red-vs-cyan-column` is `red-vs-cyan` within a unit of the last digit. The wide shots are mostly
faint pixels, which is where half floats lose the light: where Metal holds more than 1e-4 the
median difference is under 1 % on every frame. What the numbers mean, and where the large
differences are, is in `docs/notes/cuda-engine.md` on the branch of #276.
