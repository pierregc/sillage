# Driving Sillage as an agent

How to use Sillage from the command line: what to run for each common request and which file
decides what. It is not about changing Sillage's code. The person asking decides what is rendered,
at what size and in what order; this file only says how.

Everything is a command that reads and writes files, and every file is strict: a field or an
option that is not known is refused with a message, so read the message before trying again.
`docs/reference.md` is the complete reference and `docs/notes/README.md` indexes the design
notes; open them only for what is not here.

## Two engines, one set of files

| | Mac (Metal) | Linux with an NVIDIA GPU (CUDA) |
| --- | --- | --- |
| Command | `./scripts/dev.sh render <args>`, which builds `sillage-render` if needed and runs it | `scripts/linux.sh tool` builds `.build/linux/sillage-cuda`; run it with `LD_LIBRARY_PATH=.build/linux` |
| Help | `sillage-render --help`, `sillage-render <command> --help` | `sillage-cuda help`, `sillage-cuda <command> --help` |
| Has | every command below | `explore`, `hires`, `still`, `export`, `match`, `take extract`, `flight`, `look --palette\|--promote`, `pace --speed story`, `black-hole still` |
| Lacks | | `look --style auto\|--grid`, `palettes`, the visual pace, text overlays, `--format webp\|gif`, `export --palette`, `dustGlow` and `galaxyCount` of a look, a flight's `inside.dustScreen` (refused by name, #513) |

`./scripts/dev.sh explore|hires|look|export|palettes <folder>` are shortcuts for
`./scripts/dev.sh render <command> <folder>`. A scene folder goes from one engine to the other as
it is. `<command> --help` gives each option's meaning, unit and default. Both commands refuse an
option they do not read, a value that does not parse or a stray word, with exit status 2,
before anything runs.

A rented GPU is driven from the Mac with `scripts/gpu-box.sh` (`offers`, `up`, `setup`, `ship`,
`run <command>`, `wait`, `tail`, `fetch <paths>`, `down "<what ran>"`); `docs/notes/cloud-runs.md`
has a session from start to end. Renting costs money: never without the person's go.

## A scene folder

```
library/<batch>/<scene>/
    scene.json         the physics: seed, galaxies, encounters. No colour, no particle count
    look.json          the image: rendering, palette, camera plan
    clip.json          how long the clip runs and where its story starts and ends
    preview.mov, thumbnail.png, curves.csv, interest.json     written by explore
    take.sillage, hires.mov, curves-hires.csv, hires.json     written by hires
    looks/             looks the scene has been through
    flights/<name>.flight.json    camera paths
    match/             matches against real pictures
    exports/           finished videos, each with the .time.json it was drawn along
```

Four stages, each one command on the folder: `explore` (a preview at a small particle
count), `hires` (the same scene at millions of particles, which writes the take), `look` (the
style), `export` (videos and stills drawn from the take, with no solver). Colours, cameras,
speeds and formats are all export time choices: none of them needs the simulation run again.
Only the physics (`scene.json`) and the particle count do.

Moments are in megayears of the take (the `time_myr` column of the curves), distances in
kiloparsecs, angles of a look's camera in radians, a video's time in seconds.

## Recipes

Paths below stand for a scene folder `S` and use `sillage-render`; put `./scripts/dev.sh render`
in its place on the Mac.

### Many previews, to find scenes worth keeping

```bash
scripts/explore-batch.sh --scenes 50 --hours 8            # a night; the particle count is worked out
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000   # quick, about twenty seconds a scene
scripts/explore-batch.sh --out library/2026-10-24         # resumes a stopped batch
sillage-render explore S --preset antennae --seed 7 --index 3   # one scene; an archetype by name
```

