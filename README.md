# Sillage

A hobby N-body simulator for galaxy collisions on Apple Silicon. The models are taken from the
standard literature, and what they are pointed at is a picture worth looking at rather than a
research result.

![Two galaxies through a prograde encounter](docs/merger.webp)

## Running it

macOS 14 or later on an Apple Silicon Mac.

```bash
git clone https://github.com/pierregc/sillage.git
cd sillage
./scripts/dev.sh app && open .build/dev/Sillage.app
```

The app opens on a setup screen: add galaxies, set their masses, radii, inclinations and spins,
then start the run. Drag to orbit, scroll to zoom, `F` to fly, space to pause. Presets are
`encounter`, `merger`, `flyby` and `disk`.

`./scripts/dev.sh test` runs the suite, and `./scripts/dev.sh render` writes an image sequence
without opening a window, which is how the animation above was made. Everything goes through
that script rather than SwiftPM: with only the Command Line Tools installed, no manifest will
compile. Shaders are built at runtime, so Xcode is not needed either way.

Every render writes a scene file beside its output, `x.png` or `x.mov` giving `x.scene.json`
(`--scene-out` picks another path). It holds the physics and nothing else: the seed, the
encounter, each galaxy's parameters and its share of the particles, but no colour and no
particle count. `./scripts/dev.sh render --scene x.scene.json --particles 5000000` replays the
same scene at any size; flags given alongside it override the file.

A look file sits beside it, `x.look.json` (`--look-out` for another path), holding everything
that decides the image and nothing that decides the physics: the render settings, the colour
of each galaxy, and the camera, fixed or left to the director. `--look x.look.json` draws with
it, and every look flag given alongside overrides its field. A field left out takes the value
`sillage-render` uses with no flags, so a file names only what it changes. The two files
together replay a render exactly. `looks/raw.look.json` is plain points with no effects: one fixed-size point per particle in its
galaxy's tint, drawn in a single pass (about a third of the GPU time of the full render), with
the `auto` camera, which keeps every galaxy in frame.

A generated scene draws its physics and its colours from two separate streams of the seed.
`--look-seed N` repaints `--preset contemplation --seed S` with another palette and leaves
every physical parameter where it was. Scenes drawn before the split keep their physics;
`--look-seed S`, the seed itself, gives them back their old colours too.

An encounter is described by its geometry rather than by where the galaxies start: the
pericentre distance, the eccentricity (below one bound, one parabolic, above one hyperbolic,
judged against the potential the two galaxies really exert there), the mass ratio, when the
pericentre falls, each disk's inclination and line of nodes against the orbital plane with its
spin, and where that plane lies. The scene file keeps them under `encounters`, next to the
positions and velocities they gave, which are what a replay runs from. Those are worked out
backwards: each secondary is set at its pericentre beside where its primary actually is at that
moment, then stepped back to the start through the galaxies already placed, every galaxy
pulling with the mass it holds inside the separation. The centres are then run forward together
and the passages asked for are corrected until they land. A generated scene puts its
pericentres inside the clip it is rendered for, between `--settle` and `--steps`.

`--preset free --seed S --index N` is scene `N` of batch `S` from the free generator, which
spreads a batch evenly over everything a scene can physically be: one to five galaxies, each a
spiral, a lenticular disk, an elliptical, a dwarf or a compact globular, with their arm count,
arm pitch, bulge and thickness, the mass ratio and the geometry of each encounter. What changes
a scene most is drawn from a Sobol sequence shifted by the batch seed, so a batch covers the
space instead of clumping; the rest comes from a stream seeded by the scene. A candidate whose
signature (galaxy count, the first two galaxies, the first encounter) sits closer than
`--spacing`, 0.3 by default, to a scene already in the batch is passed over, and the scene file
records how it was drawn under `draw`: the generator, the batch seed, the index, the point of
the sequence and each galaxy's family. The batch is replayed up to the index, without a
particle, so a scene is found again from those two numbers alone.

