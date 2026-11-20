# Flights round the black hole close up (#335)

The three sample flights `black-hole new` writes in a close up's `flights/`, exported at 1080p
(HEVC) in both looks over a 6 M tracer take of the default scene. See
`docs/notes/black-hole-close-up.md`, "Cameras that fly (#335)", on `main`.

| file | flight | time |
| --- | --- | --- |
| `physics-orbit-1080p.mp4`, `film-orbit-1080p.mp4` | once round at 35 r_s, 8° to 20° over the plane, 40 s | runs, t 2600 to 3400 |
| `physics-descent-1080p.mp4`, `film-descent-1080p.mp4` | 300 r_s down to just over the disk's edge, 40 s | the story, t 700 to 3000, then held |
| `physics-plane-1080p.mp4`, `film-plane-1080p.mp4` | down through the disk 14 r_s from the hole, 24 s | frozen at t 3000 |

- `flights-sheet.jpg`: five frames of each, physics then film.
- `crop-plane-360.png`: the camera in the disk's plane, frame 360 of the plane pass.
- `*.flight.json`: the flights as written in the folder.
