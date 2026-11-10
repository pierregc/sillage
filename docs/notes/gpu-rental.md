# Renting an NVIDIA GPU for the big runs (#270)

Step 1 of epic #269, phase 1: a survey on paper, read on 2026-11-10, with no account created and
nothing rented. It prepares phase 2 (#283 brings the CUDA engine up on a rented GPU and times it,
#279 runs 200 M there), which starts only when Pierre says so.

Draft in progress: the provider tables and the recommendation follow.

## How this was read

Every price and rule below was read on 2026-11-10 through a web search engine, which quotes the
pages it cites. The cloud session that wrote this note cannot open the providers' own pages: its
network allows HTTPS through a proxy to a list of hosts, and www.runpod.io, docs.runpod.io,
docs.vast.ai, modal.com, www.scaleway.com, www.ovhcloud.com, www.hetzner.com,
opendata.blender.org and chipsandcheese.com are not on it. So each fact carries the page the
search engine quoted it from, a page marked *third party* is an aggregator rather than the
provider, and #283 reads the price again on the day it rents. Prices move weekly on the
marketplaces.

## What Sillage asks of a rented machine

From the ticket, unchanged:

- An NVIDIA GPU of compute capability 8.6 or more and a driver for CUDA 12.8 or later. That rules
  out the T4 (7.5), the V100 (7.0), the P100 (6.0) and, strictly, the A100 (8.0); an A100 runs
  code built for sm_80, so it stays usable if the build adds that target.
- About 4 GB of GPU memory for the tests, 12 to 16 GB for 200 M, 40 to 50 GB for a billion on one
  card.
- 8 cores, 32 GB of RAM, 60 GB of local disk, Ubuntu 22.04 or 24.04 with `nvcc` or an image we
  choose, root to install Swift 6.2 and ffmpeg.
- SSH from the Mac; the public repository cloned over HTTPS; 3 to 5 GB up and 1 to 5 GB down for
  a big run; runs of 10 to 60 minutes for tests and 5 to 10 hours for a 200 M story, checkpointed
  every hour (#240).

## A cloud session of Claude Code cannot open SSH

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
