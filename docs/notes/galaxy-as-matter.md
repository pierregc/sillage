# Making a galaxy read as matter rather than as a graphic

Eight changes asked for at once, and the useful thing to record is which of them were what they
looked like and which were something else underneath.

**Dust that stands in front of things.** The dust attachment carries four channels and they are
four slabs of view depth, not four colours. Dust is drawn first and writes into the slab it
sits in; stars are drawn second, read the attachment back out of tile memory, and are dimmed by
the slabs in front of their own plus half of their own. Two draws over the same buffer, each
culling the other's particles in the vertex stage.

The first version of this measured as doing *nothing*: mean absolute difference of 0.06 on a
mean of 16.6, with the ordering switched on. The mechanism was right and the opacity was the
problem — at the old dust strength the optical depth of a whole column was about a tenth, where
`exp(-tau)` is `1 - tau` and it makes no difference at all where along the line of sight the
dust stands. There was nothing to order. At an optical depth near one the same comparison gives
a near-to-far brightness ratio of 1.230 unordered against 1.127 ordered, and 1.3 % of pixels
moving by more than eight levels. So the fix was opacity — concentrated into the lanes, not
spread over the disk — and the ordering is what makes raising it look like lanes instead of
like fog.

**The magenta was a light-weighted age of 300 megayears.** The disk came out magenta-cored and
the obvious suspects were all wrong: not the HII colour, not the galaxy tint, not the tone
curve. A blackbody cannot be magenta — its green sits between its red and its blue at every
temperature — but a *sum* of a hot population and a cold one can, and easily: green stays near
one across the whole range while red and blue swing, so red plus blue with nothing between them
is what a mixture gives.

The mixture was there because `sampledFormation` biased an arm's draw with `pow(roll, 7)`, a
constant tuned against a colour law that no longer existed. With a light per unit mass that
really does fall steeply with age, that put the disk's light-weighted age at 396 Myr in the
middle and 297 Myr three scale lengths out — a young blue disk everywhere, no radial colour,
laid over a red bulge. Replaced with a declining-exponential star formation history whose
timescale grows outward, which is what inside-out formation means: 2678 Myr at the centre and
1617 Myr at three scale lengths, and the bulge carrying 60 % of the core's light instead of
27 %. The core measures R206 G166 B159 against a disk at R65 G59 B76.

Two other hand-set numbers turned out to be double-counting the same thing. The HII regions
carried a factor of five on their brightness from a time when nothing else made a knot bright;
with the synthesised population giving a twenty-megayear knot ten times the light per unit mass
of a gigayear disk, the two together had knots carrying 57 % of a disk's light. And the
metallicity gradient — metal-rich in the middle, metal-poor at the edge — was missing entirely,
which is half of why a real galaxy has a warm core.

**The white core was the stretch, not the exposure.** `log(1 + E s) / log(1 + s)` is normalised
so an energy of one lands on one, and a bulge is two orders of magnitude above its disk, so it
came out of the stretch at three and everything over one was flattened onto white by the curve
after it. A plateau with a hard edge, exactly where the most interesting colour in the frame
is. Replaced by a curve with a white point applied to the *luminance*, with the pixel scaled by
the ratio so hue survives the shoulder, falling back to the filmic curve only where preserving
hue would clip a channel.

**A thick component has to be a spheroid, not a thicker disk.** The soft outer edge and the
material off the plane come from one population — thick disk and inner halo, twelve per cent of
the stars, old and metal-poor. Getting it to *stay* took two wrong tries, both measured:

- Cooled along with the thin disk, its median height fell from 0.91 kpc to 0.32 and its outer
  radius from 25 kpc to 17 in three hundred megayears. Dissipation stands in for gas cooling
  and there is no gas up there, so it is excluded by component now — which is what the new
  `outskirt` component is for.
- Sampled as a disk four and a half times as thick with the vertical dispersion scaled by the
  square root of that, it *still* fell in: 0.66 kpc to 0.17 over six hundred megayears. The
  scaling rests on the sheet relation between height and dispersion, which is a statement about
  a thin self-gravitating layer; out where these stars live the vertical force comes from the
  halo and the sheet formula underestimates it badly.

Sampled instead as a flattened spheroid with an isotropic dispersion tracking the circular
speed and a slow net rotation — which is what a stellar halo is — it holds: median height 1.69
kpc settling to 2.85 by 150 Myr and flat from there to 600, outer radius stable near 33 kpc.

**The light and the matter disagreed about where the arms were.** The sampler laid particles
on a clean logarithmic spiral of perfect m-fold symmetry while the renderer painted an
irregular pattern over the top, so every asymmetry in the picture was paint and the density
underneath was still something a rotation could repeat. `SpiralPattern` is now the one
description and the shader mirrors it.

What made that possible is the hash. Both sides used `fract(sin(x) * 43758.5453)`, which cannot
agree across a CPU and a GPU: the last bits of `sin` differ, and multiplying by forty thousand
and taking the fraction turns a seventh-digit disagreement into unrelated numbers. Integer
mixing gives the same answer on both, exactly, and only then can the sampler place matter where
the paint says an arm is.

The first cut of the irregularity made every arm *weaker* rather than unequal — each modulator
was a noise term with a mean well under one, so the pattern averaged 0.375 against a clean
one's 0.500 and its ninetieth percentile 0.744 against 0.976, and the picture went soft.
Dividing each modulator by its own mean redistributes an arm's strength along its length
instead of taking a third of it away: 0.443 and 0.883, with the rest of the gap being the clip
at one. Under a quarter turn the pattern now differs from itself by 0.465 at worst, against
1.3e-6 for the clean one.

**What the volume costs.** 16.1 ms a frame against 19.1 at 1.5 million visible particles, so
about a fifth more, nearly all of it the second vertex pass over the whole buffer. The
simulation step at the same size is 275 ms, so it does not decide anything.

Handing each draw only its own particles does not buy that back (#35, branch
`perf/35-split-draws`). A stable compaction into a dust list and an emitter list, drawn
indexed and indirect, left the vertex stage where it was (2.4 ms at 2M, 5.5 ms at 5M) and cost
0.4 to 0.7 ms more a frame, with bit-identical images. A vertex the old test culls exits after
a few loads and one matrix multiply, and the index fetch costs about as much. The double pass
is cheap; do not go after it again without new evidence.
