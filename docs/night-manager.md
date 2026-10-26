# Night Manager

Generates many random galaxy-collision scenes, lets you pick the best, and renders those at
high resolution into finished videos. Each stage reads and writes the scene's own folder in
`library/<batch>/<scene>/`.

```
explore-batch → library (rate) → hires → look → export
```

Run everything through `./scripts/dev.sh` (not SwiftPM). macOS 14+, Apple Silicon.

## Run it

**1. Explore** – generate scenes (30 s previews):

```bash
scripts/explore-batch.sh --scenes 50 --hours 8        # particle count chosen to fit the time
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000   # quick
scripts/explore-batch.sh --out library/2026-10-24     # resume a stopped batch
```

**2. Rate** – open the app (`./scripts/dev.sh app && open .build/dev/Sillage.app`), press
**⌘L**. Each scene gets yes / no (`Y` / `N`) and a rating 0-10 (digits). Sort by score, rating
or date. Ratings go to `<batch>/ratings.json`.

**3. Hires** – re-run the scenes at high resolution:

```bash
./scripts/dev.sh hires library/2026-10-24                      # every "yes" scene
./scripts/dev.sh hires library/2026-10-24/scene-0001 --particles 2000000
```

**4. Look** – compare looks in a grid, then promote one:

```bash
./scripts/dev.sh look library/2026-10-24/scene-0001            # writes looks/grid.png
./scripts/dev.sh look library/2026-10-24/scene-0001 --promote <row-name>
```

To tune live, select the scene in the library and click **Régler le look** (⌘S saves,
**En faire le look de la scène** promotes).

**5. Export**:

```bash
./scripts/dev.sh export library/2026-10-24/scene-0001                    # exports/1080p.mp4 (HEVC)
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset 4k --fps 60
./scripts/dev.sh export library/2026-10-24/scene-0001 --format webp      # or gif, --max-size 5MB
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset whatsapp  # 720p H.264 under 15 MB + caption .txt
```

Presets: `1080p` (default), `4k`, `vertical`, `square`, `whatsapp`.
`--codec hevc|h264|prores` (default `hevc`). `--start` / `--duration` cut the clip,
`--look` picks a look. WebP needs `brew install webp`.

## How it works

- A scene is `--seed S --index N` of a generator: same two numbers, same scene.
- `explore-batch.sh` runs 4 scenes at once, each at a low particle count with a plain look.
  Batches are resumable; settings are kept in `batch.conf`.
- Each scene gets an interest **score** (0-1) from its curves (closest approach, tidal tails,
  disruption). It only sorts; it never filters.
- `hires` replays the same physics with more particles and saves the run as `take.sillage`.
  Its default is the machine's maximum (`SILLAGE_MAX_PARTICLES`); cost grows with the count
  (about 30 min at 1 M, 8 h at 10 M).
- `look` and `export` only draw the take; no simulation. The chosen look is `look.json`.
- Estimates come from `library/.sillage/costs.json`, fitted on past runs and refreshed after
  each one. `sillage-render costs` prints it; `--check <batch>` compares it with a batch.

Details and measurements: [README](../README.md).