A batch also holds archetypes, known interacting systems as starting points: `antennae`
(NGC 4038/9), `mice` (NGC 4676), `ring` (a head-on collision, as in the Cartwheel), `tadpole`
(UGC 10214), `polar-ring` (NGC 4650A), `minor-merger` and `compact-group` (in the style of
Stephan's Quintet). Each is a set of galaxies and encounter geometry with ranges of its own,
narrow enough that it reads as what it is named after: the Antennae are two comparable spirals,
both prograde and steeply inclined, on a bound orbit; the ring is a compact companion dropped
through a disk along its axis. One scene in four is an archetype, `--archetypes 0.4` for
another share and `0` for free draws only. Which places are archetypes follows from the share,
so every stretch of a batch holds it, each archetype comes once in every seven archetype places
in an order shuffled each time, and the free places take the free draws in order.
`--preset antennae --seed S --index K` draws the Antennae alone: their scene `K` of batch `S`,
the same one the batch draws when they come round for the `K`-th time. `draw.generator` in the
scene file names the archetype, or `free`, and the library's archetype filter reads it there. One
reference per archetype at exploration settings, five moments of each clip:
[`docs/archetypes.jpg`](docs/archetypes.jpg).

A generated scene is judged before any particle is drawn. The galaxy centres are run alone
through the clip, in a millisecond, and the scene is refused when none of its pairs comes
closer than their disks' combined radii inside the clip, when a disk's Toomre Q leaves 1 to 3,
when two galaxies start closer than half the sum of the radii holding nine tenths of their
light, or when the frame the clip needs grows past four times the one it opens on, which is
the widest shot the director takes. A lone disk has no encounter to find and passes. `sillage-render`
prints `rejected` with the reasons and exits with status 3; `--check-only` prints the numbers
and stops, `--no-check` renders anyway, and `--check` judges a scene read from a file.
`scripts/library.sh` drops a rejected seed, logs the reason in `library.log` and draws the
slot's next seed, and ends by printing how many draws were rejected.

New here? [docs/night-manager.md](docs/night-manager.md) is the short user guide to the whole
night batch, rating, hires, look and export workflow.

## Scene folders

A scene goes through four stages, each one command that reads and writes the scene's own
folder, so moving it on or doing a stage again needs the folder and nothing else:

```
library/<batch>/
    index.csv              the batch: one row per scene
    ratings.json           yes, no and a rating per scene
    <scene>/
        scene.json         the physics
        look.json          the image
        clip.json          how long the clip runs, where its story starts and ends, how large it is drawn
        preview.mov        the exploration clip
        thumbnail.png      one still from the middle of it, 480 px wide
        curves.csv         per frame separation, extent, stars formed, tails, disruption and centres
        interest.json      the interest score and the features it comes from
        hires.mov          the same clip at high resolution, raw, at the preview's size
        curves-hires.csv   its curves, in the format of curves.csv
        hires.json         the particle count, steps and settings it ran with, and its cost
        take.sillage       the run at full size, for the later stages
        looks/             the look stage's grid.png and one .look.json per row
        look-raw.json      the look explore wrote, once another is promoted over it
        exports/           the finished videos
```

```bash
./scripts/dev.sh explore library/2026-10-23/scene-0001 --seed 42 --index 1 --director
./scripts/dev.sh hires   library/2026-10-23/scene-0001 --particles 2000000
./scripts/dev.sh look    library/2026-10-23/scene-0001
./scripts/dev.sh export  library/2026-10-23/scene-0001
```

`explore` renders the preview, the thumbnail and the curves. In an empty folder it draws a
self-gravitating scene of a generated batch from the options given, `--seed` the batch and
`--index` the scene in it (`--preset contemplation` still draws the old way); once
`scene.json`, `look.json` and `clip.json` are there it reads them back, so running it again
with no options gives the same clip, and any option given overrides the file it belongs to.
The clip's options are `--particles`, `--width`, `--height`, `--frames`, `--fps`, `--steps` and
`--settle`. To start a scene over, empty its folder. The same stages are
`sillage-render <stage> <folder>`.

**Whole stories.** `explore` does not stop at the planned frames while the scene's story goes
on: it keeps capturing at the same cadence until the story is over, up to 2 Gyr of simulated
time (`--story-cap <Myr>`, 0 to stop at the planned frames). The story starts 150 Myr before the
first collision and ends once no pair will come closer again before the cap and tails, extent
and disruption have stayed quiet for 150 Myr, or at the latest 400 Myr after the last pair was
inside its reach. `clip.json` keeps the frames that ran and the story's frames and
megayears, with `complete` false for a story still going at the cap.
`sillage-render story <scene or batch folder>` judges curves already written the same way. The
detector and its measured thresholds are in
[docs/notes/whole-stories.md](docs/notes/whole-stories.md).

### High resolution

`hires` runs the scene again from its `scene.json` at `--particles`, by default this Mac's
maximum, and writes `take.sillage`, `hires.mov`, `curves-hires.csv` and `hires.json` beside the
preview without touching it. Given a batch folder instead of a scene, it runs every scene marked
yes in `ratings.json`, one after another, skipping those already done at that size.

Only the particle count and what follows from it change. The geometry is the scene file's, and
so is `timeStepScale` (3.5 for a night batch) unless `--dt-scale` overrides it. Softening follows
the interparticle spacing, so the step shrinks as the count grows, and `clip.json`'s `steps` and
`settle` are step counts at the preview's size: run as they are, they would show a shorter stretch
of the encounter. They are turned into megayears and back, with a whole number of steps per
frame, so every frame lands at the time the preview showed it and only the settle is rounded to
the nearest step. Only the story is captured: what comes before it is settled through, and
nothing after its end is run. `--frames N` runs the first N frames of it at the same cadence,
for a quick look.

The maximum is a setting of the machine, `SILLAGE_MAX_PARTICLES`, not of the scene; asking for
more is refused. It defaults to ten million on the M4 Max with 36 GB, the most measured, and
`hires` prints how long a run should take before it starts, at 150 ns per visible particle per
step.

Measured on a two-disk flyby explored at 400 000 particles (batch 20261024, scene 1, 700 Myr
over 900 frames at `--dt-scale 3.5`). Live halos add one and a half times the visible count to
what is simulated. 5 M and 10 M ran the first 60 and 30 frames and are extrapolated, with the
10 % the cost of a step climbs over the clip at 1 M and 2 M.

| particles | step | steps | clip | peak memory | every frame | take, 1 in 4 |
| --- | --- | --- | --- | --- | --- | --- |
| 400 000 (preview) | 0.111 Myr | 400 + 7 200 | 7 min | | | |
| 1 M | 0.068 Myr | 650 + 11 700 | 30 min | 6.5 GB | 5.4 GB | 1.4 GB |
| 2 M | 0.049 Myr | 900 + 16 200 | 85 min | 11.4 GB | 10.8 GB | 2.8 GB |
| 5 M | 0.044 Myr | 1 000 + 18 000 | about 4 h | about 13 GB | about 27 GB | about 6.8 GB |
| 10 M | 0.044 Myr | 1 000 + 18 000 | about 8 h | about 16 GB | about 54 GB | about 13.5 GB |

The step stops shrinking past about three million, where it reaches the solver's floor. Memory
stays bounded because the take holds a quarter of the machine's memory (`--take-memory`, in MB)
and carries on in a scratch file past that; it needs twice the take's size on disk while it is
being written. The pericentre lands within a frame of the preview's at every size (223.2 Myr in
the preview, 224.0 at 1 M, 223.2 at 2 M), and the last frame within 0.1 Myr, the drift of the
solver's single precision clock.

