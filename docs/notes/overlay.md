# Words on the picture

#317, from recommendation 2 of [What would give Sillage its dimension](next-dimension.md): a
viewer shown a video did not know he was looking at galaxies. A video can now say what it shows:
a title, a clock in millions of years, a scale bar and a caption at each of the story's events.
How to ask for them is in `docs/reference.md` (Export, Overlay); this note is why they are the way
they are.

## One plan, then a drawing

`OverlayPlan` lays out every frame of a video before the first is drawn: which marks show, at what
strength, where and how large, in pixels. It is portable Swift and holds no state between frames,
so any frame is the same whatever was drawn before it. That matters for the full pass of a hires,
which a checkpoint can resume halfway: the scale bar's length depends on the frames before it
(below), and a resumed run has to choose the same one. Laying out 300 frames takes half a
millisecond.

`OverlayPainter` draws a frame of the plan with Core Text and Core Graphics, on the CPU, over the
finished frame: after the tone curve, the bloom and the film grain, at the video's own size. For a
video that is the encoder's own pixel buffer, once the GPU is done with it and before the encoder
takes it (`VideoWriter.append(over:)`); for the animated previews, the RGBA frame read back. The
GPU waits for the frame anyway before handing it over, so drawing on the CPU costs its own time
and no copy: 0.7 ms a 4k frame, 0.3 at 9:16, 0.2 at 1080p, measured on the M4 Max with the four
elements on, against about 100 ms for the 4k frame of an 8 M take. Drawing on the GPU would have
needed the text rasterised on the CPU anyway, into a texture, and a pass to blend it.

## Not on CUDA

Linux has no Core Text, so the CUDA pass refuses an overlay before it starts
(`RunVideos.Failure.overlay`), with the reason and what to do instead: draw the run without one,
and export the massive take with it on the Mac. Drawing it there would mean bringing a font
rasteriser (FreeType and a font file) into the Linux build to set a few words; the plan it would
draw is already portable, so the day it is wanted, only `OverlayPainter` needs a second body. The
CUDA pass is for counts that show only in a 4k close-up (next-dimension), which is not where a
title is needed first.

## Where it is asked

