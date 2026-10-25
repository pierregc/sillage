# Takes on disk

A run costs minutes and six bytes a particle a frame, so a quarter of a million particles over
five hundred frames is three quarters of a gigabyte. `RecordingFile` keeps one: the scene, the
per-particle attributes, the frames and the quantised positions. Reopening it is not watching a
video — nothing about how it looks is in the file. Exposure, colour, the telescope and the
camera are all decided at draw time and stay live, and the take plays with no solver behind it.

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
