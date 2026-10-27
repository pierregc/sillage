# Following a night from afar

How to answer "où en est la nuit ?" from a phone, or be told only when something matters,
with no server: a small language model on the Mac reads the files Sillage already writes.
This page is written to be given to such a model together with the files, and nothing else.

## If you can run commands, run this first

```bash
DYLD_LIBRARY_PATH=.build/dev .build/dev/sillage-render status      # in the Sillage folder
```

It prints at most five lines, in French, in the words of the app. Answer with them as they are
(see [the answer](#the-answer-in-three-lines)). `--json` prints the same as one object,
`--night library/<day>` reports that night instead of the latest, `--full` lists every job of
the queue. Only read the files below when the command is not there or fails.

## The files

All dates are ISO 8601 with the local offset (`2026-10-27T01:09:55.000+01:00`). Everything is
under the `library/` folder of the Sillage folder. Read them; never write to them.

| file | what it is |
|---|---|
| `library/activity.json` | what runs **now**, always at this path |
| `library/<day>/night.json` | the plan and progress of the night of that day |
| `library/<day>/events.jsonl` | what happened, one JSON object a line, oldest first |
| `library/<day>/report.md` | the night's report in French, rewritten at each phase end |
| `library/.queue/queue.json` | the job queue (a night is one job); use it only to count what waits |

The night to follow is the latest `<day>` folder that has a `night.json`.

### `activity.json`

- `state`: `idle` (nothing runs), `running`, or `paused`.
- `updated`: when a running step last wrote the file, every 10 s.
- `job` (only when it runs): `kind` (`explore`, `hires`, `export`), `batch`, `scene`,
  `startedAt`, `progress` from 0 to 1, `detail` ("frame 412/900", which the app says "image 412/900"), `eta`.
- `night` (only when a night runs): `id`, `phase`, `eta` (when the whole night will be done).
- `waiting`: jobs queued behind this one.

### `night.json`

- `state`: `running`, `paused`, `done`, `failed` or `stopped` (stopped on request).
- `startedAt`, `deliverBy` (the deadline, 07:00 by default), `estimatedEnd`, `endedAt`.
- `phases`: five, in order `explore` (previews), `pick` (choice), `hires` (high resolution),
  `style` (look) and `export` (videos). Each has `planned`, `done`, `failed`, and sometimes
  `skipped` (left out). A phase is over when `done + failed + skipped` reaches `planned`.
- `recipe`: the settings; ignore it.

### `events.jsonl`

Every line has `t` (when) and `kind`; `scene` when it concerns one scene.

| kind | meaning | other fields |
|---|---|---|
| `night.start` | the night began | `night` |
| `explore.scene` | one preview finished | `status` (`ok`, `rejected`, `failed`), `score`, `seconds` |
| `pick` | a scene was chosen for hires | `chosen`, `rating`, `score` |
| `hires.start` | a high-resolution run began | `particles`, `steps` |
| `hires.done` | it finished | `particles`, `steps`, `minutes`, `takeGB` |
| `style` | the scene got its look | `style`, `world`, `path` |
| `export.done` | a video is ready | `preset`, `megabytes`, `seconds`, `path` |
| `error` | a step failed, its scene is out for the night | `stage`, `message`, `log` |
| `skip` | a step was left out, by hand or for lack of time | `stage`, `message` |
| `phase.done` | a phase is over | `phase`, `count` |
| `night.done` | the night is over | `status` (`done`, `stopped`, `failed`), `seconds`, `message` |

## What "stuck" looks like

`activity.json` says `"state": "running"` and `updated` is **15 minutes or more** older than now.
A running step rewrites it every 10 s, so something died or hangs. `sillage-render status`
then adds "semble bloqué, rien écrit depuis …". A night `paused` on purpose is not stuck.
Also not stuck: `state: idle`, whatever `updated` says.

The state of the Mac is `idle` only when nothing runs; `running` with a recent `updated` is
fine, even when the progress looks slow (a hires of 2 million particles takes about 30 minutes).

## The answer in three lines

Same words as the app and `sillage-render status`, in French, whatever language was asked.
The status command's own five lines are fine too; to write them yourself from the files:

1. **State.** `Nuit du 26 oct. · haute résolution 2/4 · scene-0023 image 412/900 · prêt vers 6 h 20 · 0 erreur`: the night's day, the phase (`aperçus`, `choix`, `haute résolution`,
   `style`, `export`) with `done+1/planned`, the scene and its `detail`, when it will be done
   (`night.eta`), the number of errors (`error` events). Ended: `terminée 6 h 41, avant 7 h 00`,
   `en échec 3 h 12` or `arrêtée`. Idle: `Rien en cours · le Mac est libre`.
2. **Progress.** `Aperçus 50/50 (2 rejetés, 1 en échec) · choix 4/4 · haute résolution 1/4 · 1 vidéo`: from the `explore`, `pick` and `hires` phases of `night.json` (its counts win over the events), and the number of `export.done` events. Say nothing of `style` and `export`.
3. **Deadline or trouble.** `Livraison : prête vers 6 h 20, avant 7 h 00, 40 min de marge`
   (`estimatedEnd` against `deliverBy`), or, when there are errors, the first one: `Erreurs :
   scene-0007 haute résolution : failed with status 1 (journal …) · et 1 de plus`.

If a video exists, add `Dernière vidéo : <path> · <Mo> · <h mm since the start>`.

## Five states, to compare with

`Tests/Fixtures/night-status/` holds five complete `library/` folders with the answer
`sillage-render status` gives for each (`expected.txt`).

| state | how to recognise it | what to say |
|---|---|---|
| idle | `activity.json` is `idle`, no night is running | `Rien en cours · le Mac est libre`, then how the last night ended |
| exploring | `night.phase` is `explore`, `job.kind` is `explore` | previews so far out of the planned, then the deadline margin |
| mid hires | `night.phase` is `hires`, `job.kind` is `hires`, some phases done | the scene and its frame, the ETA, the margin |
| failed | `night.json` is `failed`, `error` events, `night.done` with `status: failed` | the count of errors, the first with its log |
| done | `night.json` is `done`, a `night.done` event | `terminée` with the hour, the deadline, the number of videos |

## The hourly routine

A routine that runs every hour from 22:00 to 09:00 on the Mac that renders (it needs to read
the files; give it that folder, or the shell). It stays silent unless one of four things
happened since its last run, and then sends one short notification. Haiku at low effort is
enough: the command does the reading.

Prompt to paste:

```text
You follow a Sillage night on this Mac, in the folder ~/claude-workspace/sillage.
Read docs/night-status.md there first. Then run, in that folder:
DYLD_LIBRARY_PATH=.build/dev .build/dev/sillage-render status --json
and, if it is not available, read library/activity.json and the newest
library/*/night.json and events.jsonl as the page explains.

Speak only if at least one of these is true, otherwise send nothing and stop:
1. PHASE END: events.jsonl has a phase.done line less than 60 minutes old
   (a phase of the night just ended).
2. FAILURE: events.jsonl has an error line less than 60 minutes old, or a night.done line
   less than 60 minutes old with status failed.
3. STUCK: activity.json says running and its "updated" is 15 minutes or more old.
4. MORNING: events.jsonl has a night.done line less than 60 minutes old.

When you speak, send one notification of at most three lines, in French, in the words of
sillage-render status: line 1 what happened (phase ended, which error, stuck since when,
night over), line 2 where the night stands, line 3 the deadline margin. For MORNING, use the
first lines of the night's report.md and name the number of videos. Never invent a number;
if a file is missing, say so in one line. Do not write to any file.
```

Sixty minutes is the hour between runs, so an event is told once; a run late by a few minutes
may miss one at the edge, and the morning report in the app's notification covers it. A stuck run is told again at each run until someone looks.

### What Pierre sets up once

1. Create the routine with the prompt above, on the schedule `0 * * * *` (hourly) limited to
   the night's hours, with the model set to Haiku and the effort low.
2. Point it at the Sillage folder of the Mac, with read access and permission to run
   `sillage-render status`; nothing else.
3. Turn on push notifications for it on the phone.
