# Takes on disk

A run costs minutes and eight bytes a particle a frame, so a quarter of a million particles over
five hundred frames is a gigabyte. `RecordingFile` keeps one: the scene, the per-particle
attributes, the frames and the quantised positions. Reopening it is not watching a video:
nothing about how it looks is in the file. Exposure, colour, the telescope and the camera are
all decided at draw time and stay live, and the take plays with no solver behind it.

A take that outlasts its budget spills to disk rather than thinning or stopping — see "A long
capture keeps every frame". The budget is what it holds in memory; the take itself is bounded
by the volume and nothing else.

Three measurements shaped how a take is held, none of them obvious from reading the code. At
1.7 GB captured: growing the buffer a frame at a time peaked at 3.5 GB, because the array
doubles and both copies are briefly resident, so the room is reserved from the budget up front.
Writing copied the whole run into a `Data` first, costing another 1.7 GB, so it goes out of the
take's own memory in bounded pieces. Reading copied twice, peaking at 3.4 GB, so a loaded take
now stays in the mapping instead. Write and read peaks are 1 MB and 4 MB.

Two things the format leans on. The bulk sits at the end so it reads as one run of bytes, and
the file is memory-mapped rather than loaded: a take is often larger than is comfortable to
hold twice. And frames are written field by field rather than as a struct, because a `SIMD3`
carries invisible padding and a file that depends on it breaks on the next compiler.

## A take that holds no disk state

Before #186, `hires` wrote a placeholder for every disk on every frame instead of the solver's
disk states, and a take holding only that is read as holding none. The same run wrote each
disk's disruption correctly in `curves-hires.csv` beside the take, one row per captured frame,
and reading the take reads it from there (#198): each stored frame takes the row of its own
time, each disk in the plane it was laid down in and disrupted as the row says. The plane it
turned to cannot be had back. The painted arms fade with each disk's layer, which reading any
take with disk states measures on its own positions (#210, `painted-arms-fade.md`).

Matching by time does not depend on which captured frames the take kept. On the nine takes of
the library written before #186 (seven at 2 M, two at 8 M, one frame in four kept and the last),
every stored frame lands within 0.0005 Myr of its row, the precision the curves print, which is
row `4k` for frame `k` and the last row for the last frame. A frame with no row within 0.01 Myr
means the curves are another run's, and nothing is read; a take written since #186 carries its
own states and never looks.

Exported, `2026-10-30-b/scene-0031` (2 M) was the same picture as before up to 256 Myr; its
painted arms then faded with the first disk from 258 to 283 Myr and the second from 280 to 290 Myr,
before the closest approach at 308 Myr. Since #210 they fade from 298 to 308 and from 302 to
312 Myr, with the stars' own arms.

## Twenty-one bits an axis (#237)

A take holds each position as three coordinates in the box of every particle drawn that frame.
Up to version 6 each was 16 bits, cut down to the cell below, so the step between two positions
a take tells apart was the box over 65 535; the box is set by the few particles that fly
furthest out, and on the 8 M run below it ends 3 219 kpc wide. Since version 7 each axis is 21
bits rounded to the nearest cell, the three in one 64-bit word: x lowest, y across the two
32-bit halves the GPU reads, then z, the top bit zero. That is eight bytes a particle a kept
frame where six were, for a step 32 times finer, and as far as three axes go in one word. Takes
of versions 1 to 6 read at 16 bits and play as before. `sillage-render hires --take-v6 <path>`
writes the same run's take at 16 bits beside the other, for comparing.

Measured with `scripts/take-quantum.py` on `2026-10-30-b/scene-0030` at 8 M drawn from 2 M
massive, 1 514 frames kept one in four, both takes written by the same run:

| | version 6, 16 bits | version 7, 21 bits |
| --- | ---: | ---: |
| file | 18.46 GB | 24.54 GB, 1.329 times |
| bytes a particle a captured frame | 1.524 | 2.026 |
| box, first to last frame | 797 to 3 219 kpc | the same |
| step, first to last frame | 12.2 to 49.1 pc | 0.38 to 1.54 pc |
| particles sharing a cell, last frame | 22.1 % | 0.03 % |
| most in one cell, last frame | 1 523 | 3 |

The two files differ by exactly two bytes a particle a stored frame. The night plan counts 2.04
bytes a particle a frame, 0.7 % above the measured 2.026.

Drawn at 3840 x 2160 at captured frame 1 288 (1 409 Myr, 85 % of the story, the box 2 860 kpc
wide, so a 16-bit cell is 43.6 pc and a 21-bit one 1.4 pc) with the scene's look and a fixed
camera face-on to galaxy 0's remnant at 6 kpc, where a pixel is 5.8 pc, the two takes differ by
25.4 dB, 55 % of the pixels by more than 8 levels. At 16 bits the dense core carries a regular
lattice of stripes that 21 bits does not
([side by side](https://raw.githubusercontent.com/pierregc/sillage/assets/237-closeups/docs/spikes/237-closeups/closeup-core-side-by-side.png)), and blobs near the camera move by up to
90 px ([the crop that differs most](https://raw.githubusercontent.com/pierregc/sillage/assets/237-closeups/docs/spikes/237-closeups/closeup-side-by-side.png)). The wide shot of the same
frame, with the look's own camera, differs by 56.2 dB, 0.07 % of the pixels by more than 8.

Playback does not change. `Sillage.app --replay <take> 300` at 2560 x 1440, alone on the GPU:
a whole frame takes a median 37.6 ms on the 21-bit take, 37.5 ms on its 16-bit twin and 37.6 ms
on the twin with the application as it was before, the blend 1.8, 1.6 and 1.7 ms, and no frame
waits for a snapshot. Those are second runs; the first, right after the hires, took 53 to 58 ms
for all three alike.

Quantising stays on the CPU. The run spends 26.9 ms a frame on the 21-bit take, every frame
included since the last one offered may end the take, against a median 2.05 s of simulation a
frame: 1.3 %. Moving it to the GPU would save no more than that.
