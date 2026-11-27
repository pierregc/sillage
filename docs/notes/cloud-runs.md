# Runs on a rented GPU (#283)

How to compute on an NVIDIA GPU rented on Vast.ai, from the Mac, with `scripts/gpu-box.sh`. The
Mac only drives the box over SSH: renting, shipping the code, running, fetching, destroying.
Nothing heavy runs on the Mac.

## Once, on the Mac

1. An SSH key for the boxes alone: `ssh-keygen -t ed25519 -f ~/.ssh/sillage_gpu`, its public
   half added to the Vast account (Account, SSH Keys). Vast puts it on every new box.
2. A Vast API key, written by hand in `~/.config/sillage/gpu.env`, `chmod 600`:

   ```sh
   VAST_API_KEY=...
   # optional, with their defaults:
   # SSH_KEY=~/.ssh/sillage_gpu
   # GPU=RTX 3090
   # IMAGE=nvidia/cuda:12.8.1-devel-ubuntu24.04
   # MAX_PRICE=0.35
   # DEADLINE_HOURS=3
   ```

   The file never enters the repository. The script never prints the key, never puts it on a
   command line (curl reads it from a header file of its own) and never sends it to a box.
3. Prepaid credit on the account, **no saved card**: at zero credit Vast stops the instances, so a
   forgotten box cannot cost more than what is left.

## A session

```sh
scripts/gpu-box.sh offers "RTX 3090"   # the cheapest suitable offers, nothing rented
scripts/gpu-box.sh up "RTX 3090"       # rents the cheapest, waits for SSH, arms the deadline
scripts/gpu-box.sh setup               # Swift 6.2, ffmpeg, tools; prints the GPU, nvcc, Swift
scripts/gpu-box.sh ship                # the checkout, without .build and .git, to /work/sillage
scripts/gpu-box.sh run scripts/linux.sh engine-check
scripts/gpu-box.sh wait                # or `tail` to look without waiting
scripts/gpu-box.sh fetch logs          # into ~/claude-workspace/gpu-out/<date>-<box>/
scripts/gpu-box.sh down "what ran"     # destroys it, checks, appends to gpu-ledger.md
scripts/gpu-box.sh list                # every instance on the account, and the credit left
```

- `up` keeps on-demand offers only (a box that pauses in the middle of a debugging session wastes
  it), from verified hosts with a CUDA 12.8 driver, 8 cores, 32 GB, 60 GB of disk, a reliability
  of 0.98, under `MAX_PRICE`, and leaves mainland China out (swift.org and GitHub downloads are
  unreliable there). The state of the box (its id, address, price, start, deadline) is kept in
  `~/.config/sillage/box`, outside the repository.
- **The deadline.** Vast enforces none. The box arms its own at start: after `DEADLINE_HOURS` it
  deletes itself with `CONTAINER_API_KEY`, the key Vast gives each instance for that instance alone.
  `up` prints "deadline armed" once it has checked; `status` shows the time left.
- `run` starts the command in tmux on the box, its output in `/work/logs/<n>.log` and its exit
  code in `/work/logs/<n>.exit`, and returns at once: a dropped SSH connection does not stop it.
- `GPU_BOX_DRY=1 scripts/gpu-box.sh up` prints the rental it would ask for, without renting.
- Destroy the box while a fix takes long to write: a box is paid while it waits. `setup` and the
  build take about ten minutes on a fresh box.

## One frame of each scene (#513)

The first test of a card is short: the engine check, then one 4K frame of a few scenes beside the
Mac's, and no video. `engine-check` builds the tool the frames are drawn with. The check needs nothing but the checkout: it draws `Tests/Fixtures/engines`
and the Sombrero fixture's frames (the sky, the bloom's shares, the dust layer, the dust screen)
and holds them to Metal's references, once the Mac has written the Sombrero ones
(`SILLAGE_WRITE_SOMBRERO=1 ./scripts/dev.sh test --filter SombreroFixtureTests`).

On the Mac, Metal's frame of each scene at the second chosen, under the names `sillage-cuda` gives
them (`<preset>-flight-<seconds>s.png`):

```sh
./scripts/dev.sh render export <take> --look <look> --flight <flight> --flight-stills mac \
    --flight-at 39 --preset 4k --fps 30
```

