# Contemplation

Full screen, no panel, nobody at the keyboard: `Cinematographer` frames and lights a generated
scene and replaces it with another through a fade. Two paces — brisk, a whole encounter in a
minute, and slow, five minutes to breathe — and the choice drives everything: the oscillator
periods, the length of a shot, how fast the camera turns, the rate of simulated time, and how
close together the galaxies start. Space moves on now; escape leaves.

`--cinema N [slow]` is the only way to check this on a machine with no screen recording, and
**what it measures matters more than that it exists**. The first version ran draws back to back
and reported a healthy median while the real thing visibly stuttered: the cost of a draw is not
what a viewer sees. It now paces itself to sixty hertz and measures *lateness* — and reports
separately how many late frames landed while the screen was actually showing something, since
the swap between scenes happens under a fade already at black.

Level 2. Level 1 has nothing inside it to fly through: painted arms look right from far off and
go flat the moment the camera enters the disk. Self-gravity is what makes structure that holds
up close, and four things together are what make it affordable at sixty hertz.

- **The solver is paced, not run flat out.** It steps only as often as the asked rate of
  simulated time needs, so it takes that share of the GPU and no more. Above capacity the
  pacing stops protecting anything, so the rate has to sit well under it — at 450 k particles
  the solver can do 13 Myr/s and is asked for 5.
- **Fewer, larger steps.** A step costs a tree built across every core as much as it costs the
  GPU, so halving their number is worth twice what tuning the force pass is. 20x to 26x the
  tuned step, which through pericentre sits inside the encounter's own chaotic scatter.
- **A wide opening angle.** 1.0 with the quadrupole, against the usual 0.9: 15.5 ms of force
  pass against the 18.7 the monopole's 0.85 cost here at 450 000 particles, and a closer orbit.
  Nothing here is being measured.
- **Compiled libraries are cached.** `makeLibrary` is a full compile of a source string that
  never changes, and rebuilding the renderer for a new scene did it on the main thread: one
  frame a full second late, every scene. `ShaderCache` holds them for the life of the process.

**Three separate things were called "the stutter", and only the last two were.** The order
they were found in is the useful part, because the first two were measured, fixed, and turned
out not to be it.

- **The galaxies jumped while the starfield glided.** A viewer said exactly that, and it names
  the cause: the background follows only the camera, so a smooth background with jerky galaxies
  is not dropped frames at all — it is the simulation advancing in leaps. Large steps are
  cheaper for the same simulated time and that is precisely the wrong trade here. What the eye
  reads as motion is how *often* positions change, not how far they move. Two steps a second at
  four megayears each became sixty at a fifth of one, by taking small steps and reusing the tree
  across five of them (`treeReuse`) — the build is most of what a step costs, and a particle
  crosses a fraction of a leaf cell in that interval.
- **Kernels are sprites, so their size is squared in fill rate.** Raising the ceiling six-fold
  to hide the graininess of a close shot had particles painting a 384 pixel square each: 27 ms
  of GPU a frame against 1.8 for an ordinary run of four times the particles. Capped in
  absolute pixels as well as in multiple.
- **Full screen on a retina panel is 7.5 million pixels** against 2.3 for a window, and every
  stage — splatting, six levels of bloom, the composite — is paid per pixel. `pixelBudget` caps
  the drawable at four million and lets the compositor scale.

Together: 26.9 ms of GPU a frame to 4, and the solver's burst from 173 ms to 6.

**Measure a frame's cost over a whole scene, never at a moment.** The GPU time of one frame
says almost nothing: a particle is a sprite whose area goes as the square of its kernel, so a
close shot costs several times a wide one at the same particle count, and a single reading
picks up whichever shot happened to be running. Reading one is how 450 000 particles looked
free and 700 000 looked impossible when the difference was the shot. Across a full 62 s scene:
250 000 costs 3.9 ms a frame and misses one slot in 3 675, 400 000 costs 9.2 and misses
sixteen, 700 000 costs 34.7 and misses one frame in two. The kernel ceiling is capped at 70
pixels for the same reason — at 140 the close shots alone took the median from 4.7 ms to 20.

