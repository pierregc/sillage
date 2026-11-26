# GPU ledger

Every rented session, appended by `scripts/gpu-box.sh down` (#283). Cost at the box's hourly price
times its minutes; credit used is what the Vast account lost over the session (storage and
bandwidth included). Euros at 1.12 $ a euro.

| date (UTC) | provider | GPU | $/h | minutes | cost $ | credit used $ | € | issue | what ran |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 2026-11-21 | Vast.ai | RTX 3090 | 0.1907 | 161 | 0.512 | 0.649 | 0.58 | #283 | engine-check, test-cuda without timings, scene-0031 8 M on 12 M (24 frames), 4K stills, 4K flight frames |
| 2026-11-21 | Vast.ai | RTX 5090 | 0.2794 | 84 | 0.391 | 0.199 | 0.35 | #424 | interruptible 5090: engine-check, scene-0031 8 M on 12 M (128 ms a step), paused twice, lost before the exports' results |
| 2026-11-21 | Vast.ai | RTX 5090 | 0.4289 | 17 | 0.122 | 0.120 | 0.11 | #424 | on-demand 5090, host's network too slow to install anything (apt and swift.org stalled), destroyed unused |
| 2026-11-21 | Vast.ai | RTX 5090 | 0.4289 | 2 | 0.014 | 0.016 | 0.01 | #424 | on-demand 5090, the same slow host again, destroyed at once |
| 2026-11-21 | Vast.ai | RTX 5090 | 0.5009 | 120 | 1.002 | 1.075 | 0.96 | #424 | on demand (Romania): engine-check, scene-0031 8 M on 12 M, exports --profile 1080p and 4K wide and inside an arm, large splats off/256/1024/4096; the flight export tests ran but the box reached its 2 h deadline and deleted itself before their result was fetched |
| 2026-11-26 | Vast.ai | RTX 5090 | 0.5348 | 16 | 0.143 | 0.113 | 0.10 | #425 | gpu.yml run 45854414104: point-stars-timing.sh, the after only read back (the before was in the artifact) |
| 2026-11-26 | Vast.ai | RTX 5090 | 0.6037 | 19 | 0.191 | 0.164 | 0.15 | #425 | gpu.yml run 45859174282: box never reachable over SSH in 15 min, destroyed unused |
| 2026-11-26 | Vast.ai | RTX 5090 | 0.5644 | 11 | 0.103 | 0.098 | 0.09 | #425 | gpu.yml run 45862075598: point-stars-timing.sh, before and after, the same bytes |