A batch writes `index.csv` with a `score` and a `rank` per scene (`scripts/interest.py <batch>`
ranks it again): start from the rank, then look at `thumbnail.png` (480 px) and `preview.mov`.
Archetypes: `antennae`, `mice`, `ring`, `tadpole`, `polar-ring`, `minor-merger`, `compact-group`,
`black-hole-pass`. `explore` exits with status 3 on a scene that would show nothing. A scene is
found again from `--seed` and `--index` alone. On CUDA: `sillage-cuda explore S [options]`.

### The take at high resolution

```bash
sillage-render hires S                                   # 8 M drawn, 2 M carrying the mass
sillage-render hires S --particles 8000000               # every particle carries mass
sillage-render hires S --particles 8000000 --massive 2000000
sillage-render hires S --frames 60 --no-video            # a quick look at the first frames
sillage-render hires S --resume                          # after a stop; it checkpoints about hourly
```

It prints how long it should take before it starts, and `hires.json` keeps what ran. On CUDA:
`sillage-cuda hires S` with the same options. This is the long, costly step: hours on the Mac at
8 M.

### A look, a colour, a rendering

```bash
sillage-render look S --promote webb                # a look of looks/ becomes the scene's look.json
sillage-render look S --style auto --world telescope   # rendering and palette chosen on the picture
sillage-render look S --palette auto                # the palette alone; or a family, or a .palette.json
sillage-render palettes S --best 3                  # three palettes drawn on a frame, scores under each
sillage-render look S --grid --stills out/grid --base webb --frames shots   # looks against key frames
sillage-render export S --look dream                # one export with another look, look.json untouched
```

On CUDA, `sillage-cuda look S --palette ...` and `--promote` work the same; `--style auto`, `--grid`
and `palettes` draw the take with Metal and stay on the Mac.

`--look` takes a file, a name in the scene's `looks/`, or a name in the repository's `looks/`
(over forty, `hubble`, `webb`, `photograph`, `observatory`, `raw`...). For a change no look has,
copy a look file and edit it: `look` holds the rendering (`brightness`, `stretch`, `whitePoint`,
`saturation`, `dustStrength`, `bloomIntensity`, `starSize`, `spikeIntensity`, `noiseLevel`,
`skyLevel`...), `palette` each galaxy's colours in linear sRGB, `camera` the camera plan. A field
left out takes its default, so a file names only what it changes. `sillage-render fields` prints
every field with what it does, its default and the range the repository's looks use.

### A video or stills in a given format

```bash
sillage-render export S                                    # exports/1080p.mp4, HEVC
sillage-render export S --preset 4k --fps 60
sillage-render export S --preset vertical --start 4 --duration 15
sillage-render export S --width 2560 --height 1080 --codec prores
sillage-render export S --stills out/stills --still-frames 0,120,300   # PNGs, no video
sillage-render export S --format webp --max-size 5MB       # a looping preview (Mac only)
sillage-render export S --overlay clock,scale              # words over the picture (Mac only)
```

Presets: `1080p`, `4k`, `vertical` (1080 x 1920), `square`, `whatsapp`. Codecs: `hevc`, `h264`,
`prores`. `--start` and `--duration` are seconds of the video; `--out` names the file. The last
lines printed give the frames, the time taken, the size and the path. On CUDA: `sillage-cuda
export S` with the same presets and sizes, drawn in segments (`--resume` carries on a stopped
one), and `sillage-cuda still <take> --look <look> --frames 0,120 --out <dir>` for stills.

### Time faster or slower

```bash
sillage-render export S --speed 2                  # constant, 0.25 to 16
sillage-render export S --speed auto               # the collision at 1x, the settling faster
sillage-render export S --speed story:4:8 --slow 300:420:0.5   # a stretch held to half speed
sillage-render pace S --speed story --out S/exports/my.time.json   # the track alone, no video
sillage-render export S --speed S/exports/my.time.json
```

On CUDA, `sillage-cuda pace S --speed story` writes the same track; the visual pace draws with
Metal, so its `.time.json` comes from the Mac.