**Leaving contemplation must not happen inside the key handler.** Escape crashed the app:
`stopContemplation` changes `stage`, which tears down the very view whose `keyDown:` is still
on the stack, and takes the window out of full screen while AppKit is mid-transition. Both are
deferred to the next turn of the run loop now. `--cinema` exercises the teardown on every run
rather than behind a flag, because it only happens when somebody presses a key and no check
went near it.

A trap worth naming, met while fixing that: `pause()` compiles anywhere Foundation is imported
and resolves to the **POSIX** call, which suspends the thread until a signal arrives. It is not
a method on anything here. Check that a symbol you did not write exists before trusting that it
compiled.

The bank's depth is the thing to get right, not its wiring. At a fifth either side it was
working and could not be seen: the frame's mean luminance moved thirty per cent between the
extremes of a three minute period, which nobody notices while the camera is also moving. At
roughly half either side the colour in the frame moves by a factor of three and the bloom by
five. When somebody says a modulation is not reaching the picture, measure the picture — same
scene, same camera, several moments — before touching the plumbing.

`I` shows what the oscillators are doing, live. Two things about it that were wrong first.

A `ZStack` does not reliably put SwiftUI content above an `NSViewRepresentable` whose view is
layer-backed: the Metal layer draws over it and the overlay is simply never seen, which is what
happened. Everything drawn over the scene is a subview of the canvas now
(`PassThroughHostingView`), where the ordering is AppKit's own. `--uishot` renders the overlay
offscreen so it can be looked at at all on this machine.

And it runs on a `TimelineView` at ten hertz rather than on the model's publishers: the values
change sixty times a second, and republishing them would rebuild every view observing the model
at frame rate, which is the whole of what makes a picture stutter. The visibility flag lives on
the model rather than in the view, because a `@State` flag cannot be seen from outside and
there was then no way to tell a key that never arrived from an overlay that never drew.

**Saturation has to be applied on both sides of the tone curve.** The filmic shoulder pulls
bright values toward white by design — right for a photograph, wrong for a galaxy whose core is
the most interesting colour in the frame. Doing all of it beforehand, as it was, does not
survive the curve: the cores came out white. Half the amount either side gives the same overall
push and leaves the highlights a hue.

Diffraction spikes are gathered from the already blurred bloom source, so past about forty
pixels they stop being spikes and become soft cones that sit still on the screen while the
stars slide underneath. `RenderLook.calm()` shortens them and shrinks the field stars for
contemplation, where nobody is there to be impressed by an instrument.

Two measurement lessons sit underneath all of that. `present` commits and returns, so timing
around it measures encoding and not drawing — `lastGPUMilliseconds` comes from the command
buffer's own clock, and until it existed half the frame was invisible. And a viewer's report
that a classic run of nine times the particles was smooth is what finally ruled out the solver:
`--cinema classic` runs an ordinary scene through the identical harness for exactly that
comparison, and showed classic with a 207 ms burst and contemplation with 24, the wrong way
round from the complaint.

