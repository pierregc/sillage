# One age per particle

Every star carries a real age now — bulge 10 to 12.5 Gyr, disk drawn from an inside-out
history so its outskirts are the young part — and both its colour and its light per unit mass
follow from it, the second as `age^-0.9`. The `ancient` sentinel is gone for stars: a knot
three megayears old and a bulge star of eleven gigayears are the same formula at different
ages, which is the simplification that made this worth doing at all.

Three things it took two attempts to get right, and the first attempt shipped and had to be
reverted.

- **The arm term lived on the branch for stars with no age.** `+0.22 * (wave - 0.5)` is what
  makes an arm bluer than the region beside it, and it sat in the `else` of the age test. The
  moment every star had an age it reached nothing, and the arms lost their blue in a single
  edit — with every test still green, because no test looks at colour. It is 0.38 now and
  applies whatever the age came from: it used to nudge a population the sampler had already
  made blue, and it now has to separate arm from interarm on its own.
- **Normalise the law to unit mean or retune everything.** The exposure divides by the *number*
  of particles that reach a pixel, not by their light, so a law that makes some of them twenty
  times brighter moves the whole frame. `Renderer` takes the mean of the same law over the
  ages the scene was sampled with, once, and divides by it. Mean luminance 21.19 before and
  21.46 after; none of the five looks needed touching.
- **The young are what make it blue and what make it grainy, and they are the same particles.**
  A power law with no floor is a trap at these counts: ages drawn towards zero put most of a
  galaxy's light into a few hundred particles and the disk reads as glitter. Floored at
  600 Myr, and anything younger is the run's own doing, where a knot is meant to stand out.
  Raising the floor to 1500 killed the grain and the blue together, which is how the tension
  was found; between 300 and 600 the grain barely moves, so the floor is not the lever it
  looks like.

**The colour ramp has to be calibrated, not chosen, and a merger hides that a single galaxy
does not.** A ramp running from three megayears to a Hubble time puts every real disk age into
its bottom fifth: 600 Myr came out at 6270 K against the 7250 population synthesis gives,
3 Gyr at 5040 against 5800. A whole galaxy therefore rendered orange — and it was invisible on
the merger preset, because there the two galaxies carry opposite tints and the blue one still
looked blue. It took an isolated disk, which carries a cream tint and nothing to compensate,
to show that no blue was coming from the stars at all. **Judge colour on one galaxy.**

The ramp now fits the two ends that matter and the old end sits past a Hubble time on purpose,
so a twelve-gigayear bulge lands above the bottom of it rather than pinned to it.

**An arm is younger, not just brighter**, and the shift has to be wide to say so: on a ridge
the light of a three-gigayear disk reads like a few hundred megayears, which is the whole
distance between orange and blue-white. 0.55 now, from 0.22 when it only had to nudge an
already-blue population.

**A star's colour must not depend on where it is standing.** The arm term was added to the
age at draw time, and `wave` is read at the particle's *current* position, so once it was wide
enough to make an arm blue it made every star swing between five and ten thousand kelvin twice
an orbit — a viewer called it a Christmas tree and that is exactly what it was. A population
does not redden and blue again as it turns. The arm's colour comes from what it contains now,
set once by the sampler: ages are drawn hard against the young end near an arm, `roll^(1+6p)`,
so a ridge lands near a hundred megayears and the space between arms near six gigayears. Baked
in, it cannot flash.

**Physical ages cannot make a blue disk, and saturation can.** This is the one place where the
honest answer and the wanted picture pull apart, and it is worth being clear which lever does
what. A population older than about a hundred megayears is white to orange — that is what
population synthesis says, and no amount of arranging ages changes it. The hand-tuned
`population` it replaced was blue everywhere because it was never an age at all. So the disk
came out at 2 % blue pixels against the 41 % of the old look, and chasing that with younger
ages went the wrong way: below about sixty megayears the mass-to-light cap pushes those stars
through the tone curve's shoulder and they come out *white*, not blue — 15 Myr gave 1.4 % blue
and 60 Myr gave 17.9 %.

The hue was in the frame the whole time and could not be seen: mean R 122 G 115 B 122, blue by
the numbers, white to the eye. Saturation is what separates it, and it touches nothing
physical — 1.8 gives 29 %, 2.8 gives 41.3 %, 3.6 gives 46 %. The default is 2.8 now. Reach for
it, not for the ages, when a scene wants more colour.

**Judge a colour zoomed in, on one galaxy.** Two mistakes in a row came from not doing that: a
merger hides a colourless disk behind two opposing tints, and a wide framing is mostly sky, so
the numbers move for reasons that have nothing to do with the galaxy. `--zoom` and
`--saturation` are both flags on the headless renderer already.

**A warmer base makes the per-galaxy tint louder.** Stellar colour used to come out blue
whatever the tint did to it. It comes out warm now, so `galaxyTint` at 0.35 turns a galaxy
whose colour is `(1.0, 0.86, 0.62)` frankly orange. That is the slider to reach for first if a
scene looks too warm, and it is already in the panel.
