# Keeping the machine usable

Three things, all measured, none of them the renderer.

- **Dark matter was being drawn, recorded and smoothed.** It is three particles in five in a
  self-gravitating scene and reaches no pixel. The sampler now puts visible particles first, so
  the draw call, the take and the smoothing field all stop at `visibleCount`. At three million
  stars a take frame went from 43 MB to 17, and replay from 14.7 ms to 11.8 — 85 frames a
  second at three million.
- **The simulation queue runs at utility.** The tree build fans out over every core through
  `concurrentPerform`, which inherits the calling thread's class, and at default priority a big
  scene makes the whole machine unusable rather than just this window. Measured at a million
  particles: 112.7 ms a step against 116.7. It is free. Background would cost 70 %.
- **The force pass is dispatched in pieces of a million.** One kernel over seven million
  particles holds the GPU for the best part of a second. `splittingTheForcePassChangesNothing`
  guards it, and it has to: without the chunk offset the second piece recomputes the first
  one's particles and leaves the rest of the scene carrying stale accelerations, which no test
  at one chunk can see. Verified by breaking it on purpose.

A run also has a finish now. `stopAtMyr` ends it and switches to replay, and a destination
armed beforehand writes the take out with nothing to press.

Exposure divides by the particles that reach a pixel now, not by every particle simulated, so
switching live halos on no longer dims a scene by the halo ratio. The warning that used to sit
here — that fixing it would brighten every self-gravitating scene by two and a half and mean
retuning everything — was right about the linear factor and wrong about the picture. The
logarithmic stretch and the filmic shoulder absorb almost all of it: mean luminance of a
rendered frame went from 18.19 to 21.19, sixteen per cent, and nothing needed retuning. The
galaxies now carry their own diffraction spikes, which they could not reach before.