A track file is one of: `{"version": 1, "speed": 2}`; speeds from moments of the take,
`{"version": 1, "ramp": 1.5, "keys": [{"myr": 300, "speed": 1}, {"myr": 420, "speed": 0.5}]}`;
or the take's moment at seconds of the video, `{"version": 1, "times": [{"at": 0, "myr": 300},
{"at": 4, "myr": 400}, {"at": 6, "myr": 400}]}` (two keys at one moment freeze time). `--speed`
does not go with `--flight`: a flight carries its own time. Details in
`docs/notes/variable-time.md`, "The track file".

### The camera

Without a flight the camera is the look's plan, `camera` in the look file: `mode` (`fixed`,
`auto` which keeps every galaxy in frame, `director` which plans shots and cuts, `immersed`),
`elevation` and `azimuth` with optional `elevationEnd` and `azimuthEnd` (radians), `zoom`,
`zoomKeys` (pairs of progress through the take and a factor), `center` (kiloparsecs).
`look S --style auto --camera <mode>` names the mode as it promotes; otherwise edit the look file.

A flight moves the camera freely, round or inside the scene, and sets the time as well:

```bash
sillage-render flight S --at 400,452,520 --look photograph --arms 6,9
sillage-render export S --look photograph --flight dive --flight-keys out/dive   # one PNG a key
sillage-render export S --look photograph --flight dive --flight-at 3,7.5 --flight-keys out/dive
sillage-render export S --look photograph --flight dive --preset 4k   # exports/dive-4k.mp4
```

`flight` draws nothing: it prints each galaxy's centre and disk axes at those moments, the look's
camera there as a key ready to paste, and with `--arms` the densest place of each disk at those
radii, a point to fly into. The first passage is where `separation_kpc` of `curves-hires.csv` is
least. A flight file, `S/flights/dive.flight.json`:

```json
{
  "version": 1,
  "keys": [
    {"at": 0, "myr": 300, "look": true},
    {"at": 10, "myr": 430, "eye": [-10, -50, 110], "aim": [-0.5, -1, 0.3]},
    {"at": 26, "eye": {"galaxy": 0, "offset": [0, -14, 9], "disk": true}, "aim": {"galaxy": 0}, "exposure": -1.5},
    {"at": 33, "myr": 452, "eye": {"galaxy": 0, "offset": [6, 2, 4], "disk": true}, "pace": "nearness"},
    {"at": 46, "myr": 620, "eye": [0, -110, 120], "aim": [2, -1, 0], "exposure": 0}
  ]
}
```

- `at`: seconds of the video; the first key is at 0 and the video ends at the last.
- `myr`: the take's moment, required on the first and last key. Two keys with the same `myr`
  freeze time while the camera moves.
- `eye`, `aim`: a world point in kiloparsecs, or a point carried by a galaxy, the offset in the
  world's axes or, with `"disk": true`, in its disk's (x and y in the plane, z along the spin). A
  key that gives one keeps the other from the key before.
- `"look": true`: the look's own camera at that moment, so a flight can open on the plain export's
  framing.
- `fov` and `roll` (radians), `exposure` (stops) hold until changed. `"pace": "nearness"` slows the
  eye as it nears matter.

Near matter the frames are drawn from inside by themselves (point stars, automatic exposure).
The rest, the `inside` block and a worked example on the Mice are in `docs/notes/flights.md`. On
CUDA: `sillage-cuda flight S --at ...` and `sillage-cuda export S --flight dive [--flight-keys <dir>]`.

### A real picture beside the simulation

```bash
scripts/photo-match.py picture picture.jpg --preview check.png   # writes picture.map.json
sillage-render match S picture.map.json --kpc-across 60          # writes S/match/picture.json
scripts/photo-match.py sheet S/match/picture.sheet.json          # the picture against the best frame
```

`match` finds the moment and the view where the take overlaps the picture best and writes them
with a score (`megayears`, `elevation`, `azimuth`, `roll`, `kpcPerWidth`); `--at`, `--within`,
`--view` and `--span` narrow the search. On CUDA: `sillage-cuda match`. Reference pictures and
their credits are in `references/` (`references/catalogue` has twenty interacting galaxies).

`scripts/picture-film.py` makes the pictures and the film that show the two together (Pillow and
ffmpeg, on the Mac or Linux; each command prints one JSON line naming what it wrote):

```bash
scripts/picture-film.py flight S/match/picture.json --picture picture.jpg --out S/flights/photo.flight.json
sillage-render export S --flight photo --flight-keys out/photo         # the take as the picture frames it
scripts/picture-film.py still out/photo/<key>.png out/beside.jpg --picture picture.jpg --left Simulation --right Webb
scripts/picture-film.py key S/match/picture.json --picture picture.jpg --at 30   # one key, to paste in a flight
scripts/picture-film.py film master.mov out/film.mp4 --picture picture.jpg --hold 30:9 \
    --title "NGC 2207  &  IC 2163" --subtitle "115 million light-years away" \
    --left "Simulation  ·  Sillage" --right "James Webb Space Telescope" --credit "Image: NASA, ESA, CSA, STScI"