The take keeps one frame in four (`--take-interval`, 1 to keep them all), and whatever draws it
again, the export or the application, draws the other three through a cubic between the kept
frames, its tangents taken from the frames on either side. A take written before the interval
existed reads as before. Measured on the 2 M take above, a frame every 0.89 Myr, against the
frames the interval dropped:

| interval | take | half the stars within | 99 % within | inside 1 kpc of a centre, half within |
| --- | --- | --- | --- | --- |
| 1 | 10.8 GB | | | |
| 2 | 5.5 GB | 0.008 kpc | 0.14 kpc | 0.03 to 0.08 kpc |
| 4 | 2.8 GB | 0.012 kpc | 0.44 kpc | 0.17 to 0.28 kpc |
| 8 | 1.4 GB | 0.043 kpc | 1.1 kpc | 0.4 to 0.7 kpc |

What does not follow is the nuclei, where an orbit takes a few megayears and is already only
sampled a few times per turn at every frame. Past two kiloparsecs from a centre, at 1 in 4, half
the stars are within 0.01 kpc of where they were. Rendered at 1920 x 1080 with the whole
encounter in frame, stills at 1 in 4 and 1 in 8 cannot be told apart from every frame, even
zoomed twice on a nucleus. The export draws the 900 frames in the same 14 s whatever the
interval. Played back at 2560 x 1440, the blend takes 0.4 ms at 2 M and 2 ms at 10 M either way,
and a whole frame takes 15.3 ms at 1 in 4 against 14.2 ms with every frame.

Compressing the positions as well was measured and left out. On top of 1 in 4, zstd on each
frame alone saves another 29 %, and predicting each frame from the two before it 47 %, but the
second decodes only in order, and both would give up the memory-mapped random access playback
and export rely on, for a smaller saving than the interval already makes.

### Looks

```bash
./scripts/dev.sh look library/2026-10-23/scene-0001                    # the grid
./scripts/dev.sh look library/2026-10-23/scene-0001 --base dream my.look.json
./scripts/dev.sh look library/2026-10-23/scene-0001 --promote standard-vivid
```

