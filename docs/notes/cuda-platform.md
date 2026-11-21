# CUDA as a compute platform: who asks a box for work, and where takes live (#427)

A study for epic #423, written in a cloud session on 2026-11-21: no code, nothing rented. It
answers the two questions that decide whether going to a GPU and back is easy, and ends on
Pierre's verdict. #428 (one job, any machine) is amended to that verdict.

**In short.**

- **Asking for work.** A GitHub Actions workflow, started by hand (`workflow_dispatch`), rents the
  box, runs the job on it through a runner registered for that one job, uploads what it made and
  destroys the box whatever happens. The Vast key becomes a secret of the repository. A cloud
  session starts it through the GitHub tools it already has, the Mac with one command, Pierre from
  the GitHub app on his phone. The Mac stays a driver for the long, hands-on sessions (bring-up,
  debugging), with `scripts/gpu-box.sh` as today.
- **Where takes live.** A take stays where it was computed only as long as its box lives. What
  travels by default is what a flight needs: the key frames and extracts of #379, a hundredth of
  the take. A whole take comes down to the Mac only when the Mac will draw it. A take kept between
  sessions goes to an object store with no fee on the way out, if Pierre opens one; not to a Vast
  volume (it stays on one host) and not to the VPS. Computing a take again is cheap but does not
  give the same take on a GPU today, so a scene whose flights were designed keeps its take or its
  extracts.
- **Integrity.** Whatever writes a take writes its SHA-256 beside it; whatever receives one checks
  it before drawing. A new ticket.

## Pierre's verdict (2026-11-21)

- **Asking for work: the workflow** (option 2 below). #428 is amended to it. The Vast key in the
  cloud environment (option 3) is not taken.
- **Where takes live: every take kept whole**, not extracts in its place: GPU time is paid, and
  a take computed again would not be the same one. They go to a folder of Pierre's Google Drive
  (about 150 GB free), reached through rclone with Google's `drive.file` scope, which sees only
  the files rclone created; once the Drive is full, to the Mac's 1 TB disk; old takes are deleted
  only when nothing can hold them. #440 builds it, with the digest of the integrity section. The
  recommendation below, extracts by default, is kept for the record and not followed.

## What was read, and what was not

The figures for Vast.ai (storage, bandwidth, offers) come from [gpu-rental.md](gpu-rental.md),
read on Vast's pages on 2026-11-10, and from #283's run of 2026-11-21
(`cloud-runs.md`, on PR #420's branch until it merges). This session's network refuses the
providers' hosts (`docs.vast.ai`, `console.vast.ai`, `developers.cloudflare.com` answer 403 at the
proxy), so **no price here was read again today**: the object store's figures are the ones
published through 2026 and must be checked on its page before anything is opened. GitHub's rules
are those of its documentation on Actions security as of 2026.

## Asking for work

