# Sillage

A galaxy collision simulator for Apple Silicon, built for the picture rather than the
particle count.

![A pair of disks midway through a prograde encounter](docs/hero.png)

## Two levels of physics

The solver is chosen per scene, so the cheap model and the accurate one share the same
configuration, the same particle storage and the same renderer.

| Level | Model | Cost | State |
|---|---|---|---|
| 1 | Massless test particles in rigid analytic potentials (Toomre & Toomre, 1972) | O(N) | implemented, CPU and GPU |
| 2 | Self-gravitating particles on a Barnes-Hut tree | O(N log N) | planned |

Level 1 is deliberately first: it reproduces the bridges and tails that make an encounter
worth looking at, and it is cheap enough that the particle budget goes entirely into what is
visible. Each galaxy's bulge and dark halo are an analytic potential rather than particles,
so no part of the budget is spent on mass that never reaches a pixel.

## Measured on an Apple Silicon

| | Per step | Notes |
|---|---|---|
| CPU reference, 1 M | 17.4 ms | single threaded, used as the correctness reference |
| GPU, 1 M | 0.102 ms | 170x the CPU path |
| GPU, 5 M | 0.893 ms | over 1000 steps per second |
| GPU, 16 M | 2.85 ms | |

The interactive app holds 3 million particles at 2.4 ms per frame, which is the display
refresh rate rather than a GPU limit. Past roughly 20 million particles the extra points
land in pixels that are already smooth, so the picture stops improving.

## The app

```
./scripts/dev.sh app && open .build/dev/Sillage.app
```

It opens on a setup screen. Add or remove galaxies, and for each one choose its kind, mass
profile, particle count, mass, scale radius, size, extent, thickness, velocity dispersion,
inclination, position angle, spin, position and velocity. The footer shows the total particle
count and an estimate of the cost per frame, so the count can be chosen knowing whether the
run will stay real time.

Starting the run switches to the live view: drag to orbit, scroll to zoom, space to pause.
The side panel there only holds things that apply immediately, brightness and stretch and
bloom and camera, plus a button back to the setup screen. Nothing heavy is built until the
run starts, so the setup screen opens instantly.

### Galaxy kinds

| Kind | Distribution |
|---|---|
| Spirale | Thin rotating disk with a logarithmic spiral density modulation, sampled by rejection so the radial profile is untouched |
| Disque | Thin rotating disk, featureless |
| Globulaire | Pressure-supported sphere, no ordered rotation. Plummer spheres are drawn from their exact distribution function; Hernquist uses the Jeans dispersion |

Spin matters more than it looks. Prograde coplanar passages raise the long symmetric tails;
retrograde ones stay dull.

Spiral arms are an initial pattern, not a self-sustaining density wave. Without self-gravity
they wind up under differential rotation within a few hundred million years, which is the
classic winding problem and is correct for this model. Arms that persist need level 2.

## Offline rendering

```
./scripts/dev.sh render --particles 16000000 --steps 4000 --width 2400 --height 1350 --out out/frame.png
```

Add `--frames N` for an image sequence to encode into video. Rendering offline beats a
screen recording: any resolution, no capture compression, no dropped frames.

Useful flags: `--preset merger|flyby|disk`, `--solver gpu|cpu`, `--seed`, `--radius`,
`--elevation`, `--brightness`, `--stretch`, `--saturation`, `--bloom`, `--supersample`.

## Rendering

Particles are splatted additively into a supersampled `rgba16Float` target, a Kawase
dual-filter bloom pyramid is built from it, and the sum goes through a logarithmic stretch
before ACES tone mapping. The stretch is what astronomical imaging uses: the core of a
galaxy is three orders of magnitude brighter than its tidal debris, and a filmic curve alone
turns the cores into featureless discs.

Brightness is expressed per million particles, so a scene looks the same at 500 000
particles as at 20 million.

## Units

Lengths in kpc, masses in 10^10 solar masses, G = 1. The derived velocity unit is
207.4 km/s and the time unit is 4.71 Myr.

## Building

```
swift build
swift test
```

Shaders are compiled at runtime through `MTLDevice.makeLibrary(source:)`, so Xcode is not
required. Xcode only adds the GPU frame debugger and the Metal shader profiler.

Some Command Line Tools installs ship a PackageDescription whose interface and dylib
disagree, which makes every manifest fail to compile. `scripts/dev.sh` builds and runs the
same test suite through `swiftc` directly if you hit that:

```
./scripts/dev.sh test
./scripts/dev.sh lint
```

`Sillage.app --selftest` renders one frame offscreen and exits. `--verify` opens the real
window, counts the frames the view actually drew, and reports. `--uishot` renders the panels
through `ImageRenderer` to `out/`, which is how the interface gets checked on a machine that
cannot grant screen recording. Sliders and pickers come out as placeholders there; the point
is that every label is legible against its own background.

## Layout

```
Sources/SillageCore/     physics, no rendering dependency
Sources/SillageRender/   Metal solver, splat renderer, camera
Sources/SillageApp/      SwiftUI setup screen and live view
Sources/sillage-render/  headless PNG renderer
Tests/
```

`SillageCore` knows nothing about Metal. The GPU solver lives beside the renderer because
they share the position buffer: on unified memory the integrator writes exactly the buffer
the vertex shader reads, with no copy in between.

The Metal Shading Language sources are isolated in `Shaders.swift` and `SolverShaders.swift`
as plain strings. They are the part of the project that would survive a port to a C++ or
Rust host unchanged.

## Roadmap

- Barnes-Hut solver, with self-gravitating disks and live halos
- EDR output, so the XDR display shows the real dynamic range
- Scene files on disk, replacing the built-in presets

## License

MIT
