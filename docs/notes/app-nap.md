# A run stops when nobody is watching it

Left overnight with `caffeinate -i -s` beside it, a run came back in the morning barely
further along than it had been, and the machine was cold. Waking the screen did nothing;
clicking on the window brought it back.

`caffeinate -i -s` keeps the *machine* awake. It says nothing about the display, which sleeps
on its own schedule, and a window on a sleeping display is occluded as far as the window
server is concerned — as is a window behind the lock screen, which is what is actually in
front of it when the display wakes. macOS then treats the process as one with nothing
important to do and App Nap narrows the work queue. The tree build fans out over every core
through `concurrentPerform`; with the queue narrowed, its workers are barely scheduled and the
stepping thread sits in `_dispatch_group_wait_slow` waiting for them. `sample` on the frozen
process: 1676 of 2125 samples on the simulation queue, blocked there.

Measured on a 400 000 particle merger, three minutes either side of `pmset displaysleepnow`:

| screen | Myr/s | steps per 5 s | processor s per wall s |
| --- | --- | --- | --- |
| awake | 0.87 | 21 | 1.50 |
| asleep | 0.21 | 5 | 1.78 |
| asleep, holding an activity | 0.98 | 24 | 0.71 |

The middle row is the shape of it: a quarter of the work for *more* processor time, because
what the process spends it on is waiting. And the last row is faster than the first, since a
run nobody can see draws nothing and leaves the whole GPU to the solver.

The fix is one assertion. `ProcessInfo.beginActivity(options: .userInitiated)` is the
documented way to say the work is user-initiated and must not be napped; the model holds one
for exactly as long as the solver is stepping. `.userInitiated` also holds off idle system
sleep, so a run no longer needs a `caffeinate` beside it at all.

`--soak <particles>` is what made this measurable: it starts a run and writes a line to
`/tmp/sillage-soak.log` every five seconds with the wall clock, the processor time actually
burned, how far the solver has got and whether the window was on a display that was awake.
The processor column is the one that matters — timestamps alone cannot tell a solver that
stopped from a logger that was merely throttled.