One structure, `Overlay`, carried by a look (`overlay`), by a scene (`overlay.json`) or by one
export (`--overlay`), each replacing the one before whole rather than field by field: what a video
carries is in one file, never a merge of three. A look is where an overlay used on every scene
lives (the README's style with its clock and bar); a scene file is where its title and captions
are said. Nothing is asked unless named, and a look without the field writes the same bytes as
before, so every existing export and checkpoint identity stays as it was.

The words come from one table, `OverlayTexts`: English is built in, and another language is a
file with the same fields, each one it leaves out read in English. Word order differs between
languages, so a sentence is a template (`{count} {kind} galaxies, each about {size} light years
across`) rather than words the code puts together; the thousands separator is in the table too.

## The story's events

`OverlayMoments` reads them off the framing take, at every captured frame, so a full pass and an
export of its massive take find the same ones:

- **The first passage** is `Story.firstApproach` on the take's centres: the first pass of a pair
  inside its reach, counted once the pair has separated again by five per cent.
- **The approach** is the first frame halfway in distance from the start to that passage, as
  `KeyFrames` picks it.
- **The return** is the same pair's next pass counted the same way, before the merger.
- **The merger** is the first frame from which the pair stays within 2 kpc to the end. On the
  Mice of the README the centres wander within half a kiloparsec once merged, and the last
  passage before the merger dips to 1.5 kpc and comes back out to 2.7.
- **The tails** need the share of stars in tails, which a take does not hold: it is read from
  `curves-hires.csv` beside the take (the massive pass's; a full pass writes none). The moment is
  the first frame halfway up its rise from the first passage to the return, which needs a rise of
  0.05 at least. Halfway, because tails are visible well before their share peaks, and only to the
  return, because a merger raises the share again.

On the Mice (scene 67 of 2026-11-04, 1525 frames, the README's film): the approach at frame 95
(40 kpc apart), the passage at 193 (450 Myr, 12.9 kpc), the tails at 299, the return at 765
(4.2 kpc) and the merger at 868. At 30 frames a second the captions start at 5.4 s (the passage),
10.3 s (the tails, which waited 0.4 s for the passage's to go), 23.5 s (the return) and 28.4 s
(the merger); the title holds 2.5 s instead of 3.5 to let the passage's in, and the approach's,
under the title, does not show.

A caption shows a little before its moment for a passage (1 s, the return 2 s, the merger 0.5 s),
so it is read while the thing happens rather than after. Captions take the title's place, one at a
time, since a second voice in the frame is what makes a video busy. In order of priority (the
passage, the merger, the tails, the return, the approach), a caption that would overlap the title
or one already placed waits for it to go if that takes 1.5 s at most, and is left out otherwise.
The title holds for less, two seconds at the least, to let the first passage's caption in.

## The clock

It reads the take's time at the captured position each frame shows, so it follows any change of
pace and stands still where time does, without knowing about either: a time track (#305) or a
freeze (#295) only changes the positions. From the start, it counts from the take's first frame,
even in a video cut later; from the passage, it is signed with a true minus. A clock that counts
every million years changes 24 times a second on the README's film, a blur in its last digits; it
counts instead in the step of 1, 2, 5, 10... nearest a third of the video's usual pace a second
(the median over the video, so a freeze or a fast stretch does not move it), 10 Myr on the README.
Its digits are tabular, so the line does not shift as it counts.

## The scale bar

A length of 1, 2 or 5 times a power of ten, in light years or kiloparsecs, measured at the depth
of the camera's target: `height / (2 d tan(fov / 2))` pixels a kiloparsec, `d` the distance to
the target, which is what the projection gives (`OverlayTests` holds it against
`Camera.viewProjection` at two zooms and both aspect ratios). Two neighbouring lengths are at most
2.5 apart, so one always lies between a tenth and a quarter of the frame's width, the range the
ticket asked for. The bar keeps its length while it stays in that range, so a slow zoom only
stretches it; when it leaves, the length in range nearest 13 % of the width replaces it, faded in
over 0.8 s as the old one fades out, each drawn at its own true length. 13 % rather than the middle
of the range: on the README's film it gives 100,000 light years, the galaxies' own size, where the
middle gave 200,000. A cut of the director moves the old length out of all proportion (past half
the width or under 4 %), and the bar then changes at once with the picture.

## The scale in words

#407, recommendation 3 of [Immensity inside an arm](immensity-inside-an-arm.md). Among the stars
the eye judges neither lengths nor speeds: the 10 s dive of #296 covers 6,500 light years each
second, 2 × 10^11 times the speed of light, and a drift of 50 pc a second is still 160 light years
a second. Two things say it.

- **The bar reaches the stars.** Its lengths run from 1 light year (0.001 kpc) up, so a frame a
  few hundred light years across at the target still has a length between a tenth and a quarter of
  its width. A frame that had one before keeps the same one: the new lengths are all far shorter
  than any that fitted.
- **The speed**, asked with `"speed": true` in `scale`. `OverlayPlan.speedTrack` reads it off the
  cameras the plan is laid with: the eye's distance over half a second of video either side,
  so a flight's motion blur or a cubic's kink between keys does not make it flicker. The number is
  said on a ladder of 1, 1.5, 2, 3, 5, 7 times a power of ten, each about half as large again as
  the one before, and is held while the speed stays within a third of it (`speedSlack` 1.35):
  the dive above, slowing from 7 kpc to 50 pc a second over 15 s, changes it about once a
  second, where two significant figures would have changed every few frames, the blur the clock
  steps were made against. It fades out over 0.6 s while the eye covers less than half a per cent
  of the frame's width at the target a second (`speedFloor`), a camera at rest or a still turn,
  and in again when it moves. It sits between the clock and the bar's label, at the label's size,
  digits tabular. In kiloparsecs it is said in parsecs a second under a kiloparsec a second.
  The words are in `OverlayTexts` (`lightYearsPerSecond`, `parsecsPerSecond`,
  `kiloparsecsPerSecond`).

## Layout and look

Pierre asked for it clean, light and soft. White at 0.9 at its strongest, no box, a dark halo of
6 px at 1080 blurred enough to be seen only over a bright core. The system's typeface (SF) at a
light weight for the title and the captions, regular for the small lines, a touch of tracking.
Sizes are set on the frame's short side, so 4k carries 1080p's text at twice the pixels:
title 46 px, its line 21, a caption 26, the clock 19, the bar's label 15, the bar 1.4 thick with
ends rising 4.

In a wide frame the words of the story (title, then captions) sit at the bottom left and the
instruments (clock over the bar's label over the bar) at the bottom right, sharing a baseline:
nothing at the top, nothing in the middle. The margins are 6 % of the height, 7.5 % at the sides.
A 9:16 or square video is watched on a phone, its 1080 pixels across a few inches, so every size
is a quarter larger. In 9:16 the platforms cover the right side with their buttons and the bottom
fifth with the channel and its caption: the words go to the top left under 9 %, the instruments to
the bottom left above 22 %, and nothing goes past 85 % of the width.

## Checked

- An export that asks for nothing draws the frames it drew before: on the README's take, the
  frames the encoder took (`--stills`) at 1080p and 9:16 are the same bytes as main's build, the
  decoded videos are the same frames, and a ProRes export is the same stream to the byte. HEVC
  streams differ from one run to the next with the same build: VideoToolbox does not encode the
  same frames to the same bytes twice.
- The frame the encoder takes carries the overlay as the read-back frame does, within one level.
