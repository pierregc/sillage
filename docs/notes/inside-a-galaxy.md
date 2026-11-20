# Inside a galaxy (#296, #297, #353)

What the renderer does when the camera goes into a disk, tried on real frames before #297
changes anything: the README's Mice take (2026-11-04 scene-0067, 8 M visible particles on 12 M
of dark matter, no light tracers) with `looks/photograph.look.json`, at frame 48 (disks whole,
"calm") and frame 232 (first passage). Frames, sheets and clips are on the branch
`assets/296-inside` under `docs/spikes/inside/`; the throwaway code on `spike/296-inside-code`.

**In short.** From inside, today's renderer draws bokeh: every particle within a few kpc is
capped at the kernel ceiling and keeps all its light, and the near plane at 1 kpc cuts the disk
with a straight edge and leaves a black hole ahead of the eye. Handing the light of the near
particles to **point stars** (each particle drawn as a small cluster of stars) is what turns the
same 8 M particles into a star field you fly through; with the near plane at 1 pc, a fade before
it, depth slabs placed from the eye and an exposure trim of 0 to 5 stops, the dive from the
photograph into an arm holds together. The settings recommended for #297 are at the end.

## The tool

`sillage-render inside <job.json>` (branch `spike/296-inside-code`, not merged) draws a take at
any captured position through any camera, with the variants below as `InsideSettings` on the
renderer and look trims, and writes each frame with its measurements; `clips` draw camera paths
in a disk's own axes (anchored on the galaxy, optionally carried round at the disk's angular
rate at a radius) through ffmpeg, with an exposure per frame and optional sub-frames.

