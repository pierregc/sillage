# The videos drawn during the hires run (#239)

Step 3 of epic #236, two galaxies of 100 M stars in under a day. Until now a hires wrote a take
of every particle and `hires.mov`, and a night's videos were drawn afterwards from the take
(`look`, `export`). At 200 M no take of the whole history fits on a disk: 450 GB at six bytes a
star a kept frame. So the videos are drawn during the run, from the solver's floats, as
`hires.mov` always was, with the look, the camera and the shots `export` would give them.

## How it is built

**Two passes on one scene.**

- The **massive pass** (`hires --pass massive`, which passes `--massive-only` down) samples the
  draw as a run with tracers does, `[tracers | massive visible | massive halo]`, and drops the
  tracers before the solver is made: the very particles, masses and step of the full run, without
  its tracers. It writes the take of the massive particles, the curves, `hires.mov` and a
  `hires.json` that says `"pass": "massive"`. A plain 2 M run would not do: its 2 M are drawn
  from the scene at 2 M, while the massive particles of a run with tracers are a seeded quarter of
  the 8 M sample with their masses scaled up (`splittingLightTracers`).
- The **style step** works on that take as on any other: `look --style auto`, the style editor,
  and the director plans its shots on it.
- The **full pass** (`hires --pass full --export 4k,vertical`) runs the same draw again with its
  tracers and draws each frame, as soon as the solver has it, in every preset asked, straight into
  the encoders: `exports/<preset>.mp4`, at the export's size, codec and rate. It writes no take,
  no curves and no `hires.mov`, refuses to start without a massive pass of the same draw and
  steps, and adds `full` to `hires.json` (presets, frames, seconds, drawing seconds per preset,
  peak memory, key frames, drift).

**One drawing, two callers.** `RunVideos` (Sources/SillageRender/RunVideos.swift) draws through
the same code an export does: `TakeExport.replay` gives each preset's camera from the massive
take (the director's `ShotPlan` is made once from it and handed to every preset), and
`TakeExport.prepare` sets the shot's look, the time and the painted arms from the massive take at
the captured frame. Only the positions and the smoothing are the run's: the renderers read the
solver's buffers, and the smoothing field the run already refreshes every frame. A unit test
feeds the full pass a take's own positions and checks every frame of two presets against
`export`'s, to the byte, with the auto, fixed, immersed and director cameras.

**Why the massive take frames the full pass**, rather than a plan kept in the scene folder: the
plan, the auto camera's easing and the fixed camera's radius are pure functions of a take and a
look, so the full pass, an export of the massive take and the style editor get the same shots by
reading the same take, and there is no file to keep in step with the look. `export --framing
<take>` draws any other take of the same run that way, which is how the comparison below was
made, and how a take of the full pass (`--take <path>` on it, the optional sampled take) would be
exported.

**One set of particle buffers.** A renderer holds 28 bytes a particle besides the positions
(population, luminosity, component, two traits, ramp key, galaxy): 5.6 GB at 200 M. Each preset
needs its own textures, but not its own copy of those: `Renderer(sharing:settings:)` reads them
from the run's renderer, and the presets are drawn one after the other into their writers. A
preset costs only its textures (about 0.7 GB at 4K with supersampling 2, 0.2 GB vertical).

**Key frames.** At the key frames of the massive pass's curves (`KeyFrames.pick`: start,
approach, pericentre, tails, end, those far enough apart) the full pass keeps every drawn
particle in `keyframes.sillage`, one stored frame each, `keyframes.json` saying which. It is a
take like any other, so `look --grid --take keyframes.sillage --frames 0,1,2` draws any style on
them, for posters and thumbnails.

## The massive part repeats the massive pass, to the bit

The tracers carry no mass and the tree is built over the massive particles alone, so the full
pass should move its massive particles exactly as the massive pass did. Two sums said otherwise:

