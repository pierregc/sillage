# What the window costs

Anything on the main actor is the interface's frame budget. Three things were spending it and
none of them looked expensive:

- **Launching.** Sampling four million visible particles takes 4 s and building the solver 5 s
  more. Both ran on the main actor, so a large scene froze the window for nine seconds with a
  black rectangle to look at. Both are on the simulation queue now, `isPreparing` says so, and
  `--responsive` measures the stall a launch still costs: 85 ms at two million.
- **Placing the camera.** `frameCamera` sorted every particle's radius to take a percentile:
  400 ms at five million, to point a camera. Fifty thousand of them answer the same question.
- **The setup preview.** 140 ms of resampling on every slider release, twenty sliders deep.

Anything that walks every particle belongs off the main actor. That includes the smoothing
refresh and the first captured frame, both of which look like bookkeeping and are not.
