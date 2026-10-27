# What Hubble and Webb pictures are made of

The Télescope colour world (#118 to #120, #125, #126) should look like the pictures people know,
so its colours are measured on twelve published images rather than derived from stellar
populations. The physical colouring tried before ended as red, blue and white dots; this note is
the reference that replaces it.

## The images

Not committed. `scripts/telescope-colours.py fetch` downloads them into `out/telescope-images/`.
All twelve are CC BY 4.0 and must be credited as below wherever they are shown.

| Set | Image | Subject | Credit |
| --- | --- | --- | --- |
| Hubble visible | [heic0615a](https://esahubble.org/images/heic0615a/) | Antennae, NGC 4038/4039 | NASA, ESA, and the Hubble Heritage Team (STScI/AURA)-ESA/Hubble Collaboration. Acknowledgement: B. Whitmore (STScI) and James Long (ESA/Hubble) |
| Hubble visible | [heic0506a](https://esahubble.org/images/heic0506a/) | Whirlpool, M51 and NGC 5195 | NASA, ESA, S. Beckwith (STScI), and The Hubble Heritage Team (STScI/AURA) |
| Hubble visible | [heic1107a](https://esahubble.org/images/heic1107a/) | Arp 273 | NASA, ESA and the Hubble Heritage Team (STScI/AURA) |
| Hubble visible | [heic0206h](https://esahubble.org/images/heic0206h/) | The Mice, NGC 4676 | NASA, H. Ford (JHU), G. Illingworth (UCSC/LO), M. Clampin (STScI), G. Hartig (STScI), the ACS Science Team, and ESA |
| Webb NIRCam | [potm2212a](https://esawebb.org/images/potm2212a/) | NGC 7469 | ESA/Webb, NASA & CSA, L. Armus, A. S. Evans |
| Webb NIRCam | [potm2405a](https://esawebb.org/images/potm2405a/) | NGC 4449, close-up | ESA/Webb, NASA & CSA, A. Adamo (Stockholm University) and the FEAST JWST team |
| Webb NIRCam | [weic2608a](https://esawebb.org/images/weic2608a/) | M51 arm, close-up | ESA/Webb, NASA & CSA, A. Pedrini, A. Adamo (Stockholm University) and the FEAST JWST team |
| Webb MIRI | [weic2306a](https://esawebb.org/images/weic2306a/) | NGC 1433 | NASA, ESA, CSA, and J. Lee (NOIRLab), A. Pagan (STScI) |
| Webb MIRI | [weic2208b](https://esawebb.org/images/weic2208b/) | Stephan's Quintet | NASA, ESA, CSA, and STScI |
| Webb NIRCam + MIRI | [weic2211a](https://esawebb.org/images/weic2211a/) | Cartwheel and companions | NASA, ESA, CSA, STScI |
| Webb NIRCam + MIRI | [weic2420a](https://esawebb.org/images/weic2420a/) | Arp 142 | NASA, ESA, CSA, STScI |
| Webb NIRCam + MIRI | [potm2602a](https://esawebb.org/images/potm2602a/) | NGC 5134 | ESA/Webb, NASA & CSA, A. Leroy |

**Four sets, not three.** Most Webb releases people remember (Cartwheel, Arp 142, the PHANGS
spirals) combine NIRCam and MIRI, and they look like neither instrument alone, so they get their
own file. NIRCam-only pictures of whole interacting galaxies are rare on esawebb.org; two of the
three are close-ups with no nucleus and no sky, so NIRCam's core, tails and sky come from NGC 7469
alone. **No Hubble narrow-band file:** that palette is a nebula look, and Hubble's galaxy releases
are broadband with H-alpha added (the Antennae and M51 here already have it).

## Method

`references/telescope/marks.json` gives each galaxy, by hand and once, a nucleus with a core radius
and one or more ellipses for its body, in fractions of the image width. The script reads each
image at 1600 px wide, converts it to OKLab and finds the rest from brightness at two scales:

- **core**: inside a core radius.
- **knots**: in a body, brighter than the 8 px surroundings and in the top 5 % of that contrast.
- **dust**: Hubble dust absorbs, so it is darker than the broad (60 px) light and yellower than
  either the galaxy or its own surroundings (top quarter), away from knots. Webb dust emits, so it
  is the top 20 % of brightness against the 24 px surroundings. Which rule applies is the image's
  `dust` mark.
- **disk**: the rest of a body.
- **tails**: outside every body, above the sky by 0.05 in L both at 3 px and at 40 px, and not
  compact, so a small background galaxy is not a tail.
- **sky**: outside every body, within 0.03 of the sky level at both scales, not compact.

`--overlays` paints the regions into `out/telescope-overlays/`; every image was checked that way.
Shares are set by percentiles, so they describe the method, not the galaxy. Diffraction spikes are
not removed and land in whatever region they cross.

Each `references/telescope/<set>.json` has, per region, the OKLab median, the 16th and 84th
percentiles, the median chroma and hue, an sRGB swatch, and `vivid`: the median of the most
saturated sixth of the pixels, split warm (hue 330° to 110°) and cool. A set pools 20 000 pixels
per image and region so every image weighs the same; each image's own numbers follow. The run is
deterministic.

## What the numbers say

**Medians are nearly grey; the colour is in the most saturated pixels.** A Hubble disk has a
median chroma of 0.018, knots 0.037. The picture reads as colourful because of a minority of
pixels two to four times more saturated, which is why `vivid` exists. A renderer that tints
everything by the median gets mud.

| Region | Hubble visible | Webb NIRCam | Webb MIRI | NIRCam + MIRI |
| --- | --- | --- | --- | --- |
| core | cream gold, L 0.84, hue 67° | cream, L 0.88 | pale grey, L 0.72 | pinkish white, L 0.84 |
| disk | warm grey, L 0.49, chroma 0.02 | cool grey, L 0.40 | near black, L 0.24 | mauve, L 0.55, chroma 0.04 |
| knots | vivid split 76 % pink (#c47a77) / 24 % blue (#789cc8) | orange (#bf542c), no blue | violet (#6f78af), some red | coral (#f27167), chroma 0.16 |
| dust | brown shadow, L 0.43, hue 54° | rust light (#b54831) | grey-violet web | coral, as bright as knots |
| tails | neutral, L 0.26, a cool cast | cool grey | grey | dim violet-grey |
| sky | L 0.14, cyan-black | L 0.13, neutral | L 0.19, grey | L 0.17, warm black |

- **Hubble** is warm in the middle and cool outside: a gold bulge, warm grey disk, brown dust in
  shadow, beads of blue clusters and pink H-alpha along the arms, neutral tails, a sky just off
  black with a cyan cast.
- **Webb inverts the dust.** It is light, not shadow: orange-red PAH filaments over a cool
  blue-white stellar body. In NIRCam and in composites the vivid pixels are nearly all warm.
- **MIRI** loses the stars: a dark disk crossed by a grey-violet web of dust, red where it is
  hottest, and a pale core.
- **The composite** is the "Webb look": coral at a chroma nearly twice Hubble's most saturated
  knots, over blue-white starlight and a warm black.

## The look beyond colour, for #126

- **Diffraction spikes.** Hubble: four thin spikes at 90°, from the secondary mirror's spider,
  only on bright foreground stars. Webb: six long spikes from the hexagonal segments plus two short
  horizontal ones from the strut, on stars and on bright cores (NGC 7319 in MIRI, NGC 7469 in
  NIRCam), often tinted (blue on stars, red in MIRI).
- **Core glow.** Hubble bulges are a broad gold glow with no visible edge. Webb cores are smaller
  and whiter: cream in NGC 7469, blue-white in NGC 5134, pinkish in the Cartwheel. MIRI cores are
  small and pale.
- **Dust.** Hubble: brown lanes on the inner edge of arms, darkening what is behind them. Webb:
  glowing filaments, as bright as the arms.
- **Sky.** Hubble: black with sparse small galaxies and stars. Webb deep images: a dense field of
  tiny orange and red background galaxies; MIRI mosaics show a grey floor and the footprint edge.
- **Grain.** Hubble arms are granular with resolved clusters; Webb close-ups resolve individual
  stars as a fine blue-white dust over the whole disk.

## The two renderings (#126)

`looks/hubble.look.json` and `looks/webb.look.json` carry `"world": "telescope"`;
`LookCatalogue.renderings(.telescope, …)` returns them and the free world gets the rest.

- **Spikes.** `spikePattern: "webb"` lays six long arms with one pair upright and adds two short
  horizontal ones. `spikeSharpness` takes the broad light off before gathering, so only stars and
  point-like cores throw spikes, as thin lines rather than cones; at 1 those spikes are gathered
  at quarter size, which made the Webb look 0.7 ms a frame cheaper than six plain arms at 2 M
  (`--replay`, 2560 x 1440).
- **Sky.** `skyColour` replaces the fixed blue-black: cyan black at L 0.14 for Hubble, warm black at
  L 0.17 for Webb, measured on renders against the table above.
- **What stays off.** Pink knots on Hubble's arms and Webb's glowing coral dust are colours per
  component inside one galaxy, which is #119. Until then Webb tints a galaxy coral or blue-white
  as a whole.
