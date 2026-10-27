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

The picture and the look file stay the model's (`SimulationModel.lookFile`); the session edits
them and adds what the editor needs. It forwards the few model changes the inspector reads and
nothing else, because the model publishes on every played frame.

## Choices

- **A rendering is everything but the colours and the camera.** A click takes a look's light,
  instrument and buffers and keeps the palette, its world, the plan and the field of view, as
  `StyleAuto.apply` does. "Avec ses couleurs" takes the look's palette and world too. All 42
  looks of `looks/` are offered, Hubble and Webb first: the plan names them all, and #114 turns
  the names into thumbnails.
- **The Télescope / Libre switch drives the proposals and Auto, not the rendering list.** A
  palette applied writes its world into the file; a rendering alone does not change it.
- **Proposals are the best six of a round.** Each round draws `PaletteAuto`'s 48 candidates from
  the scene's seed (shifted per round) and keeps the best six by `PaletteScore`, so "Autres
  palettes" never gets worse. Up to five galaxies, the generator's limit.
- **Auto picks the pair**, as the plan says: `StyleAuto.choose` in the switch's world, then the
  best rendering and palette go on the current file with the locks and the camera kept. It says
  what it chose and its score.
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

## Checks

- `--lookcheck <take>` drives the session on the opened take: rendering alone and with its
  colours, six proposals and another round, a lock through a new palette, camera mode and
  rotation, two resets, Avant/Après, Annuler (nothing written), Utiliser pour la scène
  (`look.json` is the style on screen, the explored look kept in `look-raw.json`), and Auto when
  the take sits in a scene folder.
- `--navcheck` opens the editor from the library, leaves it for the queue and comes back, then
  closes it.
- `--uishot` writes `out/ui-style-bar.png`, `out/ui-style.png` and `out/ui-style-fine.png`.
