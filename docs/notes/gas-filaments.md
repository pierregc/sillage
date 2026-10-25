# Gas in filaments, and which frame a dust lane lives in

Two complaints, and the second took three wrong tries because I kept putting the structure in
the wrong frame.

**The sky was drifting.** A few octaves of noise across the frame, offset by `p.seed` — which
is the *frame* seed. So the whole field translated once a frame and the picture had clouds
sailing across it. Even standing still the patches read as cloud rather than as depth. Gone;
the sky is a flat faint lift again, and what makes a background convincing is the field stars
and the shot noise, both of which were already there.

**The lanes were sausages because they were a smooth painted band**, `1 + 9 * wave^2`, and
`wave` is the broad arm ridge. Three attempts at replacing it, each measured by eye and each
wrong in an instructive way:

- **Filaments from the complexes.** Twenty-six hundred small sheared clumps covered the whole
  inner disk in a fine mat and the arms went out of the dust altogether.
- **Filaments stretched azimuthally.** Shearing a round clump gives an arc at constant radius,
  which is a segment of a *circle*; a disk full of those reads as concentric rings however thin
  they are. Worse near the centre, where the shear goes as one over the radius, so a strand a
  kiloparsec in stretches a quarter of the way round.
- **Filaments along the spiral.** A strand's radius and its angle have to change together at
  the pattern's own pitch, and then it looks like a strand. That works — at t = 0.

**And then it shears away, because a carried filament must.** By two hundred megayears the
sampled lane structure was gone and the disk was a smooth ring: differential rotation wraps
anything the sampler lays down within an orbit. That is not a bug to fix, it is what the
material does.

The resolution is that a dust lane is a **pattern** feature, not a material one. Gas piles up
where the pattern is and flows through it, so the lane stands still while the material crosses
it. Painting the strands is therefore the right frame to put them in rather than a shortcut,
and `laneDetail` does that — two octaves keyed on the wound angle, at rest in the pattern
frame. The sampled filaments stay too, and give the texture a fresh galaxy opens with; the
painted strands are what it still has after a turn.

So the split is now: the arm *pattern* is shared between sampler and shader and has to agree
exactly, while the lane detail inside it is paint alone and says so.

**And a strand has to be bent, on both sides.** Following the pitch exactly gives a perfect
logarithmic segment, and a disk of those is clean, parallel and obviously drawn — combed hair
rather than torn membrane. The sampled strands are warped by a noise keyed on the strand's own
seed and read along its length, so the whole thread meanders together instead of every grain
wandering on its own, and they are lifted out of the plane by another, or a filament is a
ribbon lying flat. The painted ones are *domain-warped*: the wound angle is displaced before
the strands are read off it, which bends each one differently at every radius. Sampling the
noise straight and adding more octaves does not do this — it gives finer parallel threads, not
crooked ones.
