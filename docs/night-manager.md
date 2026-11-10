# Night Manager

Generates many random galaxy-collision scenes, lets you pick the best, and renders those at
high resolution into finished videos. Each stage reads and writes the scene's own folder in
`library/<night>/<scene>/`.

The app is the way in; the command line does the same and is kept as the [appendix](#appendix-the-command-line)
below. Build and open the app with `./scripts/dev.sh app && open .build/dev/Sillage.app`
(macOS 14+, Apple Silicon; everything goes through `./scripts/dev.sh`, not SwiftPM).

## The words

The app, the command line's messages and these docs use one word per thing. The code and the
files keep their names (`hires`, `look.json`, `take.sillage`), so the right column is what you
will meet in a command or a path.

| in the app | what it is | in the code and on disk |
|---|---|---|
| **Night** (**Batch** when started by hand) | a folder of scenes and the run that fills it | batch, `night.json` |
| **Preview** | the 30 s clip a scene is first explored as | `preview.mov` |
| **Kept** / **Discarded** (buttons **Yes** / **No**) | your verdict on a scene | `ratings.json`, yes / no |
| **Score** | the interest of a scene, 0 to 1, which only sorts | interest score |
| **High resolution** (badge **HD**) | the scene replayed with many more particles | hires, `take.sillage` |
| **Style** | how the scene is drawn; **Use for scene** makes it the scene's | look, `look.json`, promote |
| **Rendering** | one drawing of the style (halo, spikes, dust) | `RenderLook` |
| **Palette** | the colours, with a world (**Telescope** or **Free**) | palette |
| **Videos** | the finished files of a scene | `exports/` |
| **Queue** | the heavy work waiting its turn, one at a time | job queue |
| **Take** | a recording opened by hand; only in the **Workshop** | take |

## In the app

The sidebar has **Library** (the landing screen), **Nights** and **Workshop**, the status
line and the **Queue** at its top. A scene goes through five stages; the library
groups its scenes by the stage they wait at (**To sort**, **Kept**, **In high resolution**,
**Style to choose**, **Ready**, **Exported**, **All**).

1. **Previews.** Click **New night** (sidebar or toolbar), leave everything on Auto, and
   click **Launch night**: the scenes are explored overnight. By hand, outside a night, the
   command line is the way (see the appendix); the scenes land in the library as **Batch**.
2. **Selection.** Open **To sort**. Each scene shows its Preview and its Score; press **Y** or **N**
   (buttons **Yes** / **No**) to keep or discard it, and a digit 0 to 9 to rate it. The
   night picks the best by Score when you have not.
3. **High resolution.** Open a scene and click **Recompute in high resolution…**, or open **Kept** and click **Compute in high resolution (n)** for the whole collection. The job goes to the **Queue**. It is drawn as a night draws it: Auto is 8 M from 2 M massive, and every size past 2 M keeps 2 M massive, the others light tracers. A real count is a command line away (step 3 of the appendix, without `--massive`).
4. **Style.** Click **Choose style** on a scene computed in high resolution. The style
   editor plays the scene; pick a **Rendering** and a **Palette**, then **Use for scene**
   (⌘S).
5. **Videos.** Click **Export…**, choose the formats, and the job joins the queue. The
   files appear under the scene's **Videos**.

## Nights

"New night" (the Nights entry of the sidebar, and the toolbar) opens a sheet whose only
control in view is the time, **Ready by** a delivery time (07:00 unless changed) or **Duration** a
number of hours. Under it, `NightSheetPlanner` plans the night with `NightPlanner` again after
every change (about 75 ms once the batch's draws are sized, which the app does at launch and the
sheet shares): one line a phase with what it computes, how long it takes and when it ends, then
the delivery and the margin. Disk too small, a hires that does not fit, fewer hires scenes than
asked for, a night that ends late: it warns and does not block. "Customise" is closed and
holds four settings, each Auto: hires scenes (1 to 4), colour world, formats (4K, vertical),
previews only. **Launch night** writes the recipe to `library/.sillage/recipes/` (a file
a night, as a queued night reads it when its turn comes), adds the job to the queue and keeps
the settings in `library/.sillage/night-sheet.json` for the next sheet. `Sillage.app --nightcheck`
runs the model without a window (plan latency, warnings, launch) and writes
`out/ui-night-sheet*.png`, as `--uishot` does.

### The night page

The Nights section of the sidebar lists the nights newest first, each a day and "35 scenes · 4
videos" (with "running", "paused", "stopped", "failed", "interrupted" or "waiting" when
it is not over), and a night just launched opens on its page. The page, `NightsSnapshot.read`
in `NightPage.swift`, shows:

