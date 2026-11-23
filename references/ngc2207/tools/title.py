"""Title and credits over the split screen, a transparent 3840x2160 PNG. usage: title.py <out.png>"""
import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 3840, 2160
AV = "/System/Library/Fonts/Avenir Next.ttc"
def font(size, index):
    return ImageFont.truetype(AV, size, index=index)
im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
def centred(text, y, f, fill, x=W / 2, spacing=0):
    w = d.textlength(text, font=f) + spacing * (len(text) - 1)
    cx = x - w / 2
    for ch in text:
        d.text((cx, y), ch, font=f, fill=fill)
        cx += d.textlength(ch, font=f) + spacing
centred("NGC 2207  &  IC 2163", H - 470, font(118, 7), (255, 255, 255, 255), spacing=18)
centred("115 million light-years away  ·  IC 2163 grazes NGC 2207 and is drawn out into an eye",
        H - 310, font(46, 7), (225, 228, 235, 235))
small = font(40, 7)
centred("Simulation  ·  Sillage", 470, small, (235, 235, 240, 230), x=W / 4)
centred("James Webb and Hubble Space Telescopes", 470, small, (235, 235, 240, 230), x=3 * W / 4)
cred = "Image: NASA, ESA, CSA, STScI (CC BY 4.0)"
f = font(32, 7)
d.text((W - 60 - d.textlength(cred, font=f), H - 75), cred, font=f, fill=(210, 212, 220, 220))
im.save(sys.argv[1])