On the box, the same moments, then side by side:

```sh
scripts/gpu-box.sh up "RTX 3090" && scripts/gpu-box.sh setup && scripts/gpu-box.sh ship
scripts/gpu-box.sh run scripts/linux.sh engine-check
scripts/gpu-box.sh wait
scripts/gpu-box.sh put <take> <look> <flight> <tile.json> <tile .f32> <lut .f32>
scripts/gpu-box.sh run env LD_LIBRARY_PATH=.build/linux .build/linux/sillage-cuda still \
    /work/in/<take> --look /work/in/<look> --flight /work/in/<flight> --seconds 39 --preset 4k \
    --rate 30 --out /work/cuda
scripts/gpu-box.sh wait && scripts/gpu-box.sh fetch logs cuda
scripts/gpu-box.sh down "engine check, one 4K frame of each scene (#513)"
python3 scripts/still-pairs.py mac ~/claude-workspace/gpu-out/<date>-<box>/cuda --out pairs
```

A flight names its dust screen's tile by path (`inside.dustScreen.tile`): on the box it is
`/work/in/<tile.json>`, so the flight put there names that path, and the tile's json names its two
`.f32` files beside it. The frames are held to nothing but the eye and `comparison.md`'s PSNR:
the fixtures are the numbers that pass or fail.

## Every CUDA check in one run

`scripts/cuda-card-check.sh` runs the engine check and every CUDA Swift test on the card, timings,
the 200 M faint light and exact resume left out, and prints a `VERDICT` block last, which the
workflow's log shows (its artifacts cannot be fetched from the cloud). It checks bits, not speed:
the cheapest card of sm_86 or later does (RTX 3060 and up), billed by the second, so a deadline of two hours costs nothing more:

```text
gpu.yml: command scripts/cuda-card-check.sh, gpu RTX 3060, max_price 0.15, hours 2
```

## What the boxes ran

| date | GPU | driver | CUDA toolkit | image |
| --- | --- | --- | --- | --- |
| 2026-11-21 | RTX 3090 24 GB (Vast, Quebec) | 615.71.09 | 12.8.93 | `nvidia/cuda:12.8.1-devel-ubuntu24.04`, Swift 6.2 RELEASE |

## Vast's API, as it was on 2026-11-21

- `POST /api/v0/bundles/` searches offers (a JSON query); `PUT /api/v0/asks/<offer>/` rents one
  (`client_id: me`, `image`, `disk`, `runtype: "ssh_direc ssh_proxy"`, `onstart`) and returns
  `new_contract`, the instance's id; `GET /api/v0/instances/<id>/` gives its state and SSH port;
  `DELETE /api/v0/instances/<id>/` destroys it.
- The list of instances has moved: `GET /api/v0/instances/` answers 410, `GET /api/v1/instances/`
  is the one.
- `GET /api/v0/users/current/` gives the credit. Its answer also holds the account's e-mail
  address: the script reads only the credit from it.

## From a workflow, with the Mac off (#428, #440)

`.github/workflows/gpu.yml` runs `gpu-box.sh` from GitHub's runner: it rents, ships the commit, runs
one command, brings the results back as artifacts and destroys the box.

- Secrets of the repository: `VAST_API_KEY`, `GPU_SSH_KEY` (the private half of the key on the Vast
  account) and, for takes, `RCLONE_CONF` (the `sillage` remote, `drive.file` scope).
- Start it: Actions, gpu, Run workflow; or `gh workflow run gpu.yml -f dry_run=false -f command='...'`;
  or the GitHub tools of a cloud session (`actions_run_trigger`). **The first input, `dry_run`, is
  ticked by default: it lists the offers and prints the rental, and rents nothing.**
- Safety nets, in this order: the destroy step (`if: always()`), the `cleanup` job (destroys by the
  run's label), the box's own deadline. A take that did not reach the Drive keeps the box up until
  its deadline unless `drop_take` is ticked; the job summary says where to reach it.
- A run's summary holds the ledger line and the SHA-256 of every file brought back.
- `scripts/take-store.sh` keeps takes on the Drive (`up`, `down`, `list`, `archive`); `scripts/gpu-check.sh`
  tests both scripts in the Linux workflow with a recorded Vast and a folder for the Drive.
