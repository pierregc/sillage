"""tiles.py <still> <out> <kpc across the still's width> [label]: crops a still to Hubble's framing
(21 kpc across, 1024 x 606), 1024 px wide, with the label written on it. CORE=x,y puts the still's
centre at that pixel of the crop (Hubble's core is at 504,312)."""
import os
import sys
from PIL import Image, ImageDraw, ImageFont
src, out, kpc = sys.argv[1], sys.argv[2], float(sys.argv[3])
im = Image.open(src).convert("RGB"); w, h = im.size
cw = w * 21.0 / kpc; ch = cw * 606 / 1024
px, py = (float(v) for v in os.environ.get("CORE", "512,303").split(","))
x0, y0 = w / 2 - px * cw / 1024, h / 2 - py * ch / 606
box = (round(x0), round(y0), round(x0 + cw), round(y0 + ch))
im = im.crop(box).resize((1024, 606), Image.LANCZOS)
if len(sys.argv) > 4:
    d = ImageDraw.Draw(im); f = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 26, index=5)
    d.text((14, 10), sys.argv[4], font=f, fill=(255, 255, 255))
im.save(out)
