# Flying rather than orbiting

`FlyCamera` is a position and a direction, alongside the orbit rig rather than replacing it:
one answers "look at this galaxy from there", the other "go inside it". `F` swaps them, and
each adopts the other's view so the picture never jumps — `theTwoRigsHandOverWithoutJumping`
guards that in both directions.

Two things make it watchable rather than merely working.

- **Keys are held, not handled.** `keyDown` only records that a key is down; the frame reads
  the set and integrates a velocity against the real frame interval. Moving the camera from
  the events themselves would move it at the key repeat rate, which arrives in irregular
  bursts and reads as judder however smoothly the scene is drawn.
- **The rig is not `@Published`.** It changes sixty times a second, and publishing that would
  rebuild the whole control panel at frame rate — which is the very thing the section above is
  about. Only `isFlying` is published.

The flight advance sits ahead of every guard in `draw` that can decline to render: an occluded
window hands back no drawable, and a camera that stopped dead whenever that happened would be
worse than one that flies with nothing to show for a frame. That is also why the `--qa` checks
can see it at all, since the window there is always occluded.
