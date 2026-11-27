# The Antennae (NGC 4038 and NGC 4039), pictures and scale

Epic #521, ticket #522. Two pictures, both needed: the film freezes on the wide ground picture
with both tails, then, time still frozen, closes on the heart at Hubble's framing. The pictures
are not on main (`pictures/` is ignored): they live on the `assets/antennae` branch, and
`tools/fetch.sh` fetches them again on the Mac.

## The pictures

| file | what | scale | credit and licence |
| --- | --- | --- | --- |
| `antennae-ls-wide.jpg` | Legacy Surveys DR10 colour cutout, 3000 x 3000 px, centre RA 180.452, Dec -18.885, north up, east left | 0.40 arcsec/px, 1200 arcsec across | Legacy Surveys / D. Lang (Perimeter Institute), CC BY 4.0 |
| `heic0615a.tif`, `heic0615a-large.jpg` | Hubble ACS, B, V, I and H-alpha, 3915 x 3885 px | 0.0501 arcsec/px, 3.27 x 3.25 arcmin | NASA, ESA, and the Hubble Heritage Team (STScI/AURA)-ESA/Hubble Collaboration. Acknowledgement: B. Whitmore (Space Telescope Science Institute) and James Long (ESA/Hubble). CC BY 4.0, <https://esahubble.org/images/heic0615a/> |

The cutout comes from `https://www.legacysurvey.org/viewer/jpeg-cutout?ra=180.452&dec=-18.885&width=3000&height=3000&layer=ls-dr10&pixscale=0.40`.
The earlier one of #320 (0.66 arcsec/px, 169 kpc across) is the same field, coarser. The tails run
over about 2440 px of the cutout (975 arcsec, 104 kpc), above the 2160 px the 4K split screen asks
for at native scale. Faint bluish seams (tile edges of the survey) cross the sky, one vertical near x = 2530 and one
horizontal at the left; the first is inside the panel, away from the tails, and the maps' sky fit absorbs it.

Foreground stars with green bleed trails are the survey's own: the map masks them.

## Hubble's frame on the wide picture

From the archive page: centre RA 12h 01m 52.88s, Dec -18 52' 49.77", field 3.27 x 3.25 arcmin,
"North is 30.6 degrees right of vertical". On the wide cutout (north up, east left) its up
direction therefore points 30.6 degrees counter-clockwise from the picture's up, and the frame is
a rectangle of 490 x 487 px (196 x 195 arcsec) turned that way, centred at pixel (1344, 1459).
`wide-with-hubble-frame.jpg` draws it; `hubble-frame.json` holds the corners.

Check: Hubble warped onto the wide picture's grid (`tools/frame.py`) and slid over the wide
luminance in log, the correlation at the archive's numbers is 0.929 and the best shift is 0.8
arcsec (2 px of the wide picture) at 0.930: the frame sits where the archive says. A film that
closes from the wide view onto Hubble's frame must turn by 30.6 degrees as it zooms, and the
frame's top edge (red in the drawing) is Hubble's top.

Nuclei (found on Hubble's picture, 67 arcsec or 7.1 kpc apart at 22 Mpc):

| | Hubble px | wide px | wide panel (fraction of width) | Hubble (fraction of width) |
| --- | --- | --- | --- | --- |
| NGC 4038 (north) | 2421, 1143 | 1343, 1344 | 0.4346, 0.4975 | 0.6184, 0.2919 |
| NGC 4039 (south) | 1586, 2205 | 1321, 1511 | 0.4254, 0.5671 | 0.4051, 0.5633 |

## The distance: 22 Mpc

- Schweizer et al. 2008 (AJ 136, 1482), from SN 2007sr: 22.3 +/- 2.8 Mpc (mu 31.74 +/- 0.27),
  recommended 22 +/- 3 Mpc; the flow gives 22.5 +/- 2.8 and their own TRGB reanalysis 20.0 +/- 1.6.
  They say the 13.3 +/- 1.0 Mpc of Saviane et al. 2008 (TRGB) most likely took the tip for
  younger AGB stars.
- Jang and Lee 2015 (ApJ 807, 133), TRGB: (m-M)_0 = 31.67 +/- 0.05 +/- 0.12, 21.58 +/- 0.50 +/- 1.19 Mpc.
  Cepheids of SH0ES (Riess et al. 2016) first gave 31.29 and later about 31.6 once the ultra-long
  period Cepheids were set aside; a 2025 JWST TRGB study gives 31.645 (about 21.3 Mpc). Not read
  in full here.
- Pick: **22 Mpc**. It is the paper that gave the pair its modern distance, the later TRGB and
  Cepheid values (21.3 to 21.6) agree within 2 %, and 13.3 Mpc is the outlier. It is also the
  scale the earlier work (#320, the archetype) used, so nothing moves. At 22 Mpc one arcsecond is
  0.1067 kpc.

| picture | pixel scale | across | tails |
| --- | --- | --- | --- |
| wide cutout | 0.40 arcsec/px = 42.7 pc/px | 3000 px, 1200 arcsec, **128 kpc** | 2440 px, 104 kpc |
| ground panel (crop 2400 x 2700) | same | 102.5 kpc wide, 115 kpc tall | |
| Hubble | 0.0501 arcsec/px = 5.35 pc/px | 3915 px, 196 arcsec, **20.9 kpc** | |

## The maps

`photo-match.py picture`, 256 bins wide, nuclei marked:

- `antennae-crop.map.json`: the panel's crop, 256 x 288, depth 2.48 decades, 17.9 % of bins masked.
  Mask preview in `pictures/mask-wide.png`: foreground stars, spikes and the small background
  galaxies are masked; both tails are whole, the bodies are whole.
- `heic0615a.map.json`: Hubble, 256 x 254, depth 2.40 decades, 1.9 % masked (a few stars).

The crop is what the maps read, so a match on `antennae-crop.map.json` is in the panel's frame.

## The panel

`tools/panel.py` crops the wide cutout to 2400 x 2700 px at (300, 150), 8:9, and writes
`antennae-crop.jpg` and the 1920 x 2160 `panel-ground.png` for `picture-film.py --layout slide`
(the Cartwheel's panel is the same shape). Tails tip to tip fill 1950 of its 2160 px height; the
nuclei fall at (834, 955) and (817, 1089), a little left of the middle.
