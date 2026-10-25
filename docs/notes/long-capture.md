# A long capture keeps every frame

A take used to answer a full memory budget by throwing away every other frame and capturing
half as often from then on. That keeps the *duration* and loses the *run*. Measured, 3 000
frames offered against a 64 MB budget:

| | images gardées | cadence finale |
| --- | --- | --- |
| avant | 95 | 14.32 Myr, une sur 32 |
| après | 3 000 | 0.4522 Myr, inchangée |

Thirty-one times the temporal resolution, and nothing between two of the old snapshots ever
happened. Physics that cost hours is not a thing to resample.

**The budget bounds memory now, not the take.** Past it the capture continues into a scratch
file, and only the overflow goes there — the frames the budget already paid for stay in memory,
so nothing stalls at the moment it binds. Over the same 3 000 frames the take holds a flat
64.3 MB and the process a flat 159 MB while the file grows to 966 MB, and every frame reads
back. What that costs is disk and nothing else: at this cadence ten thousand megayears is
22 124 frames, which is 7.4 GB at sixty thousand particles and six hundred at five million.
**Cadence is the lever there, and it is `stepsPerFrame`** — choosing a coarser one up front is a
decision, where thinning was the same thing done silently and after the fact.

`SpillFile` opens its file and immediately unlinks it. The descriptor goes on working, nothing
else can find it, and the volume takes the space back when the process ends however it ends —
including a crash, which is exactly when an orphaned eighty gigabyte scratch file would be
least welcome. Positional reads and writes throughout, never the file offset, so a capture can
be appending on the simulation queue while playback reads an older frame on another; and the
bytes of a frame land before the frame record that describes them does, so a reader never sees
a frame whose positions are not there yet.

If the file cannot be opened at all the capture keeps going in memory and says why. Running out
of address space is a worse outcome than running out of disk, but resampling a run somebody
waited hours for is worse than either.

`--qa` checks the thing that matters rather than the mechanism: **the interval between frames
must not change when the budget binds.** Thinning doubled it. That check would have failed on
every version of this before today, and passes at 0.379 then 0.378 Myr.
