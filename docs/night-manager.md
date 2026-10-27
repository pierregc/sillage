# Night Manager

Generates many random galaxy-collision scenes, lets you pick the best, and renders those at
high resolution into finished videos. Each stage reads and writes the scene's own folder in
`library/<batch>/<scene>/`.

```
explore-batch → library (rate) → hires → look → export
```

Run everything through `./scripts/dev.sh` (not SwiftPM). macOS 14+, Apple Silicon. A
[night](#night) runs all of it from one recipe, unattended.

## Run it

**1. Explore** – generate scenes (30 s previews):

```bash
scripts/explore-batch.sh --scenes 50 --hours 8        # particle count chosen to fit the time
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000   # quick
scripts/explore-batch.sh --out library/2026-10-24     # resume a stopped batch
scripts/explore-batch.sh --scenes 20 --galaxies 2-3 --only-archetypes antennae,mice  # skip other draws
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

## Night

A whole night in one command: explore, pick the best scenes by score, run each at high
resolution, give it a style and export it, done by a delivery time.

```bash
R=".build/dev/sillage-render"   # with DYLD_LIBRARY_PATH=.build/dev, as dev.sh does
$R night tonight.night.json --plan          # what it would compute, how long, done when
$R night tonight.night.json                 # queued, into library/<today>
$R night tonight.night.json --out library/2026-10-28   # the same folder again resumes it
```

The recipe is JSON. Every setting is `"auto"` or a value, and one left out is Auto; a misspelt
name is an error.

```json
{
  "version": 1,
  "deliver": "07:00",
  "explore": { "scenes": "auto", "particlesPerGalaxy": "auto", "archetypeShare": "auto",
               "archetypes": "auto", "galaxies": "auto", "seed": "auto" },
  "pick": "auto",
  "hires": { "particles": "auto", "frames": "auto" },
  "style": { "world": "auto", "style": "auto", "palette": "auto" },
  "export": "auto"
}
```

| setting | value | Auto |
|---|---|---|
| `deliver` | `"HH:mm"` (its next occurrence) or an ISO 8601 date | `07:00` |
| `hours` | instead of `deliver`: hours from the start | |
| `explore.scenes` | scenes to explore | 50, fewer when even 50 000 a galaxy does not fit |
| `explore.particlesPerGalaxy` | particles a galaxy in the previews | largest of 50 000 to 200 000 that fits |
| `explore.archetypeShare` | share of archetype scenes, 0 to 1 | 0.25 |
| `explore.archetypes` | archetypes allowed, `["antennae", "mice"]`; a place drawn for another is skipped | all |
| `explore.galaxies` | `[least, most]` galaxies a scene has; others are skipped | any |
| `explore.seed` | the batch seed | the day, `20261028` |
| `pick` | `2` to `4`, or `"none"` to stop after exploring | 2 to 4 by score, as many as fit |
| `hires.particles` | particles in all | 2 000 000 (or the machine's maximum) |
| `hires.frames` | the first frames of the story only | the whole story |
| `style.style` | a look of the catalogue, such as `hubble` or `aurora` | the standard rendering |
| `style.world`, `style.palette` | `telescope` or `free`; a family or a `.palette.json` (`look --palette`) | the scene's own palette |
| `export` | presets (`1080p`, `4k`, `vertical`, `square`, `whatsapp`), `webp`, `gif` | `["4k", "vertical"]` |

How it plans. `NightPlanner` turns the recipe and the cost model into steps, each with its
duration, start and end, and the delivery of the whole night. Before exploring, it sizes the
first 16 draws of the batch from the generator alone (`ExploreProbe`, the same particles and
steps `explore-batch.sh` gives them, a quarter more for the story); after, it uses each scene's
own story. Auto keeps time for four picks, then three, then two, and explores fifty scenes at
the largest count a galaxy that fits in what is left, less a margin (5 %, 5 to 20 minutes).
The pick takes scenes marked yes by hand first, then the best scores, never one marked no;
score picks go to `ratings.json` as `picked`.

How it runs. Explore (through `explore-batch.sh`, stopped at its share of the night), pick, then
for each pick, best first: hires, style, exports. Before each step it plans again from the
files. A hires starts only if its scene, style and exports included, ends before the delivery
time; a style or an export may end up to 15 minutes past it; a step still running then is
stopped. A step that fails or is left out leaves the scene out for the night, and the night goes
on with the next one. The same command on the same folder resumes: explored scenes, done hires,
promoted looks and existing exports are skipped; what was left out is tried again.

Steering it, through the queue: `queue pause` and `resume` suspend the night and its step;
`queue stop` ends it after the current step; `queue stop --now` (or `cancel`) at once;
`queue skip` leaves out the scene it works on. Each takes the job's id, or acts on the night
running.

The night writes `recipe.json` (as given), `night.json`, `events.jsonl` and `report.md` in its
folder, and the logs of its steps in `.logs/` (`night-explore.log`, `<scene>.hires.log`, ...).
Exit status: 0 done, 3 stopped on request, 1 failed.

## Queue

Heavy work can go through one queue per library instead, one job at a time, in a runner of its
own that outlives the terminal or the app that started it and keeps the Mac awake:

```bash
R=".build/dev/sillage-render"   # with DYLD_LIBRARY_PATH=.build/dev, as dev.sh does
$R queue add hires library/2026-10-24/scene-0001 --particles 2000000
$R queue add hires library/2026-10-24                 # every chosen scene not done at that size
$R queue add export library/2026-10-24/scene-0001 --preset 4k
$R queue add explore --scenes 50 --hours 8            # explore-batch.sh options
$R queue add night tonight.night.json                 # as night <recipe>
$R queue list                                         # --json for the file itself
$R queue first 7 | cancel 7 | pause | resume
$R queue stop [7] [--now] | skip [7]                  # a night: after its step, or its scene
```

`add` starts a runner (`queue run`, log in `library/.queue/runner.log`) unless one is at work;
it exits once nothing is left, and waits before each job while a `sillage-render` started by
hand holds the GPU. `pause` suspends the running job where it is and starts nothing
new until `resume`; `cancel` stops a running job. An export can be queued behind the hires that
makes its take. Each job's output is in `library/.queue/logs/job-<id>.log`.

**`library/.queue/queue.json`**: `version`, `paused`, `nextID`, `jobs` in the order they run,
each with `id`, `kind` (explore, hires, export, night), `state` (waiting, running, done, failed,
cancelled), `by` (hand or night), `path` (the scene, or the batch of an exploration), `options`,
`added`, `started`, `ended`, `pid`, `status`, `message` and `log`. The last 50 finished jobs are
kept. Written under a lock by whoever changes it; read it freely.

`hires` and `export` write hidden (`.take.sillage`, `exports/.4k.mp4`) and rename once whole.
A runner that finds a job still marked running whose process is gone marks it failed and removes
what it left half written.

### Notifications

The runner posts a macOS notification at each `phase.done` and at `night.done` it finds in a
batch's `events.jsonl` while it works, when a job fails (stage and scene), and when the queue
empties after jobs asked for by hand. It runs without a bundle, which `UNUserNotificationCenter`
refuses, so it calls `osascript -e 'display notification …'` (0.14 s, exit 0 from a detached
process). The switch is `notifications` in `library/.queue/settings.json`, written by the app's
Réglages (⌘,) and read at every notice. While something runs, a menu bar ring shows the
progress and the status line. `SILLAGE_NOTICE_LOG=<file>` appends notices there instead of
showing them, for checks.

## How it works

- A scene is `--seed S --index N` of a generator: same two numbers, same scene.
- `explore-batch.sh` runs 4 scenes at once, each at a low particle count with a plain look.
  Batches are resumable; settings are kept in `batch.conf`.
- A preview runs until the scene's **story** is over: from 150 Myr before the first collision
  until nothing moves, up to 2 Gyr. Clips differ in length; `clip.json` says where the story is.
- Each scene gets an interest **score** (0-1) from its curves (closest approach, tidal tails,
  disruption). It only sorts; it never filters.
- `hires` replays the same physics with more particles, over the story only, and saves the run
  as `take.sillage`. Its default is the machine's maximum (`SILLAGE_MAX_PARTICLES`); cost grows
  with the count and the story's length (about 30 min at 1 M, 8 h at 10 M for 700 Myr).
- `look` and `export` only draw the take; no simulation. The chosen look is `look.json`.
- Estimates come from `library/.sillage/costs.json`, fitted on past runs and refreshed after
  each one. `sillage-render costs` prints it; `--check <batch>` compares it with a batch.

## Status files

What is running is written, not guessed. Three small JSON files, all with ISO 8601 dates and the
local offset, read alike by the app, a status command or a language model from afar.

**`library/activity.json`**, always at that path: `version`, `state` (`idle`, `running`,
`paused`), `job` (`kind` explore/hires/export, `batch`, `scene`, `startedAt`, `progress` 0 to 1,
`detail` such as "frame 412/900", `eta`), `night` (`id`, `phase`, `eta`) when a night runs,
`waiting` (jobs queued) and `updated`. `explore`, `hires` and `export` rewrite it every 10 s, so
`state: running` with an `updated` older than 15 minutes is a stuck run. Scenes explored side by
side share it: it shows whichever wrote last.

**`<batch>/night.json`**: `version`, `id`, `recipe` (the settings resolved), `phases` (`explore`,
`pick`, `hires`, `style`, `export`, each `name`, `planned`, `done`, `failed`, `skipped`,
`estimatedStart`, `estimatedEnd`), `state` (`running`, `paused`, `done`, `failed`, `stopped`),
`startedAt`, `deliverBy`, `estimatedEnd`, `endedAt`. The queue marks a night `paused` while it
is, and `stopped` or `failed` when it ended without saying so itself.

**`<batch>/events.jsonl`**, one JSON object a line, appended: `t`, `kind`, `scene` when it
applies, and these by kind.

| kind | fields |
|---|---|
| `night.start`, `night.done` | `night`, `seconds`; `status` (done, stopped, failed) at the end |
| `explore.scene` | `status` (ok, rejected, failed), `score`, `seconds` |
| `pick` | `chosen`, `rating`; `score` for a pick by the night |
| `hires.start` | `particles`, `steps` |
| `hires.done` | `particles`, `steps`, `minutes`, `takeGB` |
| `export.done` | `preset`, `style`, `codec`, `frames`, `megabytes`, `seconds`, `path` |
| `error` | `stage`, `message`, `log` |
| `style` | `style`, `path` (the promoted `look.json`) |
| `skip` | `stage`, `message` (skipped by hand, or for want of time) |
| `phase.done` | `phase`, `count` |

Scripts add an event with `sillage-render event <batch> <kind> --scene scene-0007 --status ok`
(`--take-gb` for `takeGB`) rather than writing JSON by hand. The ETA of `hires` follows the pace
of its frames once they start, and reaches the last frame, not the writing of the take after it.

`sillage-render status` prints what the app's status line and queue view say, from the same
formatter (`QueueStatus`): what runs and until when, the jobs waiting with their estimated start
and end, the last ten finished. A `sillage-render` process that wrote no status shows as
"Calcul en cours (sans détail)", so "le Mac est libre" is only said when nothing runs. The
fixtures in `Tests/Fixtures/queue-status/` hold the expected lines.

Details and measurements: [README](../README.md).
