# Renting an NVIDIA GPU for the big runs (#270)

Step 1 of epic #269, phase 1: a survey on paper, read on 2026-11-10, with no account created and
nothing rented. It prepares phase 2: #283 brings the CUDA engine up on a rented GPU and times it,
#279 runs 200 M there, #280 spreads a billion over several cards. Phase 2 starts only when Pierre
says so.

**In short.** RunPod, from the Mac over SSH. #283 checks correctness on a Community RTX 4090
(0.34 $/h) and times a 5090 for an hour; #279 runs on an RTX 5090 (0.69 $/h Community when one is
free, 1.19 $/h Secure otherwise), about 6 h and 4 to 7 $ for a 200 M story by the estimates below,
unless #283 measures the 4090 cheaper per run. Vast.ai's datacentre offers are the fallback. Every
box is created with a deadline RunPod enforces (`--terminate-after`), on a prepaid balance of 10 $
with no automatic top-up, so a forgotten box costs at most its deadline and never more than the
balance. Bring-up and the first 200 M run fit in phase 2's 20 €.

## How this was read

Every price and rule below was read on 2026-11-10 through a web search engine, which quotes the
pages it cites. The cloud session that wrote this note cannot open the providers' own pages: its
network allows HTTPS through a proxy to a list of hosts, and www.runpod.io, docs.runpod.io,
docs.vast.ai, console.vast.ai, modal.com, www.scaleway.com, www.ovhcloud.com, www.hetzner.com,
opendata.blender.org and chipsandcheese.com are not on it. So each fact carries the page the
search engine quoted it from (the keys in brackets, listed under [Sources](#sources)); a page marked
*third party* is an aggregator, not the provider. Where two pages disagree both are given. #283
reads the price again on the day it rents: on a marketplace it moves by the hour.

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
  private hosts or datacentres, with an interruptible tier.
- **GPU clouds with consumer and datacentre cards**: RunPod (Community Cloud on third-party hosts,
  Secure Cloud in datacentres). RTX 5090 and 4090 at fixed prices.
- **GPU clouds with datacentre cards only**: Lambda, Hyperstack, Jarvislabs, Thunder Compute,
  DigitalOcean (which absorbed Paperspace). No 4090 or 5090, except Jarvislabs's 4090.
- **European providers**: Verda (DataCrunch renamed, Finland), Scaleway and OVHcloud (France),
  Hetzner (Germany), Genesis Cloud, Sesterce (Marseille). Datacentre and workstation cards, an
  RTX PRO 6000 at Verda, Scaleway and Hetzner; a 5090 only at Sesterce, by an aggregator alone.
- **Serverless GPU functions billed by the second**: Modal, RunPod Serverless, Beam. No SSH: a
  job is a container image and a function call over HTTPS.
- **Free tiers**: Colab, Kaggle, Paperspace's free notebooks, SageMaker Studio Lab. None offers a
  GPU of compute capability 8.6 or more.
- **Hyperscalers**: AWS, Google Cloud, Azure. A new account has no GPU quota.

Across 17 providers the median on-demand price of a 5090 was 0.72 $/h on 2026-11-10, from
0.35 $/h on demand and 0.25 $/h interruptible [gd-5090]; another tracker puts the median at
0.64 $/h over 15 [beam-5090]. The epic's 0.45 to 0.69 $/h of 9 November sits in that range.

### The shortlist, side by side

| | RunPod | Vast.ai | TensorDock | Verda | Scaleway | Jarvislabs | Hyperstack |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kind | GPU cloud, two tiers | marketplace | marketplace of VMs | EU cloud | EU cloud | GPU cloud | GPU cloud |
| RTX 5090 | 0.69 Community, 1.19 Secure [rp-5090] | 0.43 to 0.53 cheapest, 0.86 median [va-5090] | not reliable [td] | 1.04, third party only [gd-5090v] | none | none | none |
| RTX 4090 | 0.34 Community, 0.89 Secure [rp-price] | 0.20 to 0.52, 0.48 median [va-4090] | from 0.35 [td] | none | none | about 0.59, old page [jl-4090] | none |
| other | L40S 0.79 / 1.09, A100 PCIe 1.19 / 1.79, H100 PCIe 1.99 / 2.89 [rp-price] [gd-rp] | 3090 from 0.11 [va-3090] | H100 2.25 [td-h100] | RTX PRO 6000 1.39 or 1.89, spot about 0.7 to 1.0 [ve-pro] | L4 0.75 €, L40S 1.40 €, H100 2.73 € excl. VAT [sw-price] | L4 0.44, A100 80 GB 1.49, RTX PRO 6000 2.19 [jl-price] | RTX PRO 6000 1.80, A100 1.35 [hs-price] |
| interruptible | spot, no table found | bid, about half price | bid, from about half | spot | none | spot (L4 0.29, A100 0.89) | spot (PRO 6000 about 1.45) |
| billing | by the second [rp-bill] | by the second [va-bill] | by the second [td-bill] | every 10 minutes [ve-bill] | by the minute [sw-faq] | by the minute [jl-faq] | unclear |
| deposit | 10 $ minimum, an hour of credit to start [rp-bill] [rp-podprice] | 5 $ minimum [va-quick] | 5 $ minimum [td] | prepaid, minimum not found [ve-bill] | none, monthly invoice after use [sw-pay] | prepaid, minimum not found | 5 $ minimum [hs-pay] |
| balance at zero | pods stopped; without a network volume, terminated [rp-bill] | stopped, storage still billed, a saved card charged ("auto-debt") [va-bill] | deleted (third party) [td-zero] | instances discontinued, volumes deleted after 96 h [ve-bill] | invoiced, no cap [sw-alert] | paused, data deleted if negative [jl-faq] | hibernated 30 days [hs-hib] |
| deadline enforced by the provider | `--terminate-after` at creation [rp-ctl] | none found; the box can destroy itself [va-env] | none found | none found | none | none found | none found |
| EU | Romania, Sweden, Iceland, more announced [rp-net] | 5090 hosts in ES, FI, PL, CZ, FR and others [va-eu] | not found | Finland [ve-cli] | Paris, Warsaw [sw-avail] | Finland (third party) | Norway (not verified) |
| script | `runpodctl`, REST API [rp-ctl] [rp-api] | `vastai`, REST API [va-cli] | REST API [td-api] | `verda` CLI and SDK [ve-sdk] | `scw` | `jl` CLI, SDK [jl-sdk] | REST API |

Prices are dollars an hour for one GPU unless marked in euros. Dropped after a first look, with the
reason:

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
- **Sign-up credits**: RunPod gives a European customer 5 $ once 10 $ are spent [rp-ref]; Modal
  gives 30 $ of compute a month on its free plan [modal-free]; Vast.ai, TensorDock and Hyperstack
  give nothing found. Google's 300 $ trial cannot attach a GPU [gcp-free].

### What each one is like to use

**RunPod** [rp-price] [rp-5090] [rp-bill] [rp-podprice] [rp-ctl] [rp-net] [rp-storage]

- Two tiers: Community Cloud on vetted third-party hosts, Secure Cloud in datacentres. A 5090 is
  0.69 or 1.19 $/h, a 4090 0.34 or 0.89, an L40S 0.79 or 1.09. On 2026-11-09 the Community 5090
  was out of stock and the Secure one in stock [gd-5090].
- Billed by the second. A pod starts only with an hour of credit for it; the minimum deposit is
  10 $ by card, crypto after an identity check; prepaid cards may be refused under 100 $. Low
  balance emails and automatic top-up exist; top-up is optional.
- Storage: the container disk is lost when a pod stops or is interrupted; the volume disk
  (`/workspace`) survives a stop (0.10 $/GB a month running, 0.20 stopped) and goes with the pod
  when it is terminated. A network volume is 0.07 $/GB a month and survives everything. Egress
  fees were not found.
- When the balance reaches zero every pod stops, and a pod without a network volume is terminated
  with its data.
- `runpodctl pod create` takes `--terminate-after` (for example `8h`): RunPod deletes the pod when
  that time is up, whatever happens on the Mac [rp-ctl]. One page calls it a stop, the start
  page a deletion; the pull request that added it speaks of a date [rp-ctl-pr]. #283 tries it on a
  first short pod before trusting it. A pod also gets its own `RUNPOD_POD_ID` and, according to a
  RunPod answer on its forum, a `RUNPOD_API_KEY` limited to that pod, so it can remove itself with
  `runpodctl remove pod $RUNPOD_POD_ID` [rp-self]; unconfirmed in the docs.
- No limit on new accounts was found. How long a pod takes to boot was not found either; #283
  writes it down.
- Templates carry CUDA 12.8 with the development tools (`runpod/pytorch:...-cuda12.8.1-cudnn-devel`)
  [rp-tpl]; any public image can be used, such as `nvidia/cuda:12.8.1-devel-ubuntu24.04`.
- A Community host is a third party's machine: it can in principle read what is on its disks.
  Sillage sends scenes and takes, nothing secret; Secure Cloud is in datacentres.

**Vast.ai** [va-bill] [va-pricing] [va-quick] [va-types] [va-sec] [va-env] [va-boot]

- A marketplace: each offer is a host's machine with its own price, reliability score, bandwidth
  and location. A 5090 from 0.43 to 0.53 $/h at the cheapest, 0.86 $/h at the median (October and
  November 2026, third parties) [va-5090]; 5090 hosts listed in Spain, Finland, Poland, Czechia,
  France and others [va-eu]. A "Secure Cloud" filter keeps only ISO 27001 datacentres [va-sec].
- Billed by the second; storage is billed for as long as the instance exists, stopped or not;
  bandwidth is billed by the byte, up and down, at the host's price. Minimum deposit 5 $, by card
  or crypto; renters need only a verified email.
- At zero balance instances stop, not destroyed, storage keeps billing, and a saved card is
  charged automatically.
- Interruptible instances are bids: a higher bid or an on-demand rental pauses them, processes
  are killed, the disk is kept, and the instance can wait a long time before it resumes [va-types].
- Each instance has `CONTAINER_ID` and a key of its own, `CONTAINER_API_KEY`, that can only start,
  stop or destroy that instance: `vastai destroy instance $CONTAINER_ID` from inside it [va-env].
  No maximum runtime enforced by Vast was found.
- Boot in 1 to 5 minutes, 10 to 60 for a large image pulled the first time, not billed [va-boot].
  For a 5090 filter on a maximum CUDA of 12.8 or more [va-5series].
- Private hosts can technically see the files on their machines [va-sec].

**TensorDock** [td] [td-bill] [td-stop] [td-spot]: virtual machines from hosts, a 4090 from
0.35 $/h, an H100 at 2.25 $/h; by the second, 5 $ minimum; a stopped VM releases its GPU and pays
storage only. Its pricing pages have not moved since August 2026 according to a third party, the
one 5090 listing found is unreliable, no EU location or deadline was found.

**Verda** [ve-pro] [ve-prod] [ve-bill] [ve-sdk]: a Finnish cloud, prepaid, charged every ten
minutes including storage; when the balance reaches zero the instances are discontinued and their
volumes deleted after 96 hours, which is a hard cap but a brutal one. An RTX PRO 6000 (96 GB) at
1.39 or 1.89 $/h (two of its own pages disagree), spot around 0.7 to 1.0; a 5090 at 1.04 $/h only
on an aggregator that may mean another card [gd-5090v]. The best European choice for a billion on
one card.

**Scaleway** [sw-price] [sw-faq] [sw-quota] [sw-pay] [sw-alert] [sw-states] [sw-avail]: French,
by the minute, L4 at 0.75 €, L40S at 1.40 €, H100 at 2.73 € an hour excluding VAT, in Paris
and Warsaw. But GPU quota needs an identity check, prepaid and virtual cards are refused, the bill
comes after use, and billing alerts cannot block spending. A powered-off instance pays only
storage. No consumer card.

**Jarvislabs** [jl-price] [jl-faq] [jl-sdk]: by the minute, L4 at 0.44 $/h (0.29 spot), A100 80 GB
at 1.49, RTX PRO 6000 at 2.19, a 4090 on an old page; paused at zero balance, data deleted if the
balance goes negative; India and Finland.

**Hyperstack** [hs-price] [hs-pay] [hs-states] [hs-hib]: datacentre cards, an RTX PRO 6000 at
1.80 $/h; a 5 $ minimum top-up; a stopped VM keeps billing at the full rate, only hibernation stops
it; below zero all VMs are hibernated for 30 days.

## Renting, step by step, on RunPod

What a session looks like the first time, for #283 to turn into `scripts/gpu-box.sh`. Command names
come from RunPod's documentation as quoted [rp-ctl] [rp-api]; their exact flags are checked with
`--help` on the day.

1. **The account and its credit.** Pierre creates the account, adds 10 $ by card, leaves automatic
   top-up off and the low-balance email on. Nothing can cost more than what is on the balance.
2. **The SSH key.** On the Mac, a key for this alone: `ssh-keygen -t ed25519 -f
   ~/.ssh/sillage_gpu`. The public half (`sillage_gpu.pub`) goes into RunPod's settings, which
   copy it into every pod; the private half never leaves the Mac.
3. **The API key**, created in RunPod's settings, kept on the Mac in `~/.config/sillage/gpu.env`
   (`RUNPOD_API_KEY=...`, mode 600), read by the scripts and by `runpodctl`. Never in the
   repository, never on a box.
4. **Choosing the GPU, the offer and the image.** A 4090 or 5090, Community or Secure, a European
   datacentre when it has one free; the image `nvidia/cuda:12.8.1-devel-ubuntu24.04` (or RunPod's
   own CUDA 12.8 devel template); a container disk of 20 GB and a volume of 60 GB on `/workspace`;
   port 22 exposed over TCP, so that `rsync` and `scp` work and not only a shell.
5. **Booting, with a deadline.** `runpodctl pod create ... --terminate-after 2h` for a test,
   `10h` for a 200 M run estimated at 6. The pod's address and SSH port come back from
   `runpodctl get pod` or the console. Billing starts now.
6. **Connecting.** `ssh -i ~/.ssh/sillage_gpu -p <port> root@<address>`.
7. **The code and the data.** `git clone https://github.com/pierregc/sillage` (public, no token);
   the scene folder and its massive take go up from the Mac with `rsync -aP` to `/workspace`.
   3 to 5 GB take 7 minutes at 100 Mbit/s up, half an hour at 20.
8. **Building there.** `apt-get install ffmpeg`, Swift 6.2 for Ubuntu 24.04 from swift.org next to
   the image's `nvcc`, then the Linux build of #272 and #278 (`scripts/linux.sh`). Ten to fifteen
   minutes the first time, paid at the GPU's price; a ready image comes later if it pays.
9. **Running a long job.** In `tmux new -s run` (or under `nohup`, its output in a log), so that
   closing the laptop or losing Wi-Fi does not stop it. Detach with `ctrl-b d`.
10. **Watching.** `ssh` again, `tmux attach -t run` or `tail -f` the log, `nvidia-smi` for the
    GPU; the console shows the balance going down.
11. **Fetching.** `rsync -aP` the videos, key frames, reports and logs back to the Mac.
12. **Destroying.** `runpodctl remove pod <id>`, then `runpodctl get pod` to see that nothing is
    left, and a line in `docs/notes/gpu-ledger.md`. Stopping is not enough: a stopped pod still
    pays for its volume.

**An interruption.** A spot pod or a Vast bid can be stopped at any time: the processes die, the
container disk is lost, the volume stays [rp-podprice] [va-types]. A full pass writes a checkpoint
every hour (#240), 6.5 GB at 200 M, so with checkpoints on `/workspace` a run loses at most an hour
and resumes with `hires --resume` once the pod is running again; on Vast it may wait in
"scheduling" for a while, its disk billed. For #279 the saving (perhaps a third to a half of 4 to
7 $) is not worth the uncertainty, so it runs on demand.

## Never paying for a forgotten box

What stops billing, and what bounds the worst case:

| | stops billing | deadline the provider enforces | at zero balance | limits and alerts |
| --- | --- | --- | --- | --- |
| RunPod | terminating; stopping keeps the volume billed | `--terminate-after` at creation [rp-ctl] | pods stopped, terminated without a network volume | low-balance email, prepaid |
| Vast.ai | destroying; stopping keeps storage billed | none; the box destroys itself with its own key [va-env] | stopped, storage billed, saved card charged | prepaid, none found |
| TensorDock | deleting; stopping keeps storage billed | none found | deleted (third party) | prepaid |
| Verda | deleting | none found | discontinued, volumes deleted after 96 h | prepaid, automatic top-up optional |
| Scaleway | deleting; powered off keeps storage billed | none | invoiced | alerts only, cannot block [sw-alert] |
| Modal | the function returning or its timeout | a timeout of up to 24 h on every function [modal-to] | stops at the spend limit | workspace spend limit [modal-budget] |

The setup recommended, so that the worst case is bounded twice:

- **A small prepaid balance, no automatic top-up and no saved card that a provider charges by
  itself.** 10 $ on RunPod: whatever goes wrong, that is the most it can cost.
- **A deadline RunPod enforces on every pod**, set by `scripts/gpu-box.sh` at creation to about
  1.5 times the estimate: if the Mac sleeps, the session dies or the script crashes, the pod goes
  anyway.
- **The job ends its own box when it is done**, once the results are fetched, if #283 confirms
  that the key RunPod puts in a pod reaches that pod only; never with Pierre's key.
- **The script always ends by listing the pods left**, and every session goes in the ledger.

On Vast the same setup lacks the provider's deadline: a watchdog on the box (`sleep`, then
`vastai destroy instance $CONTAINER_ID` with the instance's own key) does the same as long as the
box runs, and Vast's automatic charge of a saved card has to be avoided.

## Who drives the box

| | needs | risks | for |
| --- | --- | --- | --- |
| a coding session on the Mac over SSH | the Mac on to start and to fetch, the SSH key and API key on the Mac | the Mac asleep at the wrong time, covered by the deadline | **bring-up and big runs** |
| a cloud coding session over an HTTPS API | the provider's API key as a secret of the cloud environment, the provider's host allowed, a job that fetches its own inputs and puts its outputs somewhere the session can read | inputs live on the Mac and outputs need a store; the session cannot log in to see what went wrong | later, correctness checks only |
| Pierre by hand in the console | nothing more | forgetting to destroy, covered by the deadline | a first look, if he wants to learn |

The Mac is the natural driver: the scene and the massive take are made there, the videos come back
there, and the SSH session costs it nothing while the job runs in `tmux`; the Mac only has to be
on when the box starts and when the results come back, and the deadline covers the time between.

A cloud session cannot use SSH (above). It could rent through RunPod's REST API
(`api.runpod.io/v2/pods`, a start command that clones the repository, builds and runs) [rp-api] or
through RunPod Serverless (`POST .../run`, `GET .../status`, a worker image built and pushed to a
registry first) [rp-sls], or Modal, where a function runs in any image (an `nvidia/cuda` devel
image plus Swift) for up to 24 hours, billed by the second, with 30 $ of free compute a month and a
workspace spend limit [modal-free] [modal-to] [modal-cuda] [modal-budget]. Modal is the one place
a correctness check could run at no cost: an L4 (8.9) at 0.80 $/h or an A10 (8.6) at 1.10 $/h, no
4090 or 5090, so no timing for the run's GPU [modal-price]. But it needs a second account, an API
token stored in the cloud environment, Modal's hosts allowed through the proxy (its SDK talks gRPC,
untested through this proxy), and the reference outputs compared there. Worth it once the engine
changes often enough that checking it on NVIDIA from a cloud session pays; not for #283.

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
  32-core GPU (4 334): RTX 3090 1.23, RTX 4090 2.52, RTX 5090 3.44, L40S 2.03, H100 1.4 (one or
  two runs) [blender]; RTX PRO 6000 about 3.7 and RTX 5080 about 2.0 from another version's
  listing; A100 about 0.9 from a vendor's blog [blender-a100]. But Cycles uses ray tracing hardware
  on both sides (MetalRT on the M4 Max, OptiX on RTX cards) and Sillage's walk uses neither; the
  A100 and H100 have none and walk in software, so they come out lower in Blender than they would
  here.
- **Memory bandwidth** against the M4 Max's 410 GB/s [m4max]: 3090 2.3x, 4090 2.5x, L40S 2.1x,
  5090 and RTX PRO 6000 4.4x, A100 3.8 to 5x, H100 5 to 8x, L4 0.7x [tpu-5090] [nv-ampere]
  [hw-specs].
- **Caches**: the tree (5 M bodies, a few hundred MB) fits no L2, but the upper levels every walk
  crosses do in the 4090's 72 MB, the L40S's and 5090's 96 MB and the PRO 6000's 128 MB, and not in
  the 3090's 6 MB [cc-4090] [cc-bw] [tpu-5090]. Blackwell's L2 and memory latencies (about 130 and
  330 ns) are higher than Ada's (107 ns to L2) [cc-bw], which is why the 5090 is put below its
  bandwidth ratio. The M4 Max's own latencies are not published; the M2 Pro's GPU waits 234 ns at
  its system cache [cc-m2].
- **Arithmetic** last: at 5 to 15 % of peak, the 5090's 7.7 times the M4 Max's 13.6 TFLOPS is not
  what limits it.

The epic put the 5090 at about 4x (3 to 6) and the A100 at 1.3x; the numbers below are a little
lower for Blackwell and higher for the A100 and H100, for the reasons above. Each is good to about
a factor 1.5 either way; #283 measures it in its first hour on each card.

| GPU | memory | speed (range) | 200 M story | $/h seen | 200 M cost | holds 200 M | holds 1 G |
| --- | ---: | --- | ---: | --- | ---: | :---: | :---: |
| M4 Max | unified | 1 | 19.4 h | | | yes | with 64 GB or more |
| RTX 3090 | 24 GB | 1.3 (1.0 to 2.0) | 15.4 h | 0.11 to 0.46 [va-3090] [gd-rp] | 2 to 7 $ | yes | no |
| RTX 4090 | 24 GB | 2.5 (1.8 to 3.5) | 8.3 h (6 to 11) | 0.34 Community, 0.89 Secure | 2.8 $ (2 to 4) / 7.4 $ (5 to 10) | yes | no |
| RTX 5080 | 16 GB | 2.0 (1.5 to 3.0) | | rarely offered | | no margin | no |
| RTX 5090 | 32 GB | 3.5 (2.5 to 5.0) | 6.0 h (4.4 to 8.3) | 0.69 Community, 1.19 Secure, Vast 0.45 to 0.86 | 4.1 $ (3 to 6) / 7.1 $ (5 to 10) | yes | no |
| RTX PRO 6000 | 96 GB | 3.7 (2.5 to 5.0) | 5.7 h (4.4 to 8.3) | 1.39 to 1.89 Verda, 1.80 Hyperstack | 8 to 11 $ | yes | yes |
| L40S | 48 GB | 2.0 (1.5 to 3.0) | 10.2 h (7 to 13) | 0.79 Community, 1.40 € Scaleway | 8 $ / 14 € | yes | barely |
| A100 80 GB (sm_80) | 80 GB | 1.5 (1.0 to 2.5) | 13.4 h (8 to 20) | 1.09 Thunder, 1.19 Community | 15 $ | yes | yes |
| H100 | 80 GB | 2.0 (1.4 to 3.0) | 10.2 h (7 to 14) | 1.99 Community PCIe, 2.73 € Scaleway | 20 $ and more | yes | yes |
| L4 | 24 GB | 0.8 (0.6 to 1.2) | 25 h | 0.44 Jarvislabs, 0.75 € Scaleway | 11 $ and more | yes | no |

The time is 19.4 h divided by the speed, plus half an hour; the cost, that time at the price seen.
Memory follows the epic: 12 to 16 GB at 200 M (36 bytes a tracer, the massive particles and their
tree, the renderer's targets), 40 to 50 GB at a billion.

**Reading it.** Per run the 4090 on Community is the cheapest card that holds 200 M (about 3 $,
8 h), the 5090 the fastest at a price close to it (about 4 $ in 6 h on Community, 7 $ on Secure).
Datacentre cards cost two to five times more for the same story: their bandwidth and big caches do
not pay on a walk this latency bound. A whole story on 2 M massive at its own step (8 480 steps,
about 11 h on the M4 Max, [200m-preview](200m-preview.md)) costs a little over half of all this.

**A billion stars** (990 M tracers, the same 15 500 steps): the walk is 89.5 h of M4 Max, the
frames 4.3 h (8.4 s a 4K frame at a billion), about 94 h in all. On one RTX PRO 6000 (96 GB) about
26 h, 37 to 50 $ at Verda; on four 5090s with the tracers split between them (#280), 32 GB each,
about 7 to 8 h and 21 $ on Community or 37 $ on Secure; on four 4090s on Community, 10 to 11 h and
about 14 $. Beyond phase 2's 20 € in every case but the last, so #280 waits for Pierre's go and a
cap he sets, as the epic says.

## The recommendation

- **Provider: RunPod.** The only one with both the 4090 and the 5090 at fixed prices in two tiers,
  a deadline it enforces itself, a prepaid balance that stops everything at zero, billing by the
  second, a CLI and an HTTPS API, CUDA 12.8 devel images, and European datacentres.
- **#283, bring-up and timings: a Community RTX 4090** (0.34 $/h) for building and the correctness
  checks against the reference outputs, a few hours, about 1 to 2 $; then **an hour on a 5090**
  (0.69 or 1.19 $) and an hour on the 4090 timing the same steps, to choose the run's card on the
  measured cost of a step rather than on the table above. About 4 $ in all.
- **#279, the first 200 M run: an RTX 5090** on Community at 0.69 $/h when one is free, on Secure
  at 1.19 $/h otherwise, on demand: about 6 h and 4 to 7 $ by the estimate, deadline 10 h. If #283
  finds the 4090 cheaper per run by more than the time it costs, the 4090.
- **Fallback, no 5090 free on RunPod: Vast.ai** with the Secure Cloud filter, a 5090 from about
  0.5 $/h, 5 $ of credit, a watchdog with the instance's own key in place of the provider's
  deadline. Or a 4090 on RunPod, which holds 200 M as well.
- **Budget**: about 4 $ for #283 and 4 to 7 $ for #279, 8 to 11 $ in all: 7 to 10 €, 9 to 12 €
  if VAT is added, inside phase 2's 20 € unless the estimates are off by more than half, which
  #283 shows before #279 spends anything. The first 10 $ of credit cover #283; what is left is
  topped up before #279 only as far as the run's deadline needs (10 h at 1.19 $ on Secure).

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

All read on 2026-11-10 through a search engine's quotes, except where a date of the page is given.

- [rp-price] RunPod pricing, https://www.runpod.io/pricing
- [rp-5090] RunPod RTX 5090 page, table dated 2026-10-09, https://www.runpod.io/gpu-models/rtx-5090
- [gd-rp] getdeploying, RunPod (third party), https://getdeploying.com/runpod
- [gd-5090] getdeploying, RTX 5090 across providers, stock checked 2026-11-09 (third party),
  https://getdeploying.com/gpus/nvidia-rtx-5090
- [beam-5090] Beam, RTX 5090 pricing (third party), https://www.beam.cloud/blog/nvidia-rtx-5090-pricing
- [rp-bill] RunPod billing, https://docs.runpod.io/accounts-billing/billing
- [rp-podprice] RunPod pod pricing and storage, https://docs.runpod.io/pods/pricing
- [rp-storage] RunPod storage guide, https://www.runpod.io/blog/where-did-my-files-go-a-straight-guide-to-runpod-storage
- [rp-ctl] `runpodctl pod`, https://docs.runpod.io/runpodctl/reference/runpodctl-pod and
  https://docs.runpod.io/pods/manage-pods
- [rp-ctl-pr] runpodctl pull request 271, https://github.com/runpod/runpodctl/pull/271
- [rp-self] RunPod forum, terminating a pod from within, https://www.answeroverflow.com/m/1267200524181180427
- [rp-api] RunPod REST API, https://docs.runpod.io/api-reference-v2/pods/create-a-pod and
  https://docs.runpod.io/api-reference-v2/pods/terminate-a-pod
- [rp-net] RunPod data centres, https://docs.runpod.io/pods/networking and
  https://www.runpod.io/blog/runpod-global-networking-expansion
- [rp-tpl] RunPod, PyTorch 2.8 with CUDA 12.8, https://www.runpod.io/articles/guides/pytorch-2-8-cuda-12-8
- [rp-ref] RunPod referrals and welcome credit, https://docs.runpod.io/references/referrals
- [rp-sls] RunPod Serverless, https://docs.runpod.io/serverless/pricing and
  https://docs.runpod.io/serverless/endpoints/send-requests
- [va-5090] Vast.ai 5090 prices (third parties): https://www.usagepricing.com/blueprint/vast-ai
  (October 2026), https://gpuperhour.com/rent/rtx-5090, https://computeprices.com/gpus/rtx5090
  (2026-11-01), https://gpufinder.dev/gpu/rtx-5090 (2026-10-27)
- [va-4090] Vast.ai 4090 prices (third parties), https://getdeploying.com/gpus/nvidia-rtx-4090 and
  https://computeprices.com/providers/vast/gpus/rtx4090
- [va-3090] Vast.ai 3090 prices (third party, 2026-08-04), https://computeprices.com/providers/vast/gpus/rtx3090
- [va-bill] Vast.ai billing, https://docs.vast.ai/guides/reference/billing
- [va-pricing] Vast.ai instance pricing, https://docs.vast.ai/guides/instances/pricing
- [va-quick] Vast.ai quickstart, https://docs.vast.ai/guides/get-started/quickstart
- [va-types] Vast.ai rental types, https://docs.vast.ai/documentation/instances/choosing/instance-types
- [va-sec] Vast.ai security and compliance, https://docs.vast.ai/guides/reference/faq/security and
  https://vast.ai/compliance
- [va-env] Vast.ai instance environment, https://docs.vast.ai/guides/instances/docker-environment
- [va-cli] `vastai`, https://docs.vast.ai/cli/reference/destroy-instance
- [va-boot] Vast.ai hello world, https://docs.vast.ai/cli/hello-world
- [va-5series] Vast.ai RTX 50 series, https://docs.vast.ai/rtx-5-series
- [va-eu] Vast.ai 5090 offers (search snapshot), https://cloud.vast.ai/?gpu_name=RTX+5090
- [td] TensorDock prices: https://gpuperhour.com/providers/tensordock (third party, 2026-10-18),
  https://www.tensordock.com/
- [td-h100] TensorDock H100, https://www.tensordock.com/gpu-h100.html
- [td-bill] TensorDock billing, https://dashboard.tensordock.com/api/docs/billing
- [td-zero] TensorDock (third party), https://inferencehub.org/gpus/providers/tensordock
- [td-stop] TensorDock VMs, https://docs.tensordock.com/virtual-machines/introduction-to-core-compute-vms
- [td-spot] TensorDock spot, https://docs.tensordock.com/virtual-machines/spot-instances
- [td-api] TensorDock API, https://dashboard.tensordock.com/api/docs/instance-management
- [ve-pro] Verda RTX PRO 6000, https://verda.com/rtx-pro-6000; spot (third party),
  https://computeprices.com/providers/verda/gpus/rtx-pro-6000
- [ve-prod] Verda products, https://www.verda.com/products
- [ve-bill] Verda pricing and billing, https://docs.verda.com/welcome-to-verda/pricing-and-billing
- [ve-cli] Verda CLI, https://docs.verda.com/cli/instances/
- [ve-sdk] Verda SDK, https://pypi.org/project/verda/
- [gd-5090v] getdeploying, 5090 against RTX 6000 Ada (third party),
  https://getdeploying.com/gpus/nvidia-rtx-5090-vs-nvidia-rtx-6000-ada
- [sw-price] Scaleway GPU pricing, https://www.scaleway.com/en/pricing/gpu
- [sw-faq] Scaleway instances FAQ, https://www.scaleway.com/en/docs/instances/faq/
- [sw-quota] Scaleway quotas, https://www.scaleway.com/en/docs/organizations-and-projects/organization/organization-quotas/
- [sw-pay] Scaleway payment methods, https://www.scaleway.com/en/docs/billing/how-to/add-payment-method/
- [sw-alert] Scaleway billing alerts, https://www.scaleway.com/en/docs/billing/how-to/use-billing-alerts/
- [sw-states] Scaleway instance states, https://www.scaleway.com/en/docs/instances/reference-content/instance-states/
- [sw-avail] Scaleway availability, https://scaleway.com/en/docs/account/reference-content/products-availability
- [jl-price] Jarvislabs pricing, https://jarvislabs.ai/pricing
- [jl-4090] Jarvislabs, 4090 (old page), https://jarvislabs.ai/ai-faqs/best-gpu-for-stable-diffusion
- [jl-faq] Jarvislabs FAQ, https://docs.jarvislabs.ai/faqs/
- [jl-sdk] Jarvislabs SDK, https://docs.jarvislabs.ai/sdk
- [hs-price] Hyperstack, https://www.hyperstack.cloud/ and https://www.hyperstack.cloud/pricing
- [hs-pay] Hyperstack pricing and top-up, https://www.hyperstack.cloud/gpu-pricing
- [hs-states] Hyperstack billing by state, https://docs.hyperstack.cloud/docs/billing/states-and-billing/
- [hs-hib] Hyperstack hibernation, https://docs.hyperstack.cloud/docs/virtual-machines/hibernation/
- [ovh-l40s] OVHcloud community, L40S billed 1.40 €/h (July 2026),
  https://community.ovhcloud.com/t/facturation-gpu-l40s-incoherente-2-287-pour-une-instance-de-9-jours-1-40-h/53656
- [ovh-hour] OVHcloud hourly billing, https://support.us.ovhcloud.com/hc/en-us/articles/22179651508115
- [ovh-stop] OVHcloud billing of instances, https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/analyze-billing
- [ovh-quota] OVHcloud quota, https://docs.ovhcloud.com/en/guides/public-cloud/cross-functional/increasing-public-cloud-quota
- [hz-gpu] Hetzner GPU servers, https://www.hetzner.com/gpu and
  https://docs.hetzner.com/general/billing-and-account-management/billing-at-hetzner/billing-system-hetzner/
- [hz-131] Hetzner GEX131, https://www.hetzner.com/pressroom/new-gex131/
- [gc] Genesis Cloud (third party), https://www.spheron.network/blog/genesis-cloud-pricing-2026-eu-h100-cost/
- [ss-5090] Sesterce (third party, August 2026), https://computeprices.com/providers/sesterce/gpus/rtx5090
- [la-price] Lambda (third party, October 2026), https://checkthat.ai/brands/lambda/pricing
- [la-bill] Lambda billing, https://docs.lambda.ai/public-cloud/billing/
- [la-inst] Lambda instances, https://docs.lambda.ai/public-cloud/on-demand/creating-managing-instances/
- [la-fr] Lambda forum, https://deeptalk.lambda.ai/t/credit-card-declined-for-people-living-in-france/2286
- [tc-cli] Thunder Compute CLI, https://www.thundercompute.com/docs/cli-reference
- [tc-a100] Thunder Compute, https://www.thundercompute.com/blog/cheapest-cloud-gpu-providers
- [tc-proto] Thunder Compute prototyping mode, https://www.thundercompute.com/docs/prototyping-mode
- [tc-spec] Thunder Compute specs, https://www.thundercompute.com/docs/technical-specs
- [do-price] DigitalOcean GPU droplets, https://www.digitalocean.com/pricing/gpu-droplets
- [do-off] DigitalOcean powered-off droplets (third party), https://www.aquanode.io/blog/digitalocean-gpu-droplets
- [do-ps] Paperspace, https://docs.digitalocean.com/products/paperspace
- [salad] Salad prices (September 2026), https://blog.salad.com/saladcloud-price-changes-september-2026/
- [aws-quota] AWS EC2 quotas, https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-quotas.html
- [aws-g6] AWS g6.2xlarge in Paris (third party), https://www.doit.com/compute/spot/eu-west-3/g6.2xlarge
- [gcp-free] Google Cloud free trial, https://docs.cloud.google.com/free/docs/free-cloud-features
- [gcp-g2] Google Cloud g2-standard-8 in Paris (third party), https://calculator.holori.com/gcp/vm/g2-standard-8/europe-west9
- [az-nc] Azure NC family, https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/gpu-accelerated/nc-family
  and https://learn.microsoft.com/en-us/answers/questions/1616602/free-credits-do-not-allow-launching-gpu-accelerate
- [modal-price] Modal pricing, https://modal.com/pricing
- [modal-free] Modal free plan (third party), https://www.costbench.com/software/ai-gpu-cloud/modal/
- [modal-to] Modal timeouts, https://modal.com/docs/guide/timeouts
- [modal-cuda] Modal CUDA images, https://modal.com/docs/guide/cuda
- [modal-budget] Modal budgets, https://modal.com/docs/guide/budgets
- [colab] Colab free tier (third party), https://www.hivenet.com/post/google-colaboratory-gpu-complete-guide-to-free-cloud-gpu-access-and-limitations
- [colab-payg] Colab compute units (third party, March 2026), https://mccormickml.com/2024/04/23/colab-gpus-features-and-pricing/
- [kaggle] Kaggle GPUs (third party), https://research.aimultiple.com/free-cloud-gpu
- [free] Free GPUs and credits (third party), https://gpuperhour.com/blog/free-cloud-gpus-and-credits
- [blender] Blender Open Data, Blender 4.3.0, medians by device,
  https://opendata.blender.org/benchmarks/query/?compute_type=OPTIX&compute_type=HIP&blender_version=4.3.0&group_by=device_name
  and the same query with `compute_type=METAL`
- [blender-a100] A100 and H100 in Blender 4.5 (vendor blog), https://www.spheron.network/blog/blender-cloud-rendering-gpu/
- [m4max] M4 Max with a 32-core GPU, 410 GB/s, https://lowendmac.com/1234/apple-silicon-m4-max-chip-specs/
- [tpu-5090] RTX 5090, https://www.techpowerup.com/gpu-specs/nvidia-geforce-rtx-5090-founders-edition.b12225
  and https://images.nvidia.com/aem-dam/Solutions/geforce/blackwell/nvidia-rtx-blackwell-gpu-architecture.pdf
- [nv-ampere] NVIDIA Ampere whitepapers (A100, GA102),
  https://images.nvidia.com/aem-dam/en-zz/Solutions/data-center/nvidia-ampere-architecture-whitepaper.pdf
- [hw-specs] L40S, https://www.supermicro.com/datasheet/datasheet_NVIDIA_L40S_Systems.pdf; H100,
  https://www.thundercompute.com/blog/nvidia-h100-specs-full-guide; RTX PRO 6000,
  https://www.techpowerup.com/gpu-specs/rtx-pro-6000-blackwell.c4272
- [cc-4090] Chips and Cheese, RTX 4090, https://chipsandcheese.com/p/microbenchmarking-nvidias-rtx-4090
- [cc-bw] Chips and Cheese, Blackwell (RTX PRO 6000), https://chipsandcheese.com/p/blackwell-nvidias-massive-gpu
- [cc-m2] Chips and Cheese, M2 Pro GPU, https://chipsandcheese.com/p/a-brief-look-at-apples-m2-pro-igpu
- [fx] EUR to USD on 2026-10-11, https://30rates.com/eur-usd-forecast-tomorrow-this-week
