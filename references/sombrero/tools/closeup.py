"""closeup.py <out.jpg> <hubble full size> <frame 3072 px> [<frame> ...] [--labels a,b]: each frame's disk
band beside Hubble's at the same scale, laid flat about the core (504, 312 of 1024 x 606, rolled 5.63
degrees): the band 0.09 to 0.90 of the width and 0.41 to 0.63 of the height; then the lane's left end and
the core, tighter. Frames are Hubble's framing (26.5 kpc across)."""
import sys
from PIL import Image, ImageDraw, ImageFont
Image.MAX_IMAGE_PIXELS = None
args = sys.argv[1:]; labels = []
if "--labels" in args:
    i = args.index("--labels"); labels = args[i + 1].split(","); del args[i:i + 2]
out, ref, frames = args[0], args[1], args[2:]
W = 3072; H = round(W * 606 / 1024)
font = ImageFont.truetype("/System/Library/Fonts/Avenir Next.ttc", 34, index=5)
def flat(im):
    im = im.convert("RGB").resize((W, H), Image.LANCZOS)
    return im.rotate(5.63, resample=Image.BICUBIC, center=(504 * W / 1024, 312 * W / 1024))
boxes = [(0.09, 0.41, 0.90, 0.63), (0.09, 0.44, 0.30, 0.60), (0.40, 0.40, 0.60, 0.60)]
def crops(im):
    return [im.crop((round(a * W), round(b * H), round(c * W), round(d * H))) for a, b, c, d in boxes]
hub = crops(flat(Image.open(ref)))
rows = []
for n, f in enumerate(frames):
    ours = crops(flat(Image.open(f)))
    lab = labels[n] if n < len(labels) else f
    band = Image.new("RGB", (hub[0].width, hub[0].height * 2), "black")
    band.paste(hub[0], (0, 0)); band.paste(ours[0], (0, hub[0].height))
    tw = band.width // 2; th = round(hub[1].height * tw / hub[1].width)
    tight = Image.new("RGB", (band.width, th * 2), "black")
    for k, (h, o) in enumerate(zip(hub[1:], ours[1:])):
        tight.paste(h.resize((tw, th), Image.LANCZOS), (k * tw, 0)); tight.paste(o.resize((tw, th), Image.LANCZOS), (k * tw, th))
    row = Image.new("RGB", (band.width, band.height + tight.height + 50), "black")
    d = ImageDraw.Draw(row); d.text((10, 6), f"{lab}   (top: Hubble, below: Sillage; band, then lane's left end and core)", font=font, fill="white")
    row.paste(band, (0, 50)); row.paste(tight, (0, 50 + band.height)); rows.append(row)
sheet = Image.new("RGB", (rows[0].width, sum(r.height for r in rows)), "black")
y = 0
for r in rows: sheet.paste(r, (0, y)); y += r.height
sheet.save(out, quality=88)
print(out, sheet.size)
