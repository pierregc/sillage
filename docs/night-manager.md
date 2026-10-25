# Night Manager: a user guide

The Night Manager is the pipeline that turns a night of compute into a handful of finished
videos. You start a batch before bed, rate the results over coffee, and push only the best
scenes through the heavier stages.

```
explore-batch  →  rate in the library  →  hires  →  look  →  export
 (night)           (morning)              (the keepers, high resolution)
```

Every stage reads and writes the scene's own folder under `library/`, so you can stop after
any of them and come back later. Everything runs through `./scripts/dev.sh` (or
`scripts/explore-batch.sh`); do not call SwiftPM directly. Reference details live in the
[README](../README.md); this page is the short path.

Requirements: macOS 14+, Apple Silicon. Run `./scripts/dev.sh build` once, or let the batch do
it. Open the app with `./scripts/dev.sh app && open .build/dev/Sillage.app`.

## 1. The night batch

```bash
scripts/explore-batch.sh --scenes 50 --hours 8     # a night
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000   # quick test, about 20 s a scene
scripts/explore-batch.sh --out library/2026-10-24  # resume a stopped batch
```

- With `--scenes` and `--hours` together, the script picks the largest particle count that fits
  the time. `--per-galaxy N` sets it by hand (default 50 000).
- Four scenes run at once (`--jobs N` or `SILLAGE_JOBS` to change).
- Output goes to `library/<today>/` unless `--out DIR`. Each scene appears as `scene-0001/`
  only once it is finished.
- `--seed S` picks the batch (default: today's date). Same seed and index always give the same
  scene.
- Resumable: run it again with the same `--out` and it carries on. A started batch refuses
  changed settings.
- `--plan` prints what it would use and exits; `--help` lists the rest.
- Progress is in `<batch>/batch.log`; per-scene logs are in `<batch>/.logs/`.

Each finished scene holds a 30 s preview (`preview.mov`), a thumbnail, curves and an interest
score. Rejected draws leave no folder, only a row in `index.csv` and the reason in `batch.log`.

## 2. Library, ratings and score

Open the app and press **⌘L** (or **Bibliothèque** on the setup screen).

- The grid shows every scene under `library/` and picks up new ones as they land. Only the
  scene under the pointer plays.
- Under each scene: **yes**, **no** and a rating **0 to 10**. Keys: arrows to move, `Y` / `N`,
  digits for the rating (`1` then `0` for ten), delete to clear, space to enlarge, escape to
  close.
- Sort by batch, rating, score or date; filter by choice, rating, batch and archetype.
- Choices are saved in `<batch>/ratings.json`.

The **score** (0 to 1) says where to start looking, nothing more: it is computed from the
curves (closest approach, tidal tails, disruption) and never filters anything. The batch
ranks itself at the end; to recompute after changing the weights:

```bash
scripts/interest.py library/2026-10-24
scripts/interest.py --fit library     # fit the weights to your ratings
```

Mark the scenes you want to keep as **yes**. The next stage picks those up.

## 3. High resolution (`hires`)

```bash
./scripts/dev.sh hires library/2026-10-24                          # every "yes" scene in the batch
./scripts/dev.sh hires library/2026-10-24/scene-0001 --particles 2000000   # one scene
./scripts/dev.sh hires library/2026-10-24/scene-0001 --frames 60   # first 60 frames, a quick look
```

- Given a batch folder, it processes every scene rated yes and skips those already done at
  that size. Given a scene folder, it runs that scene.
- Default size is the machine's maximum, `SILLAGE_MAX_PARTICLES` (10 million on an M4 Max with
  36 GB). Asking for more is refused. It prints the expected duration first.
- Cost: about 30 min at 1 M, 85 min at 2 M, 4 h at 5 M, 8 h at 10 M (measured, M4 Max). Start
  with 1-2 M; the large-scale story holds from about 200 000 a galaxy.
- It writes `take.sillage` (the run, needed by `look` and `export`), `hires.mov` and curves
  beside the preview, which is left untouched.

## 4. Choosing the look

### The grid

```bash
./scripts/dev.sh look library/2026-10-24/scene-0001
./scripts/dev.sh look library/2026-10-24/scene-0001 --base dream
./scripts/dev.sh look library/2026-10-24/scene-0001 --promote standard-vivid
```

