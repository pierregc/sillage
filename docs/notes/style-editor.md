# The style editor

**Choisir le style** on a scene page opens the style editor (#113) in the detail area, in place
of the workshop's 290 px column of 45 controls. The take plays in the canvas with a transport
bar under it; an inspector on the right holds Rendu, Palette, Caméra and the folded Réglages
fins; the top bar says Modifié and saves.

## Where things live

| Piece | Where |
| --- | --- |
| What the editor does to a look file: a rendering over the palette, a palette with locks, a group put back, the rotation | `StyleEdit.swift` (`SillageRender`), tested in `StyleEditTests` |
| The session: the saved style, proposals, locks, Auto, Avant/Après, Annuler, promote | `StyleSession.swift` |
| The views | `StyleEditor.swift` |
| Opening and leaving, the sidebar row | `AppNavigation.tune`, `leaveStyle` in `MainView.swift` |
| The Rendu thumbnails: when they are drawn, on which queue | `StyleThumbnails.swift` |
| Drawing them: the cache, the renderers built side by side, the sliced splat | `RenderingThumbnails.swift`, `LookSheet.build`, `Renderer.render(camera:slice:pacer:)` |
| Where the canvas leaves the GPU free | `CanvasPacer.swift` |
| The export's camera at the playhead, scrubbed both ways | `PlanPlayhead.swift` (`SillageRender`), tested in `PlanPlayheadTests`; `planShot` in `SimulationModel` |
| What the mouse does to the plan | `CameraPlan.turned` and `zoomed` in `StyleEdit.swift`; `drag` and `scroll` in `CameraControl.swift` |

The picture and the look file stay the model's (`SimulationModel.lookFile`); the session edits
them and adds what the editor needs. It forwards the few model changes the inspector reads and
nothing else, because the model publishes on every played frame.

## Choices

- **A rendering is everything but the colours and the camera.** A click takes a look's light,
  instrument and buffers and keeps the palette, its world, the plan and the field of view, as
  `StyleAuto.apply` does. "Avec ses couleurs" takes the look's palette and world too. All 42
  looks of `looks/` are offered, Hubble and Webb first: the plan names them all.
- **Each rendering is a thumbnail of the frame on the canvas (#114)**, drawn with the style's
  palette and camera plan through the camera on the canvas, at the clip's size (the hires
  size when there is one, as Auto does) and scaled to 192 px, because stars and spikes are
  sized in pixels (#22). They are drawn on their own queue and kept by frame, camera and look,
  so coming back to a frame or a palette draws nothing. They are drawn again when the playhead
  has moved more than a tenth of the take, when the palette, its world, the camera plan or the
  field of view changed (a rendering applied changes none of them), and with the button next
  to "Rendu", which also takes the camera as it is now. A tile keeps its last picture until the
  new one arrives.
- **The canvas goes first.** Two command queues share the GPU rather than take turns, so a
  canvas frame drawn beside a thumbnail took four times as long (7 ms to 30 ms at 2 M). The
  thumbnails' splat is cut into command buffers of 250 000 particles, and `CanvasPacer`, told
  by the canvas when each frame finishes, holds each one until it fits before the next frame
  starts. A canvas that has no gap left (its own frame already takes more than 16.7 ms) gets
  one slice after each of its frames, so the thumbnails take longer rather than cost it frames.
  The sliced picture is the same picture, byte for byte (`aSlicedSplatDrawsTheSamePicture`).
- **The renderers are built four at a time.** Each costs a quarter of a second at 2 M on one
  core and the catalogue needs fourteen; all at once starved the main thread enough to lose
  canvas frames.
- **The Télescope / Libre switch drives the proposals and Auto, not the rendering list.** A
  palette applied writes its world into the file; a rendering alone does not change it.
- **Proposals are the best six of a round.** Each round draws `PaletteAuto`'s 48 candidates from
  the scene's seed (shifted per round) and keeps the best six by `PaletteScore`, so "Autres
  palettes" never gets worse. Up to five galaxies, the generator's limit.
- **Auto picks the pair**, as the plan says: `StyleAuto.choose` in the switch's world, then the
  best rendering and palette go on the current file with the locks and the camera kept. It says
  what it chose and its score. The rendering goes on as `StyleAuto.generated` gives it, its dust
  held back (#174), and Rendu still names it; a click on its tile brings its dust back.
- **Réinitialiser goes back to the last rendering applied** for Lumière, Instrument and Rendu
  détaillé, since resetting the light of a new rendering to the old one's would mix two looks;
  and to the saved plan for the camera.
- **Avant/Après is ⌥ held, or the button held.** A modifier works on any keyboard layout and
  whatever has the focus. While held, the saved style is on the picture and nothing in the
  inspector can change.
- **Annuler** puts the saved style back and returns to the scene page; it reads Fermer when
  nothing changed. **Utiliser pour la scène** (⌘S, which is "Enregistrer le look" elsewhere)
  promotes the style; once the style is the scene's, **Exporter…** is the main button and opens
  the export sheet of #106, whose jobs go to the queue.
- **The session survives the sidebar.** Going to the queue and back keeps the edits; a row
  "Style de scene-…" sits under the library while the editor is open. Choosing the style of the
  scene already on the canvas puts its saved style back rather than reading the take again.
- **The workshop's running panel has no look file section any more**; it keeps its live sliders.
  File > Ouvrir un look and Enregistrer le look sous stay in the menu.

## The canvas frames what the export frames (#177)

Pierre styled `2026-10-30-b/scene-0031` in Réalisateur, placed the camera well on the canvas,
and the WhatsApp export came out far too wide. Replayed headless, the export's camera stood 1.7
to 2.8 times further than the canvas's over the clip, median 2.4, and frame 552 of his video
sits 1.3 levels of 255 from the export's replay drawn again (means of 8 × 8 blocks), the canvas
10.4. Three things together:

- **In Réalisateur and Immergé the canvas could not show the plan.** `planCamera` gave nil for
  the director, which "cannot be scrubbed", so the canvas showed the orbit rig and "Voir à
  travers le plan" was only for Auto and Fixe.
- **The zoom acted on the export unseen.** `framedRadius` divides the measured radius by the
  zoom and the director frames that radius: his 0.445 made every shot 2.25 times wider.
- **The mouse never reached the file.** Dragging and scrolling moved the rig, which nothing
  copies into `LookFile.camera`.

Auto was off too, in a quieter way: the canvas framed each frame afresh, the export eases.

What changed:

- **The canvas draws the export's own `ShotReplay`**, in every mode, through `PlanPlayhead`, at
  the canvas's aspect and the rate the take was captured (`SceneFolder.capturedRate`, the one
  the export uses). Auto and Immergé are replayed from the first frame, again whenever the
  playhead goes back or the file changes: 0.7 ms for the 921 frames of scene-0031. The
  director plans its shots from the whole take since #186 (`ShotPlan`), which any frame can be
  asked of; the plan reads the take once, off the main actor when the take opens in
  Réalisateur, and `replanned` gives it another camera plan or lens without reading it again,
  so an edit costs 0.1 ms rather than 0.8 s. The radius a plan measures is sorted once per
  take, since sorting two million radii on every edit would stall the sliders. Where the
  immersed director modulates the light, the canvas draws it as the export does (calmed
  spikes included).
- **The mouse edits the plan rather than a rig beside it** (chosen over a "Garder ce cadrage"
  button, which would need a free view turned back into a plan): a drag turns the start and
  end angles together, so the move over the clip is kept, and the wheel scales the zoom, or
  the named radius outside Auto, which the zoom does not reach. What is framed is what
  `look.json` holds. The director's wide shots follow the plan's angles, zoom and lens and its
  close shots turn to face them, so the mouse steers it too; the immersed director chooses its
  own angles and lens, so there a drag does nothing and those sliders are greyed. In both the
  legend under the canvas offers Passer en Fixe.
- **The zoom reads as distance**: the slider runs in octaves around one, and says "× 0,44 · 2,2
  fois plus loin".
- **The canvas keeps the clip's shape**, 16:9 for every night scene, so it frames the
  rectangle of 1080p, 4K and WhatsApp; Vertical and Carré show less on the sides.
- Unticking Voir à travers le plan gives the old free view, and the legend says the export
  does not keep it.

## Checks

- `--lookcheck <take>` drives the session on the opened take: rendering alone and with its
  colours, six proposals and another round, a lock through a new palette, camera mode and
  rotation, two resets, Avant/Après, Annuler (nothing written), Utiliser pour la scène
  (`look.json` is the style on screen, the explored look kept in `look-raw.json`), and Auto when
  the take sits in a scene folder. Then the framing (#177): in each of the four modes the
  canvas's camera against the first frame of an export started at the playhead, read off disk
  as `sillage-render export` reads it, at five playheads visited forwards and back; the
  immersed director's light on the renderer; a drag and the wheel in Immergé, in Réalisateur
  (and what an edit costs there) and in Fixe, saved with Utiliser pour la scène and framed
  alike by the export of `look.json`; the free view; and the cost of an immersed replay to
  the end of the take. A look file written before `glint` and
  `columnSmoothing` existed fails "ouvert puis enregistré sans changement": saving adds them.
- `--navcheck` opens the editor from the library, leaves it for the queue and comes back, then
  closes it.
- `--uishot` writes `out/ui-style-bar.png`, `out/ui-style.png`, `out/ui-style-fine.png` and
  `out/ui-style-director.png`, the camera section and the canvas's legend in Réalisateur.
- `--thumbcheck <take>` opens the take headless with a 1920×1080 canvas paced at 60 Hz, opens
  the editor and reports every pass: how long, and the canvas's frames alone and during. It
  checks the cache, that a rendering applied draws nothing, the tenth-of-a-take rule, a palette,
  a canvas with no gap, and writes `out/ui-style-thumbnails.png`. On the M4 Max with a 2 M take
  (`2026-10-25-night/scene-0023`, clip 960×540, 42 renderings), alone on the GPU:

  | Pass | Thumbnails | Canvas alone | Canvas during |
  | --- | --- | --- | --- |
  | First, renderers built | 2.2 s | 0–1 % late | 0 % late |
  | Another palette | 1.3 s | 4 % late | 1 % late |
  | Playhead moved past a tenth | 1.6 s | 0 % late | 0 % late |
  | Canvas with Hubble, 20 ms a frame | 15.6 s | 100 % late | 100 % late, same 21.3 ms |

  Peak footprint 3.5 GB, the take and fourteen renderers.