Today only a session on the Mac reaches a box: the SSH key and the Vast key are on the Mac, a cloud
session has no SSH client and no route to port 22 ([gpu-rental.md](gpu-rental.md#a-cloud-coding-session-cannot-open-ssh)),
and the cloud environment's network does not even allow Vast's API. So nothing runs on a GPU unless
the Mac is on and a session sits on it; the cloud sessions, which write most of the CUDA code, never
see it run.

### 1. The Mac as the only driver (today)

- **To build**: nothing; `gpu-box.sh` exists (#283).
- **To run**: the Mac on, a session on it for the whole run; a dropped session leaves the job
  running in tmux and the box's own deadline bounds the cost.
- **Safety**: the keys never leave the Mac; the box deletes itself with the key Vast gives that
  instance alone; prepaid credit, no card.
- **For a cloud session**: nothing. Its GPU tests, timings and previews wait for a Mac session,
  which also means one of the Mac threads Pierre has to start by hand.

### 2. A workflow that rents a box and runs one job on it

A workflow `gpu.yml`, started only with `workflow_dispatch`, with inputs such as the command, the
GPU, the price ceiling and the hours allowed:

1. A job on GitHub's own runner rents the offer (the same query as `gpu-box.sh up`), with a start
   script that arms the deadline, installs the toolchain and registers an Actions runner with a
   just-in-time configuration: one job, then the runner unregisters and the box is of no further
   use to anyone.
2. The job itself runs on that runner, `runs-on` naming a label unique to the run: it checks out
   the commit asked for, builds, runs the command, and uploads the results as artifacts (logs,
   reports, videos, stills).
3. A last job on GitHub's runner, `if: always()`, destroys the instance, checks it is gone, and
   writes the session into the job's summary (price, hours, what ran), the line the ledger takes.

- **To build**: one workflow and the start script, reusing `gpu-box.sh`'s offer query and its
  deadline; about a day of a session, then one paid trial of about half an hour. GitHub's minutes
  are free on a public repository.
- **To run**: nothing on the Mac. A job runs from a cloud session (the GitHub tools these sessions
  already have can start a workflow and read its logs and artifacts), from the Mac
  (`gh workflow run gpu.yml -f ...`) or from the GitHub app on a phone.
- **Who can start a job**: `workflow_dispatch` needs write access to the repository, which only
  Pierre has. A fork cannot start it, and a pull request from a fork never reaches this runner:
  the workflow has no `pull_request` trigger, and the runner exists only for the one job that
  rented it. GitHub's advice against self-hosted runners on public repositories is about runners
  that stay and that any pull request can target; a runner made for one dispatched job and
  destroyed with its box does not have that exposure.
- **Where the key lives**: `VAST_API_KEY` as a secret of the repository, never in a file. GitHub
  hides it in logs and does not give it to workflows started from forks. Only the rent and destroy
  jobs read it, on GitHub's runners; the box never receives it (it deletes itself with its own
  instance key, as today).
- **What the box holds**: the public checkout, the inputs the job fetched, its results. No key of
  Pierre's, no SSH key.
- **The limits**: a job on a self-hosted runner may last 5 days, and an artifact is kept 90 days at
  most: videos, stills and reports go well, a 15 GB take is the wrong thing to upload (see below). The box must reach GitHub over HTTPS, which every Vast host does.
- **For a cloud session**: run a pull request's GPU tests (`scripts/linux.sh engine-check`, the
  suites skipped without a GPU), time a kernel or an export with `--profile`, draw a preview or a
  flight's keys, then read the artifacts and write the numbers on the ticket, with no Mac.

### 3. The provider's API called from a cloud session

The cloud session rents and destroys the box itself, the box gets a start script and no SSH.

- **To build**: little, `gpu-box.sh` in another shell.
- **Where the key would live**: in the cloud environment's settings, as a variable every session
  of that environment can read and print; and the environment's network would have to allow
  Vast's hosts. Neither can be confined to one job.
- **The results**: a box with no SSH has to push them somewhere the session can read (a branch, an
  object store), so it needs a write credential of its own, which is the problem of option 2
  without GitHub's handling of secrets.
- **For a cloud session**: the same as option 2, at a higher risk, and only from these sessions.

### Recommendation

Option 2 for every job that fits in a command: GPU tests, timings, previews, takes and exports at
today's sizes. Option 1 stays for bring-up and debugging, where a person or a Mac session needs a
shell on the box. #428 becomes "a job on a GPU from a workflow". The credit stays prepaid with no
card, and the workflow refuses to rent above its price ceiling or for longer than its hours.

## Where takes live

A take is 15 GB at 8 M over 923 frames, 24.5 GB over 1,514, 60 to 100 GB at 32 M
([scenes-on-rented-gpus.md](scenes-on-rented-gpus.md)); it does not compress. A box's disk goes
with the box. Every later draw of the scene (another flight, another look, the 4K after the 1080p)
needs the take, or the part of it the draw reads, on the machine that draws.

| where | what it costs | what it gives | what it asks |
| --- | --- | --- | --- |
| the Mac | 20 to 35 min at 100 Mbit/s for 15 GB, 2 to 4 at a gigabit; bandwidth 0 to 0.05 $/GB at the host (up to 0.75 $ for 15 GB) | the take where the app, the flight editor and Metal's exports are | the Mac's disk: a few scenes of 8 M, no 32 M take |
| a Vast volume | the host's storage price, 0.20 $/GB a month at the median (3 $ a month for 15 GB) | the take beside the next box | a volume lives on one physical machine: the next box must be rented on that host, at that host's price, if it is free |
| an object store with no fee out (Cloudflare R2 as published: about 0.015 $/GB a month, the first 10 GB free) | about 0.25 $ a month for 15 GB, 1.5 $ for 100 GB | the take reachable from any box, the Mac and a workflow at once | an account of Pierre's and a write key, kept like the Vast key |
| the VPS | its free disk, unknown here | nothing an object store does not | it runs Scintille in production; only with Pierre's go, and not recommended |
| no take: compute it again | an 8 M take is about 0.6 h of a 5090, 0.2 to 0.4 $ (estimate) | nothing to keep | **not the same take on a GPU today**: the tree's layout follows the order of its atomics, and #283 found that a GPU's take pass does not even resume to its own bytes. A flight designed near matter would meet other stars |
| key frames and extracts (#379) | 8 bytes a drawn particle a frame: 64 MB a key frame at 8 M, an extract of 10 stored frames of 8 M about 0.6 GB | what a flight, a still or a visit reads, small enough to travel and to sit in an artifact | the frames chosen before the take is dropped |

### Recommendation

- **By default nothing large travels.** A job computes the take, draws what was asked from it on
  the same box, and brings back the videos, the stills, the reports, and the key frames and extracts
  that the scene's flights read (`take extract`, #379). A flight can be designed and drawn again on
  those alone (`export --flight --take <extract> --framing <take>`).
- **A whole take comes down to the Mac** when the Mac will draw it or open it in the app: 8 M
  takes, as #380 did.
- **A whole take kept for later** (a 32 M scene, a scene still being explored) goes to an object
  store if Pierre opens one; the price is small against the GPU time it spares only if the take is
  drawn again before it is deleted. Until then, a take not kept is a take computed again, knowing
  it will not be the same particles.
- **Computing again becomes an option worth having** once a GPU take pass is reproducible
  (canonical tree layout on the GPU, as the CPU target does). That is a ticket of its own, which
  the resume bug of #283 already points at.

## Integrity

A take that travelled is checked before it is drawn.

- Whatever writes a take (`hires`, `take extract`, the key frames) writes `<take>.sha256` beside
  it, computed as the file is written (`PortableSHA256`, the same on the Mac and Linux), and a
  segment's digest where the file grows (`rsync --append-verify` already checks each transfer, not
  the file against what wrote it).
- Whatever receives a take checks it once on arrival and refuses to draw a take whose digest does
  not match; `export`'s plan records the digest it drew from, so a resumed export knows it reads
  the same take (today it records the take's path and size).
- A workflow's artifacts carry their own digests; a job writes `sha256sum` of what it uploads in
  its summary.

## The tickets that follow

- **#428**, amended: the workflow of option 2, its start script, a trial on the cheapest box that
  runs `engine-check`, the ledger line written by the destroy job.
- **New**: a digest beside every take, checked on arrival and recorded in an export's plan.
- **New, after #424**: a GPU take pass that lays out its tree canonically, so that computing a take
  again gives the same take and a resumed pass gives the same bytes.
- **Only on Pierre's go**: an object store for the takes kept between sessions.