**`treeReuse` stays at 5, even with the GPU build.** Measured with `--cinema 45`, brisk and slow,
two passes each, 210 000 to 350 000 particles (the scene is random, so the count wanders).
Both settings hold sixty hertz: one slot missed in 21 600 frames at 1, none at 5. What the
rebuild costs is the solver's burst: median 9–12 ms against 5–6, and 90 % of bursts over 8 ms
against 10–20 %. Brisk steps 41–42 times a second at 1 and 44–60 at 5, so the galaxies move
less often, which is the complaint reuse was introduced for. Reuse also costs star formation
15 % of its knots at two steps (#33), which was not measured here. Launching with the argument
`slow` hung before the window appeared on this machine; the pace came from an environment variable.

The rest of this section is what was fixed before that, and still holds.

**The solver's uninterrupted burst matters too, though it was not the stutter.** A viewer reported half a second of picture followed by half
a second of freeze while `--cinema` reported a healthy median, and the two were consistent: a
step held every core for 173 ms and the pacing then idled for 370, which is that half-second
cycle exactly. What brought it to 30 ms, in the order the measurements found them:

- **The smoothing field builds a tree of its own**, and it was doing so three times a second on
  top of the solver's. That alone was most of a second of saturated cores per second. In
  contemplation it refreshes every 240 frames instead of every 20. An earlier note here had
  measured this same refresh innocent — during *playback*, where there is no solver competing
  with it. It is not innocent next to one.
- **Four steps a pump** is a burst four times as long for the same work. One.
- **The tree build is the step**, at 22 ms of the 30: bigger leaves (32 rather than 16, which
  only became affordable once leaves respected the opening criterion), a depth ceiling of 13
  rather than 20 — a merged core subdivides to the ceiling and the node split was serial then — and
  fewer particles.
- **Background rather than utility priority.** The solver has ten times the throughput the
  paced rate asks for, so priority is bought with something that was not being used.

`--cinema` cannot see the last of this, and that limit is worth stating plainly: it drives an
*occluded* window, which is never throttled by the compositor, so `currentDrawable` never
blocks there and the failure mode a visible window has is invisible to it. The burst length is
the honest proxy, which is why it is reported.

The director's camera reached the renderer only after all of the above: `activeCamera` had
never consulted it, so every shot ever described here was being computed and thrown away while
the screen showed a motionless orbit rig. Anything that computes a camera has to be asked for
it somewhere.

Touching the camera in contemplation hands it over — drag, wheel, or a movement key, which also
turns flight on and takes the rig from wherever the director had it — and the director takes it
back twenty-five seconds after the last input.

One scene in three is **immersed** — the eye placed among the stars first and the aim following,
which is the opposite of the orbit rig and the only way to be inside anything. Out at the rim of
the disk, not in its middle: a few kiloparsecs from the centre puts the camera inside the bulge,
where four hundred thousand particles spread across a whole sky is not a galaxy but a brown fog,
and the wide kernels that hide the sparseness are what make it fog. From the rim the disk lies
across the frame with the companion beyond it.

A scene is built on one named look and the oscillators move around it, rather than crossfading
between five — a scene should have a character rather than an average. The same five are in the
viewing panel, since a look is a good place to start from by hand too. `RenderLook` is exactly
the subset of the settings a frame may change on its own; resolution, supersampling, bloom
levels and the starfield own textures and buffers and are not in it.

Three things about the choreography, each of which was a cut that did not work.

- **Every quantity is continuous.** Shots ease between framings with a smoothstep, and the
  azimuth drifts at a rate that never reaches zero, so shots join without either a kink or a
  stop. `theCameraNeverJumps` walks an hour at 60 Hz and caught the one field `mix` forgot to
  interpolate — the world-space point an orbit circles — which was a jump of a fifth of the
  scene at every shot boundary.
- **A shot that ends close may not change subject.** Crossing from one galaxy to the other
  while the camera closes in puts the aim on the midpoint exactly as the frame narrows: sixteen
  seconds of empty sky, measured. Nor may a close shot aim at the barycentre, which on a
  separated pair is the one place with no galaxy in it — that one was forty-five seconds.
  Easing in from the barycentre is fine, being half the distance and widening as it goes.
- **Coming in close needs its own exposure.** The mean luminance of the frame runs from 0.10 at
  a wide shot to 0.89 at a fifth of the framing distance. Trimming the brightness alone barely
  moves it, because the logarithmic stretch is what saturates, so the stretch comes down with
  it and the kernels widen — the ceiling on kernel size is what lets particles resolve into
  grains once the camera is near enough for their spacing to exceed it.

Distances are multiples of the distance at which the subject fills the frame, not of its
radius, so changing the field of view moves the camera instead of shrinking the galaxy. And the
opening shot starts at about one of those rather than two and a half: opening wide and turning
slowly meant a minute in which nothing appeared to move.
