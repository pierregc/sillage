# Working notes

Design history and measurements behind the code: what was tried, what was measured, and why
things are the way they are. Moved out of the local `CLAUDE.md` so it is not loaded into every
session. Read the note for an area before changing it.

## Workflow and the machine

- [There is no CI](no-ci.md): why `./scripts/dev.sh check` is the gate
- [This machine](this-machine.md): no Xcode, broken SwiftPM, the app's verification modes
- [Long runs](long-runs.md): memory, divergence, measuring under contention
- [A run stops when nobody is watching it](app-nap.md): App Nap, `beginActivity`, `--soak`
- [Keeping the machine usable](machine-usable.md): visible particles first, utility queue, force chunks

## Solver

- [A float cannot count past sixteen million](float-node-ranges.md): `BHNode` ranges, reading a crash report
- [A step was serial, and the overlap is not free](step-overlap.md)
- [Why a step no longer gets slower](step-cost-growth.md)
- [Quadrupoles, and why the orbit chose the angle](quadrupoles.md)
- [The tree on the GPU](gpu-tree.md): and the gap the frames were using
- [Encounters placed from their pericentre](encounters.md)
- [Whole stories](whole-stories.md): when a scene's story is over, and how long clips run
- [A black hole outside the tree](black-holes.md): its own softening, the step, energy across the mass range

## Physics and galaxies

- [Star formation, and why density alone gives no burst](star-formation.md)
- [One age per particle](one-age-per-particle.md)
- [A galaxy that keeps its colour](galaxy-colour.md)
- [Several colours per galaxy](galaxy-colours.md): the mapping per world, blend, birth radius
- [Several colours per galaxy, in the generator and the editor](multicolour-palettes.md): the switch, the ramp limits, the scores
- [What was actually cooking the disk](disk-heating.md)
- [Why a disk keeps its arms](spiral-arms.md)
- [Why a merged disk stays merged](merged-disk.md)
- [A breathing core, and a bulge with no edge](breathing-core.md)
- [Why the red went out](red-population.md): and what a constant population costs
- [Gas in filaments](gas-filaments.md): and which frame a dust lane lives in
- [What Hubble and Webb pictures are made of](telescope-colour.md): reference colours for the Télescope world
- [Scoring a palette, and the Auto palette](palette-score.md): the five parts, the reference tones, what Auto picks

## Capture and playback

- [A long capture keeps every frame](long-capture.md): spilling to disk instead of thinning
- [Takes on disk](takes-on-disk.md): `RecordingFile` format and memory peaks
- [What a played-back frame costs](playback-frame-cost.md): `SnapshotStream`
- [Two things that made a replay a slideshow](replay-slideshow.md): `--replayswitch`, `--replay`

## Rendering and the app

- [The picture is not free](the-picture-is-not-free.md): on-demand preview
- [What the window costs](what-the-window-costs.md)
- [Two scintillations, and which slider reaches which](scintillation.md): `--flicker`
- [Flying rather than orbiting](fly-camera.md): `FlyCamera`
- [The model, and why it is still one file](simulation-model.md): `SimulationModel`
- [Contemplation](contemplation.md): `--cinema`, `treeReuse`, frame pacing
- [Favourite palettes](favourite-palettes.md): `palettes/`, the heart, where favourites come first
- [The style editor](style-editor.md): renderings, palettes and locks, Auto, Avant/Après
- [Making a galaxy read as matter rather than as a graphic](galaxy-as-matter.md)

## State

- [State and known limitations](state-and-known-limitations.md): standing gaps, time step and traversal measurements