scripts/picture-film.py sheet out/sheet.jpg a.png b.png --picture picture.jpg --labels "first,second"
scripts/picture-film.py sheet out/sheet.jpg out/film.mp4 --at 5,31,34,60   # frames of a video
```

`film` takes one continuous video (a flight's export, ProRes for a master) whose camera holds the
picture's view over `--hold <start s>:<length s>`: the frame gives up half the screen, the picture
comes in beside it, the title fades in and out, and the rest of the video is untouched. Put the
`key` in the flight at the hold's start and again at its end, with the same `myr`, so the view and
the time hold. A picture wider than tall: key with `--fit width` (the default), layout `shrink`. A
taller one: `--fit height`, layout `slide`. `references/cartwheel` and `references/ngc2207` hold
two finished examples, with their scenes, looks and flights; `docs/notes/cartwheel.md` and
`ngc2207.md` tell how each was made.

### A black hole close up

`sillage-render black-hole new|run|still` and `sillage-cuda black-hole still`; its flights give
`time` in place of `myr`. See `docs/notes/black-hole-close-up.md`.

## Following long work

- `sillage-render status [--json]` says what the queue and the nights are doing;
  `sillage-cuda status S` reads a scene's run on a box. `docs/night-status.md` describes the files
  behind them (`activity.json`, `events.jsonl`).
- `sillage-render queue add|list|run|pause` lines heavy jobs up one after another on the Mac.
- `explore`, `hires` and `export`, on both engines, take `--summary <file>`, or `--summary -` for
  the last line of the output: one JSON object written as the command exits, however it exits,
  with the command, the exit status, the error, the seconds and every file it wrote.
- One heavy job at a time on a GPU: two share it badly and time nothing reliably. Sessions on
  the same machine take turns through `scripts/gpu-lock.sh run <label> <command...>`, which waits
  for the lock, runs the command and releases it; `scripts/gpu-lock.sh status` says who holds it.
  Use it for `explore`, `hires`, `export`, `look --style auto|--grid` and timings.
- Exit status: 0 done, 2 refused arguments, 3 a scene rejected by its check, 1 anything else.

## Where the rest is

- `docs/reference.md`: every command, file and format.
- `docs/night-manager.md`: a whole night, from a batch to exports, from one recipe file.
- `docs/notes/flights.md`, `variable-time.md`, `photo-match.md`, `director-shots.md`,
  `inside-a-galaxy.md`: the features above in depth.
- `docs/notes/cuda-engine.md`, `cloud-runs.md`, `cuda-platform.md`: the CUDA engine and rented
  boxes.
- `docs/notes/reproducing-a-galaxy.md`: making Sillage draw a galaxy someone has photographed, the
  order that worked and the traps; `cartwheel.md`, `ngc2207.md` and `sombrero.md` are the three
  done.