`look` draws the take, `take.sillage` from `hires`, with no solver: a few frames, several looks,
one grid in `looks/grid.png`, a row per look and a column per key frame. The rows are a base
look, `LookFile.standard` unless `--base` names a look of `looks/` or a file, then the base one
change at a time (brighter, dimmer, more and less colour, spikes, bloom, camera higher, lower,
closer, wider), then the catalogue in the repository's `looks/` (observatory, dream, gloss, ink,
ember and some thirty more: most with no gas, a discreet or absent starfield, few or no
spikes, each with colours of its own), then any `.look.json` given. A row keeps the scene's
palette, the one in its `look.json`, unless its file has a palette of its own. The base's
variants also include the base with its palette turned around the hue wheel (`hue-60` to
`hue-240`), `no-gas`, `no-stars` and `no-sky`. The rows are written 15 to an image, `grid.png`,
`grid-2.png` and so on. `--no-variants` and `--no-catalogue` leave rows
out, `--width` sets a cell's width (480), and `--take` draws a smaller take instead.

The key frames come from `curves-hires.csv`: the start, the approach (halfway in distance to the
pericentre), the pericentre (the smallest separation), the tails (the largest tidal fraction
after it) and the end, less any that fall within a twentieth of the clip of another. `--frames
0,150,299` picks captured frames by hand, `--times 120,300` the frames nearest those megayears.
Each column says whether its frame is one the take kept or one drawn through the cubic between
them. Every camera is played from the first frame to the key frame, so the auto camera's easing
and the director's cuts land where the full render puts them.

Every row's look is kept as `looks/<name>.look.json`. `--promote <name>` makes one the scene's
`look.json` for the export, moving the raw one explore wrote to `look-raw.json` the first time;
a later promotion replaces the earlier one, which stays in `looks/`.

A scene's palette can be chosen without a grid: `look <scene> --palette auto` scores a fixed
number of palettes drawn from the scene's seed and puts the best in `look.json`, promoted as
above, so the same scene always gets the same palette. `--palette <family>` does the same inside
one family, `--palette <file.palette.json>` takes a palette as it is (a `Palette` as `look.json`
records it, or just `{"colours": [[r, g, b], ...]}` in linear sRGB), and `--world telescope|free`
picks the colour world (free by default). `--base` starts from another look instead of the
scene's. `palettes <scene> --best 3` draws the three best-scored palettes of the scene on a
frame of its take, the score under each; see [the note](docs/notes/palette-score.md).

