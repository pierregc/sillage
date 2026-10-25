# A float cannot count past sixteen million, and the tree was counting with one

A run of three quarters of an hour died with a segmentation fault fifty gigabytes into
nothing, with its take still in memory and nothing written. The whole worker pool was in
`BarnesHutTree.accumulate`, the simulation thread waiting on it in `joinTree`, and the faulting
read reconstructed exactly: `x13 + 4 * x3`, a four-byte array indexed at 1 024 254 943. That is
meant to be a particle number.

**`BHNode` stored its range as `Float(start)`.** Thirty-two bytes is the right size for a node
and packing two integers into float slots is the right way to get there — but they have to be
read back as integers, and a float stops counting exactly at 16 777 216. Past that a leaf start
rounds to the nearest even index. Measured on a tree over 17.5 million: **139 455 leaves sit
beyond the limit and 69 932 of them, exactly half, come back at the wrong index.** Most of those
land inside a neighbouring leaf and are merely wrong; the one at the end of `order` reads past
it, picks up whatever the allocator left there, and hands it to an unchecked subscript. Which
is a wild address, and only in a release build, and only on a run large enough — seven million
visible particles with live halos is already past it.

The layout is unchanged; the reading of it is exact. `range` and `signedCount` carry `Int32`
bit patterns through `packed.y` and `packed.z`, and MSL reads them with `as_type<int>`.
`aNodeAddressesMoreParticlesThanAFloatCanCount` guards it, and starts by asserting that a float
really does lose the value, so it cannot quietly stop testing anything.

**And the ranges are checked once a build, on every leaf, just before its particles are read.**
The reads after it have unchecked subscripts by construction — that is what makes them fast —
so a bad range there is a crash with no message, an hour into a run. The check rides along in
the parallel leaf pass. A run that has been going for an hour deserves to be told what went
wrong with it.

Worth remembering for the next one of these: **a crash report can be read all the way down.**
The register state gives the faulting expression, not just the line — `pc`, the base register
and the index register together said "four-byte stride, index a billion" before any of the code
had been re-read, and that is what ruled out every hypothesis about races and buffer sizing.
