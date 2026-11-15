# Step schedules in hires (#312)

scene-0031 of 2026-10-30-b, 8 M drawn from 2 M massive, `--take-interval 4`, 923 frames from 157 to 887 Myr, each run alone on the GPU.

| run | steps | time |
| --- | ---: | ---: |
| (a) step 3.5 throughout (#307) | 8 968 | 2 388 s (39.8 min) |
| default schedule | 6 524 | 1 765 s (29.4 min) |

Saved: 27.3 % of the steps, 26.1 % of the time. Switches: x2 through the settle, x1 from 156.7 Myr (frame 0), x2 from 560.2 Myr (frame 510), 100 Myr after the merger as the pace reads it (centres within 10 kpc from 459 Myr).

`a-vs-schedule-1080p.mp4`: (a) left, the schedule right, fixed camera. Stills, (a) left: frames 0 and 4 after the settle's switch, 509 and 510 either side of the aftermath's, 600 and 922 later. The frame-to-frame change across frame 510 is (a)'s own within 0.3 %.
