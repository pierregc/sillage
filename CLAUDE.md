# Working notes

Read `README.md` for what the project is and how it works. This file is only the things a
fresh session cannot deduce from the code.

## This machine

**Xcode is not installed**, only the Command Line Tools. Two consequences:

- Metal shaders are compiled at runtime through `MTLDevice.makeLibrary(source:)`, so a syntax
  error in MSL only shows up when a pipeline is first built. `allShadersCompile` and
  `allBarnesHutShadersCompile` in the tests exist to force that early. There is no GPU frame
  debugger and no Metal shader profiler.
- **SwiftPM is broken**: the CLT ship a `PackageDescription` whose interface and dylib
  disagree, so every manifest fails to compile, including the one `swift package init`
  generates. `Package.swift` is kept correct for CI, which runs on a GitHub macOS runner where
  Xcode is present, but locally everything goes through `scripts/dev.sh`:

```
./scripts/dev.sh test     # builds and runs the whole suite through swiftc
./scripts/dev.sh lint     # swift-format, strict
./scripts/dev.sh render   # the headless renderer, takes the CLI flags
./scripts/dev.sh app      # builds and bundles Sillage.app
```

**Screen recording is not granted**, so `screencapture` fails and the app window cannot be
looked at directly. Five modes replace it, and they are the only way to verify the app:

```
Sillage.app --selftest    # model, solver, renderer and preview offscreen; writes out/selftest.png
Sillage.app --verify      # opens the window and drives the view, reports frames drawn
Sillage.app --uishot      # renders the panels through ImageRenderer to out/
Sillage.app --presets     # cycles the setup presets with the window up
Sillage.app --responsive  # runs a self-gravitating scene, reports how long the main actor stalls
```

`--presets` is the only mode that catches a stale index in the galaxy list: `--uishot` builds
the view tree once and never updates it, so a card that crashes on the *change* of a preset
renders perfectly there.

`--verify` drives the canvas itself rather than waiting on the display link, because a window
opened behind another application counts as occluded and MTKView parks its display link. A
report of zero frames means occlusion, not a regression.

## Conventions

- Conventional commits, small, minimal `-m`. **No `Co-authored-by` trailer.**
- Comments are sparse and explain why, never what.
- **Never push and never create the GitHub repository without explicit approval.** Nothing has
  been pushed. The repo does not exist on GitHub yet, and neither do the milestones.

## Habits worth keeping

- Render previews small when the point is to judge a look. A 900 px image answers the question
  a 5000 px contact sheet answers, at a fraction of the context.
- Prefer targeted edits over rewriting whole files: rewriting through a shell heredoc makes the
  harness echo the entire file back as a diff.
- Editing the MSL strings by pattern is fragile because the formatter reindents them. Match on
  distinctive lines without assuming leading whitespace, and always assert the pattern was
  found; a silent no-op replacement has cost hours here.

## State and known limitations

Both solvers work. Level 1 is tracers in rigid potentials, level 2 is self-gravitating
Barnes-Hut with live halos, and level 2 is the default. Galaxies merge, and the orbital decay
is measured in the README.

Standing gaps, in the order they matter:

1. **No gas.** HII regions are decorative: placed by the sampler, not produced by collapse.
   No shocks, no starbursts in the right places, no dust distribution from physics. Adding SPH
   is a project of its own and would cost another order of magnitude in speed.
2. **Colour is not derived.** Stellar populations are a hand-made ramp rather than luminosities
   in real bands composited like telescope filters. This is the next lever for making the
   interior of a galaxy legible.
3. **Disk stability over many orbits is unmeasured.** Live halos should have improved it, but
   nobody has run the ten minutes per configuration needed to say so.
4. **Force traversal is divergence-bound.** Sharing one stack across a SIMD group is the
   remaining large win; the tree build has already been parallelised.
5. **Graininess in the outskirts** comes from the clumpiness of the initial conditions, not
   from sampling. It is deliberate, but it reads as noise now that the render is sharp.
