# Renting an NVIDIA GPU for the big runs (#270)

Step 1 of epic #269, phase 1: a survey on paper, read on 2026-11-10, with no account created and
nothing rented. It prepares phase 2: #283 brings the CUDA engine up on a rented GPU and times it,
#279 runs 200 M there, #280 spreads a billion over several cards. Phase 2 starts only when Pierre
says so.

**In short.** RunPod's Secure Cloud, driven from the Mac over SSH. #283 builds and checks
correctness on an RTX 4090 (0.89 $/h) and times a 5090 for an hour, about 5 $; #279 runs on an
RTX 5090 (1.19 $/h), about 6 h and 7 $ (5 to 10) for a 200 M story by the estimates below. Vast.ai
is the fallback and the cheaper route once the routine is known: a 5090 from a verified host in
Europe at 0.65 to 0.87 $/h. No provider shortlisted here enforces a deadline on a box, so every box
carries a watchdog that deletes it with the key the provider gives that box alone, on a prepaid
balance with no automatic top-up: a forgotten box costs at most its watchdog's time, and never more
than the balance. Bring-up and the first 200 M run fit in phase 2's 20 €.

## How this was read

On 2026-11-10, first through a web search engine's quotes, then, once Pierre allowed their hosts
in the session's network the same evening, on the pages themselves. Read in full:

- **RunPod**: its pricing page and GPU pages, and its documentation (billing, pod pricing and
  storage, `runpodctl pod`, managing pods, SSH, a pod's environment variables, credentials, data
  centres, the v2 REST API, referrals).
