# Sillage

A galaxy collision simulator for Apple Silicon, built for the picture rather than the particle count.

> Status: phase 1 in progress. The physics core runs and is tested; the Metal renderer is not written yet.

## Two levels of physics

The solver is chosen per scene, so the cheap model and the accurate one share the same
configuration, the same particle storage and the same renderer.

| Level | Model | Cost | State |
|---|---|---|---|
| 1 | Massless test particles in rigid analytic potentials (Toomre & Toomre, 1972) | O(N) | implemented |
| 2 | Self-gravitating particles on a Barnes-Hut tree | O(N log N) | planned |

Level 1 is deliberately first: it reproduces the bridges and tails that make an encounter
worth looking at, and it is cheap enough that the particle budget goes entirely into what
is visible. Each galaxy's bulge and dark halo are an analytic potential rather than
particles, so no part of the budget is spent on mass that never reaches a pixel.

## Measured cost

Single-threaded CPU, level 1, Apple Silicon:

| Particles | Per step | Steps/s |
|---|---|---|
| 200 000 | 1.6 ms | 619 |
| 1 000 000 | 8.2 ms | 122 |

The renderer will target 5 million particles, which is where tidal tails stop looking
grainy on a 3456 x 2234 display, with 20 million as the point past which extra particles
stop being visible at all.

## Units

Lengths are in kpc, masses in 10^10 solar masses, and G = 1. The derived velocity unit is
207.4 km/s and the time unit is 4.71 Myr.

## Scenes

A scene is a list of galaxies plus a solver, a seed and a time step. Every galaxy carries
its own mass, scale radius, disk scale length, thickness, position, velocity, inclination,
position angle and spin direction. Spin matters more than it looks: prograde coplanar
passages produce the long symmetric tails, retrograde ones stay dull.

Scenes round-trip through JSON, and the seed makes a run reproducible from a few hundred
bytes rather than from stored trajectories.

```swift
let scene = SceneConfig.merger(particleCount: 5_000_000)
let solver = try SolverFactory.make(scene)
solver.step(count: 1_000)
```

Built-in presets: `merger`, `flyby`, `isolatedDisk`.

## Building

Requires Xcode (the Metal toolchain ships with it; Command Line Tools alone are not enough).

```
swift build
swift test
```

## Layout

```
Sources/SillageCore/   physics, no rendering dependency
Tests/SillageCoreTests/
```

`viz` lands in phase 2 and will consume `ParticleSystem` without knowing how the forces
were computed.

## Roadmap

- Phase 1 — engine: analytic potentials, disk sampling, leapfrog, restricted solver, Metal
  compute path, Barnes-Hut
- Phase 2 — visualisation: HDR point accumulation, bloom and tone mapping, EDR output,
  SwiftUI scene controls

## License

MIT
