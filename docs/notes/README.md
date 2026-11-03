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
- [Four scenes in five are pairs](pairs.md): the pair share by place, the pick slots, batches started before
- [Whole stories](whole-stories.md): when a scene's story is over, and how long clips run
- [A black hole outside the tree](black-holes.md): its own softening, the step, energy across the mass range
- [Another language would not make a step faster](solver-language.md): GPU against CPU, Swift against C, the opening angle explore and hires run at
- [Light tracers](light-tracers.md): drawing 8 M for the price of 2 M, what stays on the mass, star formation without a leaf

## Physics and galaxies

- [Star formation, and why density alone gives no burst](star-formation.md)
- [One age per particle](one-age-per-particle.md)
- [A galaxy that keeps its colour](galaxy-colour.md)
- [Several colours per galaxy](galaxy-colours.md): the mapping per world, blend, birth radius
- [Several colours per galaxy, in the generator and the editor](multicolour-palettes.md): the switch, the ramp limits, the scores
- [What was actually cooking the disk](disk-heating.md)
- [Why a disk keeps its arms](spiral-arms.md)
- [The calm-disk probe](calm-disk-probe.md): `probe-disk`, one galaxy alone, its own frame, the columns and how to read them
- [Why a generated disk takes several turns to settle](disk-settling.md): spike #170
- [Why settled arms stay lumpy and wobbly](lumpy-arms.md): spike #171, the small spirals and the response drawn for them (#181), and a steady spiral drive (#180)
- [Why a merged disk stays merged](merged-disk.md)
- [A breathing core, and a bulge with no edge](breathing-core.md)
- [Old stars seen edge-on and face-on](old-stars-by-angle.md): the outskirts' light, no young stars in the bulge
- [Why the red went out](red-population.md): and what a constant population costs
- [Gas in filaments](gas-filaments.md): and which frame a dust lane lives in
- [What Hubble and Webb pictures are made of](telescope-colour.md): reference colours for the Télescope world
- [Scoring a palette, and the Auto palette](palette-score.md): the five parts, the reference tones, what Auto picks

## Capture and playback

- [A long capture keeps every frame](long-capture.md): spilling to disk instead of thinning
- [Takes on disk](takes-on-disk.md): `RecordingFile` format and memory peaks, the curves a take without disk states reads them from
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
- [Gigantism](gigantism.md): why a render reads as sand, the compact minority, the kernel in projection, what more particles cost
- [A web of dust that turns without tearing](dust-web.md): spike #173, the web carried round and renewed, finer grains, the web where the disk is intact; #200, the lace baked and paid once per pixel; #197, on in the shipped and generated styles
- [Ten times the particles](ten-times-the-particles.md): fifty million a galaxy, what it looks like, the softening floor, the halo, the take's grid, tracers
- [Director shots that fill the frame](director-shots.md): `ShotPlan`, the cuts, the core and plane measured on the take, the disk states takes never carried

## State

- [State and known limitations](state-and-known-limitations.md): standing gaps, time step and traversal measurements