- **Vast.ai**: its documentation (billing, quickstart, instance types, security, a container's
  environment, the RTX 50 series, the CLI's first steps), and the offers themselves through the
  public search behind its console (`console.vast.ai/api/v0/bundles/`, read without an account:
  the first 64 on-demand single 5090s, 4090s and 3090s it returned, around 20:45 UTC).
- **Verda** (pricing, the RTX PRO 6000 page, billing), **Jarvislabs** (pricing, FAQ),
  **Hyperstack** (pricing, billing by state, hibernation), **TensorDock** (home page, billing API),
  **Modal** (pricing, timeouts, budgets, CUDA).
- **Blender Open Data**, through the data its query page loads, and **Chips and Cheese**'s
  articles on Blackwell, the RTX 4090 and the M2 Pro's GPU.

Not read, and so known only through the search engine's quotes (marked *quoted* below): Scaleway,
whose site answers a script with a bot challenge; TechPowerUp, which refuses it (403); and every
provider dropped early (OVHcloud, Hetzner, Lambda, Thunder Compute, DigitalOcean, Genesis Cloud,
Sesterce, Salad, the hyperscalers, the free tiers), whose hosts were not opened. A page marked
*third party* is an aggregator. Nothing was signed up for, logged into or filled in. #283 reads
the price again on the day it rents: on a marketplace it moves by the hour.

Dollars are converted at about 1.12 $ a euro (11 October 2026, [fx]); 10 € is about 11 $. A
provider outside the EU may add French VAT (20 %) to a private customer's bill; the budgets below
leave room for it.

## What Sillage asks of a rented machine

From the ticket, unchanged:

- An NVIDIA GPU of compute capability 8.6 or more and a driver for CUDA 12.8 or later (the RTX 50
  series is sm_120). That rules out the T4 (7.5), the V100 (7.0), the P100 (6.0) and, strictly,
  the A100 (8.0). An A100 runs code built for sm_80, so it stays usable if the build adds that
  target; nothing below needs it.
- About 4 GB of GPU memory for the tests, 12 to 16 GB for 200 M, 40 to 50 GB for a billion on one
  card.
- 8 cores, 32 GB of RAM, 60 GB of local disk, Ubuntu 22.04 or 24.04 with `nvcc` or an image we
  choose, root to install Swift 6.2 and ffmpeg.
- SSH from the Mac; the public repository cloned over HTTPS; 3 to 5 GB up and 1 to 5 GB down for
  a big run; tests of 10 to 60 minutes and 200 M stories of 5 to 10 hours, checkpointed every
  hour (#240).

## A cloud coding session cannot open SSH

Tested from this session's container on 2026-11-10:

- There is no `ssh` client in the image.
- A raw TCP connection to github.com port 22 (resolved to 140.82.114.3) is refused at once, as is
  one to the same address by number. `ssh.github.com` does not resolve.
- Outbound traffic goes through an HTTPS proxy (`HTTPS_PROXY` on 127.0.0.1); git remotes written
  `git@github.com:` are rewritten to HTTPS by the session, and hosts outside the environment's
  list do not resolve.

So a cloud session can reach a provider only through its HTTPS API, and only if the
environment's network allows that host; it cannot log into a box. Nothing was tried around the
proxy.

## The market

Who rents NVIDIA GPUs by the hour to a private person in France, in November 2026:

- **Marketplaces of third-party hosts**: Vast.ai, TensorDock. The cheapest consumer cards, from
  private hosts or datacentres, with an interruptible tier at Vast.
- **GPU clouds with consumer and datacentre cards**: RunPod (Community Cloud on third-party hosts,
  Secure Cloud in datacentres), with the 3090, 4090 and 5090 at fixed prices.
- **GPU clouds with datacentre cards only**: Jarvislabs, Hyperstack, Lambda, Thunder Compute,
  DigitalOcean (which absorbed Paperspace).
- **European providers**: Verda (DataCrunch renamed, Finland), Scaleway and OVHcloud (France),
  Hetzner (Germany), Genesis Cloud, Sesterce (Marseille). Datacentre and workstation cards; a 5090
  only at Sesterce, and only on an aggregator.
- **Serverless GPU functions billed by the second**: Modal, RunPod Serverless, Beam. No SSH: a
  job is a container image and a function call over HTTPS.
- **Free tiers**: Colab, Kaggle, Paperspace's free notebooks, SageMaker Studio Lab. None offers a
  GPU of compute capability 8.6 or more.
- **Hyperscalers**: AWS, Google Cloud, Azure. A new account has no GPU quota.

Across 17 providers the median on-demand price of a 5090 was 0.72 $/h on 2026-11-10, from
0.35 $/h on demand and 0.25 $/h interruptible [gd-5090, quoted]. The epic's 0.45 to 0.69 $/h of
9 November sits in that range.

### The shortlist, side by side

| | RunPod | Vast.ai | TensorDock | Verda | Jarvislabs | Hyperstack | Scaleway (quoted) |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kind | GPU cloud, two tiers | marketplace | marketplace of VMs | EU cloud | GPU cloud | GPU cloud | EU cloud |
| RTX 5090 | 0.69 Community, 1.19 Secure [rp-price] | 0.42 cheapest, 0.67 median; verified in Europe 0.65 to 0.87 [va-live] | not listed [td] | not listed [ve-price] | none | none | none |
| RTX 4090 | 0.34 Community, 0.89 Secure | 0.35 cheapest, 0.46 median; verified in Europe 0.42 to 0.54 [va-live] | from 0.35 [td] | none | none | none | none |
| other | 3090 0.22 / 0.50, L40S 0.79 / 1.09, RTX PRO 6000 1.69 / 2.49, A100 PCIe 1.19 / 1.79, H100 PCIe 1.99 / 2.89 | 3090 0.10 cheapest, 0.20 median [va-live] | A100 1.80, H100 2.25 [td] | RTX PRO 6000 2.73, L40S 1.98, A100 80 GB 2.32 [ve-price] | L4 0.44, A100 80 GB 1.49, RTX PRO 6000 2.19 [jl-price] | RTX PRO 6000 1.85, A100 1.35, L40 1.00 [hs-price] | L4 0.75 €, L40S 1.40 €, H100 2.73 € excl. VAT [sw-price] |
| interruptible | none on pods | bid [va-types] | not found | spot, half price | spot (L4 0.29, A100 0.89, PRO 6000 1.15) | spot (PRO 6000 1.48) | none |
| billing | by the second, settled every 5 min [rp-bill] | by the second; storage and bandwidth apart [va-bill] | not documented | prepaid 10-minute steps, unused part refunded [ve-bill] | by the minute [jl-faq] | by the minute [hs-price] | by the minute [sw-faq] |
| deposit | from 10 $, an hour of credit to start a pod [rp-bill] | 5 $ minimum [va-quick] | from 5 $ [td] | prepaid [ve-bill] | prepaid wallet [jl-faq] | not read | none, invoiced after use [sw-pay] |
| balance at zero | pods stopped; without a network volume, terminated [rp-bill] | stopped; a saved card is charged, else destroyed after a grace [va-bill] | not found | instances discontinued, volumes deleted [ve-bill] | paused; data deleted if negative [jl-faq] | hibernated, kept 30 days [hs-hib] | invoiced, alerts cannot block [sw-alert] |
| deadline enforced by the provider | none; a key for the pod alone [rp-env] | none; a key for the instance alone [va-env] | none found | none found | none found | none found | none |
| transfer fees | none [rp-podprice] | per byte, 0 to 0.05 $/GB by host [va-live] | not found | not read | free in region [jl-price] | not read | not read |
| EU | France, Netherlands, Czechia, Romania, Sweden, Iceland [rp-net] | 5090 hosts verified in 11 European countries [va-live] | not found | Finland [ve-cli, quoted] | India only [jl-faq] | not read | Paris, Warsaw [sw-avail] |
| script | `runpodctl`, REST API with remote commands [rp-ctl] [rp-exec] | `vastai`, REST API [va-env] | REST API [td-api] | `verda` CLI and SDK [ve-sdk, quoted] | `jl` CLI, SDK [jl-sdk, quoted] | REST API | `scw` |

Dollars an hour for one GPU, on demand, unless marked; RunPod's pairs are Community / Secure.
Dropped after a first look (quoted, not read), with the reason:

- **OVHcloud**: L40S at 1.40 € an hour, billed by the started hour, and a stopped instance keeps
  billing until it is shelved [ovh-l40s] [ovh-hour] [ovh-stop]; GPU quota depends on the account's
  age and paid invoices [ovh-quota]. No consumer card.
- **Hetzner**: dedicated servers ordered by hand, with a setup fee of 79 € or more and an hour
  rounded up, so a one-hour test costs more than a 200 M run elsewhere [hz-gpu] [hz-131].
- **Genesis Cloud**: whole 8-GPU nodes only [gc]. **Sesterce**: a 5090 at 0.715 $/h according to
  an aggregator, nothing confirmed on its own pages [ss-5090].
- **Lambda**: no consumer card, A100 at 1.99 $/h, a card charged after use with no prepaid
  balance, no stop (only terminate), and a forum thread titled "Credit card declined for people
  living in France" [la-price] [la-bill] [la-inst] [la-fr].
- **Thunder Compute**: no 4090 or 5090, A100 80 GB at 1.09 $/h, but its cheap mode virtualises the
  GPU over the network and is not meant for custom CUDA kernels; servers in Canada [tc-cli]
  [tc-a100] [tc-proto] [tc-spec].
- **DigitalOcean (Paperspace)**: RTX 4000 Ada 0.76 $/h, L40S 1.57 $/h, H100 4.41 $/h, a powered-off
  droplet still bills [do-price] [do-off]; the Paperspace APIs are retired [do-ps].
- **Salad**: 5090 from 0.25 $/h, interruptible, but managed containers with no SSH [salad].
- **Modal and the other serverless offers**: discussed under
  [who drives the box](#who-drives-the-box).
- **The hyperscalers**: AWS starts G instances at a quota of 0 vCPU, raised on request [aws-quota];
  Google Cloud allows no GPU during its free trial [gcp-free]; Azure's GPU families also start at 0
  and free subscriptions are refused [az-nc]. All bill a card after use with no hard cap; an L4
  costs 0.99 to 1.24 $/h in Paris [gcp-g2] [aws-g6] against 0.44 at Jarvislabs, and none has a
  consumer card. Not worth an account for this.
- **Free tiers**: Colab gives a T4 (7.5) [colab], Kaggle a P100 or two T4 with phone verification
  [kaggle], Paperspace's free notebooks an M4000 (5.2) [do-ps]; SageMaker Studio Lab closed to new
  users in July 2026 (third party) [free]. None reaches 8.6, so none runs the code as #283 builds
  it; a correctness test on a T4 would need an sm_75 build and no newer feature. Colab's pay as you
  go gives an L4 for about 0.17 $/h of compute units [colab-payg], a notebook rather than a box.
- **Sign-up credits**: Modal gives 30 $ of compute a month on its free plan [modal-price]; RunPod
  gives a European customer 5 $ only when signing up through someone's referral link [rp-ref];
  Vast.ai, TensorDock and Hyperstack give nothing found. Google's 300 $ trial cannot attach a GPU
  [gcp-free].

### What each one is like to use

**RunPod** [rp-price] [rp-bill] [rp-podprice] [rp-ctl] [rp-manage] [rp-ssh] [rp-env] [rp-net]
[rp-storage]

- Two tiers: Community Cloud on third-party hosts, Secure Cloud in datacentres. A 5090 is 0.69 or
  1.19 $/h, a 4090 0.34 or 0.89, a 3090 0.22 or 0.50. The 5090 offer on the pricing page comes with
  9 vCPUs and 35 GB of RAM, the 4090 with 6 and 41: under the ticket's 8 cores for the 4090, which
  only slows sampling and the video encoding. On 2026-11-09 the Community 5090 was out of stock and
  the Secure one in stock [gd-5090, quoted].
- **SSH**: every pod has a basic SSH proxied through RunPod, with no `scp`, `sftp` or `rsync`. Full
  SSH needs a pod with a public IP and TCP port 22 exposed; a Community pod is not guaranteed one,
  and RunPod's CLI says to use Secure Cloud for SSH [rp-ssh] [rp-ctl]. So Secure, or a Community
  offer showing a public IP.
- Billed by the second for compute and storage, no fee for data going in or out. The balance is
  prepaid and settled every 5 minutes; a pod starts only with an hour of credit for it. One can
  start with 10 $; prepaid cards should deposit 100 $ or more; crypto after an identity check.
  Credits are not refunded. Automatic top-up and a low-balance email are both opt-in. A default
  spend limit of 80 $ an hour applies to every account.
- When the balance reaches zero every pod stops, and a pod without a network volume is terminated
  with its data.
- Storage: the container disk is wiped whenever a pod stops; the volume disk (`/workspace`,
  0.10 $/GB a month running, 0.20 stopped) survives a stop and goes when the pod is terminated; a
  network volume (0.07 $/GB a month) survives everything. A stopped pod releases its GPU and may
  find none when started again [rp-manage].
- No interruptible tier for pods: the pricing pages and pod documentation list on-demand only, and
  savings plans are withdrawn [rp-podprice].
- **No deadline enforced by RunPod**: `runpodctl pod create` has no option for one, nor has the v2
  API's pod [rp-ctl] [rp-api]. (A `--terminate-after` option quoted by the search engine from
  older pages is not in the current reference.) Every pod gets `RUNPOD_POD_ID` and a
  `RUNPOD_API_KEY` documented as "pod-scoped" [rp-env], and RunPod's own example of a scheduled
  stop runs on the pod itself: `sleep 2h; runpodctl pod stop $RUNPOD_POD_ID &` [rp-manage].
- The v2 API also runs one command in a running pod and returns its output and exit code, with no
  SSH [rp-exec].
- Images: RunPod's templates carry CUDA 12.8 with the development tools
  (`runpod/pytorch:2.8.0-py3.11-cuda12.8.1-cudnn-devel-ubuntu...`) [rp-tpl], and its official
  templates come with full SSH configured; a custom image (say
  `nvidia/cuda:12.8.1-devel-ubuntu24.04`) has to start `sshd` itself [rp-ssh].
- Data centres in France (EU-FR-1), the Netherlands, Czechia, Romania, Sweden and Iceland.

**Vast.ai** [va-bill] [va-quick] [va-types] [va-sec] [va-env] [va-boot] [va-5series] [va-live]

- A marketplace: each offer is one host's machine at its own price, reliability and bandwidth. Of
  the first 64 on-demand single 5090s offered at 20:45 UTC on 2026-11-10, the cheapest was
  0.42 $/h and the median 0.67; keeping hosts verified by Vast, in Europe, with 8 cores, 32 GB,
  CUDA 12.8 and a reliability of 0.98 or more left 17, from 0.65 $/h, median 0.87, in 11
  countries. A 4090 the same way: 0.35 and 0.46, verified in Europe 0.42 and 0.54; a 3090: 0.10
  and 0.20 [va-live].
- Billed by the second while running; storage (0.20 $/GB a month at the median host) for every
  second the instance exists, stopped or not; bandwidth by the byte, up and down, from free to
  0.05 $/GB depending on the host. 5 $ minimum deposit, by card or crypto; only a verified email.
- At zero balance instances stop. With a card saved, Vast charges it automatically to cover the
  negative balance; without one, instances and data are destroyed after a grace period that grows
  with the account's history [va-bill]. So on Vast, no saved card.
- On-demand instances show a maximum duration set by the host; interruptible ones are bids, paused
  by a higher bid or an on-demand rental [va-types].
- Each instance has `CONTAINER_ID` and `CONTAINER_API_KEY`, a key for that instance alone, with
  which it can stop or destroy itself [va-env]. No deadline enforced by Vast.
- Boot in 1 to 5 minutes depending on the image [va-boot]; for a 5090, templates on CUDA 12.8 or
  later [va-5series].
- Containers are unprivileged and isolated; individual hosts "may have less formal security
  measures" than its tier 4 datacentres [va-sec].

**TensorDock** [td] [td-api]: virtual machines from hosts, a 4090 from 0.35 $/h, an A100 from
1.80, an H100 from 2.25, "start with just 5 $"; no 5090 on its page; its billing API is "coming
soon", and its billing rules, regions and deadlines were not found.

**Verda** [ve-price] [ve-bill]: a Finnish cloud, prepaid in 10-minute steps with the unused part
refunded; when the balance reaches zero instances are discontinued and volumes deleted, a hard cap
but a brutal one. An RTX PRO 6000 (96 GB) at 2.73 $/h on demand, 1.36 on spot; an L40S at 1.98 or
0.99; no 4090 or 5090. (Search quotes of 1.39 and 1.89 $/h for the PRO 6000 are not on its pages
today.)

**Jarvislabs** [jl-price] [jl-faq]: by the minute, L4 at 0.44 $/h (0.29 spot), A100 80 GB at 1.49
(0.89), RTX PRO 6000 at 2.19 (1.15); paused at zero balance, data deleted if it goes negative. Its
FAQ puts every server in India; no 4090 or 5090 today.

**Hyperstack** [hs-price] [hs-states] [hs-hib]: by the minute, an RTX PRO 6000 at 1.85 $/h (1.48
spot), an A100 80 GB at 1.35, an L40 at 1.00; a stopped VM keeps billing at the full rate, only
hibernation or deletion stops it; below zero every VM is hibernated and kept 30 days.

**Scaleway** (quoted) [sw-price] [sw-faq] [sw-quota] [sw-pay] [sw-alert] [sw-avail]: French, by
the minute, L4 at 0.75 €, L40S at 1.40 €, H100 at 2.73 € an hour excluding VAT, in Paris and
Warsaw.
GPU quota needs an identity check, prepaid and virtual cards are refused, the bill comes after use,
and billing alerts cannot block spending. No consumer card.

## Renting, step by step, on RunPod

What a session looks like the first time, for #283 to turn into `scripts/gpu-box.sh`. Commands
follow RunPod's current reference [rp-ctl] [rp-manage] [rp-ssh]; their flags are checked with
`--help` on the day.

1. **The account and its credit.** Pierre creates the account, adds 10 $ by card, leaves automatic
   top-up off and turns the low-balance email on. Nothing can cost more than what is on the balance.
2. **The SSH key.** On the Mac, a key for this alone: `ssh-keygen -t ed25519 -f
   ~/.ssh/sillage_gpu`. The public half (`sillage_gpu.pub`) goes into RunPod's settings, which put
   every key of the account into every pod; the private half never leaves the Mac.
3. **The API key**, created in RunPod's settings, kept on the Mac in `~/.config/sillage/gpu.env`
   (`RUNPOD_API_KEY=...`, mode 600), read by the scripts and by `runpodctl`. Never in the
   repository, never on a box.
4. **Choosing the GPU, the offer and the image.** A 4090 or 5090 on Secure Cloud (`--cloud-type
   SECURE`, a public IP for `rsync`), in France when it has one free (`--data-center-ids
   EU-FR-1`, or `--country-code`); RunPod's PyTorch template on CUDA 12.8 (devel, full SSH
   ready) or a CUDA 12.8 devel image that starts `sshd`; a container disk of 20 GB and a volume of
   60 GB on `/workspace`; `--ports 22/tcp`.
5. **Booting.** `runpodctl pod create ...`. Billing starts now. `runpodctl pod get <id>` gives the
   public address and the external port mapped to 22.
6. **The watchdog, first thing.** `ssh` in and start, detached, `sleep 10h` followed by the pod's
   own deletion with the key RunPod put in it (`DELETE https://api.runpod.io/v2/pods/$RUNPOD_POD_ID`,
   `Authorization: Bearer $RUNPOD_API_KEY`), the time set by the script to about 1.5 times the
   estimate. #283 first checks on a throwaway pod that this key deletes its own pod and nothing
   else.
7. **The code and the data.** `git clone https://github.com/pierregc/sillage` (public, no token);
   the scene folder and its massive take go up from the Mac with `rsync -aP -e 'ssh -p <port>'` to
   `/workspace`. 3 to 5 GB take 7 minutes at 100 Mbit/s up, half an hour at 20.
8. **Building there.** `apt-get install ffmpeg`, Swift 6.2 for Ubuntu from swift.org next to the
   image's `nvcc`, then the Linux build of #272 and #278 (`scripts/linux.sh`). Ten to fifteen
   minutes the first time, paid at the GPU's price; anything installed outside `/workspace` is lost
   if the pod stops.
9. **Running a long job.** In `tmux new -s run` (or under `nohup`, its output in a log), so that
   closing the laptop or losing Wi-Fi does not stop it. Detach with `ctrl-b d`.
10. **Watching.** `ssh` again, `tmux attach -t run` or `tail -f` the log, `nvidia-smi` for the
    GPU; `runpodctl user` shows the balance and the spend an hour.
11. **Fetching.** `rsync -aP` the videos, key frames, reports and logs back to the Mac.
12. **Destroying.** `runpodctl pod delete <id>`, then `runpodctl pod list` until the pod is gone
    ("not found" is the reliable sign, RunPod says), and a line in `docs/notes/gpu-ledger.md`.
    Stopping is not enough: a stopped pod still pays for its volume.

**An interruption.** RunPod's pods are not interruptible. A host can still fail; and on Vast an
interruptible bid is paused when outbid, its processes killed and its disk kept [va-types]. A full
pass writes a checkpoint every hour (#240), 6.5 GB at 200 M, so with checkpoints on `/workspace` a
run loses at most an hour and resumes with `hires --resume` once the box runs again. For #279 an
interruptible offer's saving is not worth the uncertainty, so it runs on demand.

## Never paying for a forgotten box

What stops billing, and what bounds the worst case:

| | stops billing | deadline the provider enforces | at zero balance | limits and alerts |
| --- | --- | --- | --- | --- |
| RunPod | deleting; a stopped pod pays for its volume | none; the pod can delete itself with its own key | pods stopped, terminated without a network volume | prepaid, low-balance email, 80 $/h spend limit |
| Vast.ai | destroying; a stopped instance pays for storage | none; the instance can destroy itself with its own key | stopped; a saved card charged, else destroyed | prepaid, low-balance email |
| Verda | deleting | none found | discontinued, volumes deleted | prepaid, top-up optional |
| Jarvislabs | deleting; a paused one pays for storage | none found | paused, data deleted if negative | prepaid |
| Hyperstack | deleting or hibernating; a stopped VM pays in full | none found | hibernated 30 days | prepaid |
| Scaleway (quoted) | deleting; powered off pays for storage | none | invoiced | alerts only, cannot block |
| Modal | the function returning or its timeout | a timeout of up to 24 h on every function [modal-to] | stops at the budget | workspace and environment budgets [modal-budget] |

Only the serverless offers enforce a time limit themselves. The setup recommended, so that the
worst case is bounded twice:

- **A small prepaid balance, no automatic top-up, and on Vast no saved card.** 10 $ on RunPod:
  whatever goes wrong, that is the most it can cost, and RunPod terminates every pod without a
  network volume when it runs out.
- **A watchdog on every box**, started by `scripts/gpu-box.sh` before anything else: after about
  1.5 times the estimate it deletes the box with the key the provider gave that box alone, never
  with Pierre's key. If the Mac sleeps, the session dies or the script crashes, the box goes
  anyway. If the watchdog itself fails, the balance is the bound.
- **The script always ends by deleting the box and listing what is left**, and every session goes
  in the ledger.

## Who drives the box

| | needs | risks | for |
| --- | --- | --- | --- |
| a coding session on the Mac over SSH | the Mac on to start and to fetch, the SSH key and API key on the Mac | the Mac asleep at the wrong time, covered by the watchdog | **bring-up and big runs** |
| a cloud coding session over an HTTPS API | the provider's API key as a network secret of the cloud environment, the provider's API host allowed | inputs live on the Mac, so only runs needing nothing but the repository; long outputs need a store | later, correctness checks on NVIDIA |
| Pierre by hand in the console | nothing more | forgetting to delete, covered by the watchdog | a first look, if he wants to learn |

The Mac is the natural driver: the scene and the massive take are made there, the videos come back
there, and the SSH session costs it nothing while the job runs in `tmux`; the Mac only has to be
on when the box starts and when the results come back, and the watchdog covers the time between.

A cloud session cannot use SSH (above), but RunPod's v2 API lets it do everything else over
HTTPS: create a pod [rp-api], run a command in it and read its output [rp-exec], delete it. With
`api.runpod.io` allowed and the key saved as a network secret of the environment (the proxy adds
it to the requests; the session never sees it), a cloud session could clone, build and run the
reference checks of #281 on a real NVIDIA card with no Mac at all. The other routes are RunPod
Serverless (`POST .../run`, `GET .../status`, a worker image built and pushed to a registry first)
[rp-sls] and Modal, where a function runs in any image (an `nvidia/cuda` devel image plus Swift)
for up to 24 hours, billed by the second, with 30 $ of free compute a month and a budget that
stops it [modal-price] [modal-to] [modal-cuda] [modal-budget]; Modal's cheapest suitable cards are
an L4 (8.9) at 0.80 $/h and an A10 (8.6) at 1.10 $/h, no 4090 or 5090, and its SDK talks gRPC,
untested through this proxy. Worth it once the engine changes often enough that checking it on
NVIDIA from a cloud session pays; not for #283, which has to time the run's card and send data.

## What the runs would take on each GPU

**The reference.** On the M4 Max a light tracer step costs 21.0 ns on 2 M massive (#238, #241) and
the walk through the massive tree is nearly all of it, 2.06 s of a 2.21 s step at 100 M, latency
bound at 5 to 15 % of the arithmetic peak ([solver-language](solver-language.md)). The ticket's
200 M story, 15 500 steps of 198 M tracers, is then:

- the walk, 15 500 × 198 M × 21.0 ns = 17.9 h;
- the massive part (5 M walkers with the halo), 0.11 to 0.16 s a step, about 0.6 h;
- 923 frames drawn in 4K and vertical, 1.70 s a 4K frame at 200 M ([200m-preview](200m-preview.md)),
  about 0.9 h;

about **19.4 h of M4 Max**, the epic's 19 h. A rented box adds about half an hour that does not
shrink with the GPU: booting, building, sending 3 to 5 GB, sampling (1.5 µs a particle, 5 minutes)
and fetching. The video is encoded on the box's CPU alongside.

**The speed of each GPU against the M4 Max on that walk** is estimated, not measured. What it rests
on, in order of weight:

- **Blender Cycles**, the closest public workload: a path tracer is a tree walk with divergent
  threads, bound by latency like ours. Median Open Data scores, Blender 4.3, against the M4 Max's
  32-core GPU (4 334, 34 runs, Metal) [blender]: through OptiX, RTX 3090 1.23, RTX 4090 2.52,
  RTX 5090 3.44, RTX 5080 2.08, L40S 2.03, H100 1.39 (two runs), A100 0.85 (one run), L4 0.23. But
  OptiX and Metal both use ray tracing hardware (the M4 Max's since Blender 4.0) and Sillage's
  walk uses none. Through plain CUDA, without it, the cards that have it lose about 30 % (3090 at
  0.86, 5080 at 1.41, one run each), while the H100, which has none, scores 1.62 and a B200 1.93.
  If the M4 Max gains as much from its own hardware, the OptiX ratios stand; if it gains nothing,
  the RTX cards are 30 % lower. The range below spans both.
- **Memory bandwidth** against the M4 Max's 410 GB/s [m4max, quoted]: 3090 2.3x, 4090 2.5x, L40S
  2.1x, 5090 and RTX PRO 6000 4.4x, A100 3.8 to 5x, H100 5 to 8x, L4 0.7x [tpu-5090, quoted]
  [hw-specs, quoted].
- **Caches**: the tree (5 M bodies, a few hundred MB) fits no L2, but the upper levels every walk
  crosses do in the 4090's 72 MB, the L40S's and 5090's 96 MB and the PRO 6000's 128 MB, and not in
  the 3090's 6 MB. Blackwell's L2 answers in just over 130 ns against 107 on Ada, and the RTX PRO
  6000's memory in 329 ns [cc-bw] [cc-4090], which is why the 5090 is put below its bandwidth
  ratio. The M4 Max's own latencies are not published; the M2 Pro's GPU waits 234 ns at its system
  cache [cc-m2].
- **Arithmetic** last: at 5 to 15 % of peak, the 5090's 7.7 times the M4 Max's 13.6 TFLOPS is not
  what limits it.

The epic put the 5090 at about 4x (3 to 6) and the A100 at 1.3x; the numbers below are a little
lower for Blackwell and higher for the A100 and H100, for the reasons above, and much lower for the
L4. Each is good to about a factor 1.5 either way; #283 measures it in its first hour on each card.

| GPU | memory | speed (range) | 200 M story | $/h seen | 200 M cost | holds 200 M | holds 1 G |
| --- | ---: | --- | ---: | --- | ---: | :---: | :---: |
| M4 Max | unified | 1 | 19.4 h | | | yes | with 64 GB or more |
| RTX 3090 | 24 GB | 1.2 (0.9 to 2.0) | 16.7 h (10 to 22) | 0.20 Vast median, 0.22 / 0.50 RunPod | 3 to 8 $ | yes | no |
| RTX 4090 | 24 GB | 2.5 (1.8 to 3.5) | 8.3 h (6 to 11) | 0.46 Vast median, 0.34 / 0.89 RunPod | 3.8 $ Vast, 7.4 $ (5 to 10) Secure | yes | no |
| RTX 5080 | 16 GB | 2.0 (1.4 to 3.0) | | rarely offered | | no margin | no |
| RTX 5090 | 32 GB | 3.5 (2.5 to 5.0) | 6.0 h (4.4 to 8.3) | 0.87 Vast verified Europe, 0.69 / 1.19 RunPod | 5.2 $ Vast, 7.1 $ (5 to 10) Secure | yes | no |
| RTX PRO 6000 | 96 GB | 3.7 (2.5 to 5.0) | 5.7 h (4.4 to 8.3) | 1.69 / 2.49 RunPod, 1.85 Hyperstack, 2.73 Verda | 10 to 16 $ | yes | yes |
| L40S | 48 GB | 2.0 (1.4 to 3.0) | 10.2 h (7 to 14) | 0.79 / 1.09 RunPod, 1.40 € Scaleway | 8 to 11 $ | yes | barely |
| A100 80 GB (sm_80) | 80 GB | 1.5 (0.9 to 2.5) | 13.4 h (8 to 22) | 1.19 / 1.79 RunPod, 1.35 Hyperstack | 16 to 24 $ | yes | yes |
| H100 | 80 GB | 2.0 (1.4 to 3.0) | 10.2 h (7 to 14) | 1.99 / 2.89 RunPod PCIe | 20 to 30 $ | yes | yes |
| L4 | 24 GB | 0.4 (0.25 to 0.8) | 49 h | 0.44 RunPod, Jarvislabs | 22 $ and more | yes | no |

The time is 19.4 h divided by the speed, plus half an hour; the cost, that time at the price seen.
Memory follows the epic: 12 to 16 GB at 200 M (36 bytes a tracer, the massive particles and their
tree, the renderer's targets), 40 to 50 GB at a billion.

**Reading it.** Per run the 4090 is the cheapest card that holds 200 M (about 4 $ on Vast, 8 h),
the 5090 the fastest at a price close to it (about 5 $ in 6 h on Vast, 7 $ on RunPod's Secure
Cloud). Datacentre cards cost two to six times more for the same story: their bandwidth and big
caches do not pay on a walk this latency bound. A whole story on 2 M massive at its own step
(8 480 steps, about 11 h on the M4 Max, [200m-preview](200m-preview.md)) costs a little over half
of all this.

**A billion stars** (990 M tracers, the same 15 500 steps): the walk is 89.5 h of M4 Max, the
frames 4.3 h (8.4 s a 4K frame at a billion), about 94 h in all. On one RTX PRO 6000 (96 GB) about
26 h: 45 $ on RunPod's Community Cloud, 36 $ on Verda's spot. On four 5090s with the tracers split
between them (#280), 32 GB each, about 7 to 8 h: 27 $ on Vast, 37 $ on RunPod's Secure Cloud. On
four 4090s, 10 to 11 h and about 19 $ on Vast. Beyond phase 2's 20 € in every case, so #280 waits
for Pierre's go and a cap he sets, as the epic says.

## The recommendation

- **Provider: RunPod, on its Secure Cloud.** Fixed prices for both the 4090 and the 5090,
  datacentres in France and five other European countries, a public IP for SSH and `rsync`, no fee
  on transfers, billing by the second on a prepaid balance that terminates every pod when it runs
  out, a key that lets a pod delete itself, a CLI and an HTTPS API that also runs commands in a
  pod. It costs a third more than Vast's verified hosts, the price of a simpler first time.
- **#283, bring-up and timings: an RTX 4090** (0.89 $/h) for building and the correctness checks
  against the reference outputs, two to three hours; then **an hour on a 5090** (1.19 $/h) and an
  hour on the 4090 timing the same steps, to choose the run's card on the measured cost of a step
  rather than on the table above. About 5 $ in all.
- **#279, the first 200 M run: an RTX 5090** on Secure Cloud at 1.19 $/h (or a Community one at
  0.69 $/h showing a public IP), on demand: about 6 h and 7 $ (5 to 10) by the estimate, watchdog
  at 10 h. If #283 finds the 4090 cheaper per run by more than the time it costs, the 4090.
- **Fallback, no 5090 free on RunPod, and the cheaper route for later runs: Vast.ai**, on-demand,
  a host verified by Vast in Europe with a high reliability score, a 5090 at 0.65 to 0.87 $/h:
  about 5 $ a 200 M run. 5 $ of credit, no saved card, and the watchdog with the instance's own
  key.
- **Budget**: about 5 $ for #283 and 5 to 10 $ for #279, 10 to 15 $ in all: 9 to 13 €, 11 to 16 €
  if VAT is added, inside phase 2's 20 € unless the estimates are off by more than half, which
  #283 shows before #279 spends anything. The first 10 $ of credit cover #283; what is left is
  topped up before #279 as far as the run's watchdog needs (10 h at 1.19 $).

## What Pierre does on the day he decides to rent

Nothing of this now.

1. Create the RunPod account, with an email and a card.
2. Put 10 $ of credit on it, with automatic top-up off and the low-balance email on.
3. On the Mac, `ssh-keygen -t ed25519 -f ~/.ssh/sillage_gpu`, and paste the public key
   (`~/.ssh/sillage_gpu.pub`) into RunPod's settings.
4. Create an API key in RunPod's settings and put it in `~/.config/sillage/gpu.env` as
   `RUNPOD_API_KEY=...`, then `chmod 600 ~/.config/sillage/gpu.env`. Not in the repository, not in
   an issue or a PR, never on a box.
5. Tell the session running #283 that the account is ready.

## Sources

Read on the page on 2026-11-10 unless marked *quoted*, in which case through a search engine's
quotes of it, the same day.

- [rp-price] RunPod pricing, https://www.runpod.io/pricing
- [rp-bill] RunPod billing, https://docs.runpod.io/accounts-billing/billing
- [rp-podprice] RunPod pod pricing and storage, https://docs.runpod.io/pods/pricing
- [rp-ctl] `runpodctl pod`, https://docs.runpod.io/runpodctl/reference/runpodctl-pod
- [rp-manage] RunPod, managing pods, https://docs.runpod.io/pods/manage-pods
- [rp-ssh] RunPod, SSH, https://docs.runpod.io/pods/configuration/use-ssh
- [rp-env] RunPod, a pod's environment variables, https://docs.runpod.io/pods/templates/environment-variables
- [rp-api] RunPod REST API v2, creating a pod, https://docs.runpod.io/api-reference-v2/pods/create-a-pod
- [rp-exec] RunPod REST API v2, running a command in a pod,
  https://docs.runpod.io/api-reference-v2/pods/run-a-command-in-a-pod
- [rp-net] RunPod data centres, https://docs.runpod.io/pods/networking
- [rp-storage] RunPod storage guide, https://www.runpod.io/blog/where-did-my-files-go-a-straight-guide-to-runpod-storage
- [rp-tpl] RunPod, PyTorch 2.8 with CUDA 12.8, https://www.runpod.io/articles/guides/pytorch-2-8-cuda-12-8
- [rp-ref] RunPod referrals, https://docs.runpod.io/references/referrals
- [rp-sls] RunPod Serverless pricing, https://docs.runpod.io/serverless/pricing
- [gd-5090] getdeploying, RTX 5090 across providers, stock checked 2026-11-09 (third party,
  quoted), https://getdeploying.com/gpus/nvidia-rtx-5090
- [va-live] Vast.ai offers, public search behind the console, on-demand single 5090, 4090 and 3090
  around 20:45 UTC, https://console.vast.ai/api/v0/bundles/
- [va-bill] Vast.ai billing, https://docs.vast.ai/guides/reference/billing
- [va-quick] Vast.ai quickstart, https://docs.vast.ai/guides/get-started/quickstart
- [va-types] Vast.ai instance types, https://docs.vast.ai/documentation/instances/choosing/instance-types
- [va-sec] Vast.ai security, https://docs.vast.ai/guides/reference/faq/security
- [va-env] Vast.ai container environment, https://docs.vast.ai/guides/instances/docker-environment
- [va-boot] Vast.ai CLI first steps, https://docs.vast.ai/cli/hello-world
- [va-5series] Vast.ai RTX 50 series, https://docs.vast.ai/rtx-5-series
- [td] TensorDock, https://www.tensordock.com/
- [td-api] TensorDock API, https://dashboard.tensordock.com/api/docs/billing
- [ve-price] Verda pricing, https://verda.com/pricing and https://verda.com/rtx-pro-6000
- [ve-bill] Verda pricing and billing, https://docs.verda.com/welcome-to-verda/pricing-and-billing
- [ve-cli] Verda CLI (quoted), https://docs.verda.com/cli/instances/
- [ve-sdk] Verda SDK (quoted), https://pypi.org/project/verda/
- [jl-price] Jarvislabs pricing, https://jarvislabs.ai/pricing
- [jl-faq] Jarvislabs FAQ, https://docs.jarvislabs.ai/faqs/
- [jl-sdk] Jarvislabs SDK (quoted), https://docs.jarvislabs.ai/sdk
- [hs-price] Hyperstack pricing, https://www.hyperstack.cloud/gpu-pricing
- [hs-states] Hyperstack billing by state, https://docs.hyperstack.cloud/docs/billing/states-and-billing/
- [hs-hib] Hyperstack hibernation, https://docs.hyperstack.cloud/docs/virtual-machines/hibernation/
- [sw-price] Scaleway GPU pricing (quoted), https://www.scaleway.com/en/pricing/gpu
- [sw-faq] Scaleway instances FAQ (quoted), https://www.scaleway.com/en/docs/instances/faq/
- [sw-quota] Scaleway quotas (quoted), https://www.scaleway.com/en/docs/organizations-and-projects/organization/organization-quotas/
- [sw-pay] Scaleway payment methods (quoted), https://www.scaleway.com/en/docs/billing/how-to/add-payment-method/
- [sw-alert] Scaleway billing alerts (quoted), https://www.scaleway.com/en/docs/billing/how-to/use-billing-alerts/
- [sw-avail] Scaleway availability (quoted), https://scaleway.com/en/docs/account/reference-content/products-availability
- [ovh-l40s] OVHcloud community, L40S billed 1.40 €/h (July 2026, quoted),
  https://community.ovhcloud.com/t/facturation-gpu-l40s-incoherente-2-287-pour-une-instance-de-9-jours-1-40-h/53656
- [ovh-hour] OVHcloud hourly billing (quoted), https://support.us.ovhcloud.com/hc/en-us/articles/22179651508115
- [ovh-stop] OVHcloud billing of instances (quoted), https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/analyze-billing
- [ovh-quota] OVHcloud quota (quoted), https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/increasing-public-cloud-quota
- [hz-gpu] Hetzner GPU servers (quoted), https://www.hetzner.com/gpu and
  https://docs.hetzner.com/general/billing-and-account-management/billing-at-hetzner/billing-system-hetzner/
- [hz-131] Hetzner GEX131 (quoted), https://www.hetzner.com/pressroom/new-gex131/
- [gc] Genesis Cloud (third party, quoted), https://www.spheron.network/blog/genesis-cloud-pricing-2026-eu-h100-cost/
- [ss-5090] Sesterce (third party, August 2026, quoted), https://computeprices.com/providers/sesterce/gpus/rtx5090
- [la-price] Lambda (third party, October 2026, quoted), https://checkthat.ai/brands/lambda/pricing
- [la-bill] Lambda billing (quoted), https://docs.lambda.ai/public-cloud/billing/
- [la-inst] Lambda instances (quoted), https://docs.lambda.ai/public-cloud/on-demand/creating-managing-instances/
- [la-fr] Lambda forum (quoted), https://deeptalk.lambda.ai/t/credit-card-declined-for-people-living-in-france/2286
- [tc-cli] Thunder Compute CLI (quoted), https://www.thundercompute.com/docs/cli-reference
- [tc-a100] Thunder Compute (quoted), https://www.thundercompute.com/blog/cheapest-cloud-gpu-providers
- [tc-proto] Thunder Compute prototyping mode (quoted), https://www.thundercompute.com/docs/prototyping-mode
- [tc-spec] Thunder Compute specs (quoted), https://www.thundercompute.com/docs/technical-specs
- [do-price] DigitalOcean GPU droplets (quoted), https://www.digitalocean.com/pricing/gpu-droplets
- [do-off] DigitalOcean powered-off droplets (third party, quoted), https://www.aquanode.io/blog/digitalocean-gpu-droplets
- [do-ps] Paperspace (quoted), https://docs.digitalocean.com/products/paperspace
- [salad] Salad prices (September 2026, quoted), https://blog.salad.com/saladcloud-price-changes-september-2026/
- [aws-quota] AWS EC2 quotas (quoted), https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html
- [aws-g6] AWS g6.2xlarge in Paris (third party, quoted), https://www.doit.com/compute/spot/eu-west-3/g6.2xlarge
- [gcp-free] Google Cloud free trial (quoted), https://docs.cloud.google.com/free/docs/free-cloud-features
- [gcp-g2] Google Cloud g2-standard-8 in Paris (third party, quoted), https://calculator.holori.com/gcp/vm/g2-standard-8/europe-west9
- [az-nc] Azure NC family (quoted), https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/nc-family
  and https://learn.microsoft.com/en-us/answers/questions/1616602/free-credits-do-not-allow-launching-gpu-accelerate
- [modal-price] Modal pricing and plans, https://modal.com/pricing
- [modal-to] Modal timeouts, https://modal.com/docs/guide/timeouts
- [modal-cuda] Modal CUDA images, https://modal.com/docs/guide/cuda
- [modal-budget] Modal budgets, https://modal.com/docs/guide/budgets
- [colab] Colab free tier (third party, quoted), https://www.hivenet.com/post/google-colaboratory-gpu-complete-guide-to-free-cloud-gpu-access-and-limitations
- [colab-payg] Colab compute units (third party, March 2026, quoted), https://mccormickml.com/2024/04/23/colab-gpus-features-and-pricing/
- [kaggle] Kaggle GPUs (third party, quoted), https://research.aimultiple.com/free-cloud-gpu
- [free] Free GPUs and credits (third party, quoted), https://gpuperhour.com/blog/free-cloud-gpus-and-credits
- [blender] Blender Open Data, Blender 4.3.0, medians by device for OptiX, CUDA and Metal, read
  through the data behind
  https://opendata.blender.org/benchmarks/query/?compute_type=OPTIX&blender_version=4.3.0&group_by=device_name
  (and `compute_type=CUDA`, `compute_type=METAL`)
- [m4max] M4 Max with a 32-core GPU, 410 GB/s (quoted), https://lowendmac.com/1234/apple-silicon-m4-max-chip-specs/
- [tpu-5090] RTX 5090 (quoted), https://www.techpowerup.com/gpu-specs/geforce-rtx-5090.c4216
- [hw-specs] GPU specifications (quoted): L40S, https://www.supermicro.com/datasheet/datasheet_NVIDIA_L40S_Systems.pdf;
  H100, https://www.thundercompute.com/blog/nvidia-h100-specs-full-guide; RTX PRO 6000,
  https://www.techpowerup.com/gpu-specs/rtx-pro-6000-blackwell.c4272; A100 and GA102,
  https://images.nvidia.com/aem-dam/en-zz/Solutions/data-center/nvidia-ampere-architecture-whitepaper.pdf
- [cc-bw] Chips and Cheese, Blackwell (RTX PRO 6000), https://chipsandcheese.com/p/blackwell-nvidias-massive-gpu
- [cc-4090] Chips and Cheese, RTX 4090, https://chipsandcheese.com/p/microbenchmarking-nvidias-rtx-4090
- [cc-m2] Chips and Cheese, M2 Pro GPU, https://chipsandcheese.com/p/a-brief-look-at-apples-m2-pro-igpu
- [fx] EUR to USD on 2026-10-11 (quoted), https://30rates.com/eur-usd-forecast-tomorrow-this-week
