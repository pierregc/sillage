# The videos drawn during the hires run (#239)

Step 3 of epic #236, two galaxies of 100 M stars in under a day. Until now a hires wrote a take
of every particle and `hires.mov`, and a night's videos were drawn afterwards from the take
(`look`, `export`). At 200 M no take of the whole history fits on a disk: 450 GB at six bytes a
star a kept frame, 600 GB at the eight a take holds since #237. So the videos are drawn during the run, from the solver's floats, as
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

**One flow, two engines** (#278): the full pass is `FullPassRun`, which `sillage-render` runs on
Metal and `sillage-cuda` on CUDA, and `RunVideos` draws through a `RunVideoDrawing` each engine
gives it ([cuda-engine.md](cuda-engine.md#the-full-pass-278)).

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
  reactions land where nothing reads them (since #238, in their own pass).

Neither change touches a run without tracers, which stays the same to the bit. With them, the
massive particles, their velocities, their formation times, the centres and the disk states of a
run with tracers equal the run without them after 40 steps, with and without a black hole
(`theMassiveParticlesRepeatTheRunWithoutTracersToTheBit`). The full pass also checks it live:
on every frame the massive take stored, it compares the solver's centres with the take's, and
prints and records how far they strayed (`drift`, 0 when identical).

On scene-0031 of 2026-10-30-b at 8 M drawn from 2 M massive, the full pass's massive particles
were the massive pass's to the bit on all 232 frames the massive take stored: the quantised
positions, each frame's box, the centres and the disk states, compared byte for byte against a
take of the full pass's massive particles (`--take-massive`), and their formation times at the
end too. The live check printed the same: "repeats the massive pass to the bit over 232 stored
frames".

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

Measured on the same scene: two spirals, 923 frames, the Webb look with the director, whose plan
on the massive take is a close disk (frames 0 to 78), a wide shot, the pericentre (158 to 286), a
long wide shot (287 to 738) and the survivor close (739 to 922). The massive pass, then the full
pass drawing 4K and vertical with a take of every particle at interval 1 beside it (44 GB, for
this check only), then `export --take <that take> --framing <the massive take>` of both presets.
Thirteen frames of each were kept as PNGs on both sides, as the encoders took them
(`--draw-stills`, `--stills`).

| frame | shot | take step | 4K PSNR | 4K mean diff | 4K pixels off by > 8 | vertical PSNR | vertical mean diff |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 0 | disk 0 | 3.7 pc | 46.1 dB | 0.35 | 0.72 % | 48.4 dB | 0.24 |
| 50 | disk 0 | 4.2 pc | 44.2 dB | 0.50 | 1.16 % | 46.6 dB | 0.34 |
| 120 | wide | 4.9 pc | 57.2 dB | 0.03 | 0.04 % | 52.8 dB | 0.10 |
| 200 | pericentre | 5.9 pc | 46.4 dB | 0.32 | 0.68 % | 48.2 dB | 0.27 |
| 260 | pericentre | 6.6 pc | 45.7 dB | 0.43 | 0.67 % | 49.1 dB | 0.26 |
| 330 | wide | 7.3 pc | 53.6 dB | 0.09 | 0.09 % | 49.1 dB | 0.27 |
| 400 | wide | 8.1 pc | 51.3 dB | 0.17 | 0.15 % | 49.2 dB | 0.28 |
| 480 | wide | 9.0 pc | 49.2 dB | 0.28 | 0.24 % | 47.8 dB | 0.40 |
| 560 | wide | 9.9 pc | 49.2 dB | 0.28 | 0.25 % | 46.6 dB | 0.49 |
| 650 | wide | 10.9 pc | 49.4 dB | 0.25 | 0.26 % | 45.7 dB | 0.54 |
| 750 | disk 1 | 12.0 pc | 42.8 dB | 0.80 | 1.54 % | 43.6 dB | 0.73 |
| 850 | disk 1 | 13.2 pc | 41.6 dB | 0.95 | 2.19 % | 42.3 dB | 0.92 |
| 922 | disk 1 | 14.1 pc | 40.7 dB | 1.09 | 2.79 % | 41.4 dB | 1.07 |

Levels are 8-bit. The largest single differences, 137 at 4K and 121 vertical, are the edges of
bright compact stars moved by a fraction of a pixel: on the first 4K frame, 504 pixels differ by
more than 32 levels, in 405 spots of one pixel at the median, where the frame is at level 140
against 23 for the whole frame. The two draw the same picture: no difference of camera, cut,
colour or exposure shows in any frame. What differs is the positions. The take keeps each axis in 16 bits over a box that
holds every particle drawn, and that box grows from 244 kpc on the first frame to 923 kpc on the
last as a few particles fly out, so the step grows from 3.7 to 14.1 pc, and a quantised position
sits up to a step below the float one (the take truncates; since #237 it holds 21 bits an axis
and rounds, see `takes-on-disk.md`). In the closing shot a 4K pixel is
about 19 pc of the disk, so the take moves the stars by up to 0.7 px there; the kernels also come
from a tree built on those positions, and a particle that crosses a cell boundary changes its
kernel. The difference follows the step and the framing: 57 dB on the wide shot at frame 120, 41
dB in the closing close-up. Given the take's own positions instead of the solver's, the full pass
draws every frame of both presets to the byte as `export` does (the unit test above), so the
quantum is all there is between them.

Both are far below what the encoder itself does. Decoded from the two MP4s, the run's 4K video and
the export's differ by 35.6 to 38.2 dB on frames 0, 120, 480 and 922, while each video differs
from its own frames before encoding by 29.2 to 36.7 dB.

## What drawing costs during the run

Alone on the GPU (M4 Max, the lock held), per frame drawn, the solver's time apart. A preset's
time is drawing it and handing it to its encoder, which runs on its own queue behind three frames
in flight; the smoothing is once a frame for every preset.

At 8 M drawn from 2 M massive, the whole story of scene-0031 (923 frames, Webb, supersampling 2):

| | 4K | vertical | smoothing |
| --- | ---: | ---: | ---: |
| mean | 100.9 ms | 49.7 ms | 17.2 ms |
| median | 98.8 ms | 50.0 ms | 16.8 ms |
| 95th percentile | 126.7 ms | 59.1 ms | 20.0 ms |
| first frame | 563.9 ms | 150.1 ms | |
| disk 0, close (0 to 78) | 98.7 ms | 42.2 ms | 17.4 ms |
| wide (79 to 157) | 62.9 ms | 41.7 ms | 17.9 ms |
| pericentre (158 to 286) | 98.3 ms | 48.2 ms | 17.3 ms |
| wide (287 to 738) | 97.3 ms | 50.3 ms | 17.3 ms |
| disk 1, close (739 to 922) | 128.8 ms | 55.8 ms | 16.7 ms |

The run itself took 2 006 ms a frame (eight steps of 246 ms), so drawing both presets added 7.5 %
to the frames: 139 s of 2 458 for the whole pass. Exporting the same two presets from the 8 M
take afterwards took 107 and 67 s, which decode the take as well: drawing during the run costs
what an export costs, and needs no take. The full pass peaked at 12.1 GB, and that with a take of
every particle beside it for the check, 3 GB of it held in memory. The massive pass took 18 min
(13.5 s of it sampling the 8 M and dropping the tracers), peaked at 7.4 GB and wrote a take of
2.84 GB.

At 30 M drawn from 2 M massive, the first 120 frames of the same story, framed on the 8 M run's
massive take so that they are the same shots (the close disk to frame 78, then wide). The same
120 frames of the 8 M run beside them:

| frames 1 to 119 | 8 M | 30 M | a particle drawn |
| --- | ---: | ---: | ---: |
| 4K | 79.6 ms | 212.4 ms | 6.0 ns |
| vertical | 39.4 ms | 127.0 ms | 4.0 ns |
| smoothing | 17.6 ms | 64.5 ms | 2.1 ns |
| a step of the run | 243 ms | 712 ms | 21 ns |

Drawing is linear in the particles drawn, a fixed part for the pixels (about 31 ms at 4K and 8 ms
vertical on these shots) and the rest for each particle: the vertical preset has a quarter of
4K's pixels and two thirds of its cost a particle, which is the splatting rather than the fill.
Over a whole story the later shots cost more (the whole story at 8 M is 1.27 times its first 120
frames, 4K and vertical alike), so the cost model's fallback is that line scaled to the whole
story: 40 ms + 7.6 ns a particle a 4K frame, 9.5 ms + 5.0 ns a vertical one (and for any preset
of 1080p's pixels). That gives 101 and 50 ms at 8 M as measured, 0.42 and 0.26 s at 50 M, and 1.56
and 1.01 s at 200 M, where the step itself will be about 4 s, 32 s a frame: drawing both presets
adds about 8 % to a full pass at 200 M, as it did at 8 M. Every full pass refits these lines from
its `hires.json` (`draws` in `costs.json`).

50 M was planned and not run: the Mac had 16.9 GB free with 7.5 GB already in swap that night, and
a 20 M probe of the full pass peaked at 10.5 GB (the 30 M run at 11.1 GB, under that pressure).
With today's tracers a full pass holds every particle about five times over (the sample, the
solver's buffers, its CPU copies, the renderer's attributes, the smoothing tree), which #238
takes apart; #241 measures 50 M once it has.

## In the nights

`hires.passes` in the recipe: 1, a take of every particle and the videos exported from it after
the style; 2, the massive pass, the style on its take, then the full pass drawing every video
preset of the recipe. Auto is 1 up to 10 M drawn and 2 past it: at the night's 8 M a second pass
costs the massive run once more (18 minutes on scene-0031) for no gain in a night whose take
still fits (12 to 18 GB), while past 10 M a long story's take passes 20 GB (scene-0031's 923
frames would take 71 GB at 50 M). Without light tracers there is nothing to draw in a second
pass, and a night runs one.

The planner prices the hires step as the massive particles alone, and puts the whole full pass on
the first video preset's export step: the run with its tracers, and each preset's frames at the
`draws` line's cost for the count drawn. The other video presets are done with it, previews
(`webp`, `gif`) are exported from the massive take as before, and the disk counts the massive
take, the key frames and the videos. The runner runs `hires --pass massive`, the style, then
`hires --pass full --export <the presets left>`; a night resumed after the massive pass starts at
the full pass, and a scene whose take of every particle is already there is exported from it.
The report lists both passes, and counts a scene once.

A night of two previews at 5 000 a galaxy and one pick drawn at 40 000 from 10 000, in two
passes, ran its exploration, the pick, the massive pass, the style, the full pass (1080p and
square) and the GIF in 30 s; the same night run again redid nothing.

## What is left

- #238 moves the tracers out of the solver's full buffers. The full pass reads the drawn positions
  in three places only: the renderers (the run's renderer's external positions, which every preset
  shares), the smoothing update, and the key frames' offer; `--massive-only` slices the sampled
  system, which #238's sampling by chunks would do by not keeping the tracers at all.
- At 200 M the run still keeps a `ParticleSystem` of every particle on the CPU (#238), and the
  smoothing builds a tree over every drawn particle each frame; both are #238's and #241's.
- A sampled take of the tracers (one frame in eight, for restyling later) is `--take <path>
  --take-interval 8` on the full pass at 8 M drawn; a subset of the tracers at 200 M is for #241.
- The key frames are `KeyFrames.pick`'s, whose pericentre is the deepest approach in the curves:
  for a merger that is the coalescence, so scene-0031 kept its start, its approach and frame 914
  of 923. The first passage, which the director films, is not among them.
- `hires.mov` stays the massive pass's: the 2 M at the preview's size, as the scene page shows it.
- The take's exposure, four times dimmer than a live run's (above), wants a ticket of its own.
