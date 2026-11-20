# #357: point stars seen from inside an arm

The Mice take (2026-11-04 scene-0067, 8 M visible), look `photograph`, the frozen demo flight
`dive.flight.json`. Before is main at 50cd184, after is `feat/357-inside-star-field`.

- `still-<frame>-<before|after>-1080p.jpg`: one render of frames 700, 1000, 1104 and 1200, no
  motion blur (`export --flight-keys --flight-at`).
- `stills-1104-crops.jpg`: frame 1104, 600 by 260 pixels at 1:1, before and after, 1080p and 4K
  scaled to 1080p.
- `after-1080p-against-4k.jpg`: the after frame 1104 drawn in 1080p and in 4K, both at 960 wide.
- `clip-frame-1104-crops.jpg`: frame 1104 of the clips, with the streaks of motion blur.
- `dive-1000-1200-<before|after>-1080p.mp4`: frames 1000 to 1200 of the flight, HEVC as `export`
  writes it. The 4K clips (43 MB each) are on the Mac.
- `variants-tried.jpg`: the settings tried and left (see `docs/notes/inside-a-galaxy.md`).
