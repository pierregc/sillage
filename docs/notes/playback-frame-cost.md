# What a played-back frame costs

Playback stuttered at five million particles with the GPU only half busy, which is the
signature of a stall rather than of a shortage of throughput. It was a memcpy on the main
thread: every displayed frame copied *both* surrounding snapshots into a staging buffer —
sixty megabytes, measured at 33 ms against a 16.7 ms budget — and on a take larger than the
page cache the copy went to the disk as well. Most of it was wasted twice over, because at the
default speed the playhead crosses a snapshot only every other frame, so half the copies were
of data that was already there.

`SnapshotStream` copies each snapshot once, on a background queue, before it is wanted, into a
direct-mapped cache (`index % slots`) that the expand kernel reads in place — the kernel takes
the two snapshots as separate bindings so neither has to be moved next to the other. On
save01.sillage at 5.2 M particles, a whole frame including a 2560x1440 render: 35.2 ms to
8.7 ms median, 109 frames a second, nothing over budget in 206 frames.

Two things were suspected and measured innocent, so do not go after them again without new
evidence. The smoothing refresh runs on the simulation queue and never touched a frame: on
good01 at 4.8 M, frame medians 8.0 ms with the CPU tree and 8.2 with the GPU one. It moved to
the GPU in #39 anyway, 33 ms of every core down to 11 ms, and the real bug there was that the
app never ran it: the periodic refresh lived only in `snapshot(steps:)`, so a window kept the
lengths it got when the renderer was built, and a replay could build them from a positions buffer
nothing had been expanded into yet. `draw` ticks it now. And `expand`'s `waitUntilCompleted`
costs about 2 ms; it is what lets the reader overwrite slots without racing the GPU, and it is
worth keeping until something needs those two milliseconds.
