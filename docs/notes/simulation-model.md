# The model, and why it is still one file

`SimulationModel` carries eight concerns at once — camera and flight, the pace of the solver,
capture, playback, the setup preview, the picture's settings, files, contemplation, telemetry —
and it is a single main-actor `ObservableObject` that every view observes. It is the one place
in the app that is genuinely too big.

**Two thirds of it cannot be split with extensions, and finding that out is worth not repeating.**
Swift's `private` is file-scoped, so a member moved into `extension SimulationModel` in another
file loses access to everything private the type holds. Measured on the actual split: moving the
stepping, capture, playback and preview groups out would force **twenty-nine** `private(set)`
properties open — `elapsedMyr`, `mode`, `capturedFrames`, `recording`, the preview's whole
renderer, and so on. Those private setters are the only thing stopping a view from writing the
clock or the capture counters, so that is a real guarantee traded for moving text between files.
Not worth it.

What did move cleanly is what writes nothing protected: `CameraControl.swift` and
`SceneDraft.swift`. The rest is bounded by state, not by code, so the honest fix is extracting
owned objects rather than extensions — `ScenePreview` first, since the setup preview is an
entirely separate renderer with an entirely separate lifetime. That is a bigger change: it moves
view bindings and needs its own republishing.

**What did come out of the model is the picture's settings, and that was worth doing on its own.**
There were three copies of the same numbers: ten `@Published` knobs each with a `didSet` calling
a one-line setter on `Renderer`, a `lookExtras` holding the eight fields with no slider, and
`RenderSettings.init`'s own defaults. Adding a setting meant editing three places and the third
was easy to miss. It is one `RenderLook` now, and `Renderer.apply` — which already existed and
already covered every field — replaced the ten setters.

Two things that surfaced while collapsing it, both pre-existing:

- **The panel's opening values were never `.observatory`, though the picker said so from the
  first frame.** Choosing Observatoire from the picker visibly changed the picture it claimed to
  already be showing. Kept exactly as it was, as `SimulationModel.openingLook`, because every
  rendered comparison in these notes was made there — but the picker still lies, and reconciling
  the two is a look-tuning decision, not a refactor.
- **The setup preview ignored the eight fields with no slider.** It matched at startup only
  because `RenderSettings`'s defaults happened to equal the model's, and diverged the moment a
  named look was chosen: kernels, bloom knee, diffraction pattern and star size never reached it.
  It builds from `renderSettings` now, so the preview is a preview.

A render is the only proof a change like this is neutral. `--selftest` writes `out/selftest.png`
and is deterministic to the byte; both commits here left it identical.
