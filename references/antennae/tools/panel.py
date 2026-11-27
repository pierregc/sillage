#!/usr/bin/env python3
"""The ground half of the split screen: the wide cutout cropped 8:9 to both tails, tip to tip.
The same crop is the map photo-match.py reads. usage: panel.py <antennae-ls-wide.jpg> <out dir>

The tails span x 600-2400, y 280-2720 of the 3000 px cutout (0.40 arcsec/px); the crop adds a
margin of sky on each side. Writes the crop at full size, the 1920x2160 panel, and
panel.json with the crop's origin and where the two nuclei fall.
"""
import json, sys
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
X0, Y0, W, H = 300, 150, 2400, 2700
# nuclei, in pixels of the 3000 px cutout (found on Hubble's picture, carried over by hubble-frame.json)
NUCLEI = {"NGC 4038": (1343, 1344), "NGC 4039": (1321, 1511)}
im = Image.open(sys.argv[1])
crop = im.crop((X0, Y0, X0 + W, Y0 + H))
crop.save(f"{sys.argv[2]}/antennae-crop.jpg", quality=95)
crop.resize((1920, 2160), Image.LANCZOS).save(f"{sys.argv[2]}/panel-ground.png")
fr = {k: [round((x - X0) / W, 4), round((y - Y0) / W, 4)] for k, (x, y) in NUCLEI.items()}
json.dump({"crop": [X0, Y0, W, H], "nuclei_fraction_of_width": fr,
           "nuclei_panel_px": {k: [round((x - X0) * 0.8), round((y - Y0) * 0.8)] for k, (x, y) in NUCLEI.items()}},
          open(f"{sys.argv[2]}/panel.json", "w"), indent=1)
print(open(f"{sys.argv[2]}/panel.json").read())
