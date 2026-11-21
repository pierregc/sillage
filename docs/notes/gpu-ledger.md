# GPU ledger

Every rented session, appended by `scripts/gpu-box.sh down` (#283). Cost at the box's hourly price
times its minutes; credit used is what the Vast account lost over the session (storage and
bandwidth included). Euros at 1.12 $ a euro.

| date (UTC) | provider | GPU | $/h | minutes | cost $ | credit used $ | € | issue | what ran |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| 2026-11-21 | Vast.ai | RTX 3090 | 0.1907 | 161 | 0.512 | 0.649 | 0.58 | #283 | engine-check, test-cuda without timings, scene-0031 8 M on 12 M (24 frames), 4K stills, 4K flight frames |
