# Two things that made a replay a slideshow

One frame every half second on a 4.8 M particle take, and neither cause was the picture.

**The solver never stopped.** `stopAndReplay` retired the stepping chain, then set
`isPlaying = true`, and only then set the mode. `isPlaying`'s observer starts a chain whenever
the mode still says `.running` — so the line that was meant to resume the *playhead* restarted
the *solver*, which then held the GPU behind the picture for the whole replay. Every run that
reaches its finish goes through this: `checkFinish` pauses and calls `stopAndReplay`, and the
pause is exactly what makes the observer fire. At five million particles a burst is four steps
of a few hundred milliseconds each, which is the half second between frames, measured from the
other side. `--replayswitch` is the check: it runs a scene, pauses, replays, and fails if the
step count moves afterwards. It read `+55 pas pendant la relecture` before and `OUI` after.

**The bulk copy held the lock the main actor wanted.** `Recording.copy` took the lock for the
whole twenty-eight megabyte memcpy. The reader runs that on its own queue, so `fetch` never
blocked — but `frame(at:)`, which only wants a struct, waited behind it on every displayed
frame. A take read from a file is finished: every frame is in it and the mapping never moves,
so the copy needs the lock only to read the frame's metadata. A capture still growing is the
other case, and that one keeps it, because the next batch can reallocate the array mid-copy.

Measured headless at 2560x1440 on good01.sillage, 4.8 M particles:

| | image entière | attente lock | rendu GPU |
| --- | --- | --- | --- |
| avant | 38.0 ms | 28.1 ms | 18.0 ms |
| après | 20.1 ms | 0.0 ms | 17.7 ms |

The remaining twenty milliseconds is the picture itself, and that is a fair price for nearly
five million particles.

`--replay <prise> [images]` is the instrument, and it is **headless on purpose**. Half an hour
went into a windowed version that sat there doing nothing before `screencapture` answered
"could not create image from display": a machine whose screen is asleep never shows a window,
so `onAppear` never fires and every check that hangs off it waits for ever. Anything that has
to be measurable while nobody is at the machine belongs in `init()`, next to `--selftest`.