`look` draws a few key frames of the take under many looks and writes `looks/grid.png`: one row
per look (a base, small variations of it, then the catalogue: observatory, dream, gloss, ink,
ember), one column per key frame (start, approach, pericentre, tails, end). No simulation runs,
so it is quick. Open `grid.png`, pick the row you like, then **promote** it by its row name
with `--promote <name>`. That row becomes the scene's `look.json`, used by the export.

Handy options: `--no-variants`, `--no-catalogue`, `--width N` (cell width), `--frames 0,150,299`
or `--times 120,300` for specific key frames.

### Live tuning in the app

In the library, select a scene with a take and click **Régler le look**. The panel edits every
field of the look with the picture updating live (sliders, galaxy colours, starfield, bloom,
camera plan). Scrub the timeline to check different moments.

- **⌘S** saves the look file back where it came from; **⇧⌘S** saves under a new name (the
  scene's `looks/` by default).
- **En faire le look de la scène** promotes the current look, like `--promote`.
- **⌘O** opens any take, **⇧⌘O** any look file.

Use the grid to compare, the app to fine-tune.

## 5. Export

```bash
./scripts/dev.sh export library/2026-10-24/scene-0001                    # exports/1080p.mp4
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset 4k --fps 60
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset vertical --look dream --start 4 --duration 15
```

The export draws `take.sillage` with the scene's `look.json` into `exports/`, frame by frame.

**Presets** (`--preset`): `1080p` (default), `4k`, `vertical` (1080 x 1920), `square`
(1080 x 1080) and `whatsapp` (below). Override with `--width`, `--height`, `--bitrate` (Mbit/s)
or `--quality` (0 to 1). Cut the clip with `--start` and `--duration` (seconds); `--fps`
defaults to the take's rate. `--look` takes a look file, a grid row name or a catalogue look;
`--take` and `--out` change the input and output path.

**Codecs** (`--codec`):

| codec | file | use |
| --- | --- | --- |
| `hevc` (default) | `<preset>.mp4` | about half the size of H.264; plays in QuickTime and iOS |
| `h264` | `<preset>-h264.mp4` | plays everywhere, older devices included |
| `prores` | `<preset>-prores.mov` | editing (ProRes 422 HQ), very large files |

ProRes has a fixed rate: `--bitrate` and `--quality` do not apply to it. Every video carries
the licence (CC BY 4.0) and the scene id in its metadata.

**WebP and GIF previews** (`--format webp|gif`) write a looping animation instead of a video:
960 wide, 16 fps, 8 s by default, into `exports/preview.webp` or `exports/preview.gif`.

```bash
./scripts/dev.sh export library/2026-10-24/scene-0001 --format webp
./scripts/dev.sh export library/2026-10-24/scene-0001 --format gif --max-size 5MB
```

`--max-size` (`5MB`, `800KB`) redraws narrower, then at a lower frame rate, until the file
fits. WebP needs `brew install webp`; GIF needs nothing but gets big, so give it `--max-size`.

**WhatsApp** (`--preset whatsapp`): 1280 x 720, H.264 in an MP4 (it plays in every browser;
the codec cannot be changed), aimed under 15 MB so WhatsApp Web and Desktop keep it whole.
The bit rate drops by itself for longer clips; if the clip is too long to fit at all, the
export stops and asks you to cut it with `--duration`. It also writes a caption file next to
the video, `exports/whatsapp.txt`, with the title and licence to paste with the video.

```bash
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset whatsapp
```

## A typical week

1. Evening: `scripts/explore-batch.sh --scenes 50 --hours 8`.
2. Morning: open the library (⌘L), sort by score, rate, mark the keepers **yes**.
3. `./scripts/dev.sh hires library/<batch> --particles 2000000` (overnight again).
4. `./scripts/dev.sh look <scene>`, pick a row, promote it; fine-tune in **Régler le look**
   if needed.
5. `./scripts/dev.sh export <scene>`, plus `--format webp` or `--preset whatsapp` to share.

## If something goes wrong

- A batch stops after five failed scenes: check `<batch>/.logs/`.
- "not enough disk": about 30 MB a scene, so free space or lower `--scenes`.
- To start a scene over, empty its folder. Seed and index reproduce it exactly.
