# The CUDA engine's stills against Metal's (#277)

`sillage-cuda still` on the CPU target against `sillage-render export --stills`, from the take of
`../../render/take/`, in the looks of `../../render/looks/`. The pairs, the difference maps and
the numbers come in the PR that closes #277.

`looks/hubble-nonoise.look.json` is `hubble` with `look.noiseLevel` 0 and `name` `hubble-nonoise`:
the film grain's hash is the one thing the two engines do not give alike (a last bit of its
argument changes it), so Metal's stills of that look, `../../render/stills/hubble-nonoise-*.png`,
say how far apart the rest of the post-processing is.
