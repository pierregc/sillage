# This machine

**Xcode is not installed**, only the Command Line Tools. Two consequences:

- Metal shaders are compiled at runtime through `MTLDevice.makeLibrary(source:)`, so a syntax
  error in MSL only shows up when a pipeline is first built. `allShadersCompile` and
  `allBarnesHutShadersCompile` in the tests exist to force that early. There is no GPU frame
  debugger and no Metal shader profiler.
- **SwiftPM is broken**: the CLT ship a `PackageDescription` whose interface and dylib
  disagree, so every manifest fails to compile, including the one `swift package init`
  generates, and there is no Xcode.app to point `xcode-select` at. `Package.swift` is kept
  correct anyway — it is the description of the project, and it is what a machine with Xcode
  would build — but nothing here reads it. Everything goes through `scripts/dev.sh`:

```
./scripts/dev.sh check    # everything below, in order. Run this before every commit
./scripts/dev.sh test     # builds and runs the whole suite through swiftc
./scripts/dev.sh lint     # swift-format, strict
./scripts/dev.sh strict   # the strict-concurrency typecheck the package would do
./scripts/dev.sh render   # the headless renderer, takes the CLI flags
./scripts/dev.sh app      # builds and bundles Sillage.app
```

**Screen recording is not granted**, so `screencapture` fails and the app window cannot be
looked at directly. Nine modes replace it, and they are the only way to verify the app:

```
Sillage.app --selftest    # model, solver, renderer and preview offscreen; writes out/selftest.png
Sillage.app --verify      # opens the window and drives the view, reports frames drawn
Sillage.app --uishot      # renders the panels through ImageRenderer to out/
Sillage.app --presets     # cycles the setup presets with the window up
Sillage.app --responsive  # runs a self-gravitating scene, reports how long the main actor stalls
Sillage.app --qa          # walks the whole run flow and reports every check
Sillage.app --navcheck    # walks the sidebar: library, nights, workshop, a run left behind, contemplation
Sillage.app --cinema N    # contemplation for N seconds, paced to 60 Hz, reports lateness
Sillage.app --baseline N  # headless; every phase of a step and a frame at N visible particles
```

`--qa` is the one to run after touching anything in the app: it sets up a scene, launches it,
watches it capture, pauses it, stops it, replays it, scrubs it, picks it back up, starts over,
fills the memory budget, and does the last of it again on the self-gravitating solver.

A check that disappears is worse than one that fails. `--qa` used to give the memory budget a
fixed pause to bind in, and it landed just short often enough that three checks about thinning
skipped themselves while the run still printed everything green. It waits for the condition now.
Anything guarded by `if` in `QACheck` deserves the same suspicion.

`--presets` is the only mode that catches a stale index in the galaxy list: `--uishot` builds
the view tree once and never updates it, so a card that crashes on the *change* of a preset
renders perfectly there.

`--verify` drives the canvas itself rather than waiting on the display link, because a window
opened behind another application counts as occluded and MTKView parks its display link. A
report of zero frames means occlusion, not a regression.
