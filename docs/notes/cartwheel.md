# The Cartwheel, reproduced

Rank 4 of [twenty galaxies to reproduce](twenty-galaxies.md), and one of Pierre's four picks. A
film in three acts: the collision runs until the take looks like Webb's picture, time freezes and
the screen splits with the picture and a title, then the camera dives through the intruder,
through the Cartwheel's centre and across its disk edge on, and pulls back while time runs again.
Everything is in `references/cartwheel/`.

## What is known of the object

- ESO 350-40, about 150 Mpc (500 million light-years). Outer ring about 46 kpc across (150 000
  light-years); an inner ring round an off-centre nucleus; spokes between them.
- The ring expands at about 53 km/s in HI (Higdon 1993; 89 km/s in HII), which puts the impact
  300 to 430 Myr ago depending on the distance assumed. HI kinematics give an inclination of
  about 44 degrees and a total mass of 3.5 x 10^11 solar masses (H0 = 75), about six times its old
  stars (Appleton and Struck-Marcell 1996, section 3.3.1).
- Three companions. G1 (gas-rich irregular) and G2 (S0) are the two in Webb's frame; G3, 3
  arcminutes to the north-east (about 130 kpc), is an edge-on gas-rich disk joined to the
  Cartwheel by an HI plume, which is why Higdon (1996) made it the intruder. Its old stars are
  about a third of the Cartwheel's. Horellou and Combes (2001) model it as a rigid companion of
  half the target's mass on a nearly central collision.
- The colours of Webb's picture are infrared (NIRCam and MIRI): the pink is dust and gas. The film
  keeps the photographic look; recognition comes from the shape.

## The scene

`tools/make_scene.py` writes it from the ring archetype scene 35 of batch seed 20261121, a draw
that already looked close, with the encounter imposed (the restricted solver forces the placement,
as for a scene written by hand): G3 a spiral of a third of the mass, pericentre 1.2 kpc at
300 Myr, eccentricity 1.2, falling along the Cartwheel's axis tilted by 0.2 rad. `scene.json` is
the placed scene, as the 8 M hires read it.

- **The intruder must be compact.** A G3 drawn as a scaled copy of the Cartwheel (Hernquist halo,
  3.4 kpc disk) tears itself into a wide fan and leaves the Cartwheel nearly untouched. With the
  archetype's compact profile (Plummer, 1.7 kpc, a disk of 1.8 kpc cut at four lengths) the ring
  is sharp 86 Myr after the impact, and G3 leaves as a thin disk with a tail, much as it is seen.
- **The offset sets the nucleus.** At 2.5 kpc and 0.4 rad the nucleus ends up against the ring,
  twice as far out as in the picture; 1.2 kpc and 0.2 rad put it where it is. 0.7 kpc and 0.3 rad
  centre it and grow the inner ring too much. All three score alike (0.59 to 0.67), so the choice
  was made on the sheets.
- The ring is the picture's size 107 Myr after the impact, sooner than the 300 to 430 Myr
  measured: the ring's pattern runs faster than its gas.

Costs: explore at 200 k, 30 s; a check hires at 500 k, 2 min; the 8 M hires (12 M of halo,
sticky gas, 151 to 733 Myr), 10 770 s and a 12 GB take.

## Matching the picture

The picture is `weic2211a` at 4685 px, cropped 8:9 to the Cartwheel without G1 and G2
(`tools/panel.py`). `photo-match.py picture` maps it; `match --kpc-across 48.6` holds the scale
to the measured ring, since a free scale prefers a younger, smaller ring (0.74 at 25 kpc across,
44 Myr after the impact). On the 8 M take: 0.656 at 407.2 Myr, elevation 62.2, azimuth 43.1,
roll -88 (`match.json`). The 500 k take found the mirror, from below; the view flips between the
two from one take to the next, so the flight is written from the match, never by hand.

`tools/view2key.py` turns a match into a flight key that frames the crop in the middle half of a
16:9 frame: the aim is the crop's centre, the eye on the view's direction at the distance that
gives the crop's height at the key's field of view (0.15 rad, near enough orthographic for the
match), the roll the match's.

## Webb's colours

Pierre asked for the picture's colours and its field as well. Measured on the crop in linear
light, the bodies split into blue (0.59, 0.47, 1.0) over a fifth of them, red (1, 0.26, 0.24)
over half and pink between; the brightest percent, knots and nucleus, is a pale pink. The red is
dust and PAH glowing under MIRI, not stars, so no palette gets it: coloured by birth radius, the
ring stays lavender, because its stars were born well inside where it now stands.

- `dustGlow` draws the dust grains a second time into the light, in `dustGlowColour`, in
  proportion to their optical depth. The dust sits in the ring and the spokes, as Webb's red
  does. `cartwheel-webb.look.json`: Webb's look, dust opacity 0.12 without the web, glow 1 in
  (1, 0.2, 0.12), disk and outskirts in the measured blue, core and knots pale pink, spikes 0.18
  so that bright glowing grains do not throw them.
- `galaxyCount` 150 000 fills the sky with galaxies of 0.25 to 3.5 milliradians, the sizes of
  those round the Cartwheel, mostly orange: about as many in the frame as in the picture.

## Previews

The plain frames (explore's previews and the raw look) went through 1 - exp(-E): a dense core was
white past a few units and hid what moved in it. They now go through asinh, linear in the faint
light and logarithmic past it, white at 64 times the toe, so the nuclei keep their structure.

## The flights and the montage

`tools/flights.py` writes four flights from the match:

1. `1-collision`, 56 s: the approach from the side, the passage, the camera rising into the
   picture's view while widening its distance and narrowing its field (0.6 to 0.15 rad), time
   easing into a freeze at the match's moment, nine still seconds, then into G3 face on, through
   its disk and turning back to the Cartwheel behind it.
2. `2-centre`, 13 s: through the Cartwheel's centre along its axis, looking back up at the nucleus.
3. `3-edge`, 12 s: across the disk 1.5 kpc above its plane, through the ring's wall.
4. `4-again`, 31 s: a turn low over the ring, then a pull back framing both galaxies while time
   runs to the end of the take.

`tools/compose.py` pushes the split screen in over flight 1's hold (the frame slides left by a
quarter, the picture comes in from the right, the title and the credit fade in and out), cuts to
the other three and encodes x265 10 bit at CRF 14. ffmpeg here has no `drawtext`, so
`tools/title.py` draws the words to a PNG. Look: `cartwheel.look.json`, the photograph with dust
and dust web at 0.4, after Pierre found the dust heavy in the night's films.

Credit on screen: Image NASA, ESA, CSA, STScI (CC BY 4.0).
