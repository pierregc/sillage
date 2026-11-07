# Sillage

Galaxy collisions, simulated and filmed on an Apple Silicon Mac: a Barnes-Hut N-body solver
that builds and walks its tree on the GPU, and a renderer for tens of millions of particles.

https://github.com/user-attachments/assets/325910ab-a244-47e4-a323-6c62412da79a

*Two spiral galaxies meet, fling out two long tidal tails and merge into one over about a
billion years: 32 million particles, 3 million of them carrying the mass.*

A hobby project by one person. The aim is a beautiful render that stays honest about the
physics: the models come from the standard literature, and the limits are listed below.

## What it does

- Simulates self-gravitating galaxies on the GPU, dark-matter halos included.
- Renders them in dozens of looks, filmed by a fixed camera or by a director.
- Runs nights: random scenes, a preview of each, and the ones you pick at high resolution.
- Exports videos and looping animations, replayable from the scene and look files kept
  beside every render.

## Try it

macOS 14 or later on an Apple Silicon Mac.

```bash
git clone https://github.com/pierregc/sillage.git
cd sillage
./scripts/dev.sh app && open .build/dev/Sillage.app
```

Set up the galaxies on the first screen and start the run. The same script runs the tests,
the headless renderer and the night pipeline; Xcode is not needed.

## How it works

Two solvers share one scene: a restricted one that moves test particles through rigid
potentials, after Toomre and Toomre (1972), and a Barnes-Hut one that gives the particles
mass, with a tree built in Morton order and walked on the GPU. Both integrate with leapfrog,
and the softening and the step are derived from the scene. Units: kpc, 10^10 solar masses,
G = 1.

## Known limits

- No gas, no pressure, no shocks.
- Hand-made colours, not real bands.
- A fixed time step.
- Single precision.
- Not compared against a published simulation.
- Apple Silicon only.

## Documentation

- [Reference](docs/reference.md): every command, flag, file and format.
- [Night Manager](docs/night-manager.md): the user guide.
- [Working notes](docs/notes/README.md): what was tried, what was measured, and why.

## Layout

```
Sources/SillageCore/     physics, no rendering dependency
Sources/SillageRender/   Metal solver, splat renderer, camera
Sources/SillageApp/      SwiftUI setup screen and live view
Sources/sillage-render/  headless renderer and the night pipeline
```

## Status and license

One maintainer, no roadmap. Issues are welcome and answered when there is time.

Code: MIT. Renders and videos: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
so reuse them freely as long as the credit comes along.

## Small print

AI did a good share of the typing here. Seemed worth saying out loud.