- the five phases (Previews, Selection, High resolution, Style, Videos) with their counts, what
  was rejected, failed or left out, when each finished and when the others are expected to;
- while it runs, the job on one line ("scene-0023, high resolution, frame 412/900, ready around
  01:12"), its bar, and the delivery against the deadline;
- buttons: **Pause** / **Resume** (the whole queue), **Stop after this step**,
  **Stop now** (asks first), **Skip this scene** (during a scene's own steps; once
  asked it waits for the next scene) and **Sort**, which opens the triage view on the night's
  scenes still to sort;
- once it is over, the morning summary, `report.md` (written again from the files if it is
  missing);
- the scenes as cards as they arrive: the picked ones first in the order they were picked, then
  the others latest first, each at the stage it has reached; a click opens its page;
- the errors, each with a button to its log.

Everything is read from `night.json`, `events.jsonl`, `report.md`, `activity.json` and the
queue, every second, so a change shows within two and a night that ran while the app was closed
shows as it ended. A night whose file says running with no process behind it is
"interrupted". `Sillage.app --nightpagecheck` runs all this on copies of the fixtures of
`Tests/Fixtures/night-status/`, without a window or the GPU, and writes `out/ui-night-page*.png`.


## Appendix: the command line

Everything above can be run from a terminal; the stage commands first, then the night's recipe,
the queue and the status files, which the app reads and writes too.

### Stage by stage

**1. Explore** – generate scenes (30 s previews):

```bash
scripts/explore-batch.sh --scenes 50 --hours 8        # particle count chosen to fit the time
scripts/explore-batch.sh --scenes 20 --per-galaxy 50000   # quick
scripts/explore-batch.sh --out library/2026-10-24     # resume a stopped batch
scripts/explore-batch.sh --scenes 20 --galaxies 2-3 --only-archetypes antennae,mice  # skip other draws
scripts/explore-batch.sh --scenes 20 --pair-share 0.5  # half pairs instead of four in five; off for none
```

**2. Rate** – in the app (**Library**), or by editing `<batch>/ratings.json`.

**3. Hires** – re-run the scenes at high resolution:

```bash
./scripts/dev.sh hires library/2026-10-24                      # every "yes" scene, as a night
./scripts/dev.sh hires library/2026-10-24/scene-0001 --particles 2000000
./scripts/dev.sh hires library/2026-10-24/scene-0001 --particles 8000000 --massive 2000000
```

Without `--particles`, `hires` draws what a night draws (#243): 8 M, or the machine's maximum
below that, of which 2 M carry the mass. `--massive M` gives the mass to about M of the
particles drawn and makes the others light tracers in their field
([the note](notes/light-tracers.md)): the run looks like its count drawn and is stepped like M,
whose softening, step and settle it takes. The tracers walk at the scene's opening angle
(`--theta-tracers` is refused), and `hires.json` keeps both counts. `--particles N` without
`--massive` is a real N, every particle carrying the mass: that is how to get a real count,
which the app's form does not offer since it draws as a night does (#222).

Two passes (#239, [the note](notes/render-during-hires.md)), for counts whose take of every
particle would not fit on the disk:

```bash
./scripts/dev.sh hires library/2026-10-24/scene-0001 --massive 2000000 --pass massive
./scripts/dev.sh look library/2026-10-24/scene-0001 --style auto
./scripts/dev.sh hires library/2026-10-24/scene-0001 --massive 2000000 --pass full --export 4k,vertical
```

`--pass massive` samples the draw as a run with tracers does and runs its massive particles
alone: the take, the curves, `hires.mov` and `hires.json` (with `"pass": "massive"`) are theirs,
and the style is chosen on that take as on any other. `--pass full` runs the same draw again with
its tracers, which repeats the massive particles to the bit, and draws each frame in each preset
of `--export` (4k and vertical by default) as soon as the solver has it, framed, painted and
exposed as an export of the massive take: `exports/<preset>.mp4`, every particle drawn, no take
of them. It also keeps every particle at the curves' key frames in `keyframes.sillage`
(`keyframes.json` says which frames), for posters in any style, and adds `full` to `hires.json`.
It refuses to run without a massive pass of the same draw and steps. A take of the full pass is
still a flag away for whoever wants one (`--take <path> --take-interval 8`).

**4. Look** – choose the scene's style:

```bash
./scripts/dev.sh look library/2026-10-24/scene-0001 --style auto
```

Or open the scene in the library and click **Choose style**: the style editor plays the
take, and **Use for scene** (⌘S) promotes.

**5. Export**:

```bash
./scripts/dev.sh export library/2026-10-24/scene-0001                    # exports/1080p.mp4 (HEVC)
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset 4k --fps 60
./scripts/dev.sh export library/2026-10-24/scene-0001 --format webp      # or gif, --max-size 5MB
./scripts/dev.sh export library/2026-10-24/scene-0001 --preset whatsapp  # 720p H.264 under 15 MB + caption .txt
```

Presets: `1080p` (default), `4k`, `vertical`, `square`, `whatsapp`.
`--codec hevc|h264|prores` (default `hevc`). `--start` / `--duration` cut the clip,
`--look` picks a look. WebP needs `brew install webp`. `--take <path> --framing <take>` draws
another take of the same run framed, painted and exposed on the scene's take, as a full pass is
(#239); `--stills <dir> --still-frames 12,300` keeps those frames as PNGs, as the encoder took
them.

### The night recipe

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
               "archetypes": "auto", "pairShare": "auto", "galaxies": "auto", "seed": "auto" },
  "pick": "auto",
  "hires": { "particles": "auto", "massive": "auto", "frames": "auto", "passes": "auto" },
  "style": { "world": "auto", "freeShare": "auto", "style": "auto", "palette": "auto" },
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
| `explore.pairShare` | share of scenes with exactly two galaxies, 0 to 1, in the batch and in the picks | 0.8; `explore.galaxies` wins over it |
| `explore.galaxies` | `[least, most]` galaxies a scene has; others are skipped | any |
| `explore.seed` | the batch seed | the day, `20261028` |
| `pick` | `1` to `4`, or `"none"` to stop after exploring | 1 to 4 by score, as many as fit; a slot goes to a pair as often as `explore.pairShare` says |
| `hires.particles` | particles drawn, light tracers included | 8 000 000 (or the machine's maximum) |
| `hires.massive` | the particles that carry the mass, the others light tracers; as many as `hires.particles` for none | 2 000 000 (all of them below that) |
| `hires.frames` | the first frames of the story only | the whole story |
| `hires.passes` | `1`: a take of every particle, the videos exported from it after the style; `2`: the massive particles alone, the style on their take, then every particle again with the videos drawn as it runs (#239) | 1 up to 10 000 000 drawn, 2 past it; always 1 without light tracers |
| `style.world` | `telescope` or `free` | Auto: drawn for each pick, free as often as `style.freeShare` says |
| `style.freeShare` | share of the picks Auto puts in the free world, 0 to 1 | 0.2 |
| `style.style` | a look of the catalogue, such as `hubble` or `aurora` (its world is the pick's) | Auto: the best rendering of the world (`look --style auto`, #124) |
| `style.palette` | a family, the name of a favourite in `palettes/` or a `.palette.json` (its world is the pick's) | Auto: the best of the scene's seed in the pick's world, the favourites that fit among the candidates |
| `style.multicolour` | `false` for one colour per galaxy | Auto: on, each galaxy gets a ramp of colours (#120) |
| `style.camera` | `director`, `fixed`, `immersed`, or `scene` for the camera explore wrote | Auto: `director`, wide shots and shots that fill the frame with a disk and the pericentre (#186) |
| `export` | presets (`1080p`, `4k`, `vertical`, `square`, `whatsapp`), `webp`, `gif` | `["4k", "vertical"]` |

The style step. A world asked for holds for every pick; else a named `style.style` or a
`style.palette` family or file gives it; else Auto draws it for each pick: free with the chance
`style.freeShare` gives, 0.2 since the free palettes came out loud (#175), telescope otherwise.
The draw comes from the batch seed and the pick's place, best first, so a night resumed gives
each pick the world it had. A night of one pick has it free one time in five, of two picks a
free one 36 % of the time, of four 59 %; every fifth pick instead would never come round in a
night of four picks at most. A recipe whose parts disagree (a free family in the telescope
world) is refused before the night starts. A named style gets a palette of its world (Auto's or
the one given); no style is `look --style auto`, which scores every rendering of the world with
the scene's best palettes (or the one given) on key frames of the take, filmed with
`style.camera` (the director by default, [the note](notes/director-shots.md)). Planned at 20 s
in the telescope world and 400 s in the free one (52 pairs at 2 M particles), 20 s for a named
style; the plan draws each pick's world as the night will.

Dust as a web of filaments (#197). The dust of the 2026-10-30-b night read as coarse blobs
(#168), so #174 held it back from every generated style. It is drawn now as a web of filaments
in each disk's plane, carried round by the disk and renewed before it winds up (#173, #200,
[the note](notes/dust-web.md)), and it is back: the styles of `looks/` that carry dust, the
five built in and the standard look draw it as the web (`dustWeb` at `RenderLook.styleDustWeb`,
1), and `look --style auto`, the night's style step and the style editor's Auto draw and score
each rendering with its own dust (`StyleAuto.dustCap` is nil; set to 0 it would hold the dust
back again, a named `style.style` included, since it still goes to `look` with `--generated`).
Where the solver reads a disk as torn the web fades out and the grains carry the dust as they
always did, so tails and bridges keep theirs. Webb's dust went from 0.08 to 0.2, chosen side by
side on three takes: at 0.08 its web does not show even in a 4K export, at 0.2 it reads as fine
rust filaments over the blue-white disk, and Webb is Auto's usual telescope pick. Hubble keeps
0.45, which shows the web best. On the same takes the web keeps as much light as the grains
did, or up to 2.3 % less, and reddens as much, so no style needed its brightness or white point
back. A scene's `look.json` written before keeps its picture: a file that leaves `dustWeb` out
reads as 0.

How it plans. `NightPlanner` turns the recipe and the cost model into steps, each with its
duration, start and end, and the delivery of the whole night. Before exploring, it sizes the
first 16 draws of the batch from the generator alone (`ExploreProbe`, the same particles and
steps `explore-batch.sh` gives them, a quarter more for the story); after, it uses each scene's
own story. Auto keeps time for four picks, then three, two, one, and explores fifty scenes at
the largest count a galaxy that fits in what is left, less a margin (5 %, 5 to 20 minutes).
The pick takes scenes marked yes by hand first, never one marked no; then each slot goes to a
pair with the chance `explore.pairShare` gives, drawn from the batch seed as the worlds are, and
takes the best pair by score, or else the best of the others, or the best scene left once its
kind runs out. The score leans to groups (0.70 for pairs, 0.81 for groups of four on
2026-10-30-b), so the best alone would undo the batch's share. Score picks go to `ratings.json`
as `picked`.

A hires is drawn at 8 M, Auto's count since #185 (the count at which a disk filling the frame
reads as matter, see [gigantism](notes/gigantism.md)), and since #211 the mass is carried by 2 M
of them, the other 6 M light tracers in their field ([the note](notes/light-tracers.md)): the
texture of 8 M, the dynamics and the step of 2 M. The two real 8 M hires of 2026-10-30 took 237
and 239 minutes for 28 681 and 28 084 steps with the settle, peaked at 15.4 GB of memory and
wrote takes of 12.7 and 18.5 GB for 1 030 and 1 514 frames: the 1.53 bytes a particle a frame
the plan counted, which still holds since a take keeps every particle drawn. Since #237 a take
holds eight bytes a particle a kept frame instead of six, and the plan counts 2.04. Their 4K exports
took one and two and a half minutes. Drawn from 2 M, the same stories take 14 964 and 14 042
steps, and the model puts them at 63 and 59 minutes: 108 s + 62.4 ns a massive particle step,
fitted on the library's 2 M and real 8 M runs as before, and 20 ns a tracer step until runs with
tracers refit it. The first night with tracer hires (2026-11-04, in a library of its own: four
previews at 50 000 a galaxy, one pick, a spiral and a globular) ran its hires, 487 frames over
8 071 + 6 818 steps, in 66 minutes against 63 planned with the library's model, which puts a
real 8 M of it at 2 h 32. It peaked at 14.8 GB with its 6.1 GB take held in memory, and its
style and 4K export took 11 and 32 s. Refitted on it, a tracer step costs 22 ns. Planned from
the draws (seed 20261104) with the library's model, Auto now keeps room for four scenes in a
night of seven, eight or nine hours, after fifty previews at 150 000, 200 000 and 200 000 a
galaxy, where a real 8 M left room for one, two and two; `--plan` and the sheet say which before
the night starts. A real 8 M is still one setting away (`hires.massive` as large as
`hires.particles`), and a night resumed on a scene already done at a real 8 M keeps it.

How it runs. Explore (through `explore-batch.sh`, stopped at its share of the night), pick, then
for each pick, best first: hires, style, exports. Before each step it plans again from the
files. A hires starts only if its scene, style and exports included, ends before the delivery
time; a style or an export may end up to 15 minutes past it; a step still running then is
stopped. A step that fails or is left out leaves the scene out for the night, and the night goes
on with the next one. The same command on the same folder resumes: explored scenes, done hires,
promoted looks and existing exports are skipped; what was left out is tried again.

In two passes (`hires.passes`, #239) the hires step is the massive pass, the style is chosen on
its take, and the first video preset's export step is the full pass, which draws every video
preset of the recipe at once (`<scene>.full.log`); the other video presets are then done, and
`webp` and `gif` are exported from the massive take as before. The plan prices the hires step as
the massive particles alone and puts the whole full pass on that first preset: the run with its
tracers and each preset's frames drawn as it goes. The disk it counts is the massive take, the
key frames of every particle and the videos. A scene whose take of every particle is already
there is exported from it, in one pass.

Steering it, through the queue: `queue pause` and `resume` suspend the night and its step;
`queue stop` ends it after the current step; `queue stop --now` (or `cancel`) at once;
`queue skip` leaves out the scene it works on. Each takes the job's id, or acts on the night
running.

The night writes `recipe.json` (as given), `night.json`, `events.jsonl` and `report.md` in its
folder, and the logs of its steps in `.logs/` (`night-explore.log`, `<scene>.hires.log`, ...).
Exit status: 0 done, 3 stopped on request, 1 failed.

`report.md` is rewritten at the end of each phase and at the end, from `night.json`
and `events.jsonl` alone: seven lines (state and duration, delivery against the deadline, scenes
explored, rejected and failed, picks with their score, hires done, videos with their weight,
scenes left out and errors), then the list of hires with particles (and how many carry the mass)
and minutes, of videos with their path from the night's folder, and of failures with the path of
their log. Only what the night's runs wrote counts: a hires or a video run in the folder after
the night's end, by hand or from the queue, shows on its scene page and in the export list, not
in the night's numbers. A scene counts as left out only by the night's last run, and only until
the night does that step for it; the night page and `sillage-render status` count alike.

### Queue

Heavy work can go through one queue per library instead, one job at a time, in a runner of its
own that outlives the terminal or the app that started it and keeps the Mac awake:

```bash
R=".build/dev/sillage-render"   # with DYLD_LIBRARY_PATH=.build/dev, as dev.sh does
$R queue add hires library/2026-10-24/scene-0001 --particles 2000000
$R queue add hires library/2026-10-24                 # every chosen scene not done, as a night
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

#### Notifications

The runner posts a macOS notification at each `phase.done` and at `night.done` it finds in a
batch's `events.jsonl` while it works, when a job fails (stage and scene), and when the queue
empties after jobs asked for by hand. It runs without a bundle, which `UNUserNotificationCenter`
refuses, so it calls `osascript -e 'display notification …'` (0.14 s, exit 0 from a detached
process). The switch is `notifications` in `library/.queue/settings.json`, written by the app's
Settings (⌘,) and read at every notice. While something runs, a menu bar ring shows the
progress and the status line. `SILLAGE_NOTICE_LOG=<file>` appends notices there instead of
showing them, for checks.

### How it works

- A scene is `--seed S --index N` of a generator: same two numbers, same scene.
- `explore-batch.sh` runs 4 scenes at once, each at a low particle count with a plain look.
  Batches are resumable; settings are kept in `batch.conf`. It steps at seven times the
  recommended step (`--dt-scale 7`, 375 steps of settle) since #225: the same scenes come out
  on top as at 3.5, in half the time, with a third fewer young stars in the previews. A batch
  started before keeps its 3.5 and 750.
- Four scenes in five have exactly two galaxies, a globular or a dwarf companion counting as one
  and a black hole as none, in every stretch of ten (`--pair-share`, `pair_share` in
  `batch.conf`). A batch started before the share (#176) goes on with the draw it started with.
- A preview runs until the scene's **story** is over: from 150 Myr before the first collision
  until nothing moves, up to 2 Gyr. Clips differ in length; `clip.json` says where the story is.
- Each scene gets an interest **score** (0-1) from its curves (closest approach, tidal tails,
  disruption). It only sorts; it never filters. A preview that shows its largest galaxy under
  8 pixels in radius for more than half the clip is scored down in proportion, so a black one
  scores zero and a night picks it last (#217).
- `hires` replays the same physics with more particles, over the story only, and saves the run
  as `take.sillage`. It steps at 3.5 whatever the preview ran at: at 7 the story holds, but
  star formation and the compact knots do not ([the note](notes/doubled-step.md)). Its default
  is a night's draw, 8 M from 2 M, never above the machine's
  maximum (`SILLAGE_MAX_PARTICLES`); cost grows with the count and the story's length (about
  30 min at 1 M, 8 h at a real 10 M for 700 Myr). With `--massive M`, as a night runs it, only
  M carry the mass and set the step; the others are light tracers, which cost a third of a
  massive particle a step and nothing in the step. `--particles N` alone is a real N.
- `look` and `export` only draw the take; no simulation. The chosen look is `look.json`.
- Estimates come from `library/.sillage/costs.json`, fitted on past runs and refreshed after
  each one. `sillage-render costs` prints it; `--check <batch>` compares it with a batch. A
  hires is priced as the steps of its massive particles (`hires`, fitted on the runs without
  tracers as it always was) plus those of its light tracers (`tracers`, a line through zero
  fitted on what the runs with tracers took past the first, 20 ns a step before any). Every
  night draws 8 M from 2 M, so its runs alone could not tell the two apart. A `costs.json`
  written before has no `tracers` and reads with the 20 ns. In two passes (#239) a massive pass
  is a run without tracers, a full pass one with them less its drawing, and `draws` prices a
  frame drawn during the run for each preset, a fixed part and a part for each particle drawn,
  fitted on the full passes' `hires.json` (their videos stay out of the `exports` lines).

### Status files

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
| `hires.start` | `particles`, `massive` (with light tracers), `steps`, `pass` (`massive` or `full`, in two passes) |
| `hires.done` | `particles`, `massive`, `steps`, `minutes`, `takeGB`, `pass` |
| `export.done` | `preset`, `style`, `world`, `family`, `harmony`, `seed`, `codec`, `frames`, `megabytes`, `seconds`, `path`, `pass` (`full` for a video a full pass drew) |
| `error` | `stage`, `message`, `log` |
| `style` | `style`, `world`, `family`, `harmony`, `seed` (the palette's, as in `look.json`), `path` (the promoted `look.json`) |
| `skip` | `stage`, `message` (skipped by hand, or for want of time) |
| `phase.done` | `phase`, `count` |

Scripts add an event with `sillage-render event <batch> <kind> --scene scene-0007 --status ok`
(`--take-gb` for `takeGB`) rather than writing JSON by hand. The ETA of `hires` follows the pace
of its frames once they start, and reaches the last frame, not the writing of the take after it.

`sillage-render status` prints at most five lines, in the words of the app's status line and
queue view (the first comes from the same formatter, `QueueStatus`, then the night's own files):

```
Night of 26 Oct · high resolution 2/4 · scene-0023 frame 412/900 · ready around 06:20 · 0 errors
Previews 50/50 (2 rejected, 1 failed) · selection 4/4 · high resolution 1/4 · 1 video
Delivery: ready around 06:20, by 07:00, 40 min to spare
Last video: scene-0019/exports/4k.mp4 · 212.3 MB · 00:40
```

A line of errors (the first, with its log) comes before the video when there are any. Idle, it
says "Nothing running · the Mac is free" and names the last night with how it ended. `--night
<folder>` reports that night instead, `--json` prints the same as one object (the `lines`, and
the counts, failures and last video apart), and `--full` prints every job of the queue: what
runs and until when, the jobs waiting with their estimated start and end, the last ten finished. A `sillage-render` process that wrote no status shows as
"Computing (no detail)", so "the Mac is free" is only said when nothing runs. The
fixtures in `Tests/Fixtures/queue-status/` hold the expected lines.

Following a night from afar, with a small model: [night-status.md](night-status.md).

Details and measurements: [the reference](reference.md).
