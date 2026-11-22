"""Title and credits for the split screen, a transparent 3840x2160 PNG. usage: title.py <out.png>"""
import sys
from PIL import Image, ImageDraw, ImageFont
W, H = 3840, 2160
AV = "/System/Library/Fonts/Avenir Next.ttc"
def font(size, index):
    return ImageFont.truetype(AV, size, index=index)
im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
band = Image.new("L", (1, 520))
for y in range(520):
    band.putpixel((0, y), int(200 * (y / 519) ** 1.6))
im.paste((0, 0, 0, 255), (0, H - 520, W, H), band.resize((W, 520)))
d = ImageDraw.Draw(im)
def centred(text, y, f, fill, x=W / 2, spacing=0):
    w = d.textlength(text, font=f) + spacing * (len(text) - 1)
    cx = x - w / 2
    for ch in text:
        d.text((cx, y), ch, font=f, fill=fill)
        cx += d.textlength(ch, font=f) + spacing
centred("CARTWHEEL GALAXY", H - 330, font(118, 7), (255, 255, 255, 255), spacing=18)
centred("ESO 350-40  ·  500 million light-years away  ·  struck by a smaller galaxy a few hundred million years ago",
        H - 170, font(46, 7), (225, 228, 235, 235))
small = font(40, 7)
centred("Simulation  ·  Sillage", 70, small, (235, 235, 240, 230), x=W / 4)
centred("James Webb Space Telescope", 70, small, (235, 235, 240, 230), x=3 * W / 4)
cred = "Image: NASA, ESA, CSA, STScI (CC BY 4.0)"
f = font(32, 7)
d.text((W - 60 - d.textlength(cred, font=f), H - 75), cred, font=f, fill=(210, 212, 220, 220))
d.line([(W / 2, 0), (W / 2, H)], fill=(255, 255, 255, 90), width=3)
im.save(sys.argv[1])