Views, from the export's framing into an arm of the larger disk (R 9 kpc at frame 48, R 6 at
232, the crest of the face-on density): `photo` (the export), `above40` to `above1` (kpc above
the disk's plane, looking down at 35°), and in the plane 50 pc above the arm: `along` it,
toward the `bulge`, at the `companion`; `inbulge`, 2 kpc from the centre. 4K, supersampling 2.

## Variants

1. as drawn today;
2. near plane at 1 pc;
3. 2, with a capped kernel keeping the surface brightness of its own size (`spread × (cap /
   raw)²`) and a fade over the last 3 kernel lengths before the near plane, stars and dust;
4. 3, with point stars: k points scattered in the kernel from a hash of the index, cross-faded
   in from half the cap to the cap, sharing the light the splat gives up, at the star's own
   distance (inverse square, each star capped at a half-float-safe value);
5. 4, with the four dust slabs from the eye, log-spaced at 0.3, 1 and 3.3 kpc;
6. 5, with an exposure trim per view: brightness × 2^−s and stretch × 2^−1.46 s (the ratio
   contemplation's closeness trim uses), s chosen on 4K frames for a mean luminance near 0.16
   with under 2 % clipped.

![Calm, every view and variant](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/matrix-calm.jpg)

![Calm, 1:1 crops](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/matrix-calm-crops.jpg)

What each does, on the frames:

- **Outside nothing changes** (photo to `above20`): variants 2 and 3 draw the same frames as 1
  (0.1 % of pixels by more than 8 levels at 20 kpc); from 8 kpc the cap law of 3 starts to dim
  the nearest capped kernels (26 % of the pixels).
- **2, the near plane at 1 pc**, fills the blind zone, and the flare shows: in the plane 56 to
  80 % of the frame's light comes from particles nearer than 1 kpc, as big bright blobs, and
  dust grains near the eye turn into black disks (variant 2, `bulge` and `companion`).
- **3** ends the flare (the near light falls to 13 to 39 %) and the black disks; what is left
  is a soft veil of capped kernels at the right surface brightness. It is the cheapest fix and
  it reads as fog.
- **4** turns the veil into stars: in the plane the frame is a dense star field with dark dust
  between, toward the bulge the bulge glows behind the lane at the horizon, as the Milky Way does
  from inside. Point stars keep the light (76 % of it from within 1 kpc in `along`, which is the
  inverse square law), so the frame is two to four times too bright until 6.
- **5** keeps the dust ordered in depth from inside (the lanes in front of the bulge break into
  patches at the right distances). With the last boundary at 3.3 kpc a lane 5 to 9 kpc away
  falls in the last slab with the bulge behind it and is halved: boundaries at 0.3, 1.5 and
  7.5 kpc (`slab5` below) keep it.
- **6** brings every view to a photograph's exposure. The trims picked: 0 down to `above8`,
  1 at 3 kpc, 2 at 1 kpc, 2 to 3 in the plane at frame 48, 4 to 5 in the plane at the passage
  (denser, brighter), 5 in the bulge. Five stops between two views a few seconds apart in a
  flight: **an automatic exposure is needed**, not hand trims.

Measured (GPU time of the timed frame, nothing else on the GPU; light share and painted pixels
worked out on the CPU from the positions and smoothing the frame was drawn with, before dust):

| view, frame 48 | variant | GPU ms | mean | clipped % | in view | capped % | light < 1 kpc % | star points |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| photo | 1 / 4 | 115 / 175 | 0.01 | 0.0 | 7.0 M | 2 | 0 | 9.7 M |
| above8 | 1 / 4 | 174 / 294 | 0.20 | 1.0 | 2.7 M | 6 | 0 | 14.7 M |
| above3 | 1 / 4 / 6 | 91 / 156 / 151 | 0.21 / 0.26 / 0.12 | 0.0 | 0.39 M | 43 | 0 | 9.9 M |
| above1 | 1 / 4 / 6 | 31 / 73 / 74 | 0.23 / 0.50 / 0.17 | 0.1 / 0.2 / 0.7 | 0.09 M | 98 | 1 | 2.7 M |
| along | 1 / 2 / 3 / 4 / 6 | 39 / 43 / 41 / 84 / 87 | 0.08 / 0.14 / 0.06 / 0.46 / 0.14 | 0.0 / 0.5 / 0.0 / 1.4 / 1.5 | 0.09 M | 77 | 0 / 80 / 39 / 76 / 76 | 2.8 M |
| bulge | 1 / 2 / 3 / 4 / 6 | 268 / 266 / 273 / 470 / 446 | 0.21 / 0.27 / 0.16 / 0.42 / 0.19 | 0.6 / 0.8 / 1.3 / 1.4 / 1.1 | 2.4 M | 15 | 0 / 22 / 1 / 18 / 18 | 33 M |
| inbulge | 1 / 6 | 158 / 286 | 0.86 / 0.09 | 58.8 / 0.5 | 0.6 M | 61 | 0 / 4 | 18 M |

At the passage the same views are denser: `bulge` and `companion` take 430 ms today and 840 ms
with point stars (45 M star points at k 32). Painted pixels hardly change between variants
(the splats keep their size): 3 to 40 G accumulation pixels a frame, the most in the bulge views.

## Point stars, tested hard

On variant 4 then at each view's exposure (6), 1:1 crops of the 4K frames: k 8, 32, 128; equal
shares against rank^−1 (a few stars carry most of the light); the particle's colour against
colours drawn around its population's (old about 4800 K, young 9000 K, ±0.8 stop in temperature);
spread 0.5, 1, 2 kernel lengths; 1, 1.5, 3 px; the cross-fade from half the cap (variant 4),
from 0.15 to 0.4 of it (`mid`) or from 0.05 to 0.2 (`far`, the whole near arm turns to stars);
an inverse-square floor of 20 pc; and `combo` (k 128, rank^−1, colours, `far`).

![Point stars at the view's exposure](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/stars2-crops-a.jpg)

![Point stars, continued](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/stars2-crops-b.jpg)

- **k** sets the texture: 8 gives big clumpy stars (each particle reads as a little cluster),
  128 a fine dense field that reads as a galaxy of stars rather than of clusters. Cost goes with
  k: in `bulge` at frame 48, 312 ms at k 8, 470 at 32, 2 250 at 128 (every particle drawn k times
  and culled in the vertex stage; #297 should list the near particles on the GPU first).
- **Shares**: rank^−1 is what makes it look like a photograph of stars, a few bright ones over a
  crowd of faint ones; equal shares look uniform.
- **Colours** drawn around the population add the orange and blue-white mix of a real field;
  the particle's own colour is flatter.
- **Spread, size, inverse-square floor**: small differences at 1:1; 2 kernel lengths blurs the
  dust's edges, 3 px thickens the field. Kept at 1 length, 1.5 px, 1 pc.
- **Where the cross-fade starts**: `far` removes the last capped blobs between the stars.
- **Outside, the cap is the wrong key.** Keyed on the kernel's size on screen, point stars also
  replace the large kernels of the sparse outskirts seen from 20 to 40 kpc: there the disk's
  edge turns from a smooth glow into sprinkled stars (24 % of the pixels of `above20` change by
  more than 8 levels). Stars belong to the near field: the recommended settings add a distance
  window (all stars nearer than 3 kpc, none beyond 8), and with it the photograph and the
  approach draw as today: with the window and today's slabs, the photograph and the views from 40
  and 20 kpc are the same frames within rounding (under 1.3 % of pixels by more than 8 levels);
  from 8 kpc the cap law starts to dim the nearest capped kernels (26 to 32 %), which is where
  the entry begins.
- **Eye slabs belong to the near field too.** Placed from the eye for every camera, they put a
  whole galaxy seen from 20 kpc or more in the last slab, where soft slabs dim each star by all
  of it rather than half: the lanes of the photograph darken (mean level 61 against 51 at
  20 kpc). #297 should keep today's slabs around the aim point outside and slide the boundaries
  to the eye's layout as the camera comes within a few kpc of a disk; soft slabs make the
  boundaries free to move.

![Recommended settings on every view](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/matrix-recommended.jpg)

What #297 could build, at each view's exposure: today, A a veil (variant 3, no stars, darker
here because it is exposed as B and C are; an automatic exposure would lift it), B simple stars
(variant 6) and C rich stars (the recommended settings). Full 4K frames of six views, today and
C, are in `frames/` on the assets branch.

![What #297 could build](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/choice-whole.jpg)

![The same, 1:1 crops](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/choice-crops.jpg)

![The approach: the photograph must not change](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/approach-crops.jpg)

## Other settings, on variant 6

![Smoothing, ceiling, column smoothing, web, slabs](https://raw.githubusercontent.com/pierregc/sillage/assets/296-inside/docs/spikes/inside/extras.jpg)

- **Smoothing 1** against the look's 2.18: the dust breaks into dark blotches everywhere. Keep
  the look's.
- **Kernel ceiling** 64 / 92 (the look) / 128 / 256 px: a higher ceiling draws fewer point stars
  and bigger dust blotches, and costs more (186 against 74 ms in `above1`); 64 is a little
  smoother and cheaper. Keep the look's.
- **Column smoothing** 0 against 300: no visible change inside; nothing to do.
- **Dust web** off: from 3 kpc above the lanes lose their lace and turn to grains; inside it
  changes little. Keep it.
- **Slabs** at 0.3 / 1.5 / 7.5 kpc keep the lane in front of the bulge; at 0.1 / 0.5 / 2.5 the
  far lanes are halved again.

## Motion

Clips in 1080p at 30 fps, 5 s, on frame 48 unless said. Side-by-side copies are on the assets
branch (`compare/`): the dive, the glide, the turn, the pass, the speeds, the 10 s dive from the
photograph (today against C) and time flowing slowly.

- **From the photograph into the arm** (`6-photo-dive-v1-vs-C`, 10 s): the photograph is the
  export's frame, the disk comes up, the lanes pass, and the camera ends 50 pc above the arm among
  its stars; today it ends in bokeh.

- **Dive from 20 kpc into the arm**: today ends in bokeh, and the near plane draws a straight
  line across the disk as it enters it; with the variants the disk comes up and turns into stars
  without a seam (exposure ramped from 0 to 3 stops with the height).
- **Glide 0.5 kpc above the arm, turn in the plane**: point stars hold up in motion; nothing
  pops at the near plane (the fade), and no splat pops at the frame's edge at these sizes.
- **The #295 flight's defects** (Pierre, 2026-11-19: cut galaxies, sweeping, streaks) are the
  near plane and the slabs. A pass 4 kpc above the disk as that flight makes it shows them: with
  the slabs around the aim point the lanes in front of the bulge fade out as the camera moves
  (the slab that holds them slides over the bulge's), the frame washes out without a trim, and
  the near plane cuts the companion's disk with a straight edge. With the slabs from the eye the
  lanes stay put; soft slabs (a grain spread over a slab's depth, a star behind the share of
  each slab in front of it) remove the last switch when a boundary crosses a lane, with no
  visible change on stills.
- **Speed.** A star at distance d crossing the frame moves about 1 750 × v / d px a frame in
  1080p (v in kpc a frame): 2 pc a frame is smooth, 20 pc a frame makes the nearest stars jump
  tens of pixels, 100 pc a frame turns the field to noise. Eight sub-frames turn that into
  streaks, a warp-speed look that reads well; **motion blur is needed for anything faster than
  about 10 pc a frame near matter**, or the camera slows down as it nears it.
- **Time flowing slowly** (`7-time-flowing`): the glide again with the take's time at 1/10 of
  the export's speed (12 Myr in 5 s) and 1/100. Fixed in the galaxy's frame, the camera sees the
  disk turn under it at about 200 km/s (2.4 kpc in those 5 s at 1/10) and the stars stream past
  as in a fast glide; carried round at the disk's angular rate at 9 kpc, the arm drifts slowly
  as the material flows through it, and at 1/100 the frame is a still that breathes. The take
  keeps one frame in four and draws the others on a cubic (3.2 Myr apart here): with the camera
  parked, the change from frame to frame is flat, with no peak where a stored frame is crossed.
  It is not small: at 1/10, 8.1 % of the pixels change by more than 24 levels each frame, the
  nearest stars darting (a dispersion of 30 km/s is about 2.5 pc a frame, tens of pixels for a
  star 100 pc away), so near matter time wants 1/100 or slower. With the stars' scatter radius
  fixed rather than following the smoothing, which is read off a tree built again every frame
  and jumps, it is 5.8 %: a quarter of the shimmer is the kernel length. #297 should scatter the
  stars and cross-fade them on a length that is smooth in time (fixed per particle, or the
  smoothing eased). Seen from 0.5 kpc above the plane, the dust web's lace is almost edge on and
  draws long straight streaks that slide as it turns: the web should fade out near a disk's plane.

## Recommended for #297

**Pierre chose C on 2026-11-20** ("rich stars, the best rendering"), with the goal for #297:
the most immersive rendering, as if travelling inside the galaxy in a transparent spaceship.
#297 builds what follows.
The settings the `R` frames and clips use; neutral defaults, flights only.

- **Near plane 1 pc** for flight cameras, every other camera keeps 1 kpc.
- **Capped kernels keep the surface brightness of their own size**, stars and dust, and **fade
  over 3 kernel lengths before the near plane**.
- **Point stars**: k 128 (64 if cost bites), shares rank^−1, colours drawn around the
  population's, scattered over 1 kernel length, 1.5 output px, cross-faded in from 0.05 to 0.2
  of the cap, **within a distance window** (all of them nearer than 3 kpc, none beyond 8), each
  star capped. The near particles listed on the GPU first, then one instanced draw: at k 128 the
  brute-force spike costs 2.3 to 2.5 s a 4K frame in the bulge views of frame 48 (0.45 s at
  k 32, 0.27 s today) and 0.3 to 0.4 s in the arm views (timed while other sessions' tests
  shared the GPU). Scatter radius and cross-fade on a length smooth in time.
- **Dust slabs from the eye** inside, log-spaced at 0.3, 1.5 and 7.5 kpc, **soft**; around the
  aim point as today outside, the boundaries sliding from one layout to the other on the way in.
- **Automatic exposure**: the frame's mean luminance held near 0.16 by a trim in stops
  (brightness × 2^−s, stretch × 2^−1.46 s), eased over about a second; 0 to 5 stops on this take.
- **Motion blur** by sub-frames for fast passes, or a speed limit near matter; time at 1/100
  or slower near matter.
- **The dust web fades out** near a disk's plane.
- Kernel ceiling, smoothing, column smoothing and the dust web: the look's.

## What #297 built

A flight's frames are drawn with all of the above (`docs/notes/flights.md` has the file's
`inside` block and its defaults, which are the settings of the last section). What was built as
recommended is not told again; what follows is where the building found something else, and what
it costs.

**One text, two libraries.** The passes are the renderer's own with `#if defined(SILLAGE_INSIDE)`
around what the inside of a galaxy adds, compiled by Metal into a library of its own the first
time a flight is drawn, as #339 did for the population widths: with fast math, code that never
runs still moves the roundings of a frame drawn without it. The frame's `InsideUniforms` lie
behind its `SplatUniforms` in that library alone. The CUDA engine has one library and compiles
the same lines into it (below). Checked: with the symbol
undefined the shader's text is main's but for comments, and three frames of the Mice's export in
`photograph` and in the README's look are the same bytes from this branch and from main.

**The photograph is the export's.** Everything is keyed on a distance, and past it nothing is
added:

- the capped kernels' law and the stars apply in the near field (view depth under 3 kpc, fading
  to nothing at 8), the law too, which the spike applied everywhere: a kernel of the sparse
  outskirts seen from 180 kpc is capped as well, and dimming it changed the photograph a little;
- the slabs are placed by the very expression every export uses until the eye comes within 6 kpc
  of matter, then slide to the eye's layout (wholly at 1.5 kpc), their softness with them. Soft
  slabs for every camera would have changed the stars past the stack's far end, which stand
  behind half of the last slab when hard and all of it when soft;
- the automatic exposure only darkens, never on the look's own camera, and its target is raised
  to the photograph's mean when the photograph is brighter;
- a look that measures its exposure (#340) measures it on the flight's look keys.

On a 20 000 particle disk seen from 100 kpc, a frame set to the inside of a galaxy is within one
level in 255 of the same frame without it (`InsideRenderTests`).

**"Near matter" is measured**: the distance from the eye within which a ten-thousandth of the
drawn particles lie (`Nearness`, 800 of 8 M: a histogram of the squared distances by their float
bits, then the exact rank in the one bin: 6 ms a frame at 8 M). A count cannot change
faster than the eye moves, so what is keyed on it, the slabs' layout and the number of renders a
frame is averaged from, never jumps. The disks the take tracks were the other candidate; a tidal
arm or a bridge is not one of them.

**The dust web is not removed near a disk: its lace flattens.** The issue asked for the web to
fade out near the plane. Without the web the dust is its grains again, capped at the kernel
ceiling: black blotches a hundred pixels wide from one to three kiloparsecs above a lane. What
draws the streaks is the lace alone, a pattern lying in the mid-plane whose walls run to the
horizon like a tiled floor. So the web keeps carrying the dust, as the even layer it makes of the
grains, and the lace's contrast goes to nothing as the eye comes within 10 to 3 kpc of the disk
(its plane out to seven scale lengths), the rays that graze the plane losing it first, from 20 kpc.
From 3 kpc down a lane is a soft dark band with the stars coming out in front of it.

**A splat that has given all its light to its stars is not drawn**, nor a particle faded out at
the near plane. The spike drew them black, at the ceiling's size; inside an arm they were most of
the pixels painted.

**Only the stars a particle's light has reached are drawn, the brightest first.** The spike drew
all 128 stars of every particle in the near field, each at the share of the light the cross-fade
had given the stars so far: a particle at 6 kpc, a tenth of the way, cost 128 points that showed
nothing. A particle now draws its first `128 × w` stars, w being how far its light has gone over
(the kernel's size on screen times the near field's window), and its splat keeps the light of the
others, a closed form of the partial sum of the shares (`insideShareSum`, within 1 % of it). A
particle wholly turned draws all of them, so the inside of an arm is the frame Pierre chose; on
the way in the count of stars drawn falls by 2.6 (122 M to 47 M points in an arm at 452 Myr) and
the frames are the same: 0.01 % of the pixels differ by more than 24 levels.

**The stars are listed on the GPU in the order of their particles' indices**, eight to an entry:
each block of 1 024 particles counts its entries, one thread turns the counts into each block's
place in the list and writes the draw's arguments, each block writes its entries, and one indirect
draw of eight instances lays the stars (`insideCount`, `insideOffsets`, `insideFill`,
`pointStarVertex`). An atomic counter would have listed them in whatever order the threads ran,
and the half-float sum of a pixel's stars would then round differently from one drawing to the
next: the same flight drawn twice is the same bytes (`ExportTests`). The list holds 16 M entries,
128 M stars, more than a frame can afford.

**Kernel lengths are eased in time** (`EasedSmoothing`): trees are built at the take's captured
frames only, and a moment between two takes the lengths between theirs. A frozen flight builds
one or two trees for the whole freeze; with time flowing at a hundredth of the take's speed a tree
is built every hundred frames, where the export builds one a frame.

**Motion blur: streaks for the stars, the mean of a few renders for the rest.** The spike
averaged eight 8-bit pictures a frame, and a star that crosses thirty pixels in a frame came out as
a row of eight dots. A point star is now drawn as the streak it leaves: the vertex stage projects
it through the render's camera and through the next one, the point grows to hold the line between
the two, and the fragment draws the star's own profile across that line, its light spread along
it. A frame's renders (one for every four pixels the matter at `Nearness` crosses while the
shutter is open, eight at most) each draw their share of every streak, end to end, and are
averaged down to the picture's size before bloom and the tone curve (`insideResolve`, which also
holds every sample under what a half float carries: a few near stars on one pixel would otherwise
sum to infinity, and the bloom of an infinity is a NaN). A camera at rest, past the near field or
on the look's camera draws the frame once. Only the camera moves between a frame's renders; the
take's time is the frame's.

**Sizes are output pixels**, as the look's are. The 4K frames Pierre chose on have stars half as
wide, against the frame, as the same flight drawn in 1080p: the demo is drawn in 4K and scaled down.

### What it costs

The Mice take (8 M drawn), `photograph`, the GPU alone on a timed run, one render of each view
through `export --flight-keys`, which prints them. At 335 Myr, the views of the first table
(frame 48), in 4K with supersampling 2, against what #296 measured for the frame as drawn before
and for C by brute force:

| view | before (#296) | C, brute force (#296) | #297 | 1080p |
|---|---:|---:|---:|---:|
| the photograph | 115 ms | | 138 ms | 79 ms |
| 20 kpc above | | | 246 ms | 113 ms |
| 8 kpc above | 174 ms | | 221 ms | 103 ms |
| 3 kpc above | 91 ms | | 143 ms | 86 ms |
| 1 kpc above | 31 ms | | 47 ms | 33 ms |
| in the arm, along it | 39 ms | 300 to 400 ms | 94 ms | 58 ms |
| in the arm, at the bulge | 268 ms | 2 250 to 2 500 ms | 360 ms | 175 ms |
| in the arm, at the companion | | | 217 ms | 121 ms |

Up to 20 M point stars a render there. At the passage (452 Myr, the demo flight's keys) a render
takes 160 to 480 ms in 4K and 110 to 215 ms in 1080p, with up to 67 M stars. So a frame with
the eye inside a disk draws in 4K at 8 M in under half a second, against 2.3 to 2.5 s for the
spike's C; the far frames cost a fifth to a half more than before (the inside library's text,
and the column and web passes drawn through it).

A flight costs its renders: the demo, 84 s in 1080p (2 521 frames), took 34 minutes with time
frozen and 43 with time flowing, 11 800 renders, 4.7 a frame, and before them the automatic
exposure's pass over the flight, 337 moments of two to four draws. The same flight in 4K is about
four times that. A still at a key is a fifth of a second.

### Not built

- A slider in the style editor: the settings are the flight file's, where a flight's other
  choices are.
- The CUDA engine's side (#347).
- Splats popping at the frame's edge were looked for again in the demo flight: the change from
  each frame to the next has no peak over its 84 s (the mean absolute difference of two frames
  never passes twice the median of the six around it), and near the eye there is nothing left to
  pop, a particle wholly turned to stars drawing no splat. A splat of the 3 to 8 kpc shell still
  leaves the frame when its centre does; at that distance it is faint against the stars in front.

**What stays a limit of 8 M.** The stars are drawn, not simulated: each particle stands for
about 6 000 suns and its k stars are scattered at random in its kernel, so up close the field
is uniform at the particle's scale (about 50 pc in an arm) and the dust is grains of the same
size. Structure finer than that (a cluster, a filament of young stars, a dust lane's edge) is
not in the take; a frozen visit at a full pass's key frames could show it at 50 M, which Pierre
has set aside.

## Two disks that cross (#353)

Pierre, on #297's frozen flight: where the two disks cross, a galaxy is cut along straight lines
and "disappears where it comes too near the other", when he expected the stars of one to pass
between the stars of the other. Frames 440 to 580 at 30 a second, the camera 20 to 40 kpc above
the pair. The sheets are on the branch `assets/353-crossing-disks` under `docs/spikes/inside-353/`.

**The cut is in the matter, not in the drawing.** Frame 550 four ways: as the flight draws it;
with `dustStrength` 0, where every edge is still there; as plain points coloured by galaxy (a
look with `"plain": true` and a palette `colour` per galaxy: one point a particle, added, no
kernel and no dust); and the larger galaxy's points alone (the companion's colour black). The
whole side of the larger disk toward the companion is missing from its own matter, along the same
straight edges. The take's positions read without the renderer, as a histogram in the disk's
axes, give the same shapes.

![Frame 550: as drawn, without dust, the matter by galaxy, galaxy 0 alone](https://raw.githubusercontent.com/pierregc/sillage/assets/353-crossing-disks/docs/spikes/inside-353/cause-550.jpg)

**Why.** The flight freezes at 452 Myr, and that is the closest approach: the nuclei are 12.9 kpc
apart from 449 to 452 Myr (the scene file planned 445). The orbit lies 5° from the larger disk's
plane, so from 430 Myr on the companion's nucleus goes through that disk, in its plane, 13 to
16 kpc from its centre. What lies within 6 to 8 kpc of its track is pulled off its orbit and
gathered into a ridge, which is the straight edge; the larger galaxy's nucleus passes 6 kpc
above the companion's disk and bends its near side into a lobe. Read off the take: a patch of the
larger disk 10 kpc out on that side turns about its centre at 277 km/s at 427 Myr and at 443 at
455, rising smoothly as it passes 4 to 10 kpc from the companion's nucleus, about
5 700 (km/s)² a kiloparsec, the size of that nucleus's pull (a Hernquist potential of
4.3 × 10¹¹ suns and 4.2 kpc: 6 300 at 13 kpc, 10 700 at 9). Past 8 kpc on that side a 30° sector
holds a fifth to a quarter of what it held at 436 Myr, and the next one twice as much. Nothing in the solver
does this but gravity: the disk cooling closes 5 % of a gap in the same time.

![From above the larger disk, 420 to 452 Myr](https://raw.githubusercontent.com/pierregc/sillage/assets/353-crossing-disks/docs/spikes/inside-353/history.jpg)

At 420 and 430 Myr the two disks do go through each other whole, as Pierre pictured it.

**Where the disks cross whole, the dust does cut.** Nothing above changes at 452 Myr. Frozen at
430 instead, the same frames show two things that are the drawing's, both in the dust:

- The part of the companion's disk that has gone through the larger disk's plane ends on a sharp
  tip. Without dust it carries on behind the disk, faint. Where it vanishes, 10 to 14 kpc from
  the larger galaxy's centre, the dust in front of it has an optical depth of 1.7 along the line
  of sight (median; 0.8 to 6), which lets 13 % of the light through in V, and 1.1 over the outer
  disk at large, when the inner 4 kpc are at 0.08 (the frame's dust target, `--dump-targets`).
  The look's dust is thickest in the outer disk, where a real spiral's is thinnest: from 280 kpc
  that reads as lanes, from 20 kpc with another disk behind it is a screen.
- Where the companion's carried dust shares a slab of a pixel with the larger disk's, the
  companion's web serves both (`webResolved`: the tags keep the later galaxy), so the larger
  disk's lace turns to an even layer inside a scalloped edge, the outline of the companion's
  outermost grains in the coarse tag target. The stack around the aim point also holds all of
  that frame's dust in its last two slabs (31 % and 67 %), so the two disks are hardly ordered.

![Frozen at 430 Myr: the scalloped edge, and the dust's optical depth](https://raw.githubusercontent.com/pierregc/sillage/assets/353-crossing-disks/docs/spikes/inside-353/dust-430.jpg)

Both are the dust of a flight, which #354 and #356 rework: nothing is changed here, and the
numbers are on those issues.

**Any second of a flight as a still.** `export --flight <name> --flight-keys <dir> --flight-at
14.67,18.33` draws those seconds instead of the keys, one render each at its own exposure: four
frames of this flight in ten seconds, where a clip of one frame took a minute and a half. Every
sheet here is drawn with it.

**What is left is the flight's choice** (#358): keep the freeze at the closest approach, where
the cut is the encounter itself; freeze near 430 Myr once the dust lets one disk show through
another; or let time flow from 425 to 452 Myr over the pair, so that the cut is seen being made.

![Frames 440 to 580 frozen at 452 and at 430 Myr](https://raw.githubusercontent.com/pierregc/sillage/assets/353-crossing-disks/docs/spikes/inside-353/freeze-452-430.jpg)

## On the CUDA engine (#347)

The CUDA engine draws the same frames from the same text. Every guard reads
`#if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)`: Metal still compiles the lines only
into a flight's library, and the other engines always have them. A frame that is not inside a
galaxy sends `InsideUniforms(outside:)` behind its `SplatUniforms`: a near field that ends
before it starts, no star, no fade, no slab from the eye, and the per splat ceiling of 6e4 left
out, so its fixed point light is the one it had (the four reference frames and
`aPixelSaturatesRatherThanWrap` hold it).

The bodies of `insideCount`, `insideOffsets`, `insideFill`, `pointStarVertex`,
`pointStarFragment` and `insideResolve` moved into shared functions (`insideCounted`,
`insideOffset`, `insideFilled`, `pointStar`, `starRadius2`, `insideResolvePixel`); the Metal
entry points only call them. On CUDA:

- `SC_RENDER_POINT_STARS` runs the three listing kernels, reads the count back, and draws eight
  instances an entry through the rasteriser's rules, large stars by the second way, as a splat.
  `sc_render_stars_listed` gives the count. The list holds at most 16 M entries.
- `sc_post_inside_resolve` adds one render's share to the resolved picture, with the 6e4 clamp.
- `CUDARenderer.inside` takes the frame's `InsideFrame`; `picture(cameras:)` draws one render a
  camera and averages them. A frame drawn in parts (the full pass's batches) leaves the inside
  out, as Metal's does.
- `CUDATakeStills.flightStill` draws a moment of a flight: the camera and the moment
  `Flight` gives, the smoothing lengths eased between the two captured frames around it, the
  nearness, and the exposure from the pre-pass of `TakeExport.measureTrims` (a small frame
  every half second of the flight, cached on the first call).
  `sillage-cuda still <take> --look <look> --flight <file> --seconds 0,2.5,9` writes them as
  `<preset>-flight-<seconds>s.png`.

`CUDAInsideTests` holds on the CPU target what `InsideRenderTests` holds on Metal, and that the
two ways of laying a star give the same bits. `Tests/Fixtures/engines/frames/inside.flight.json`
is a flight into the fixture take's disk; the workflow draws two of its frames.

Checked on the Mac (#369): the move left Metal's bytes alone. Three moments of the Mice's
`dive` flight (23.3, 33.3 and 36.8 s, 1920 x 1080, `photograph` and `readme-v4`, 261 pc from
matter and up to 19.8 M point stars) and three frames of its video at 33.3 s (seven renders a
frame) are the same bytes from main and from the commit before #347, and `InsideRenderTests`,
`KernelSourceTests` and `EngineFixtureTests` pass. Two moments of `inside.flight.json` are now
among the reference outputs, and `sillage-cuda check` holds the CUDA engine to them
([one-kernel-source.md](one-kernel-source.md#the-frames-from-inside-a-galaxy-369)): within
60 dB of Metal's on the CPU target, not yet run on an NVIDIA GPU (#283). The CUDA engine has no
flight video export; the full pass draws no flight on either engine.