`look <scene> --style auto` chooses the rendering and the palette together, on the picture:
every rendering of the world (`--world`, else the world of the scene's look) is drawn with the
scene's best palette on three key frames at the clip's size, then the four best renderings with
the next three palettes, and each frame is scored on its pixels (clipped highlights, exposure,
colourfulness, how far apart the galaxies are drawn, sky noise and, in the telescope world, the
reference colours). The best pair is promoted, keeping the scene's camera; `--keep` only writes
`looks/auto-<world>.png` (the best three) and `looks/auto-<world>.json` (every pair's score). It
takes about 2 s in the telescope world and 8 s in the free one at 2 M particles; see
[the note](docs/notes/frame-score.md).

`export <scene> --palette auto|<family>|<file> [--world telescope|free]` draws that one export
with another palette, as `look --palette` would, and leaves the scene's `look.json` alone.

The grid compares; the application chooses. In the library, **Choisir le style** on a scene
that has a take opens the style editor: the take plays in the canvas with a transport bar under
it, and an inspector holds four sections. **Rendu** offers the 42 looks of `looks/` as
renderings: a click puts a look's light, instrument and buffers on the picture and keeps the
palette and the camera, **Avec ses couleurs** takes its palette too. **Palette** has a Télescope
/ Libre switch, one swatch per galaxy (a click opens a colour picker, a lock keeps that colour
through any new palette), six proposals from the generator with their score, **Autres
palettes**, and **Auto**, which draws three key frames with every rendering of the world and
applies the best rendering and palette (`--style auto` below). **Caméra** sets the plan's mode,
zoom and rotation over the clip. **Réglages fins**, folded, hold Lumière, Instrument, Rendu
détaillé (starfield, bloom levels, supersampling, plain points, which rebuild the renderer) and
the whole camera plan, each with **Réinitialiser**; **Voir à travers le plan** draws through
the plan at the playhead, so scrubbing shows the render's own framing. The top bar says
**Modifié** when the style differs from `look.json`, holding ⌥ or **Avant / Après** shows the
saved style for as long as it is held, **Annuler** puts it back, and **Utiliser pour la scène**
(⌘S) promotes it as `--promote` does, after which **Exporter…** is the main button. File > Open
takes any take (⌘O) and any look file (⇧⌘O) over the picture, ⇧⌘S saves the look anywhere, and
outside the editor ⌘S writes it back where it came from. A file opened and saved untouched is
the same file; see [the note](docs/notes/style-editor.md).
`Sillage.app --lookcheck <take> [look]` checks all of that headless and times scrubbing.

### Export

```bash
./scripts/dev.sh export library/2026-10-23/scene-0001                     # exports/1080p.mp4
./scripts/dev.sh export library/2026-10-23/scene-0001 --preset 4k --fps 60
./scripts/dev.sh export library/2026-10-23/scene-0001 --preset vertical --look dream --start 4 --duration 15
```

`export` draws `take.sillage` with the scene's `look.json` into `exports/<preset>.mp4`, HEVC
in an MP4 by default, frame by frame and as fast as the GPU goes. The presets are `1080p` (1920 x 1080, the
default), `4k` (3840 x 2160), `vertical` (1080 x 1920), `square` (1080 x 1080) and `whatsapp`
(see below); the others get six bits a pixel
a second of HEVC, twelve of H.264, since a galaxy is mostly faint gradient that a lean bit rate bands. `--width`,
`--height` and `--bitrate` (Mbit/s) override the preset, `--start` and `--duration` (seconds) cut
the clip, and `--fps` defaults to the rate the take was captured at; any other rate draws the
moments between captured frames through the same cubic the take's skipped frames use, and the
camera between the two captured frames around them. `--look` takes a file, a row of the look
grid by name or a catalogue look, `--take` another take and `--out` another path.

`--codec hevc|h264|prores` picks what the frames are compressed with, all on the media engine:

| codec | file | for | rate |
| --- | --- | --- | --- |
| `h264` | `<preset>-h264.mp4` | plays everywhere, older devices included | twelve bits a pixel a second |
| `hevc` (default) | `<preset>.mp4` | about half the bytes of H.264, tagged `hvc1` for QuickTime and iOS; compared by eye on a 4k clip, no visible difference | six bits a pixel a second |
| `prores` | `<preset>-prores.mov` | editing: ProRes 422 HQ, 10 bit | fixed by the size |

`--bitrate` steers H.264 and HEVC, `--quality` (0 to 1) replaces it with what the picture needs;
ProRes takes neither. The quality scale is steep, not linear: on a 10 s 1080p clip HEVC goes from
1 MB at 0.5 to 9 MB at 0.6, 27 at 0.65, 91 at 0.7 and 126 at 0.75, and the grain of the look
decides where a given picture lands, so try it on the take.

Every video leaves with the licence in its metadata: `Copyright <year> Pierre Gunet-Caplain, CC BY
4.0 (https://creativecommons.org/licenses/by/4.0/)`, the author, a title and description naming
the scene as `<batch>/<scene>`, and the creation date. The application's video export writes the
same. A movie (ProRes, and the application's `.mov`) keeps them as QuickTime keys, which Finder,
`mdls` and `ffprobe` show; an MP4 keeps them as user data atoms, which `AVAsset` reads back
(`ffprobe` and Spotlight skip those in an MP4, whatever wrote them).

The camera is replayed from the take's first frame exactly as the look grid replays it, through
the same code, so a cell of the grid and the same frame of the export are the same picture.
Every frame is drawn straight into a pixel buffer of the encoder's pool, a BGRA Metal texture
over it, and compressed on a queue of its own while the next one renders; the application's
video export and `explore`'s preview go through the same writer. Stars, spikes and kernels are
sized in pixels, so a 4k export shows them finer than a grid drawn at the clip's size.

Measured on the M4 Max with a 2 M take of 300 frames and the standard look, nothing else
running, the same over two runs:

| preset | frames a second | real time | file |
| --- | --- | --- | --- |
| 1080p | 36.9 | 1.23x | 31.8 MB |
| 1080p at 60 fps | 36.9 | 0.62x | 31.5 MB |
| 4k | 19.2 | 0.64x | 127.3 MB |
| whatsapp | 51.6 | 1.72x | 5.1 MB |

At 1080p 24 of the 27 ms a frame are the renderer's own GPU time, at supersample 2; expanding
the take and the smoothing field take the other 3, and handing the frame to the encoder costs
nothing that shows. A 400 k take exports at 110 frames a second at 1080p and 43 at 4k.

The codec changes the file, not the time: the encoders keep up with the renderer. On a 150 k take
of 300 frames (10 s), one export at a time:

| codec | 1080p | | 4k | |
| --- | --- | --- | --- | --- |
| | frames a second | file | frames a second | file |
| h264 | 202 | 31.9 MB | 77 | 127.6 MB |
| hevc | 205 | 15.9 MB | 77 | 63.9 MB |
| prores | 201 | 282 MB | 78 | 1126 MB |

#### Previews

```bash
./scripts/dev.sh export library/2026-10-23/scene-0001 --format webp                  # exports/preview.webp
./scripts/dev.sh export library/2026-10-23/scene-0001 --format gif --max-size 5MB
./scripts/dev.sh export library/2026-10-23/scene-0001 --format webp --preset square --width 480 --start 3
```

`--format webp` or `gif` writes a looping animation instead of a video, from the same take, look
and camera, each frame drawn by the same renderer and read back rather than decoded from a video:
960 wide at 16 fps for 8 seconds by default, the size of the README's own animation, with
`--width`, `--height`, `--fps`, `--start` and `--duration` as for a video and `--preset` giving
only the proportions. `--max-size` (`5MB`, `800KB`, megabytes without a unit) draws it again
narrower until it fits, down to 320 wide, then at a lower frame rate, down to 10 fps.

ImageIO reads WebP but does not write it, so WebP goes through `img2webp` from libwebp
(`brew install webp`), lossy at `--quality` 0.8. GIF needs nothing: ImageIO spends its palette
on the bright cores and leaves the faint tails in a few flat steps, and given one palette for
every frame it merges them into one of its own, sixteen colours deep. Here the palette is cut
from the whole animation by median cut at full precision, weighted by how many pixels a colour
covers so the dark levels a galaxy is mostly made of keep a colour each, every frame is mapped
onto it with Floyd Steinberg dithering, and the file is written by hand, one global table and
LZW, so nothing quantises it again.

Measured on the M4 Max with a 150 k take and the standard look, 8 seconds at 16 fps, 128 frames
drawn in 0.5 s; the error is the mean gap, in levels out of 255, between 4 x 4 blocks of the
source frame and of the file read back, over the faint blocks (brightest pixel under 40) and the
others:

| file | size | written in | faint error | bright error |
| --- | --- | --- | --- | --- |
| WebP, quality 0.8 | 11.4 MB | 5.9 s | 1.06 | 1.55 |
| WebP, quality 0.6 | 5.8 MB | 5.3 s | 1.40 | 2.17 |
| WebP, `--max-size 5MB` | 4.6 MB, 604 wide | 8.7 s | | |
| WebP without grain | 0.9 MB | 2.1 s | | |
| GIF | 62.7 MB | 1.6 s | 0.14 | 0.57 |
| GIF through ImageIO's own palette | 40.0 MB | 1.3 s | 0.47 | 0.75 |
| GIF, `--max-size 5MB` | 4.1 MB, 320 wide at 10 fps | 3.1 s | | |
| GIF without grain | 26.6 MB | 1.6 s | | |

The grain is most of every file: noise compresses badly in both, and in a GIF not at all. WebP
halves the chroma, which blurs the grain and tints the faint halo, where the dithered GIF keeps
both; but the GIF weighs five times as much, so WebP stays the default and a GIF wants a narrow
`--max-size`. img2webp's slowest method saves 8 % for fifteen times the time and is not used.

### Fidelity

Whether a scene picked at the exploration size is the same scene at millions, measured on ten
scenes of batch 2110 (two to five galaxies, the Antennae, a polar ring and a compact group among
them), each replayed at 50 000, 200 000 and 500 000 particles a galaxy and two at a million:

```bash
scripts/fidelity.py run    library/2026-10-24-fidelity/scene-0007 --per-galaxy 50000,200000,500000
scripts/fidelity.py report library/2026-10-24-fidelity
```

`run` replays the scene through `hires` into `<scene>/.fidelity/<size>/`, and keeps only the
curves and the density maps: `--density` counts the stars on a fixed grid around the centre of
mass at eight instants, the same grid at every size. `report` compares every replay with the
largest, into `.fidelity/fidelity.json`: the centres' tracks, which `curves.csv` now carries,
the closest passage, the tidal fraction, and the share of stars that two maps put in the same
cells. Against the largest replay:

| per galaxy | centres apart | pericentre | tidal fraction, end | stars in the same place, end |
| --- | --- | --- | --- | --- |
| 50 000 | 0.5 to 3.6 kpc | within 1 Myr on 8 of 10, 11 Myr at worst | within 0.03 | 0.24 to 0.88 |
| 200 000 | 0.6 to 2.9 kpc | within 1 Myr on 7 of 10, 5 Myr at worst | within 0.04 | 0.54 to 0.94 |
| 500 000, against 1 M | 0.4 and 0.6 kpc | the same frame | within 0.01 | 0.77 and 0.81 |

The large scale holds at 200 000: the same passages at the same time and distance, the same
amount in the tails. The detail of the tails does not hold at any size, since even 500 000 and a
million part ways on a fifth of the stars by the end of the clip, and 200 000 comes within a
tenth of that floor on eight scenes of ten. At 50 000 the centres still go the same way, but the tails of one scene
of ten come out unrecognisable (a quarter of the stars in the same place), so a quick batch finds
encounters and a night batch judges them. Run again at its own size, a scene comes back within
0.15 kpc, so the differences are the particle count and not the run.

`--dt-scale 3.5` holds at high resolution: halving the step at 500 000 a galaxy moves the centres
by less than 0.01 kpc and leaves 98 % of the stars in the same place, for twice the time.

### Exploration batches

```bash
scripts/explore-batch.sh --scenes 50 --hours 8          # a night: the particle count is worked out
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000  # quick: about twenty seconds a scene
scripts/explore-batch.sh --out library/2026-10-24        # picks a stopped batch up where it was
```

`explore` over the free scenes of one batch, several at once, raw look, self-gravitating,
30 s at 960x540. Each scene is explored in a hidden folder, `.scene-0001`, and renamed into
place once its clip, thumbnail and curves are written, so the library shows it the moment it
is done and never halfway; a folder that exists is a scene that is finished. A rejected draw
leaves no folder, a row in `index.csv` and its reason in `batch.log`; the batch moves on to the
next index. The scene log is in `.logs/`.

**Reproducible and resumable.** Scene `n` is `--seed S --index n` of the free generator, and
nothing else goes into it: the order scenes finish in does not matter. The batch's settings go
to `batch.conf` on its first run and are read back on the next, so `--out` alone resumes it;
a different seed or size given to a batch already started is refused. Scenes in flight when it
stops are started again.

**The clip shows the encounter.** A step three and a half times the recommended one
(`--dt-scale 3.5`, measured in #13), 400 steps to settle, which is the first 80 Myr, and then
as many steps as cover `--span`, 700 Myr by default: a step is shorter the more particles a disk
holds, so the step count is worked out per scene. The generator puts the first pericentre at
least 150 Myr into the clip, and `explore` runs on past the span while the story goes on, so the
budget plans for spans longer by the share measured in #123 and `index.csv` keeps the frames and
steps that actually ran. The clip of #41, 900 steps at the generator's
own scale, covers 40 Myr, which is one passage and no tails.

**The particle count.** `--per-galaxy`, 50 000 by default, times the scene's galaxy count. With
`--scenes` and `--hours` together and no `--per-galaxy`, the batch picks the largest count for
which its first sixteen scenes, costed at the measured rate, fill 85% of the hours; the rest is
for rejected draws and the scenes in flight at the deadline. `--hours` stops it either way.

**Several at once.** A scene is mostly waiting on the GPU, and another one fills the gaps.
`--benchmark` runs the same scenes one to four at a time and prints the wall clock per scene
finished. On the M4 Max, twelve scenes at 50 000 a galaxy over 175 Myr:

| at once | s per scene | each scene | ns per particle step |
| --- | --- | --- | --- |
| 1 | 29.7 | 27.8 | 143.6 |
| 2 | 25.2 | 42.6 | 118.4 |
| 3 | 23.8 | 59.1 | 111.0 |
| 4 | 22.1 | 78.3 | 101.2 |

At 400 000 a galaxy, eight scenes over 50 Myr, the GPU is already full with one scene and a
second only fills the pauses between steps: 186.5 s per scene alone, 176.5 with two, 176.6 with
three, and four took the same 1 413 s of wall clock as three. Four costs nothing there and wins
a quarter at the small sizes, so four is the default. The budget costs a scene at the night's
rate, 126 ns per particle step, which overestimates the small sizes a little. For 50 scenes in 8
hours it comes out at 200 000 a galaxy, about 390 s a scene, which is 550 000 visible particles
for the average scene of 2.8 galaxies.

On another Mac, run `--benchmark` and set `DEFAULT_JOBS` and
`NS_PER_PARTICLE_STEP` at the top of the script, or `SILLAGE_JOBS` in the environment. The
batch ends by printing the mean wall clock per scene finished and per scene run.

`scripts/library.sh` is the older batch, flat and with the full look; it stays for now.

### Interest score

Where to start looking in a batch, from the curves alone: no extra simulation, no image
analysis, and never a filter. Each frame of `curves.csv` adds the closest pair of centres, the
tidal fraction (the share of every 64th drawn star farther than 1.5 disk radii from every
centre: tails and bridges) and each disk's disruption from the solver's `DiskState`.
`scripts/interest.py` turns them into the scene's features, the closest approach and when it
happens, the peak tidal fraction, the burst ratio (peak over median star formation, smoothed
over 15 frames), the final disruption and whether the passage falls inside the clip, and into a
score from 0 to 1, a hand weighted sum with the weights in `WEIGHTS` at the top of the script.

The batch scores each scene as it lands, into `interest.json` and the `score` column of
`index.csv`, and ranks the batch once it is done (`rank`, 1 first). The library sorts by it.
`scripts/interest.py library/2026-10-24` scores and ranks a batch again, after the weights
change for instance.

Once enough scenes carry a rating, `scripts/interest.py --fit library` fits the weights to the
ratings by least squares and compares how well each set ranks the scenes (Spearman, each scene
predicted by weights fitted without it). It prints the fitted weights, and they replace the
hand ones only if they rank better.

### The library

The application opens on its library (⌘L from anywhere; the sidebar also holds Nuits and the
Atelier, where scenes are set up by hand) and shows every
scene under `library/`, both scene folders and the older flat batches, and picks up new
scenes as they are written. The grid shows stills; only the scene under the pointer, the
selected one or the enlarged one plays its clip. Under each scene, yes, no and a rating from
0 to 10, each saved in one click to the batch's `ratings.json`; clicking a lit button takes it
back. Keys: arrows to move, `Y` and `N`, digits for the rating (`1` then `0` for ten), delete
to clear, space to enlarge, escape to close. Sort by batch, rating, score or date, filter by choice,
rating, batch and archetype.

```json
{ "version": 1, "scenes": { "scene-0001": { "choice": "yes", "rating": 8, "updated": "2026-10-24T06:00:00Z" } } }
```

The scenes kept for the next stage are
`jq -r '.scenes | to_entries[] | select(.value.choice == "yes") | .key' ratings.json`.
`Sillage.app --librarycheck` drives the whole window model through a library it builds on disk.

## The physics

Two solvers share one scene description, one particle buffer and one renderer. **Restricted**
moves massless test particles through rigid analytic potentials, following Toomre and Toomre
(1972), at O(N); it raises the bridges and tails cheaply, which is useful while framing a shot.
**Barnes-Hut** gives the particles mass and a tree built in Morton order and traversed on the
GPU, at O(N log N). Dark halos become particles too, so an infalling companion
raises a wake that drags on it, and the disks grow their own bars and arms. The images above
use Barnes-Hut.

**Integrator.** Kick drift kick leapfrog in both solvers, at a fixed step. The step and the
force softening are derived from the scene rather than exposed: softening is 1.5 times the mean
interparticle spacing of the densest disk, capped at 1 kpc, and the step is short enough that a
particle crosses well under one softening length per step.

**Units.** Lengths in kpc, masses in 10^10 solar masses, G = 1. The derived velocity unit is
207.4 km/s and the time unit is 4.71 Myr.

**Parameters.** Per scene: particle count, opening angle, halo particle ratio. Per galaxy:
mass, scale radius, truncation, thickness, Toomre Q, inclination, position angle and spin.

### Known limits

- Single precision throughout: positions, velocities and forces are all 32 bit floats.
- No hydrodynamics. No gas, no pressure, no shocks. The dissipation time is a relaxation term
  standing in for the gas that keeps a real disk cool, not a fluid solver.
- Star formation decides how a region is drawn and nothing else. It never feeds back into the
  forces.
- The step is fixed for the whole run rather than adaptive, so a deep pericentre is integrated
  no more finely than the approach.
- In restricted mode the halos are rigid and follow their galaxy, which does work on the
  system, so the pair never actually merges. The suite checks that live halos conserve momentum
  considerably better.
- None of this has been compared against a published simulation. The tests check internal
  consistency, equilibrium and conservation, not agreement with anyone else's results.

## Layout

```
Sources/SillageCore/     physics, no rendering dependency
Sources/SillageRender/   Metal solver, splat renderer, camera
Sources/SillageApp/      SwiftUI setup screen and live view
Sources/sillage-render/  headless PNG renderer
```

## Small print

AI did a good share of the typing here. Seemed worth saying out loud.

## License

Code: MIT. Renders and videos: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/),
so reuse them freely as long as the credit comes along.