- **The halo centres** were summed in blocks of 65 536 counted from particle 0. With 6 M tracers
  in front, the massive particles fell into other blocks than in the run without them, the double
  sums rounded differently, and a centre moved by a last bit now and then; the cooling and the
  nucleus picked from it carried that on, and chaos grew it. The blocks now start at the first
  massive particle (the existing test allowed 1e-5 kpc for this; it now asks for equality).
- **A black hole's reaction** was summed by threadgroups of 256 particles counted from 0, tracers
  included: zero contributions, but the massive ones grouped differently. The massive particles
  are now pulled in groups of their own; the tracers are pulled in a second dispatch whose
  reactions land where nothing reads them.

Neither change touches a run without tracers, which stays the same to the bit. With them, the
massive particles, their velocities, their formation times, the centres and the disk states of a
run with tracers equal the run without them after 40 steps, with and without a black hole
(`theMassiveParticlesRepeatTheRunWithoutTracersToTheBit`). The full pass also checks it live:
on every frame the massive take stored, it compares the solver's centres with the take's, and
prints and records how far they strayed (`drift`, 0 when identical).

MEASURED-DETERMINISM

## The exposure is the massive take's

A renderer divides every particle's light by the mean light per unit mass of the scene, read on
50 000 of its particles' formation times. A take carries the formation times the run ended on
(#150), and a star the run formed has a formation time after the start, which the stellar
population table reads as a negative age, clamped to its youngest: the brightest light per unit
mass there is. With 8 % of the particles formed by the end, the mean of a take is four times a
live run's: on scene-0031 of 2026-10-30-b the normalisation is 0.176 from its take and 0.679
from the same particles' ages at the start (0.182 and 0.764 on scene-0030). A live run, which
does not know yet what it will form, would draw its star light four times brighter than an export
of its own take.

Every style since #150 was chosen on takes, so the full pass draws as they do: its normalisation
is the massive take's, as an export of that take has it, and `export --framing` takes the framing
take's too. Whether the normalisation should leave the run's stars out everywhere (the intent its
comment states, "the ages the scene was sampled with") is a decision about every video's
exposure, and is left to a ticket of its own.

## Frame for frame against `export`

MEASURED-COMPARISON

## What drawing costs during the run

MEASURED-COSTS

## In the nights

`hires.passes` in the recipe: 1, a take of every particle and the videos exported from it after
the style; 2, the massive pass, the style on its take, then the full pass drawing every video
preset of the recipe. Auto is 1 up to 10 M drawn and 2 past it: at the night's 8 M a second pass
costs the massive run once more (17 minutes on scene-0031) for no gain in a night whose take
still fits (12 to 18 GB), while past 10 M the take reaches 20 GB and more (75 GB at 50 M). Without
light tracers there is nothing to draw in a second pass, and a night runs one.

The planner prices the hires step as the massive particles alone, and puts the whole full pass on
the first video preset's export step: the run with its tracers, and each preset's frames at the
`draws` line's cost for the count drawn. The other video presets are done with it, previews
(`webp`, `gif`) are exported from the massive take as before, and the disk counts the massive
take, the key frames and the videos. The runner runs `hires --pass massive`, the style, then
`hires --pass full --export <the presets left>`; a night resumed after the massive pass starts at
the full pass, and a scene whose take of every particle is already there is exported from it.
The report lists both passes, and counts a scene once.

## What is left

- #238 moves the tracers out of the solver's full buffers. The full pass reads the drawn positions
  in three places only: the renderers (the run's renderer's external positions, which every preset
  shares), the smoothing update, and the key frames' offer; `--massive-only` slices the sampled
  system, which #238's sampling by chunks would do by not keeping the tracers at all.
- At 200 M the run still keeps a `ParticleSystem` of every particle on the CPU (#238), and the
  smoothing builds a tree over every drawn particle each frame; both are #238's and #241's.
- A sampled take of the tracers (one frame in eight, for restyling later) is `--take <path>
  --take-interval 8` on the full pass at 8 M drawn; a subset of the tracers at 200 M is for #241.
